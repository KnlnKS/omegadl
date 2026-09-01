import Foundation

func retrying<T>(attempts: Int, _ body: () async throws -> T) async throws -> T {
    for attempt in 0..<attempts {
        try Task.checkCancellation()
        do {
            return try await body()
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as MegaError where !error.isRetryable {
            throw error
        } catch {
            if attempt == attempts - 1 { throw error }
        }
        try await Task.sleep(for: .seconds(1 << attempt))
    }
    throw MegaError.httpStatus(0)
}
