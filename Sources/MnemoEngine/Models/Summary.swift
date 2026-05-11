// Graceful memory. Raw events roll up into daily → weekly → monthly → yearly
// summaries (Gemma summarizes; the SummaryEngine runs on idle/charging, only on
// CLOSED day-buckets, never mutating an event in place). Old detail degrades
// instead of vanishing — a year-old day is still recallable as "that week you
// were moving apartments." The yearly tier keeps the summary scaffold bounded
// for a 5-year user. (Critic-loop §10.) Phase 1 defines the types; the
// SummaryEngine is Phase 2.

import Foundation

public enum SummaryTier: Int, Codable, Sendable, Comparable {
    case daily = 0, weekly = 1, monthly = 2, yearly = 3
    public static func < (a: SummaryTier, b: SummaryTier) -> Bool { a.rawValue < b.rawValue }
}

public struct DailySummary: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let date: DateInterval        // the closed day-bucket
    public var summary: String
    public var keyEventIDs: [UUID]
    public var entities: [EntityMention]
    public init(id: UUID = UUID(), date: DateInterval, summary: String,
                keyEventIDs: [UUID] = [], entities: [EntityMention] = []) {
        self.id = id; self.date = date; self.summary = summary
        self.keyEventIDs = keyEventIDs; self.entities = entities
    }
}

/// Weekly / monthly / yearly rollups share a shape (a span + a summary + the
/// child summaries that fed it).
public struct RollupSummary: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let tier: SummaryTier         // .weekly / .monthly / .yearly
    public let span: DateInterval
    public var summary: String
    public var childSummaryIDs: [UUID]
    public var entities: [EntityMention]
    public init(id: UUID = UUID(), tier: SummaryTier, span: DateInterval, summary: String,
                childSummaryIDs: [UUID] = [], entities: [EntityMention] = []) {
        self.id = id; self.tier = tier; self.span = span; self.summary = summary
        self.childSummaryIDs = childSummaryIDs; self.entities = entities
    }
}
