import Foundation

enum FormattingPreferencesTests {
    static func run() {
        testDefaultsAddNothing()
        testChangedAmountsReachPrompt()
        testPersistence()
    }

    private static func testDefaultsAddNothing() {
        let preferences = FormattingPreferences()
        TestSupport.expectEqual(preferences.promptSection, "")
        for element in FormattingElement.allCases {
            TestSupport.expectEqual(preferences.amount(for: element), .standard)
            TestSupport.expect(element.instruction(for: .standard) == nil, "\(element) default must leave the prompt alone")
            TestSupport.expect(element.instruction(for: .less) != nil, "\(element) must have a Less instruction")
            TestSupport.expect(element.instruction(for: .more) != nil, "\(element) must have a More instruction")
        }
    }

    private static func testChangedAmountsReachPrompt() {
        var preferences = FormattingPreferences()
        preferences.setAmount(.more, for: .parentheses)
        preferences.setAmount(.less, for: .lists)
        let section = preferences.promptSection
        TestSupport.expect(section.hasPrefix("Formatting preferences."), "Section must name itself")
        TestSupport.expect(section.contains("- Parentheses (more):"), "More parentheses must reach the prompt")
        TestSupport.expect(section.contains("- Lists (less):"), "Fewer lists must reach the prompt")
        TestSupport.expect(!section.contains("Paragraph breaks ("), "Default elements must stay out of the prompt")
        TestSupport.expect(section.contains("never the content"), "Preferences must not license added content")

        preferences.setAmount(.standard, for: .parentheses)
        TestSupport.expectEqual(preferences.amounts, ["lists": .less])
    }

    private static func testPersistence() {
        let suite = "FreeFlowTests.FormattingPreferences.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        TestSupport.expectEqual(FormattingPreferences.load(from: defaults), FormattingPreferences())

        var preferences = FormattingPreferences()
        preferences.setAmount(.more, for: .quotationMarks)
        preferences.save(to: defaults)
        TestSupport.expectEqual(FormattingPreferences.load(from: defaults), preferences)

        // An amount from a newer build must not wipe the other settings' load.
        defaults.set(Data(#"{"amounts":{"lists":"synthetic-unknown"}}"#.utf8), forKey: FormattingPreferences.storageKey)
        TestSupport.expectEqual(FormattingPreferences.load(from: defaults), FormattingPreferences())
    }
}
