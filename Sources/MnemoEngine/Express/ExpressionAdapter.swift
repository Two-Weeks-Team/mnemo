// One adapter per modality. Each turns a `RecallResult` into an `ExpressionPlan`
// value; the app performs the side effect. Pure → testable. (Critic-loop §10.)

import Foundation

public protocol ExpressionAdapter: Sendable {
    var modality: ExpressionModality { get }
    func render(_ result: RecallResult, profile: UserProfile) -> ExpressionPlan
}

public struct VoiceAdapter: ExpressionAdapter {
    public init() {}
    public var modality: ExpressionModality { .voice }
    public func render(_ result: RecallResult, profile: UserProfile) -> ExpressionPlan {
        // Hedge with a slower rate when confidence is low; quicken slightly when urgent.
        var rate = 1.0
        if result.confidence < 0.4 { rate = 0.9 }
        if result.urgency == .urgent { rate = 1.1 }
        let prefix = result.confidence < 0.4 ? "I'm not certain, but — " : ""
        let body = result.deferredToHuman?.reason ?? (prefix + result.answerText)
        return .voice(VoicePlan(text: body, rate: rate, pitch: result.urgency == .urgent ? 1.05 : 1.0,
                                locale: profile.locale))
    }
}

public struct SoundAdapter: ExpressionAdapter {
    public init() {}
    public var modality: ExpressionModality { .sound }
    public func render(_ result: RecallResult, profile: UserProfile) -> ExpressionPlan {
        let e: Earcon
        if result.deferredToHuman != nil { e = .deferred }
        else if result.urgency == .urgent { e = .urgent }
        else if result.urgency == .attention { e = .attention }
        else if result.confidence < 0.3 { e = .notFound }
        else { e = .found }
        return .sound(EarconPlan(e))
    }
}

public struct ScreenAdapter: ExpressionAdapter {
    public init() {}
    public var modality: ExpressionModality { .screen }
    public func render(_ result: RecallResult, profile: UserProfile) -> ExpressionPlan {
        let timeline = result.citations.map { TimelineMark(eventID: $0.eventID, timestamp: $0.timestamp) }
        return .screen(ScreenPresentation(
            headline: result.deferredToHuman?.reason,
            answerText: result.deferredToHuman == nil ? result.answerText : "See \(result.deferredToHuman!.resourceClass).",
            citations: result.citations,
            timeline: timeline,
            hedged: result.confidence < 0.4
        ))
    }
}

public struct HapticAdapter: ExpressionAdapter {
    public init() {}
    public var modality: ExpressionModality { .haptic }
    public func render(_ result: RecallResult, profile: UserProfile) -> ExpressionPlan {
        let k: HapticPatternKind
        if result.deferredToHuman != nil { k = .attention }
        else if result.urgency == .urgent { k = .urgent }
        else if result.urgency == .attention { k = .attention }
        else if result.confidence < 0.3 { k = .noNotFound }
        else { k = .yesFound }
        return .haptic(HapticPattern(k))
    }
}

public struct LargeTypeAdapter: ExpressionAdapter {
    public init() {}
    public var modality: ExpressionModality { .largeType }
    public func render(_ result: RecallResult, profile: UserProfile) -> ExpressionPlan {
        let body = result.deferredToHuman?.reason ?? result.answerText
        return .largeType(LargeTypePresentation(text: body, scale: 2.2, highContrast: true))
    }
}

public struct SimplifiedAdapter: ExpressionAdapter {
    public init() {}
    public var modality: ExpressionModality { .simplified }
    public func render(_ result: RecallResult, profile: UserProfile) -> ExpressionPlan {
        let src = result.deferredToHuman?.reason ?? result.answerText
        return .simplified(SimplificationRequest(sourceText: src, targetReadingLevel: 5))
    }
}

/// The default set of adapters, keyed by modality.
public enum DefaultAdapters {
    public static let all: [ExpressionModality: any ExpressionAdapter] = [
        .voice: VoiceAdapter(),
        .sound: SoundAdapter(),
        .screen: ScreenAdapter(),
        .haptic: HapticAdapter(),
        .largeType: LargeTypeAdapter(),
        .simplified: SimplifiedAdapter(),
    ]
}
