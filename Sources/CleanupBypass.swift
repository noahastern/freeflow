import Foundation

/// Decides when a dictation is short and clean enough that the cleanup LLM
/// would return it unchanged, so the request can be skipped. Every rule leans
/// toward running cleanup: a missed skip costs one request, a wrong skip pastes
/// text the user expected to be fixed.
enum CleanupBypass {
    static let maxWords = 6

    struct Settings: Equatable {
        var cleanupLevel: CleanupLevel
        var outputLanguage: String = ""
        /// The configured dictation language name; "" means auto-detect.
        var dictationLanguage: String = ""
        var isEditMode: Bool = false
        var pressesEnterAfterPaste: Bool = false
        var customSystemPrompt: String = ""
        var formattingPrompt: String = ""
        /// Resolved with `styleAllowsVerbatim` for the destination app.
        var styleAllowsVerbatim: Bool = true
        var vocabularyTerms: [String] = []
    }

    static func canSkipCleanup(transcript: String, settings: Settings) -> Bool {
        // `none` already skips the LLM through its own path.
        guard settings.cleanupLevel != .none,
              settings.outputLanguage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              ["", "english"].contains(settings.dictationLanguage.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()),
              !settings.isEditMode,
              !settings.pressesEnterAfterPaste,
              settings.customSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              settings.formattingPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              settings.styleAllowsVerbatim else {
            return false
        }
        return isAlreadyClean(transcript)
            && !nearMatchesVocabulary(transcript, terms: settings.vocabularyTerms)
    }

    /// Only styles whose cleanup leaves a short, punctuated sentence as is.
    /// Casual tones drop the final period, Very Casual lowercases, Excited adds
    /// exclamation marks, email and code apply layout rules, and a custom
    /// instruction could ask for anything.
    static func styleAllowsVerbatim(
        bundleIdentifier: String?,
        windowTitle: String?,
        settings: AppStyleSettings
    ) -> Bool {
        guard settings.isEnabled else { return true }
        let category = AppStyleResolver.category(
            bundleIdentifier: bundleIdentifier,
            windowTitle: windowTitle,
            assignments: settings.appAssignments
        )
        switch category {
        case .email, .coding:
            return false
        case .messaging, .aiAssistant, .documents, .general:
            break
        }
        guard !settings.isCustomized(category) else { return false }
        let tone = settings.tone(for: category)
        return tone == nil || tone == .formal
    }

    // MARK: Transcript rules

    private static let fillerWords: Set<String> = [
        "um", "umm", "uh", "uhh", "uhm", "er", "erm", "ah", "hmm", "hm", "mm", "mhm",
        "like", "basically", "literally"
    ]

    /// Openers the cleanup prompt drops when more words follow.
    private static let fillerOpeners: Set<String> = ["so", "well", "yeah"]

    private static let correctionWords: Set<String> = [
        "actually", "wait", "sorry", "rather", "rephrase", "scratch",
        // Romanian, Spanish, and French markers from the cleanup prompt.
        "nu", "stai", "fapt", "perdón", "perdon", "non"
    ]

    /// Spoken punctuation, layout, and symbols that cleanup converts.
    private static let spokenSymbolWords: Set<String> = [
        "comma", "period", "colon", "semicolon", "dash", "hyphen", "underscore", "slash",
        "backslash", "newline", "paragraph", "emoji", "quote", "unquote", "paren",
        "parenthesis", "parentheses", "bracket", "asterisk", "hashtag", "dot", "ellipsis",
        "exclamation", "apostrophe", "ampersand", "percent"
    ]

    /// Spelled numbers are rewritten as digits.
    private static let numberWords: Set<String> = [
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
        "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen",
        "eighteen", "nineteen", "twenty", "thirty", "forty", "fifty", "sixty", "seventy",
        "eighty", "ninety", "hundred", "thousand", "million", "billion", "first", "second",
        "third", "half", "quarter"
    ]

    private static let informalContractions: Set<String> = ["gonna", "wanna", "gotta", "kinda", "sorta"]

    private static let fillerPhrases = [
        "you know", "i mean", "okay so", "ok so", "so yeah", "sort of", "kind of", "or something", "or whatever", "and stuff",
        "scratch that", "or rather", "let me rephrase", "de fapt", "new line", "question mark"
    ]

    private static let allowedPunctuation: Set<Character> = [".", ",", "?", "!", "'", "-"]
    private static let terminalPunctuation: Set<Character> = [".", "?", "!"]

    static func isAlreadyClean(_ transcript: String) -> Bool {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = text.last, terminalPunctuation.contains(last),
              !text.contains(where: \.isNewline) else { return false }

        // Plain ASCII letters, digits, spaces, and basic sentence punctuation
        // only. The word rules below are English; accented text, quotes,
        // symbols, dashes, and emoji may all be reformatted by cleanup.
        for character in text {
            let isPlain = (character.isASCII && (character.isLetter || character.isNumber))
                || character == " " || allowedPunctuation.contains(character)
            guard isPlain else { return false }
        }

        let rawWords = text.split(separator: " ").map(String.init)
        guard (1...maxWords).contains(rawWords.count) else { return false }

        // Every sentence starts with a capital letter.
        var expectsCapital = true
        for character in text {
            if character.isLetter {
                if expectsCapital && !character.isUppercase { return false }
                expectsCapital = false
            } else if terminalPunctuation.contains(character) {
                expectsCapital = true
            }
        }

        let words = rawWords.map(normalizedWord).filter { !$0.isEmpty }
        guard !words.isEmpty else { return false }
        for (index, word) in words.enumerated() {
            if fillerWords.contains(word) || correctionWords.contains(word)
                || spokenSymbolWords.contains(word) || numberWords.contains(word)
                || informalContractions.contains(word) {
                return false
            }
            if index > 0 && words[index - 1] == word { return false }
        }
        if words.count > 1, fillerOpeners.contains(words[0]) { return false }
        // A bare "no" is an answer; inside a sentence it may be a correction.
        if words.count > 1, words.contains("no") { return false }

        let phraseText = " " + words.joined(separator: " ") + " "
        return !fillerPhrases.contains { phraseText.contains(" \($0) ") }
    }

    private static func normalizedWord(_ word: String) -> String {
        word.lowercased().trimmingCharacters(in: CharacterSet.letters.union(.decimalDigits).union(CharacterSet(charactersIn: "'")).inverted)
    }

    // MARK: Vocabulary

    /// True when any vocabulary term appears, or nearly appears, in the
    /// transcript, so cleanup should get the chance to fix its spelling.
    static func nearMatchesVocabulary(_ transcript: String, terms: [String]) -> Bool {
        let words = transcript
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
        guard !words.isEmpty else { return false }
        for term in terms {
            let key = compactKey(term)
            guard !key.isEmpty else { continue }
            let tolerance = key.count <= 3 ? 0 : (key.count <= 6 ? 1 : 2)
            for start in words.indices {
                var candidate = ""
                for end in start..<min(words.count, start + 3) {
                    candidate += words[end]
                    if abs(candidate.count - key.count) <= tolerance,
                       editDistance(candidate, key, limit: tolerance) <= tolerance {
                        return true
                    }
                }
            }
        }
        return false
    }

    private static func compactKey(_ value: String) -> String {
        String(value.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    /// Levenshtein distance, stopping early once it exceeds `limit`.
    static func editDistance(_ lhs: String, _ rhs: String, limit: Int) -> Int {
        let a = Array(lhs), b = Array(rhs)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = Array(repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            var rowMinimum = current[0]
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                rowMinimum = min(rowMinimum, current[j])
            }
            if rowMinimum > limit { return rowMinimum }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}
