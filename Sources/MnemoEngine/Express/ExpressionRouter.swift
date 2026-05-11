// The adaptive heart. Given a RecallResult + the UserProfile + the time (for
// quiet hours) + an optional per-query modality override, decide which channels
// fire. The precedence is an explicit ordered lattice (critic-loop §10):
//
//   1. accessibility-required modalities — every accessibility need contributes
//      a set from which AT LEAST ONE modality must survive in the decision;
//      these can never be fully suppressed or narrowed away.
//   2. profile modalities — primary + additional.
//   3. per-query override — narrows to that modality FOR THIS QUERY, but cannot
//      remove an accessibility-required channel (so "show me" from a blind user
//      adds screen, doesn't drop voice).
//   4. urgency escalation — urgency == .urgent adds all available modalities,
//      subject to step 5.
//   5. quiet-hours suppression — during quiet hours, voice & sound are
//      suppressed (haptic + screen survive). An urgent item in quiet hours =
//      haptic + screen, never voice/sound.
//   6. suggestedModality narrowing — result.suggestedModality may only NARROW
//      within the already-permitted set; it can never add, never empty an
//      accessibility-required or query-overridden channel.
//   7. alert-threshold suppression — for UNPROMPTED surfacings only: if
//      result.urgency < profile.alertThreshold, the whole thing is suppressed
//      (logged, not surfaced).
//
// Output is a `RoutingDecision` value (which channels, what each emits, what was
// suppressed and why). The adapters are pure; the *app* performs side effects.

import Foundation

public struct ExpressionRouter: Sendable {
    private let adapters: [ExpressionModality: any ExpressionAdapter]
    private let clock: any TimeProvider

    public init(adapters: [ExpressionModality: any ExpressionAdapter] = DefaultAdapters.all,
                clock: any TimeProvider = SystemClock()) {
        self.adapters = adapters
        self.clock = clock
    }

    public func route(_ result: RecallResult, profile: UserProfile, query: RecallQuery) -> RoutingDecision {
        var suppressed: [(ExpressionModality, SuppressionReason)] = []
        let now = clock.now()
        let inQuietHours = profile.quietHours.contains { $0.contains(now) }

        // --- step 7 (checked first because if it fires, nothing surfaces) ---
        if query.isProactive && result.urgency < profile.alertThreshold {
            // Everything is suppressed.
            let all = Set(ExpressionModality.allCases)
            return RoutingDecision(
                modalities: [],
                plans: [],
                suppressed: all.sorted { $0.rawValue < $1.rawValue }.map { ($0, .belowAlertThreshold) }
            )
        }

        // --- step 1: accessibility-required channels (each need: at least one survives) ---
        // We'll seed `chosen` with the FIRST element of each required set (a
        // sensible default — the order in `requiredModalitySet` puts the
        // preferred channel first) and treat the whole set as "protected".
        var chosen = Set<ExpressionModality>()
        var protectedRequired = Set<ExpressionModality>()   // never suppress these once chosen
        var requiredOneOf: [Set<ExpressionModality>] = []
        for set in profile.accessibilityRequiredSets {
            requiredOneOf.append(set)
            if let first = ExpressionModality.allCases.first(where: { set.contains($0) }) {
                chosen.insert(first)
                protectedRequired.insert(first)
            }
        }

        // --- step 2: profile modalities ---
        chosen.insert(profile.primaryModality)
        for m in profile.additionalModalities { chosen.insert(m) }

        // --- step 3: per-query override (narrow to it, but keep protected) ---
        if let override = query.modalityOverride {
            // Narrow: keep only `override` + the protected accessibility channels.
            let dropped = chosen.subtracting(protectedRequired).subtracting([override])
            for m in dropped { suppressed.append((m, .notInProfile)) }   // narrowed by the user's "show me/tell me"
            chosen = protectedRequired.union([override])
        }

        // --- step 4: urgency escalation ---
        if result.urgency == .urgent {
            chosen = Set(ExpressionModality.allCases)   // all hands; step 5 will trim for quiet hours
        }

        // --- step 5: quiet-hours suppression (voice & sound off; haptic + screen survive) ---
        if inQuietHours {
            for m in [ExpressionModality.voice, .sound] where chosen.contains(m) {
                // ...unless this is the ONLY way to satisfy an accessibility need.
                let neededHere = requiredOneOf.contains { req in
                    req.contains(m) && req.intersection(chosen).subtracting([m]).isEmpty
                }
                if !neededHere {
                    chosen.remove(m)
                    suppressed.append((m, .quietHours))
                }
            }
        }

        // --- ensure every accessibility "one-of" set still has a survivor ---
        for req in requiredOneOf where req.intersection(chosen).isEmpty {
            if let revive = ExpressionModality.allCases.first(where: { req.contains($0) }) {
                chosen.insert(revive)
                protectedRequired.insert(revive)
                // un-suppress it if it was suppressed
                suppressed.removeAll { $0.0 == revive }
            }
        }

        // --- step 6: suggestedModality narrowing (may only narrow within `chosen`) ---
        if let suggested = result.suggestedModality, !suggested.isEmpty {
            let suggestedSet = Set(suggested)
            let keep = chosen.intersection(suggestedSet).union(protectedRequired)
            // Only narrow if doing so leaves a non-empty, accessibility-valid set.
            let validAfterNarrow = !keep.isEmpty && requiredOneOf.allSatisfy { !$0.intersection(keep).isEmpty }
            if validAfterNarrow {
                let dropped = chosen.subtracting(keep)
                for m in dropped { suppressed.append((m, .narrowedBySuggestion)) }
                chosen = keep
            }
        }

        // If somehow nothing is chosen (shouldn't happen given step 2), fall back to screen.
        if chosen.isEmpty { chosen = [.screen] }

        // Stable, sensible firing order.
        let order: [ExpressionModality] = [.screen, .voice, .haptic, .sound, .largeType, .simplified]
        let modalities = order.filter { chosen.contains($0) }
        let plans = modalities.compactMap { m -> ExpressionPlan? in
            adapters[m]?.render(result, profile: profile)
        }
        // De-dup suppressed list (a modality might have been added back).
        var seen = Set<ExpressionModality>()
        let suppressedFinal = suppressed.filter { entry in
            if chosen.contains(entry.0) { return false }      // not actually suppressed
            if seen.contains(entry.0) { return false }
            seen.insert(entry.0); return true
        }
        return RoutingDecision(modalities: modalities, plans: plans, suppressed: suppressedFinal)
    }
}
