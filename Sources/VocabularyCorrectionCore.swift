import Foundation

/// One word of dictated or edited text, with its UTF-16 position in the source string.
/// Leading and trailing punctuation is excluded so "Netties," and "Netties" compare equal.
struct CorrectionToken: Equatable {
    let text: String
    let range: NSRange
}

/// Decides whether a user's edit of freshly inserted dictation is a misrecognition fix
/// worth learning. Pure and deterministic: it sees only the inserted text and the edited
/// region, never the rest of the field, and has no side effects.
enum VocabularyCorrectionCore {
    enum Outcome: Equatable {
        case candidate(heard: String, meant: String)
        case none(reason: Reason)
    }

    /// Reason codes are safe to log; they never carry text.
    enum Reason: String, Equatable {
        case empty
        case tooLong
        case unchanged
        case insertion
        case deletion
        case multipleHunks
        case hunkTooLarge
        case rewording
        case tooShort
        case notWords
        case urlOrEmail
        case notSimilar
        case inflection
        case commonWordSwap
        case caseChangeOfCommonWord
        case alreadyLearned
        case previouslyRemoved
    }

    /// Keys of pairs the store already knows. Removed pairs stay suppressed after Undo.
    struct KnownPairs: Equatable {
        var learned: Set<String> = []
        var removed: Set<String> = []

        static func key(heard: String, meant: String) -> String {
            normalizedPhrase(heard) + "\u{1F}" + normalizedPhrase(meant)
        }
    }

    static let maxOriginalHunkTokens = 3
    static let maxReplacementHunkTokens = 2
    static let minimumMeantLength = 3
    static let maxRewordingFraction = 0.4
    /// Short dictations are judged as if they had this many words, so fixing one word of
    /// a two-word dictation is not mistaken for rewording.
    static let rewordingDenominatorFloor = 5
    static let maxSimilarityDistance = 0.5
    static let maxTokens = 2_000

    // MARK: - Evaluation

    /// Compares the inserted dictation with the user's edited version of that region.
    /// Words typed after the end of the dictation are treated as continued typing and ignored.
    static func evaluate(inserted: String, edited: String, known: KnownPairs = KnownPairs()) -> Outcome {
        let original = tokenize(inserted)
        let revised = tokenize(edited)
        guard !original.isEmpty else { return .none(reason: .empty) }
        guard original.count <= maxTokens, revised.count <= maxTokens else { return .none(reason: .tooLong) }

        let originalWords = original.map(\.text)
        let revisedWords = revised.map(\.text)
        // Several end points can tie when the user also kept typing; prefer one that
        // yields a learnable fix, otherwise report the longest alignment's reason.
        var firstOutcome: Outcome?
        for end in tiedAlignmentEnds(original: originalWords, edited: revisedWords) {
            let outcome = evaluate(
                hunks: alignmentHunks(original: originalWords, edited: revisedWords, editedEnd: end),
                original: original, revised: revised, inserted: inserted, edited: edited, known: known
            )
            if case .candidate = outcome { return outcome }
            if firstOutcome == nil { firstOutcome = outcome }
        }
        return firstOutcome ?? .none(reason: .unchanged)
    }

    private static func evaluate(
        hunks: [Hunk], original: [CorrectionToken], revised: [CorrectionToken],
        inserted: String, edited: String, known: KnownPairs
    ) -> Outcome {
        guard !hunks.isEmpty else { return .none(reason: .unchanged) }
        let changedOriginalTokens = hunks.reduce(0) { $0 + $1.original.count }
        let denominator = max(original.count, rewordingDenominatorFloor)
        if Double(changedOriginalTokens) / Double(denominator) > maxRewordingFraction {
            return .none(reason: .rewording)
        }
        guard hunks.count == 1, let hunk = hunks.first else { return .none(reason: .multipleHunks) }
        guard !hunk.original.isEmpty else { return .none(reason: .insertion) }
        guard !hunk.edited.isEmpty else { return .none(reason: .deletion) }
        guard hunk.original.count <= maxOriginalHunkTokens,
              hunk.edited.count <= maxReplacementHunkTokens else {
            return .none(reason: .hunkTooLarge)
        }

        let heard = span(of: original, indices: hunk.original, in: inserted)
        let meant = span(of: revised, indices: hunk.edited, in: edited)
        return judge(heard: heard, meant: meant, known: known)
    }

    /// Applies the acceptance rules to one substitution.
    static func judge(heard: String, meant: String, known: KnownPairs = KnownPairs()) -> Outcome {
        guard heard != meant else { return .none(reason: .unchanged) }
        guard meant.count >= minimumMeantLength else { return .none(reason: .tooShort) }
        guard meant.contains(where: \.isLetter), heard.contains(where: \.isLetter) else {
            return .none(reason: .notWords)
        }
        guard !looksLikeURLOrEmail(meant), !looksLikeURLOrEmail(heard) else {
            return .none(reason: .urlOrEmail)
        }

        let heardLower = heard.lowercased()
        let meantLower = meant.lowercased()
        if heardLower == meantLower {
            guard isMixedCase(meant) || !allCommonWords(meant) else {
                return .none(reason: .caseChangeOfCommonWord)
            }
        } else {
            guard !isInflection(heardLower, meantLower) else { return .none(reason: .inflection) }
            guard !(allCommonWords(heard) && allCommonWords(meant)) else {
                return .none(reason: .commonWordSwap)
            }
            guard soundsOrLooksAlike(heard, meant) else { return .none(reason: .notSimilar) }
        }

        let key = KnownPairs.key(heard: heard, meant: meant)
        if known.removed.contains(key) { return .none(reason: .previouslyRemoved) }
        if known.learned.contains(key) { return .none(reason: .alreadyLearned) }
        return .candidate(heard: heard, meant: meant)
    }

    // MARK: - Tokenizing

    /// Splits on whitespace and trims edge punctuation; offsets are UTF-16 so they line up
    /// with Accessibility ranges even around emoji and CJK text.
    static func tokenize(_ text: String) -> [CorrectionToken] {
        var tokens: [CorrectionToken] = []
        var index = text.startIndex
        while index < text.endIndex {
            while index < text.endIndex, text[index].isWhitespace { index = text.index(after: index) }
            guard index < text.endIndex else { break }
            var end = index
            while end < text.endIndex, !text[end].isWhitespace { end = text.index(after: end) }

            var coreStart = index
            var coreEnd = end
            while coreStart < coreEnd, isEdgePunctuation(text[coreStart]) {
                coreStart = text.index(after: coreStart)
            }
            while coreEnd > coreStart, isEdgePunctuation(text[text.index(before: coreEnd)]) {
                coreEnd = text.index(before: coreEnd)
            }
            if coreStart < coreEnd {
                tokens.append(CorrectionToken(
                    text: String(text[coreStart..<coreEnd]),
                    range: NSRange(coreStart..<coreEnd, in: text)
                ))
            }
            index = end
        }
        return tokens
    }

    private static func isEdgePunctuation(_ character: Character) -> Bool {
        guard !character.isLetter, !character.isNumber else { return false }
        return character.isPunctuation || character.isSymbol
    }

    private static func span(of tokens: [CorrectionToken], indices: [Int], in text: String) -> String {
        guard let first = indices.first, let last = indices.last else { return "" }
        let start = tokens[first].range.location
        let end = NSMaxRange(tokens[last].range)
        return (text as NSString).substring(with: NSRange(location: start, length: end - start))
    }

    // MARK: - Alignment

    struct Hunk: Equatable {
        var original: [Int]
        var edited: [Int]
    }

    private static func distanceTable(original: [String], edited: [String]) -> [[Int]] {
        let n = original.count
        let m = edited.count
        var distance = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in 0...n { distance[i][0] = i }
        for j in 0...m { distance[0][j] = j }
        if n > 0 && m > 0 {
            for i in 1...n {
                for j in 1...m {
                    let substitution = distance[i - 1][j - 1] + (original[i - 1] == edited[j - 1] ? 0 : 1)
                    distance[i][j] = min(substitution, distance[i - 1][j] + 1, distance[i][j - 1] + 1)
                }
            }
        }
        return distance
    }

    /// Edited-prefix lengths with the cheapest alignment, longest first. Words after the
    /// chosen end are continued typing and cost nothing.
    static func tiedAlignmentEnds(original: [String], edited: [String]) -> [Int] {
        let lastRow = distanceTable(original: original, edited: edited)[original.count]
        let best = lastRow.min() ?? 0
        return lastRow.indices.filter { lastRow[$0] == best }.reversed()
    }

    /// Word-level Levenshtein alignment of `original` against `edited[..<editedEnd]`
    /// (all of `edited` when nil), grouping adjacent non-matching operations into hunks.
    static func alignmentHunks(original: [String], edited: [String], editedEnd: Int? = nil) -> [Hunk] {
        let n = original.count
        let distance = distanceTable(original: original, edited: edited)
        var j = min(editedEnd ?? edited.count, edited.count)
        var i = n

        enum Operation { case match, substitute, delete, insert }
        var operations: [(Operation, Int?, Int?)] = []
        while i > 0 || j > 0 {
            if i > 0, j > 0, original[i - 1] == edited[j - 1], distance[i][j] == distance[i - 1][j - 1] {
                operations.append((.match, i - 1, j - 1)); i -= 1; j -= 1
            } else if i > 0, j > 0, distance[i][j] == distance[i - 1][j - 1] + 1 {
                operations.append((.substitute, i - 1, j - 1)); i -= 1; j -= 1
            } else if i > 0, distance[i][j] == distance[i - 1][j] + 1 {
                operations.append((.delete, i - 1, nil)); i -= 1
            } else {
                operations.append((.insert, nil, j - 1)); j -= 1
            }
        }

        var hunks: [Hunk] = []
        var current: Hunk?
        for (operation, originalIndex, editedIndex) in operations.reversed() {
            if operation == .match {
                if let finished = current { hunks.append(finished) }
                current = nil
                continue
            }
            var hunk = current ?? Hunk(original: [], edited: [])
            if let originalIndex { hunk.original.append(originalIndex) }
            if let editedIndex { hunk.edited.append(editedIndex) }
            current = hunk
        }
        if let finished = current { hunks.append(finished) }
        return hunks
    }

    // MARK: - Similarity

    /// Sound-alike or look-alike: a close spelling, or the same consonant skeleton.
    static func soundsOrLooksAlike(_ heard: String, _ meant: String) -> Bool {
        let a = Array(heard.lowercased().filter { !$0.isWhitespace })
        let b = Array(meant.lowercased().filter { !$0.isWhitespace })
        guard !a.isEmpty, !b.isEmpty else { return false }
        let normalized = Double(editDistance(a, b)) / Double(max(a.count, b.count))
        if normalized <= maxSimilarityDistance { return true }
        let heardKey = consonantSkeleton(heard)
        return heardKey.count >= 2 && heardKey == consonantSkeleton(meant)
    }

    static func editDistance<T: Equatable>(_ a: [T], _ b: [T]) -> Int {
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var previous = Array(0...b.count)
        var current = Array(repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                current[j] = min(
                    previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1),
                    previous[j] + 1,
                    current[j - 1] + 1
                )
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    /// An in-house phonetic key: vowels and silent-ish letters drop out, consonants that
    /// speech recognizers confuse share a class, and repeats collapse.
    /// "Cooper Netties" and "Kubernetes" both become "KPRNTS".
    static func consonantSkeleton(_ text: String) -> String {
        let letters = Array(text.lowercased().filter { $0.isLetter || $0.isNumber })
        var key: [Character] = []
        var index = 0
        while index < letters.count {
            let letter = letters[index]
            let next: Character? = index + 1 < letters.count ? letters[index + 1] : nil
            var mapped: Character?
            switch letter {
            case "a", "e", "i", "o", "u", "y", "h", "w":
                mapped = nil
            case "b", "p":
                if letter == "p", next == "h" {
                    mapped = "F"
                    index += 1
                } else {
                    mapped = "P"
                }
            case "d", "t": mapped = "T"
            case "g", "k", "q", "x": mapped = "K"
            case "c":
                if let next, "eiy".contains(next) { mapped = "S" } else { mapped = "K" }
            case "s", "z": mapped = "S"
            case "f", "v": mapped = "F"
            case "j": mapped = "J"
            case "l": mapped = "L"
            case "m": mapped = "M"
            case "n": mapped = "N"
            case "r": mapped = "R"
            default:
                mapped = Character(String(letter).uppercased())
            }
            if let mapped, key.last != mapped { key.append(mapped) }
            index += 1
        }
        return String(key)
    }

    // MARK: - Rejection rules

    static func isInflection(_ a: String, _ b: String) -> Bool {
        isInflected(stem: a, form: b) || isInflected(stem: b, form: a)
    }

    private static func isInflected(stem: String, form: String) -> Bool {
        guard form.count > stem.count, !stem.isEmpty else { return false }
        let suffixes = ["s", "es", "ed", "d", "ing", "'s", "’s", "er", "ers"]
        if form.hasPrefix(stem) {
            let rest = String(form.dropFirst(stem.count))
            if suffixes.contains(rest) { return true }
            // Doubled final consonant: run -> running, stop -> stopped.
            if let last = stem.last, rest.first == last, suffixes.contains(String(rest.dropFirst())) { return true }
        }
        // Silent e: make -> making, bake -> baked.
        if stem.hasSuffix("e") {
            let trimmed = String(stem.dropLast())
            if form.hasPrefix(trimmed), ["ing", "ed", "er"].contains(String(form.dropFirst(trimmed.count))) {
                return true
            }
        }
        // y -> ies/ied: try -> tries.
        if stem.hasSuffix("y") {
            let trimmed = String(stem.dropLast())
            if form.hasPrefix(trimmed), ["ies", "ied"].contains(String(form.dropFirst(trimmed.count))) {
                return true
            }
        }
        return false
    }

    static func looksLikeURLOrEmail(_ text: String) -> Bool {
        let lower = text.lowercased()
        if lower.contains("://") || lower.hasPrefix("www.") { return true }
        if let at = lower.firstIndex(of: "@"), lower[lower.index(after: at)...].contains(".") { return true }
        return false
    }

    /// Internal capitals such as "iPhone", "GitHub", or all-caps acronyms like "NVIDIA".
    static func isMixedCase(_ text: String) -> Bool {
        text.split(whereSeparator: \.isWhitespace).contains { word in
            let letters = word.filter(\.isLetter)
            guard letters.count >= 2 else { return false }
            return letters.dropFirst().contains(where: \.isUppercase)
        }
    }

    static func allCommonWords(_ text: String) -> Bool {
        let words = text.lowercased()
            .split(whereSeparator: { $0.isWhitespace || $0 == "-" })
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }
        return !words.isEmpty && words.allSatisfy { commonWords.contains($0) }
    }

    static func normalizedPhrase(_ text: String) -> String {
        text.lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    /// Everyday English words. A swap between two of these is a wording choice, not a
    /// misheard name or term, so it is never learned.
    static let commonWords: Set<String> = Set([
        "a", "about", "above", "after", "again", "against", "all", "almost", "also", "always", "am", "an",
        "and", "another", "any", "anyone", "anything", "are", "around", "as", "ask", "at", "away", "back",
        "bad", "be", "because", "been", "before", "being", "below", "best", "better", "between", "big",
        "both", "bring", "but", "buy", "by", "call", "came", "can", "can't", "cannot", "case", "change",
        "check", "come", "could", "couldn't", "day", "days", "did", "didn't", "do", "does", "doesn't",
        "doing", "don't", "done", "down", "during", "each", "early", "easy", "either", "else", "end",
        "enough", "even", "ever", "every", "everyone", "everything", "fact", "far", "few", "find", "fine",
        "first", "for", "found", "from", "full", "get", "gets", "getting", "give", "go", "goes", "going",
        "gonna", "good", "got", "gotta", "great", "had", "hand", "has", "have", "haven't", "having", "he",
        "head", "hear", "help", "her", "here", "hey", "hi", "high", "him", "his", "hold", "home", "hope",
        "how", "i", "i'd", "i'll", "i'm", "i've", "idea", "if", "in", "into", "is", "isn't", "it", "it's",
        "its", "just", "keep", "kind", "know", "last", "late", "later", "least", "left", "less", "let",
        "let's", "like", "line", "little", "long", "look", "lot", "lots", "made", "make", "many", "may",
        "maybe", "me", "mean", "meet", "might", "mind", "more", "most", "move", "much", "must", "my",
        "need", "never", "new", "next", "nice", "no", "nope", "not", "nothing", "now", "of", "off", "oh",
        "ok", "okay", "old", "on", "once", "one", "only", "open", "or", "other", "our", "out", "over",
        "own", "part", "people", "place", "point", "pretty", "put", "quite", "rather", "read", "ready",
        "real", "really", "right", "run", "said", "same", "saw", "say", "see", "seem", "send", "set",
        "she", "should", "show", "side", "since", "so", "some", "someone", "something", "soon", "sorry",
        "sounds", "start", "still", "stuff", "such", "sure", "take", "talk", "tell", "than", "thank",
        "thanks", "that", "that's", "the", "their", "them", "then", "there", "there's", "these", "they",
        "they're", "thing", "things", "think", "this", "those", "though", "thought", "through", "time",
        "to", "today", "together", "tomorrow", "too", "took", "try", "turn", "two", "under", "until",
        "up", "us", "use", "used", "very", "wait", "want", "wanna", "was", "wasn't", "way", "we", "we'll",
        "we're", "week", "well", "went", "were", "what", "what's", "when", "where", "whether", "which",
        "while", "who", "whole", "why", "will", "with", "without", "won't", "word", "work", "would",
        "wouldn't", "write", "yeah", "year", "yep", "yes", "yet", "you", "you'll", "you're", "your",
        "yours", "alright", "all right", "cool", "awesome", "please", "thx", "ya", "yup", "nah",
        "insight", "sight", "site", "cite", "write", "rite", "here's", "hear", "its", "your", "you're",
        "to", "too", "two", "then", "than", "affect", "effect", "accept", "except", "loose", "lose",
        "weather", "whether", "peace", "piece", "plain", "plane", "principal", "principle", "right",
        "brake", "break", "buy", "bye", "by", "fair", "fare", "for", "four", "know", "no", "new", "knew",
        "meat", "meet", "one", "won", "our", "hour", "sea", "see", "sun", "son", "tail", "tale",
        "week", "weak", "which", "witch", "wood", "would", "flour", "flower", "mail", "male",
    ] as [String])
}
