import Foundation

/// Actor reentrancy must not let another request touch MLX while a load awaits.
/// Cancellation removes queued requests, and ownership lasts until the caller
/// has finished all model work (including cancellation of token generation).
actor SerialGate {
    private var held = false
    private var waiters: [(UUID, CheckedContinuation<Void, Error>)] = []

    func acquire() async throws {
        try Task.checkCancellation()
        if !held { held = true; return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append((id, continuation))
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
        // Release the transferred ownership if cancellation raced with release.
        if Task.isCancelled {
            release()
            throw CancellationError()
        }
    }

    func release() {
        if waiters.isEmpty { held = false }
        else { waiters.removeFirst().1.resume() }
    }

    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.0 == id }) else { return }
        waiters.remove(at: index).1.resume(throwing: CancellationError())
    }
}
