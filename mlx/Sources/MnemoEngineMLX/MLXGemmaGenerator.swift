// `MLXGemmaGenerator` — the on-device text generator behind Mnemo's recall.
// Implements the engine's `FunctionCallGenerating` seam over Gemma 4 E4B-it
// 4-bit via `mlx-swift-lm`. With this in place,
// `GemmaReasoningOverFunctionCalls(generator: MLXGemmaGenerator())` is a full
// `GemmaReasoning` — recall, simplify, daily/rollup summaries — all running on
// the device, no network in the hot path.
//
// All MLX code is `#if canImport(MLXLLM)`-guarded so this file compiles even
// where MLX isn't available (the `#else` branch throws `runtimeUnavailable`).
// The call surface mirrors He Was Socrates's `GemmaService.real`
// (mlx-swift-lm 3.31.3). It has NOT been built against the real library in the
// environment that authored it (no Xcode there) — reconcile any API drift
// (loadContainer signature, ChatSession init, GenerateParameters fields)
// against the pinned mlx-swift-lm version on a machine that has Xcode + the
// staged weights, then add a CI job (mirror He Was Socrates: `macos-15` +
// `setup-xcode`). The model is fetched on first `generate` into the system MLX
// cache (`~/Library/Caches/com.apple.MLX/…`) — the only sanctioned network
// egress; an always-on app must front this with a separate installer flow.

import Foundation
import MnemoEngine

#if canImport(MLXLLM)
import MLXLLM
import MLXLMCommon
#endif

public actor MLXGemmaGenerator: FunctionCallGenerating {
    /// Default cap when a caller doesn't pass one. Recall answers are short;
    /// summaries shorter.
    private let defaultMaxTokens: Int
    /// Called with the model-download fraction (0…1) the first time the model
    /// is loaded. The app can surface this; nil = no progress reporting.
    private let onLoadProgress: (@Sendable (Double) -> Void)?

    #if canImport(MLXLLM)
    private var container: ModelContainer?
    #endif

    public init(
        defaultMaxTokens: Int = 512,
        onLoadProgress: (@Sendable (Double) -> Void)? = nil
    ) {
        self.defaultMaxTokens = defaultMaxTokens
        self.onLoadProgress = onLoadProgress
    }

    /// Eagerly load the model (otherwise it loads lazily on first `generate`).
    /// Throws if MLX isn't available in this build or the load fails.
    public func preload() async throws {
        #if canImport(MLXLLM)
        _ = try await loadedContainer()
        #else
        throw FunctionCallGenerationError.runtimeUnavailable
        #endif
    }

    // MARK: FunctionCallGenerating

    public func generate(prompt: String, maxTokens: Int) async throws -> String {
        #if canImport(MLXLLM)
        let container = try await loadedContainer()
        let cap = maxTokens > 0 ? maxTokens : defaultMaxTokens
        // `RecallPromptBuilder` already bakes the system preamble into `prompt`,
        // so we run it as a single user turn with no separate instructions.
        let session = ChatSession(
            container,
            instructions: nil,
            generateParameters: GenerateParameters(maxTokens: cap)
        )
        var assembled = ""
        for try await chunk in session.streamResponse(to: prompt) {
            assembled += chunk
        }
        return assembled
        #else
        throw FunctionCallGenerationError.runtimeUnavailable
        #endif
    }

    // MARK: load

    #if canImport(MLXLLM)
    private func loadedContainer() async throws -> ModelContainer {
        if let container { return container }
        let progress = onLoadProgress
        let c = try await LLMModelFactory.shared.loadContainer(
            configuration: LLMRegistry.gemma4_e4b_it_4bit
        ) { p in
            progress?(p.fractionCompleted)
        }
        container = c
        return c
    }
    #endif
}
