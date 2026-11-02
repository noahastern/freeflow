import AVFoundation
import Foundation

/// File names and content types for the audio sent to transcription providers.
enum AudioUploadFormat {
    static func contentType(forFileName fileName: String) -> String {
        switch (fileName as NSString).pathExtension.lowercased() {
        case "flac": return "audio/flac"
        case "wav": return "audio/wav"
        case "mp3": return "audio/mpeg"
        default: return "audio/mp4"
        }
    }

    /// The compressed companion written next to a recording's WAV file.
    static func flacURL(besideWAV wavURL: URL) -> URL {
        wavURL.deletingPathExtension().appendingPathExtension("flac")
    }

    static func flacSettings(for format: AVAudioFormat) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatFLAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: Int(format.channelCount),
        ]
    }
}

/// Encodes the recording to lossless FLAC as buffers arrive, alongside the WAV
/// file, so a smaller upload is ready the moment recording stops. Any failure
/// drops the FLAC file and the WAV is uploaded instead. Not thread-safe: the
/// recorder calls it from its sample-buffer queue only.
final class StreamingFLACWriter {
    let url: URL
    private var file: AVAudioFile?
    private(set) var frameCount: AVAudioFramePosition = 0
    private(set) var failed = false

    /// Nil when the encoder cannot be created; the caller then keeps only the WAV.
    init?(url: URL, format: AVAudioFormat) {
        self.url = url
        do {
            file = try AVAudioFile(
                forWriting: url,
                settings: AudioUploadFormat.flacSettings(for: format),
                commonFormat: format.commonFormat,
                interleaved: format.isInterleaved
            )
        } catch {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
    }

    func write(_ buffer: AVAudioPCMBuffer) {
        guard let file, !failed else { return }
        do {
            try file.write(from: buffer)
            frameCount += AVAudioFramePosition(buffer.frameLength)
        } catch {
            failed = true
            self.file = nil
        }
    }

    /// Closes the file. Returns its URL only when it holds exactly the frames
    /// written to the WAV; otherwise deletes it and returns nil.
    func finish(expectedFrameCount: AVAudioFramePosition) -> URL? {
        file = nil
        guard !failed, expectedFrameCount > 0, frameCount == expectedFrameCount,
              let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber,
              size.int64Value > 0 else {
            discard()
            return nil
        }
        return url
    }

    func discard() {
        file = nil
        failed = true
        try? FileManager.default.removeItem(at: url)
    }
}
