import Testing
import Foundation
@testable import MnemoEngine

/// A `FunctionCallGenerating` that returns a fixed string (or throws), so we
/// can exercise everything between "we built the prompt" and "the model spoke"
/// without an actual model.
private struct FakeGenerator: FunctionCallGenerating {
    let reply: String?            // nil → throw
    func generate(prompt: String, maxTokens: Int) async throws -> String {
        guard let reply else { throw FunctionCallGenerationError.runtimeUnavailable }
        return reply
    }
}

@Suite("GemmaReasoningOverFunctionCalls — the last non-MLX piece of Phase 3")
struct GemmaReasoningOverFunctionCallsTests {

    private func events() -> [CaptureEvent] {
        [
            CaptureEvent(timestamp: Date(timeIntervalSince1970: 1_700_000_000), source: .audio, text: "dentist Thursday 3pm"),
            CaptureEvent(timestamp: Date(timeIntervalSince1970: 1_700_003_600), source: .file, text: "lease renewal due the 14th"),
        ]
    }

    @Test("answer-JSON → answerText, cited indices map to event ids, confidence carried")
    func answerJSON() async {
        let evs = events()
        let g = GemmaReasoningOverFunctionCalls(generator: FakeGenerator(
            reply: #"{"answer":"It's Thursday at 3pm.","cited":[1],"confidence":0.92}"#))
        let out = await g.recall(query: "when is the dentist", contextEvents: evs, contextSummaries: [])
        #expect(out.answerText == "It's Thursday at 3pm.")
        #expect(out.citedEventIDs == [evs[0].id])
        #expect(abs(out.confidence - 0.92) < 1e-6)
        #expect(out.urgency == .normal)
    }

    @Test("fenced answer-JSON with prose around it is still read")
    func fencedAnswerJSON() async {
        let evs = events()
        let g = GemmaReasoningOverFunctionCalls(generator: FakeGenerator(reply: """
            Sure — here's what I found.
            ```json
            {"answer":"Renew the lease by the 14th.","cited":[2]}
            ```
            """))
        let out = await g.recall(query: "lease deadline?", contextEvents: evs, contextSummaries: [])
        #expect(out.answerText == "Renew the lease by the 14th.")
        #expect(out.citedEventIDs == [evs[1].id])
        #expect(abs(out.confidence - 1.0) < 1e-6)   // confidence omitted → 1.0
    }

    @Test("flag_for_human call → answer mentions the resource, confidence 1.0, urgency .attention")
    func flagForHuman() async {
        let g = GemmaReasoningOverFunctionCalls(generator: FakeGenerator(
            reply: #"{"name":"flag_for_human","arguments":{"reason":"this asks for medical advice","resource_class":"a doctor"}}"#))
        let out = await g.recall(query: "should I double the dose?", contextEvents: events(), contextSummaries: [])
        #expect(out.answerText.contains("a doctor"))
        #expect(out.confidence == 1.0)
        #expect(out.urgency == .attention)
        #expect(out.citedEventIDs.isEmpty)
    }

    @Test("set_reminder call → answer mentions the time, modality propagated")
    func setReminder() async {
        let g = GemmaReasoningOverFunctionCalls(generator: FakeGenerator(
            reply: #"{"name":"set_reminder","arguments":{"when":"2026-07-01T09:00:00Z","what":"renew the lease","surface_modality":"haptic"}}"#))
        let out = await g.recall(query: "remind me to renew the lease July 1", contextEvents: events(), contextSummaries: [])
        #expect(out.answerText.contains("renew the lease"))
        #expect(out.suggestedModality == [.haptic])
    }

    @Test("a tool the engine already ran (recall_events) → deterministic fallback synthesis")
    func toolAlreadyRun() async {
        let evs = events()
        let g = GemmaReasoningOverFunctionCalls(generator: FakeGenerator(
            reply: #"{"name":"recall_events","arguments":{"query":"dentist"}}"#))
        let out = await g.recall(query: "dentist?", contextEvents: evs, contextSummaries: [])
        #expect(!out.answerText.isEmpty)            // the stub synthesized something from the context
    }

    @Test("plain prose (no JSON) → that prose as the answer, hedged confidence")
    func proseOnly() async {
        let g = GemmaReasoningOverFunctionCalls(generator: FakeGenerator(reply: "It looks like Thursday afternoon."))
        let out = await g.recall(query: "when?", contextEvents: events(), contextSummaries: [])
        #expect(out.answerText == "It looks like Thursday afternoon.")
        #expect(out.confidence <= 0.5)
    }

    @Test("generator throws → graceful fallback to the deterministic stub (recall never hard-fails)")
    func generatorThrowsRecall() async {
        let g = GemmaReasoningOverFunctionCalls(generator: FakeGenerator(reply: nil))
        let out = await g.recall(query: "dentist Thursday 3pm", contextEvents: events(), contextSummaries: [])
        #expect(!out.answerText.isEmpty)            // came from StubGemmaService
    }

    @Test("simplify: generator's rewrite is used; on throw, falls back")
    func simplify() async {
        let ok = GemmaReasoningOverFunctionCalls(generator: FakeGenerator(reply: "Short. Plain. Done."))
        let rewritten = await ok.simplify("A long parenthetical sentence (with an aside) that rambles.", toReadingLevel: 4)
        #expect(rewritten == "Short. Plain. Done.")
        let bad = GemmaReasoningOverFunctionCalls(generator: FakeGenerator(reply: nil))
        let fb = await bad.simplify("First sentence. Second sentence.", toReadingLevel: 4)
        #expect(!fb.isEmpty)
    }

    @Test("summarizeDay: generator's prose becomes the summary; keyEventIDs stay deterministic; throw → fallback")
    func summarizeDay() async {
        let evs = events()
        let day = DateInterval(start: Date(timeIntervalSince1970: 1_700_000_000), duration: 86400)
        let ok = GemmaReasoningOverFunctionCalls(generator: FakeGenerator(reply: "A quiet day: a dentist note and a lease reminder."))
        let out = await ok.summarizeDay(events: evs, dayBucket: day)
        #expect(out.summary == "A quiet day: a dentist note and a lease reminder.")
        #expect(out.keyEventIDs == Array(evs.sorted { $0.timestamp < $1.timestamp }.prefix(3).map(\.id)))
        let bad = GemmaReasoningOverFunctionCalls(generator: FakeGenerator(reply: nil))
        let fb = await bad.summarizeDay(events: evs, dayBucket: day)
        #expect(!fb.summary.isEmpty)                // came from StubGemmaService
    }

    @Test("end to end through RecallEngine with a fake generator: the answer cites the right event")
    func throughRecallEngine() async {
        let store = InMemoryMemoryStore()
        let embedder = StubEmbeddingService()
        let e = CaptureEvent(timestamp: Date().addingTimeInterval(-3600), source: .audio, text: "the dentist appointment is on Thursday at 3pm")
        _ = await store.append(e)
        await store.storeEnrichment(eventID: e.id, embedding: await embedder.embed(e.text), entities: [], structure: [])
        // The fake "model" returns the answer-JSON citing event [1].
        let gemma = GemmaReasoningOverFunctionCalls(generator: FakeGenerator(reply: #"{"answer":"Thursday at 3pm.","cited":[1],"confidence":0.9}"#))
        let engine = RecallEngine(store: store, embedder: embedder, gemma: gemma)
        let r = await engine.recall(RecallQuery(text: "the dentist appointment is on Thursday at 3pm"))
        #expect(r.deferredToHuman == nil)
        #expect(r.answerText == "Thursday at 3pm.")
        #expect(r.citations.contains { $0.eventID == e.id })
    }

    @Test("parseAnswerJSON: clean / fenced / missing optionals / no `answer` key")
    func parseAnswerJSONUnits() {
        let a = GemmaReasoningOverFunctionCalls.parseAnswerJSON(#"{"answer":"x","cited":[2,3],"confidence":0.4}"#)
        #expect(a?.answer == "x"); #expect(a?.cited == [2, 3]); #expect(abs((a?.confidence ?? 0) - 0.4) < 1e-9)
        let b = GemmaReasoningOverFunctionCalls.parseAnswerJSON("prefix\n```json\n{\"answer\":\"y\"}\n```\nsuffix")
        #expect(b?.answer == "y"); #expect(b?.cited == []); #expect(b?.confidence == 1.0)
        #expect(GemmaReasoningOverFunctionCalls.parseAnswerJSON(#"{"name":"recall_events"}"#) == nil)   // no `answer`
        #expect(GemmaReasoningOverFunctionCalls.parseAnswerJSON("just prose, no json") == nil)
    }
}
