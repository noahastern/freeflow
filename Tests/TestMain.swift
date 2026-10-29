import Foundation

@main
struct FreeFlowTests {
    static func main() async {
        AlertSoundPreferenceTests.run()
        AppStyleTests.run()
        CleanupLevelTests.run()
        FormattingPreferencesTests.run()
        AppContextServiceTests.run()
        await LLMAPITransportTests.run()
        TemperatureCapabilityCacheTests.run()
        ModelConfigurationTests.run()
        OverlayPlacementPreferenceTests.run()
        RecordingCaptureTimingTests.run()
        RecordingTimerPreferenceTests.run()
        MicrophoneReadinessPreferenceTests.run()
        OriginalFieldInsertionPreferenceTests.run()
        ShortcutCoreTests.run()
        SemanticVersionTests.run()
        LLMCooldownManagerTests.run()
        PostProcessingServiceTests.run()
        TranscriptionErrorPresentationCoreTests.run()
        TranscriptTextCoreTests.run()
        AppTextInsertionCoreTests.run()
        AppTextInsertionDispatchTests.run()
        await TranscriptionServiceTests.run()
        await RawTranscriptResolverTests.run()
        await APIConfigurationDraftTests.run()
        VocabularyPromptTests.run()
        print("FreeFlowTests passed")
    }
}
