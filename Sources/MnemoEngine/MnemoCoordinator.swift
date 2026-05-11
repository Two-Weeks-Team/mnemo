// The thin top-level. Per critic-loop §10, what the app actually talks to is a
// small set of focused services — `RecallService` (query → routed expression),
// plus (in later phases) `CaptureControl` (switches, blackout, the indicator)
// and the SummaryEngine. `MnemoCoordinator` just holds the references. The
// capture/memory/rollup paths run OFF @MainActor; only the query/expression UI
// surface would be @MainActor in the app. Phase 1 ships `RecallService` + the
// coordinator; `CaptureControl` is an interface stub here (real providers are
// Phase 4).

import Foundation

// MARK: - RecallService — the query → routed-expression path

public actor RecallService {
    private let engine: RecallEngine
    private let router: ExpressionRouter
    private var profile: UserProfile

    public init(engine: RecallEngine, router: ExpressionRouter, profile: UserProfile) {
        self.engine = engine
        self.router = router
        self.profile = profile
    }

    public func updateProfile(_ p: UserProfile) { self.profile = p }
    public func currentProfile() -> UserProfile { profile }

    /// Ask. Returns the recall result *and* the routing decision (the app
    /// renders the plans). For an unprompted surfacing, pass `query.isProactive
    /// = true` — the router applies the alert threshold.
    public func ask(_ query: RecallQuery,
                    scaffoldDailies: [DailySummary] = [],
                    scaffoldRollups: [RollupSummary] = []) async -> (RecallResult, RoutingDecision) {
        let result = await engine.recall(query, scaffoldDailies: scaffoldDailies, scaffoldRollups: scaffoldRollups)
        let decision = router.route(result, profile: profile, query: query)
        return (result, decision)
    }
}

// MARK: - CaptureControl — interface only in Phase 1 (real providers are Phase 4)

/// What the app uses to flip capture on/off, set blackout windows, and read the
/// "is capture active right now" indicator state. Phase 1 ships only the
/// protocol + a no-op impl; the real implementation wires `ScreenCaptureKit`,
/// `AVAudioEngine`+VAD+STT, clipboard, files, and the manual "remember this"
/// in Phase 4, with `BlackoutPolicy` enforced and a non-dismissible indicator
/// while the mic is live (audio default = push-to-capture).
public protocol CaptureControlling: Sendable {
    func setSource(_ source: CaptureSource, enabled: Bool) async
    func isSourceEnabled(_ source: CaptureSource) async -> Bool
    func pauseEverything() async
    func resume() async
    func isCaptureActive() async -> Bool
    /// Black out the last `interval` and delete those events.
    func blackoutAndDeleteRecent(_ interval: TimeInterval) async
}

public actor NoopCaptureControl: CaptureControlling {
    private var enabled: Set<CaptureSource> = []
    private var paused = false
    public init() {}
    public func setSource(_ source: CaptureSource, enabled: Bool) async {
        if enabled { self.enabled.insert(source) } else { self.enabled.remove(source) }
    }
    public func isSourceEnabled(_ source: CaptureSource) async -> Bool { enabled.contains(source) }
    public func pauseEverything() async { paused = true }
    public func resume() async { paused = false }
    public func isCaptureActive() async -> Bool { !paused && !enabled.isEmpty }
    public func blackoutAndDeleteRecent(_ interval: TimeInterval) async { /* no-op in Phase 1 */ }
}

// MARK: - MnemoCoordinator — holds the references; the app talks through it

public actor MnemoCoordinator {
    public let store: any MemoryStore
    public let recall: RecallService
    public let capture: any CaptureControlling
    private let enricher: any EventEnriching

    public init(
        store: any MemoryStore = InMemoryMemoryStore(),
        embedder: any EmbeddingService = StubEmbeddingService(),
        gemma: any GemmaReasoning = StubGemmaService(),
        profile: UserProfile = UserProfile(),
        clock: any TimeProvider = SystemClock(),
        capture: any CaptureControlling = NoopCaptureControl(),
        enricher: (any EventEnriching)? = nil
    ) {
        self.store = store
        let engine = RecallEngine(store: store, embedder: embedder, gemma: gemma)
        let router = ExpressionRouter(clock: clock)
        self.recall = RecallService(engine: engine, router: router, profile: profile)
        self.capture = capture
        self.enricher = enricher ?? StubEventEnricher(embedder: embedder)
    }

    /// Ingest a captured event: append cheaply, then kick off enrichment off
    /// the write path. Returns the outcome (stored / duplicate).
    @discardableResult
    public func ingest(_ event: CaptureEvent) async -> AppendOutcome {
        let outcome = await store.append(event)
        if case .stored(let e) = outcome {
            // Deferred enrichment — NOT in the write path. (Phase 1: a synchronous
            // stub; Phase 3: a real background pass on idle.)
            await enricher.enrich(eventID: e.id, text: e.text, in: store)
        }
        return outcome
    }

    public func ask(_ query: RecallQuery,
                    scaffoldDailies: [DailySummary] = [],
                    scaffoldRollups: [RollupSummary] = []) async -> (RecallResult, RoutingDecision) {
        await recall.ask(query, scaffoldDailies: scaffoldDailies, scaffoldRollups: scaffoldRollups)
    }
}
