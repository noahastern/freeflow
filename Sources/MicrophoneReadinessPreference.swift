import Foundation

/// How long the capture session stays running between dictations. A warm
/// session lets the next recording start without opening the device, at
/// the cost of macOS showing the microphone indicator while it is open.
/// Audio that arrives between recordings is dropped, never written or sent.
enum MicrophoneReadiness: String, CaseIterable, Identifiable {
    /// Open the microphone on each shortcut press and close it afterwards.
    case off
    /// Keep the microphone open for a while after each dictation.
    case afterUse
    /// Keep the microphone open whenever FreeFlow is running.
    case always

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return "Off"
        case .afterUse: return "After use"
        case .always: return "Always"
        }
    }
}

enum MicrophoneReadinessPreference {
    static let storageKey = "microphone_readiness"
    static let defaultReadiness: MicrophoneReadiness = .off
    /// Idle time after a dictation before an `afterUse` session is released.
    static let afterUseIdleTimeout: TimeInterval = 5 * 60

    static func load(from defaults: UserDefaults) -> MicrophoneReadiness {
        defaults.string(forKey: storageKey).flatMap(MicrophoneReadiness.init(rawValue:)) ?? defaultReadiness
    }

    /// A warm session is reused only while it is running uninterrupted on the
    /// device and audio API the next recording would open; anything else
    /// takes the cold path.
    static func canReuseWarmSession(
        isRunning: Bool,
        isInterrupted: Bool,
        warmDeviceUID: String?,
        resolvedDeviceUID: String?,
        warmBackend: AudioCaptureBackend?,
        requestedBackend: AudioCaptureBackend
    ) -> Bool {
        guard isRunning, !isInterrupted, let warmDeviceUID, let resolvedDeviceUID else {
            return false
        }
        return warmDeviceUID == resolvedDeviceUID && warmBackend == requestedBackend
    }
}
