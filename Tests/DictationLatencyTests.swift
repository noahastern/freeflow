import Foundation

enum DictationLatencyTests {
    static func run() {
        var timeline = DictationLatencyTimeline(keyReleasedAt: 100)
        TestSupport.expectEqual(
            timeline.logLine,
            "audio_ms=-1 transcript_ms=-1 context_ms=-1 cleanup_ms=-1 pasted_ms=-1 wav_bytes=-1 flac_bytes=-1"
        )

        timeline.mark(.audioFinalized, at: 100.0124)
        timeline.mark(.transcriptReceived, at: 100.4506)
        timeline.mark(.contextReady, at: 100.452)
        timeline.mark(.cleanupDone, at: 100.9)
        timeline.mark(.pasted, at: 101.026)
        timeline.wavBytes = 96_044
        timeline.flacBytes = 51_200

        TestSupport.expectEqual(timeline.milliseconds(to: .audioFinalized), 12)
        TestSupport.expectEqual(timeline.milliseconds(to: .transcriptReceived), 451)
        TestSupport.expectEqual(timeline.milliseconds(to: .pasted), 1_026)
        TestSupport.expectEqual(
            timeline.logLine,
            "audio_ms=12 transcript_ms=451 context_ms=452 cleanup_ms=900 pasted_ms=1026 wav_bytes=96044 flac_bytes=51200"
        )

        var skewed = DictationLatencyTimeline(keyReleasedAt: 50)
        skewed.mark(.audioFinalized, at: 49.9)
        TestSupport.expectEqual(skewed.milliseconds(to: .audioFinalized), 0)
        skewed.mark(.cleanupDone, at: .infinity)
        TestSupport.expect(skewed.milliseconds(to: .cleanupDone) == nil, "Non-finite times are dropped")

        let line = timeline.logLine
        let allowed = Set("abcdefghijklmnopqrstuvwxyz_=- 0123456789")
        TestSupport.expect(line.allSatisfy { allowed.contains($0) }, "The log line holds only field names and integers")

        TestSupport.expect(DictationLatencyTimeline.fileSize(at: nil) == nil, "No file has no size")
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString).wav")
        TestSupport.expect(DictationLatencyTimeline.fileSize(at: missing) == nil, "A missing file has no size")
    }
}
