// swift-tools-version: 6.1
// MnemoEngineMLX — the on-device transformer runtime for Mnemo.
//
// This is a SEPARATE package from the engine (`../Package.swift`) on purpose:
// it depends on `mlx-swift-lm` (which pulls in `mlx-swift` / the C++ MLX core),
// which needs Apple Silicon and the Metal toolchain (i.e. Xcode, not bare
// CommandLineTools). Keeping it out of the engine package preserves the
// engine's "builds with CommandLineTools alone, no third-party SPM deps"
// property. The engine defines the seam (`FunctionCallGenerating`); this
// package implements it over Gemma 4.
//
// Build it with Xcode (Swift 6.1+):
//     cd mlx && swift build
// First build resolves `mlx-swift-lm` (a sizeable download) and, on first
// *run*, `LLMModelFactory` fetches `mlx-community/gemma-4-e4b-it-4bit`
// (~4 GB) into the system MLX cache (`~/Library/Caches/com.apple.MLX/…`) —
// the ONLY sanctioned network egress; an always-on app must do this through a
// separate, clearly-scoped installer flow, never the main process.
//
// Status: the MLX call surface in `Sources/MnemoEngineMLX/MLXGemmaGenerator.swift`
// mirrors He Was Socrates's `GemmaService.real` (mlx-swift-lm 3.31.3). It is
// `#if canImport(MLXLLM)`-guarded so the file compiles even without MLX (the
// `#else` branch throws). It has NOT been built/run in the environment that
// authored it (no Xcode there) — reconcile any mlx-swift-lm API drift on a
// machine that has Xcode + the weights, then add a CI job (mirror He Was
// Socrates: `macos-15` + `setup-xcode`).

import PackageDescription

let package = Package(
    name: "MnemoEngineMLX",
    platforms: [
        .macOS("14.0")
    ],
    products: [
        .library(name: "MnemoEngineMLX", targets: ["MnemoEngineMLX"])
    ],
    dependencies: [
        .package(path: ".."),
        // mlx-swift-lm — Apple's official LLM/VLM Swift package (MIT). Brings
        // mlx-swift transitively, and `LLMRegistry.gemma4_e4b_it_4bit`
        // (→ HF `mlx-community/gemma-4-e4b-it-4bit`). Same version He Was
        // Socrates pins.
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", from: "3.31.3")
    ],
    targets: [
        .target(
            name: "MnemoEngineMLX",
            dependencies: [
                .product(name: "MnemoEngine", package: "MnemoEngine"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            ],
            path: "Sources/MnemoEngineMLX"
        )
    ]
)
