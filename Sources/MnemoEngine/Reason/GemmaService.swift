// The on-device model that reasons over retrieved memory. Phase 1 ships only
// `.stub` (deterministic, canned-style synthesis from the retrieved events) so
// the whole pipeline runs without a 2.5 GB model download. Phase 3 wires
// `.real` (Gemma 4 E4B-it 4-bit via mlx-swift-lm — confirm the HF repo id and
// the `mlx-swift-lm` registry key at wiring time, per critic-loop §10).
//
// The recall path uses native function calling (recall_events / summarize_period
// / find_entity_mentions / set_reminder / flag_for_human) — see
// RecallFunctionContract. The stub returns a structured `GemmaRecallOutput`
// directly; the real service would parse the model's function-call output.

import Foundation

/// What the model produces for a recall turn (after function-call parsing).
public struct GemmaRecallOutput: Sendable, Equatable {
    public var answerText: String
    public var citedEventIDs: [UUID]
    public var confidence: Double
    public var urgency: Urgency
    public var suggestedModality: [ExpressionModality]?
    public init(answerText: String, citedEventIDs: [UUID] = [], confidence: Double = 1.0,
                urgency: Urgency = .normal, suggestedModality: [ExpressionModality]? = nil) {
        self.answerText = answerText; self.citedEventIDs = citedEventIDs
        self.confidence = confidence; self.urgency = urgency; self.suggestedModality = suggestedModality
    }
}

public protocol GemmaReasoning: Sendable {
    /// Given the query and the assembled context (recent raw events + summary
    /// scaffold, already budgeted to fit 128K), produce a recall answer.
    func recall(query: String, contextEvents: [CaptureEvent], contextSummaries: [DailySummary]) async -> GemmaRecallOutput

    /// Re-render text at a target reading level (the SimplifiedAdapter asks for
    /// this; the *app* would call it — Phase 1 stub is near-passthrough).
    func simplify(_ text: String, toReadingLevel level: Int) async -> String
}

public struct StubGemmaService: GemmaReasoning {
    public init() {}

    public func recall(query: String, contextEvents: [CaptureEvent], contextSummaries: [DailySummary]) async -> GemmaRecallOutput {
        guard !contextEvents.isEmpty || !contextSummaries.isEmpty else {
            return GemmaRecallOutput(
                answerText: "I don't have anything recorded that answers that.",
                confidence: 0.2, urgency: .ambient
            )
        }
        // Deterministic "synthesis": echo the most relevant event(s) with their times.
        let top = Array(contextEvents.prefix(3))
        let lines = top.map { e -> String in
            let d = ISO8601DateFormatter().string(from: e.timestamp)
            let snippet = e.text.count > 160 ? String(e.text.prefix(157)) + "…" : e.text
            return "• \(d): \(snippet)"
        }
        let body = lines.isEmpty
            ? (contextSummaries.first.map { "Around then: \($0.summary)" } ?? "")
            : lines.joined(separator: "\n")
        let answer = "Here's what I have for “\(query)”:\n\(body)"
        // Confidence ~ how strong the top retrieval looked (the stub has no
        // scores here, so use count as a crude proxy).
        let conf = min(1.0, 0.4 + 0.2 * Double(top.count))
        return GemmaRecallOutput(
            answerText: answer,
            citedEventIDs: top.map(\.id),
            confidence: conf,
            urgency: .normal
        )
    }

    public func simplify(_ text: String, toReadingLevel level: Int) async -> String {
        // Stub: keep first sentence per line, strip parentheticals — a crude
        // stand-in for a real plain-language pass.
        text.split(separator: "\n").map { line -> String in
            let firstSentence = line.split(separator: ".").first.map(String.init) ?? String(line)
            return firstSentence.replacingOccurrences(of: #"\([^)]*\)"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
        }.joined(separator: "\n")
    }
}
