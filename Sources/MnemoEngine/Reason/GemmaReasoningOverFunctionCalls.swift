// A complete `GemmaReasoning` built from a `FunctionCallGenerating` (the raw
// text generator — Gemma 4 via MLX, supplied by `MnemoEngineMLX` or the app
// layer) + `RecallPromptBuilder` + `FunctionCallParser`. This is the last
// non-MLX piece of Phase 3: with this in place, "wire the real model" is
// literally "provide one `generate(prompt:maxTokens:)` method" — everything
// around it (prompt assembly, function-call parsing, answer extraction,
// graceful degradation) lives here and is testable with a fake generator.
//
// Degradation is deliberate: if the generator throws (no runtime in this
// build, model not staged, OOM), every method falls back to the deterministic
// `StubGemmaService` rather than crashing. A recall turn never hard-fails.

import Foundation

public struct GemmaReasoningOverFunctionCalls: GemmaReasoning {
    private let generator: any FunctionCallGenerating
    private let prompts: RecallPromptBuilder
    private let fallback: any GemmaReasoning
    private let locale: Locale
    private let maxAnswerTokens: Int
    private let maxRewriteTokens: Int
    private let maxSummaryTokens: Int

    public init(
        generator: any FunctionCallGenerating,
        prompts: RecallPromptBuilder = .init(),
        fallback: any GemmaReasoning = StubGemmaService(),
        locale: Locale = .current,
        maxAnswerTokens: Int = 512,
        maxRewriteTokens: Int = 512,
        maxSummaryTokens: Int = 256
    ) {
        self.generator = generator
        self.prompts = prompts
        self.fallback = fallback
        self.locale = locale
        self.maxAnswerTokens = maxAnswerTokens
        self.maxRewriteTokens = maxRewriteTokens
        self.maxSummaryTokens = maxSummaryTokens
    }

    // MARK: recall

    public func recall(
        query: String, contextEvents: [CaptureEvent], contextSummaries: [DailySummary]
    ) async -> GemmaRecallOutput {
        let prompt = prompts.recallPrompt(
            query: query, contextEvents: contextEvents, contextSummaries: contextSummaries, locale: locale
        )
        let raw: String
        do {
            raw = try await generator.generate(prompt: prompt, maxTokens: maxAnswerTokens)
        } catch {
            return await fallback.recall(query: query, contextEvents: contextEvents, contextSummaries: contextSummaries)
        }

        switch FunctionCallParser.parse(raw) {
        case .flagForHuman(let reason, let resource):
            return GemmaRecallOutput(
                answerText: "\(reason). This isn't mine to answer — \(resource) can help.",
                citedEventIDs: [], confidence: 1.0, urgency: .attention
            )

        case .setReminder(let when, let what, let modality):
            // The model scheduled a follow-up. Surface it as the answer; the
            // app's reminder subsystem (Phase 5) acts on `set_reminder` calls.
            let mods = modality.map { [$0] }
            return GemmaRecallOutput(
                answerText: "I'll bring this back at \(RecallPromptBuilder.iso(when)): \(what)",
                citedEventIDs: [], confidence: 0.9, urgency: .normal, suggestedModality: mods
            )

        case .recallEvents, .summarizePeriod, .findEntityMentions:
            // The model "called" a retrieval tool the engine already ran. Fall
            // back to the deterministic synthesis over the supplied context.
            return await fallback.recall(query: query, contextEvents: contextEvents, contextSummaries: contextSummaries)

        case .unparseable(let text):
            // Expected, the common path: the model produced the answer-JSON
            // (or just prose). Try to read {"answer":..,"cited":[..],"confidence":..}.
            if let parsed = Self.parseAnswerJSON(text) {
                let ids = parsed.cited.compactMap { idx -> UUID? in
                    let i = idx - 1
                    return contextEvents.indices.contains(i) ? contextEvents[i].id : nil
                }
                let conf = max(0, min(1, parsed.confidence))
                return GemmaRecallOutput(
                    answerText: parsed.answer.isEmpty ? text.trimmingCharacters(in: .whitespacesAndNewlines) : parsed.answer,
                    citedEventIDs: ids,
                    confidence: parsed.answer.isEmpty ? min(conf, 0.5) : conf,
                    urgency: .normal
                )
            }
            // No structured answer — take the prose, hedge.
            let prose = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !prose.isEmpty else {
                return await fallback.recall(query: query, contextEvents: contextEvents, contextSummaries: contextSummaries)
            }
            return GemmaRecallOutput(answerText: prose, citedEventIDs: [], confidence: 0.5, urgency: .normal)
        }
    }

    // MARK: simplify

    public func simplify(_ text: String, toReadingLevel level: Int) async -> String {
        let prompt = prompts.simplifyPrompt(text, toReadingLevel: level, locale: locale)
        do {
            let out = try await generator.generate(prompt: prompt, maxTokens: maxRewriteTokens)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return out.isEmpty ? await fallback.simplify(text, toReadingLevel: level) : out
        } catch {
            return await fallback.simplify(text, toReadingLevel: level)
        }
    }

    // MARK: summaries

    public func summarizeDay(events: [CaptureEvent], dayBucket: DateInterval) async -> GemmaSummaryOutput {
        let prompt = prompts.summarizeDayPrompt(events: events, dayBucket: dayBucket, locale: locale)
        do {
            let prose = try await generator.generate(prompt: prompt, maxTokens: maxSummaryTokens)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !prose.isEmpty else { return await fallback.summarizeDay(events: events, dayBucket: dayBucket) }
            // Structured fields (keyEventIDs / entities) aren't reliably
            // extractable from prose — keep them deterministic (the most recent
            // few events), matching the stub. A structured-extraction pass is a
            // later enrichment, not load-bearing.
            let keyIDs = Array(events.sorted { $0.timestamp < $1.timestamp }.prefix(3).map(\.id))
            return GemmaSummaryOutput(summary: prose, keyEventIDs: keyIDs, entities: [])
        } catch {
            return await fallback.summarizeDay(events: events, dayBucket: dayBucket)
        }
    }

    public func summarizeRollup(
        tier: SummaryTier, span: DateInterval, childSummaries: [String], childEntities: [EntityMention]
    ) async -> GemmaSummaryOutput {
        let prompt = prompts.summarizeRollupPrompt(tier: tier, span: span, childSummaries: childSummaries, locale: locale)
        do {
            let prose = try await generator.generate(prompt: prompt, maxTokens: maxSummaryTokens)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !prose.isEmpty else {
                return await fallback.summarizeRollup(tier: tier, span: span, childSummaries: childSummaries, childEntities: childEntities)
            }
            return GemmaSummaryOutput(summary: prose, keyEventIDs: [], entities: [])
        } catch {
            return await fallback.summarizeRollup(tier: tier, span: span, childSummaries: childSummaries, childEntities: childEntities)
        }
    }

    // MARK: answer-JSON

    /// Pull `{"answer": "...", "cited": [1,3], "confidence": 0.0–1.0}` out of
    /// the model's text (tolerant of fences/prose around it). `cited` /
    /// `confidence` are optional → default `[]` / `1.0`.
    static func parseAnswerJSON(_ raw: String) -> (answer: String, cited: [Int], confidence: Double)? {
        // Strip code fences so the brace scanner sees the object.
        let cleaned = raw.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }
            .joined(separator: "\n")
        guard let obj = FunctionCallParser.firstJSONObject(in: cleaned),
            let answer = obj["answer"] as? String
        else { return nil }
        let cited: [Int]
        if let arr = obj["cited"] as? [Any] {
            cited = arr.compactMap { ($0 as? NSNumber)?.intValue ?? Int("\($0)") }
        } else { cited = [] }
        let confidence: Double
        if let n = obj["confidence"] as? NSNumber { confidence = n.doubleValue }
        else if let s = obj["confidence"] as? String, let d = Double(s) { confidence = d }
        else { confidence = 1.0 }
        return (answer.trimmingCharacters(in: .whitespacesAndNewlines), cited, confidence)
    }
}
