/// Accurate Vision requests share one process-wide slot, including warmups. Concurrent model
/// initialization can stall them; a timed-out request must not overlap its replacement.
actor RecognitionSlots {
    static let shared = RecognitionSlots(count: 1)

    private struct Waiter {
        let id: Int
        let continuation: CheckedContinuation<Void, Error>
    }

    private var free: Int
    private var waiting: [Waiter] = []
    private var nextWaiter = 0

    init(count: Int) {
        free = count
    }

    /// Runs `operation` in a slot, waiting cancellably if capacity is taken. A timeout belongs outside
    /// this call: the slot stays occupied until the actual operation ends, even if it ignores cancellation.
    nonisolated func run<T>(_ operation: () async throws -> T) async throws -> T {
        try await acquire()
        do {
            try Task.checkCancellation()
            let value = try await operation()
            await release()
            return value
        } catch {
            await release()
            throw error
        }
    }

    /// Background warmup is useful only when it can start now. It must never queue ahead of a real
    /// recognition. As with `run`, a started native operation owns the slot until it actually ends.
    nonisolated func runIfAvailable<T>(_ operation: () async throws -> T) async throws -> T? {
        guard try await acquireIfAvailable() else { return nil }
        do {
            try Task.checkCancellation()
            let value = try await operation()
            await release()
            return value
        } catch {
            await release()
            throw error
        }
    }

    private func acquireIfAvailable() throws -> Bool {
        try Task.checkCancellation()
        guard free > 0, waiting.isEmpty else { return false }
        free -= 1
        return true
    }

    private func acquire() async throws {
        try Task.checkCancellation()
        if free > 0 {
            free -= 1
        } else {
            let id = nextWaiter
            nextWaiter += 1
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    if Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        waiting.append(Waiter(id: id, continuation: continuation))
                    }
                }
            } onCancel: {
                Task { await self.cancelWaiter(id) }
            }
        }
    }

    private func cancelWaiter(_ id: Int) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func release() {
        if waiting.isEmpty {
            free += 1
        } else {
            waiting.removeFirst().continuation.resume()
        }
    }
}
