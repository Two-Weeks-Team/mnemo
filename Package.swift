// swift-tools-version: 6.1
// Mnemo — the engine layer.
// On-device capture → memory → recall (Gemma 4) → adaptive expression
// (voice / sound / screen / haptic / large-type / simplified). Everything
// stays on the device. See docs/mnemo-implementation-plan.md.
//
// Phase 1 (this package, as committed): the engine *core* — model types,
// an in-memory MemoryStore actor + a flat-cosine VectorIndex + a stub
// EmbeddingService, a RecallEngine skeleton + ContextBudgeter, a stub
// GemmaService + AbstentionGate, the ExpressionRouter + 6 value-emitting
// adapters, a Clock abstraction, and a thin MnemoCoordinator. Pure logic;
// no platform capture APIs yet. macOS 14 floor (no macOS-26-specific APIs
// in Phase 1) so it stays portable and broadly testable.

import PackageDescription

let package = Package(
    name: "MnemoEngine",
    platforms: [
        .macOS("14.0"),
    ],
    products: [
        .library(name: "MnemoEngine", targets: ["MnemoEngine"]),
    ],
    dependencies: [
        // swift-testing — bundled with recent Swift toolchains; fetched as a
        // package for CommandLineTools-only environments (same as SocraticEngine).
        .package(url: "https://github.com/apple/swift-testing", from: "0.10.0"),
    ],
    targets: [
        .target(
            name: "MnemoEngine",
            path: "Sources/MnemoEngine"
        ),
        .testTarget(
            name: "MnemoEngineTests",
            dependencies: [
                "MnemoEngine",
                .product(name: "Testing", package: "swift-testing"),
            ],
            path: "Tests/MnemoEngineTests"
        ),
    ]
)
