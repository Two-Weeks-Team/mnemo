// The rollup job (Phase 2). Runs on idle/charging. Walks CLOSED buckets only —
// a day/week/month/year whose end is in the past — and writes a summary for any
// bucket that doesn't yet have one (the model does the prose; this owns the
// envelope and the child links). It NEVER mutates a CaptureEvent — old detail
// degrades by being *summarised alongside*, not edited. Idempotent: a second
// run with no new closed buckets does nothing.
//
// Bucket boundaries use the ISO-8601 calendar in UTC (matching the dedup
// fingerprint's day-bucketing). Bucket query intervals are the true
// [start, nextStart] ranges; an event whose timestamp is *exactly* a bucket
// boundary (microsecond-precise) would be counted in two buckets — captured
// timestamps don't land there in practice, and a duplicate mention in a summary
// is harmless.

import Foundation

public struct RollupRun: Sendable, Equatable {
    public var dailyCreated: Int = 0
    public var weeklyCreated: Int = 0
    public var monthlyCreated: Int = 0
    public var yearlyCreated: Int = 0
    public var total: Int { dailyCreated + weeklyCreated + monthlyCreated + yearlyCreated }
}

public actor SummaryEngine {
    private let memory: any MemoryStore
    private let summaries: any SummaryStore
    private let model: any GemmaReasoning
    private let clock: any TimeProvider
    private let calendar: Calendar

    public init(
        memory: any MemoryStore,
        summaries: any SummaryStore,
        model: any GemmaReasoning,
        clock: any TimeProvider = SystemClock(),
        calendar: Calendar = SummaryEngine.utcISOCalendar
    ) {
        self.memory = memory
        self.summaries = summaries
        self.model = model
        self.clock = clock
        self.calendar = calendar
    }

    public static var utcISOCalendar: Calendar {
        var c = Calendar(identifier: .iso8601)
        c.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return c
    }

    /// Roll up every closed day without a daily summary, then build any
    /// newly-completable weekly → monthly → yearly rollups. Returns the count
    /// created at each tier.
    @discardableResult
    public func runRollups() async -> RollupRun {
        let now = clock.now()
        guard let earliest = await memory.allEvents().last?.timestamp else { return RollupRun() }

        var run = RollupRun()
        run.dailyCreated = await rollDays(from: earliest, now: now)
        run.weeklyCreated = await rollTier(.weekly, component: .weekOfYear, from: earliest, now: now)
        run.monthlyCreated = await rollTier(.monthly, component: .month, from: earliest, now: now)
        run.yearlyCreated = await rollTier(.yearly, component: .year, from: earliest, now: now)
        return run
    }

    // MARK: daily

    private func rollDays(from earliest: Date, now: Date) async -> Int {
        var created = 0
        var dayStart = calendar.startOfDay(for: earliest)
        while let nextStart = calendar.date(byAdding: .day, value: 1, to: dayStart), nextStart <= now {
            defer { dayStart = nextStart }
            if await summaries.hasDaily(forDayStarting: dayStart) { continue }
            let bucket = DateInterval(start: dayStart, end: nextStart)
            let events = await memory.events(in: bucket)
            guard !events.isEmpty else { continue }   // no summary for an empty day
            let out = await model.summarizeDay(events: events, dayBucket: bucket)
            await summaries.upsertDaily(
                DailySummary(date: bucket, summary: out.summary,
                             keyEventIDs: out.keyEventIDs, entities: out.entities)
            )
            created += 1
        }
        return created
    }

    // MARK: weekly / monthly / yearly

    /// Roll up one higher tier. Its children: for `.weekly`, the daily summaries
    /// in the week; for `.monthly`, the weekly rollups starting in the month;
    /// for `.yearly`, the monthly rollups starting in the year.
    private func rollTier(
        _ tier: SummaryTier, component: Calendar.Component, from earliest: Date, now: Date
    ) async -> Int {
        var created = 0
        guard var span = calendar.dateInterval(of: component, for: earliest) else { return 0 }
        while span.end <= now {
            if !(await summaries.hasRollup(tier: tier, spanStarting: span.start)) {
                let (childTexts, childEntities, childIDs) = await children(for: tier, in: span)
                if !childTexts.isEmpty {   // skip a bucket with nothing under it
                    let out = await model.summarizeRollup(
                        tier: tier, span: span, childSummaries: childTexts, childEntities: childEntities
                    )
                    await summaries.upsertRollup(
                        RollupSummary(tier: tier, span: span, summary: out.summary,
                                      childSummaryIDs: childIDs, entities: out.entities)
                    )
                    created += 1
                }
            }
            // Advance to the next bucket; bail if the calendar can't (never, in practice).
            guard let next = calendar.date(byAdding: component, value: 1, to: span.start),
                let nextSpan = calendar.dateInterval(of: component, for: next),
                nextSpan.start > span.start
            else { break }
            span = nextSpan
        }
        return created
    }

    private func children(
        for tier: SummaryTier, in span: DateInterval
    ) async -> (texts: [String], entities: [EntityMention], ids: [UUID]) {
        switch tier {
        case .weekly:
            let kids = await summaries.daily(in: span)
            return (kids.map(\.summary), kids.flatMap(\.entities), kids.map(\.id))
        case .monthly:
            let kids = await summaries.rollups(tier: .weekly, in: span)
            return (kids.map(\.summary), kids.flatMap(\.entities), kids.map(\.id))
        case .yearly:
            let kids = await summaries.rollups(tier: .monthly, in: span)
            return (kids.map(\.summary), kids.flatMap(\.entities), kids.map(\.id))
        case .daily:
            return ([], [], [])  // daily is handled by rollDays, not here
        }
    }
}
