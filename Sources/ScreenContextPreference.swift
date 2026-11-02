import Foundation
import os

/// Whether each dictation takes a window screenshot and asks the context model
/// for a summary. Off keeps only local app metadata (name, bundle ID, window
/// title) for per-app styles, so no screenshot is taken and nothing is sent.
enum ScreenContextPreference {
    static let storageKey = "screen_context_enabled"
    static let defaultEnabled = true

    /// Returns the default-on choice for missing or invalid values without persisting it.
    static func load(from defaults: UserDefaults) -> Bool {
        (defaults.object(forKey: storageKey) as? Bool) ?? defaultEnabled
    }

    static func save(_ enabled: Bool, to defaults: UserDefaults) {
        defaults.set(enabled, forKey: storageKey)
    }
}

/// Bounds how long cleanup waits for an in-flight context capture once the
/// transcript is ready. The context model call can take many seconds; past the
/// deadline cleanup proceeds with whatever cheap local context exists.
enum ContextWaitRace {
    static let defaultDeadline: TimeInterval = 0.15

    typealias Sleep = @Sendable (TimeInterval) async -> Void

    static let realSleep: Sleep = { seconds in
        try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }

    /// The operation's value if it finishes before `deadline`, otherwise nil.
    /// Returns as soon as either side finishes; the losing side keeps running
    /// unstructured, so callers cancel the underlying work themselves.
    static func value<Value: Sendable>(
        of operation: @escaping @Sendable () async -> Value?,
        deadline: TimeInterval,
        sleep: @escaping Sleep = realSleep
    ) async -> Value? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Value?, Never>) in
            let gate = ResumeOnce(continuation)
            let timer = Task {
                await sleep(deadline)
                gate.resume(nil)
            }
            Task {
                let value = await operation()
                gate.resume(value)
                timer.cancel()
            }
        }
    }

    private final class ResumeOnce<Value: Sendable>: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock<CheckedContinuation<Value?, Never>?>(initialState: nil)

        init(_ continuation: CheckedContinuation<Value?, Never>) {
            lock.withLock { $0 = continuation }
        }

        func resume(_ value: Value?) {
            let continuation = lock.withLock { state -> CheckedContinuation<Value?, Never>? in
                defer { state = nil }
                return state
            }
            continuation?.resume(returning: value)
        }
    }
}
