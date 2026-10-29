import Foundation

private struct StepFailure: Error, Equatable {
    let step: String
}

@MainActor
private final class StepLog {
    private(set) var calls: [String] = []

    func step(_ name: String, returning text: String) -> () async throws -> String {
        { self.calls.append(name); return text }
    }

    func failingStep(_ name: String) -> () async throws -> String {
        { self.calls.append(name); throw StepFailure(step: name) }
    }

    func cancelledStep(_ name: String) -> () async throws -> String {
        { self.calls.append(name); throw CancellationError() }
    }
}

enum RawTranscriptResolverTests {
    @MainActor
    static func run() async {
        await testRealtimeSuccessUsesNothingElse()
        await testRealtimeFailureAfterServerContactRetriesEndpoint()
        await testUnreachableRealtimeSkipsEndpointForMainProvider()
        await testUnreachableRealtimeWithoutMainProviderStillTriesEndpoint()
        await testEndpointFailureFallsBackToMainProvider()
        await testEndpointFailureWithoutMainProviderRethrows()
        await testMainProviderFailureIsReported()
        await testCancellationNeverFallsBack()
    }

    @MainActor
    private static func testRealtimeSuccessUsesNothingElse() async {
        let log = StepLog()
        let resolver = RawTranscriptResolver(
            realtime: log.step("realtime", returning: "streamed"),
            realtimeReachedServer: { true },
            transcriptionEndpoint: log.step("endpoint", returning: "uploaded"),
            mainProvider: log.step("main", returning: "fallback")
        )
        let result = try? await resolver.resolve()
        TestSupport.expectEqual(result?.transcript, "streamed")
        TestSupport.expectEqual(result?.source, .realtime)
        TestSupport.expectEqual(log.calls, ["realtime"])
    }

    @MainActor
    private static func testRealtimeFailureAfterServerContactRetriesEndpoint() async {
        let log = StepLog()
        var fallbacks: [RawTranscriptSource] = []
        let resolver = RawTranscriptResolver(
            realtime: log.failingStep("realtime"),
            realtimeReachedServer: { true },
            transcriptionEndpoint: log.step("endpoint", returning: "uploaded"),
            mainProvider: log.step("main", returning: "fallback")
        )
        let result = try? await resolver.resolve { fallbacks.append($0) }
        TestSupport.expectEqual(result?.transcript, "uploaded")
        TestSupport.expectEqual(result?.source, .transcriptionEndpoint)
        TestSupport.expectEqual(log.calls, ["realtime", "endpoint"])
        TestSupport.expectEqual(fallbacks, [.transcriptionEndpoint])
    }

    @MainActor
    private static func testUnreachableRealtimeSkipsEndpointForMainProvider() async {
        let log = StepLog()
        var fallbacks: [RawTranscriptSource] = []
        let resolver = RawTranscriptResolver(
            realtime: log.failingStep("realtime"),
            realtimeReachedServer: { false },
            transcriptionEndpoint: log.step("endpoint", returning: "uploaded"),
            mainProvider: log.step("main", returning: "fallback")
        )
        let result = try? await resolver.resolve { fallbacks.append($0) }
        TestSupport.expectEqual(result?.transcript, "fallback")
        TestSupport.expectEqual(result?.source, .mainProvider)
        TestSupport.expectEqual(log.calls, ["realtime", "main"])
        TestSupport.expectEqual(fallbacks, [.mainProvider])
    }

    @MainActor
    private static func testUnreachableRealtimeWithoutMainProviderStillTriesEndpoint() async {
        let log = StepLog()
        let resolver = RawTranscriptResolver(
            realtime: log.failingStep("realtime"),
            realtimeReachedServer: { false },
            transcriptionEndpoint: log.step("endpoint", returning: "uploaded"),
            mainProvider: nil
        )
        let result = try? await resolver.resolve()
        TestSupport.expectEqual(result?.transcript, "uploaded")
        TestSupport.expectEqual(log.calls, ["realtime", "endpoint"])
    }

    @MainActor
    private static func testEndpointFailureFallsBackToMainProvider() async {
        let log = StepLog()
        let resolver = RawTranscriptResolver(
            realtime: nil,
            transcriptionEndpoint: log.failingStep("endpoint"),
            mainProvider: log.step("main", returning: "fallback")
        )
        let result = try? await resolver.resolve()
        TestSupport.expectEqual(result?.transcript, "fallback")
        TestSupport.expectEqual(result?.source, .mainProvider)
        TestSupport.expectEqual(log.calls, ["endpoint", "main"])
    }

    @MainActor
    private static func testEndpointFailureWithoutMainProviderRethrows() async {
        let log = StepLog()
        let resolver = RawTranscriptResolver(
            realtime: nil,
            transcriptionEndpoint: log.failingStep("endpoint"),
            mainProvider: nil
        )
        do {
            _ = try await resolver.resolve()
            TestSupport.expect(false, "Expected the endpoint failure to be rethrown")
        } catch {
            TestSupport.expectEqual(error as? StepFailure, StepFailure(step: "endpoint"))
        }
        TestSupport.expectEqual(log.calls, ["endpoint"])
    }

    @MainActor
    private static func testMainProviderFailureIsReported() async {
        let log = StepLog()
        let resolver = RawTranscriptResolver(
            realtime: log.failingStep("realtime"),
            realtimeReachedServer: { true },
            transcriptionEndpoint: log.failingStep("endpoint"),
            mainProvider: log.failingStep("main")
        )
        do {
            _ = try await resolver.resolve()
            TestSupport.expect(false, "Expected the main provider failure to be thrown")
        } catch {
            TestSupport.expectEqual(error as? StepFailure, StepFailure(step: "main"))
        }
        TestSupport.expectEqual(log.calls, ["realtime", "endpoint", "main"])
    }

    @MainActor
    private static func testCancellationNeverFallsBack() async {
        let log = StepLog()
        let realtimeCancelled = RawTranscriptResolver(
            realtime: log.cancelledStep("realtime"),
            realtimeReachedServer: { false },
            transcriptionEndpoint: log.step("endpoint", returning: "uploaded"),
            mainProvider: log.step("main", returning: "fallback")
        )
        do {
            _ = try await realtimeCancelled.resolve()
            TestSupport.expect(false, "Expected cancellation from realtime")
        } catch {
            TestSupport.expect(error is CancellationError, "Expected CancellationError, got \(error)")
        }
        TestSupport.expectEqual(log.calls, ["realtime"])

        let endpointLog = StepLog()
        let endpointCancelled = RawTranscriptResolver(
            realtime: nil,
            transcriptionEndpoint: endpointLog.cancelledStep("endpoint"),
            mainProvider: endpointLog.step("main", returning: "fallback")
        )
        do {
            _ = try await endpointCancelled.resolve()
            TestSupport.expect(false, "Expected cancellation from the endpoint")
        } catch {
            TestSupport.expect(error is CancellationError, "Expected CancellationError, got \(error)")
        }
        TestSupport.expectEqual(endpointLog.calls, ["endpoint"])
    }
}
