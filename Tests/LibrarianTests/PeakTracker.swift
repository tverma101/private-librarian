import Foundation

/// Thread-safe peak-concurrency tracker for scheduler tests.
final class PeakTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0
    private var maxSeen = 0

    func enter() -> Int {
        lock.lock()
        current += 1
        if current > maxSeen { maxSeen = current }
        let now = current
        lock.unlock()
        return now
    }

    func exit() {
        lock.lock()
        current -= 1
        lock.unlock()
    }

    func peak() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return maxSeen
    }
}
