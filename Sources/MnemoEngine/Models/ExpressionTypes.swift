// Who the user is, and what forms they can receive. Drives the ExpressionRouter.
// Privacy defaults are conservative by design (critic-loop §10): textOnly raw
// retention, a finite prune window.

import Foundation

public enum ExpressionModality: String, Codable, Sendable, CaseIterable, Equatable {
    case voice        // TTS reads it (primary for blind / low-vision)
    case sound        // non-speech earcons
    case screen       // a rich card with citations + timeline (primary for deaf / HoH; the default rich view)
    case haptic       // Taptic patterns (primary layer for deaf-blind; the silent channel)
    case largeType    // high-contrast, large-text screen mode
    case simplified   // plain-language, short-sentence rendering (cognitive accessibility) — composes with a visual/audio channel
}

/// An accessibility need maps to a *required* set of modalities the router may
/// never suppress (a blind user always gets a non-visual channel; a deaf user
/// always gets a non-audio channel).
public enum AccessibilityNeed: Codable, Sendable, Equatable, Hashable {
    case visionImpaired(severity: Severity)   // requires a non-visual channel: voice and/or haptic
    case hearingImpaired(severity: Severity)  // requires a non-audio channel: screen and/or haptic
    case motorImpaired                        // affects input, not output modality requirements
    case cognitiveLoad                        // requires `simplified` to be in the set

    public enum Severity: Int, Codable, Sendable, Comparable {
        case mild = 0, moderate = 1, severe = 2
        public static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
    }

    /// The modalities this need makes mandatory in the routing decision.
    /// (`screen` and `voice` are not *forbidden* by an impairment — only the
    ///  opposing sense is downgraded — but at least one channel from the
    ///  required set must be present and unsuppressed.)
    public var requiredModalitySet: Set<ExpressionModality> {
        switch self {
        case .visionImpaired:  return [.voice, .haptic]   // at least one of these must survive
        case .hearingImpaired: return [.screen, .haptic]  // at least one of these must survive
        case .motorImpaired:   return []
        case .cognitiveLoad:   return [.simplified]
        }
    }
}

public enum RawRetentionPolicy: Codable, Sendable, Equatable {
    case textOnly                       // DEFAULT — no raw images/audio kept
    case keepRaw                        // explicit opt-in
    case keepRawForDays(Int)            // keep raw for N days, then drop the blob (text survives)
}

public struct UserProfile: Sendable, Equatable {
    public var primaryModality: ExpressionModality
    public var additionalModalities: [ExpressionModality]   // fire alongside the primary
    public var accessibility: [AccessibilityNeed]           // sets the *required* modality floor
    public var quietHours: [DateInterval]                   // no voice/sound; haptic+screen only
    public var alertThreshold: Urgency                      // unprompted surfacings below this are suppressed
    public var locale: Locale                               // TTS voice, plain-language pass, Gemma output
    public var rawRetention: RawRetentionPolicy             // DEFAULT .textOnly
    public var pruneAfterDays: Int?                         // DEFAULT 30 — raw older than this gets pruned (summaries remain); nil = never auto-prune (not recommended)

    public init(
        primaryModality: ExpressionModality = .screen,
        additionalModalities: [ExpressionModality] = [],
        accessibility: [AccessibilityNeed] = [],
        quietHours: [DateInterval] = [],
        alertThreshold: Urgency = .attention,
        locale: Locale = .current,
        rawRetention: RawRetentionPolicy = .textOnly,
        pruneAfterDays: Int? = 30
    ) {
        self.primaryModality = primaryModality
        self.additionalModalities = additionalModalities
        self.accessibility = accessibility
        self.quietHours = quietHours
        self.alertThreshold = alertThreshold
        self.locale = locale
        self.rawRetention = rawRetention
        self.pruneAfterDays = pruneAfterDays
    }

    /// The union of all accessibility-driven required modality sets. Each
    /// element of `accessibility` contributes a set from which *at least one*
    /// modality must appear unsuppressed in the routing decision.
    public var accessibilityRequiredSets: [Set<ExpressionModality>] {
        accessibility.map { $0.requiredModalitySet }.filter { !$0.isEmpty }
    }
}
