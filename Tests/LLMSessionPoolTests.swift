import Foundation

/// Fails the first `failuresRemaining` requests with `failure`, then answers 200.
private final class FlakyConnectionURLProtocol: URLProtocol {
    static var failuresRemaining = 0
    static var failure: Error = URLError(.networkConnectionLost)
    static var requestCount = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requestCount += 1
        if Self.failuresRemaining > 0 {
            Self.failuresRemaining -= 1
            client?.urlProtocol(self, didFailWithError: Self.failure)
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{\"text\":\"synthetic\"}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class TestClock: @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 1_000_000)
}

enum LLMSessionPoolTests {
    static func run() async {
        testIdleExpiryDecision()
        testPoolReplacesSessionOnlyAfterIdleWindow()
        testStaleConnectionClassification()
        testPreconnectOrigins()
        await testStaleConnectionRetriesOnceOnFreshSession()
        await testOtherErrorsAreNotRetried()
        await testPersistentStaleConnectionFailsAfterOneRetry()
    }

    private static func makeStubPool(clock: TestClock = TestClock()) -> (LLMSessionPool, () -> Int) {
        var created = 0
        let pool = LLMSessionPool(
            idleTimeout: 300,
            now: { clock.now },
            makeSession: {
                created += 1
                let configuration = URLSessionConfiguration.ephemeral
                configuration.protocolClasses = [FlakyConnectionURLProtocol.self]
                return URLSession(configuration: configuration)
            }
        )
        return (pool, { created })
    }

    private static func testIdleExpiryDecision() {
        let start = Date(timeIntervalSince1970: 0)
        TestSupport.expectEqual(LLMSessionPool.defaultIdleTimeout, 300)
        TestSupport.expect(!LLMSessionPool.isIdleExpired(lastActivity: nil, now: start, idleTimeout: 300), "No activity yet is not expired")
        TestSupport.expect(!LLMSessionPool.isIdleExpired(lastActivity: start, now: start.addingTimeInterval(299), idleTimeout: 300), "Inside the window stays warm")
        TestSupport.expect(LLMSessionPool.isIdleExpired(lastActivity: start, now: start.addingTimeInterval(300), idleTimeout: 300), "The window boundary expires")
        TestSupport.expect(LLMSessionPool.isIdleExpired(lastActivity: start, now: start.addingTimeInterval(3_600), idleTimeout: 300), "Long idle expires")
    }

    private static func testPoolReplacesSessionOnlyAfterIdleWindow() {
        let clock = TestClock()
        let (pool, created) = makeStubPool(clock: clock)
        let first = pool.currentSession()
        clock.now += 240
        TestSupport.expect(pool.currentSession() === first, "A request within five minutes reuses the session")
        clock.now += 240
        TestSupport.expect(pool.currentSession() === first, "Each request extends the idle window")
        clock.now += 301
        let replaced = pool.currentSession()
        TestSupport.expect(replaced !== first, "Five idle minutes start a fresh session")
        TestSupport.expectEqual(created(), 2)

        pool.discard(first)
        TestSupport.expect(pool.currentSession() === replaced, "Discarding a stale session leaves the current one alone")
        pool.discard(replaced)
        TestSupport.expect(pool.currentSession() !== replaced, "Discarding the current session forces a fresh one")
        TestSupport.expectEqual(created(), 3)
    }

    private static func testStaleConnectionClassification() {
        TestSupport.expect(LLMAPITransport.isStaleConnectionError(URLError(.networkConnectionLost)), "Connection lost is stale")
        TestSupport.expect(LLMAPITransport.isStaleConnectionError(NSError(domain: NSPOSIXErrorDomain, code: Int(ECONNRESET))), "Reset socket is stale")
        let wrappedReset = URLError(.unknown, userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EPIPE))])
        TestSupport.expect(LLMAPITransport.isStaleConnectionError(wrappedReset), "Broken pipe under a URL error is stale")
        for code in [URLError.Code.timedOut, .cancelled, .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .userAuthenticationRequired] {
            TestSupport.expect(!LLMAPITransport.isStaleConnectionError(URLError(code)), "\(code) must not retry")
        }
        TestSupport.expect(!LLMAPITransport.isStaleConnectionError(CancellationError()), "Cancellation must not retry")
    }

    private static func testPreconnectOrigins() {
        let origins = LLMAPITransport.preconnectOrigins(for: [
            "https://provider.invalid/openai/v1",
            " https://PROVIDER.invalid/other?x=1 ",
            "https://user:secret@speech.invalid:8443/v1",
            "http://localhost:11434/v1",
            "",
            "ftp://files.invalid",
            "not a url"
        ])
        TestSupport.expectEqual(origins.map(\.absoluteString), [
            "https://provider.invalid/",
            "https://speech.invalid:8443/",
            "http://localhost:11434/"
        ])
    }

    private static func request() -> URLRequest {
        var request = URLRequest(url: URL(string: "https://provider.invalid/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        return request
    }

    private static func testStaleConnectionRetriesOnceOnFreshSession() async {
        let (pool, created) = makeStubPool()
        FlakyConnectionURLProtocol.requestCount = 0
        FlakyConnectionURLProtocol.failure = URLError(.networkConnectionLost)
        FlakyConnectionURLProtocol.failuresRemaining = 1
        let warm = pool.currentSession()
        do {
            let (_, response) = try await LLMAPITransport.upload(for: request(), from: Data("synthetic".utf8), pool: pool)
            TestSupport.expectEqual((response as? HTTPURLResponse)?.statusCode, 200)
        } catch {
            TestSupport.expect(false, "A stale connection should succeed on retry, got \(error)")
        }
        TestSupport.expectEqual(FlakyConnectionURLProtocol.requestCount, 2)
        TestSupport.expectEqual(created(), 2)
        TestSupport.expect(pool.currentSession() !== warm, "The poisoned session is not reused")
    }

    private static func testOtherErrorsAreNotRetried() async {
        let (pool, created) = makeStubPool()
        FlakyConnectionURLProtocol.requestCount = 0
        FlakyConnectionURLProtocol.failure = URLError(.cannotFindHost)
        FlakyConnectionURLProtocol.failuresRemaining = 1
        do {
            _ = try await LLMAPITransport.upload(for: request(), from: Data("synthetic".utf8), pool: pool)
            TestSupport.expect(false, "A non-connection error must surface")
        } catch {
            TestSupport.expectEqual((error as? URLError)?.code, .cannotFindHost)
        }
        TestSupport.expectEqual(FlakyConnectionURLProtocol.requestCount, 1)
        TestSupport.expectEqual(created(), 1)
    }

    private static func testPersistentStaleConnectionFailsAfterOneRetry() async {
        let (pool, _) = makeStubPool()
        FlakyConnectionURLProtocol.requestCount = 0
        FlakyConnectionURLProtocol.failure = URLError(.networkConnectionLost)
        FlakyConnectionURLProtocol.failuresRemaining = 5
        do {
            _ = try await LLMAPITransport.upload(for: request(), from: Data("synthetic".utf8), pool: pool)
            TestSupport.expect(false, "A connection that keeps failing must surface")
        } catch {
            TestSupport.expectEqual((error as? URLError)?.code, .networkConnectionLost)
        }
        TestSupport.expectEqual(FlakyConnectionURLProtocol.requestCount, 2)
        FlakyConnectionURLProtocol.failuresRemaining = 0
    }
}
