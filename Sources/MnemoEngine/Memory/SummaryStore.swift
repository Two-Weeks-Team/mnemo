// Where the hierarchical summaries live. The SummaryEngine writes closed-bucket
// summaries here; the RecallEngine reads the scaffold from here. Like the event
// store it's an `actor` (the rollup job and recall both touch it). Phase 2
// ships an in-memory impl + a SQLite-backed one (its own hardened db file,
// alongside the event db).

import Foundation

public protocol SummaryStore: Actor {
    func upsertDaily(_ summary: DailySummary)
    func upsertRollup(_ summary: RollupSummary)

    /// Daily summaries whose day-bucket starts within `span`, ascending by start.
    func daily(in span: DateInterval) -> [DailySummary]
    /// Rollups of `tier` whose span starts within `span`, ascending by start.
    func rollups(tier: SummaryTier, in span: DateInterval) -> [RollupSummary]

    /// Has a daily summary already been written for the day starting at `dayStart`?
    func hasDaily(forDayStarting dayStart: Date) -> Bool
    /// Has a rollup of `tier` already been written for the span starting at `spanStart`?
    func hasRollup(tier: SummaryTier, spanStarting spanStart: Date) -> Bool

    func allDaily() -> [DailySummary]
    func allRollups() -> [RollupSummary]
}

/// In-memory `SummaryStore`. For tests and the skeleton.
public actor InMemorySummaryStore: SummaryStore {
    private var dailyByDayStart: [Date: DailySummary] = [:]
    private var rollupBySpanStart: [SummaryTier: [Date: RollupSummary]] = [:]

    public init() {}

    public func upsertDaily(_ summary: DailySummary) {
        dailyByDayStart[summary.date.start] = summary
    }
    public func upsertRollup(_ summary: RollupSummary) {
        rollupBySpanStart[summary.tier, default: [:]][summary.span.start] = summary
    }

    public func daily(in span: DateInterval) -> [DailySummary] {
        dailyByDayStart.values
            .filter { span.contains($0.date.start) }
            .sorted { $0.date.start < $1.date.start }
    }
    public func rollups(tier: SummaryTier, in span: DateInterval) -> [RollupSummary] {
        (rollupBySpanStart[tier] ?? [:]).values
            .filter { span.contains($0.span.start) }
            .sorted { $0.span.start < $1.span.start }
    }

    public func hasDaily(forDayStarting dayStart: Date) -> Bool {
        dailyByDayStart[dayStart] != nil
    }
    public func hasRollup(tier: SummaryTier, spanStarting spanStart: Date) -> Bool {
        (rollupBySpanStart[tier] ?? [:])[spanStart] != nil
    }

    public func allDaily() -> [DailySummary] {
        dailyByDayStart.values.sorted { $0.date.start < $1.date.start }
    }
    public func allRollups() -> [RollupSummary] {
        rollupBySpanStart.values.flatMap { $0.values }.sorted {
            $0.tier == $1.tier ? $0.span.start < $1.span.start : $0.tier < $1.tier
        }
    }
}

/// SQLite-backed `SummaryStore`. One file (`summaries.sqlite3`) in a hardened
/// directory. Two tables; each summary stored as its `Codable` JSON plus the
/// scalar columns we filter on (`bucket_start`, `tier`).
public actor SQLiteSummaryStore: SummaryStore {
    private let db: SQLiteDB
    private let dbURL: URL
    private let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; return e
    }()
    private let decoder = JSONDecoder()

    public init(directory: URL) throws {
        try StorageHardening.hardenDirectory(directory)
        self.dbURL = directory.appendingPathComponent("summaries.sqlite3")
        self.db = try SQLiteDB(path: dbURL)
        try db.exec(
            """
            CREATE TABLE IF NOT EXISTS daily (
              day_start REAL PRIMARY KEY NOT NULL,
              json      BLOB NOT NULL
            );
            CREATE TABLE IF NOT EXISTS rollups (
              tier       INTEGER NOT NULL,
              span_start REAL NOT NULL,
              json       BLOB NOT NULL,
              PRIMARY KEY (tier, span_start)
            );
            """
        )
        for suffix in ["", "-wal", "-shm"] {
            try? StorageHardening.hardenFile(URL(fileURLWithPath: dbURL.path + suffix))
        }
    }

    public func upsertDaily(_ summary: DailySummary) {
        guard let json = try? encoder.encode(summary) else { return }
        try? db.run(
            "INSERT OR REPLACE INTO daily (day_start, json) VALUES (?, ?);",
            [.double(summary.date.start.timeIntervalSinceReferenceDate), .blob(json)]
        )
    }
    public func upsertRollup(_ summary: RollupSummary) {
        guard let json = try? encoder.encode(summary) else { return }
        try? db.run(
            "INSERT OR REPLACE INTO rollups (tier, span_start, json) VALUES (?, ?, ?);",
            [
                .int(Int64(summary.tier.rawValue)),
                .double(summary.span.start.timeIntervalSinceReferenceDate),
                .blob(json),
            ]
        )
    }

    public func daily(in span: DateInterval) -> [DailySummary] {
        (try? decodeAll(
            "SELECT json FROM daily WHERE day_start >= ? AND day_start <= ? ORDER BY day_start ASC;",
            [
                .double(span.start.timeIntervalSinceReferenceDate),
                .double(span.end.timeIntervalSinceReferenceDate),
            ],
            as: DailySummary.self
        )) ?? []
    }
    public func rollups(tier: SummaryTier, in span: DateInterval) -> [RollupSummary] {
        (try? decodeAll(
            "SELECT json FROM rollups WHERE tier = ? AND span_start >= ? AND span_start <= ? ORDER BY span_start ASC;",
            [
                .int(Int64(tier.rawValue)),
                .double(span.start.timeIntervalSinceReferenceDate),
                .double(span.end.timeIntervalSinceReferenceDate),
            ],
            as: RollupSummary.self
        )) ?? []
    }

    public func hasDaily(forDayStarting dayStart: Date) -> Bool {
        (try? exists("SELECT 1 FROM daily WHERE day_start = ? LIMIT 1;",
                     [.double(dayStart.timeIntervalSinceReferenceDate)])) ?? false
    }
    public func hasRollup(tier: SummaryTier, spanStarting spanStart: Date) -> Bool {
        (try? exists("SELECT 1 FROM rollups WHERE tier = ? AND span_start = ? LIMIT 1;",
                     [.int(Int64(tier.rawValue)), .double(spanStart.timeIntervalSinceReferenceDate)])) ?? false
    }

    public func allDaily() -> [DailySummary] {
        (try? decodeAll("SELECT json FROM daily ORDER BY day_start ASC;", [], as: DailySummary.self)) ?? []
    }
    public func allRollups() -> [RollupSummary] {
        (try? decodeAll("SELECT json FROM rollups ORDER BY tier ASC, span_start ASC;", [], as: RollupSummary.self)) ?? []
    }

    // MARK: helpers

    private func decodeAll<T: Decodable>(
        _ sql: String, _ binds: [SQLiteValue], as: T.Type
    ) throws -> [T] {
        let s = try db.prepare(sql)
        defer { s.finalize() }
        for (i, v) in binds.enumerated() { try s.bind(v, at: Int32(i + 1)) }
        var out: [T] = []
        while try s.step() {
            if let v = try? decoder.decode(T.self, from: s.columnBlob(0)) { out.append(v) }
        }
        return out
    }
    private func exists(_ sql: String, _ binds: [SQLiteValue]) throws -> Bool {
        let s = try db.prepare(sql)
        defer { s.finalize() }
        for (i, v) in binds.enumerated() { try s.bind(v, at: Int32(i + 1)) }
        return try s.step()
    }
}
