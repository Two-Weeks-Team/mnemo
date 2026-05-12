import Testing
import Foundation
import NaturalLanguage
@testable import MnemoEngine

@Suite("NLEmbeddingService — a real on-device embedding (NaturalLanguage, no SPM dep, no download)")
struct NLEmbeddingServiceTests {

    private func cosine(_ a: [Float], _ b: [Float]) -> Float {
        precondition(a.count == b.count)
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in a.indices { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        return (na > 0 && nb > 0) ? dot / (sqrt(na) * sqrt(nb)) : 0
    }

    @Test("embed returns a `dimension`-length, L2-normalized vector; same text → same vector")
    func shapeAndDeterminism() async {
        let svc = NLEmbeddingService(language: .english)
        #expect(svc.dimension > 0)
        let v1 = await svc.embed("the lease renewal is due the fourteenth")
        let v2 = await svc.embed("the lease renewal is due the fourteenth")
        #expect(v1.count == svc.dimension)
        #expect(v1 == v2)                          // deterministic
        let norm = sqrt(v1.reduce(Float(0)) { $0 + $1 * $1 })
        #expect(abs(norm - 1) < 1e-3)              // L2-normalized
    }

    @Test("similar sentences are closer than dissimilar ones")
    func similarityOrdering() async {
        let svc = NLEmbeddingService(language: .english)
        let q = await svc.embed("when is my dentist appointment")
        let near = await svc.embed("the dentist appointment is on Thursday at three")
        let far = await svc.embed("photographs of the mountains from last summer")
        #expect(cosine(q, near) > cosine(q, far))
    }

    @Test("Retrieval through InMemoryMemoryStore works with NLEmbeddingService as the embedder")
    func retrievalEndToEnd() async {
        let svc = NLEmbeddingService(language: .english)
        let store = InMemoryMemoryStore()
        let e1 = CaptureEvent(timestamp: Date().addingTimeInterval(-7200), source: .audio,
                              text: "the dentist appointment is on Thursday at 3pm")
        let e2 = CaptureEvent(timestamp: Date().addingTimeInterval(-3600), source: .file,
                              text: "quarterly tax filing instructions and the payment portal link")
        for e in [e1, e2] {
            _ = await store.append(e)
            await store.storeEnrichment(eventID: e.id, embedding: await svc.embed(e.text), entities: [], structure: [])
        }
        let hits = await store.retrieve(near: await svc.embed("when is the dentist visit"), k: 2, minScore: -1)
        #expect(hits.first?.id == e1.id)
    }

    @Test("A language with no NaturalLanguage asset falls back to the hashed stub at the requested dimension")
    func fallbackForUnsupportedLanguage() async {
        // Use a made-up language code so neither sentence nor word embedding exists.
        let svc = NLEmbeddingService(language: NLLanguage(rawValue: "zz-fake"), stubDimension: 48)
        #expect(svc.dimension == 48)
        #expect(svc.assetInUse.contains("stub"))
        let v = await svc.embed("anything at all")
        let again = await svc.embed("anything at all")
        #expect(v.count == 48)
        #expect(v == again)   // still deterministic
    }
}
