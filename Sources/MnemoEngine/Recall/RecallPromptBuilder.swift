// Assembles the strings the on-device model is asked to complete. Pure: given
// the (already-budgeted) context the `RecallEngine`/`SummaryEngine` produced, it
// renders a prompt. The model's reply goes back through `FunctionCallParser`.
// Phase 3 — paired with `GemmaReasoningOverFunctionCalls`, this is everything
// between "we retrieved the events" and "the model spoke" that isn't MLX.
//
// The recall prompt is deliberately a *narrow* tool surface: the engine already
// ran retrieval/budgeting (the contract's `recall_events` / `summarize_period` /
// `find_entity_mentions` are "done"), so the model is asked to either ANSWER
// from the supplied context (a small answer-JSON) or, for advice/emergency,
// emit the contract's `flag_for_human` call. (`set_reminder` is surfaced too —
// the model may schedule a follow-up.) Recall, don't advise.

import Foundation

public struct RecallPromptBuilder: Sendable {
    /// Prepended to the recall prompt. Defaults to a compact statement of
    /// Mnemo's role + the recall-don't-advise rule. Override to localize / lock
    /// a tone (as He Was Socrates does with its verbatim Korean system prompt).
    public var systemPreamble: String

    public init(systemPreamble: String = RecallPromptBuilder.defaultPreamble) {
        self.systemPreamble = systemPreamble
    }

    public static let defaultPreamble = """
        You are Mnemo. You answer questions about the user's own recorded life — \
        what was on their screen, what was said near them, what they copied, the \
        documents they scanned, the moments they marked "remember this". You \
        recall, surface, summarize, and remind. You do NOT advise on health, \
        money, the law, or immigration, and you do NOT handle emergencies — those \
        go to a human. Everything here is on the user's device.
        """

    // MARK: recall

    public func recallPrompt(
        query: String,
        contextEvents: [CaptureEvent],
        contextSummaries: [DailySummary],
        locale: Locale = .current,
        nowDescription: String? = nil
    ) -> String {
        var lines: [String] = [systemPreamble, ""]
        lines.append("Reply language: \(locale.identifier).")
        if let now = nowDescription { lines.append("Now: \(now).") }
        lines.append("")

        if contextEvents.isEmpty && contextSummaries.isEmpty {
            lines.append("(No recorded events match this question.)")
        } else {
            if !contextEvents.isEmpty {
                lines.append("Recorded events (most relevant first):")
                for (i, e) in contextEvents.enumerated() {
                    lines.append("[\(i + 1)] \(Self.iso(e.timestamp)) · \(e.source.rawValue) — \(Self.snippet(e.text, 240))")
                }
            }
            if !contextSummaries.isEmpty {
                lines.append("")
                lines.append("Period summaries:")
                for (i, s) in contextSummaries.enumerated() {
                    lines.append("(S\(i + 1)) \(Self.iso(s.date.start))–\(Self.iso(s.date.end)) — \(Self.snippet(s.summary, 320))")
                }
            }
        }

        lines.append("")
        lines.append("The user asks: \"\(query)\"")
        lines.append("")
        lines.append(
            """
            Use ONLY the events/summaries above. Cite events by their [index].

            • If this asks for medical, legal, financial, or immigration advice, or is an emergency, do NOT answer. Emit exactly:
              {"name":"flag_for_human","arguments":{"reason":"<one short clause>","resource_class":"<e.g. 'a doctor' / 'a lawyer'>"}}
            • If the user is asking you to remember/schedule something for later, you may emit:
              {"name":"set_reminder","arguments":{"when":"<ISO-8601>","what":"<text>","surface_modality":"<voice|sound|screen|haptic|largeType|simplified|null>"}}
            • Otherwise emit exactly one JSON object and nothing else:
              {"answer":"<the answer, in the reply language>","cited":[<event indices>],"confidence":<0.0–1.0>}
            """
        )
        return lines.joined(separator: "\n")
    }

    // MARK: simplify

    public func simplifyPrompt(_ text: String, toReadingLevel level: Int, locale: Locale = .current) -> String {
        """
        Rewrite the text below in plain \(locale.identifier) at roughly a grade-\(level) reading level: \
        short sentences, common words, no parentheticals, keep every fact. Output only the rewritten text.

        ---
        \(text)
        ---
        """
    }

    // MARK: summaries

    public func summarizeDayPrompt(
        events: [CaptureEvent], dayBucket: DateInterval, locale: Locale = .current
    ) -> String {
        let body = events
            .sorted { $0.timestamp < $1.timestamp }
            .map { "- \(Self.iso($0.timestamp)) · \($0.source.rawValue): \(Self.snippet($0.text, 200))" }
            .joined(separator: "\n")
        return """
            Summarize this one day of the user's recorded life in 1–3 sentences, in \(locale.identifier). \
            Name what mattered; don't list everything. Output only the summary.

            Day: \(Self.iso(dayBucket.start))–\(Self.iso(dayBucket.end))
            \(body)
            """
    }

    public func summarizeRollupPrompt(
        tier: SummaryTier, span: DateInterval, childSummaries: [String], locale: Locale = .current
    ) -> String {
        let body = childSummaries.enumerated()
            .map { "- (\($0.offset + 1)) \(Self.snippet($0.element, 280))" }
            .joined(separator: "\n")
        let unit = ["day", "week", "month", "year"][min(tier.rawValue, 3)]
        return """
            Combine these \(unit)-level summaries into one \(["daily", "weekly", "monthly", "yearly"][min(tier.rawValue, 3)]) \
            summary (2–4 sentences) in \(locale.identifier): the through-line, the things worth remembering a long time. \
            Output only the summary.

            Span: \(Self.iso(span.start))–\(Self.iso(span.end))
            \(body)
            """
    }

    // MARK: helpers

    static func iso(_ d: Date) -> String { ISO8601DateFormatter().string(from: d) }
    static func snippet(_ s: String, _ max: Int) -> String {
        let t = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return t.count > max ? String(t.prefix(max - 1)) + "…" : t
    }
}
