import Foundation

enum EscapeUndoCoreTests {
    static func run() {
        testPolicySkipsShortEmptyAndCommandSessions()
        testUndoBeforeExpiryWithoutTranscriptTranscribes()
        testExpiryDiscardsPendingItem()
        testUndoAfterDeadlineDiscardsEvenIfTimerIsLate()
        testUndoWhileTranscriptionInFlightAwaitsIt()
        testUndoAfterTranscriptionFinishedReusesResult()
        testUndoAfterTranscriptionFailedTranscribesAgain()
        testNewRecordingSupersedesPendingItem()
        testBeginReplacesEarlierPendingItem()
        testStaleTranscriptionUpdatesAreIgnored()
        testUndoHandsOffSoLaterSupersedeKeepsIt()
    }

    // MARK: - Fakes

    private final class ManualClock {
        var current = Date(timeIntervalSinceReferenceDate: 1_000)
        func advance(_ seconds: TimeInterval) { current = current.addingTimeInterval(seconds) }
    }

    private final class ManualTimer: EscapeUndoTimer {
        let fireAt: Date
        let action: () -> Void
        private(set) var isCancelled = false
        init(fireAt: Date, action: @escaping () -> Void) {
            self.fireAt = fireAt
            self.action = action
        }
        func cancel() { isCancelled = true }
    }

    private final class ManualScheduler: EscapeUndoTimerScheduling {
        let clock: ManualClock
        private(set) var timers: [ManualTimer] = []
        init(clock: ManualClock) { self.clock = clock }

        func schedule(after delay: TimeInterval, _ action: @escaping () -> Void) -> EscapeUndoTimer {
            let timer = ManualTimer(fireAt: clock.current.addingTimeInterval(delay), action: action)
            timers.append(timer)
            return timer
        }

        /// Advances the clock and fires every live timer that is due.
        func advance(_ seconds: TimeInterval) {
            clock.advance(seconds)
            for timer in timers where !timer.isCancelled && timer.fireAt <= clock.current {
                timer.cancel()
                timer.action()
            }
        }

        var liveTimerCount: Int { timers.filter { !$0.isCancelled }.count }
    }

    /// Flattened effect so tests can compare with `==`.
    private enum Recorded: Equatable {
        case discard(String, EscapeUndoDiscardReason)
        case process(String, String)
        case await(String)
        case transcribe(String)
    }

    private struct Harness {
        let clock: ManualClock
        let scheduler: ManualScheduler
        let controller: EscapeUndoController<String>
        let effects: EffectLog
    }

    private final class EffectLog {
        var items: [Recorded] = []
    }

    private static func makeHarness() -> Harness {
        let clock = ManualClock()
        let scheduler = ManualScheduler(clock: clock)
        let controller = EscapeUndoController<String>(
            undoWindow: 5,
            now: { clock.current },
            scheduler: scheduler
        )
        let log = EffectLog()
        controller.onEffect = { effect in
            switch effect {
            case .discard(let payload, let reason): log.items.append(.discard(payload, reason))
            case .process(let payload, let raw): log.items.append(.process(payload, raw))
            case .awaitInFlightTranscription(let payload): log.items.append(.await(payload))
            case .transcribe(let payload): log.items.append(.transcribe(payload))
            }
        }
        return Harness(clock: clock, scheduler: scheduler, controller: controller, effects: log)
    }

    // MARK: - Tests

    private static func testPolicySkipsShortEmptyAndCommandSessions() {
        TestSupport.expect(
            !EscapeUndoPolicy.shouldOfferUndo(capturedDuration: nil, isCommandMode: false),
            "No captured audio means no toast"
        )
        TestSupport.expect(
            !EscapeUndoPolicy.shouldOfferUndo(capturedDuration: 0.2, isCommandMode: false),
            "Very short captures are discarded"
        )
        TestSupport.expect(
            EscapeUndoPolicy.shouldOfferUndo(capturedDuration: 0.5, isCommandMode: false),
            "Captures at the threshold are offered Undo"
        )
        TestSupport.expect(
            !EscapeUndoPolicy.shouldOfferUndo(capturedDuration: 30, isCommandMode: true),
            "Edit/command sessions are never offered Undo"
        )
    }

    private static func testUndoBeforeExpiryWithoutTranscriptTranscribes() {
        let h = makeHarness()
        h.controller.begin(payload: "a", transcript: .notRequested)
        TestSupport.expect(h.controller.hasPending, "Escape starts a pending item")
        TestSupport.expectEqual(h.scheduler.liveTimerCount, 1)

        h.scheduler.advance(4.9)
        TestSupport.expect(h.controller.undo(), "Undo inside the window succeeds")
        TestSupport.expectEqual(h.effects.items, [.transcribe("a")])
        TestSupport.expect(!h.controller.hasPending, "Undo hands the item off")
        TestSupport.expectEqual(h.scheduler.liveTimerCount, 0)

        h.scheduler.advance(10)
        TestSupport.expectEqual(h.effects.items, [.transcribe("a")])
        TestSupport.expect(!h.controller.undo(), "A second Undo is a no-op")
    }

    private static func testExpiryDiscardsPendingItem() {
        let h = makeHarness()
        h.controller.begin(payload: "a", transcript: .notRequested)
        h.scheduler.advance(4.99)
        TestSupport.expectEqual(h.effects.items, [])
        h.scheduler.advance(0.01)
        TestSupport.expectEqual(h.effects.items, [.discard("a", .expired)])
        TestSupport.expect(!h.controller.hasPending, "Expiry clears the item")
        TestSupport.expect(!h.controller.undo(), "Undo after expiry does nothing")
        TestSupport.expectEqual(h.effects.items, [.discard("a", .expired)])
    }

    private static func testUndoAfterDeadlineDiscardsEvenIfTimerIsLate() {
        let h = makeHarness()
        h.controller.begin(payload: "a", transcript: .finished("hello"))
        // Move the clock without firing the timer, as a busy main queue would.
        h.clock.advance(5)
        TestSupport.expect(!h.controller.undo(), "Undo at the deadline is refused")
        TestSupport.expectEqual(h.effects.items, [.discard("a", .expired)])
    }

    private static func testUndoWhileTranscriptionInFlightAwaitsIt() {
        let h = makeHarness()
        h.controller.begin(payload: "a", transcript: .inFlight)
        h.scheduler.advance(1)
        TestSupport.expect(h.controller.undo(), "Undo succeeds")
        TestSupport.expectEqual(h.effects.items, [.await("a")])
    }

    private static func testUndoAfterTranscriptionFinishedReusesResult() {
        let h = makeHarness()
        let id = h.controller.begin(payload: "a", transcript: .inFlight)
        h.controller.transcriptionFinished(id: id, rawTranscript: "synthetic words")
        TestSupport.expectEqual(h.controller.pending?.transcript, .finished("synthetic words"))
        h.controller.undo()
        TestSupport.expectEqual(h.effects.items, [.process("a", "synthetic words")])
    }

    private static func testUndoAfterTranscriptionFailedTranscribesAgain() {
        let h = makeHarness()
        let id = h.controller.begin(payload: "a", transcript: .inFlight)
        h.controller.transcriptionFailed(id: id)
        h.controller.undo()
        TestSupport.expectEqual(h.effects.items, [.transcribe("a")])
    }

    private static func testNewRecordingSupersedesPendingItem() {
        let h = makeHarness()
        h.controller.begin(payload: "a", transcript: .inFlight)
        h.scheduler.advance(2)
        h.controller.supersede()
        TestSupport.expectEqual(h.effects.items, [.discard("a", .superseded)])
        TestSupport.expectEqual(h.scheduler.liveTimerCount, 0)

        h.scheduler.advance(10)
        TestSupport.expectEqual(h.effects.items, [.discard("a", .superseded)])
        h.controller.supersede()
        TestSupport.expectEqual(h.effects.items.count, 1)
    }

    private static func testBeginReplacesEarlierPendingItem() {
        let h = makeHarness()
        h.controller.begin(payload: "a", transcript: .notRequested)
        h.scheduler.advance(3)
        h.controller.begin(payload: "b", transcript: .notRequested)
        TestSupport.expectEqual(h.effects.items, [.discard("a", .superseded)])

        // The first item's timer must not expire the second.
        h.scheduler.advance(2.5)
        TestSupport.expect(h.controller.hasPending, "Second item gets its own full window")
        h.scheduler.advance(2.5)
        TestSupport.expectEqual(h.effects.items, [.discard("a", .superseded), .discard("b", .expired)])
    }

    private static func testStaleTranscriptionUpdatesAreIgnored() {
        let h = makeHarness()
        let first = h.controller.begin(payload: "a", transcript: .inFlight)
        h.controller.begin(payload: "b", transcript: .notRequested)
        h.controller.transcriptionFinished(id: first, rawTranscript: "stale")
        TestSupport.expectEqual(h.controller.pending?.transcript, .notRequested)
        h.controller.transcriptionFailed(id: first)
        TestSupport.expectEqual(h.controller.pending?.transcript, .notRequested)

        // A finished transcript is never downgraded by a late failure.
        let third = h.controller.begin(payload: "c", transcript: .inFlight)
        h.controller.transcriptionFinished(id: third, rawTranscript: "kept")
        h.controller.transcriptionFailed(id: third)
        TestSupport.expectEqual(h.controller.pending?.transcript, .finished("kept"))
    }

    private static func testUndoHandsOffSoLaterSupersedeKeepsIt() {
        let h = makeHarness()
        h.controller.begin(payload: "a", transcript: .inFlight)
        h.controller.undo()
        h.controller.supersede()
        TestSupport.expectEqual(h.effects.items, [.await("a")])
    }
}
