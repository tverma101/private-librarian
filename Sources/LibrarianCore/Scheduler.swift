import Foundation

/// Central resource-aware scheduler (plan §30).
/// LIGHT: metadata/hash/text — many at once.
/// MEDIUM: OCR/embedding — 1-2.
/// HEAVY: speech/video/LLM — 1.
/// Responds to macOS memory pressure by shrinking concurrency.
public final class Scheduler: @unchecked Sendable {

    public enum JobClass: String, Sendable {
        case light, medium, heavy

        func maxConcurrent(base: Int) -> Int {
            switch self {
            case .light: return base
            case .medium: return max(1, min(2, base / 4))
            case .heavy: return 1
            }
        }
    }

    private let lock = NSLock()
    private var running: [JobClass: Int] = [.light: 0, .medium: 0, .heavy: 0]
    private var waiters: [(JobClass, () throws -> Void)] = []
    private var pressureLevel: Int = 0 // 0 normal, 1 warning, 2 critical

    /// Base parallelism from active core count.
    private let baseConcurrency: Int

    public init() {
        baseConcurrency = max(2, ProcessInfo.processInfo.activeProcessorCount)
        Self.installMemoryPressureHandler { [weak self] level in
            self?.lock.lock()
            self?.pressureLevel = level
            self?.lock.unlock()
        }
    }

    static func installMemoryPressureHandler(_ onChange: @escaping (Int) -> Void) {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global(qos: .utility))
        source.setEventHandler {
            let level: Int = source.data.contains(.critical) ? 2 : (source.data.contains(.warning) ? 1 : 0)
            onChange(level)
        }
        source.resume()
        // Retain forever; this is a process-lifetime monitor.
        pressureSourceRetain.append(source)
    }
    nonisolated(unsafe) static var pressureSourceRetain: [DispatchSourceMemoryPressure] = []

    func allowedConcurrent(for cls: JobClass) -> Int {
        let cap = cls.maxConcurrent(base: baseConcurrency)
        switch pressureLevel {
        case 2: return cls == .heavy ? 0 : 1   // critical: only one job of any class
        case 1: return max(1, cap / 2)
        default: return cap
        }
    }

    /// Run `body` under the class's concurrency limit. Blocks the calling
    /// thread while waiting for a slot (callers are worker threads).
    public func perform<T>(as cls: JobClass, _ body: () throws -> T) rethrows -> T {
        acquire(cls)
        defer { release(cls) }
        return try body()
    }

    public func performAsync<T>(as cls: JobClass, _ body: @escaping () throws -> T) async throws -> T {
        return try await withCheckedThrowingContinuation { cont in
            enqueue(cls) {
                do { cont.resume(returning: try body()) }
                catch { cont.resume(throwing: error) }
            }
        }
    }

    private func enqueue(_ cls: JobClass, _ body: @escaping () throws -> Void) {
        lock.lock()
        waiters.append((cls, body))
        lock.unlock()
        drain()
    }
    private func acquire(_ cls: JobClass) {
        while true {
            lock.lock()
            if running[cls]! < allowedConcurrent(for: cls) {
                running[cls]! += 1
                lock.unlock()
                return
            }
            lock.unlock()
            usleep(20_000)
        }
    }

    private func release(_ cls: JobClass) {
        lock.lock()
        running[cls]! -= 1
        lock.unlock()
        drain()
    }

    private func drain() {
        lock.lock()
        guard !waiters.isEmpty else { lock.unlock(); return }
        // Start every waiter whose class now has capacity.
        var remaining: [(JobClass, () throws -> Void)] = []
        for (cls, body) in waiters {
            if running[cls]! < allowedConcurrent(for: cls) {
                running[cls]! += 1
                DispatchQueue.global(qos: .userInitiated).async {
                    do { try body() }
                    catch { /* job errors surface via their own channels */ }
                    self.lock.lock()
                    self.running[cls]! -= 1
                    self.lock.unlock()
                    self.drain()
                }
            } else {
                remaining.append((cls, body))
            }
        }
        waiters = remaining
        lock.unlock()
    }
}
