import Foundation

/// How much cleanup the LLM applies to a dictation. `none` is the former
/// "Preserve exact wording" toggle, so that key is still written for builds
/// that only know the toggle. `medium` adds nothing to the system prompt.
enum CleanupLevel: String, CaseIterable, Identifiable {
    case none
    case light
    case medium

    static let storageKey = "cleanup_level"
    static let legacyPreserveExactWordingKey = "preserve_exact_wording"
    static let defaultLevel: CleanupLevel = .medium

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "None"
        case .light: return "Light"
        case .medium: return "Medium"
        }
    }

    var summary: String {
        switch self {
        case .none:
            return "Skips the LLM and pastes the transcript verbatim: filler words, informal phrasing, and explicit language are kept. Voice macros and Edit Mode still run. If Output Language is set, the transcript is translated literally."
        case .light:
            return "Removes ums, uhs, and stutters, and fixes punctuation and layout. Keeps your phrasing, including words like \"like\" and \"you know\"."
        case .medium:
            return "Also removes filler words and false starts and fixes grammar, while keeping your meaning and tone."
        }
    }

    /// Appended to the cleanup system prompt; empty when the base prompt already
    /// describes the level.
    var promptSection: String {
        switch self {
        case .none, .medium:
            return ""
        case .light:
            return """
Cleanup level: Light. Where this conflicts with the filler rules above, this wins.
- Keep the speaker's wording, phrasing, and sentence structure. Do not rephrase, reorder, shorten, or fix grammar beyond obvious speech-to-text mistakes.
- Remove only hesitation sounds such as "um", "uh", "er", and "hmm", plus stutters and immediately repeated words.
- Keep discourse words and verbal habits such as "like", "you know", "I mean", "so", "basically", and "actually".
- Still apply self-corrections, punctuation, capitalization, and paragraph breaks.
"""
        }
    }

    static func load(from defaults: UserDefaults) -> CleanupLevel {
        if let raw = defaults.string(forKey: storageKey), let level = CleanupLevel(rawValue: raw) {
            return level
        }
        return defaults.bool(forKey: legacyPreserveExactWordingKey) ? .none : defaultLevel
    }

    func save(to defaults: UserDefaults) {
        defaults.set(rawValue, forKey: Self.storageKey)
        defaults.set(self == .none, forKey: Self.legacyPreserveExactWordingKey)
    }
}
