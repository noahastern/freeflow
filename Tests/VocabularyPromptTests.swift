import Foundation

enum VocabularyPromptTests {
    static func run() {
        TestSupport.expectEqual(VocabularyPrompt.section(for: []), "")
        TestSupport.expectEqual(VocabularyPrompt.section(for: ["  ", "\n"]), "")

        let section = VocabularyPrompt.section(for: [" Nsight ", "", "examplehandle"])
        TestSupport.expect(section.contains("Nsight, examplehandle\n"), "Terms must be trimmed, joined, and listed verbatim")
        TestSupport.expect(section.contains("split into ordinary words"), "Prompt must cover terms split into separate words")
        TestSupport.expect(section.contains("similar-sounding"), "Prompt must cover sound-alike substitutions")
        TestSupport.expect(section.contains("ordinary sense"), "Prompt must keep ordinary uses of the words unchanged")
    }
}
