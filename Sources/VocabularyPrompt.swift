import Foundation

enum VocabularyPrompt {
    /// Speech recognition rarely produces handles, brand names, or jargon intact,
    /// and often swaps a term for a better-known sound-alike ("Groq" as "Grok").
    /// The speaker added each term on purpose, so the model is told to prefer the
    /// dictionary spelling over the common word unless context rules it out.
    static func section(for vocabularyTerms: [String]) -> String {
        let terms = cleanedTerms(vocabularyTerms)
        guard !terms.isEmpty else { return "" }
        return """
Personal dictionary (highest priority). These are the speaker's own spellings. They override your general knowledge of how a word or name is usually written:
\(terms.joined(separator: ", "))

Dictionary rules:
- When a word or phrase in the transcript sounds like, or is spelled close to, a dictionary term, write the dictionary term exactly as listed, including casing and spacing.
- This applies even when the transcribed word is a real word or a different well-known name. The speaker added the term because that is what they usually mean. Example: with "Groq" in the dictionary, "Grok", "grok", or "grock" becomes "Groq".
- A term may arrive as a similar-sounding common word or name, e.g. "Nsight" as "insight" or "in sight".
- A term may arrive split into ordinary words, e.g. a handle "janedoedesign" transcribed as "Jane Doe design" or "by Jane Doe" for "byjanedoe".
- Keep the transcribed words only when the sentence clearly uses them in their ordinary sense, unrelated to the term, e.g. "a photo by Jane Doe" or "I finally grok how this works".
"""
    }

    /// A one-line restatement placed next to the transcript in the user message,
    /// where smaller models weigh it more heavily than the end of a long system prompt.
    static func reminder(for vocabularyTerms: [String]) -> String {
        let terms = cleanedTerms(vocabularyTerms)
        guard !terms.isEmpty else { return "" }
        return "PERSONAL_DICTIONARY (write sound-alike words with these exact spellings): \(terms.joined(separator: ", "))"
    }

    private static func cleanedTerms(_ terms: [String]) -> [String] {
        terms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

/// The saved vocabulary is one string that accepts commas, semicolons, or new
/// lines between entries. Edits from the Vocabulary tab write one term per line.
enum VocabularyList {
    static func terms(from raw: String) -> [String] {
        var seen = Set<String>()
        return raw
            .split(whereSeparator: { $0 == "\n" || $0 == "," || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { seen.insert($0.lowercased()).inserted }
    }

    static func serialized(_ terms: [String]) -> String {
        terms.joined(separator: "\n")
    }

    /// Adds every entry in `input` (which may itself hold several, comma-separated)
    /// that isn't already present, ignoring case.
    static func adding(_ input: String, to raw: String) -> String {
        serialized(terms(from: raw + "\n" + input))
    }

    static func removing(_ term: String, from raw: String) -> String {
        serialized(terms(from: raw).filter { $0.caseInsensitiveCompare(term) != .orderedSame })
    }
}
