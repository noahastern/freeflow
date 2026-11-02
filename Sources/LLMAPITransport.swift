import Foundation
import os

private let transportLog = OSLog(subsystem: "com.zachlatta.freeflow", category: "Transport")

/// One long-lived URLSession for provider requests, so transcription and
/// cleanup reuse warm TCP/TLS connections instead of opening new ones on the
/// critical path. After `idleTimeout` with no requests the session is dropped
/// and the next request starts on a fresh one.
final class LLMSessionPool: @unchecked Sendable {
    /// Matches the microphone's "after use" window.
    static let defaultIdleTimeout: TimeInterval = MicrophoneReadinessPreference.afterUseIdleTimeout
    static let shared = LLMSessionPool()

    private let lock = NSLock()
    private let idleTimeout: TimeInterval
    private let now: () -> Date
    private let makeSession: () -> URLSession
    private var session: URLSession?
    private var lastActivity: Date?

    init(
        idleTimeout: TimeInterval = LLMSessionPool.defaultIdleTimeout,
        now: @escaping () -> Date = Date.init,
        makeSession: @escaping () -> URLSession = LLMSessionPool.makeDefaultSession
    ) {
        self.idleTimeout = idleTimeout
        self.now = now
        self.makeSession = makeSession
    }

    static func makeDefaultSession() -> URLSession {
        // Ephemeral keeps cookies, credentials, and caches in memory only.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        // No state carries between requests other than the connections themselves.
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        // Session timers are only outer caps. Each request's own timeout is
        // enforced as a total deadline by `LLMAPITransport`.
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 300
        return URLSession(configuration: configuration)
    }

    /// True when the session has gone unused long enough that it should be replaced.
    static func isIdleExpired(lastActivity: Date?, now: Date, idleTimeout: TimeInterval) -> Bool {
        guard let lastActivity else { return false }
        return now.timeIntervalSince(lastActivity) >= idleTimeout
    }

    /// The session to use now. Counts as activity and replaces an idle session.
    func currentSession() -> URLSession {
        lock.lock()
        defer { lock.unlock() }
        let current = now()
        if let existing = session,
           !Self.isIdleExpired(lastActivity: lastActivity, now: current, idleTimeout: idleTimeout) {
            lastActivity = current
            return existing
        }
        session?.finishTasksAndInvalidate()
        let fresh = makeSession()
        session = fresh
        lastActivity = current
        return fresh
    }

    /// Drops `failed` if it is still current, so the next request opens new connections.
    func discard(_ failed: URLSession) {
        lock.lock()
        let shouldInvalidate = session === failed
        if shouldInvalidate {
            session = nil
            lastActivity = nil
        }
        lock.unlock()
        if shouldInvalidate {
            failed.finishTasksAndInvalidate()
        }
    }
}

enum LLMAPITransport {
    private static func timeout(for request: URLRequest) -> TimeInterval {
        let requestTimeout = request.timeoutInterval
        guard requestTimeout.isFinite, requestTimeout > 0 else {
            return 60
        }
        return requestTimeout
    }

    /// Errors that mean a reused connection went stale (the server or a middlebox
    /// closed it) rather than that the provider is unreachable or rejected the request.
    static func isStaleConnectionError(_ error: Error) -> Bool {
        let staleCodes: Set<Int32> = [ECONNRESET, EPIPE, ENOTCONN]
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain {
            return staleCodes.contains(Int32(nsError.code))
        }
        guard let urlError = error as? URLError else { return false }
        if urlError.code == .networkConnectionLost { return true }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain {
            return staleCodes.contains(Int32(underlying.code))
        }
        return false
    }

    /// Runs `operation` on the pool's warm session. A stale-connection error is
    /// retried once on a fresh session. The whole exchange, retry included, is
    /// bounded by the request's own timeout and fails with `URLError(.timedOut)`.
    static func pooled<T: Sendable>(
        _ request: URLRequest,
        pool: LLMSessionPool,
        operation: @escaping @Sendable (URLSession) async throws -> T
    ) async throws -> T {
        let deadline = timeout(for: request)
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                let session = pool.currentSession()
                do {
                    return try await operation(session)
                } catch where isStaleConnectionError(error) && !Task.isCancelled {
                    os_log(.info, log: transportLog, "stale connection; retrying once on a fresh session")
                    pool.discard(session)
                    return try await operation(pool.currentSession())
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(deadline * 1_000_000_000))
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw URLError(.unknown)
            }
            return result
        }
    }

    static func data(
        for request: URLRequest,
        pool: LLMSessionPool = .shared
    ) async throws -> (Data, URLResponse) {
        try await data(for: request, cache: TemperatureCapabilityCache.shared, pool: pool)
    }

    static func data(
        for request: URLRequest,
        cache: TemperatureCapabilityCache,
        pool: LLMSessionPool = .shared
    ) async throws -> (Data, URLResponse) {
        try await pooled(request, pool: pool) { session in
            try await data(for: request, using: session, cache: cache)
        }
    }

    /// Opens connections to each provider origin while the user is still
    /// speaking, so TLS is ready when the transcript upload starts. Sends a bare
    /// HEAD to the origin root: no credentials, no body, no user content, and
    /// no side effects. The response, including any error, is ignored.
    static func preconnect(to baseURLs: [String], pool: LLMSessionPool = .shared) {
        let origins = preconnectOrigins(for: baseURLs)
        guard !origins.isEmpty else { return }
        let session = pool.currentSession()
        for origin in origins {
            var request = URLRequest(url: origin)
            request.httpMethod = "HEAD"
            request.timeoutInterval = 5
            session.dataTask(with: request).resume()
        }
    }

    /// Unique scheme/host/port origins for the given base URLs, as root URLs.
    /// Invalid, non-HTTP(S), and empty entries are skipped; paths, queries, and
    /// any embedded credentials are dropped.
    static func preconnectOrigins(for baseURLs: [String]) -> [URL] {
        var seen = Set<String>()
        var origins: [URL] = []
        for raw in baseURLs {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let parsed = URLComponents(string: trimmed),
                  let scheme = parsed.scheme?.lowercased(), scheme == "https" || scheme == "http",
                  let host = parsed.host?.lowercased(), !host.isEmpty else { continue }
            var origin = URLComponents()
            origin.scheme = scheme
            origin.host = host
            origin.port = parsed.port
            origin.path = "/"
            guard let url = origin.url, seen.insert(url.absoluteString).inserted else { continue }
            origins.append(url)
        }
        return origins
    }

    static func data(
        for request: URLRequest,
        using session: URLSession
    ) async throws -> (Data, URLResponse) {
        try await data(for: request, using: session, cache: TemperatureCapabilityCache.shared)
    }

    static func data(
        for request: URLRequest,
        using session: URLSession,
        cache: TemperatureCapabilityCache
    ) async throws -> (Data, URLResponse) {
        let observation = cache.beginObservation(for: request)
        let capability = observation.capability
        let outgoing = capability == .unsupported ? requestWithoutTemperature(request) ?? request : request
        let result = try await session.data(for: outgoing)
        if let response = result.1 as? HTTPURLResponse, response.statusCode == 200,
           isValidCompletionResponse(result.0), payloadHasTemperature(outgoing) {
            cache.record(.supported, for: outgoing, observation: observation)
        }
        guard capability != .unsupported,
              let response = result.1 as? HTTPURLResponse,
              response.statusCode == 400,
              let retry = requestWithoutUnsupportedTemperature(outgoing, errorData: result.0) else {
            return result
        }
        cache.record(.unsupported, for: outgoing, observation: observation)
        let retried = try await session.data(for: retry)
        return retried
    }

    private static func payloadHasTemperature(_ request: URLRequest) -> Bool {
        guard let body = request.httpBody,
              let payload = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return false }
        return payload["temperature"] != nil
    }

    private static func isValidCompletionResponse(_ data: Data) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]], !choices.isEmpty,
              let message = choices[0]["message"] as? [String: Any] else { return false }
        return message["content"] != nil || message["reasoning"] != nil
    }

    private static func requestWithoutTemperature(_ request: URLRequest) -> URLRequest? {
        guard let body = request.httpBody,
              var payload = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              payload.removeValue(forKey: "temperature") != nil,
              let retryBody = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        var retry = request
        retry.httpBody = retryBody
        return retry
    }

    private static func requestWithoutUnsupportedTemperature(
        _ request: URLRequest,
        errorData: Data
    ) -> URLRequest? {
        guard request.httpBody != nil,
              let error = try? JSONSerialization.jsonObject(with: errorData) as? [String: Any],
              let details = error["error"] as? [String: Any] else {
            return nil
        }
        let code = (details["code"] as? String ?? "").lowercased()
        let param = (details["param"] as? String ?? "").lowercased()
        let message = (details["message"] as? String ?? "").lowercased()
        let unsupportedCode = code == "unsupported_parameter" || code == "unsupported_value"
        let unsupportedMessage = message.contains("unsupported") ||
            message.contains("not supported") || message.contains("does not support")
        guard unsupportedCode && param == "temperature" && unsupportedMessage else {
            return nil
        }
        return requestWithoutTemperature(request)
    }

    static func upload(
        for request: URLRequest,
        from bodyData: Data,
        pool: LLMSessionPool = .shared
    ) async throws -> (Data, URLResponse) {
        // Reuses the warm session; a poisoned connection is retried once on a fresh one.
        try await pooled(request, pool: pool) { session in
            try await session.upload(for: request, from: bodyData)
        }
    }
}
