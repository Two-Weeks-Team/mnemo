// Nearest-neighbour retrieval over event embeddings. Phase 1: a brute-force
// flat-cosine index (fine up to ~10⁶ events). The protocol also has a
// non-functional `SqliteVecVectorIndex` stub so the seam is proven
// generalizable to an ANN backend (critic-loop §10, cheap insurance).

import Foundation

public struct VectorHit: Sendable, Equatable {
    public var id: UUID
    public var score: Float   // cosine similarity, -1...1
    public init(id: UUID, score: Float) { self.id = id; self.score = score }
}

public protocol VectorIndex: Sendable {
    /// Upsert. Vectors are assumed L2-normalized (cosine == dot product).
    mutating func upsert(id: UUID, vector: [Float])
    mutating func remove(id: UUID)
    /// Top-K by cosine similarity, descending. `minScore` filters weak hits.
    func search(_ query: [Float], k: Int, minScore: Float) -> [VectorHit]
    var count: Int { get }
}

public extension VectorIndex {
    func search(_ query: [Float], k: Int) -> [VectorHit] { search(query, k: k, minScore: -1) }
}

/// Brute-force flat index. Simple, correct, fast enough for v1.
public struct FlatCosineVectorIndex: VectorIndex {
    private var vectors: [UUID: [Float]] = [:]
    public init() {}

    public var count: Int { vectors.count }

    public mutating func upsert(id: UUID, vector: [Float]) { vectors[id] = vector }
    public mutating func remove(id: UUID) { vectors.removeValue(forKey: id) }

    public func search(_ query: [Float], k: Int, minScore: Float) -> [VectorHit] {
        guard k > 0, !query.isEmpty else { return [] }
        var hits: [VectorHit] = []
        hits.reserveCapacity(vectors.count)
        for (id, v) in vectors where v.count == query.count {
            let s = Self.dot(v, query)
            if s >= minScore { hits.append(VectorHit(id: id, score: s)) }
        }
        hits.sort { $0.score > $1.score }
        if hits.count > k { hits.removeLast(hits.count - k) }
        return hits
    }

    static func dot(_ a: [Float], _ b: [Float]) -> Float {
        var s: Float = 0
        for i in a.indices { s += a[i] * b[i] }
        return s
    }
}

/// Placeholder for an `sqlite-vec`-backed ANN index (Phase 3). Exists in
/// Phase 1 only to prove the protocol generalizes; calls are no-ops / empty.
public struct SqliteVecVectorIndex: VectorIndex {
    public init() {}
    public var count: Int { 0 }
    public mutating func upsert(id: UUID, vector: [Float]) { /* TODO Phase 3 */ }
    public mutating func remove(id: UUID) { /* TODO Phase 3 */ }
    public func search(_ query: [Float], k: Int, minScore: Float) -> [VectorHit] {
        // Intentionally empty until the sqlite-vec backend lands.
        []
    }
}
