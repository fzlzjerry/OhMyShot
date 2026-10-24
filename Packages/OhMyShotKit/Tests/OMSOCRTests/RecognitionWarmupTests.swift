import Foundation
import Synchronization
import Testing
@testable import OMSOCR

struct RecognitionWarmupTests {
    private actor Gate {
        private var open = false
        private var waiting: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            guard !open else { return }
            await withCheckedContinuation { waiting.append($0) }
        }

        func release() {
            open = true
            let continuations = waiting
            waiting = []
            continuations.forEach { $0.resume() }
        }
    }

    private func settle(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(5)) }
        try #require(condition())
    }

    @Test func successfulModelsAreWarmedOnlyOnce() async throws {
        let warmup = RecognitionWarmup()
        let starts = Mutex(0)
        for _ in 0..<3 {
            #expect(try await warmup.run(for: ["zh-Hans", "en"]) {
                starts.withLock { $0 += 1 }
                return true
            })
        }
        #expect(starts.withLock { $0 } == 1)
        #expect(try await warmup.run(for: ["en"]) {
            starts.withLock { $0 += 1 }
            return true
        })
        #expect(starts.withLock { $0 } == 2)
    }

    @Test func concurrentWarmupsDoNotDuplicateWork() async throws {
        let warmup = RecognitionWarmup()
        let gate = Gate()
        defer { Task { await gate.release() } }
        let starts = Mutex(0)
        let first = Task {
            try await warmup.run(for: ["zh-Hans", "en"]) {
                starts.withLock { $0 += 1 }
                await gate.wait()
                return true
            }
        }
        try await settle { starts.withLock { $0 } == 1 }
        #expect(try await warmup.run(for: ["zh-Hans", "en"]) {
            starts.withLock { $0 += 1 }
            return true
        } == false)
        #expect(starts.withLock { $0 } == 1)
        await gate.release()
        #expect(try await first.value)
    }

    @Test func skippedAndFailedWarmupsCanRetry() async throws {
        struct Failure: Error {}
        let warmup = RecognitionWarmup()
        #expect(try await warmup.run(for: ["en"]) { false } == false)
        await #expect(throws: Failure.self) {
            try await warmup.run(for: ["en"]) { throw Failure() }
        }
        #expect(try await warmup.run(for: ["en"]) { true })
    }

    @Test func cancelledWarmupDoesNotContinueToAnotherModelAndCanRetry() async throws {
        let warmup = RecognitionWarmup()
        let starts = Mutex(0)
        let task = Task {
            for languages in [["zh-Hans", "en"], ["en"]] {
                guard try await warmup.run(for: languages, {
                    starts.withLock { $0 += 1 }
                    try await Task.sleep(for: .seconds(10))
                    return true
                }) else { return }
            }
        }
        try await settle { starts.withLock { $0 } == 1 }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(starts.withLock { $0 } == 1)
        #expect(try await warmup.run(for: ["zh-Hans", "en"]) { true })
    }

    @Test func warmupSkipsABusySlotInsteadOfQueueing() async throws {
        let slots = RecognitionSlots(count: 1)
        let gate = Gate()
        defer { Task { await gate.release() } }
        let started = Mutex(false)
        let holder = Task {
            try await slots.run {
                started.withLock { $0 = true }
                await gate.wait()
            }
        }
        try await settle { started.withLock { $0 } }
        let value = try await slots.runIfAvailable { 1 }
        #expect(value == nil)
        await gate.release()
        try await holder.value
        #expect(try await slots.runIfAvailable { 2 } == 2)
    }

    @Test func timedOutWarmupRetainsTheSlotUntilNativeWorkEnds() async throws {
        let slots = RecognitionSlots(count: 1)
        let gate = Gate()
        defer { Task { await gate.release() } }
        let started = Mutex(false)
        let finished = Mutex(false)
        let task = Task {
            try await withTimeout(.milliseconds(200)) {
                try await slots.runIfAvailable {
                    started.withLock { $0 = true }
                    await gate.wait()
                    finished.withLock { $0 = true }
                    return 1
                }
            }
        }
        try await settle { started.withLock { $0 } }
        await #expect(throws: OCRError.timedOut) { try await task.value }
        #expect(try await slots.runIfAvailable { 2 } == nil)
        await gate.release()
        try await settle { finished.withLock { $0 } }
        // Release follows the native operation's completion on the slot's actor.
        #expect(try await withTimeout(.seconds(1)) { try await slots.run { 3 } } == 3)
    }
}
