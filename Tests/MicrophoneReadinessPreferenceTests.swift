import Foundation

enum MicrophoneReadinessPreferenceTests {
    static func run() {
        testDefaultsToOffWithoutPersisting()
        testRoundTripsAndRejectsUnknownValues()
        testWarmSessionReuseRequiresRunningSessionOnResolvedDevice()
        testAudioCaptureBackendDefaultsAndRoundTrips()
    }

    private static func makeDefaults() -> (UserDefaults, String) {
        let suite = "FreeFlowTests.MicrophoneReadiness.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    private static func testDefaultsToOffWithoutPersisting() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        TestSupport.expectEqual(MicrophoneReadinessPreference.defaultReadiness, .off)
        TestSupport.expectEqual(MicrophoneReadinessPreference.load(from: defaults), .off)
        TestSupport.expect(
            defaults.object(forKey: MicrophoneReadinessPreference.storageKey) == nil,
            "Loading the default must not persist a choice"
        )
    }

    private static func testRoundTripsAndRejectsUnknownValues() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        for readiness in MicrophoneReadiness.allCases {
            defaults.set(readiness.rawValue, forKey: MicrophoneReadinessPreference.storageKey)
            TestSupport.expectEqual(MicrophoneReadinessPreference.load(from: defaults), readiness)
        }

        defaults.set("bogus", forKey: MicrophoneReadinessPreference.storageKey)
        // An unknown saved value must fall back to keeping the microphone closed.
        TestSupport.expectEqual(MicrophoneReadinessPreference.load(from: defaults), .off)
    }

    private static func testWarmSessionReuseRequiresRunningSessionOnResolvedDevice() {
        func canReuse(
            isRunning: Bool = true,
            isInterrupted: Bool = false,
            warm: String? = "mic-a",
            resolved: String? = "mic-a",
            warmBackend: AudioCaptureBackend? = .captureSession,
            requestedBackend: AudioCaptureBackend = .captureSession
        ) -> Bool {
            MicrophoneReadinessPreference.canReuseWarmSession(
                isRunning: isRunning,
                isInterrupted: isInterrupted,
                warmDeviceUID: warm,
                resolvedDeviceUID: resolved,
                warmBackend: warmBackend,
                requestedBackend: requestedBackend
            )
        }

        TestSupport.expect(canReuse(), "A running session on the resolved device must be reused")
        TestSupport.expect(!canReuse(isRunning: false), "A stopped session must take the cold path")
        TestSupport.expect(!canReuse(isInterrupted: true), "An interrupted session must take the cold path")
        TestSupport.expect(!canReuse(resolved: "mic-b"), "Switching microphones must rebuild the session")
        TestSupport.expect(!canReuse(warm: nil), "No warm session means nothing to reuse")
        TestSupport.expect(!canReuse(resolved: nil), "No resolvable device must take the cold path")
        TestSupport.expect(
            canReuse(warmBackend: .audioEngine, requestedBackend: .audioEngine),
            "A warm Audio Engine session must be reused for Audio Engine recordings"
        )
        TestSupport.expect(
            !canReuse(warmBackend: .captureSession, requestedBackend: .audioEngine),
            "Switching audio engines must rebuild the session"
        )
        TestSupport.expect(!canReuse(warmBackend: nil), "No warm backend means nothing to reuse")
    }

    private static func testAudioCaptureBackendDefaultsAndRoundTrips() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        // Existing installs keep the original capture path until the user opts in.
        TestSupport.expectEqual(AudioCaptureBackendPreference.load(from: defaults), .captureSession)
        TestSupport.expect(
            defaults.object(forKey: AudioCaptureBackendPreference.storageKey) == nil,
            "Loading the default must not persist a choice"
        )

        for backend in AudioCaptureBackend.allCases {
            defaults.set(backend.rawValue, forKey: AudioCaptureBackendPreference.storageKey)
            TestSupport.expectEqual(AudioCaptureBackendPreference.load(from: defaults), backend)
        }

        // An unknown saved value must fall back to the original capture path.
        defaults.set("bogus", forKey: AudioCaptureBackendPreference.storageKey)
        TestSupport.expectEqual(AudioCaptureBackendPreference.load(from: defaults), .captureSession)
    }
}
