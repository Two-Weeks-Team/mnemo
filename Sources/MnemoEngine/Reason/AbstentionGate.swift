// "Recall, don't advise." Mnemo answers questions about your own recorded
// life. It does NOT give medical, legal, financial, or immigration advice —
// those route to a human (`flag_for_human`). This gate is a deterministic
// pre-check on the *query* (the model's own function-calling is a second line
// of defense, but a hard keyword gate makes the boundary legible and testable).
// (Critic-loop §10. Same idea as the He Was Socrates `defer_to_human`.)

import Foundation

public enum RegulatedDomain: String, Sendable, CaseIterable {
    case medical
    case legal
    case financial
    case immigration
    case emergency      // self-harm, harm to others, acute danger — route immediately

    public var resourceClass: String {
        switch self {
        case .medical:     return "a doctor"
        case .legal:       return "a lawyer"
        case .financial:   return "a financial professional"
        case .immigration: return "an immigration lawyer or accredited representative"
        case .emergency:   return "emergency services"
        }
    }
}

public struct AbstentionGate: Sendable {
    public init() {}

    /// Returns the regulated domain if the query is asking for advice in one,
    /// else nil. Conservative: it triggers on advice-seeking phrasing about a
    /// regulated topic, not on mere recall ("what did the doctor say last
    /// Tuesday?" is recall — fine; "should I take this medication?" is advice —
    /// abstain).
    public func evaluate(_ queryText: String) -> RegulatedDomain? {
        let q = queryText.lowercased()

        // Emergency markers fire regardless of phrasing.
        let emergencyMarkers = ["kill myself", "want to die", "suicide", "hurt myself",
                                "harm myself", "end my life", "overdose"]
        if emergencyMarkers.contains(where: { q.contains($0) }) { return .emergency }

        // Advice-seeking patterns: an advice cue + a domain cue, OR a strong
        // standalone advice phrase in a domain.
        let adviceCues = ["should i", "do i need to", "is it ok to", "is it safe to",
                          "what should i do about", "can i sue", "am i allowed to",
                          "what are my rights", "how do i file", "is this legal",
                          "should i take", "what's the right dose", "is this covered",
                          "should i invest", "should i sign", "will i be deported",
                          "diagnose", "what disease", "what's wrong with me"]
        let domains: [(RegulatedDomain, [String])] = [
            (.medical, ["medication", "dose", "symptom", "diagnos", "treatment", "prescription",
                        "side effect", "disease", "illness", "doctor", "medicine", "pill",
                        "blood pressure", "chest pain", "lump", "rash"]),
            (.legal, ["sue", "lawsuit", "lawyer", "court", "evict", "tenant rights", "contract",
                      "custody", "divorce", "criminal", "legal", "subpoena", "lease"]),
            (.financial, ["invest", "stock", "401k", "retirement fund", "loan", "mortgage rate",
                          "tax deduction", "should i buy", "should i sell", "bankruptcy",
                          "credit score", "interest rate"]),
            (.immigration, ["visa", "green card", "deport", "asylum", "citizenship", "i-9",
                            "uscis", "immigration status", "work permit"]),
        ]

        let hasAdviceCue = adviceCues.contains { q.contains($0) }
        for (domain, cues) in domains {
            let hasDomainCue = cues.contains { q.contains($0) }
            if hasDomainCue && hasAdviceCue { return domain }
        }
        // A few standalone "this is clearly advice-seeking" phrases.
        if q.contains("should i take") && domains[0].1.contains(where: { q.contains($0) }) { return .medical }
        if q.contains("should i sign") { return .legal }
        if q.contains("should i invest") { return .financial }
        if q.contains("will i be deported") { return .immigration }
        return nil
    }

    /// The referral to put in `RecallResult.deferredToHuman`.
    public func referral(for domain: RegulatedDomain) -> RecallResult.HumanReferral {
        let reason: String
        switch domain {
        case .emergency:
            reason = "This is beyond what I should answer — please contact emergency services or a crisis line right now."
        default:
            reason = "This isn't mine to answer — that's a question for \(domain.resourceClass)."
        }
        return .init(reason: reason, resourceClass: domain.resourceClass)
    }
}
