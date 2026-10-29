import CoreGraphics
import Foundation

enum OverlayPlacementPreferenceTests {
    static func run() {
        testPlacementMigratesLegacyCompactToggle()
        testBottomFrameSitsJustAboveBottomEdge()
        testEscapeBehaviorDefaultsToDiscard()
    }

    private static func makeDefaults(_ name: String) -> (UserDefaults, String) {
        let suite = "FreeFlowTests.\(name).\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    private static func testPlacementMigratesLegacyCompactToggle() {
        let (defaults, suite) = makeDefaults("OverlayPlacement")
        defer { defaults.removePersistentDomain(forName: suite) }

        TestSupport.expectEqual(OverlayPlacementPreference.load(from: defaults), .menuBar)

        defaults.set(false, forKey: OverlayPlacementPreference.legacyCompactStorageKey)
        TestSupport.expectEqual(OverlayPlacementPreference.load(from: defaults), .dropDown)

        defaults.set(true, forKey: OverlayPlacementPreference.legacyCompactStorageKey)
        TestSupport.expectEqual(OverlayPlacementPreference.load(from: defaults), .menuBar)

        defaults.set(OverlayPlacement.bottom.rawValue, forKey: OverlayPlacementPreference.storageKey)
        TestSupport.expectEqual(OverlayPlacementPreference.load(from: defaults), .bottom)

        // An unknown placement falls back to the legacy toggle.
        defaults.set("sideways", forKey: OverlayPlacementPreference.storageKey)
        TestSupport.expectEqual(OverlayPlacementPreference.load(from: defaults), .menuBar)
    }

    private static func testBottomFrameSitsJustAboveBottomEdge() {
        let secondaryScreen = CGRect(x: 1440, y: -200, width: 1920, height: 1080)
        let frame = OverlayPlacementPreference.bottomFrame(
            size: CGSize(width: 150, height: 36),
            screenFrame: secondaryScreen
        )

        TestSupport.expectEqual(frame.midX, secondaryScreen.midX)
        TestSupport.expectEqual(frame.minY, secondaryScreen.minY + 12)
        TestSupport.expectEqual(frame.size, CGSize(width: 150, height: 36))
    }

    private static func testEscapeBehaviorDefaultsToDiscard() {
        let (defaults, suite) = makeDefaults("EscapeKey")
        defer { defaults.removePersistentDomain(forName: suite) }

        TestSupport.expectEqual(EscapeKeyPreference.load(from: defaults), .discard)
        TestSupport.expect(
            defaults.object(forKey: EscapeKeyPreference.storageKey) == nil,
            "Loading the default must not persist a choice"
        )

        defaults.set(EscapeKeyBehavior.ignore.rawValue, forKey: EscapeKeyPreference.storageKey)
        TestSupport.expectEqual(EscapeKeyPreference.load(from: defaults), .ignore)

        defaults.set("bogus", forKey: EscapeKeyPreference.storageKey)
        TestSupport.expectEqual(EscapeKeyPreference.load(from: defaults), .discard)
    }
}
