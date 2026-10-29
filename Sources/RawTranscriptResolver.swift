import Foundation

/// Which path produced a raw transcript, for logging.
enum RawTranscriptSource: Equatable {
    case realtime
    case transcriptionEndpoint
    case mainProvider
}

/// Picks the raw transcript from, in order: the realtime stream, a file upload
/// to the transcription endpoint, and a file upload to the main provider.
///
/// The main provider step exists only when a separate transcription endpoint
/// is configured (for example a self-hosted server), so an unreachable
/// endpoint still produces a transcript. When the realtime socket never heard
/// from its server, the endpoint is treated as unreachable and its upload is
/// skipped instead of waiting out the upload timeout.
struct RawTranscriptResolver {
    /// Commits the realtime stream and returns its final transcript. Nil when
    /// realtime streaming is off.
    var realtime: (() async throws -> String)?
    /// Whether the realtime socket received any server event. Read after the
    /// realtime step fails.
    var realtimeReachedServer: () -> Bool = { false }
    var transcriptionEndpoint: () async throws -> String
    var mainProvider: (() async throws -> String)?

    func resolve(
        onFallback: (RawTranscriptSource) -> Void = { _ in }
    ) async throws -> (transcript: String, source: RawTranscriptSource) {
        if let realtime {
            do {
                try Task.checkCancellation()
                return (try await realtime(), .realtime)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                if !realtimeReachedServer(), let mainProvider {
                    onFallback(.mainProvider)
                    return (try await mainProvider(), .mainProvider)
                }
                onFallback(.transcriptionEndpoint)
            }
        }

        do {
            return (try await transcriptionEndpoint(), .transcriptionEndpoint)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard let mainProvider else { throw error }
            try Task.checkCancellation()
            onFallback(.mainProvider)
            return (try await mainProvider(), .mainProvider)
        }
    }
}
