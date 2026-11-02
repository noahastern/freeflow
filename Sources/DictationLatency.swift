import Foundation

/// Per-stage timings for one dictation, measured from key release. Holds only
/// monotonic timestamps and byte counts, so its log line never carries text.
struct DictationLatencyTimeline: Equatable {
    enum Stage: String, CaseIterable {
        case audioFinalized = "audio_ms"
        case transcriptReceived = "transcript_ms"
        case contextReady = "context_ms"
        case cleanupDone = "cleanup_ms"
        case pasted = "pasted_ms"
    }

    /// Seconds on a monotonic clock, such as `ProcessInfo.systemUptime`.
    let keyReleasedAt: TimeInterval
    private(set) var stamps: [Stage: TimeInterval] = [:]
    var wavBytes: Int64?
    var flacBytes: Int64?

    init(keyReleasedAt: TimeInterval) {
        self.keyReleasedAt = keyReleasedAt
    }

    static func now() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    mutating func mark(_ stage: Stage, at time: TimeInterval = DictationLatencyTimeline.now()) {
        stamps[stage] = time
    }

    /// Whole milliseconds from key release to `stage`, or nil if it never happened.
    func milliseconds(to stage: Stage) -> Int? {
        guard let time = stamps[stage] else { return nil }
        let elapsed = (time - keyReleasedAt) * 1_000
        guard elapsed.isFinite else { return nil }
        return max(0, Int(elapsed.rounded()))
    }

    /// One line of integers: each stage in order, then byte counts. Missing values are -1.
    var logLine: String {
        var fields = Stage.allCases.map { "\($0.rawValue)=\(milliseconds(to: $0) ?? -1)" }
        fields.append("wav_bytes=\(wavBytes ?? -1)")
        fields.append("flac_bytes=\(flacBytes ?? -1)")
        return fields.joined(separator: " ")
    }

    static func fileSize(at url: URL?) -> Int64? {
        guard let url,
              let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber else {
            return nil
        }
        return size.int64Value
    }
}
