// What each adapter emits — plain values. The *app* performs the side effects
// (runs the TTS, plays the haptic, renders the card). This keeps every adapter
// pure and Phase-1-testable. (Critic-loop §10.)

import Foundation

/// TTS instructions. `rate`/`pitch` are modulated by confidence/urgency.
public struct VoicePlan: Sendable, Equatable {
    public var text: String
    public var rate: Double          // 0.5...1.5 (1.0 = normal)
    public var pitch: Double         // 0.8...1.2 (1.0 = normal)
    public var locale: Locale
    public init(text: String, rate: Double = 1.0, pitch: Double = 1.0, locale: Locale = .current) {
        self.text = text; self.rate = rate; self.pitch = pitch; self.locale = locale
    }
}

public enum Earcon: String, Sendable, Equatable {
    case found          // a rising chime
    case notFound       // a soft descending tone
    case attention      // a single soft pulse
    case urgent         // a triple pulse
    case deferred       // a neutral two-note "see a human"
}

public struct EarconPlan: Sendable, Equatable {
    public var earcon: Earcon
    public init(_ earcon: Earcon) { self.earcon = earcon }
}

/// A timeline mark the screen card can offer ("jump to this moment").
public struct TimelineMark: Sendable, Equatable {
    public var eventID: UUID
    public var timestamp: Date
    public init(eventID: UUID, timestamp: Date) { self.eventID = eventID; self.timestamp = timestamp }
}

public struct ScreenPresentation: Sendable, Equatable {
    public var headline: String?            // e.g. the human-referral line, if deferred
    public var answerText: String
    public var citations: [CitationRef]     // tapping degrades per `availability`
    public var timeline: [TimelineMark]
    public var hedged: Bool                 // true when confidence was low — the UI shows a "I'm not certain" affordance
    public init(headline: String? = nil, answerText: String, citations: [CitationRef] = [],
                timeline: [TimelineMark] = [], hedged: Bool = false) {
        self.headline = headline; self.answerText = answerText
        self.citations = citations; self.timeline = timeline; self.hedged = hedged
    }
}

public enum HapticPatternKind: String, Sendable, Equatable {
    case yesFound        // a double-tap
    case noNotFound      // a single short buzz
    case attention       // a long buzz
    case urgent          // an escalating buzz
    case ambient         // a slow pulse
}

public struct HapticPattern: Sendable, Equatable {
    public var kind: HapticPatternKind
    public init(_ kind: HapticPatternKind) { self.kind = kind }
}

public struct LargeTypePresentation: Sendable, Equatable {
    public var text: String
    public var scale: Double         // type-size multiplier, e.g. 1.5...3.0
    public var highContrast: Bool
    public init(text: String, scale: Double = 2.0, highContrast: Bool = true) {
        self.text = text; self.scale = scale; self.highContrast = highContrast
    }
}

/// The SimplifiedAdapter doesn't simplify — it *asks* for a simplification.
/// The app runs the Gemma plain-language pass and feeds the result back into
/// whatever visual/audio channel is also active. (Phase 1: no real pass.)
public struct SimplificationRequest: Sendable, Equatable {
    public var sourceText: String
    public var targetReadingLevel: Int      // ~ a US grade level; lower = simpler
    public init(sourceText: String, targetReadingLevel: Int = 5) {
        self.sourceText = sourceText; self.targetReadingLevel = targetReadingLevel
    }
}

/// The tagged union of all adapter outputs.
public enum ExpressionPlan: Sendable, Equatable {
    case voice(VoicePlan)
    case sound(EarconPlan)
    case screen(ScreenPresentation)
    case haptic(HapticPattern)
    case largeType(LargeTypePresentation)
    case simplified(SimplificationRequest)

    public var modality: ExpressionModality {
        switch self {
        case .voice: return .voice
        case .sound: return .sound
        case .screen: return .screen
        case .haptic: return .haptic
        case .largeType: return .largeType
        case .simplified: return .simplified
        }
    }
}

public enum SuppressionReason: String, Sendable, Equatable {
    case quietHours
    case belowAlertThreshold
    case narrowedBySuggestion
    case notInProfile
}

/// The router's decision — a value, not "calls adapters".
public struct RoutingDecision: Sendable, Equatable {
    public var modalities: [ExpressionModality]                 // the channels that will fire, in order
    public var plans: [ExpressionPlan]                          // what each emits
    public var suppressed: [(ExpressionModality, SuppressionReason)]

    public init(modalities: [ExpressionModality], plans: [ExpressionPlan],
                suppressed: [(ExpressionModality, SuppressionReason)] = []) {
        self.modalities = modalities; self.plans = plans; self.suppressed = suppressed
    }

    // `(ExpressionModality, SuppressionReason)` tuples aren't Equatable for free.
    public static func == (a: RoutingDecision, b: RoutingDecision) -> Bool {
        a.modalities == b.modalities && a.plans == b.plans &&
        a.suppressed.count == b.suppressed.count &&
        zip(a.suppressed, b.suppressed).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
    }
}
