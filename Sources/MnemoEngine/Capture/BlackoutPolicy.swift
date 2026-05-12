// Invariant #2: the user owns the switches. Blackout windows — time-based AND
// app-based — plus a global pause. This is the *decision* logic, pure and
// testable: given a prospective capture (its source, its timestamp, and the
// app/window it came from), should it happen? The real capture providers
// (Phase 4: `ScreenCaptureKit`, `AVAudioEngine`, …) consult this BEFORE
// recording a frame; nothing is captured while a blackout applies. App-based
// rules only bite on `screen` / `clipboard` captures (those carry an
// `AppContext`); a global pause and time windows bite on everything.
//
// A "this is a private conversation" gesture is modelled as a short-lived
// absolute `timeWindow` the app appends. Recurring quiet hours (e.g. every
// night) are `DailyTimeWindow`s (wall-clock minute-of-day, wrap-around-midnight
// aware), evaluated against an injectable `Calendar`.

import Foundation

/// A recurring within-a-day window, in local wall-clock minutes since midnight.
/// `start == end` means an empty window (matches nothing). `start > end` wraps
/// past midnight (e.g. 22:00–07:00 → `1320...420`).
public struct DailyTimeWindow: Sendable, Equatable, Codable {
    public var startMinute: Int   // 0...1439
    public var endMinute: Int     // 0...1439

    public init(startMinute: Int, endMinute: Int) {
        self.startMinute = max(0, min(1439, startMinute))
        self.endMinute = max(0, min(1439, endMinute))
    }

    /// Convenience: `DailyTimeWindow(from: 22, 0, to: 7, 0)`.
    public init(fromHour h1: Int, _ m1: Int, toHour h2: Int, _ m2: Int) {
        self.init(startMinute: h1 * 60 + m1, endMinute: h2 * 60 + m2)
    }

    /// Does `minuteOfDay` (0...1439) fall inside this window? Half-open at the
    /// end (`[start, end)`), so back-to-back windows don't double-cover a minute.
    public func contains(minuteOfDay m: Int) -> Bool {
        guard startMinute != endMinute else { return false }
        if startMinute < endMinute { return m >= startMinute && m < endMinute }
        // wraps midnight
        return m >= startMinute || m < endMinute
    }
}

/// Why a prospective capture was (or wasn't) allowed.
public enum CaptureDecision: Sendable, Equatable {
    case capture
    case blocked(BlockReason)

    public enum BlockReason: Sendable, Equatable {
        case globalPause
        case timeWindow(DateInterval)
        case dailyWindow(DailyTimeWindow)
        case blockedApp(bundleID: String)
    }

    public var isBlocked: Bool { if case .blocked = self { return true } else { return false } }
}

public struct BlackoutPolicy: Sendable, Equatable {
    /// Master switch — when true, nothing is captured at all.
    public var paused: Bool
    /// Absolute intervals during which capture is suppressed (also how a
    /// "private conversation" gesture is recorded: a short window from now).
    public var timeWindows: [DateInterval]
    /// Recurring within-a-day windows (quiet hours), in local wall-clock time.
    public var dailyWindows: [DailyTimeWindow]
    /// Apps from which screen/clipboard capture is never taken (password
    /// managers, banking apps). Matched exactly…
    public var blockedBundleIDs: Set<String>
    /// …or by prefix (e.g. `"com.apple.keychain"` to cover a family).
    public var blockedBundleIDPrefixes: [String]

    public init(
        paused: Bool = false,
        timeWindows: [DateInterval] = [],
        dailyWindows: [DailyTimeWindow] = [],
        blockedBundleIDs: Set<String> = [],
        blockedBundleIDPrefixes: [String] = []
    ) {
        self.paused = paused
        self.timeWindows = timeWindows
        self.dailyWindows = dailyWindows
        self.blockedBundleIDs = blockedBundleIDs
        self.blockedBundleIDPrefixes = blockedBundleIDPrefixes
    }

    /// Should a capture from `source`, at `time`, in `appContext`, happen?
    /// Checks (in order): global pause → absolute time windows → recurring
    /// daily windows (in `calendar`'s time zone) → the app blocklist (only
    /// meaningful when `appContext != nil`, i.e. screen/clipboard).
    public func decide(
        source: CaptureSource,
        at time: Date,
        appContext: AppContext?,
        calendar: Calendar = .current
    ) -> CaptureDecision {
        if paused { return .blocked(.globalPause) }

        if let w = timeWindows.first(where: { $0.contains(time) }) {
            return .blocked(.timeWindow(w))
        }

        if !dailyWindows.isEmpty {
            let comps = calendar.dateComponents([.hour, .minute], from: time)
            let minuteOfDay = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
            if let w = dailyWindows.first(where: { $0.contains(minuteOfDay: minuteOfDay) }) {
                return .blocked(.dailyWindow(w))
            }
        }

        if let bundleID = appContext?.bundleId {
            if blockedBundleIDs.contains(bundleID)
                || blockedBundleIDPrefixes.contains(where: { bundleID.hasPrefix($0) }) {
                return .blocked(.blockedApp(bundleID: bundleID))
            }
        }

        return .capture
    }

    /// Convenience: true iff `decide(...)` would allow the capture.
    public func allows(
        source: CaptureSource, at time: Date, appContext: AppContext?, calendar: Calendar = .current
    ) -> Bool {
        !decide(source: source, at: time, appContext: appContext, calendar: calendar).isBlocked
    }
}
