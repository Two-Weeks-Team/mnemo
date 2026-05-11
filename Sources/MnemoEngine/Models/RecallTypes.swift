// What you ask, and what comes back. The recall result is modality-agnostic;
// the ExpressionRouter renders it. (Critic-loop §10: separate "what was found"
// from "how it's expressed".)

import Foundation

public struct RecallQuery: Sendable, Equatable {
    public var text: String
    public var timeRange: DateInterval?      // optional explicit scope
    public var isProactive: Bool             // true → an unprompted surfacing (subject to alertThreshold)
    public var modalityOverride: ExpressionModality?  // "show me" / "tell me" / "buzz me" for THIS query

    public init(
        text: String,
        timeRange: DateInterval? = nil,
        isProactive: Bool = false,
        modalityOverride: ExpressionModality? = nil
    ) {
        self.text = text; self.timeRange = timeRange
        self.isProactive = isProactive; self.modalityOverride = modalityOverride
    }
}

public enum Urgency: Int, Codable, Sendable, Comparable {
    case ambient = 0    // a soft signal at most
    case normal = 1
    case attention = 2  // worth a notice
    case urgent = 3     // fire every available channel (subject to quiet hours)

    public static func < (a: Urgency, b: Urgency) -> Bool { a.rawValue < b.rawValue }
}

/// A pointer back to a CaptureEvent that backs an answer, with the degradation
/// state recorded so the screen adapter can render "the original was pruned".
public struct CitationRef: Codable, Sendable, Equatable {
    public var eventID: UUID
    public var timestamp: Date
    public var snippet: String           // the bit of text that's cited
    public var availability: Availability

    public enum Availability: String, Codable, Sendable {
        case rawAndText      // the blob + the text both survive
        case textOnly        // the blob was pruned; the text survives
        case summaryOnly     // the text was pruned; only the summary that mentioned it survives
    }

    public init(eventID: UUID, timestamp: Date, snippet: String, availability: Availability) {
        self.eventID = eventID; self.timestamp = timestamp
        self.snippet = snippet; self.availability = availability
    }
}

public struct RecallResult: Sendable, Equatable {
    public var answerText: String
    public var citations: [CitationRef]
    public var confidence: Double            // 0...1 — low → the expression hedges
    public var urgency: Urgency
    public var suggestedModality: [ExpressionModality]?  // a hint; may only NARROW within what the profile permits
    public var deferredToHuman: HumanReferral?           // non-nil if the abstention gate fired

    public struct HumanReferral: Sendable, Equatable {
        public var reason: String
        public var resourceClass: String    // e.g. "doctor", "lawyer", "financial professional"
        public init(reason: String, resourceClass: String) {
            self.reason = reason; self.resourceClass = resourceClass
        }
    }

    public init(
        answerText: String,
        citations: [CitationRef] = [],
        confidence: Double = 1.0,
        urgency: Urgency = .normal,
        suggestedModality: [ExpressionModality]? = nil,
        deferredToHuman: HumanReferral? = nil
    ) {
        self.answerText = answerText
        self.citations = citations
        self.confidence = max(0, min(1, confidence))
        self.urgency = urgency
        self.suggestedModality = suggestedModality
        self.deferredToHuman = deferredToHuman
    }
}
