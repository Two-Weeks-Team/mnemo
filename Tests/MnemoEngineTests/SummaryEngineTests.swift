import Testing
import Foundation
@testable import MnemoEngine

@Suite("SummaryEngine — graceful memory: roll up CLOSED buckets, never mutate events")
struct SummaryEngineTests {

    private let cal = SummaryEngine.utcISOCalendar
    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: 0))!
    }

    /// Memory pre-loaded with four events across two ISO weeks of March 2026.
    private func loadedMemory() async -> InMemoryMemoryStore {
        let m = InMemoryMemoryStore()
        let events = [
            CaptureEvent(timestamp: date(2026, 3, 2, 11), source: .manual,
                         text: "moving boxes from the old apartment"),
            CaptureEvent(timestamp: date(2026, 3, 9, 10), source: .screen,
                         text: "project kickoff meeting notes"),
            CaptureEvent(timestamp: date(2026, 3, 9, 14), source: .audio,
                         text: "lunch with Jordan, talked about the move"),
            CaptureEvent(timestamp: date(2026, 3, 11, 9), source: .clipboard,
                         text: "dentist appointment Thursday at 3pm"),
        ]
        for e in events { _ = await m.append(e) }
        return m
    }

    @Test("Daily + weekly rollups land for closed buckets; the open month/year do not")
    func rollupsRespectClosedBuckets() async {
        let memory = await loadedMemory()
        let summaries = InMemorySummaryStore()
        let clock = FixedClock(date(2026, 3, 16, 12))   // Monday — 03-02..03-15 are closed
        let engine = SummaryEngine(memory: memory, summaries: summaries, model: StubGemmaService(), clock: clock, calendar: cal)

        let run = await engine.runRollups()
        #expect(run.dailyCreated == 3)    // 03-02, 03-09 (2 events → 1 daily), 03-11
        #expect(run.weeklyCreated == 2)   // week of 03-02, week of 03-09
        #expect(run.monthlyCreated == 0)  // March is not closed yet (now is 03-16)
        #expect(run.yearlyCreated == 0)   // 2026 is not closed
        #expect(run.total == 5)

        let dailies = await summaries.allDaily()
        #expect(dailies.count == 3)
        // The 03-09 daily summarizes both that day's events; its keyEventIDs are real.
        let allEventIDs = Set(await memory.allEvents().map(\.id))
        for d in dailies { #expect(Set(d.keyEventIDs).isSubset(of: allEventIDs)) }
        // The weekly rollups link their daily children.
        let weeklies = await summaries.allRollups().filter { $0.tier == .weekly }
        #expect(weeklies.count == 2)
        let dailyIDs = Set(dailies.map(\.id))
        for w in weeklies {
            #expect(!w.childSummaryIDs.isEmpty)
            #expect(Set(w.childSummaryIDs).isSubset(of: dailyIDs))
        }
    }

    @Test("Idempotent: a second run with no newly-closed buckets creates nothing")
    func idempotent() async {
        let memory = await loadedMemory()
        let summaries = InMemorySummaryStore()
        let clock = FixedClock(date(2026, 3, 16, 12))
        let engine = SummaryEngine(memory: memory, summaries: summaries, model: StubGemmaService(), clock: clock, calendar: cal)

        _ = await engine.runRollups()
        let again = await engine.runRollups()
        #expect(again.total == 0)
        #expect(await summaries.allDaily().count == 3)
        #expect(await summaries.allRollups().count == 2)
    }

    @Test("The rollup never mutates a CaptureEvent")
    func doesNotMutateEvents() async {
        let memory = await loadedMemory()
        let before = await memory.allEvents()
        let summaries = InMemorySummaryStore()
        let engine = SummaryEngine(memory: memory, summaries: summaries, model: StubGemmaService(),
                                   clock: FixedClock(date(2026, 3, 16, 12)), calendar: cal)
        _ = await engine.runRollups()
        let after = await memory.allEvents()
        #expect(before == after)   // CaptureEvent is Equatable; nothing changed
    }

    @Test("Once a month closes, its monthly rollup is built from the weekly rollups")
    func monthlyRollupAfterMonthCloses() async {
        let memory = await loadedMemory()
        let summaries = InMemorySummaryStore()
        let clock = FixedClock(date(2026, 3, 16, 12))
        let engine = SummaryEngine(memory: memory, summaries: summaries, model: StubGemmaService(), clock: clock, calendar: cal)
        _ = await engine.runRollups()                 // dailies + weeklies, no monthly yet

        clock.set(date(2026, 5, 2, 12))               // March (and April) are now closed
        let later = await engine.runRollups()
        #expect(later.monthlyCreated == 1)            // March: rolls up the 2 March weeklies
        #expect(later.dailyCreated == 0)              // no events in the new closed days
        #expect(later.weeklyCreated == 0)
        let monthlies = await summaries.allRollups().filter { $0.tier == .monthly }
        #expect(monthlies.count == 1)
        let weeklyIDs = Set(await summaries.allRollups().filter { $0.tier == .weekly }.map(\.id))
        #expect(Set(monthlies[0].childSummaryIDs) == weeklyIDs)
    }

    @Test("Empty memory → an empty run")
    func emptyMemory() async {
        let engine = SummaryEngine(memory: InMemoryMemoryStore(), summaries: InMemorySummaryStore(),
                                   model: StubGemmaService(), clock: FixedClock(date(2026, 3, 16, 12)), calendar: cal)
        let run = await engine.runRollups()
        #expect(run.total == 0)
    }

    @Test("Works the same with the SQLite-backed summary store")
    func withSQLiteSummaryStore() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mnemo-summary-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let memory = await loadedMemory()
        let summaries = try SQLiteSummaryStore(directory: dir)
        let engine = SummaryEngine(memory: memory, summaries: summaries, model: StubGemmaService(),
                                   clock: FixedClock(date(2026, 3, 16, 12)), calendar: cal)
        let run = await engine.runRollups()
        #expect(run.dailyCreated == 3)
        #expect(run.weeklyCreated == 2)
        // Reopen the summary store — the rollups persisted.
        let reopened = try SQLiteSummaryStore(directory: dir)
        #expect(await reopened.allDaily().count == 3)
        #expect(await reopened.allRollups().filter { $0.tier == .weekly }.count == 2)
    }
}
