import Foundation

enum VocabularyPromptTests {
    static func run() {
        TestSupport.expectEqual(VocabularyPrompt.section(for: []), "")
        TestSupport.expectEqual(VocabularyPrompt.section(for: ["  ", "\n"]), "")
        TestSupport.expectEqual(VocabularyPrompt.reminder(for: [" "]), "")

        let section = VocabularyPrompt.section(for: [" Nsight ", "", "examplehandle"])
        TestSupport.expect(section.contains("Nsight, examplehandle\n"), "Terms must be trimmed, joined, and listed verbatim")
        TestSupport.expect(section.contains("split into ordinary words"), "Prompt must cover terms split into separate words")
        TestSupport.expect(section.contains("similar-sounding"), "Prompt must cover sound-alike substitutions")
        TestSupport.expect(section.contains("ordinary sense"), "Prompt must keep ordinary uses of the words unchanged")
        TestSupport.expect(section.contains("even when the transcribed word is a real word"), "Dictionary terms must win over real-word sound-alikes such as Grok for Groq")

        TestSupport.expectEqual(
            VocabularyPrompt.reminder(for: ["Groq", " Nsight "]),
            "PERSONAL_DICTIONARY (write sound-alike words with these exact spellings): Groq, Nsight"
        )

        TestSupport.expectEqual(VocabularyList.terms(from: "Groq, Nsight;\n groq \n\nexamplehandle"), ["Groq", "Nsight", "examplehandle"])
        TestSupport.expectEqual(VocabularyList.adding("Exampleco, NSIGHT", to: "Groq,\nNsight"), "Groq\nNsight\nExampleco")
        TestSupport.expectEqual(VocabularyList.adding("Groq", to: ""), "Groq")
        TestSupport.expectEqual(VocabularyList.removing("nsight", from: "Groq, Nsight, Exampleco"), "Groq\nExampleco")
    }
}
