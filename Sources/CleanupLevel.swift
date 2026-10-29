import Foundation

/// How much cleanup the LLM applies to a dictation. `none` is the former
/// "Preserve exact wording" toggle, so that key is still written for builds
/// that only know the toggle. `medium` adds nothing to the system prompt.
/// Levels follow Wispr Flow's Auto Cleanup: `high` tightens and polishes the
/// wording, while every level below it keeps the speaker's own words.
enum CleanupLevel: String, CaseIterable, Identifiable {
    case none
    case light
    case medium
    case high

    static let storageKey = "cleanup_level"
    static let legacyPreserveExactWordingKey = "preserve_exact_wording"
    static let defaultLevel: CleanupLevel = .medium

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "None"
        case .light: return "Light"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }

    var summary: String {
        switch self {
        case .none:
            return "Skips the LLM and pastes the transcript verbatim: filler words, informal phrasing, and explicit language are kept. Voice macros and Edit Mode still run. If Output Language is set, the transcript is translated literally."
        case .light:
            return "Removes ums, uhs, and stutters, and fixes punctuation and layout. Keeps your phrasing, including words like \"like\" and \"you know\"."
        case .medium:
            return "Also removes filler words and false starts, fixes grammar, writes numbers as digits, and turns spoken lists into lists, while keeping your wording and tone."
        case .high:
            return "Also tightens your wording for clarity and brevity: cuts rambling, repetition, and empty hedges, and polishes sentences, while keeping every point you made."
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
Cleanup level: Light. Where this conflicts with the rules above, this wins.
- Keep the speaker's wording, phrasing, and sentence structure. Do not rephrase, reorder, shorten, or fix grammar beyond obvious speech-to-text mistakes.
- Remove only hesitation sounds such as "um", "uh", "er", and "hmm", plus stutters and immediately repeated words.
- Keep discourse words and verbal habits such as "like", "you know", "I mean", "so", "basically", and "actually".
- Do not turn spoken items into a list unless the speaker asks for one, and keep "gonna" and "wanna" as spoken.
- Still apply self-corrections, punctuation, capitalization, numbers, and paragraph breaks.
"""
        case .high:
            return """
Cleanup level: High. Where this conflicts with the rules above about keeping the speaker's wording, this wins.
- Rewrite for clarity, brevity, and polish, the way the speaker would after rereading and editing their own draft. You may replace, reorder, and combine the speaker's words to do this.
- Keep every fact, request, question, name, number, date, and decision, in the order given. Never drop a point to make the text shorter, and never add one.
- Cut rambling and repetition: wind-up phrases such as "so what I was thinking is", "I just wanted to say that", and "the thing is"; hedges that add nothing, such as "I guess", "I feel like", and "maybe kind of"; points said twice; and closing restatements of what was already said.
- Merge fragments into complete, well-formed sentences, and tighten wordy phrasing: "at this point in time" -> "now", "in order to" -> "to".
- Keep the speaker's voice and point of view: first person stays first person, casual stays casual, and questions stay questions. Do not make it more formal than the destination calls for.
- In prompts for AI assistants and code editors, tighten the wording but keep every requirement, constraint, and detail.
- Example of required behavior:
  - "so um what I was thinking is that maybe we could like push the meeting to Thursday because I'm kind of swamped on Wednesday and also I think Sarah is out on Wednesday too so yeah Thursday would probably be better" -> "Could we push the meeting to Thursday? I'm swamped on Wednesday, and I think Sarah is out too."
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
