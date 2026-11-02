import AppKit
import ApplicationServices
import Foundation
import os.log

private let correctionWatchLog = OSLog(subsystem: "com.zachlatta.freeflow", category: "CorrectionWatch")

/// Watches the field a dictation was just inserted into and reports when the user fixes a
/// misrecognized word there. Main thread only.
///
/// Privacy boundary: the field value is read through Accessibility once per poll, used to
/// find the dictated region, and dropped before the poll returns. Only hashed anchors, a
/// hash of the last region, and at most one pending heard/meant pair outlive a poll, and
/// only in memory for the life of the watch. Logs carry reason codes, never text.
final class CorrectionWatcher {
    enum StopReason: String {
        case learned
        case timeout
        case focusLost
        case appSwitched
        case newDictation
        case disabled
        case notTrusted
        case excludedApp
        case unreadable
        case fieldTooLarge
        case insertionNotFound
        case regionLost
        case regionAmbiguous
    }

    struct Timing {
        var armingInterval: TimeInterval = 0.25
        var armingTimeout: TimeInterval = 3
        var pollInterval: TimeInterval = 1
        var maxDuration: TimeInterval = 30
    }

    private struct Session {
        let id = UUID()
        let insertedText: String
        let startedAt: Date
        var target: AppTextInsertionTarget?
        var anchors: CorrectionAnchors?
        var progress: CorrectionWatchProgress
    }

    var isEnabled: () -> Bool = { false }
    var knownPairs: () -> VocabularyCorrectionCore.KnownPairs = { .init() }
    var onCorrection: (_ heard: String, _ meant: String) -> Void = { _, _ in }

    private let timing: Timing
    private var session: Session?
    private var timer: Timer?

    init(timing: Timing = Timing()) {
        self.timing = timing
    }

    /// Starts watching for edits of `insertedText`. Never prompts for Accessibility; when
    /// it is not trusted, or the setting is off, nothing happens.
    func start(insertedText: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        stop(.newDictation)
        guard isEnabled() else { return }
        guard AXIsProcessTrusted() else {
            log(.notTrusted)
            return
        }
        let trimmed = insertedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf16.count <= CorrectionRegionCore.maxFieldLength else { return }
        session = Session(
            insertedText: trimmed,
            startedAt: Date(),
            progress: CorrectionWatchProgress(insertedFingerprint: CorrectionRegionCore.regionFingerprint(trimmed))
        )
        schedule(after: timing.armingInterval)
    }

    /// Ends the watch. A fix that was stable before the stop is still learned, unless the
    /// setting was turned off.
    func stop(_ reason: StopReason) {
        timer?.invalidate()
        timer = nil
        guard let ending = session else { return }
        session = nil
        if reason != .disabled, isEnabled(),
           let pair = ending.progress.pairOnStop(isTimeout: reason == .timeout) {
            log(.learned)
            onCorrection(pair.heard, pair.meant)
            return
        }
        log(reason)
    }

    private func schedule(after interval: TimeInterval) {
        timer?.invalidate()
        let sessionID = session?.id
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            guard let self, self.session?.id == sessionID else { return }
            self.tick()
        }
    }

    private func tick() {
        guard var current = session else { return }
        guard isEnabled() else { return stop(.disabled) }
        guard AXIsProcessTrusted() else { return stop(.notTrusted) }

        guard let target = current.target, let anchors = current.anchors else {
            return arm(current)
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier else {
            return stop(.appSwitched)
        }
        guard target.isFocusedInApplication else { return stop(.focusLost) }

        // The field value and the region text live only inside this closure.
        let known = knownPairs()
        let insertedText = current.insertedText
        var progress = current.progress
        let result: Result<CorrectionWatchProgress.Decision, StopError> = {
            guard let value = target.readTextForObservation() else { return .failure(StopError(.unreadable)) }
            guard value.utf16.count <= CorrectionRegionCore.maxFieldLength else {
                return .failure(StopError(.fieldTooLarge))
            }
            switch CorrectionRegionCore.extractRegion(from: value, anchors: anchors) {
            case .failure(.prefixAmbiguous), .failure(.suffixAmbiguous):
                return .failure(StopError(.regionAmbiguous))
            case .failure(.fieldTooLarge):
                return .failure(StopError(.fieldTooLarge))
            case .failure:
                return .failure(StopError(.regionLost))
            case .region(let range):
                let region = (value as NSString).substring(with: range)
                return .success(progress.observe(regionFingerprint: CorrectionRegionCore.regionFingerprint(region)) {
                    VocabularyCorrectionCore.evaluate(inserted: insertedText, edited: region, known: known)
                })
            }
        }()
        current.progress = progress
        session = current

        switch result {
        case .failure(let error):
            stop(error.reason)
        case .success(.learn):
            stop(.learned)
        case .success(.keepWatching):
            if Date().timeIntervalSince(current.startedAt) >= timing.maxDuration {
                stop(.timeout)
            } else {
                schedule(after: timing.pollInterval)
            }
        }
    }

    private struct StopError: Error {
        let reason: StopReason
        init(_ reason: StopReason) { self.reason = reason }
    }

    /// Waits for the inserted text to show up at the caret of the focused field, then
    /// records hashed anchors around it.
    private func arm(_ current: Session) {
        let elapsed = Date().timeIntervalSince(current.startedAt)
        let retry: (StopReason) -> Void = { reason in
            if elapsed + self.timing.armingInterval > self.timing.armingTimeout {
                self.stop(reason)
            } else {
                self.schedule(after: self.timing.armingInterval)
            }
        }
        guard let app = NSWorkspace.shared.frontmostApplication else { return retry(.insertionNotFound) }
        guard !CorrectionRegionCore.isExcluded(bundleIdentifier: app.bundleIdentifier) else { return stop(.excludedApp) }
        guard let target = AppTextInsertionTarget.captureForObservation(
            from: AXUIElementCreateApplication(app.processIdentifier), processIdentifier: app.processIdentifier
        ) else { return retry(.unreadable) }
        target.limitMessagingTimeout(seconds: 0.5)

        let anchors: CorrectionAnchors? = {
            guard let value = target.readTextForObservation(),
                  value.utf16.count <= CorrectionRegionCore.maxFieldLength,
                  let range = CorrectionRegionCore.locateInsertion(
                      of: current.insertedText, in: value, caret: target.readCaretForObservation()
                  ) else { return nil }
            return CorrectionRegionCore.makeAnchors(value: value, insertedRange: range)
        }()
        guard let anchors else { return retry(.insertionNotFound) }
        var armed = current
        armed.target = target
        armed.anchors = anchors
        session = armed
        schedule(after: timing.pollInterval)
    }

    private func log(_ reason: StopReason) {
        os_log(.info, log: correctionWatchLog, "correction watch ended: %{public}@", reason.rawValue)
    }
}
