import Foundation

/// Run `body`, retrying up to `attempts` times with exponential backoff
/// (2s, 4s, … between tries) on failure. `CancellationError` is passed straight
/// through — it never counts as a retryable failure and never sleeps.
///
/// Shared by the model-load paths in `LLMService` and `VoiceprintService`,
/// which all want the same transient-network retry. `#isolation` makes the
/// helper inherit the caller's actor isolation, so `body` may freely touch the
/// caller actor's state under Swift's complete concurrency checking.
func withExponentialBackoff<T>(
    attempts: Int,
    isolation: isolated (any Actor)? = #isolation,
    _ body: () async throws -> T
) async throws -> T {
    precondition(attempts >= 1, "withExponentialBackoff needs at least one attempt")
    var lastError: Error?
    for attempt in 0..<attempts {
        do {
            return try await body()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            lastError = error
            if attempt < attempts - 1 {
                try await Task.sleep(for: .seconds(Double(1 << (attempt + 1))))
            }
        }
    }
    // Unreachable for attempts >= 1: the loop either returned or set lastError.
    throw lastError ?? CancellationError()
}
