import Testing
import Foundation
@testable import MnemoEngine

@Suite("SQLiteMemoryStore — the on-disk MemoryStore")
struct SQLiteMemoryStoreTests {

    private func makeTempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("mnemo-sqlite-test-\(UUID().uuidString)")
    }

    @Test("Append + count + allEvents, newest first")
    func appendAndList() async throws {
        let dir = makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try SQLiteMemoryStore(directory: dir)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let older = CaptureEvent(timestamp: t0, source: .manual, text: "older note")
        let newer = CaptureEvent(timestamp: t0.addingTimeInterval(3_600), source: .manual, text: "newer note")
        _ = await store.append(older)
        _ = await store.append(newer)

        let count = await store.count
        #expect(count == 2)
        let all = await store.allEvents()
        #expect(all.map(\.id) == [newer.id, older.id])   // descending by timestamp
        #expect(all.first?.text == "newer note")
    }

    @Test("Dedup: same text + same day + same window → duplicate, not a second row")
    func dedup() async throws {
        let dir = makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try SQLiteMemoryStore(directory: dir)
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        let e1 = CaptureEvent(timestamp: t, source: .clipboard, text: "1600 Pennsylvania Ave",
                              appContext: AppContext(bundleId: "com.apple.Safari"))
        let e2 = CaptureEvent(timestamp: t.addingTimeInterval(120), source: .clipboard,
                              text: "1600 Pennsylvania Ave", appContext: AppContext(bundleId: "com.apple.Safari"))
        let r1 = await store.append(e1)
        let r2 = await store.append(e2)
        if case .stored = r1 {} else { Issue.record("first should store") }
        if case .duplicate(let id) = r2 { #expect(id == e1.id) } else { Issue.record("second should dedup") }
        let count = await store.count
        #expect(count == 1)
    }

    @Test("Deferred enrichment: enrich off the write path, then retrieval finds it")
    func enrichThenRetrieve() async throws {
        let dir = makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try SQLiteMemoryStore(directory: dir)
        let embedder = StubEmbeddingService()
        let e = CaptureEvent(timestamp: Date(), source: .audio, text: "the dentist appointment is Thursday at 3pm")
        _ = await store.append(e)

        let pre = await store.retrieve(near: await embedder.embed("the dentist appointment is Thursday at 3pm"), k: 5, minScore: -1)
        #expect(pre.isEmpty)

        let emb = await embedder.embed(e.text)
        await store.storeEnrichment(eventID: e.id, embedding: emb, entities: [], structure: [.uiElement])
        let post = await store.retrieve(near: await embedder.embed(e.text), k: 5, minScore: -1)
        #expect(post.contains { $0.id == e.id })
        #expect(post.first?.structure == [.uiElement])
        #expect(post.first?.embedding != nil)
    }

    @Test("events(in:) filters to the range, newest first")
    func eventsInRange() async throws {
        let dir = makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try SQLiteMemoryStore(directory: dir)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let a = CaptureEvent(timestamp: base, source: .manual, text: "A")
        let b = CaptureEvent(timestamp: base.addingTimeInterval(86_400), source: .manual, text: "B")
        let c = CaptureEvent(timestamp: base.addingTimeInterval(86_400 * 5), source: .manual, text: "C")
        for e in [a, b, c] { _ = await store.append(e) }

        let window = DateInterval(start: base.addingTimeInterval(-1), end: base.addingTimeInterval(86_400 + 1))
        let hit = await store.events(in: window)
        #expect(hit.map(\.id) == [b.id, a.id])
    }

    @Test("Delete is real: the event is gone, a tombstone remains, and it stays gone after reopen")
    func deleteIsReal() async throws {
        let dir = makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let kept: UUID
        let removed: UUID
        do {
            let store = try SQLiteMemoryStore(directory: dir)
            let e1 = CaptureEvent(timestamp: Date(), source: .manual, text: "keep me")
            let e2 = CaptureEvent(timestamp: Date().addingTimeInterval(60), source: .manual, text: "delete me")
            _ = await store.append(e1)
            _ = await store.append(e2)
            kept = e1.id; removed = e2.id
            await store.delete(eventID: removed)
            let count = await store.count
            #expect(count == 1)
            let tombs = await store.tombstoneCount()
            #expect(tombs == 1)
            #expect(await store.allEvents().map(\.id) == [kept])
        }
        // Reopen — the deletion persisted, the content didn't come back.
        let reopened = try SQLiteMemoryStore(directory: dir)
        let count = await reopened.count
        #expect(count == 1)
        #expect(await reopened.allEvents().map(\.id) == [kept])
        #expect(await reopened.tombstoneCount() == 1)
    }

    @Test("Persistence: events (and their enrichment) survive a close + reopen; the vector index rebuilds")
    func persistsAcrossReopen() async throws {
        let dir = makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let embedder = StubEmbeddingService()
        let id: UUID
        do {
            let store = try SQLiteMemoryStore(directory: dir)
            let e = CaptureEvent(timestamp: Date(), source: .file, text: "lease renewal is due the 14th")
            _ = await store.append(e)
            id = e.id
            await store.storeEnrichment(eventID: e.id, embedding: await embedder.embed(e.text), entities: [], structure: [])
        }
        let reopened = try SQLiteMemoryStore(directory: dir)
        let count = await reopened.count
        #expect(count == 1)
        // The in-memory vector index was rebuilt from disk on open → retrieval works.
        let hit = await reopened.retrieve(near: await embedder.embed("lease renewal is due the 14th"), k: 5, minScore: -1)
        #expect(hit.contains { $0.id == id })
    }

    @Test("compact() reclaims tombstone space and preserves live rows")
    func compact() async throws {
        let dir = makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try SQLiteMemoryStore(directory: dir)
        let live = CaptureEvent(timestamp: Date(), source: .manual, text: "live")
        let dead = CaptureEvent(timestamp: Date().addingTimeInterval(1), source: .manual, text: "dead")
        _ = await store.append(live)
        _ = await store.append(dead)
        await store.delete(eventID: dead.id)
        try await store.compact()
        let count = await store.count
        #expect(count == 1)
        #expect(await store.allEvents().first?.id == live.id)
    }
}
