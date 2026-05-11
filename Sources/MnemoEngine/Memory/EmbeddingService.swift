// Turns text into a vector for retrieval. Phase 1 ships only a deterministic
// stub (a hashed-bag-of-words pseudo-embedding) so the rest of the pipeline is
// testable. Phase 3 swaps in a real small on-device model (an all-MiniLM-class
// model in MLX/Core ML, ~25 MB) — Gemma 4 does not expose a first-class
// embedding API, so this is a separate model. (Critic-loop §10: decided.)

import Foundation

public protocol EmbeddingService: Sendable {
    var dimension: Int { get }
    func embed(_ text: String) async -> [Float]
}

/// Deterministic, dependency-free pseudo-embedding for tests and the Phase-1
/// skeleton. NOT a real embedding — same text → same vector; similar text →
/// somewhat-similar vector (shared tokens land in shared buckets). Replace in
/// Phase 3.
public struct StubEmbeddingService: EmbeddingService {
    public let dimension: Int
    public init(dimension: Int = 64) { self.dimension = max(8, dimension) }

    public func embed(_ text: String) async -> [Float] {
        var v = [Float](repeating: 0, count: dimension)
        let tokens = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return v }
        for tok in tokens {
            let h = Self.stableHash(tok)
            let bucket = Int(h % UInt64(dimension))
            let sign: Float = (h & 1) == 0 ? 1 : -1
            v[bucket] += sign
        }
        // L2-normalize so cosine == dot product.
        let norm = sqrt(v.reduce(Float(0)) { $0 + $1 * $1 })
        if norm > 0 { for i in v.indices { v[i] /= norm } }
        return v
    }

    /// FNV-1a — stable across runs/platforms (unlike `String.hashValue`).
    static func stableHash(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return h
    }
}
