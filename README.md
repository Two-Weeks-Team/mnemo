# MnemoEngine

The engine layer for **Mnemo** — an on-device system that records what you need (from your screen, mic, clipboard, files, or a deliberate "remember this") and expresses it back to you in whatever form you can receive: voice, non-speech sound, screen, haptics, large type, or plain-language simplification. Everything stays on the device. The model that does the remembering and the reasoning is Gemma 4, running on-device.

> **Phases 1–2 + all of Phase 3 *except* the MLX text generator have landed.** It is not the product yet. It is the architecture, proven and tested: the model types, the `MemoryStore` actor (in-memory **and** a SQLite-backed on-disk store), a flat-cosine `VectorIndex` + a **real on-device `EmbeddingService`** (`NLEmbeddingService`, via Apple's `NaturalLanguage` — no SPM dep, no download) alongside the stub, a `RecallEngine` skeleton + `ContextBudgeter` + the frozen `RecallFunctionContract` + a tolerant `FunctionCallParser` + a `RecallPromptBuilder` + `GemmaReasoningOverFunctionCalls` (a complete `GemmaReasoning` built from a `FunctionCallGenerating` — the only thing left external is the model's text-generation), a stub `GemmaService` + `AbstentionGate` + `FunctionCallOrchestrator`-pattern, the `SummaryEngine` rollup job (closed-bucket daily → weekly → monthly → yearly summaries), the `ExpressionRouter` (the adaptive heart — an explicit precedence lattice) + 6 value-emitting adapters, a `Clock` abstraction, and a thin `MnemoCoordinator`. Pure logic + on-device SQLite + system NLP; the on-device *transformer runtime* (Gemma 4 via MLX) and the platform *capture* APIs are not wired here (they need Xcode + ~4 GB weights — a separate `MnemoEngineMLX` target / the app layer). **Compiles with CommandLineTools alone; 86 swift-testing tests pass.**
>
> See **`docs/mnemo-implementation-plan.md`** for the full plan, the 3-critic loop-validation (§10), and the honest deployable-state assessment.

## What's here (Phase 1)

```
Sources/MnemoEngine/
  MnemoEngine.swift            — umbrella + version
  Support/Clock.swift          — TimeProvider (SystemClock / FixedClock) — injectable time
  Models/
    CaptureEvent.swift         — CaptureEvent (embedding/entities/structure OPTIONAL — deferred enrichment), CaptureSource, StructureTag, EntityMention, SensitivityTag, BlobRef, AppContext; SHA-256 content-fingerprint dedup
    RecallTypes.swift          — RecallQuery, RecallResult, Urgency, CitationRef (with availability — pruning-degradation contract)
    ExpressionTypes.swift      — ExpressionModality, UserProfile (rawRetention defaults .textOnly; pruneAfterDays defaults 30), AccessibilityNeed (→ required modality floors), RawRetentionPolicy
    Summary.swift              — DailySummary, RollupSummary (weekly/monthly/yearly), SummaryTier
  Memory/
    MemoryStore.swift          — MemoryStore protocol (Actor) + InMemoryMemoryStore actor (dedup, retrieval, tombstone deletes)
    VectorIndex.swift          — VectorIndex protocol + FlatCosineVectorIndex + a SqliteVecVectorIndex stub (seam proven)
    EmbeddingService.swift     — EmbeddingService protocol + StubEmbeddingService (deterministic hashed-bag-of-words; real MiniLM-class model is Phase 3)
    EventEnricher.swift        — EventEnriching protocol + StubEventEnricher (embedding is NEVER in the capture write path — deferred pass)
  Reason/
    AbstentionGate.swift       — "recall, don't advise" — medical/legal/financial/immigration/emergency advice-seeking → flag_for_human
    GemmaService.swift         — GemmaReasoning protocol + StubGemmaService (.real wires Gemma 4 E4B via mlx-swift-lm in Phase 3)
  Recall/
    RecallFunctionContract.swift — the frozen 5-function contract (recall_events / summarize_period / find_entity_mentions / set_reminder / flag_for_human)
    ContextBudgeter.swift      — packs the recall context into the model window: top-K raw retrieval (any age) + temporal summary scaffold, overhead budgeted first, slack rolls between them; token-counting injected → pure & deterministic
    RecallEngine.swift         — query → abstention check → embed → retrieve → budget → Gemma → RecallResult
  Express/
    ExpressionPlans.swift      — VoicePlan / EarconPlan / ScreenPresentation / HapticPattern / LargeTypePresentation / SimplificationRequest; ExpressionPlan union; RoutingDecision
    ExpressionAdapter.swift    — ExpressionAdapter protocol + 6 adapters (each emits a value; the app performs side effects) + DefaultAdapters
    ExpressionRouter.swift     — THE ADAPTIVE HEART — the explicit precedence lattice (accessibility floor → profile → query override → urgency escalation → quiet-hours suppression → suggestedModality narrowing → alert-threshold suppression)
  MnemoCoordinator.swift       — RecallService (query → routed expression); CaptureControlling protocol + NoopCaptureControl (real providers are Phase 4); the thin MnemoCoordinator (ingest → deferred enrich; ask)
Tests/MnemoEngineTests/
  ExpressionRouterTests.swift  — exhausts the precedence lattice (the most-tested thing)
  AbstentionGateTests.swift    — recall-allowed vs advice-abstained, per domain
  ContextBudgeterTests.swift   — overhead-first, capping, slack-rolling, finer-tiers-preferred, ordering
  MemoryAndRecallTests.swift   — dedup, deferred enrichment, recall happy path, recall defers advice, recall-empty, coordinator end to end
```

### Phase 2 additions — the memory layer, on disk

```
Sources/MnemoEngine/Memory/
  SQLiteSupport.swift          — a deliberately tiny wrapper over the system `SQLite3` C module (no SPM dependency — the dependency gate stays clean): open + WAL pragmas + prepared statements + transactions + VACUUM
  StorageHardening.swift       — invariant #5: `isExcludedFromBackup`, the `.metadata_never_index` Spotlight marker, iOS `FileProtectionType` — hardens whatever path the app layer hands it (the *location* is the app's job, Phase 4/5)
  SQLiteMemoryStore.swift      — the on-disk `MemoryStore` (one row per event: indexed scalars + the `Codable` event as a JSON blob; the flat-cosine vector index is held in memory, rebuilt from disk on open). Deletes are REAL: payload columns nulled + `deleted = 1`, leaving an `(id, timestamp)` tombstone; `compact()` runs `VACUUM`
  SummaryStore.swift           — `SummaryStore` protocol + `InMemorySummaryStore` + `SQLiteSummaryStore` (its own hardened `summaries.sqlite3`)
  SummaryEngine.swift          — the rollup job: walks CLOSED day/week/month/year buckets (ISO-8601, UTC), writes a summary for any bucket that lacks one, NEVER mutates a `CaptureEvent`. Idempotent.
Sources/MnemoEngine/Reason/GemmaService.swift  — `GemmaReasoning` gains `summarizeDay` / `summarizeRollup` (the stub is deterministic; the real model is Phase 3)
Tests/MnemoEngineTests/
  SQLiteMemoryStoreTests.swift — append/dedup/enrich+retrieve/range/real-delete+reopen/persistence+index-rebuild/compact
  StorageHardeningTests.swift  — directory excluded-from-backup + Spotlight marker; the store hardens its own paths; idempotent  (this is the path-attributes CI test the plan §7 calls for, landing early)
  SummaryEngineTests.swift     — closed-buckets-only; idempotent; never mutates events; monthly rollup after the month closes; SQLite summary store
```

### Phase 3 — the recall model (everything but the MLX text generator is in)

`GemmaService.real` = a text generator (Gemma 4 E4B-it 4-bit, on-device via MLX) **+** the prompt builder, the function-call parser, the answer extractor, and a real embedder. All of that except the text generator ships here; the generator needs MLX (Apple-Silicon-only, Xcode-only to build, ~4 GB of weights) and lives in a separate `MnemoEngineMLX` target / the app layer, mirroring He Was Socrates's `#if canImport(MLXLLM)` split.

```
Sources/MnemoEngine/Memory/NLEmbeddingService.swift   — a REAL on-device EmbeddingService backed by Apple's NaturalLanguage embeddings (a system framework — no SPM dep, no model download; the language assets ship with the OS): sentence embedding when available (512-dim for English), else averaged word embeddings, else the hashed-bag-of-words stub. L2-normalized. Not the engine default (the stub is — deterministic for tests); the app wires `NLEmbeddingService(locale:)`.
Sources/MnemoEngine/Recall/FunctionCallParser.swift   — model text → a typed RecallFunctionCall against RecallFunctionContract's 5 functions. Tolerant of ```fences```, <tool_call> tags, prose around the JSON, alternate key names (`function`/`parameters`/`q`/…), {start,end} vs [a,b] vs "yyyy-MM" ranges, ISO-8601 dates; a `}` inside a JSON string doesn't fool the brace matcher. Genuinely-unparseable output → `.unparseable(rawText:)` so the caller falls back.
Sources/MnemoEngine/Recall/RecallPromptBuilder.swift  — assembles the strings the model completes: a recall prompt (system preamble + numbered context events/summaries + the question + an answer-JSON instruction + the `flag_for_human`/`set_reminder` escape hatches), a simplify prompt, day/rollup summary prompts. Pure.
Sources/MnemoEngine/Reason/FunctionCallGenerating.swift  — the seam: `FunctionCallGenerating { func generate(prompt:maxTokens:) async throws -> String }` (whoever provides MLX implements it) + the verified model identity (HF `mlx-community/gemma-4-e4b-it-4bit`, `LLMRegistry.gemma4_e4b_it_4bit`, mlx-swift-lm ≥ 3.31.3) + `UnavailableFunctionCallGenerator` (the dependency-free engine ships no runtime — throws)
Sources/MnemoEngine/Reason/GemmaReasoningOverFunctionCalls.swift  — a COMPLETE `GemmaReasoning` (recall / simplify / summarizeDay / summarizeRollup) built from a `FunctionCallGenerating` + the prompt builder + the parser + the answer-JSON extractor. With this in place, "wire the real model" = "provide one `generate` method". If the generator throws (no runtime, model not staged, OOM), every method degrades to the deterministic `StubGemmaService` — a recall turn never hard-fails.
Tests/MnemoEngineTests/  — FunctionCallParserTests (all 5 functions; fenced/tagged/prose; alt keys; inlined args; brace-in-string; the 3 range shapes; missing-arg/unknown-fn → unparseable), NLEmbeddingServiceTests (shape/L2-norm/determinism; similar > dissimilar; retrieval end-to-end; unsupported-language fallback), RecallPromptBuilderTests, GemmaReasoningOverFunctionCallsTests (answer-JSON/fenced/flag_for_human/set_reminder/tool-already-run/prose-only/generator-throws-→-fallback/simplify/summarizeDay; end-to-end through RecallEngine with a fake generator; parseAnswerJSON units)
```

## Build & test

```bash
make build       # swift build — builds with CommandLineTools alone (no Xcode required)
make test        # swift test — 86 swift-testing tests
make lint        # swift-format lint -r Sources Tests
make ci-local    # build + test + lint — the same gates CI runs
```

CI (`.github/workflows/ci.yml`, `macos-15`): build-and-test · swift-format lint · gitleaks secret scan. This repo was extracted from [`Two-Weeks-Team/he-was-socrates`](https://github.com/Two-Weeks-Team/he-was-socrates) (`packages/MnemoEngine/`); Mnemo is a distinct product that reuses that POC's on-device substrate. See `CLAUDE.md` for working conventions and `docs/mnemo-implementation-plan.md` for the validated plan (§1 invariants, §10 binding revisions).

## What's NOT here (and why "deployable" is months away, honestly)

| Phase | What | Effort (raw eng) | Realistic calendar |
|---|---|---|---|
| 1 ✅ | the engine core | ~1.5 sessions | done |
| 2 ◑ | `SQLiteMemoryStore` (tombstone deletes, **outside all backup/sync/Spotlight scopes** + a CI test for the path attributes), the `SummaryEngine` rollup job — **done**. Still pending: a real *on-disk* vector index (the flat index is rebuilt in memory on open today — fine to ~10⁶ events), at-rest *encryption* (today: FileVault + iOS `FileProtection`; the Mnemo-vault key is Phase 5) | days | landed; encryption + on-disk ANN are follow-ups |
| 3 ◑ | The function-call **parser** + the `FunctionCallGenerating` seam + the verified model identity + the `RecallPromptBuilder` + `GemmaReasoningOverFunctionCalls` (a complete `GemmaReasoning` lacking only the generator) + a **real on-device `EmbeddingService`** (`NLEmbeddingService`, via `NaturalLanguage` — no dep, no download) — **done** (pure, testable, ships here). Still pending: the MLX text generator (`mlx-community/gemma-4-e4b-it-4bit` via `LLMRegistry.gemma4_e4b_it_4bit`, mlx-swift-lm ≥ 3.31.3 — a separate Xcode-built `MnemoEngineMLX` target, ~4 GB weights) — and, optionally, a stronger embedding model (an all-MiniLM-class model, ~25 MB) behind the same protocol | days (the MLX side) | the only thing left is one `generate(prompt:maxTokens:)` method, backed by MLX |
| 4 | real capture (macOS): `ScreenCaptureKit` (+ the screen-recording entitlement, the TCC flow, a non-dismissible indicator while the mic is live), `AVAudioEngine`+VAD+STT (audio default = push-to-capture), clipboard (read-only), files, manual; `BlackoutPolicy` enforced | 1–2 weeks | ~1–2 months with the privacy UX done correctly |
| 5 | the macOS app: the Mnemo mode/window, the query bar, the screen-presentation renderer, the haptic player (degraded on macOS), the timeline view, onboarding (the affirmative privacy framing + the accessibility-needs guided setup + the recording-legality note at audio-enable time + a separate Mnemo vault credential + a panic-wipe reachable without unlocking the app), the privacy-controls UI | 1–2 weeks | ~1–2 months |
| 6 | iOS (where the haptic adapter is *strong*): iOS app + iOS capture (`ReplayKit`/`RPScreenRecorder`, Core Haptics), the iOS LLM runtime | 2–3 weeks | later |
| 7 | hardening + deploy: privacy review, the dependency gate (CI fails on any analytics/crash-reporting SDK and on unpinned deps), the CI network-entitlement gate, the path-attributes CI test (`isExcludedFromBackup`, `.metadata_never_index`), performance (thermal, battery, idle-scheduled rollups — may force architecture changes), the accessibility audit (a tool *for* accessibility must itself be accessible — VoiceOver etc.), notarization / App Store review (a bundled-LLM screen-recorder gets extra scrutiny — may be Developer-ID-only) | weeks | months |

**Honest read**: engine prototype (Phases 1–3) ~ weeks; a runnable macOS demo (through Phase 5) ~ 2–3 months for a small team; "actually deployable" (Phase 7 done) ~ 5–9 months.

## The immediate next concrete step

**The MLX text generator (`MnemoEngineMLX`).** Everything around the model is in — the prompt builder, the function-call parser, the answer extractor, `GemmaReasoningOverFunctionCalls`, a real embedder. What's left of Phase 3 is the one piece that needs a toolchain this library deliberately doesn't depend on: a `FunctionCallGenerating` conformance backed by Gemma 4. Add a separate Swift package / target `MnemoEngineMLX` that:
- depends on `mlx-swift-lm` ≥ 3.31.3 and path-depends on `MnemoEngine`,
- guards all MLX code with `#if canImport(MLXLLM)` so it compiles even where MLX isn't available (the body is excluded — like He Was Socrates's `GemmaService`),
- loads `LLMRegistry.gemma4_e4b_it_4bit` (HF `mlx-community/gemma-4-e4b-it-4bit`, downloaded once into the system MLX cache by a clearly-scoped installer flow — the always-on app carries no network entitlement),
- implements `func generate(prompt:maxTokens:) async throws -> String` — and that's it; `GemmaReasoningOverFunctionCalls(generator: MLXGemmaGenerator())` is then a full `GemmaReasoning`.

Optionally a stronger `EmbeddingService` (an `all-MiniLM`-class model in MLX/Core ML, ~25 MB) behind the same protocol — `NLEmbeddingService` covers the dependency-free case. Build `MnemoEngineMLX` with Xcode (Swift 6.1+), wire it in CI with `setup-xcode` (mirroring He Was Socrates), and budget for the ~4 GB first-launch download + the E4B latency/thermal questions the plan §7 flags.

After that: **Phase 4** — real macOS capture (`ScreenCaptureKit` + the screen-recording entitlement + the TCC flow + the non-dismissible mic indicator), `AVAudioEngine`+VAD+STT (push-to-capture default), clipboard (read-only), files, manual; `BlackoutPolicy` enforced — then the macOS app (Phase 5), iOS (Phase 6), and the hardening/distribution pass (Phase 7). Those are platform work measured in months, not a session — see the phase table above and the plan §6/§10.

Smaller follow-ups that round out Phase 2: an on-disk ANN vector index behind the `VectorIndex` protocol (the flat index is fine to ~10⁶ events but is rebuilt in memory on open today), and at-rest encryption integration (the engine sets `isExcludedFromBackup` + iOS `FileProtection`; the Mnemo-vault Keychain key is the app layer's, Phase 5).
