import Testing
import Foundation
@testable import MnemoEngine

@Suite("Memory + recall — end to end through the engine core")
struct MemoryAndRecallTests {

    @Test("Dedup: same text + same day + same window → a duplicate, not a second event")
    func dedup() async {
        let store = InMemoryMemoryStore()
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        let e1 = CaptureEvent(timestamp: t, source: .clipboard, text: "1600 Pennsylvania Ave",
                              appContext: AppContext(bundleId: "com.apple.Safari"))
        let e2 = CaptureEvent(timestamp: t.addingTimeInterval(120), source: .clipboard,  // same day
                              text: "1600 Pennsylvania Ave",
                              appContext: AppContext(bundleId: "com.apple.Safari"))
        let r1 = await store.append(e1)
        let r2 = await store.append(e2)
        if case .stored = r1 {} else { Issue.record("first should store") }
        if case .duplicate(let id) = r2 { #expect(id == e1.id) } else { Issue.record("second should dedup") }
        let count = await store.count
        #expect(count == 1)
    }

    @Test("Different day → not a duplicate")
    func notDedupAcrossDays() async {
        let store = InMemoryMemoryStore()
        let day1 = Date(timeIntervalSince1970: 1_700_000_000)
        let day2 = day1.addingTimeInterval(86_400 * 2)
        let e1 = CaptureEvent(timestamp: day1, source: .manual, text: "remember the milk")
        let e2 = CaptureEvent(timestamp: day2, source: .manual, text: "remember the milk")
        _ = await store.append(e1)
        let r2 = await store.append(e2)
        if case .stored = r2 {} else { Issue.record("different day shouldn't dedup") }
        let count = await store.count
        #expect(count == 2)
    }

    @Test("Capture is cheap: an event lands without an embedding; the enricher fills it")
    func deferredEnrichment() async {
        let store = InMemoryMemoryStore()
        let embedder = StubEmbeddingService()
        let enricher = StubEventEnricher(embedder: embedder)
        let e = CaptureEvent(timestamp: Date(), source: .manual, text: "the form is due the 14th")
        _ = await store.append(e)
        // Before enrichment: no embedding, retrieval finds nothing.
        let pre = await store.retrieve(near: await embedder.embed("when is the form due"), k: 5, minScore: -1)
        #expect(pre.isEmpty)
        // Enrich (off the write path).
        await enricher.enrich(eventID: e.id, text: e.text, in: store)
        let post = await store.retrieve(near: await embedder.embed("the form is due the 14th"), k: 5, minScore: -1)
        #expect(post.contains { $0.id == e.id })
    }

    @Test("RecallEngine: retrieves a relevant event and synthesizes an answer (stub Gemma)")
    func recallHappyPath() async {
        let store = InMemoryMemoryStore()
        let embedder = StubEmbeddingService()
        let gemma = StubGemmaService()
        let enricher = StubEventEnricher(embedder: embedder)
        let engine = RecallEngine(store: store, embedder: embedder, gemma: gemma)

        let e = CaptureEvent(timestamp: Date().addingTimeInterval(-3600), source: .audio,
                             text: "the dentist appointment is on Thursday at 3pm")
        _ = await store.append(e)
        await enricher.enrich(eventID: e.id, text: e.text, in: store)

        let r = await engine.recall(RecallQuery(text: "the dentist appointment is on Thursday at 3pm"))
        #expect(r.deferredToHuman == nil)
        #expect(r.answerText.contains("dentist") || r.citations.contains { $0.eventID == e.id })
        #expect(r.confidence > 0)
    }

    @Test("RecallEngine: an advice-seeking query is deferred to a human, not answered from memory")
    func recallDefersAdvice() async {
        let store = InMemoryMemoryStore()
        let engine = RecallEngine(store: store, embedder: StubEmbeddingService(), gemma: StubGemmaService())
        let r = await engine.recall(RecallQuery(text: "should I take this medication twice a day?"))
        #expect(r.deferredToHuman != nil)
        #expect(r.deferredToHuman?.resourceClass == "a doctor")
        #expect(r.citations.isEmpty)
    }

    @Test("RecallEngine: nothing recorded → a low-confidence 'I don't have that' answer")
    func recallEmpty() async {
        let store = InMemoryMemoryStore()
        let engine = RecallEngine(store: store, embedder: StubEmbeddingService(), gemma: StubGemmaService())
        let r = await engine.recall(RecallQuery(text: "what did I have for lunch on the moon"))
        #expect(r.confidence < 0.5)
        #expect(r.citations.isEmpty)
    }

    @Test("MnemoCoordinator: ingest → ask, full path with the default stubs")
    func coordinatorEndToEnd() async {
        let coord = MnemoCoordinator(profile: UserProfile(primaryModality: .screen))
        let e = CaptureEvent(timestamp: Date().addingTimeInterval(-7200), source: .screen,
                             text: "PIN reset link expires in 24 hours — code 882041")
        _ = await coord.ingest(e)
        let (result, decision) = await coord.ask(RecallQuery(text: "PIN reset link expires in 24 hours — code 882041"))
        #expect(result.deferredToHuman == nil)
        #expect(decision.modalities.contains(.screen))
        // The screen plan should carry the answer.
        if case .screen(let s)? = decision.plans.first(where: { $0.modality == .screen }) {
            #expect(!s.answerText.isEmpty)
        } else { Issue.record("expected a screen plan") }
    }
}
