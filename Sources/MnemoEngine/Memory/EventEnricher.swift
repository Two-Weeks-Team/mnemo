// The deferred-enrichment seam. Capture lands an event cheaply (fingerprint
// only); a background pass computes the embedding (and, later, entities +
// structure via Gemma vision/NLP) and writes it back via
// `MemoryStore.storeEnrichment`. Embedding inference is NEVER in the capture
// write path. (Critic-loop §10, blocking issue #1.)
//
// Phase 1: a synchronous stub that embeds via `EmbeddingService` and extracts
// no entities/structure (empty arrays). Phase 3: real entity/structure
// extraction via Gemma 4.

import Foundation

public protocol EventEnriching: Sendable {
    /// Enrich a single event and persist the result. Safe to call off the
    /// capture path (e.g. from a background task / on idle).
    func enrich(eventID: UUID, text: String, in store: any MemoryStore) async
}

public struct StubEventEnricher: EventEnriching {
    private let embedder: any EmbeddingService
    public init(embedder: any EmbeddingService = StubEmbeddingService()) { self.embedder = embedder }

    public func enrich(eventID: UUID, text: String, in store: any MemoryStore) async {
        let emb = await embedder.embed(text)
        await store.storeEnrichment(eventID: eventID, embedding: emb, entities: [], structure: [])
    }
}
