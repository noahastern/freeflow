import SwiftUI
import AppKit

// MARK: - State

final class RecordingOverlayState: ObservableObject {
    @Published var phase: OverlayPhase = .recording
    @Published var recordingStartedAt: ContinuousClock.Instant?
    /// Freezes the elapsed timer once recording stops.
    @Published var recordingStoppedAt: ContinuousClock.Instant?
    @Published var showsRecordingTimer = RecordingTimerPreference.defaultEnabled
    @Published var audioLevel: Float = 0.0
    /// The pill shows on the shortcut press; the waveform stays flat until
    /// the microphone delivers its first real audio.
    @Published var isAwaitingAudio = false
    @Published var recordingTriggerMode: RecordingTriggerMode = .hold
    @Published var isCommandMode = false
    @Published var updateVersion: String = ""
    @Published var errorMessage: String?
    @Published var toastID: UUID?

    /// Tap-to-toggle recordings show a discard X and a finish checkmark;
    /// the panel only accepts clicks in that mode.
    var showsSessionControls: Bool {
        phase == .recording && recordingTriggerMode == .toggle
    }

    /// Recording and transcribing share one layout so the overlay keeps its
    /// shape: the waveform settles flat and a spinner takes the checkmark's place.
    var showsRecordingLayout: Bool {
        phase == .recording || phase == .transcribing
    }

    /// Tap-to-toggle recordings keep their control slots while transcribing.
    var reservesSessionControlSpace: Bool {
        showsRecordingLayout && recordingTriggerMode == .toggle
    }

    var isProcessing: Bool {
        phase == .transcribing
    }
}

enum OverlayPhase {
    case recording
    case transcribing
    case feedback
    case updateAvailable
}

// MARK: - NSScreen Helpers

extension NSScreen {
    /// CoreGraphics display identifier for this screen, or nil if the
    /// device description is missing the key (vanishingly rare). Stable
    /// across screen-arrangement changes for as long as the display is
    /// connected, which is what the overlay picker stores in UserDefaults.
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}

// MARK: - Panel Helpers

private func makeOverlayPanel(width: CGFloat, height: CGFloat) -> NSPanel {
    let panel = NSPanel(
        contentRect: NSRect(x: 0, y: 0, width: width, height: height),
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered,
        defer: false
    )
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = true
    panel.level = .screenSaver
    panel.ignoresMouseEvents = true
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.isReleasedWhenClosed = false
    panel.hidesOnDeactivate = false
    return panel
}

private func makeNotchContent<V: View>(
    width: CGFloat,
    height: CGFloat,
    cornerRadius: CGFloat,
    rootView: V
) -> NSView {
    let shaped = rootView
        .frame(width: width, height: height)
        .background(Color.black)
        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: cornerRadius, bottomTrailingRadius: cornerRadius))

    let hosting = NSHostingView(rootView: shaped)
    hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
    hosting.autoresizingMask = [.width, .height]
    return hosting
}

private func makeFloatingContent<V: View>(width: CGFloat, height: CGFloat, rootView: V) -> NSView {
    let shaped = rootView
        .frame(width: width, height: height)
        .background(Color.black)
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.3), lineWidth: 1))

    let hosting = NSHostingView(rootView: shaped)
    hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
    hosting.autoresizingMask = [.width, .height]
    return hosting
}

/// Filled circular button with a dark glyph, used for the discard X and
/// the finish checkmark at opposite ends of the overlay.
private struct RecordingControlButton: View {
    let systemName: String
    let diameter: CGFloat
    let fill: Color
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: diameter * 0.5, weight: .bold))
                .foregroundStyle(Color.black)
                .frame(width: diameter, height: diameter)
                .background(Circle().fill(fill))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct DiscardRecordingButton: View {
    let diameter: CGFloat
    let action: () -> Void

    var body: some View {
        RecordingControlButton(
            systemName: "xmark",
            diameter: diameter,
            fill: Color(white: 0.72),
            accessibilityLabel: "Discard recording",
            action: action
        )
    }
}

private struct FinishRecordingButton: View {
    let diameter: CGFloat
    let action: () -> Void

    var body: some View {
        RecordingControlButton(
            systemName: "checkmark",
            diameter: diameter,
            fill: Color.white,
            accessibilityLabel: "Finish recording",
            action: action
        )
    }
}

// MARK: - Manager

final class RecordingOverlayManager {
    private var overlayWindow: NSPanel?
    private let overlayState = RecordingOverlayState()
    private var lockedOverlayWidth: CGFloat?
    var onStopButtonPressed: (() -> Void)?
    var onCancelButtonPressed: (() -> Void)?
    var onUpdateOverlayPressed: (() -> Void)?

    /// The screen the overlay should drop down on. The user picks one of
    /// three modes in Settings, stored in UserDefaults under
    /// `overlay_display_id`:
    ///
    /// - `0` (default) — Active window: follows focus across monitors via
    ///   NSScreen.main. Default for backward compatibility — the original
    ///   behavior on a single-display setup is unchanged.
    /// - `-1` — Primary display: always NSScreen.screens.first (the display
    ///   designated as primary in System Settings → Displays).
    /// - any positive integer — specific NSScreen displayID. Falls back to
    ///   primary if that display is unplugged.
    private var targetScreen: NSScreen? {
        let savedID = UserDefaults.standard.integer(forKey: "overlay_display_id")
        switch savedID {
        case 0:
            return NSScreen.main ?? NSScreen.screens.first
        case -1:
            return NSScreen.screens.first ?? NSScreen.main
        default:
            if let match = NSScreen.screens.first(where: { Int($0.displayID ?? 0) == savedID }) {
                return match
            }
            return NSScreen.screens.first ?? NSScreen.main
        }
    }

    private var placement: OverlayPlacement {
        OverlayPlacementPreference.load(from: .standard)
    }

    /// The bottom pill floats free of the menu bar, so notch geometry
    /// only applies to the top placements.
    private var screenHasNotch: Bool {
        guard placement != .bottom, let screen = targetScreen else { return false }
        return screen.safeAreaInsets.top > 0
    }

    private var notchWidth: CGFloat {
        guard let screen = targetScreen, screenHasNotch else { return 0 }
        guard let leftArea = screen.auxiliaryTopLeftArea,
              let rightArea = screen.auxiliaryTopRightArea else { return 0 }
        return screen.frame.width - leftArea.width - rightArea.width
    }

    private var notchOverlap: CGFloat {
        guard let screen = targetScreen else { return 0 }
        return screen.frame.maxY - screen.visibleFrame.maxY
    }

    private var overlayAcceptsMouseEvents: Bool {
        (overlayState.phase == .recording && overlayState.recordingTriggerMode == .toggle)
            || overlayState.phase == .updateAvailable
    }

    func showRecording(
        mode: RecordingTriggerMode = .hold,
        isCommandMode: Bool = false,
        startedAt: ContinuousClock.Instant = .now,
        showsRecordingTimer: Bool,
        isAwaitingAudio: Bool = false
    ) {
        DispatchQueue.main.async {
            self.lockedOverlayWidth = nil
            self.overlayState.recordingTriggerMode = mode
            self.overlayState.isCommandMode = isCommandMode
            self.beginRecordingTimer(startedAt: startedAt, showsRecordingTimer: showsRecordingTimer)
            self.overlayState.isAwaitingAudio = isAwaitingAudio
            self.overlayState.phase = .recording
            self.overlayState.audioLevel = 0
            self.showOverlayPanel(animatedResize: true)
        }
    }

    /// Lets the waveform respond once the microphone is live, and restarts
    /// the timer from when capture actually began.
    func markAudioReady(startedAt: ContinuousClock.Instant) {
        DispatchQueue.main.async {
            guard self.overlayState.phase == .recording else { return }
            self.overlayState.recordingStartedAt = startedAt
            self.overlayState.isAwaitingAudio = false
        }
    }

    private func beginRecordingTimer(startedAt: ContinuousClock.Instant, showsRecordingTimer: Bool) {
        overlayState.showsRecordingTimer = showsRecordingTimer
        overlayState.recordingStartedAt = startedAt
        overlayState.recordingStoppedAt = nil
    }

    func setRecordingTriggerMode(_ mode: RecordingTriggerMode, animated: Bool) {
        DispatchQueue.main.async {
            self.overlayState.recordingTriggerMode = mode
            self.updateOverlayLayout(animated: animated)
        }
    }

    func updateAudioLevel(_ level: Float) {
        DispatchQueue.main.async {
            self.overlayState.audioLevel = level
        }
    }

    func showTranscribing() {
        DispatchQueue.main.async {
            self.setTranscribingPhase()
        }
    }

    func showFailureIndicator() {
        DispatchQueue.main.async {
            self.showFeedbackPanel()
        }
    }

    /// Maximum length of an in-pill error message. Anything longer is
    /// truncated with an ellipsis to keep the pill from stretching across
    /// the menu bar; the full text remains available in `os_log` for
    /// forensic review.
    private static let maxToastMessageLength = 90

    /// Surface a transient error in the menu-bar pill. The pill resizes to
    /// fit the message (subject to the truncation cap), holds for a few
    /// seconds, then dismisses. Intended for non-fatal user-facing errors
    /// that previously only landed in `os_log` — rate limits, network
    /// failures, permission gaps, etc.
    func showError(_ message: String) {
        let truncated: String = {
            if message.count <= Self.maxToastMessageLength { return message }
            let cutoff = message.index(message.startIndex, offsetBy: Self.maxToastMessageLength - 1)
            return String(message[..<cutoff]) + "…"
        }()
        DispatchQueue.main.async { [self] in
            let toastID = UUID()
            self.overlayState.errorMessage = truncated
            self.overlayState.toastID = toastID
            self.lockedOverlayWidth = nil
            self.overlayState.phase = .feedback
            self.showOverlayPanel(animatedResize: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) { [weak self] in
                guard let self else { return }
                guard self.overlayState.phase == .feedback,
                      self.overlayState.errorMessage == truncated,
                      self.overlayState.toastID == toastID else {
                    return
                }
                self.overlayState.errorMessage = nil
                self.overlayState.toastID = nil
                self.dismissAll()
            }
        }
    }

    func showUpdateAvailable(version: String) {
        DispatchQueue.main.async {
            self.lockedOverlayWidth = nil
            self.overlayState.isCommandMode = false
            self.overlayState.updateVersion = version
            self.overlayState.phase = .updateAvailable
            self.showOverlayPanel(animatedResize: true)
        }
    }

    func dismiss() {
        DispatchQueue.main.async {
            self.dismissAll()
        }
    }

    private func showOverlayPanel(animatedResize: Bool) {
        let frame = overlayFrame

        if let panel = overlayWindow {
            panel.ignoresMouseEvents = !overlayAcceptsMouseEvents
            panel.contentView = makeOverlayContent(frame: frame)
            resize(panel: panel, to: frame, animated: animatedResize)
            panel.alphaValue = 1
            panel.orderFrontRegardless()
            return
        }

        let panel = makeOverlayPanel(width: frame.width, height: frame.height)
        panel.hasShadow = false
        panel.ignoresMouseEvents = !overlayAcceptsMouseEvents
        panel.contentView = makeOverlayContent(frame: frame)

        guard let screen = targetScreen else { return }

        if placement == .bottom {
            // Rise and fade in from slightly below the resting position.
            panel.setFrame(frame.offsetBy(dx: 0, dy: -12), display: true)
            panel.alphaValue = 0
            panel.orderFrontRegardless()

            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.34, 1.56, 0.64, 1.0)
                panel.animator().setFrame(frame, display: true)
                panel.animator().alphaValue = 1
            }

            overlayWindow = panel
            return
        }

        let hiddenFrame = NSRect(x: frame.origin.x, y: screen.frame.maxY, width: frame.width, height: frame.height)
        panel.setFrame(hiddenFrame, display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.34, 1.56, 0.64, 1.0)
            panel.animator().setFrame(frame, display: true)
        }

        overlayWindow = panel
    }

    private func updateOverlayLayout(animated: Bool) {
        guard let panel = overlayWindow else { return }
        let frame = overlayFrame
        panel.ignoresMouseEvents = !overlayAcceptsMouseEvents
        panel.contentView = makeOverlayContent(frame: frame)
        resize(panel: panel, to: frame, animated: animated)
    }

    private func setTranscribingPhase() {
        lockedOverlayWidth = overlayWindow?.frame.width ?? overlayWidth
        overlayState.recordingStoppedAt = .now
        overlayState.isAwaitingAudio = false
        overlayState.phase = .transcribing

        // Keep the mounted view when the frame is unchanged so the waveform
        // settles and the spinner fades in place instead of being rebuilt.
        if let panel = overlayWindow, panel.frame.equalTo(overlayFrame) {
            panel.ignoresMouseEvents = !overlayAcceptsMouseEvents
            return
        }
        showOverlayPanel(animatedResize: true)
    }

    private func makeOverlayContent(frame: NSRect) -> NSView {
        let onStopButtonPressed: () -> Void = { [weak self] in
            self?.onStopButtonPressed?()
        }
        let onCancelButtonPressed: () -> Void = { [weak self] in
            self?.onCancelButtonPressed?()
        }

        if useWingedLayout {
            // Winged layout: notch x-range stays solid black so the cutout masks it.
            let rootView = WingedRecordingView(
                state: overlayState,
                leftWingWidth: activeWingWidth,
                notchWidth: notchWidth,
                rightWingWidth: activeWingWidth,
                height: frame.height,
                onStopButtonPressed: onStopButtonPressed,
                onCancelButtonPressed: onCancelButtonPressed
            )
            return makeNotchContent(
                width: frame.width,
                height: frame.height,
                cornerRadius: 14,
                rootView: AnyView(rootView)
            )
        }

        if placement == .bottom {
            return makeFloatingContent(
                width: frame.width,
                height: frame.height,
                rootView: BottomPillOverlayView(
                    state: overlayState,
                    onStopButtonPressed: onStopButtonPressed,
                    onCancelButtonPressed: onCancelButtonPressed,
                    onUpdateOverlayPressed: { [weak self] in
                        self?.onUpdateOverlayPressed?()
                    }
                )
            )
        }

        return makeNotchContent(
            width: frame.width,
            height: frame.height,
            cornerRadius: screenHasNotch ? 18 : 12,
            rootView: AnyView(
                RecordingOverlayView(
                    state: overlayState,
                    onStopButtonPressed: onStopButtonPressed,
                    onCancelButtonPressed: onCancelButtonPressed,
                    onUpdateOverlayPressed: { [weak self] in
                        self?.onUpdateOverlayPressed?()
                    }
                )
                .padding(.top, screenHasNotch ? notchOverlap : 0)
            )
        )
    }

    private func resize(panel: NSPanel, to frame: NSRect, animated: Bool) {
        guard animated else {
            panel.setFrame(frame, display: true)
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(frame, display: true)
        }
    }

    /// True iff the overlay renders as wings flanking the notch (notched display
    /// + menu-bar placement). updateAvailable and error toasts still use
    /// the drop-down pill.
    private var useWingedLayout: Bool {
        guard screenHasNotch, placement == .menuBar else { return false }
        switch overlayState.phase {
        case .recording, .transcribing:
            return true
        case .feedback:
            return overlayState.errorMessage?.isEmpty ?? true
        case .updateAvailable:
            return false
        }
    }

    /// Equal wings keep the overlay balanced around the camera cutout.
    /// Recording needs just enough room for the timer on the left, plus
    /// the X and checkmark at the outer edges in tap-to-toggle mode.
    private var activeWingWidth: CGFloat {
        let base: CGFloat = overlayState.showsRecordingLayout && overlayState.showsRecordingTimer ? 48 : 36
        return overlayState.reservesSessionControlSpace ? base + 22 : base
    }

    private var overlayFrame: NSRect {
        guard let screen = targetScreen else { return .zero }

        if useWingedLayout {
            // Anchor to the screen's auxiliary-area boundaries of the notch;
            // panel height matches the menu-bar overlap so nothing protrudes below.
            let nWidth = notchWidth
            let nLeftX = screen.auxiliaryTopLeftArea?.maxX
                ?? (screen.frame.midX - nWidth / 2)
            let leftWing = activeWingWidth
            let rightWing = activeWingWidth
            let panelHeight = notchOverlap
            let panelWidth = leftWing + nWidth + rightWing
            let panelX = nLeftX - leftWing
            let panelY = screen.frame.maxY - panelHeight
            return NSRect(x: panelX, y: panelY, width: panelWidth, height: panelHeight)
        }

        let width = overlayWidth

        if placement == .bottom {
            return OverlayPlacementPreference.bottomFrame(
                size: CGSize(width: width, height: BottomPillOverlayView.height),
                screenFrame: screen.frame
            )
        }

        let useCompact = placement == .menuBar
        let forceDropDownPill = overlayState.phase == .feedback
            && !(overlayState.errorMessage?.isEmpty ?? true)
        // Compact mode: overlay sits flush with the menu bar on every display.
        // notchOverlap equals the menu-bar height on non-notched screens too,
        // so zero protrusion is universal — not notch-only. The legacy
        // 38pt drop-down pill remains available when use_compact_overlay
        // is explicitly toggled off. Error toasts also force the drop-down
        // height so messages stay readable even when compact overlay is enabled.
        let height: CGFloat = (useCompact && !forceDropDownPill)
            ? notchOverlap
            : 38 + (screenHasNotch ? notchOverlap : 0)
        let x = screen.frame.midX - width / 2
        let y = screen.frame.maxY - height
        return NSRect(x: x, y: y, width: width, height: height)
    }

    private var overlayWidth: CGFloat {
        if placement == .bottom {
            return BottomPillOverlayView.width(for: overlayState)
        }

        if let lockedOverlayWidth, overlayState.phase == .transcribing {
            return lockedOverlayWidth
        }

        if overlayState.phase == .feedback {
            // Error toasts size to the message length so short messages do
            // not get the same wide pill as long ones. ~6.8pt per character
            // plus 60pt of icon and padding chrome, clamped to 180-420pt so
            // very short messages stay readable and very long ones do not
            // stretch the pill across the menu bar. Bare failure-X marker
            // (no message) keeps the original 92pt.
            let feedbackWidth: CGFloat = {
                guard let msg = overlayState.errorMessage, !msg.isEmpty else {
                    return 92
                }
                let estimated = CGFloat(msg.count) * 6.8 + 60
                return min(420, max(180, estimated))
            }()
            guard screenHasNotch else { return feedbackWidth }
            return max(notchWidth, feedbackWidth)
        }

        if overlayState.phase == .updateAvailable {
            let updateWidth: CGFloat = 190
            guard screenHasNotch else { return updateWidth }
            return max(notchWidth, updateWidth)
        }

        let commandModeWidth: CGFloat = 180
        let toggleWidth: CGFloat = 132
        let defaultWidth: CGFloat = 92
        let baseWidth: CGFloat

        if overlayState.isCommandMode {
            baseWidth = commandModeWidth
        } else if overlayState.reservesSessionControlSpace {
            baseWidth = toggleWidth
        } else {
            baseWidth = defaultWidth
        }

        // Reserve separate leading, center, and trailing slots while recording.
        // The X joins the leading slot in tap-to-toggle mode, so the slots
        // on both sides of the centered timer need more room.
        let timerWidth: CGFloat
        if overlayState.reservesSessionControlSpace {
            timerWidth = overlayState.isCommandMode ? 260 : 216
        } else {
            timerWidth = overlayState.isCommandMode ? 224 : 180
        }
        let width = overlayState.showsRecordingLayout && overlayState.showsRecordingTimer
            ? max(baseWidth, timerWidth)
            : baseWidth
        guard screenHasNotch else { return width }
        return max(notchWidth, width)
    }

    private func showFeedbackPanel() {
        lockedOverlayWidth = nil
        overlayState.phase = .feedback
        showOverlayPanel(animatedResize: true)
    }

    private func dismissAll() {
        lockedOverlayWidth = nil
        overlayState.recordingStartedAt = nil
        overlayState.recordingStoppedAt = nil
        overlayState.isAwaitingAudio = false
        overlayState.isCommandMode = false
        overlayState.updateVersion = ""
        if let panel = overlayWindow {
            panel.orderOut(nil)
            // orderOut alone leaves the panel retained in NSApp.windows with its
            // SwiftUI hierarchy mounted — repeatForever animations keep flushing
            // Core Animation forever. Unmount and close so the panel deallocates.
            panel.contentView = nil
            panel.close()
            overlayWindow = nil
        }
    }
}

// MARK: - Winged Recording View

/// Wing layout: timer (or waveform) left, stop button right, black notch in the middle
/// (the camera cutout masks those pixels).
struct WingedRecordingView: View {
    @ObservedObject var state: RecordingOverlayState
    let leftWingWidth: CGFloat
    let notchWidth: CGFloat
    let rightWingWidth: CGFloat
    let height: CGFloat
    let onStopButtonPressed: () -> Void
    let onCancelButtonPressed: () -> Void

    private let controlDiameter: CGFloat = 16
    private let controlEdgeInset: CGFloat = 8

    var body: some View {
        wingsHStack
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.spring(response: 0.28, dampingFraction: 1.0), value: state.phase)
    }

    private var wingsHStack: some View {
        HStack(spacing: 0) {
            // Left wing — empty during feedback so the right-wing X reads as the sole signal.
            HStack(spacing: 0) {
                if state.reservesSessionControlSpace {
                    DiscardRecordingButton(diameter: controlDiameter, action: onCancelButtonPressed)
                        .opacity(state.showsSessionControls ? 1 : 0.35)
                        .padding(.leading, controlEdgeInset)
                        .transition(.opacity)
                }
                Spacer(minLength: 0)
                Group {
                    if state.phase == .feedback {
                        Color.clear
                    } else if state.showsRecordingLayout {
                        VStack(spacing: 1) {
                            if state.isCommandMode {
                                Image(systemName: "pencil")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.92))
                                    .transition(.opacity)
                            }
                            if state.showsRecordingTimer, let start = state.recordingStartedAt {
                                RecordingElapsedTimeView(start: start, end: state.recordingStoppedAt)
                            } else {
                                CompactWaveformView(
                                    audioLevel: state.audioLevel,
                                    showsActivityPulse: true,
                                    isFlat: state.isAwaitingAudio || state.isProcessing,
                                    isDimmed: state.isProcessing
                                )
                            }
                        }
                        .transition(.opacity)
                    } else {
                        Color.clear
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(width: leftWingWidth, height: height)

            // Notch spacer — solid black; camera cutout hides it.
            Color.black
                .frame(width: notchWidth, height: height)

            // Right wing — finish checkmark at the outer edge, mirroring the
            // X, then the spinner in its place; or the failure X centered.
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                if state.phase == .feedback {
                    Image(systemName: "xmark")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 14, height: 14)
                        .background(Circle().fill(Color.red.opacity(0.92)))
                        .transition(.opacity)
                    Spacer(minLength: 0)
                } else if state.showsSessionControls {
                    FinishRecordingButton(diameter: controlDiameter, action: onStopButtonPressed)
                        .padding(.trailing, controlEdgeInset)
                        .transition(.opacity)
                } else if state.isProcessing {
                    ProcessingSpinner(diameter: 11, lineWidth: 1.75)
                        .frame(width: controlDiameter, height: controlDiameter)
                        .padding(.trailing, state.reservesSessionControlSpace ? controlEdgeInset : 0)
                        .transition(.opacity)
                    if !state.reservesSessionControlSpace {
                        Spacer(minLength: 0)
                    }
                }
            }
            .frame(width: rightWingWidth, height: height)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(response: 0.28, dampingFraction: 1.0), value: state.phase)
    }
}

// MARK: - Waveform Views

struct WaveformBar: View {
    let amplitude: CGFloat

    private let minHeight: CGFloat = 2
    private let maxHeight: CGFloat = 22

    var body: some View {
        Capsule()
            .fill(.white)
            .frame(width: 3, height: minHeight + (maxHeight - minHeight) * amplitude)
    }
}

struct WaveformView: View {
    let audioLevel: Float
    var showsActivityPulse = false
    /// Holds the bars flat: before the microphone is live and after recording stops.
    var isFlat = false
    /// Dims the bars once recording stops.
    var isDimmed = false

    private static let barCount = 9
    private static let multipliers: [CGFloat] = [0.35, 0.55, 0.75, 0.9, 1.0, 0.9, 0.75, 0.55, 0.35]
    private static let centerIndex = CGFloat((barCount - 1) / 2)

    var body: some View {
        Group {
            if showsActivityPulse {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: isFlat)) { context in
                    waveformBars(pulseTime: context.date.timeIntervalSinceReferenceDate)
                }
            } else {
                waveformBars(pulseTime: nil)
            }
        }
        .frame(height: 24)
        .opacity(isDimmed ? 0.5 : 1)
        .animation(.easeOut(duration: 0.3), value: isFlat)
        .animation(.easeOut(duration: 0.3), value: isDimmed)
    }

    private func waveformBars(pulseTime: TimeInterval?) -> some View {
        HStack(spacing: 2.5) {
            ForEach(0..<Self.barCount, id: \.self) { index in
                WaveformBar(amplitude: barAmplitude(for: index, pulseTime: pulseTime))
                    .animation(
                        .spring(
                            response: barResponse(for: index),
                            dampingFraction: 0.88
                        )
                        .delay(barDelay(for: index)),
                        value: audioLevel
                    )
            }
        }
    }

    private func barAmplitude(for index: Int, pulseTime: TimeInterval?) -> CGFloat {
        guard !isFlat else { return 0 }
        let level = CGFloat(max(audioLevel, 0))
        let baseAmplitude = min(level * Self.multipliers[index], 1.0)

        guard let pulseTime else { return baseAmplitude }

        let travelingWave = CGFloat(0.5 + 0.5 * sin((pulseTime * 6.2) - Double(index) * 0.78))
        let shimmer = CGFloat(0.5 + 0.5 * sin((pulseTime * 3.1) + Double(index) * 0.5))
        let pulse = travelingWave * 0.22 + shimmer * 0.06

        let saturationRelief = baseAmplitude * (0.74 + pulse)
        let quietPulse = (1.0 - baseAmplitude) * (0.04 + pulse * 0.28)
        return min(saturationRelief + quietPulse, 1.0)
    }

    private func barResponse(for index: Int) -> Double {
        let distance = abs(CGFloat(index) - Self.centerIndex)
        let normalizedDistance = distance / Self.centerIndex
        return 0.18 + Double(normalizedDistance) * 0.06
    }

    private func barDelay(for index: Int) -> Double {
        let distance = abs(CGFloat(index) - Self.centerIndex)
        return Double(distance) * 0.01
    }
}

/// Tighter 5-bar waveform sized for the 36pt wing layout.
struct CompactWaveformView: View {
    let audioLevel: Float
    var showsActivityPulse = false
    /// Holds the bars flat: before the microphone is live and after recording stops.
    var isFlat = false
    /// Dims the bars once recording stops.
    var isDimmed = false

    private static let barCount = 5
    private static let multipliers: [CGFloat] = [0.5, 0.75, 1.0, 0.75, 0.5]
    private static let centerIndex = CGFloat((barCount - 1) / 2)

    var body: some View {
        Group {
            if showsActivityPulse {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: isFlat)) { context in
                    bars(pulseTime: context.date.timeIntervalSinceReferenceDate)
                }
            } else {
                bars(pulseTime: nil)
            }
        }
        .frame(height: 18)
        .opacity(isDimmed ? 0.5 : 1)
        .animation(.easeOut(duration: 0.3), value: isFlat)
        .animation(.easeOut(duration: 0.3), value: isDimmed)
    }

    private func bars(pulseTime: TimeInterval?) -> some View {
        HStack(spacing: 1.5) {
            ForEach(0..<Self.barCount, id: \.self) { index in
                CompactWaveformBar(amplitude: amplitude(for: index, pulseTime: pulseTime))
                    .animation(
                        .spring(response: 0.18, dampingFraction: 0.88),
                        value: audioLevel
                    )
            }
        }
    }

    private func amplitude(for index: Int, pulseTime: TimeInterval?) -> CGFloat {
        guard !isFlat else { return 0 }
        let level = CGFloat(max(audioLevel, 0))
        let base = min(level * Self.multipliers[index], 1.0)
        guard let pulseTime else { return base }
        let traveling = CGFloat(0.5 + 0.5 * sin((pulseTime * 6.2) - Double(index) * 0.78))
        let shimmer = CGFloat(0.5 + 0.5 * sin((pulseTime * 3.1) + Double(index) * 0.5))
        let pulse = traveling * 0.22 + shimmer * 0.06
        let saturationRelief = base * (0.74 + pulse)
        let quietPulse = (1.0 - base) * (0.04 + pulse * 0.28)
        return min(saturationRelief + quietPulse, 1.0)
    }
}

struct CompactWaveformBar: View {
    let amplitude: CGFloat
    private let minHeight: CGFloat = 2
    private let maxHeight: CGFloat = 14

    var body: some View {
        Capsule()
            .fill(.white)
            .frame(width: 2, height: minHeight + (maxHeight - minHeight) * amplitude)
    }
}

/// One continuous spinner for the whole transcribe-and-clean-up step.
/// Rotation is driven by the timeline rather than a repeating animation so
/// it never inherits the layout springs around it.
struct ProcessingSpinner: View {
    let diameter: CGFloat
    let lineWidth: CGFloat

    var body: some View {
        TimelineView(.animation) { context in
            let degrees = (context.date.timeIntervalSinceReferenceDate * 450)
                .truncatingRemainder(dividingBy: 360)
            Circle()
                .trim(from: 0.1, to: 0.9)
                .stroke(Color.white, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .frame(width: diameter, height: diameter)
                .rotationEffect(.degrees(degrees))
        }
        .accessibilityLabel("Transcribing")
    }
}

struct RecordingOverlayView: View {
    @ObservedObject var state: RecordingOverlayState
    let onStopButtonPressed: () -> Void
    let onCancelButtonPressed: () -> Void
    let onUpdateOverlayPressed: () -> Void

    private let controlDiameter: CGFloat = 16

    private var leadingAccessoryWidth: CGFloat {
        let width: CGFloat = state.showsRecordingLayout && state.showsRecordingTimer
            ? (state.isCommandMode ? 72 : 48)
            : 24
        return state.reservesSessionControlSpace ? width + controlDiameter + 6 : width
    }
    private let trailingAccessoryWidth: CGFloat = 32

    var body: some View {
        Group {
            if state.phase == .feedback, let message = state.errorMessage {
                ErrorOverlayView(message: message)
            } else if state.phase == .feedback {
                FailureIndicatorView()
            } else if state.phase == .updateAvailable {
                UpdateAvailableOverlayView(onPress: onUpdateOverlayPressed)
            } else {
                ZStack {
                    Group {
                        if state.showsRecordingLayout {
                            if state.showsRecordingTimer, let start = state.recordingStartedAt {
                                RecordingElapsedTimeView(start: start, end: state.recordingStoppedAt)
                                    .transition(.opacity)
                            } else {
                                WaveformView(
                                    audioLevel: state.audioLevel,
                                    showsActivityPulse: true,
                                    isFlat: state.isAwaitingAudio || state.isProcessing,
                                    isDimmed: state.isProcessing
                                )
                                .transition(.opacity)
                            }
                        }
                    }

                    HStack {
                        HStack(spacing: 6) {
                            if state.reservesSessionControlSpace {
                                DiscardRecordingButton(diameter: controlDiameter, action: onCancelButtonPressed)
                                    .opacity(state.showsSessionControls ? 1 : 0.35)
                                    .transition(.opacity)
                            }
                            if state.showsRecordingLayout && state.showsRecordingTimer {
                                HStack(spacing: 6) {
                                    if state.isCommandMode {
                                        CommandModeIndicator()
                                    }
                                    WaveformView(
                                        audioLevel: state.audioLevel,
                                        showsActivityPulse: true,
                                        isFlat: state.isAwaitingAudio || state.isProcessing,
                                        isDimmed: state.isProcessing
                                    )
                                }
                                .transition(.opacity)
                            } else if state.isCommandMode {
                                CommandModeIndicator()
                                    .transition(.opacity)
                            }
                        }
                        .frame(
                            width: leadingAccessoryWidth,
                            alignment: state.reservesSessionControlSpace ? .leading : .center
                        )
                        .frame(maxHeight: .infinity, alignment: .center)

                        Spacer(minLength: 0)

                        Group {
                            if state.showsSessionControls {
                                FinishRecordingButton(diameter: controlDiameter, action: onStopButtonPressed)
                                    .transition(.opacity)
                            } else if state.isProcessing {
                                ProcessingSpinner(diameter: 12, lineWidth: 2)
                                    .frame(width: controlDiameter, height: controlDiameter)
                                    .transition(.opacity)
                            }
                        }
                        .frame(width: trailingAccessoryWidth, alignment: .trailing)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(response: 0.28, dampingFraction: 1.0), value: state.phase)
        .animation(.spring(response: 0.28, dampingFraction: 1.0), value: state.recordingTriggerMode)
        .animation(.spring(response: 0.28, dampingFraction: 1.0), value: state.isCommandMode)
    }
}

// MARK: - Bottom Pill View

/// Small floating pill: just the waveform, flanked by a discard X and a
/// finish checkmark in tap-to-toggle mode. While transcribing, the
/// waveform settles flat and a spinner sits where the checkmark was.
struct BottomPillOverlayView: View {
    @ObservedObject var state: RecordingOverlayState
    let onStopButtonPressed: () -> Void
    let onCancelButtonPressed: () -> Void
    let onUpdateOverlayPressed: () -> Void

    static let height: CGFloat = 28
    private static let horizontalPadding: CGFloat = 12
    private static let waveformSize = CGSize(width: 34, height: 18)
    private static let itemSpacing: CGFloat = 6
    /// Wider gap between each control and the waveform.
    private static let controlSpacing: CGFloat = 10
    private static let controlDiameter: CGFloat = 20
    /// Keeps each control concentric with the capsule's rounded end.
    private static let controlEdgePadding: CGFloat = (height - controlDiameter) / 2
    private static let commandIndicatorWidth: CGFloat = 16
    private static let timerWidth: CGFloat = 40

    /// Panel width for the current state; mirrors the layout in `body`.
    static func width(for state: RecordingOverlayState) -> CGFloat {
        switch state.phase {
        case .feedback:
            guard let message = state.errorMessage, !message.isEmpty else { return 60 }
            return min(420, max(180, CGFloat(message.count) * 6.8 + 60))
        case .updateAvailable:
            return 150
        case .recording, .transcribing:
            var content = waveformSize.width
            if state.isCommandMode { content += commandIndicatorWidth + itemSpacing }
            if state.showsRecordingTimer { content += timerWidth + itemSpacing }
            let controlSide = controlEdgePadding + controlDiameter + controlSpacing
            let leading = state.reservesSessionControlSpace ? controlSide : horizontalPadding
            let trailing = hasTrailingControl(state) ? controlSide : horizontalPadding
            return content + leading + trailing
        }
    }

    /// The checkmark while recording in tap-to-toggle mode, then the spinner.
    private static func hasTrailingControl(_ state: RecordingOverlayState) -> Bool {
        state.reservesSessionControlSpace || state.isProcessing
    }

    var body: some View {
        Group {
            switch state.phase {
            case .feedback:
                if let message = state.errorMessage {
                    ErrorOverlayView(message: message)
                        .padding(.horizontal, Self.horizontalPadding)
                } else {
                    FailureIndicatorView()
                }
            case .updateAvailable:
                UpdateAvailableOverlayView(onPress: onUpdateOverlayPressed)
                    .padding(.horizontal, Self.horizontalPadding)
            case .recording, .transcribing:
                recordingContent
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(response: 0.28, dampingFraction: 1.0), value: state.phase)
    }

    private var recordingContent: some View {
        HStack(spacing: Self.controlSpacing) {
            if state.reservesSessionControlSpace {
                DiscardRecordingButton(diameter: Self.controlDiameter, action: onCancelButtonPressed)
                    .opacity(state.showsSessionControls ? 1 : 0.35)
            }
            HStack(spacing: Self.itemSpacing) {
                if state.isCommandMode {
                    CommandModeIndicator()
                }
                WaveformView(
                    audioLevel: state.audioLevel,
                    showsActivityPulse: true,
                    isFlat: state.isAwaitingAudio || state.isProcessing,
                    isDimmed: state.isProcessing
                )
                .scaleEffect(0.72)
                .frame(width: Self.waveformSize.width, height: Self.waveformSize.height)
                if state.showsRecordingTimer, let start = state.recordingStartedAt {
                    RecordingElapsedTimeView(start: start, end: state.recordingStoppedAt)
                }
            }
            if state.showsSessionControls {
                FinishRecordingButton(diameter: Self.controlDiameter, action: onStopButtonPressed)
                    .transition(.opacity)
            } else if state.isProcessing {
                ProcessingSpinner(diameter: 14, lineWidth: 2)
                    .frame(width: Self.controlDiameter, height: Self.controlDiameter)
                    .transition(.opacity)
            }
        }
        .padding(.leading, state.reservesSessionControlSpace ? Self.controlEdgePadding : Self.horizontalPadding)
        .padding(.trailing, Self.hasTrailingControl(state) ? Self.controlEdgePadding : Self.horizontalPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The manager owns the start instant so rebuilding the overlay or switching
/// from hold to toggle mode cannot reset the elapsed time. A monotonic clock
/// also keeps system clock adjustments from changing the displayed duration.
private struct RecordingElapsedTimeView: View {
    let start: ContinuousClock.Instant
    var end: ContinuousClock.Instant?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let seconds = max(0, start.duration(to: end ?? .now).components.seconds)
            Text(String(format: "%lld:%02lld", seconds / 60, seconds % 60))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.9))
                .fixedSize()
                .frame(minWidth: 40)
                .accessibilityLabel("Recording duration")
                .accessibilityValue("\(seconds / 60) minutes, \(seconds % 60) seconds")
        }
    }
}

// MARK: - Transcribing Indicator

struct CommandModeIndicator: View {
    var body: some View {
        Image(systemName: "pencil")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white.opacity(0.92))
            .frame(width: 16, height: 16, alignment: .center)
    }
}

struct FailureIndicatorView: View {
    var body: some View {
        Image(systemName: "xmark")
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background(Circle().fill(Color.red.opacity(0.92)))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// In-pill error toast. Red exclamation icon plus the message text,
/// rendered inside the standard menu-bar pill. Sized by the manager's
/// `overlayWidth` based on message length.
struct ErrorOverlayView: View {
    let message: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color.red.opacity(0.92))
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

struct UpdateAvailableOverlayView: View {
    let onPress: () -> Void

    var body: some View {
        Button(action: onPress) {
            HStack(spacing: 7) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)

                Text("Update Available")
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .buttonStyle(.plain)
    }
}
