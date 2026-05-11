// An injectable time source. Blackout windows, quiet hours, day-bucket
// rollups, and reminders all need testable time — never call `Date()` directly.

import Foundation

public protocol TimeProvider: Sendable {
    func now() -> Date
}

/// Wall-clock time. Production default.
public struct SystemClock: TimeProvider {
    public init() {}
    public func now() -> Date { Date() }
}

/// A clock you can set/advance. For tests.
public final class FixedClock: TimeProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    public init(_ start: Date) { self.current = start }

    public func now() -> Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    public func set(_ date: Date) {
        lock.lock(); defer { lock.unlock() }
        current = date
    }

    public func advance(by interval: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        current = current.addingTimeInterval(interval)
    }
}
