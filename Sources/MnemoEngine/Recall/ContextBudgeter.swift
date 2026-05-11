// Pack the recall context into the model's window. Two sources fight over the
// budget (critic-loop §10): (a) top-K raw retrieval — full text, ANY age; (b)
// the temporal summary scaffold (today raw → this-week dailies → this-month
// weeklies → older monthlies → a yearly tier so it's bounded). The fixed
// overhead (system prompt + the function-contract tool spec + a scratchpad
// reserve) is budgeted FIRST; events get the remainder. Token counting is
// injected (a closure) so this is a pure, deterministic, testable function —
// the *allocation policy* is what's under test, not the tokenizer.

import Foundation

public struct ContextBudget: Sendable {
    /// The model's context window, in tokens (Gemma 4 E4B = 128_000).
    public var windowTokens: Int
    /// Reserve for the system prompt.
    public var systemPromptTokens: Int
    /// Reserve for the function-contract tool spec.
    public var toolSpecTokens: Int
    /// Reserve for the model's function-call scratchpad + the answer it will write.
    public var scratchpadTokens: Int
    /// How much of the *event* budget goes to top-K raw retrieval vs. the
    /// temporal scaffold (0...1; the rest goes to the scaffold).
    public var rawRetrievalShare: Double

    public init(windowTokens: Int = 128_000, systemPromptTokens: Int = 800,
                toolSpecTokens: Int = 400, scratchpadTokens: Int = 2_000,
                rawRetrievalShare: Double = 0.55) {
        self.windowTokens = windowTokens
        self.systemPromptTokens = systemPromptTokens
        self.toolSpecTokens = toolSpecTokens
        self.scratchpadTokens = scratchpadTokens
        self.rawRetrievalShare = max(0, min(1, rawRetrievalShare))
    }

    /// Tokens available for retrieved events + summary scaffold.
    public var eventBudget: Int {
        max(0, windowTokens - systemPromptTokens - toolSpecTokens - scratchpadTokens)
    }
}

/// What goes into the model, after budgeting.
public struct AssembledContext: Sendable, Equatable {
    public var rawEvents: [CaptureEvent]      // included full-text, newest-first within their slice
    public var dailySummaries: [DailySummary]
    public var rollups: [RollupSummary]
    public var droppedEventCount: Int         // how many candidate raw events didn't fit
    public var droppedSummaryCount: Int
}

public struct ContextBudgeter: Sendable {
    public let budget: ContextBudget
    /// Token estimator. For text it should approximate the real tokenizer; for
    /// an event it should also account for any image-derived structure tags.
    private let tokensFor: @Sendable (String) -> Int

    public init(budget: ContextBudget = .init(),
                tokensFor: @escaping @Sendable (String) -> Int = { max(1, $0.count / 4) }) {
        self.budget = budget
        self.tokensFor = tokensFor
    }

    private func tokens(_ e: CaptureEvent) -> Int {
        var t = tokensFor(e.text)
        // structure tags add a little; an image-derived event carries more.
        t += (e.structure?.count ?? 0) * 4
        if e.rawRef?.kind == .image { t += 24 }   // a small fixed penalty for "this came from an image"
        return t
    }
    private func tokens(_ s: DailySummary) -> Int { tokensFor(s.summary) + s.keyEventIDs.count }
    private func tokens(_ r: RollupSummary) -> Int { tokensFor(r.summary) + r.childSummaryIDs.count }

    /// Assemble. `rankedRawHits` is the retrieval output, best-first, any age.
    /// `scaffold` is the temporal tiers, most-recent-first within each tier,
    /// most-recent tier first. Both compete for `budget.eventBudget`, split by
    /// `rawRetrievalShare`; if one side under-uses its share, the other gets the
    /// slack.
    public func assemble(
        rankedRawHits: [CaptureEvent],
        scaffoldDailies: [DailySummary],
        scaffoldRollups: [RollupSummary]
    ) -> AssembledContext {
        let total = budget.eventBudget
        let rawCap = Int(Double(total) * budget.rawRetrievalShare)
        let scaffoldCap = total - rawCap

        // Fill raw first, up to rawCap.
        var raw: [CaptureEvent] = []
        var rawUsed = 0
        var droppedRaw = 0
        for e in rankedRawHits {
            let t = tokens(e)
            if rawUsed + t <= rawCap { raw.append(e); rawUsed += t }
            else { droppedRaw += 1 }
        }
        // Slack from raw rolls into the scaffold.
        let scaffoldBudgetActual = scaffoldCap + (rawCap - rawUsed)

        // Fill the scaffold: dailies first (finest, most recent), then rollups
        // coarse-last (yearly is cheapest per span).
        var dailies: [DailySummary] = []
        var rollups: [RollupSummary] = []
        var sUsed = 0
        var droppedS = 0
        for s in scaffoldDailies {
            let t = tokens(s)
            if sUsed + t <= scaffoldBudgetActual { dailies.append(s); sUsed += t } else { droppedS += 1 }
        }
        // Within rollups, prefer finer tiers (weekly before monthly before yearly)
        // because finer detail is more useful when it fits.
        for r in scaffoldRollups.sorted(by: { $0.tier < $1.tier }) {
            let t = tokens(r)
            if sUsed + t <= scaffoldBudgetActual { rollups.append(r); sUsed += t } else { droppedS += 1 }
        }
        // Second pass: whatever's left of the WHOLE event budget can take more
        // raw hits. (Invariant: after step 1, rawUsed ≤ rawCap; after step 2,
        // sUsed ≤ scaffoldCap + (rawCap - rawUsed), so rawUsed + sUsed ≤ total;
        // here we top up raw with exactly the remainder, so the bound holds.)
        if droppedRaw > 0 {
            let leftover = total - rawUsed - sUsed
            if leftover > 0 {
                let remaining = rankedRawHits.dropFirst(raw.count)
                var extraUsed = 0
                for e in remaining {
                    let t = tokens(e)
                    if extraUsed + t <= leftover { raw.append(e); extraUsed += t; rawUsed += t; droppedRaw -= 1 }
                }
            }
        }

        let sortedRollups = rollups.sorted {
            $0.tier != $1.tier ? $0.tier < $1.tier : $0.span.start < $1.span.start
        }
        return AssembledContext(
            rawEvents: raw.sorted { $0.timestamp > $1.timestamp },
            dailySummaries: dailies,
            rollups: sortedRollups,
            droppedEventCount: max(0, droppedRaw),
            droppedSummaryCount: droppedS
        )
    }
}
