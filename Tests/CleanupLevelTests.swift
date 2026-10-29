import Foundation

enum CleanupLevelTests {
    static func run() {
        testDefaultsAndLegacyMigration()
        testSaveKeepsLegacyKeyInSync()
        testPromptSections()
    }

    private static func withDefaults(_ body: (UserDefaults) -> Void) {
        let suite = "FreeFlowTests.CleanupLevel.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        body(defaults)
    }

    private static func testDefaultsAndLegacyMigration() {
        withDefaults { defaults in
            TestSupport.expectEqual(CleanupLevel.load(from: defaults), .medium)

            defaults.set(true, forKey: CleanupLevel.legacyPreserveExactWordingKey)
            TestSupport.expectEqual(CleanupLevel.load(from: defaults), .none)

            defaults.set("light", forKey: CleanupLevel.storageKey)
            TestSupport.expectEqual(CleanupLevel.load(from: defaults), .light)

            defaults.set("synthetic-unknown", forKey: CleanupLevel.storageKey)
            TestSupport.expectEqual(CleanupLevel.load(from: defaults), .none)
        }
    }

    private static func testSaveKeepsLegacyKeyInSync() {
        withDefaults { defaults in
            CleanupLevel.none.save(to: defaults)
            TestSupport.expect(defaults.bool(forKey: CleanupLevel.legacyPreserveExactWordingKey), "None must keep exact wording for older builds")
            TestSupport.expectEqual(CleanupLevel.load(from: defaults), .none)

            CleanupLevel.light.save(to: defaults)
            TestSupport.expect(!defaults.bool(forKey: CleanupLevel.legacyPreserveExactWordingKey), "Light must turn exact wording off")
            TestSupport.expectEqual(CleanupLevel.load(from: defaults), .light)
        }
    }

    private static func testPromptSections() {
        TestSupport.expectEqual(CleanupLevel.medium.promptSection, "")
        TestSupport.expectEqual(CleanupLevel.none.promptSection, "")
        let light = CleanupLevel.light.promptSection
        TestSupport.expect(light.hasPrefix("Cleanup level: Light."), "Light must name itself")
        TestSupport.expect(light.contains("\"you know\""), "Light must keep verbal habits")
        TestSupport.expect(light.contains("paragraph breaks"), "Light must still lay out paragraphs")
    }
}
