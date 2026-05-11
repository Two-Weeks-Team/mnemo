import Testing
import Foundation
@testable import MnemoEngine

@Suite("ContextBudgeter — fit the window")
struct ContextBudgeterTests {

    private func evt(_ text: String, daysAgo: Int = 0) -> CaptureEvent {
        CaptureEvent(timestamp: Date().addingTimeInterval(TimeInterval(-daysAgo * 86_400)),
                     source: .manual, text: text)
    }
    private func daily(_ s: String, daysAgo: Int) -> DailySummary {
        let start = Date().addingTimeInterval(TimeInterval(-daysAgo * 86_400))
        return DailySummary(date: DateInterval(start: start, duration: 86_400), summary: s)
    }
    private func rollup(_ s: String, tier: SummaryTier) -> RollupSummary {
        RollupSummary(tier: tier, span: DateInterval(start: Date(), duration: 86_400), summary: s)
    }

    // 1 token ≈ 1 character here, so budgets are easy to reason about.
    private func budgeter(window: Int, rawShare: Double = 0.5) -> ContextBudgeter {
        let b = ContextBudget(windowTokens: window, systemPromptTokens: 0, toolSpecTokens: 0,
                              scratchpadTokens: 0, rawRetrievalShare: rawShare)
        return ContextBudgeter(budget: b, tokensFor: { $0.count })
    }

    @Test("Overhead is budgeted first; events get the remainder")
    func overheadFirst() {
        let b = ContextBudget(windowTokens: 1000, systemPromptTokens: 100, toolSpecTokens: 50,
                              scratchpadTokens: 200)
        #expect(b.eventBudget == 650)
    }

    @Test("Everything fits when there's room")
    func everythingFits() {
        let bdg = budgeter(window: 10_000)
        let raw = [evt("alpha"), evt("beta"), evt("gamma")]
        let ds = [daily("monday was busy", daysAgo: 3)]
        let c = bdg.assemble(rankedRawHits: raw, scaffoldDailies: ds, scaffoldRollups: [])
        #expect(c.rawEvents.count == 3)
        #expect(c.dailySummaries.count == 1)
        #expect(c.droppedEventCount == 0)
    }

    @Test("Raw retrieval is capped; the best hits win, the rest are dropped")
    func rawCapped() {
        // window 20, rawShare 0.5 → rawCap 10, scaffoldCap 10. No scaffold here,
        // so the slack rolls into raw → effective raw budget 20.
        // Each event text is 6 chars → 3 fit (18 ≤ 20), 4th dropped.
        let bdg = budgeter(window: 20)
        let raw = ["aaaaaa", "bbbbbb", "cccccc", "dddddd"].map { evt($0) }
        let c = bdg.assemble(rankedRawHits: raw, scaffoldDailies: [], scaffoldRollups: [])
        #expect(c.rawEvents.count == 3)
        #expect(c.droppedEventCount == 1)
    }

    @Test("A high-similarity OLD raw hit is kept (any age — not summarized away)")
    func oldRawHitKept() {
        // The budgeter doesn't know ages affect rank — the *caller* ranks. We
        // just verify a 400-days-ago event passed in `rankedRawHits` is included
        // when it fits.
        let bdg = budgeter(window: 1000)
        let raw = [evt("the case number was XJ-4471", daysAgo: 400), evt("recent thing", daysAgo: 1)]
        let c = bdg.assemble(rankedRawHits: raw, scaffoldDailies: [], scaffoldRollups: [])
        #expect(c.rawEvents.contains { $0.text.contains("XJ-4471") })
    }

    @Test("Finer rollup tiers are preferred over coarser ones when both can't fit")
    func finerTiersPreferred() {
        // window small enough that only one rollup fits. weekly (10 chars) before yearly (10 chars)
        // → both 10; with budget for exactly one, the weekly (finer) wins.
        let b = ContextBudget(windowTokens: 12, systemPromptTokens: 0, toolSpecTokens: 0,
                              scratchpadTokens: 0, rawRetrievalShare: 0.0)  // all budget → scaffold
        let bdg = ContextBudgeter(budget: b, tokensFor: { $0.count })
        let rollups = [rollup("yyyyyyyyyy", tier: .yearly), rollup("wwwwwwwwww", tier: .weekly)]
        let c = bdg.assemble(rankedRawHits: [], scaffoldDailies: [], scaffoldRollups: rollups)
        #expect(c.rollups.count == 1)
        #expect(c.rollups.first?.tier == .weekly)
    }

    @Test("rawEvents come back newest-first")
    func rawSortedNewestFirst() {
        let bdg = budgeter(window: 10_000)
        let raw = [evt("oldest", daysAgo: 30), evt("newest", daysAgo: 1), evt("middle", daysAgo: 10)]
        let c = bdg.assemble(rankedRawHits: raw, scaffoldDailies: [], scaffoldRollups: [])
        #expect(c.rawEvents.map(\.text) == ["newest", "middle", "oldest"])
    }
}
