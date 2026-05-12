import Testing
import Foundation
@testable import MnemoEngine

@Suite("BlackoutPolicy — the user owns the switches (time + app + global pause)")
struct BlackoutPolicyTests {

    private let utc: Calendar = {
        var c = Calendar(identifier: .iso8601); c.timeZone = TimeZone(secondsFromGMT: 0)!; return c
    }()
    private func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        utc.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    @Test("Default policy allows everything")
    func defaultAllows() {
        let p = BlackoutPolicy()
        #expect(p.allows(source: .screen, at: Date(), appContext: AppContext(bundleId: "com.example.app"), calendar: utc))
        #expect(p.allows(source: .audio, at: Date(), appContext: nil, calendar: utc))
    }

    @Test("Global pause blocks every source")
    func globalPause() {
        let p = BlackoutPolicy(paused: true)
        for src in CaptureSource.allCases {
            #expect(p.decide(source: src, at: Date(), appContext: nil, calendar: utc) == .blocked(.globalPause))
        }
    }

    @Test("An absolute time window blocks events inside it and allows ones outside")
    func absoluteWindow() {
        let win = DateInterval(start: at(2026, 5, 12, 9, 0), end: at(2026, 5, 12, 10, 0))
        let p = BlackoutPolicy(timeWindows: [win])
        #expect(p.decide(source: .screen, at: at(2026, 5, 12, 9, 30), appContext: nil, calendar: utc) == .blocked(.timeWindow(win)))
        #expect(p.allows(source: .screen, at: at(2026, 5, 12, 8, 59), appContext: nil, calendar: utc))
        #expect(p.allows(source: .screen, at: at(2026, 5, 13, 9, 30), appContext: nil, calendar: utc))   // different day
    }

    @Test("DailyTimeWindow.contains: normal window, wrap-past-midnight, empty")
    func dailyWindowContains() {
        let work = DailyTimeWindow(fromHour: 9, 0, toHour: 17, 0)
        #expect(work.contains(minuteOfDay: 12 * 60))     // noon — inside
        #expect(!work.contains(minuteOfDay: 17 * 60))    // half-open at end
        #expect(!work.contains(minuteOfDay: 8 * 60))     // before
        let night = DailyTimeWindow(fromHour: 22, 0, toHour: 7, 0)
        #expect(night.contains(minuteOfDay: 23 * 60))    // 23:00 — inside
        #expect(night.contains(minuteOfDay: 3 * 60))     // 03:00 — inside (wrapped)
        #expect(!night.contains(minuteOfDay: 12 * 60))   // noon — outside
        let empty = DailyTimeWindow(startMinute: 600, endMinute: 600)
        #expect(!empty.contains(minuteOfDay: 600))
    }

    @Test("A recurring daily (quiet-hours) window blocks by wall-clock time, every day")
    func dailyWindowPolicy() {
        let night = DailyTimeWindow(fromHour: 22, 0, toHour: 7, 0)
        let p = BlackoutPolicy(dailyWindows: [night])
        #expect(p.decide(source: .audio, at: at(2026, 5, 12, 23, 30), appContext: nil, calendar: utc) == .blocked(.dailyWindow(night)))
        #expect(p.decide(source: .audio, at: at(2026, 5, 13, 6, 0), appContext: nil, calendar: utc) == .blocked(.dailyWindow(night)))
        #expect(p.allows(source: .audio, at: at(2026, 5, 12, 13, 0), appContext: nil, calendar: utc))
    }

    @Test("A blocked bundle id suppresses screen/clipboard capture from that app — and only that app")
    func blockedApp() {
        let p = BlackoutPolicy(blockedBundleIDs: ["com.1password.1password"])
        let from1P = AppContext(bundleId: "com.1password.1password", windowTitle: "Vault")
        #expect(p.decide(source: .screen, at: Date(), appContext: from1P, calendar: utc) == .blocked(.blockedApp(bundleID: "com.1password.1password")))
        #expect(p.decide(source: .clipboard, at: Date(), appContext: from1P, calendar: utc).isBlocked)
        #expect(p.allows(source: .screen, at: Date(), appContext: AppContext(bundleId: "com.apple.Safari"), calendar: utc))
        // audio carries no AppContext → the app rule can't bite
        #expect(p.allows(source: .audio, at: Date(), appContext: nil, calendar: utc))
    }

    @Test("Bundle-id prefix matching covers a family of apps")
    func blockedPrefix() {
        let p = BlackoutPolicy(blockedBundleIDPrefixes: ["com.apple.keychainaccess"])
        #expect(p.decide(source: .screen, at: Date(), appContext: AppContext(bundleId: "com.apple.keychainaccess.helper"), calendar: utc).isBlocked)
        #expect(p.allows(source: .screen, at: Date(), appContext: AppContext(bundleId: "com.apple.notes"), calendar: utc))
    }

    @Test("Precedence: pause beats a time window beats a daily window beats the app block")
    func precedence() {
        let win = DateInterval(start: at(2026, 5, 12, 9, 0), end: at(2026, 5, 12, 10, 0))
        let p = BlackoutPolicy(
            paused: true, timeWindows: [win],
            dailyWindows: [DailyTimeWindow(fromHour: 0, 0, toHour: 23, 59)],
            blockedBundleIDs: ["x"]
        )
        // Everything would block; pause is reported first.
        #expect(p.decide(source: .screen, at: at(2026, 5, 12, 9, 30), appContext: AppContext(bundleId: "x"), calendar: utc) == .blocked(.globalPause))
    }
}
