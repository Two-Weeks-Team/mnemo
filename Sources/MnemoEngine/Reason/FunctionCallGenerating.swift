// The Phase-3 boundary. `GemmaService.real` = a text generator (Gemma 4 E4B-it
// 4-bit, running on-device via MLX) + the pure `FunctionCallParser`. The text
// generator needs MLX — Apple-Silicon-only, Xcode-only to build, ~4 GB of
// weights — so it lives in a separate integration target (or the app layer),
// mirroring He Was Socrates's `#if canImport(MLXLLM)` split. This protocol is
// the seam: whoever provides MLX implements `generate`; the engine consumes it.
//
// Verified model identity (closes plan §10 open question #3 — it IS Gemma 4
// E4B, not a Gemma-3n typo):
//   • HuggingFace repo:  mlx-community/gemma-4-e4b-it-4bit
//   • mlx-swift-lm key:  LLMRegistry.gemma4_e4b_it_4bit  (mlx-swift-lm ≥ 3.31.3)
//   • first-launch download lands in ~/Library/Caches/com.apple.MLX/… (the
//     ONLY sanctioned network egress; the always-on app process carries no
//     network entitlement — a separate installer flow does the fetch).
//
// Embeddings: Gemma 4 has no first-class embedding API, so a real
// `EmbeddingService` is a separate small model (an all-MiniLM-class model in
// MLX or Core ML, ~25 MB) — also Phase 3, also behind its existing protocol.

import Foundation

/// Produces raw model text for a fully-assembled prompt (system + tool spec +
/// budgeted context + the user turn). The recall path then runs
/// `FunctionCallParser.parse` over the result.
public protocol FunctionCallGenerating: Sendable {
    func generate(prompt: String, maxTokens: Int) async throws -> String
}

public enum FunctionCallGenerationError: Error, CustomStringConvertible {
    /// No on-device model runtime is available in this build (the engine
    /// library builds without MLX; the integration target/app wires it in).
    case runtimeUnavailable
    public var description: String {
        "No on-device model runtime in this build — wire an MLX-backed FunctionCallGenerating (see FunctionCallGenerating.swift)."
    }
}

/// The default generator the dependency-free engine ships with: there isn't
/// one. Always throws `.runtimeUnavailable`. Tests and the Phase-1/2 paths use
/// `StubGemmaService` instead, which doesn't need a generator at all.
public struct UnavailableFunctionCallGenerator: FunctionCallGenerating {
    public init() {}
    public func generate(prompt: String, maxTokens: Int) async throws -> String {
        throw FunctionCallGenerationError.runtimeUnavailable
    }
}
