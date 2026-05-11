// query → (abstention check) → embed → retrieve top-K raw + assemble the
// temporal scaffold → budget to fit the window → Gemma reasons → RecallResult.
// Phase 1: real retrieval (against the in-memory store) + real budgeting +
// stub Gemma. (Critic-loop §10.)

import Foundation

public actor RecallEngine {
    private let store: any MemoryStore
    private let embedder: any EmbeddingService
    private let gemma: any GemmaReasoning
    private let budgeter: ContextBudgeter
    private let abstention: AbstentionGate
    private let topK: Int

    public init(
        store: any MemoryStore,
        embedder: any EmbeddingService,
        gemma: any GemmaReasoning,
        budgeter: ContextBudgeter = .init(),
        abstention: AbstentionGate = .init(),
        topK: Int = 24
    ) {
        self.store = store
        self.embedder = embedder
        self.gemma = gemma
        self.budgeter = budgeter
        self.abstention = abstention
        self.topK = topK
    }

    /// `scaffoldDailies` / `scaffoldRollups` are normally supplied by the
    /// SummaryEngine (Phase 2); Phase 1 callers pass `[]` and the recall runs
    /// on raw events alone.
    public func recall(
        _ query: RecallQuery,
        scaffoldDailies: [DailySummary] = [],
        scaffoldRollups: [RollupSummary] = []
    ) async -> RecallResult {
        // 1. Abstention gate — recall, don't advise.
        if let domain = abstention.evaluate(query.text) {
            let ref = abstention.referral(for: domain)
            return RecallResult(
                answerText: ref.reason,
                citations: [],
                confidence: 1.0,
                urgency: domain == .emergency ? .urgent : .attention,
                suggestedModality: nil,
                deferredToHuman: ref
            )
        }

        // 2. Retrieve top-K raw events by embedding similarity (any age).
        let qVec = await embedder.embed(query.text)
        var rawHits = await store.retrieve(near: qVec, k: topK, minScore: -1)
        // If the query carries an explicit time range, prefer events inside it.
        if let range = query.timeRange {
            let inRange = await store.events(in: range)
            let inRangeIDs = Set(inRange.map(\.id))
            rawHits = inRange + rawHits.filter { !inRangeIDs.contains($0.id) }
        }

        // 3. Budget the context to fit the window.
        let ctx = budgeter.assemble(
            rankedRawHits: rawHits,
            scaffoldDailies: scaffoldDailies,
            scaffoldRollups: scaffoldRollups
        )

        // 4. Reason.
        let out = await gemma.recall(
            query: query.text,
            contextEvents: ctx.rawEvents,
            contextSummaries: ctx.dailySummaries
        )

        // 5. Build citations (with availability — Phase 1: everything that
        // survives is rawAndText or textOnly depending on whether a blob exists).
        let byID = Dictionary(uniqueKeysWithValues: ctx.rawEvents.map { ($0.id, $0) })
        let citations: [CitationRef] = out.citedEventIDs.compactMap { id in
            guard let e = byID[id] else { return nil }
            let avail: CitationRef.Availability = e.rawRef != nil ? .rawAndText : .textOnly
            let snippet = e.text.count > 200 ? String(e.text.prefix(197)) + "…" : e.text
            return CitationRef(eventID: id, timestamp: e.timestamp, snippet: snippet, availability: avail)
        }

        return RecallResult(
            answerText: out.answerText,
            citations: citations,
            confidence: out.confidence,
            urgency: out.urgency,
            suggestedModality: out.suggestedModality,
            deferredToHuman: nil
        )
    }
}
