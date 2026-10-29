import Foundation

enum AppStyleTests {
    static func run() {
        testKnownAppsResolve()
        testBrowserUsesWindowTitle()
        testAssignmentsOverrideDefaults()
        testPromptSection()
        testCustomInstructions()
        testSettingsPersistence()
    }

    private static func testKnownAppsResolve() {
        TestSupport.expectEqual(AppStyleResolver.category(bundleIdentifier: "com.tinyspeck.slackmacgap", windowTitle: nil), .messaging)
        TestSupport.expectEqual(AppStyleResolver.category(bundleIdentifier: "com.hnc.Discord", windowTitle: nil), .messaging)
        TestSupport.expectEqual(AppStyleResolver.category(bundleIdentifier: "com.apple.MobileSMS", windowTitle: nil), .messaging)
        TestSupport.expectEqual(AppStyleResolver.category(bundleIdentifier: "com.apple.mail", windowTitle: nil), .email)
        TestSupport.expectEqual(AppStyleResolver.category(bundleIdentifier: "com.anthropic.claudefordesktop", windowTitle: nil), .aiAssistant)
        TestSupport.expectEqual(AppStyleResolver.category(bundleIdentifier: "com.openai.codex", windowTitle: nil), .aiAssistant)
        TestSupport.expectEqual(AppStyleResolver.category(bundleIdentifier: "com.jetbrains.intellij", windowTitle: nil), .coding)
        TestSupport.expectEqual(AppStyleResolver.category(bundleIdentifier: "com.example.unknown", windowTitle: "Gmail"), .general)
        TestSupport.expectEqual(AppStyleResolver.category(bundleIdentifier: nil, windowTitle: nil), .general)
        TestSupport.expectEqual(AppStyleResolver.category(bundleIdentifier: "", windowTitle: nil), .general)
    }

    private static func testBrowserUsesWindowTitle() {
        TestSupport.expectEqual(AppStyleResolver.category(bundleIdentifier: "com.google.Chrome", windowTitle: "Inbox (3) - synthetic@example.com - Gmail"), .email)
        TestSupport.expectEqual(AppStyleResolver.category(bundleIdentifier: "com.apple.Safari", windowTitle: "ChatGPT"), .aiAssistant)
        TestSupport.expectEqual(AppStyleResolver.category(bundleIdentifier: "company.thebrowser.Browser", windowTitle: "general | Example Workspace | slack"), .messaging)
        TestSupport.expectEqual(AppStyleResolver.category(bundleIdentifier: "com.google.Chrome", windowTitle: "Synthetic Plan - Google Docs"), .documents)
        TestSupport.expectEqual(AppStyleResolver.category(bundleIdentifier: "com.google.Chrome", windowTitle: "Example Search Results"), .general)
        TestSupport.expectEqual(AppStyleResolver.category(bundleIdentifier: "com.google.Chrome", windowTitle: nil), .general)
    }

    private static func testAssignmentsOverrideDefaults() {
        let assignments = [
            "com.tinyspeck.slackmacgap": AppStyleAssignment(appName: "Slack", category: .documents),
            "com.example.unknown": AppStyleAssignment(appName: "Example", category: .email),
        ]
        TestSupport.expectEqual(AppStyleResolver.category(bundleIdentifier: "com.tinyspeck.slackmacgap", windowTitle: nil, assignments: assignments), .documents)
        TestSupport.expectEqual(AppStyleResolver.category(bundleIdentifier: "com.example.unknown", windowTitle: nil, assignments: assignments), .email)
        TestSupport.expectEqual(AppStyleResolver.category(bundleIdentifier: "com.apple.mail", windowTitle: nil, assignments: assignments), .email)
    }

    private static func testPromptSection() {
        let section = AppStyleResolver.promptSection(bundleIdentifier: "com.apple.mail", windowTitle: nil, settings: AppStyleSettings())
        TestSupport.expect(section.hasPrefix("Destination app style (Email):\n"), "Section must name the style")
        TestSupport.expect(section.contains(AppStyleCategory.email.defaultInstruction.trimmingCharacters(in: .whitespacesAndNewlines)), "Section must include the default instruction")
        TestSupport.expect(section.contains("never add content"), "Section must restate the hard contract")

        TestSupport.expectEqual(
            AppStyleResolver.promptSection(bundleIdentifier: "com.example.unknown", windowTitle: nil, settings: AppStyleSettings()),
            ""
        )

        var disabled = AppStyleSettings()
        disabled.isEnabled = false
        TestSupport.expectEqual(
            AppStyleResolver.promptSection(bundleIdentifier: "com.apple.mail", windowTitle: nil, settings: disabled),
            ""
        )
    }

    private static func testCustomInstructions() {
        var settings = AppStyleSettings()
        TestSupport.expect(!settings.isCustomized(.messaging), "Defaults are not customized")

        settings.customInstructions[AppStyleCategory.messaging.rawValue] = "  Synthetic chat style.  "
        TestSupport.expectEqual(settings.instruction(for: .messaging), "Synthetic chat style.")
        TestSupport.expect(settings.isCustomized(.messaging), "A different instruction is customized")

        settings.customInstructions[AppStyleCategory.messaging.rawValue] = "   "
        TestSupport.expectEqual(settings.instruction(for: .messaging), AppStyleCategory.messaging.defaultInstruction.trimmingCharacters(in: .whitespacesAndNewlines))
        TestSupport.expect(!settings.isCustomized(.messaging), "A blank instruction falls back to the default")

        settings.customInstructions[AppStyleCategory.general.rawValue] = "Synthetic general style."
        let section = AppStyleResolver.promptSection(bundleIdentifier: "com.example.unknown", windowTitle: nil, settings: settings)
        TestSupport.expect(section.contains("Synthetic general style."), "Everything Else can be given its own instruction")
    }

    private static func testSettingsPersistence() {
        let suite = "FreeFlowTests.AppStyle.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        TestSupport.expectEqual(AppStyleSettings.load(from: defaults), AppStyleSettings())
        TestSupport.expect(AppStyleSettings.load(from: defaults).isEnabled, "App styles are on by default")

        var settings = AppStyleSettings()
        settings.isEnabled = false
        settings.customInstructions[AppStyleCategory.email.rawValue] = "Synthetic email style."
        settings.appAssignments["com.example.unknown"] = AppStyleAssignment(appName: "Example", category: .coding)
        settings.save(to: defaults)
        TestSupport.expectEqual(AppStyleSettings.load(from: defaults), settings)

        defaults.set(Data("not json".utf8), forKey: AppStyleSettings.storageKey)
        TestSupport.expectEqual(AppStyleSettings.load(from: defaults), AppStyleSettings())
    }
}
