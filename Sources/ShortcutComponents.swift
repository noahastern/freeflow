import SwiftUI
import AppKit

struct DictationShortcutEditor: View {
    @EnvironmentObject var appState: AppState

    let showsIntroText: Bool
    let onCaptureStateChange: ((Bool) -> Void)?

    @State private var activeCaptureRole: ShortcutRole?
    @State private var holdValidationMessage: String?
    @State private var toggleValidationMessage: String?
    @State private var copyAgainValidationMessage: String?

    init(showsIntroText: Bool = true, onCaptureStateChange: ((Bool) -> Void)? = nil) {
        self.showsIntroText = showsIntroText
        self.onCaptureStateChange = onCaptureStateChange
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if showsIntroText {
                Text("Pick a key for each action, or record your own. Pressing the tap shortcut while holding the hold shortcut latches into tap mode.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if appState.holdShortcut.isDisabled && appState.toggleShortcut.isDisabled {
                Label("Both dictation shortcuts are disabled.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            ShortcutRoleSection(
                role: .hold,
                selection: appState.holdShortcut,
                validationMessage: holdValidationMessage,
                isCapturing: Binding(
                    get: { activeCaptureRole == .hold },
                    set: { activeCaptureRole = $0 ? .hold : nil }
                ),
                onSelect: { binding in
                    holdValidationMessage = appState.setShortcut(binding, for: .hold)
                }
            )

            ShortcutRoleSection(
                role: .toggle,
                selection: appState.toggleShortcut,
                validationMessage: toggleValidationMessage,
                isCapturing: Binding(
                    get: { activeCaptureRole == .toggle },
                    set: { activeCaptureRole = $0 ? .toggle : nil }
                ),
                onSelect: { binding in
                    toggleValidationMessage = appState.setShortcut(binding, for: .toggle)
                }
            )

            ShortcutRoleSection(
                role: .copyAgain,
                selection: appState.copyAgainShortcut,
                validationMessage: copyAgainValidationMessage,
                isCapturing: Binding(
                    get: { activeCaptureRole == .copyAgain },
                    set: { activeCaptureRole = $0 ? .copyAgain : nil }
                ),
                onSelect: { binding in
                    copyAgainValidationMessage = appState.setShortcut(binding, for: .copyAgain)
                }
            )

            if appState.usesFnShortcut {
                Text("Tip: If Fn opens the Emoji picker, go to System Settings > Keyboard and change \"Press fn key to\" to \"Do Nothing\".")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .onChange(of: activeCaptureRole) { role in
            onCaptureStateChange?(role != nil)
        }
        .onDisappear {
            onCaptureStateChange?(false)
        }
    }
}

struct ShortcutRoleSection: View {
    @EnvironmentObject var appState: AppState
    let role: ShortcutRole
    let selection: ShortcutBinding
    let validationMessage: String?
    @Binding var isCapturing: Bool
    let onSelect: (ShortcutBinding) -> Void

    private static let disabledTag = "disabled"
    private static let customTag = "custom"
    private static let recordTag = "record"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(role.title)
                        .font(.body.weight(.medium))
                    Text(role.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                Picker(role.title, selection: pickerSelection) {
                    Text("Disabled").tag(Self.disabledTag)
                    Divider()
                    ForEach(ShortcutPreset.allCases) { preset in
                        Text(preset.title).tag(preset.rawValue)
                    }
                    if let customBinding {
                        Divider()
                        Text(customBinding.displayName).tag(Self.customTag)
                    }
                    Divider()
                    Text(customBinding == nil ? "Record Custom…" : "Record New Custom…").tag(Self.recordTag)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 210)
                .disabled(isCapturing)
            }

            if isCapturing {
                ShortcutRecorderPanel(
                    isCapturing: $isCapturing,
                    onCapture: onSelect
                )
            }

            if let validationMessage, !validationMessage.isEmpty {
                Label(validationMessage, systemImage: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    /// The custom shortcut offered in the menu: the active one if it is custom,
    /// otherwise the last one the user recorded for this role.
    private var customBinding: ShortcutBinding? {
        selection.isCustom ? selection : appState.savedCustomShortcut(for: role)
    }

    private var pickerSelection: Binding<String> {
        Binding(
            get: {
                if selection.isDisabled { return Self.disabledTag }
                if let preset = selection.preset { return preset.rawValue }
                return Self.customTag
            },
            set: { tag in
                switch tag {
                case Self.disabledTag:
                    onSelect(.disabled)
                case Self.customTag:
                    if let customBinding { onSelect(customBinding) }
                case Self.recordTag:
                    isCapturing = true
                default:
                    if let preset = ShortcutPreset(rawValue: tag) {
                        onSelect(preset.binding)
                    }
                }
            }
        )
    }
}

private struct ShortcutRecorderPanel: View {
    @Binding var isCapturing: Bool
    let onCapture: (ShortcutBinding) -> Void

    @State private var captureBackend: LocalShortcutCaptureBackend?
    @State private var captureInputState = ShortcutInputState()
    @State private var currentBinding: ShortcutBinding?

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "keyboard")
                .foregroundStyle(.blue)

            VStack(alignment: .leading, spacing: 2) {
                Text(currentBinding?.displayName ?? "Press the shortcut you want…")
                    .font(currentBinding == nil ? .body : .system(.body, design: .monospaced).weight(.semibold))
                Text(currentBinding == nil
                    ? "Regular keys, modifier-only shortcuts, and modifier combos all work."
                    : "Press Enter or Esc to save, or keep pressing to change it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Cancel") {
                cancelCapture()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            Button("Save") {
                finishCapture()
            }
            .buttonStyle(.borderedProminent)
            .disabled(currentBinding == nil)
        }
        .padding(12)
        .background(Color.blue.opacity(0.08))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.blue.opacity(0.6), lineWidth: 1)
        )
        .onAppear {
            startCapture()
        }
        .onDisappear {
            stopCapture(clearCaptureState: true)
        }
    }

    private func startCapture() {
        stopCapture(clearCaptureState: false)
        isCapturing = true
        captureInputState = ShortcutInputState()
        currentBinding = nil

        let backend = LocalShortcutCaptureBackend()
        backend.onInputEvent = { inputEvent in
            let result = ShortcutMatcher.reduce(
                state: captureInputState,
                event: inputEvent,
                configuration: .disabled
            )
            captureInputState = result.state

            guard case .modifierChanged(let keyCode, _) = inputEvent else { return }
            if let binding = ShortcutBinding.fromModifierKeyCode(
                keyCode,
                pressedModifierKeyCodes: captureInputState.pressedModifierKeyCodes,
                allowBareModifier: true
            ) {
                currentBinding = binding
            }
        }
        backend.onKeyDownEvent = { event in
            let isReturnKey = event.keyCode == 36 || event.keyCode == 76
            let hasPendingCapture = currentBinding != nil

            if isReturnKey && hasPendingCapture {
                finishCapture()
                return
            }
            if event.keyCode == 53 && hasPendingCapture {
                finishCapture()
                return
            }

            guard !ShortcutBinding.modifierKeyCodes.contains(event.keyCode) else {
                return
            }

            guard let binding = ShortcutBinding.from(
                event: event,
                pressedModifierKeyCodes: captureInputState.pressedModifierKeyCodes
            ) else {
                return
            }

            currentBinding = binding
        }
        backend.start()
        captureBackend = backend
    }

    private func finishCapture() {
        guard let currentBinding else {
            cancelCapture()
            return
        }
        onCapture(currentBinding)
        stopCapture(clearCaptureState: true)
    }

    private func cancelCapture() {
        stopCapture(clearCaptureState: true)
    }

    private func stopCapture(clearCaptureState: Bool) {
        captureBackend?.stop()
        captureBackend = nil
        captureInputState = ShortcutInputState()
        currentBinding = nil
        if clearCaptureState {
            isCapturing = false
        }
    }
}
