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

/// What the model produces when it rolls up a span of memory (a day's events,
/// or a set of child summaries). The SummaryEngine owns the child IDs and the
/// `id`/`tier`/`span` envelope; the model just supplies the prose + entities.
public struct GemmaSummaryOutput: Sendable, Equatable {
    public var summary: String
    public var keyEventIDs: [UUID]
    public var entities: [EntityMention]
    public init(summary: String, keyEventIDs: [UUID] = [], entities: [EntityMention] = []) {
        self.summary = summary; self.keyEventIDs = keyEventIDs; self.entities = entities
    }
}

public protocol GemmaReasoning: Sendable {
    /// Given the query and the assembled context (recent raw events + summary
    /// scaffold, already budgeted to fit 128K), produce a recall answer.
    func recall(query: String, contextEvents: [CaptureEvent], contextSummaries: [DailySummary]) async -> GemmaRecallOutput

    /// Re-render text at a target reading level (the SimplifiedAdapter asks for
    /// this; the *app* would call it — Phase 1 stub is near-passthrough).
    func simplify(_ text: String, toReadingLevel level: Int) async -> String

    /// Summarize one CLOSED day-bucket's events. The SummaryEngine calls this on
    /// idle/charging; it never mutates the events. `keyEventIDs` should be a
    /// small set of the most informative event ids.
    func summarizeDay(events: [CaptureEvent], dayBucket: DateInterval) async -> GemmaSummaryOutput

    /// Roll up child summaries (dailies → weekly, weeklies → monthly, …) into a
    /// higher-tier body. `childSummaries` are the child prose blocks in order;
    /// `childEntities` are their merged entity mentions.
    func summarizeRollup(tier: SummaryTier, span: DateInterval, childSummaries: [String], childEntities: [EntityMention]) async -> GemmaSummaryOutput
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

    public func summarizeDay(events: [CaptureEvent], dayBucket: DateInterval) async -> GemmaSummaryOutput {
        guard !events.isEmpty else {
            return GemmaSummaryOutput(summary: "Nothing recorded.")
        }
        // Deterministic "summary": count by source + a few snippets, oldest-first.
        let ordered = events.sorted { $0.timestamp < $1.timestamp }
        var bySource: [CaptureSource: Int] = [:]
        for e in ordered { bySource[e.source, default: 0] += 1 }
        let counts = CaptureSource.allCases
            .compactMap { s in bySource[s].map { "\($0) \(s.rawValue)" } }
            .joined(separator: ", ")
        let snippets = ordered.prefix(3).map { e in
            e.text.count > 80 ? String(e.text.prefix(77)) + "…" : e.text
        }
        let summary = "\(events.count) events (\(counts)). " + snippets.joined(separator: " / ")
        let keyIDs = Array(ordered.prefix(3).map(\.id))
        let entities = mergedEntities(ordered.flatMap { $0.entities ?? [] })
        return GemmaSummaryOutput(summary: summary, keyEventIDs: keyIDs, entities: entities)
    }

    public func summarizeRollup(tier: SummaryTier, span: DateInterval, childSummaries: [String], childEntities: [EntityMention]) async -> GemmaSummaryOutput {
        guard !childSummaries.isEmpty else {
            return GemmaSummaryOutput(summary: "No activity this \(tier).")
        }
        // Deterministic: first sentence of each child, capped.
        let leads = childSummaries.prefix(5).map { s in
            (s.split(separator: ".").first.map(String.init) ?? s).trimmingCharacters(in: .whitespaces)
        }
        let more = childSummaries.count > 5 ? " (+\(childSummaries.count - 5) more)" : ""
        return GemmaSummaryOutput(
            summary: "\(childSummaries.count) sub-periods: " + leads.joined(separator: "; ") + more,
            entities: mergedEntities(childEntities)
        )
    }

    /// Deduplicate entity mentions by (surfaceForm, kind), preferring a resolved name.
    private func mergedEntities(_ mentions: [EntityMention]) -> [EntityMention] {
        var seen: [String: EntityMention] = [:]
        for m in mentions {
            let key = "\(m.kind.rawValue)\u{1F}\(m.surfaceForm.lowercased())"
            if let existing = seen[key] {
                if existing.resolvedName == nil, m.resolvedName != nil { seen[key] = m }
            } else {
                seen[key] = m
            }
        }
        return seen.values.sorted { $0.surfaceForm < $1.surfaceForm }
    }
}
