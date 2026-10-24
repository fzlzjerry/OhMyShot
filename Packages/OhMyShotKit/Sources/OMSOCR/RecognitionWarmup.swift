/// A language model needs warming only once per process. Concurrent callers skip work already under
/// way, and only successful warmups are kept: a busy slot, failure, or cancellation can be tried later.
actor RecognitionWarmup {
    static let shared = RecognitionWarmup()

    private var completed: Set<[String]> = []
    private var running: Set<[String]> = []

    func run(for languages: [String], _ operation: @Sendable () async throws -> Bool) async throws -> Bool {
        try Task.checkCancellation()
        if completed.contains(languages) { return true }
        guard running.insert(languages).inserted else { return false }
        defer { running.remove(languages) }
        let succeeded = try await operation()
        try Task.checkCancellation()
        if succeeded { completed.insert(languages) }
        return succeeded
    }
}
