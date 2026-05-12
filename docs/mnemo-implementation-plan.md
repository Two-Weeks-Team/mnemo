# Mnemo — Implementation Plan (v1, draft for loop-validation)

> **What this is.** An on-device system that *records what you need* — from your screen, your microphone, your clipboard, your files, or a deliberate "remember this" — and *expresses it back to you* in whatever form you can receive: voice, non-speech sound, screen, haptics, large type, or plain-language simplification. The expression modality adapts to the user — a blind user gets voice + haptics; a deaf user gets screen + haptics; a cognitively-overloaded user gets short plain sentences; an able-bodied user gets whatever's convenient. **Everything stays on the device.** Working name: *Mnemo* (from Mnemosyne, memory). Final name TBD.
>
> This is not a hackathon submission. It reuses the He Was Socrates POC's substrate (on-device STT/TTS, the function-call orchestrator pattern, the SHA-256-deduped log, the deterministic build, the zero-network-entitlement discipline) but is a distinct product. Built (at least initially) as a new Swift package `packages/MnemoEngine/` in this repo; can be extracted to its own repo later.
>
> Status: **draft, for loop-validation.** §10 lists the open questions the critic loop must close.

---

## 0. The one-paragraph statement

You shouldn't have to hold everything yourself. Mnemo holds it for you — what was on your screen at 3pm, what someone told you on the phone yesterday, the address you copied last week, the document you scanned in March, the moment you marked "remember this" — and gives it back when you ask, in the form you can take it. It runs entirely on your device: no cloud, no account, no subscription, no byte that leaves your hands. You own the off switch, the blackout windows, and the delete button. It does not advise you on your health, your money, or the law — it remembers, it surfaces, it reminds, and it knows when to hand you to a human. The model that does the remembering and the reasoning is Gemma 4, running on-device; the model that the bytes never leave is your phone or your Mac.

---

## 1. Principles (the invariants — these do not move)

1. **Zero network egress for captured content.** No `network.client`/`network.server` entitlement on the app process. The OS kernel rejects any socket. The *only* sanctioned network event is the one-time model download (and that is done by a separate, clearly-scoped installer flow, not the always-on app process — or sideloaded). Verifiable: `aapt dump permissions` (Android) / `codesign -d --entitlements` (macOS) shows no network; `tcpdump`/Wireshark during use shows nothing; CI fails the build if a network entitlement appears.
2. **The user owns the data and the switches.** Per-source on/off. Blackout windows (time-based + app-based: never capture in a password manager, a banking app, an incognito window, a flagged-private app). A global "pause everything" affordance always reachable. An on-screen/at-a-glance indicator whenever capture is active. Per-event, per-window, and total delete. Export the user controls. Nothing is captured without an explicit prior opt-in for that source.
3. **Recall, don't advise.** Mnemo answers questions about *your own recorded life*. It does not give medical, legal, financial, or immigration advice — those route to a human (the `flag_for_human` function, the He Was Socrates abstention gate). It reminds; it surfaces; it summarizes. It does not opine on what you should do with your body, your money, or your legal situation.
4. **Adaptive expression — the user's needs decide the modality, not the developer's defaults.** A `UserProfile` (set at onboarding, changeable any time, with a "guided setup" for accessibility needs) drives which expression adapter(s) fire. The output of recall is modality-agnostic (`RecallResult`); the `ExpressionRouter` renders it. Multiple adapters can fire together (voice + haptic). Any query can override the modality ("show me" vs "tell me").
5. **Honest about what's the model and what isn't.** Gemma 4 does: the vision/OCR of captured screens, the ASR of captured audio, the embeddings (if Gemma supplies them) or a separate small embedding model, the summarization, the recall reasoning, the function-call dispatch. The platform does: the screen capture, the audio capture, the TTS voice, the haptics, the on-screen rendering. The writeup/docs say which is which.
6. **Graceful memory.** Old memory does not vanish; it degrades — raw events roll up into daily → weekly → monthly summaries (Gemma summarizes) so a year-old day is still recallable as "that week you were moving apartments," even if the minute-by-minute is pruned. The user can pin events to never-prune.
7. **No surveillance of others.** Mnemo captures *the user's* environment for *the user*. It does not transcribe or store identifiable content about people who haven't consented where the law requires it (this is a real legal/ethical line — see §7); a "this is a private conversation" gesture blacks out a window; faces of non-users are not enrolled or recognized.

---

## 2. Architecture (layers)

### 2.1 Capture layer
Each source is opt-in, has a kill switch, and respects blackout windows. A capture produces a `CaptureEvent`.

| Source | macOS | iOS | How it becomes text |
|---|---|---|---|
| **Screen** | `ScreenCaptureKit` — periodic frames (configurable interval, default e.g. every N seconds; or on-significant-change via a cheap diff) | `ReplayKit` / `ScreenCaptureKit` (iOS 18+) — same | Gemma 4 vision (OCR + document/UI parsing) or Apple `Vision` framework for fast OCR + Gemma for structure; result = extracted text + structural tags (this is a window, this is a doc, this is a chat) |
| **Audio** | always-on mic with on-device VAD (voice-activity detection) gating, or push-to-capture | same | Gemma 4 ASR or Apple `Speech` (`requiresOnDeviceRecognition = true`) → transcript with speaker turns; speaker labels are *positional* ("speaker A/B"), not identity, unless the user names them |
| **Clipboard** | `NSPasteboard` change observation | `UIPasteboard` (with the iOS paste-permission model) | text directly; images → OCR |
| **Files** | user-designated folders, `FSEvents` on new/changed docs | Files app providers the user grants | OCR/parse the doc |
| **Manual** | a global hotkey / menu-bar action: "remember this" → captures the current screen + a few seconds of audio + a typed/spoken note | a Share Sheet action / a widget | the user's note + the captured context |

`CaptureEvent`:
```
struct CaptureEvent {
  id: UUID
  timestamp: Date
  source: CaptureSource          // .screen, .audio, .clipboard, .file, .manual
  rawRef: BlobRef?               // optional reference to a stored raw blob (image/audio), encrypted; user can disable raw retention entirely (text-only mode)
  text: String                  // the extracted/transcribed text
  structure: [StructureTag]      // e.g. .document, .chatMessage(sender:), .uiElement, .heading
  entities: [EntityMention]      // people/places/things Gemma extracted (positional, not resolved to real identities unless the user names them)
  embedding: [Float]             // on-device embedding of `text`
  fingerprint: Data              // SHA-256(text + day-bucket + sourceWindowId) — dedup (from He Was Socrates WonderingLog)
  sensitivity: SensitivityTag    // .normal, .sensitive (financial/health/legal keywords detected), .userMarkedPrivate — affects retention default & whether it surfaces unprompted
  appContext: AppContext?        // which app/window (for screen/clipboard) — used for blackout rules
}
```

### 2.2 Memory layer (all on-device)
- **Event log**: SQLite with `FileProtection` complete (iOS) / a `Data Protection`-equivalent encrypted store (macOS — FileVault + an app-managed key in the Keychain). SHA-256 content-fingerprint dedup. Append-only with tombstones for deletes (so "delete" is real, not just hidden).
- **Vector index**: on-device embeddings. Options to evaluate in the critic loop: (a) `sqlite-vec` extension (C, embeddable, brute-force + ANN); (b) a hand-rolled flat cosine index for v1 (fine up to ~10⁵–10⁶ events) with an ANN upgrade later; (c) Gemma 4's embeddings if exposed, else a small dedicated on-device embedding model (e.g. an `all-MiniLM`-class model in MLX/Core ML — ~25MB). Retrieval = top-K by cosine.
- **Hierarchical summaries**: a background job (when the device is idle/charging) takes each completed day's events → Gemma 4 summarizes → a `DailySummary {date, summary, keyEvents:[id], entities}`. Daily → weekly → monthly rollups. Raw events older than a user-set window can be pruned (raw blobs first, then text — but a tier of summaries always remains). Pinned events never prune.
- **Indexes**: B-tree on `timestamp`; secondary on `source`, `sensitivity`, `appContext.bundleId`; an entity index (entity → events that mention it).

### 2.3 Recall engine (Gemma 4 E4B, on-device)
Input: a `RecallQuery` (typed, spoken via ASR, or a proactive trigger — see §2.5).
1. **Retrieve**: embed the query → top-K events from the vector index → plus the relevant summary tiers (today's raw + this week's daily summaries + this month's weekly summaries + older months' monthly summaries) → assemble into a **128K-token context budget** (Gemma 4 E4B's window, verified): recent raw events get full text; older content gets its summary; a token-budget allocator + an eviction policy (recency- and relevance-weighted) keeps it under 128K.
2. **Reason**: Gemma 4 answers, with native function calling for:
   - `recall_events(query, time_range?)` → the events that answer the query, with citations
   - `summarize_period(time_range)` → a synthesized summary of a span
   - `find_entity_mentions(entity)` → every event mentioning a person/place/thing
   - `set_reminder(when, what, surface_modality?)` → schedule a future surfacing
   - `flag_for_human(reason, suggested_resource_class)` → the abstention gate (medical/legal/financial/immigration → "this is not mine to answer; here's who")
   A frozen JSON contract for these functions + a parser for malformed output (the He Was Socrates `FunctionCallOrchestrator` pattern).
3. **Output**: a `RecallResult`:
```
struct RecallResult {
  answerText: String             // the synthesized answer
  citations: [UUID]              // which CaptureEvents back it
  confidence: Double             // 0..1 — low confidence → the expression hedges ("I think...", a tentative tone)
  urgency: Urgency               // .ambient, .normal, .attention, .urgent — modulates the expression (urgent → all adapters fire)
  suggestedModality: [ExpressionModality]?  // a hint (e.g. a long answer → screen; a yes/no → haptic ok)
  followUpHandle: RecallContext? // so a follow-up question keeps the thread
}
```

### 2.4 Expression router (the adaptive part)
A `UserProfile` drives it:
```
struct UserProfile {
  primaryModality: ExpressionModality       // .voice | .screen | .sound | .haptic | .largeType | .simplified
  additionalModalities: [ExpressionModality] // fire alongside the primary (e.g. .haptic + .voice)
  accessibility: AccessibilityNeeds          // .vision(level), .hearing(level), .motor, .cognitive — sets sensible defaults at onboarding
  quietHours: [DateInterval]                 // no sound/voice; haptic/screen only
  alertThreshold: Urgency                    // below this, surface silently / not at all
  language: Locale                           // for TTS, for plain-language simplification, for Gemma's output
  rawRetention: RawRetentionPolicy           // .keepRaw | .textOnly | .keepRawForDays(n)
  pruneAfter: Duration?                      // raw events older than this get pruned (summaries remain)
}
```
Adapters (each is an `ExpressionAdapter` — `func render(_ result: RecallResult, profile: UserProfile)`):
- **VoiceAdapter** — TTS reads `answerText` (Apple `AVSpeechSynthesizer` or a small on-device TTS); tone modulated by `confidence`/`urgency`. Primary for blind/low-vision.
- **SoundAdapter** — non-speech earcons: a rising chime = "found it", a soft descending tone = "couldn't find it", a triple pulse = "urgent". An ambient layer or a standalone modality for users who want signals without speech.
- **ScreenAdapter** — a card: `answerText` + a citations list (tap a citation → jump to that `CaptureEvent` with its raw blob if retained) + a timeline scrubber. The default rich view; primary for deaf/HoH.
- **HapticAdapter** — Taptic Engine patterns (a double-tap = yes/found, a long buzz = needs attention, a slow pulse = ambient). Primary layer for deaf-blind users; the silent-context channel.
- **LargeTypeAdapter** — a high-contrast, large-text screen mode. For low-vision users who use screen, not voice.
- **SimplifiedAdapter** — re-renders `answerText` through Gemma with a "plain language, short sentences, one idea per sentence" instruction before voicing/showing it. For cognitive accessibility; composable with any visual/audio adapter.
The router: picks `profile.primaryModality` + `profile.additionalModalities`, lets `result.suggestedModality` *narrow* (not override) when sensible, escalates to all-adapters when `result.urgency == .urgent` (subject to `quietHours` — urgent in quiet hours → haptic + screen, not voice/sound), respects `profile.alertThreshold` for unprompted surfacings. A per-query override ("show me" / "tell me" / "buzz me") wins for that query.

### 2.5 Proactive surfacing (the "마니또" part — quiet, opt-in, conservative)
Beyond answering queries, Mnemo can surface things *unprompted* — but conservatively, and entirely opt-in:
- **Reminders** the user set (`set_reminder`) fire at their time/modality.
- **Echoes**: if the user's *current* context (what's on screen now, what they just said) strongly matches an old event ("you're filling out the same form you struggled with two months ago — here's what you concluded then"), Mnemo *can* offer it — but only if the user enabled "echoes," only above `alertThreshold`, and with a one-tap dismiss + "don't echo this again." Default: off. This is the feature that, done wrong, is creepy; done right (opt-in, conservative, dismissible, never about other people, never about `.userMarkedPrivate` content), it's the manito.
- **Daily/weekly digests**: an opt-in "here's what your week held" — built from the rollup summaries, delivered in the user's modality at a time they choose.

---

## 3. Tech stack (verified where possible; open items go to the critic loop)

| Concern | Choice | Status |
|---|---|---|
| Language / platform | Swift, macOS first (the team has the He Was Socrates Swift/MLX substrate), iOS second | ✅ pragmatic |
| LLM | Gemma 4 **E4B-it**, 4-bit, ~2.5 GB, **128K context**, text+image+audio input, built-in multilingual OCR + document parsing + ASR + speech-to-translated-text + native function calling, Apache 2.0 | ✅ verified (Gemma 4 model card) |
| LLM runtime (macOS) | MLX via `mlx-swift-lm` (already in He Was Socrates: `LLMRegistry.gemma4_e4b_it_4bit`) | ✅ proven path |
| LLM runtime (iOS) | MLX-Swift on iOS, or MediaPipe LLM Inference SDK | ⚠️ critic loop: which? |
| Screen capture (macOS) | `ScreenCaptureKit` (macOS 12.3+) — needs `com.apple.security.device.screen-capture` or the TCC screen-recording grant (a user prompt) | ⚠️ entitlement change — new vs the He Was Socrates "no extra entitlements"; this is a *deliberate*, user-granted capability, not a regression |
| Audio capture | `AVAudioEngine` + on-device VAD; STT via `SFSpeechRecognizer` (`requiresOnDeviceRecognition`) or Gemma 4 ASR | ⚠️ critic loop: which STT? VAD lib? |
| OCR / vision | Apple `Vision` for fast OCR + Gemma 4 vision for structure/understanding | ⚠️ critic loop: split or all-Gemma? |
| Embeddings | Gemma 4 embeddings if exposed; else a small on-device embedding model (MiniLM-class, ~25 MB, MLX/Core ML) | ⚠️ critic loop: confirm Gemma 4 embedding availability |
| Vector index | v1: hand-rolled flat cosine (fine ≤ ~10⁶ events); upgrade: `sqlite-vec` ANN | ⚠️ critic loop: is flat enough? sqlite-vec maturity? |
| Storage | SQLite, encrypted (`FileProtection` complete / FileVault + Keychain key), SHA-256 dedup, tombstone deletes, raw blobs in an encrypted container | ✅ extends He Was Socrates `WonderingLog` |
| TTS | Apple `AVSpeechSynthesizer` (offline voices) | ✅ proven (He Was Socrates `TTSManager`) |
| Haptics | macOS: limited (`NSHapticFeedbackManager` — coarse); iOS: `UIFeedbackGenerator` / Core Haptics (rich patterns) | ⚠️ macOS haptics are weak — the haptic adapter is iOS-strong, macOS-degraded; honest about it |
| Function calling | Gemma 4 native; frozen JSON contract + parser (He Was Socrates `FunctionCallOrchestrator` pattern) | ✅ proven |
| Build / CI | Makefile + xcodegen + a CI gate that fails on any network entitlement (extend the He Was Socrates pattern) | ✅ extends existing |

---

## 4. Module map (the code)

New package `packages/MnemoEngine/` (Swift Package, builds on CommandLineTools where possible, like `SocraticEngine`):

```
MnemoEngine/
  Sources/MnemoEngine/
    Models/
      CaptureEvent.swift          // CaptureEvent, CaptureSource, StructureTag, EntityMention, SensitivityTag, AppContext, BlobRef
      RecallTypes.swift           // RecallQuery, RecallResult, Urgency, RecallContext
      ExpressionTypes.swift       // ExpressionModality, UserProfile, AccessibilityNeeds, RawRetentionPolicy
      Summary.swift               // DailySummary, WeeklySummary, MonthlySummary
    Capture/
      CaptureSourceProtocol.swift // protocol CaptureProvider { func start/stop; var events: AsyncStream<CaptureEvent> }
      ScreenCaptureProvider.swift  // ScreenCaptureKit wrapper (macOS) — stubbed on non-mac
      AudioCaptureProvider.swift   // AVAudioEngine + VAD + STT
      ClipboardCaptureProvider.swift
      FileCaptureProvider.swift
      ManualCaptureProvider.swift
      CaptureCoordinator.swift     // composes providers, applies blackout rules, the on/off switches, the indicator
      BlackoutPolicy.swift         // time windows + app/window rules
    Memory/
      MemoryStore.swift            // protocol: append, dedup, retrieve(query, k), retrieveByTime, byEntity, prune, delete, export
      SQLiteMemoryStore.swift      // the real impl (extends WonderingLog patterns)
      InMemoryMemoryStore.swift    // for tests
      VectorIndex.swift            // protocol + a flat-cosine impl + (later) a sqlite-vec impl
      EmbeddingService.swift       // protocol + a Gemma/MiniLM impl + a stub
      SummaryEngine.swift          // the rollup job (Gemma summarizes); runs on idle/charging
    Recall/
      RecallEngine.swift           // retrieve → assemble 128K budget → Gemma function call → RecallResult
      ContextBudgeter.swift        // the token-budget allocator + eviction policy
      RecallFunctionContract.swift // the frozen JSON contract for recall_events/summarize_period/find_entity_mentions/set_reminder/flag_for_human
    Reason/
      GemmaService.swift           // .stub (canned) | .real (mlx-swift-lm) — same split as He Was Socrates
      FunctionCallOrchestrator.swift // ported pattern: dispatch + parser + abstention gate
      AbstentionGate.swift         // the regulated-topics refusal list → flag_for_human
    Express/
      ExpressionAdapter.swift      // protocol render(RecallResult, UserProfile)
      ExpressionRouter.swift       // the modality-selection logic (the heart of "adaptive")
      VoiceAdapter.swift           // TTSManager-backed
      SoundAdapter.swift           // earcons
      ScreenAdapter.swift          // emits a ScreenPresentation value (the app renders it)
      HapticAdapter.swift          // emits a HapticPattern value (the app plays it)
      LargeTypeAdapter.swift
      SimplifiedAdapter.swift      // re-renders answerText via Gemma "plain language" pass
    Proactive/
      ReminderScheduler.swift
      EchoEngine.swift             // the conservative, opt-in "you've seen this before" surfacing
      DigestEngine.swift           // opt-in daily/weekly digests
    MnemoCoordinator.swift          // the top-level: wires CaptureCoordinator → MemoryStore → (queries / proactive triggers) → RecallEngine → ExpressionRouter; the app talks only to this
  Tests/MnemoEngineTests/
    ExpressionRouterTests.swift
    MemoryStoreTests.swift          // against InMemoryMemoryStore + a tmp SQLite
    RecallEngineTests.swift         // with .stub Gemma
    BlackoutPolicyTests.swift
    AbstentionGateTests.swift
    ContextBudgeterTests.swift
    DedupTests.swift
```

The macOS app target gets a new "Mnemo" mode/window (or a new app target): the capture indicator, the on/off switches, the query bar, the screen-presentation renderer, the haptic player, the timeline view. (The app target is *not* in v1's scope to fully build — see §6.)

---

## 5. Privacy & ethics model (this is load-bearing — Mnemo records a lot)

| Concern | Mitigation |
|---|---|
| Captured content leaking | No network entitlement on the always-on app process — kernel-enforced; CI-gated; user-verifiable. Model download (if not sideloaded) is a separate, one-time, clearly-scoped installer. |
| Capturing things the user didn't mean to | Blackout rules: a curated default list of never-capture apps (password managers, banking, health apps, incognito browser windows) the user can extend; a "pause everything" affordance always reachable; an always-visible capture indicator; a "this is private — black out this window" gesture. Default capture interval is conservative; the user tunes it. Nothing captured without a prior opt-in for that source. |
| Capturing other people without consent | Audio speaker labels are positional, not identity, unless the user names them. Faces of non-users are not enrolled/recognized. A "this is a private conversation" gesture blacks out the moment. The onboarding flow surfaces the legal reality (one-/two-party-consent jurisdictions for recording) and the user attests they understand. Mnemo never *shares* anything (no network), which mitigates a lot — but the ethical line about recording others stands and the docs are explicit about it. |
| Self-surveillance harm (rumination, "a perfect record of every bad day") | Proactive surfacing is opt-in, conservative, dismissible, and never surfaces `.userMarkedPrivate` content unprompted. Graceful memory (rollups + pruning) means the minute-by-minute of an old bad day fades unless pinned. A "blackout the last hour" / "delete today" affordance is one tap. Onboarding names the trade-off. The default mode is *recall-on-demand*, not *constant proactive narration*. |
| The model giving harmful advice | The abstention gate: medical/legal/financial/immigration → `flag_for_human`, never advise. Mnemo answers questions about *your recorded life*, not about *what you should do*. |
| Data outliving the user's intent | The user owns: per-event delete, per-window blackout+delete, "delete today/this week," full wipe; export (so they can leave with their data); `rawRetention` (text-only mode keeps no images/audio); `pruneAfter` (auto-prune raw after N days). Deletes are real (tombstones, then vacuum), not hidden. |
| Compelled disclosure (subpoena, theft, abuse) | Encryption at rest (FileProtection complete / FileVault + Keychain key — the data is unreadable without the device unlocked). A "panic wipe" affordance. No cloud copy to subpoena. Honest in the docs: a powerful, unlocked device in the wrong hands is a risk no on-device system fully eliminates — encryption + the wipe affordance + no-cloud are the mitigations. |
| Vulnerable users (early dementia, ADHD, TBI, grief) — is a memory aid good or fraught? | Mnemo is positioned as a *tool the user controls*, not a clinical device — no diagnosis, no treatment claims. If a future version targets a clinical population, that requires a named clinical partner who validates it (the He Was Socrates honesty principle). v1: a general-purpose memory aid, with the controls above, and explicit "this is not a medical device" language. |

---

## 6. Build phases (honest about what's a session vs a multi-week effort)

| Phase | What | Effort | This session? |
|---|---|---|---|
| **0. Plan** | This document, loop-validated | — | ✅ now |
| **1. Engine core** | `packages/MnemoEngine/`: all the `Models/`, `MemoryStore` protocol + `InMemoryMemoryStore`, `VectorIndex` protocol + flat-cosine impl, `EmbeddingService` protocol + stub, `RecallEngine` skeleton + `ContextBudgeter`, `GemmaService.stub`, `FunctionCallOrchestrator` + `AbstentionGate` (ported patterns), `ExpressionRouter` + all 6 adapters (emitting values; the app plays them), `MnemoCoordinator`. `Package.swift`. Compiles. swift-testing tests for the testable units (router, budgeter, blackout, abstention, dedup, in-memory store, recall-with-stub). | ~1 session for a working skeleton | ✅ this session (as much as fits) |
| **2. Real persistence** | `SQLiteMemoryStore` (encrypted, deduped, tombstones), `sqlite-vec` or a real flat index on disk, the `SummaryEngine` rollup job | ~days | next |
| **3. Real reason** | `GemmaService.real` wiring (mlx-swift-lm, the E4B 4-bit weights), the real `EmbeddingService`, real function-calling round-trips | ~days | next |
| **4. Real capture (macOS)** | `ScreenCaptureKit` integration (+ the entitlement, the TCC flow, the indicator), `AVAudioEngine`+VAD+STT, clipboard, files, manual; `BlackoutPolicy` enforcement | ~1–2 weeks | next |
| **5. The app** | macOS app: the Mnemo mode/window, the query bar, the screen-presentation renderer, the haptic player (degraded on macOS), the timeline view, the onboarding (incl. the accessibility-needs guided setup and the legal attestation), the privacy controls UI | ~1–2 weeks | next |
| **6. iOS** | iOS app + iOS capture (`ScreenCaptureKit`/`ReplayKit`, Core Haptics — where the haptic adapter is *strong*), the iOS LLM runtime | ~2–3 weeks | later |
| **7. Hardening + deploy** | privacy review, the panic-wipe, the CI network-entitlement gate, performance (thermal, battery, idle scheduling for rollups), accessibility audit (VoiceOver/etc. — the irony is real: a tool *for* accessibility must itself be accessible), notarization / App Store review | ~weeks | later |

**"Deployable" honestly means**: after Phase 7. Phases 1–5 get you a *working macOS prototype* you can run and demo (capture → memory → recall → expression, on-device, zero-egress). Phase 1 (this session) gets you the *engine skeleton that compiles and has tests* — the architecture proven, the seams in place, ready to be filled.

---

## 7. Open questions for the critic loop (close these before/during implementation)

1. **iOS LLM runtime**: MLX-Swift on iOS vs MediaPipe LLM Inference SDK — which is the real path for E4B-it 4-bit with vision+audio input on iOS in 2026?
2. **Embeddings**: does Gemma 4 expose an embedding API, or do we ship a separate small embedding model? If separate — MiniLM-class in MLX, or Core ML? Size/speed?
3. **Vector index**: is a hand-rolled flat cosine genuinely fine for the realistic event volume (a heavy user might generate ~10⁴–10⁵ events/year)? Or do we need `sqlite-vec` ANN from day one? Is `sqlite-vec` mature enough to depend on?
4. **OCR split**: Apple `Vision` for fast OCR + Gemma for structure, or all-Gemma vision? Latency/quality trade-off on captured screen frames (which are frequent — efficiency matters)?
5. **Screen capture cadence**: periodic frames vs on-significant-change (cheap perceptual diff)? What interval balances completeness against battery/storage? Is "on-significant-change" reliable enough?
6. **macOS haptics**: `NSHapticFeedbackManager` is coarse (the trackpad's three feedback patterns). Is the haptic adapter meaningfully useful on macOS, or is it honestly iOS-only and macOS gets a degraded fallback (a screen-flash + a sound)?
7. **Audio always-on**: is an always-on mic with VAD the right default, or is push-to-capture the safer default with always-on as an opt-in? Battery and the surveillance-of-others concern both push toward push-default.
8. **The "echo" feature**: is the conservative-opt-in design (default off, above-threshold only, dismissible, never about others, never `.userMarkedPrivate`) actually safe enough? Or is unprompted surfacing of *anything* from a life-log too fraught to ship in v1 — should v1 be recall-on-demand *only*?
9. **Entitlement change**: He Was Socrates' headline was "no extra entitlements." Mnemo needs the screen-recording grant (and mic). This is a *deliberate, user-granted capability*, not a regression — but the framing matters: Mnemo's privacy claim is "what's captured never leaves the device," not "nothing is captured." Is that framing defensible? (It is — but the critic loop should pressure-test it.)
10. **Recording-others legality**: the onboarding attestation about one-/two-party-consent recording — is that sufficient, or does Mnemo need to *technically* enforce something (e.g., a louder capture indicator when audio capture is on, a "you may be in a two-party-consent jurisdiction" warning)? Where's the line between "the user is responsible" and "the tool should make the responsible thing the easy thing"?

---

## 8. What "validated via a loop" will mean

After this draft: spawn 3 critic agents — an **architecture critic** (is the layering sound? are the seams right? does the 128K-budget recall actually work? is the in-memory→SQLite→vector path coherent?), a **privacy/ethics critic** (is the privacy model airtight given that Mnemo records the screen and mic? is the recording-others handling adequate? is the proactive-surfacing design safe?), and a **feasibility critic** (can Phase 1 actually be built as scoped? are the tech choices real? are the open questions the *right* open questions?). Collect their findings, revise this document, re-review once (a second round) — until the critics have no blocking objections. Then implement Phase 1.

---

## 9. Why this is worth building (the value statement, plainly)

You should not have to be the only copy of your own life. Mnemo is a second copy that you control completely — it remembers what you'd otherwise lose, and it gives it back in the form you can take it: a voice if you can't see, a screen if you can't hear, a buzz if you're in a meeting, a plain sentence if your head is too full. It costs nothing to run. Nothing leaves your device. You hold the off switch. For someone with early dementia it's a thread back to the morning; for an ADHD adult it's the form they were stuck on last month; for a deaf person it's the meeting they couldn't hear, transcribed; for anyone, it's the address they copied last week and the thing they meant to remember. The model that does the remembering — Gemma 4 — runs on the same device the bytes never leave. That combination is the point: a memory that is yours, useful, adaptive to your senses, and incapable of betraying you.

---

## 10. Critic-loop revisions (v2 — accepted from the 3-critic review, 2026-05-11)

Three context-free critics reviewed v1 (architecture / privacy-ethics / feasibility). Accepted changes, all folded into the plan that gets implemented:

### Data-model changes (must land before Phase-1 code — they change the types)
- **`CaptureEvent.embedding`, `.entities`, `.structure` become OPTIONAL.** Capture must be cheap and durable; embedding/entity-extraction/structure-parsing are a *deferred enrichment pass* (a new `EventEnricher` seam). An event lands with the SHA-256 fingerprint computed synchronously and everything else `nil`; a background indexer fills the rest. Embedding inference is NEVER in the capture write path.
- **Privacy defaults flipped**: `UserProfile.rawRetention` defaults to **`.textOnly`** (no raw images/audio kept); `pruneAfter` defaults to a **finite** value (e.g. 14–30 days). Keeping raw blobs is an explicit per-source opt-in. A life-log that hoards raw screen frames by default is a honeypot regardless of encryption.

### Architecture changes
- **`ExpressionAdapter` emits a VALUE; the app performs all side effects.** `VoiceAdapter → VoicePlan {text, rate, pitch, voiceId, locale}` · `SoundAdapter → EarconPlan {earcon}` · `ScreenAdapter → ScreenPresentation {answerText, citations:[CitationRef], timeline:[TimelineMark]}` · `HapticAdapter → HapticPattern {pattern}` · `LargeTypeAdapter → LargeTypePresentation {text, scale, contrast}` · `SimplifiedAdapter → SimplificationRequest {sourceText, targetReadingLevel}` (the *app* runs the Gemma plain-language pass; the adapter just asks for it). This makes all 6 adapters pure and Phase-1-testable.
- **`ExpressionRouter` returns a `RoutingDecision` value, not "calls adapters."** `RoutingDecision { modalities:[ExpressionModality], plans:[ExpressionPlan], suppressed:[(ExpressionModality, SuppressionReason)] }`. **The precedence is an explicit ordered lattice** (this is the most-tested thing in Phase 1):
  1. **accessibility-required modalities** (from `profile.accessibility`) are *always* included — never suppressed, never narrowed away. (A blind user always gets a non-visual channel; a deaf user always gets a non-audio channel.)
  2. then **profile modalities** (`primaryModality` + `additionalModalities`).
  3. then a **per-query override** ("show me"/"tell me"/"buzz me") narrows to that modality *for this query* — but cannot remove an accessibility-required modality (so "show me" from a blind user adds screen, doesn't remove voice).
  4. then **urgency escalation**: `urgency == .urgent` adds all available modalities — *subject to* step 5.
  5. then **quiet-hours suppression**: during `quietHours`, voice and sound are suppressed (haptic + screen survive); an urgent item in quiet hours = haptic + screen, never voice/sound.
  6. then **`result.suggestedModality` may only NARROW within the already-permitted set** — never add, never empty an accessibility-required or query-overridden modality.
  7. then **`profile.alertThreshold`**: for *unprompted* surfacings only, if `result.urgency < alertThreshold` the whole thing is suppressed (logged, not surfaced).
- **`MemoryStore` is an `actor`** (the protocol can't enforce it; the in-memory and SQLite impls are actors). Capture writes and recall reads are concurrent — this is the #1 corruption hazard.
- **The rollup job (`SummaryEngine`) operates on CLOSED day-buckets only** (never today's), produces *new* summary rows + tombstones (never mutates an event in place), runs on idle/charging. Invariant, stated.
- **Capture fan-in is a BOUNDED buffer + a "capture lag" indicator** — a burst of screen frames during a slow enrichment pass never silently drops events (silent data loss is the worst bug in a memory product) and never grows unbounded.
- **`MnemoCoordinator` is split**: `CaptureControl` (switches, blackout, indicator state) · `RecallService` (query → RecallResult) · `ExpressionRouter` (RecallResult+Profile → RoutingDecision) · a thin `MnemoCoordinator` holding references. The app talks to all of them. The capture/memory/rollup paths run **off** `@MainActor`; only the query/expression UI surface is `@MainActor`.
- **New `Clock`/`TimeProvider` abstraction** (injectable time) — `BlackoutPolicy`, `ExpressionRouter` (quiet hours), `SummaryEngine`, `ReminderScheduler` all use it; without it none are deterministically testable. In Phase 1.
- **Recall context assembly is two-source, not "today raw + older summaries"**: (a) **top-K raw retrieval** by cosine — full text, *any age*, even if that month is "supposed to be" summarized (a high-similarity old hit wins); (b) **temporal summary scaffold** — today raw + this-week dailies + this-month weeklies + older monthlies + a **yearly tier** (summary-of-summaries) so the scaffold is bounded for a 5-year user. Both fight over the 128K budget. **System prompt + function-contract JSON + function-call scratchpad overhead is budgeted FIRST**; events get the remainder. Token counting accounts for image-derived structure tags, not just words.
- **Pruning/citation degradation contract**: `RecallResult.citations` reference `CaptureEvent`s; an event may have (raw blob + text), (text only — blob pruned), or (only the summary that mentioned it — text pruned). `ScreenPresentation`'s "tap a citation" degrades: raw → show the blob; text-only → show the text + "the original image was pruned on [date]"; summary-only → show the summary + "this is what survived of [date]'s record."

### Privacy/ethics changes
- **Storage-location invariant** (in §1 and §5): the SQLite store + raw-blob container live **outside all backup/sync/Spotlight scopes** — `URLResourceValues.isExcludedFromBackup = true`, never under an iCloud/Handoff/synced-folder container, a `.metadata_never_index` marker. A CI/test asserts these path attributes. The kernel-no-socket claim is the *floor*, not the ceiling.
- **Dependency gate** (CI): the build fails on any analytics or crash-reporting SDK in the dependency graph, and on any unpinned dependency. The "no network entitlement" gate doesn't catch a transitively-pulled crash reporter that XPCs to a system daemon — this gate does. Also: opt out of system crash submission where possible.
- **Clipboard capture is read-only** — never re-sets the pasteboard (which can trigger Universal-Clipboard sync); onboarding discloses that clipboard contents may *already* be syncing via the OS, which Mnemo cannot fix.
- **Audio capture default = push-to-capture, not always-on VAD.** Always-on mic is an explicit, friction-laden opt-in. The recording indicator is **non-dismissible while the mic is live** (not "at-a-glance"). A jurisdiction note (one-/two-party-consent recording) appears at the moment audio capture is first enabled, not buried in onboarding. (Always-on screen capture of *your own* screen is far less fraught than always-on mic — the asymmetry is deliberate.)
- **v1 = recall-on-demand ONLY.** `EchoEngine` and `DigestEngine` are physically absent from the v1 build (not flagged-off — absent). Only `ReminderScheduler` ships in v1 (a user-set reminder is an alarm clock, not surveillance). Echoes/digests come in a later version after real-usage observation. The `Proactive/` module name `EchoEngine` is dropped (it was a feature leaking into architecture).
- **Separate Mnemo vault credential** distinct from the device unlock — an unlocked device handed to a partner / a border agent / a thief does not open the life-log. Designed now (impl in the hardening phase). **Panic-wipe must be reachable WITHOUT unlocking the app** (a coerced unlock otherwise defeats it). Honest in the docs: nothing protects against a coerced, cooperative unlock.
- **Framing pivot stated affirmatively** (onboarding screen 1): "Mnemo records your screen and microphone. That's the point. The promise is narrower and stronger than 'we don't record much' — it's: what's recorded never leaves this device, and you hold every switch." Don't inherit "no extra entitlements" and quietly amend — own the screen+mic grant as a deliberate capability with a sharper guarantee attached.

### Feasibility changes
- **Model name**: the plan says "Gemma 4 E4B" — verified against the official Gemma 4 model card (`ai.google.dev/gemma/docs/core/model_card_4`) and the `google/gemma-4-E4B` HF repo. (The feasibility critic, whose knowledge cutoff predates Gemma 4's release, thought this was a misnamed "Gemma 3n E4B" — Gemma 4 carries the "E" effective-parameter / per-layer-embedding architecture forward from 3n.) **Code-time double-check the exact HF repo ID and the `mlx-swift-lm` registry key** before wiring `.real` Gemma — cheap insurance. (He Was Socrates already uses `LLMRegistry.gemma4_e4b_it_4bit`, so the team has presumably confirmed it.)
- **`ScreenCaptureKit` on iOS is wrong** — iOS screen recording is `ReplayKit` (`RPScreenRecorder`), not ScreenCaptureKit. Table corrected.
- **Embeddings: DECIDED, not open** — ship a separate small embedding model (an `all-MiniLM`-class model, ~25 MB, in MLX or Core ML); Gemma 4 does not expose a first-class embedding API. (Removed from the open-questions list.)
- **Phase-1 re-scoped** (drop `Capture/` and most of `Proactive/`): **Phase 1 = `Models/` + `Memory/` (in-memory `MemoryStore` actor + flat-cosine `VectorIndex` + `EmbeddingService` stub + an `EventEnricher` synchronous-stub seam) + `Recall/` (`RecallEngine` skeleton + `ContextBudgeter` (the "given a token-count closure, allocate" version) + the frozen `RecallFunctionContract` JSON) + `Reason/` (`GemmaService.stub` + `FunctionCallOrchestrator` + `AbstentionGate`) + `Express/` (`ExpressionRouter` + 6 value-emitting adapters) + `Support/Clock.swift` + a thin `MnemoCoordinator` + the splits (`CaptureControl` interface, `RecallService`) + swift-testing tests for the testable units (router precedence — exhaustive; budgeter allocation; abstention gate; dedup; in-memory store; recall-with-stub).** `Capture/` (the 5 real providers, `CaptureCoordinator`, `BlackoutPolicy`) → Phase 4. `EchoEngine`/`DigestEngine` → cut from v1 entirely; `ReminderScheduler` → Phase 5. The two non-trivial Phase-1 items: **`ContextBudgeter`** (~half a day with deterministic tests) and the **`FunctionCallOrchestrator` + frozen contract** (~half-to-full day — re-deriving a new 5-function contract + parser + dispatch, not a 30-min "port").
- **Three feasibility-blocking open questions ADDED to §7** (these are not polish — they can break the approach): (Q11) *Can E4B do screen-frame OCR/structure at the capture cadence without continuous inference?* If not, what's the lazy-OCR-at-recall fallback, and is recall still fast enough? (He Was Socrates measured ~6 s median for one E4B turn on an M1 Max — a frame every N seconds needing a vision pass is either lazy-at-recall or thermal death.) (Q12) *Thermal/battery envelope for the always-on-capture + periodic-rollup-inference app on a MacBook — measured, not assumed.* A laptop that runs hot and dies in 3 hours isn't shippable. (Q13) *macOS distribution — does a bundled-2.5 GB-LLM screen-recorder survive App Store review, or is this Developer-ID-only? What's the notarization friction?* (Screen-recording + always-on-mic + a bundled LLM is exactly the profile that gets extra scrutiny; App Store may reject continuous background screen capture outright.)
- **"Deployable" calendar — corrected to honest**: the engine prototype (Phases 1–3) is *weeks*; a runnable macOS demo (through Phase 5) is *2–3 months* for a small team; "actually deployable" (Phase 7 done — privacy review, panic-wipe, key management, notarization/distribution, the accessibility audit of a tool *for* accessibility, the E4B latency/thermal tuning which may force architecture changes) is **5–9 months**. The §6 table's "~weeks after hardening" was optimistic; real calendar with review cycles, testing, and inevitable rework is 2–3× the raw engineering estimate.
- **Optional cheap insurance**: the `VectorIndex` protocol gets a non-functional `SqliteVecVectorIndex` stub in Phase 1 so the seam is proven generalizable beyond the flat index.

### What this session delivers (honest)
1. The plan, critic-validated and revised (this document). ✅
2. The re-scoped Phase-1 engine core implemented as `packages/MnemoEngine/` — compiles, has swift-testing tests for the testable units. ⏳ (as much as fits)
3. An honest "deployable-state" assessment: what's done, what's the realistic 5–9-month path, what's the immediate next concrete step (Phase 2: `SqliteMemoryStore` + real `EmbeddingService` + the `SummaryEngine` rollup). ⏳

**"Deployable" is not reachable in one session, and the plan now says so honestly (§6, §10).** What is reachable: a validated plan and a compiling, tested engine core — the architecture proven, the seams in place, ready to be filled.
