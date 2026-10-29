import Foundation

enum VocabularyPrompt {
    /// Speech recognition rarely produces handles, brand names, or jargon intact,
    /// so the model is told how terms get mangled and to restore them from context.
    static func section(for vocabularyTerms: [String]) -> String {
        let terms = vocabularyTerms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !terms.isEmpty else { return "" }
        return """
Custom vocabulary (high-priority terms). When the speaker means one of these, write it exactly as listed, including casing and spacing:
\(terms.joined(separator: ", "))

Speech recognition often mangles these terms, so match on sound and context, not just spelling:
- A term may arrive split into ordinary words, e.g. a handle "janedoedesign" transcribed as "Jane Doe design" or "by Jane Doe" for "byjanedoe".
- A term may arrive as a similar-sounding common word or name, e.g. "Nsight" as "insight" or "in sight", "Groq" as "Grok".
- When the surrounding context shows the speaker is referring to the thing a term names (an account, handle, channel, domain, product, company, or tool), replace the mangled words with the term.
- Leave words alone when they are clearly used in their ordinary sense, e.g. "a photo by Jane Doe" stays as written.
"""
    }
}
