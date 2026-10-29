import CoreGraphics
import Foundation

/// Where the recording overlay appears on screen.
enum OverlayPlacement: String, CaseIterable, Identifiable {
    /// Slim wings around the notch, flush with the menu bar.
    case menuBar
    /// Pill hanging below the menu bar.
    case dropDown
    /// Floating pill centered near the bottom of the screen.
    case bottom

    var id: String { rawValue }
}

/// Installs from before `overlay_placement` existed only saved the
/// `use_compact_overlay` toggle, so a missing placement falls back to it.
enum OverlayPlacementPreference {
    static let storageKey = "overlay_placement"
    static let legacyCompactStorageKey = "use_compact_overlay"

    /// Gap between the bottom pill and the bottom edge of the screen.
    static let bottomInset: CGFloat = 12

    static func load(from defaults: UserDefaults) -> OverlayPlacement {
        if let raw = defaults.string(forKey: storageKey),
           let placement = OverlayPlacement(rawValue: raw) {
            return placement
        }
        let useCompact = (defaults.object(forKey: legacyCompactStorageKey) as? Bool) ?? true
        return useCompact ? .menuBar : .dropDown
    }

    /// Frame for the bottom pill: horizontally centered, `bottomInset`
    /// points above the bottom edge.
    static func bottomFrame(size: CGSize, screenFrame: CGRect) -> CGRect {
        CGRect(
            x: screenFrame.midX - size.width / 2,
            y: screenFrame.minY + bottomInset,
            width: size.width,
            height: size.height
        )
    }
}

/// What pressing Escape does while FreeFlow is recording or transcribing.
enum EscapeKeyBehavior: String, CaseIterable, Identifiable {
    /// Stop and throw away the current recording or transcription.
    case discard
    /// Leave the recording running and let Escape reach the active app.
    case ignore

    var id: String { rawValue }

    var title: String {
        switch self {
        case .discard: return "Discard recording"
        case .ignore: return "Do nothing"
        }
    }
}

enum EscapeKeyPreference {
    static let storageKey = "escape_key_behavior"
    static let defaultBehavior: EscapeKeyBehavior = .discard

    static func load(from defaults: UserDefaults) -> EscapeKeyBehavior {
        defaults.string(forKey: storageKey).flatMap(EscapeKeyBehavior.init(rawValue:)) ?? defaultBehavior
    }
}
