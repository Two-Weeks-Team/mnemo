# CLAUDE.md

Guidance for Claude Code working in the **Mnemo** repo.

## What this is

Mnemo is an on-device system that **records what you need** (screen, mic, clipboard, files, or a deliberate "remember this") and **expresses it back** in whatever form you can receive — voice, non-speech sound, screen, haptics, large type, plain-language simplification. Everything stays on the device; the reasoning model is Gemma 4, on-device. It is *not* the He Was Socrates hackathon submission — it reuses that POC's substrate (on-device STT/TTS, the function-call orchestrator pattern, the SHA-256-deduped log, the zero-network-entitlement discipline) but is a distinct product, extracted from `Two-Weeks-Team/he-was-socrates`'s `packages/MnemoEngine/` into this repo.

## Read first

- **`docs/mnemo-implementation-plan.md`** — the validated plan. **§1 is the invariants** (do not move). **§10 is the binding revisions** from the 3-critic loop (architecture / privacy-ethics / feasibility) — when §10 contradicts the body of the plan, §10 wins.
- **`README.md`** — current state (Phase 1: engine core, compiles, tests pass) + the phase table + the honest "deployable is months away" read.

## Invariants (DO NOT violate without explicit user approval)

1. **Zero network egress for captured content.** No `network.client`/`network.server` entitlement on the app process. The only sanctioned network event is the one-time model download, done by a separate clearly-scoped installer flow, never the always-on app. CI must fail the build if a network entitlement appears.
2. **The user owns the data and the switches** — per-source on/off, blackout windows (time + app), a global pause, an always-visible capture indicator, per-event/per-window/total delete (real tombstone deletes, not hidden), export of the controls. Nothing captured without a prior opt-in for that source.
3. **Recall, don't advise.** Medical / legal / financial / immigration / emergency advice-seeking routes to `flag_for_human` — Mnemo remembers, surfaces, summarizes, reminds; it does not opine on your body, money, or legal situation. The `AbstentionGate` is load-bearing.
4. **Adaptive expression — the user's `UserProfile` decides the modality, not the developer's defaults.** Recall output is modality-agnostic (`RecallResult`); the `ExpressionRouter` (the explicit precedence lattice) renders it. Multiple adapters can fire together. Any query can override ("show me" vs "tell me").
5. **Storage lives outside all backup / sync / Spotlight scopes** — `isExcludedFromBackup = true`, no iCloud/Handoff container, a `.metadata_never_index` marker — with a CI test asserting those path attributes (Phase 2+).
6. **No surveillance of others** — captures the user's environment for the user; a "this is private" gesture blacks out a window; non-user faces are not enrolled.

## Layout

```
Package.swift                    — SwiftPM manifest (macOS 14 floor; builds with CommandLineTools alone)
Sources/MnemoEngine/             — the engine: Models, Support (Clock), Memory, Reason, Recall, Express, MnemoCoordinator
Tests/MnemoEngineTests/          — swift-testing suite
docs/mnemo-implementation-plan.md — the validated plan (§1 invariants, §10 binding revisions)
Makefile                         — build / test / lint / ci-local (`make help`)
.github/workflows/ci.yml         — build-and-test · swift-format lint · gitleaks (macos-15)
```

## Common commands

```bash
make build        # swift build — CommandLineTools alone, no Xcode required
make test         # swift test — the swift-testing suite
make lint         # swift-format lint -r Sources Tests (errors fail; warnings tolerated)
make format       # swift-format in place
make ci-local     # build + test + lint, the same gates CI runs
```

Run `make ci-local` before pushing — it is the same gate as CI.

## Stable public API surface

These are part of the published surface; don't change shape without a note in `docs/`:
`Mode`-equivalent enums in `Models/`, `ExpressionModality`, `RecallResult`, `RecallQuery`, `CaptureEvent`, the `MemoryStore` protocol, the `RecallFunctionContract` (the frozen 5-function contract), `ExpressionRouter`'s precedence order, `MnemoCoordinator`.

## Workflow conventions

- `main` is the last green build. Work on `feat/`, `fix/`, `docs/`, `chore/`, `refactor/`, `perf/`, `test/` branches. Conventional Commits: `type(scope): description` with scopes from {`engine`, `memory`, `recall`, `express`, `reason`, `ci`, `docs`}.
- PR merging: `gh pr merge --merge` (preserve history). Squash is forbidden. `--rebase` only when resolving conflicts.
- AI-assisted commits carry the `Co-Authored-By:` trailer.

## What is NOT here yet (and the honest timeline)

Phase 1 = the engine *core* (pure logic). Phase 2 ◑ = `SQLiteMemoryStore` (real tombstone deletes, outside backup/sync/Spotlight, with the path-attributes CI test) + `SummaryEngine` rollup — **done**; still pending an on-disk ANN vector index and at-rest encryption integration. Phase 3 (next) = `GemmaService.real` (Gemma 4 E4B-it 4-bit via mlx-swift-lm — confirm the HF repo id / registry key first) + a real embedding model + real function-calling round-trips (~weeks). Phase 4 = real macOS capture + the privacy UX (~1–2 months). Phase 5 = the macOS app (~1–2 months). Phase 6 = iOS. Phase 7 = hardening + deploy (privacy review, the dependency gate, the network-entitlement CI gate, the path-attributes CI test, thermal/battery perf, the accessibility audit, notarization) — months. **"Actually deployable" ≈ 5–9 months for a small team.** See README's phase table and the plan §6/§10.
