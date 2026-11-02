import AVFoundation
import Foundation

/// Rejects FLAC uploads with `flacStatus` and accepts WAV, recording each upload's part content type.
private final class FormatStubURLProtocol: URLProtocol {
    static var flacStatus = 400
    static var contentTypes: [String] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let body = Self.body(of: request)
        let text = String(decoding: body, as: UTF8.self)
        let contentType = text.components(separatedBy: "\r\n")
            .first { $0.hasPrefix("Content-Type: audio/") }?
            .replacingOccurrences(of: "Content-Type: ", with: "") ?? "missing"
        Self.contentTypes.append(contentType)
        let status = contentType == "audio/flac" ? Self.flacStatus : 200
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{\"text\":\"synthetic \(contentType)\"}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: 4096)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

enum AudioUploadEncodingTests {
    static func run() async {
        testContentTypeMapping()
        testStreamingFLACRoundTripsLosslessly()
        testFLACWriterDropsIncompleteFile()
        await testUploadPrefersFLACAndFallsBackToWAV()
    }

    private static func testContentTypeMapping() {
        TestSupport.expectEqual(AudioUploadFormat.contentType(forFileName: "A1B2.flac"), "audio/flac")
        TestSupport.expectEqual(AudioUploadFormat.contentType(forFileName: "A1B2.FLAC"), "audio/flac")
        TestSupport.expectEqual(AudioUploadFormat.contentType(forFileName: "A1B2.wav"), "audio/wav")
        TestSupport.expectEqual(AudioUploadFormat.contentType(forFileName: "clip.mp3"), "audio/mpeg")
        TestSupport.expectEqual(AudioUploadFormat.contentType(forFileName: "clip.m4a"), "audio/mp4")
        let wav = URL(fileURLWithPath: "/tmp/synthetic/4F2A.wav")
        TestSupport.expectEqual(AudioUploadFormat.flacURL(besideWAV: wav).path, "/tmp/synthetic/4F2A.flac")
        TestSupport.expectEqual(AudioUploadFormat.flacURL(besideWAV: wav).lastPathComponent, "4F2A.flac")
    }

    private static let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!

    /// One second of a 440 Hz synthetic tone, in recorder-sized chunks.
    private static func sineChunks(frames: Int = 16_000, chunk: Int = 1_024) -> [AVAudioPCMBuffer] {
        stride(from: 0, to: frames, by: chunk).map { start in
            let length = min(chunk, frames - start)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(length))!
            buffer.frameLength = AVAudioFrameCount(length)
            for offset in 0..<length {
                let phase = Double(start + offset) * 2 * .pi * 440 / 16_000
                buffer.int16ChannelData![0][offset] = Int16(8_000 * sin(phase))
            }
            return buffer
        }
    }

    private static func temporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FreeFlowTests-FLAC-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func testStreamingFLACRoundTripsLosslessly() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("tone.flac")
        guard let writer = StreamingFLACWriter(url: url, format: format) else {
            TestSupport.expect(false, "FLAC encoder should be available on macOS")
            return
        }
        let chunks = sineChunks()
        chunks.forEach(writer.write)
        TestSupport.expectEqual(writer.finish(expectedFrameCount: 16_000), url)

        let data = try! Data(contentsOf: url)
        TestSupport.expectEqual(Array(data.prefix(4)), Array("fLaC".utf8))
        TestSupport.expect(data.count < 32_000, "FLAC should be smaller than the 32 KB of PCM, got \(data.count)")

        let reader = try! AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true)
        TestSupport.expectEqual(reader.length, 16_000)
        let decoded = AVAudioPCMBuffer(pcmFormat: reader.processingFormat, frameCapacity: 16_000)!
        try! reader.read(into: decoded)
        TestSupport.expectEqual(decoded.frameLength, 16_000)
        var index = 0
        for chunk in chunks {
            for offset in 0..<Int(chunk.frameLength) {
                guard decoded.int16ChannelData![0][index] == chunk.int16ChannelData![0][offset] else {
                    TestSupport.expect(false, "FLAC must be lossless; sample \(index) differs")
                    return
                }
                index += 1
            }
        }
    }

    private static func testFLACWriterDropsIncompleteFile() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("short.flac")
        let writer = StreamingFLACWriter(url: url, format: format)!
        sineChunks(frames: 2_048).forEach(writer.write)
        TestSupport.expect(writer.finish(expectedFrameCount: 4_096) == nil, "A frame mismatch with the WAV must fall back")
        TestSupport.expect(!FileManager.default.fileExists(atPath: url.path), "A dropped FLAC file is deleted")

        let emptyURL = directory.appendingPathComponent("empty.flac")
        let empty = StreamingFLACWriter(url: emptyURL, format: format)!
        TestSupport.expect(empty.finish(expectedFrameCount: 0) == nil, "An empty recording has no FLAC upload")
        TestSupport.expect(!FileManager.default.fileExists(atPath: emptyURL.path), "An empty FLAC file is deleted")
    }

    private static func testUploadPrefersFLACAndFallsBackToWAV() async {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let wavURL = directory.appendingPathComponent("clip.wav")
        let flacURL = AudioUploadFormat.flacURL(besideWAV: wavURL)
        try! Data("synthetic wav bytes".utf8).write(to: wavURL)
        try! Data("synthetic flac bytes".utf8).write(to: flacURL)

        let pool = LLMSessionPool(makeSession: {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [FormatStubURLProtocol.self]
            return URLSession(configuration: configuration)
        })
        let service = try! TranscriptionService(
            apiKey: "synthetic-test-token",
            baseURL: "https://provider.invalid/v1",
            transcriptionModel: "gpt-4o-transcribe",
            sessionPool: pool
        )

        FormatStubURLProtocol.contentTypes = []
        FormatStubURLProtocol.flacStatus = 200
        let accepted = try! await service.transcribe(fileURL: wavURL, compressedFileURL: flacURL)
        TestSupport.expectEqual(accepted, "synthetic audio/flac")
        TestSupport.expectEqual(FormatStubURLProtocol.contentTypes, ["audio/flac"])

        FormatStubURLProtocol.contentTypes = []
        FormatStubURLProtocol.flacStatus = 415
        let fallback = try! await service.transcribe(fileURL: wavURL, compressedFileURL: flacURL)
        TestSupport.expectEqual(fallback, "synthetic audio/wav")
        TestSupport.expectEqual(FormatStubURLProtocol.contentTypes, ["audio/flac", "audio/wav"])

        FormatStubURLProtocol.contentTypes = []
        let missing = try! await service.transcribe(
            fileURL: wavURL,
            compressedFileURL: directory.appendingPathComponent("missing.flac")
        )
        TestSupport.expectEqual(missing, "synthetic audio/wav")
        TestSupport.expectEqual(FormatStubURLProtocol.contentTypes, ["audio/wav"])

        TestSupport.expect(TranscriptionService.isUnsupportedUploadFormatStatus(400), "400 may mean the format is rejected")
        TestSupport.expect(TranscriptionService.isUnsupportedUploadFormatStatus(415), "415 is unsupported media type")
        TestSupport.expect(!TranscriptionService.isUnsupportedUploadFormatStatus(401), "Auth failures do not retry as WAV")
        TestSupport.expect(!TranscriptionService.isUnsupportedUploadFormatStatus(500), "Server errors do not retry as WAV")
    }
}
