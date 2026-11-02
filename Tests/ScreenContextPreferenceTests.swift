import Foundation

enum ScreenContextPreferenceTests {
    static func run() async {
        testPreferenceDefaultsOnAndRoundTrips()
        testDisabledSummaryStaysOutOfPrompt()
        await testRaceReturnsValueBeforeDeadline()
        await testRaceTimesOutWhenContextIsSlow()
        await testRacePassesThroughNil()
    }

    private static func testPreferenceDefaultsOnAndRoundTrips() {
        let suite = "FreeFlowTests.ScreenContext.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        TestSupport.expect(ScreenContextPreference.defaultEnabled, "Screen context must default to on")
        TestSupport.expect(ScreenContextPreference.load(from: defaults), "A missing preference must keep screen context on")
        TestSupport.expect(
            defaults.object(forKey: ScreenContextPreference.storageKey) == nil,
            "Loading the default must not persist a choice"
        )
        for enabled in [false, true] {
            ScreenContextPreference.save(enabled, to: defaults)
            TestSupport.expectEqual(ScreenContextPreference.load(from: defaults), enabled)
        }
        defaults.set("invalid", forKey: ScreenContextPreference.storageKey)
        TestSupport.expect(ScreenContextPreference.load(from: defaults), "An invalid saved value must default to on")
    }

    private static func testDisabledSummaryStaysOutOfPrompt() {
        let summary = ContextInferenceFailure.screenContextDisabledSummary
        TestSupport.expect(ContextInferenceFailure.isFailureSummary(summary), "Disabled marker is not a usable summary")
        TestSupport.expectEqual(ContextInferenceFailure.promptSection(for: summary), "")
    }

    private static func testRaceReturnsValueBeforeDeadline() async {
        // The deadline never fires on its own: the injected sleep waits far longer
        // than the operation, so the value must win.
        let value = await ContextWaitRace.value(
            of: { "synthetic context" },
            deadline: 0.15,
            sleep: { _ in try? await Task.sleep(nanoseconds: 30_000_000_000) }
        )
        TestSupport.expectEqual(value, "synthetic context")
    }

    private static func testRaceTimesOutWhenContextIsSlow() async {
        let start = Date()
        // The deadline elapses immediately while the context capture is still running.
        let value: String? = await ContextWaitRace.value(
            of: {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                return "late context"
            },
            deadline: 0.15,
            sleep: { _ in }
        )
        TestSupport.expect(value == nil, "A slow capture must fall back once the deadline passes")
        TestSupport.expect(Date().timeIntervalSince(start) < 5, "The race must not wait for the slow capture")
    }

    private static func testRacePassesThroughNil() async {
        let value: String? = await ContextWaitRace.value(
            of: { nil },
            deadline: 0.15,
            sleep: { _ in try? await Task.sleep(nanoseconds: 30_000_000_000) }
        )
        TestSupport.expect(value == nil, "A capture that returns nothing yields nil")
    }
}
