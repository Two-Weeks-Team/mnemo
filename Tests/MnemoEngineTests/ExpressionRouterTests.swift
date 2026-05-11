import Testing
import Foundation
@testable import MnemoEngine

/// The precedence lattice (critic-loop §10) is the heart of "adaptive
/// expression". These exhaust the rules.
@Suite("ExpressionRouter — precedence lattice")
struct ExpressionRouterTests {

    private func result(urgency: Urgency = .normal, confidence: Double = 1.0,
                        suggested: [ExpressionModality]? = nil,
                        deferred: RecallResult.HumanReferral? = nil) -> RecallResult {
        RecallResult(answerText: "x", confidence: confidence, urgency: urgency,
                     suggestedModality: suggested, deferredToHuman: deferred)
    }

    @Test("Step 2 — profile modalities fire")
    func profileModalities() {
        let router = ExpressionRouter(clock: FixedClock(Date()))
        let p = UserProfile(primaryModality: .screen, additionalModalities: [.haptic])
        let d = router.route(result(), profile: p, query: RecallQuery(text: "q"))
        #expect(Set(d.modalities) == Set([.screen, .haptic]))
    }

    @Test("Step 1 — a blind user always gets a non-visual channel, even if profile says screen")
    func accessibilityVisionFloor() {
        let router = ExpressionRouter(clock: FixedClock(Date()))
        let p = UserProfile(primaryModality: .screen,
                            accessibility: [.visionImpaired(severity: .severe)])
        let d = router.route(result(), profile: p, query: RecallQuery(text: "q"))
        // requiredModalitySet for vision = {voice, haptic} — at least one must survive.
        #expect(d.modalities.contains(.voice) || d.modalities.contains(.haptic))
    }

    @Test("Step 1 — a deaf user always gets a non-audio channel")
    func accessibilityHearingFloor() {
        let router = ExpressionRouter(clock: FixedClock(Date()))
        let p = UserProfile(primaryModality: .voice,
                            accessibility: [.hearingImpaired(severity: .severe)])
        let d = router.route(result(), profile: p, query: RecallQuery(text: "q"))
        #expect(d.modalities.contains(.screen) || d.modalities.contains(.haptic))
    }

    @Test("Step 1 — cognitiveLoad forces `simplified` into the set")
    func accessibilityCognitive() {
        let router = ExpressionRouter(clock: FixedClock(Date()))
        let p = UserProfile(primaryModality: .screen, accessibility: [.cognitiveLoad])
        let d = router.route(result(), profile: p, query: RecallQuery(text: "q"))
        #expect(d.modalities.contains(.simplified))
    }

    @Test("Step 3 — a per-query override narrows, but cannot remove an accessibility channel")
    func queryOverrideKeepsAccessibility() {
        let router = ExpressionRouter(clock: FixedClock(Date()))
        // A blind user (must keep voice/haptic) who says "show me" → adds screen, keeps voice.
        let p = UserProfile(primaryModality: .voice,
                            accessibility: [.visionImpaired(severity: .moderate)])
        let d = router.route(result(), profile: p,
                             query: RecallQuery(text: "q", modalityOverride: .screen))
        #expect(d.modalities.contains(.screen))
        #expect(d.modalities.contains(.voice))   // protected — not narrowed away
    }

    @Test("Step 3 — for a user with no accessibility floor, an override narrows to it")
    func queryOverrideNarrows() {
        let router = ExpressionRouter(clock: FixedClock(Date()))
        let p = UserProfile(primaryModality: .screen, additionalModalities: [.voice, .sound])
        let d = router.route(result(), profile: p,
                             query: RecallQuery(text: "q", modalityOverride: .voice))
        #expect(d.modalities == [.voice])
        #expect(d.suppressed.contains { $0.0 == .screen })
        #expect(d.suppressed.contains { $0.0 == .sound })
    }

    @Test("Step 4 — urgent fires all available channels")
    func urgencyEscalation() {
        let router = ExpressionRouter(clock: FixedClock(Date()))
        let p = UserProfile(primaryModality: .screen)
        let d = router.route(result(urgency: .urgent), profile: p, query: RecallQuery(text: "q"))
        #expect(Set(d.modalities) == Set(ExpressionModality.allCases))
    }

    @Test("Step 5 — in quiet hours, voice & sound are suppressed; haptic + screen survive")
    func quietHoursSuppression() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)   // arbitrary fixed instant
        let clock = FixedClock(now)
        let router = ExpressionRouter(clock: clock)
        let quiet = DateInterval(start: now.addingTimeInterval(-3600), duration: 7200)  // now is inside it
        let p = UserProfile(primaryModality: .voice, additionalModalities: [.sound, .haptic, .screen],
                            quietHours: [quiet])
        let d = router.route(result(), profile: p, query: RecallQuery(text: "q"))
        #expect(!d.modalities.contains(.voice))
        #expect(!d.modalities.contains(.sound))
        #expect(d.modalities.contains(.haptic) || d.modalities.contains(.screen))
        #expect(d.suppressed.contains { $0.0 == .voice && $0.1 == .quietHours })
    }

    @Test("Step 5 — an urgent item in quiet hours = haptic + screen, never voice/sound")
    func urgentInQuietHours() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = FixedClock(now)
        let router = ExpressionRouter(clock: clock)
        let quiet = DateInterval(start: now.addingTimeInterval(-3600), duration: 7200)
        let p = UserProfile(primaryModality: .screen, quietHours: [quiet])
        let d = router.route(result(urgency: .urgent), profile: p, query: RecallQuery(text: "q"))
        #expect(!d.modalities.contains(.voice))
        #expect(!d.modalities.contains(.sound))
        #expect(d.modalities.contains(.screen) || d.modalities.contains(.haptic))
    }

    @Test("Step 6 — suggestedModality may only NARROW within the permitted set")
    func suggestedNarrows() {
        let router = ExpressionRouter(clock: FixedClock(Date()))
        let p = UserProfile(primaryModality: .screen, additionalModalities: [.voice, .haptic])
        // suggest screen-only → narrows to screen.
        let d = router.route(result(suggested: [.screen]), profile: p, query: RecallQuery(text: "q"))
        #expect(d.modalities == [.screen])
        // suggest something NOT in the set (sound) → it cannot ADD; the set is unchanged.
        let d2 = router.route(result(suggested: [.sound]), profile: p, query: RecallQuery(text: "q"))
        #expect(!d2.modalities.contains(.sound))
    }

    @Test("Step 6 — suggestedModality cannot empty an accessibility-required channel")
    func suggestedCannotKillAccessibility() {
        let router = ExpressionRouter(clock: FixedClock(Date()))
        // Blind user; suggest screen-only — but voice/haptic must survive.
        let p = UserProfile(primaryModality: .voice, additionalModalities: [.screen],
                            accessibility: [.visionImpaired(severity: .severe)])
        let d = router.route(result(suggested: [.screen]), profile: p, query: RecallQuery(text: "q"))
        #expect(d.modalities.contains(.voice) || d.modalities.contains(.haptic))
    }

    @Test("Step 7 — an unprompted surfacing below the alert threshold is fully suppressed")
    func belowAlertThreshold() {
        let router = ExpressionRouter(clock: FixedClock(Date()))
        let p = UserProfile(primaryModality: .screen, alertThreshold: .attention)
        let d = router.route(result(urgency: .normal), profile: p,
                             query: RecallQuery(text: "q", isProactive: true))
        #expect(d.modalities.isEmpty)
        #expect(d.plans.isEmpty)
        #expect(d.suppressed.allSatisfy { $0.1 == .belowAlertThreshold })
    }

    @Test("Step 7 — a *prompted* query is never suppressed by the alert threshold")
    func promptedIgnoresThreshold() {
        let router = ExpressionRouter(clock: FixedClock(Date()))
        let p = UserProfile(primaryModality: .screen, alertThreshold: .urgent)
        let d = router.route(result(urgency: .ambient), profile: p,
                             query: RecallQuery(text: "q", isProactive: false))
        #expect(!d.modalities.isEmpty)
    }

    @Test("A deferred-to-human result still routes through the user's channels")
    func deferredRouting() {
        let router = ExpressionRouter(clock: FixedClock(Date()))
        let p = UserProfile(primaryModality: .voice)
        let ref = RecallResult.HumanReferral(reason: "see a doctor", resourceClass: "a doctor")
        let d = router.route(result(urgency: .attention, deferred: ref), profile: p, query: RecallQuery(text: "q"))
        #expect(d.modalities.contains(.voice))
        if case .voice(let plan)? = d.plans.first(where: { $0.modality == .voice }) {
            #expect(plan.text.contains("see a doctor"))
        } else { Issue.record("expected a voice plan") }
    }

    @Test("Low confidence → the voice plan slows and hedges; the screen plan is marked hedged")
    func lowConfidenceHedges() {
        let router = ExpressionRouter(clock: FixedClock(Date()))
        let p = UserProfile(primaryModality: .voice, additionalModalities: [.screen])
        let d = router.route(result(confidence: 0.2), profile: p, query: RecallQuery(text: "q"))
        if case .voice(let v)? = d.plans.first(where: { $0.modality == .voice }) {
            #expect(v.rate < 1.0)
            #expect(v.text.lowercased().contains("not certain"))
        } else { Issue.record("expected a voice plan") }
        if case .screen(let s)? = d.plans.first(where: { $0.modality == .screen }) {
            #expect(s.hedged)
        } else { Issue.record("expected a screen plan") }
    }
}
