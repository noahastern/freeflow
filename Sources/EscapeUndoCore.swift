import Foundation

// MARK: - Timer injection

/// Cancels a scheduled undo-window timer.
protocol EscapeUndoTimer: AnyObject {
    func cancel()
}

/// Schedules undo-window timers. The app uses the main queue; tests inject a
/// manual scheduler so expiry is deterministic.
protocol EscapeUndoTimerScheduling {
    func schedule(after delay: TimeInterval, _ action: @escaping () -> Void) -> EscapeUndoTimer
}

final class MainQueueEscapeUndoTimerScheduler: EscapeUndoTimerScheduling {
    private final class WorkItemTimer: EscapeUndoTimer {
        let workItem: DispatchWorkItem
        init(workItem: DispatchWorkItem) { self.workItem = workItem }
        func cancel() { workItem.cancel() }
    }

    func schedule(after delay: TimeInterval, _ action: @escaping () -> Void) -> EscapeUndoTimer {
        let workItem = DispatchWorkItem(block: action)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        return WorkItemTimer(workItem: workItem)
    }
}

// MARK: - Policy

/// Decides whether an Escape-cancelled dictation is worth offering Undo for.
enum EscapeUndoPolicy {
    /// How long the "Dictation cancelled — Undo" toast stays up.
    static let undoWindow: TimeInterval = 5
    /// Captures shorter than this are treated as accidental and discarded
    /// without a toast, matching the plain discard behavior.
    static let minimumCapturedDuration: TimeInterval = 0.5

    /// - Parameters:
    ///   - capturedDuration: Seconds of real audio captured, or nil when the
    ///     microphone never delivered audio.
    ///   - isCommandMode: Edit/command sessions transform selected text, so
    ///     they are never offered Undo; Escape discards them as before.
    static func shouldOfferUndo(capturedDuration: TimeInterval?, isCommandMode: Bool) -> Bool {
        guard !isCommandMode, let capturedDuration else { return false }
        return capturedDuration >= minimumCapturedDuration
    }
}

// MARK: - State machine

/// Where the raw transcript of a cancelled dictation stands.
enum CancelledTranscriptState: Equatable {
    /// Cancelled while recording; nothing was uploaded.
    case notRequested
    /// A transcription request was already in flight when Escape was pressed.
    case inFlight
    /// The in-flight request finished; its result is held in memory.
    case finished(String)
    /// The in-flight request failed; Undo transcribes the audio again.
    case failed
}

/// What the app must do in response to a state change.
enum EscapeUndoEffect<Payload> {
    /// The undo window closed (expired or superseded); delete the audio.
    case discard(Payload, reason: EscapeUndoDiscardReason)
    /// Undo was pressed and the raw transcript is already available.
    case process(Payload, rawTranscript: String)
    /// Undo was pressed while the original transcription is still running;
    /// await that request instead of uploading again.
    case awaitInFlightTranscription(Payload)
    /// Undo was pressed and no usable transcript exists; transcribe the audio.
    case transcribe(Payload)
}

enum EscapeUndoDiscardReason: Equatable {
    case expired
    case superseded
}

/// Pure, clock-injected state machine for Escape-then-Undo. Holds at most one
/// cancelled dictation. Once Undo is pressed the item is handed off to the
/// app (via an effect) and the controller returns to idle, so a later
/// recording can never drop work the user already asked to keep.
final class EscapeUndoController<Payload> {
    struct Pending {
        let id: UInt64
        let cancelledAt: Date
        let expiresAt: Date
        let payload: Payload
        var transcript: CancelledTranscriptState
    }

    private let undoWindow: TimeInterval
    private let now: () -> Date
    private let scheduler: EscapeUndoTimerScheduling
    private var expiryTimer: EscapeUndoTimer?
    private var nextID: UInt64 = 1

    private(set) var pending: Pending?
    var onEffect: ((EscapeUndoEffect<Payload>) -> Void)?

    init(
        undoWindow: TimeInterval = EscapeUndoPolicy.undoWindow,
        now: @escaping () -> Date = Date.init,
        scheduler: EscapeUndoTimerScheduling
    ) {
        self.undoWindow = undoWindow
        self.now = now
        self.scheduler = scheduler
    }

    var hasPending: Bool { pending != nil }

    /// Starts the undo window for a cancelled dictation. Any earlier pending
    /// item is discarded first. Returns the id used for later updates.
    @discardableResult
    func begin(payload: Payload, transcript: CancelledTranscriptState) -> UInt64 {
        supersede()
        let id = nextID
        nextID += 1
        let cancelledAt = now()
        pending = Pending(
            id: id,
            cancelledAt: cancelledAt,
            expiresAt: cancelledAt.addingTimeInterval(undoWindow),
            payload: payload,
            transcript: transcript
        )
        expiryTimer = scheduler.schedule(after: undoWindow) { [weak self] in
            self?.expire(id: id)
        }
        return id
    }

    /// Records that the in-flight transcription for `id` finished.
    func transcriptionFinished(id: UInt64, rawTranscript: String) {
        guard var current = pending, current.id == id, current.transcript == .inFlight else { return }
        current.transcript = .finished(rawTranscript)
        pending = current
    }

    /// Records that the in-flight transcription for `id` failed.
    func transcriptionFailed(id: UInt64) {
        guard var current = pending, current.id == id, current.transcript == .inFlight else { return }
        current.transcript = .failed
        pending = current
    }

    /// Handles a click on Undo. Returns false when nothing was pending or the
    /// window had already closed (a late click after a delayed timer).
    @discardableResult
    func undo() -> Bool {
        guard let current = pending else { return false }
        guard now() < current.expiresAt else {
            expire(id: current.id)
            return false
        }
        clear()
        switch current.transcript {
        case .finished(let rawTranscript):
            onEffect?(.process(current.payload, rawTranscript: rawTranscript))
        case .inFlight:
            onEffect?(.awaitInFlightTranscription(current.payload))
        case .notRequested, .failed:
            onEffect?(.transcribe(current.payload))
        }
        return true
    }

    /// Drops the pending item because a new dictation is starting.
    func supersede() {
        guard let current = pending else { return }
        clear()
        onEffect?(.discard(current.payload, reason: .superseded))
    }

    /// Timer callback; also reachable from `undo()` after the deadline.
    func expire(id: UInt64) {
        guard let current = pending, current.id == id else { return }
        clear()
        onEffect?(.discard(current.payload, reason: .expired))
    }

    private func clear() {
        expiryTimer?.cancel()
        expiryTimer = nil
        pending = nil
    }
}
