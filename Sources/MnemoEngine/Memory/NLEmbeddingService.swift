// A real on-device `EmbeddingService` backed by Apple's `NaturalLanguage`
// embeddings — a *system framework* (like `SQLite3`), so it adds no SPM
// dependency and needs no model download (the language assets ship with the
// OS). Prefers `NLEmbedding.sentenceEmbedding` when the OS has one for the
// language (512-dim for English); falls back to averaging word embeddings;
// falls back to the deterministic hashed-bag-of-words stub for languages
// `NaturalLanguage` has no asset for — so `embed` always returns a vector of
// `dimension` length. Output is L2-normalized (cosine == dot product).
//
// This is the Phase-3 "real EmbeddingService" — modest by 2026 standards (NL's
// embeddings are classic static word/sentence vectors, not a transformer), but
// real, on-device, dependency-free, and good enough for "find the events
// similar to this query". A larger all-MiniLM-class model in MLX/Core ML is a
// later upgrade behind this same protocol; it would belong in `MnemoEngineMLX`,
// not here, to keep the engine library dependency-free.
//
// NOT the engine default: `MnemoCoordinator` / `RecallEngine` still default to
// `StubEmbeddingService` (deterministic — tests and reproducibility). The app
// layer wires `NLEmbeddingService(locale:)` explicitly. Both the query and the
// stored events must be embedded by the *same* service instance.

import Foundation
import NaturalLanguage

/// `@unchecked Sendable`: it holds immutable `NLEmbedding` handles whose only
/// operation (`vector(for:)`) is a pure, thread-safe lookup.
public struct NLEmbeddingService: EmbeddingService, @unchecked Sendable {
    public let dimension: Int

    private enum Backend {
        case sentence(NLEmbedding)
        case wordAverage(NLEmbedding)
        case stub(StubEmbeddingService)
    }
    private let backend: Backend
    private let language: NLLanguage

    /// Build an embedder for `language`, using the best on-device asset
    /// available. `stubDimension` is used only when `NaturalLanguage` has no
    /// asset for the language at all.
    public init(language: NLLanguage = .english, stubDimension: Int = 64) {
        self.language = language
        if let s = NLEmbedding.sentenceEmbedding(for: language) {
            self.backend = .sentence(s)
            self.dimension = s.dimension
        } else if let w = NLEmbedding.wordEmbedding(for: language) {
            self.backend = .wordAverage(w)
            self.dimension = w.dimension
        } else {
            let stub = StubEmbeddingService(dimension: stubDimension)
            self.backend = .stub(stub)
            self.dimension = stub.dimension
        }
    }

    /// Convenience: derive the `NLLanguage` from a `Locale`.
    public init(locale: Locale, stubDimension: Int = 64) {
        let code = locale.language.languageCode?.identifier ?? "en"
        self.init(language: NLLanguage(rawValue: code), stubDimension: stubDimension)
    }

    /// Which on-device asset this instance ended up using — handy for the app
    /// layer (e.g. to warn that a less-precise fallback is in effect).
    public var assetInUse: String {
        switch backend {
        case .sentence: return "NLEmbedding.sentenceEmbedding(\(language.rawValue))"
        case .wordAverage: return "NLEmbedding.wordEmbedding(\(language.rawValue)) (averaged)"
        case .stub: return "hashed-bag-of-words stub (no NaturalLanguage asset for \(language.rawValue))"
        }
    }

    public func embed(_ text: String) async -> [Float] {
        switch backend {
        case .sentence(let s):
            if let v = s.vector(for: text) { return Self.normalized(v.map(Float.init)) }
            // The sentence model occasionally returns nil for empty/odd input.
            return [Float](repeating: 0, count: dimension)

        case .wordAverage(let w):
            let tokens = tokenize(text)
            guard !tokens.isEmpty else { return [Float](repeating: 0, count: dimension) }
            var acc = [Double](repeating: 0, count: dimension)
            var n = 0
            for tok in tokens {
                guard let v = w.vector(for: tok) else { continue }
                for i in 0..<min(dimension, v.count) { acc[i] += v[i] }
                n += 1
            }
            guard n > 0 else { return [Float](repeating: 0, count: dimension) }
            return Self.normalized(acc.map { Float($0 / Double(n)) })

        case .stub(let stub):
            return await stub.embed(text)
        }
    }

    private func tokenize(_ text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var out: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let tok = String(text[range]).lowercased()
            if !tok.isEmpty { out.append(tok) }
            return true
        }
        return out
    }

    private static func normalized(_ v: [Float]) -> [Float] {
        let norm = sqrt(v.reduce(Float(0)) { $0 + $1 * $1 })
        guard norm > 0 else { return v }
        return v.map { $0 / norm }
    }
}
