# MnemoEngine

The engine layer for **Mnemo** — an on-device system that records what you need (from your screen, mic, clipboard, files, or a deliberate "remember this") and expresses it back to you in whatever form you can receive: voice, non-speech sound, screen, haptics, large type, or plain-language simplification. Everything stays on the device. The model that does the remembering and the reasoning is Gemma 4, running on-device.

> **Phase 1 (the engine core) + Phase 2 (the memory layer on disk) have landed.** It is not the product yet. It is the architecture, proven and tested: the model types, the `MemoryStore` actor (in-memory **and** a SQLite-backed on-disk store), a flat-cosine `VectorIndex` + a stub `EmbeddingService`, a `RecallEngine` skeleton + `ContextBudgeter` + the frozen `RecallFunctionContract`, a stub `GemmaService` + `AbstentionGate` + `FunctionCallOrchestrator`-pattern, the `SummaryEngine` rollup job (closed-bucket daily → weekly → monthly → yearly summaries), the `ExpressionRouter` (the adaptive heart — an explicit precedence lattice) + 6 value-emitting adapters, a `Clock` abstraction, and a thin `MnemoCoordinator`. Pure logic + on-device SQLite; no platform *capture* APIs yet. **Compiles with CommandLineTools alone; 51 swift-testing tests pass.**
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

## Build & test

```bash
make build       # swift build — builds with CommandLineTools alone (no Xcode required)
make test        # swift test — 51 swift-testing tests
make lint        # swift-format lint -r Sources Tests
make ci-local    # build + test + lint — the same gates CI runs
```

CI (`.github/workflows/ci.yml`, `macos-15`): build-and-test · swift-format lint · gitleaks secret scan. This repo was extracted from [`Two-Weeks-Team/he-was-socrates`](https://github.com/Two-Weeks-Team/he-was-socrates) (`packages/MnemoEngine/`); Mnemo is a distinct product that reuses that POC's on-device substrate. See `CLAUDE.md` for working conventions and `docs/mnemo-implementation-plan.md` for the validated plan (§1 invariants, §10 binding revisions).

## What's NOT here (and why "deployable" is months away, honestly)

| Phase | What | Effort (raw eng) | Realistic calendar |
|---|---|---|---|
| 1 ✅ | the engine core | ~1.5 sessions | done |
| 2 ◑ | `SQLiteMemoryStore` (tombstone deletes, **outside all backup/sync/Spotlight scopes** + a CI test for the path attributes), the `SummaryEngine` rollup job — **done**. Still pending: a real *on-disk* vector index (the flat index is rebuilt in memory on open today — fine to ~10⁶ events), at-rest *encryption* (today: FileVault + iOS `FileProtection`; the Mnemo-vault key is Phase 5) | days | landed; encryption + on-disk ANN are follow-ups |
| 3 | `GemmaService.real` (Gemma 4 E4B-it 4-bit via mlx-swift-lm — confirm the HF repo id / registry key first), a real `EmbeddingService` (MiniLM-class), real function-calling round-trips | days | ~weeks |
| 4 | real capture (macOS): `ScreenCaptureKit` (+ the screen-recording entitlement, the TCC flow, a non-dismissible indicator while the mic is live), `AVAudioEngine`+VAD+STT (audio default = push-to-capture), clipboard (read-only), files, manual; `BlackoutPolicy` enforced | 1–2 weeks | ~1–2 months with the privacy UX done correctly |
| 5 | the macOS app: the Mnemo mode/window, the query bar, the screen-presentation renderer, the haptic player (degraded on macOS), the timeline view, onboarding (the affirmative privacy framing + the accessibility-needs guided setup + the recording-legality note at audio-enable time + a separate Mnemo vault credential + a panic-wipe reachable without unlocking the app), the privacy-controls UI | 1–2 weeks | ~1–2 months |
| 6 | iOS (where the haptic adapter is *strong*): iOS app + iOS capture (`ReplayKit`/`RPScreenRecorder`, Core Haptics), the iOS LLM runtime | 2–3 weeks | later |
| 7 | hardening + deploy: privacy review, the dependency gate (CI fails on any analytics/crash-reporting SDK and on unpinned deps), the CI network-entitlement gate, the path-attributes CI test (`isExcludedFromBackup`, `.metadata_never_index`), performance (thermal, battery, idle-scheduled rollups — may force architecture changes), the accessibility audit (a tool *for* accessibility must itself be accessible — VoiceOver etc.), notarization / App Store review (a bundled-LLM screen-recorder gets extra scrutiny — may be Developer-ID-only) | weeks | months |

**Honest read**: engine prototype (Phases 1–3) ~ weeks; a runnable macOS demo (through Phase 5) ~ 2–3 months for a small team; "actually deployable" (Phase 7 done) ~ 5–9 months.

## The immediate next concrete step

**Phase 3 — wire the real model.** `GemmaService.real`: Gemma 4 E4B-it 4-bit via `mlx-swift-lm` (confirm the HF repo id and the `mlx-swift-lm` registry key at wiring time — cheap insurance, per plan §10 open question #3), implementing `recall` + `simplify` + `summarizeDay` + `summarizeRollup` against the same protocols the stubs satisfy, with native function calling parsed against `RecallFunctionContract`. Plus a real `EmbeddingService` (an `all-MiniLM`-class model in MLX/Core ML, ~25 MB — Gemma 4 has no first-class embedding API, so it's a separate model) replacing `StubEmbeddingService`. Both slot in behind their existing protocols; the rest of the engine doesn't move.

Smaller follow-ups that round out Phase 2: an on-disk ANN vector index behind the `VectorIndex` protocol (the flat index is fine to ~10⁶ events but is rebuilt in memory on open today), and at-rest encryption integration (the engine sets `isExcludedFromBackup` + iOS `FileProtection`; the Mnemo-vault Keychain key is the app layer's, Phase 5).
