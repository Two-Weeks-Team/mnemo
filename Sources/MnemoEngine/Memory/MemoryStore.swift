// The on-device record. Capture writes it; recall reads it; the rollup job
// reads closed day-buckets. It's an `actor` (the protocol can't enforce that,
// but the concrete impls are actors — capture and recall are concurrent, and
// that's the #1 corruption hazard). Phase 1 ships the in-memory impl;
// `SQLiteMemoryStore` (encrypted, tombstone deletes, outside all backup/sync/
// Spotlight scopes) is Phase 2. (Critic-loop §10.)

import Foundation

/// Result of an append: whether the event was new or a dedup hit.
public enum AppendOutcome: Sendable, Equatable {
    case stored(CaptureEvent)
    case duplicate(existingID: UUID)
}

public protocol MemoryStore: Actor {
    /// Append. Dedup by `fingerprint` within the same session-day. Embedding is
    /// NOT computed here — the event lands as-is; the enricher fills it later.
    func append(_ event: CaptureEvent) -> AppendOutcome

    /// Replace an event with its enriched version (same id; the enricher calls this).
    func storeEnrichment(eventID: UUID, embedding: [Float], entities: [EntityMention], structure: [StructureTag])

    /// Top-K events by embedding similarity to `queryVector`, full text, ANY age.
    /// (The temporal summary scaffold is assembled separately by the RecallEngine.)
    func retrieve(near queryVector: [Float], k: Int, minScore: Float) -> [CaptureEvent]

    /// Events in a time range, newest first.
    func events(in range: DateInterval) -> [CaptureEvent]

    /// Real delete (tombstone, then the impl vacuums).
    func delete(eventID: UUID)
    func deleteEvents(in range: DateInterval)

    /// All events (for tests / export). Phase 2's SQLite impl will stream this.
    func allEvents() -> [CaptureEvent]

    var count: Int { get }
}

/// In-memory `MemoryStore`. For tests and the Phase-1 skeleton. Holds a flat
/// vector index alongside the events so `retrieve` works once events are enriched.
public actor InMemoryMemoryStore: MemoryStore {
    private var byID: [UUID: CaptureEvent] = [:]
    private var seenFingerprints: Set<Data> = []
    private var index = FlatCosineVectorIndex()
    private var tombstones: Set<UUID> = []

    public init() {}

    public var count: Int { byID.count }

    public func append(_ event: CaptureEvent) -> AppendOutcome {
        if seenFingerprints.contains(event.fingerprint) {
            // Find the existing event with this fingerprint.
            if let existing = byID.values.first(where: { $0.fingerprint == event.fingerprint }) {
                return .duplicate(existingID: existing.id)
            }
        }
        seenFingerprints.insert(event.fingerprint)
        byID[event.id] = event
        if let emb = event.embedding { index.upsert(id: event.id, vector: emb) }
        return .stored(event)
    }

    public func storeEnrichment(eventID: UUID, embedding: [Float], entities: [EntityMention], structure: [StructureTag]) {
        guard var e = byID[eventID] else { return }
        e.embedding = embedding
        e.entities = entities
        e.structure = structure
        byID[eventID] = e
        index.upsert(id: eventID, vector: embedding)
    }

    public func retrieve(near queryVector: [Float], k: Int, minScore: Float) -> [CaptureEvent] {
        index.search(queryVector, k: k, minScore: minScore)
            .compactMap { byID[$0.id] }
    }

    public func events(in range: DateInterval) -> [CaptureEvent] {
        byID.values
            .filter { range.contains($0.timestamp) }
            .sorted { $0.timestamp > $1.timestamp }
    }

    public func delete(eventID: UUID) {
        if let e = byID.removeValue(forKey: eventID) {
            seenFingerprints.remove(e.fingerprint)
            index.remove(id: eventID)
            tombstones.insert(eventID)
        }
    }

    public func deleteEvents(in range: DateInterval) {
        for e in byID.values where range.contains(e.timestamp) { delete(eventID: e.id) }
    }

    public func allEvents() -> [CaptureEvent] {
        byID.values.sorted { $0.timestamp > $1.timestamp }
    }
}
