// The on-disk `MemoryStore` (Phase 2). One SQLite file in a hardened directory
// (outside backup / sync / Spotlight — see StorageHardening). Each event is one
// row: a few indexed scalar columns + the full `Codable` `CaptureEvent` as a
// JSON blob. The vector index is held in memory (a flat-cosine index, rebuilt
// from the rows that carry an embedding on open) — fine up to ~10^5–10^6 events;
// an on-disk ANN index is a later swap behind the same `VectorIndex` protocol.
//
// Deletes are REAL: the row's payload columns are nulled and `deleted = 1` is
// set, leaving an `(id, timestamp, deleted)` tombstone so a future sync layer
// can tell the difference between "never had it" and "had it, removed it" —
// while the *content* is genuinely gone (not merely hidden). `compact()` runs
// `VACUUM` to reclaim the space.

import Foundation

public actor SQLiteMemoryStore: MemoryStore {
    private let db: SQLiteDB
    private let directory: URL
    private let dbURL: URL
    private var index = FlatCosineVectorIndex()
    private var liveCount: Int = 0

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]  // deterministic blobs (eases diffing / tests)
        return e
    }()
    private let decoder = JSONDecoder()

    /// Open (creating if needed) the store at `directory/mnemo.sqlite3`. Hardens
    /// the directory and the db files. Rebuilds the in-memory vector index from
    /// any already-enriched rows.
    public init(directory: URL) throws {
        try StorageHardening.hardenDirectory(directory)
        self.directory = directory
        self.dbURL = directory.appendingPathComponent("mnemo.sqlite3")
        self.db = try SQLiteDB(path: dbURL)
        try Self.migrate(db)
        // Harden the db + its WAL/SHM sidecars (created by the WAL pragma above).
        for suffix in ["", "-wal", "-shm"] {
            try? StorageHardening.hardenFile(URL(fileURLWithPath: dbURL.path + suffix))
        }
        // Rebuild the in-memory vector index + the live-row count from disk.
        // (Inline, not a helper call — a synchronous actor `init` may touch its
        // own stored properties but not call isolated instance methods.)
        let (idx, n) = try Self.loadIndexAndCount(db: db, decoder: decoder)
        self.index = idx
        self.liveCount = n
    }

    // MARK: schema

    private static func migrate(_ db: SQLiteDB) throws {
        try db.exec(
            """
            CREATE TABLE IF NOT EXISTS events (
              id          TEXT PRIMARY KEY NOT NULL,
              timestamp   REAL NOT NULL,
              source      TEXT NOT NULL,
              fingerprint BLOB,
              sensitivity TEXT,
              bundle_id   TEXT,
              deleted     INTEGER NOT NULL DEFAULT 0,
              json        BLOB
            );
            CREATE INDEX IF NOT EXISTS idx_events_ts     ON events(timestamp) WHERE deleted = 0;
            CREATE INDEX IF NOT EXISTS idx_events_fp     ON events(fingerprint) WHERE deleted = 0;
            CREATE INDEX IF NOT EXISTS idx_events_source ON events(source) WHERE deleted = 0;
            CREATE INDEX IF NOT EXISTS idx_events_bundle ON events(bundle_id) WHERE deleted = 0;
            """
        )
    }

    private static func loadIndexAndCount(
        db: SQLiteDB, decoder: JSONDecoder
    ) throws -> (FlatCosineVectorIndex, Int) {
        var idx = FlatCosineVectorIndex()
        var n = 0
        let s = try db.prepare("SELECT json FROM events WHERE deleted = 0;")
        defer { s.finalize() }
        while try s.step() {
            n += 1
            if let e = try? decoder.decode(CaptureEvent.self, from: s.columnBlob(0)),
                let emb = e.embedding {
                idx.upsert(id: e.id, vector: emb)
            }
        }
        return (idx, n)
    }

    // MARK: MemoryStore

    public var count: Int { liveCount }

    public func append(_ event: CaptureEvent) -> AppendOutcome {
        // Dedup against live rows with the same fingerprint.
        if let existingID = try? firstLiveID(matchingFingerprint: event.fingerprint) {
            return .duplicate(existingID: existingID)
        }
        do {
            let json = try encoder.encode(event)
            try db.run(
                """
                INSERT INTO events (id, timestamp, source, fingerprint, sensitivity, bundle_id, deleted, json)
                VALUES (?, ?, ?, ?, ?, ?, 0, ?);
                """,
                [
                    .text(event.id.uuidString),
                    .double(event.timestamp.timeIntervalSinceReferenceDate),
                    .text(event.source.rawValue),
                    .blob(event.fingerprint),
                    .text(event.sensitivity.rawValue),
                    event.appContext.map { .text($0.bundleId) } ?? .null,
                    .blob(json),
                ]
            )
            liveCount += 1
            if let emb = event.embedding { index.upsert(id: event.id, vector: emb) }
            return .stored(event)
        } catch {
            // A failed write leaves the store unchanged. The protocol is
            // non-throwing, so we trap in debug and report optimistically in
            // release (a disk-full / corruption condition the app layer must
            // surface separately — Phase 5).
            assertionFailure("SQLiteMemoryStore.append failed: \(error)")
            return .stored(event)
        }
    }

    public func storeEnrichment(
        eventID: UUID, embedding: [Float], entities: [EntityMention], structure: [StructureTag]
    ) {
        guard var e = (try? loadLive(id: eventID)) ?? nil else { return }
        e.embedding = embedding
        e.entities = entities
        e.structure = structure
        do {
            let json = try encoder.encode(e)
            try db.run(
                "UPDATE events SET json = ? WHERE id = ? AND deleted = 0;",
                [.blob(json), .text(eventID.uuidString)]
            )
            index.upsert(id: eventID, vector: embedding)
        } catch {
            assertionFailure("SQLiteMemoryStore.storeEnrichment failed: \(error)")
        }
    }

    public func retrieve(near queryVector: [Float], k: Int, minScore: Float) -> [CaptureEvent] {
        index.search(queryVector, k: k, minScore: minScore)
            .compactMap { hit in (try? loadLive(id: hit.id)) ?? nil }
    }

    public func events(in range: DateInterval) -> [CaptureEvent] {
        (try? query(
            """
            SELECT json FROM events
            WHERE deleted = 0 AND timestamp >= ? AND timestamp <= ?
            ORDER BY timestamp DESC;
            """,
            [
                .double(range.start.timeIntervalSinceReferenceDate),
                .double(range.end.timeIntervalSinceReferenceDate),
            ]
        )) ?? []
    }

    public func delete(eventID: UUID) {
        do {
            try db.run(
                "UPDATE events SET deleted = 1, json = NULL, fingerprint = NULL, bundle_id = NULL WHERE id = ? AND deleted = 0;",
                [.text(eventID.uuidString)]
            )
            index.remove(id: eventID)
            try recountIfNeeded()
        } catch {
            assertionFailure("SQLiteMemoryStore.delete failed: \(error)")
        }
    }

    public func deleteEvents(in range: DateInterval) {
        // Collect the ids first (so we can prune the in-memory index), then
        // tombstone in one statement.
        let ids = ((try? query(
            "SELECT json FROM events WHERE deleted = 0 AND timestamp >= ? AND timestamp <= ?;",
            [
                .double(range.start.timeIntervalSinceReferenceDate),
                .double(range.end.timeIntervalSinceReferenceDate),
            ]
        )) ?? []).map(\.id)
        guard !ids.isEmpty else { return }
        do {
            try db.run(
                "UPDATE events SET deleted = 1, json = NULL, fingerprint = NULL, bundle_id = NULL WHERE deleted = 0 AND timestamp >= ? AND timestamp <= ?;",
                [
                    .double(range.start.timeIntervalSinceReferenceDate),
                    .double(range.end.timeIntervalSinceReferenceDate),
                ]
            )
            for id in ids { index.remove(id: id) }
            try recountIfNeeded()
        } catch {
            assertionFailure("SQLiteMemoryStore.deleteEvents failed: \(error)")
        }
    }

    public func allEvents() -> [CaptureEvent] {
        (try? query("SELECT json FROM events WHERE deleted = 0 ORDER BY timestamp DESC;")) ?? []
    }

    // MARK: maintenance (not part of the protocol)

    /// Reclaim space left by tombstoned rows. Run on idle/charging.
    public func compact() throws { try db.vacuum() }

    /// Number of tombstones (deleted rows whose content has been removed).
    public func tombstoneCount() -> Int {
        (try? scalarInt("SELECT COUNT(*) FROM events WHERE deleted = 1;")) ?? 0
    }

    // MARK: helpers

    private func query(_ sql: String, _ binds: [SQLiteValue] = []) throws -> [CaptureEvent] {
        let s = try db.prepare(sql)
        defer { s.finalize() }
        for (i, v) in binds.enumerated() { try s.bind(v, at: Int32(i + 1)) }
        var out: [CaptureEvent] = []
        while try s.step() {
            if let e = try? decoder.decode(CaptureEvent.self, from: s.columnBlob(0)) { out.append(e) }
        }
        return out
    }

    private func loadLive(id: UUID) throws -> CaptureEvent? {
        let s = try db.prepare("SELECT json FROM events WHERE id = ? AND deleted = 0;")
        defer { s.finalize() }
        try s.bind(.text(id.uuidString), at: 1)
        guard try s.step() else { return nil }
        return try? decoder.decode(CaptureEvent.self, from: s.columnBlob(0))
    }

    private func firstLiveID(matchingFingerprint fp: Data) throws -> UUID? {
        let s = try db.prepare("SELECT id FROM events WHERE deleted = 0 AND fingerprint = ? LIMIT 1;")
        defer { s.finalize() }
        try s.bind(.blob(fp), at: 1)
        guard try s.step() else { return nil }
        return UUID(uuidString: s.columnText(0))
    }

    private func scalarInt(_ sql: String) throws -> Int {
        let s = try db.prepare(sql)
        defer { s.finalize() }
        guard try s.step() else { return 0 }
        return Int(s.columnInt(0))
    }

    private func recountIfNeeded() throws {
        liveCount = try scalarInt("SELECT COUNT(*) FROM events WHERE deleted = 0;")
    }
}
