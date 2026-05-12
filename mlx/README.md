# MnemoEngineMLX

The on-device transformer runtime for Mnemo — a thin package that implements the engine's `FunctionCallGenerating` seam over **Gemma 4 E4B-it 4-bit** via [`mlx-swift-lm`](https://github.com/ml-explore/mlx-swift-lm). With it, `GemmaReasoningOverFunctionCalls(generator: MLXGemmaGenerator())` is a complete `GemmaReasoning` (recall · simplify · daily/rollup summaries), all on the device.

It's a **separate package** from the engine (`../Package.swift`) on purpose: `mlx-swift-lm` pulls in `mlx-swift` / the C++ MLX core, which needs Apple Silicon and the **Metal toolchain — i.e. Xcode, not bare CommandLineTools**. Keeping it out of the engine preserves the engine's "builds with CommandLineTools alone, no third-party SPM deps" property. The engine owns the contract; this owns the model.

## Build

```bash
cd mlx
swift build          # needs Xcode (Swift 6.1+); resolves mlx-swift-lm (a sizeable download)
```

On first **run**, `LLMModelFactory` fetches `mlx-community/gemma-4-e4b-it-4bit` (~4 GB) into the system MLX cache (`~/Library/Caches/com.apple.MLX/…`). That download is the **only** sanctioned network egress for Mnemo — an always-on app must front it with a separate, clearly-scoped installer flow, never the main process (invariant #1).

## Status — not yet built/run here

`Sources/MnemoEngineMLX/MLXGemmaGenerator.swift` mirrors He Was Socrates's `GemmaService.real` (mlx-swift-lm 3.31.3) and is `#if canImport(MLXLLM)`-guarded so it compiles even without MLX (the `#else` branch throws `FunctionCallGenerationError.runtimeUnavailable`). It has **not** been compiled against the real `mlx-swift-lm` in the environment that authored it (no Xcode there). Before relying on it:

1. On a machine with Xcode + Apple Silicon: `cd mlx && swift build`.
2. Reconcile any API drift against the pinned `mlx-swift-lm` version — likely spots: `LLMModelFactory.shared.loadContainer(configuration:progressHandler:)` signature (He Was Socrates uses the `#hubDownloader()` / `#huggingFaceTokenizerLoader()` macro form), `ChatSession.init`, `GenerateParameters` fields, `streamResponse(to:)`.
3. Stage the weights (or let first-run fetch them) and verify it generates valid recall output: feed it `RecallPromptBuilder().recallPrompt(...)`, parse the result with `FunctionCallParser.parse(...)`.
4. Add a CI job — mirror He Was Socrates's: `runs-on: macos-15` (or `macos-26`) + `maxim-lobanov/setup-xcode@…` + cache `~/.swiftpm` + `swift build` here. (No CI job exists yet — the repo's main CI deliberately stays MLX-free.)

## What it provides

- `MLXGemmaGenerator` — `actor`, `FunctionCallGenerating`. Lazily loads the model on first `generate` (or eagerly via `preload()`); runs the prompt as a single `ChatSession` turn; accumulates the streamed response. `onLoadProgress` reports the first-run download fraction.

A stronger embedding model (an `all-MiniLM`-class model in MLX/Core ML, ~25 MB) could also live here behind the engine's `EmbeddingService` protocol — `MnemoEngine`'s `NLEmbeddingService` (via Apple's `NaturalLanguage`) covers the dependency-free case, so this is optional.
