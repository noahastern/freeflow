import Foundation

/// Which Apple audio API opens the microphone. Both write the same 16 kHz
/// mono recording; they differ in how quickly capture starts on a press.
enum AudioCaptureBackend: String, CaseIterable, Identifiable {
    /// AVCaptureSession: the original path, built for camera and mic capture.
    case captureSession
    /// AVAudioEngine with a sink node: a lighter path closer to Core Audio
    /// that receives the device's own small I/O buffers.
    case audioEngine

    var id: String { rawValue }

    var title: String {
        switch self {
        case .captureSession: return "Capture Session"
        case .audioEngine: return "Audio Engine"
        }
    }
}

enum AudioCaptureBackendPreference {
    static let storageKey = "audio_capture_backend"
    static let defaultBackend: AudioCaptureBackend = .captureSession

    static func load(from defaults: UserDefaults) -> AudioCaptureBackend {
        defaults.string(forKey: storageKey).flatMap(AudioCaptureBackend.init(rawValue:)) ?? defaultBackend
    }
}
