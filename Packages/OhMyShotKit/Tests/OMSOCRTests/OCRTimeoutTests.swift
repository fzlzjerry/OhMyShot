import CoreGraphics
import Foundation
import Synchronization
import Testing
@testable import OMSOCR

struct OCRTimeoutTests {
    /// Deliberately ignores task cancellation, as native work can; only the test can finish it.
    private final class Gate: Sendable {
        private struct State {
            var open = false
            var waiting: [CheckedContinuation<Void, Never>] = []
        }
        private let state = Mutex(State())

        func wait() async {
            await withCheckedContinuation { continuation in
                let open = state.withLock { state in
                    if !state.open { state.waiting.append(continuation) }
                    return state.open
                }
                if open { continuation.resume() }
            }
        }

        func open() {
            let waiting = state.withLock { state in
                state.open = true
                defer { state.waiting = [] }
                return state.waiting
            }
            waiting.forEach { $0.resume() }
        }
    }

    private final class Runs: Sendable {
        struct Counts {
            var started = 0
            var running = 0
            var peak = 0
        }
        let counts = Mutex(Counts())
        func start() {
            counts.withLock { $0.started += 1; $0.running += 1; $0.peak = max($0.peak, $0.running) }
        }
        func finish() { counts.withLock { $0.running -= 1 } }
    }

    private static func settle(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(5)) }
        try #require(condition())
    }

    @Test func timedOutNativeWorkKeepsItsSlotsAndQueuedWorkHasABoundedDeadline() async throws {
        let slots = RecognitionSlots(count: 2)
        let gate = Gate()
        defer { gate.open() }
        let runs = Runs()
        func request() -> Task<Int, Error> {
            Task {
                try await withTimeout(.milliseconds(200)) {
                    try await slots.run {
                        runs.start()
                        await gate.wait()
                        runs.finish()
                        return 1
                    }
                }
            }
        }
        let first = request(), second = request()
        try await Self.settle { runs.counts.withLock { $0.running == 2 } }
        await #expect(throws: OCRError.timedOut) { try await first.value }
        await #expect(throws: OCRError.timedOut) { try await second.value }
        // Both callers have left, but the native operations are still alive.
        #expect(runs.counts.withLock { $0.running == 2 && $0.peak == 2 })
        await #expect(throws: OCRError.timedOut) {
            try await withTimeout(.milliseconds(30)) {
                try await slots.run {
                    runs.start()
                    runs.finish()
                    return 3
                }
            }
        }
        #expect(runs.counts.withLock { $0.started == 2 })
        gate.open()
        try await Self.settle { runs.counts.withLock { $0.running == 0 } }
        #expect(try await withTimeout(.seconds(1)) { try await slots.run { 42 } } == 42)
        #expect(runs.counts.withLock { $0.peak == 2 })
    }

    @Test func cancellingAQueuedCallerStopsWaitingWithoutStartingItsOperation() async throws {
        let slots = RecognitionSlots(count: 1)
        let gate = Gate()
        defer { gate.open() }
        let runs = Runs()
        let holder = Task {
            try await slots.run {
                runs.start()
                await gate.wait()
                runs.finish()
            }
        }
        try await Self.settle { runs.counts.withLock { $0.running == 1 } }
        let queued = Task {
            try await slots.run {
                runs.start()
                runs.finish()
            }
        }
        try await Task.sleep(for: .milliseconds(20))
        queued.cancel()
        await #expect(throws: CancellationError.self) {
            try await withTimeout(.seconds(1)) { try await queued.value }
        }
        #expect(runs.counts.withLock { $0.started == 1 })
        gate.open()
        try await holder.value
        #expect(try await withTimeout(.seconds(1)) { try await slots.run { 7 } } == 7)
        #expect(runs.counts.withLock { $0.started == 1 })
    }

    @Test func processWideRequestsInitializeOneAtATime() async throws {
        let gate = Gate()
        defer { gate.open() }
        let runs = Runs()
        let first = Task {
            try await RecognitionSlots.shared.run {
                runs.start()
                await gate.wait()
                runs.finish()
            }
        }
        try await Self.settle { runs.counts.withLock { $0.running == 1 } }
        let second = Task {
            try await RecognitionSlots.shared.run {
                runs.start()
                runs.finish()
            }
        }
        try await Task.sleep(for: .milliseconds(20))
        #expect(runs.counts.withLock { $0.started == 1 })
        gate.open()
        try await first.value
        try await second.value
        #expect(runs.counts.withLock { $0.started == 2 && $0.peak == 1 })
    }

    @Test func cancellingTheCallerReturnsBeforeUncooperativeWorkEnds() async throws {
        let gate = Gate()
        defer { gate.open() }
        let runs = Runs()
        let caller = Task {
            try await withTimeout(.seconds(10)) {
                runs.start()
                await gate.wait()
                runs.finish()
                return 1
            }
        }
        try await Self.settle { runs.counts.withLock { $0.started == 1 } }
        caller.cancel()
        await #expect(throws: CancellationError.self) {
            try await withTimeout(.seconds(1)) { try await caller.value }
        }
        #expect(runs.counts.withLock { $0.running == 1 })
        gate.open()
        try await Self.settle { runs.counts.withLock { $0.running == 0 } }
    }

    @Test func aCallerAlreadyCancelledStartsNoWork() async {
        let runs = Runs()
        let caller = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await withTimeout(.seconds(10)) {
                runs.start()
                return 1
            }
        }
        await #expect(throws: CancellationError.self) { try await caller.value }
        #expect(runs.counts.withLock { $0.started == 0 })
    }

    @Test func successfulAndFailedOperationsKeepTheirOriginalOutcome() async throws {
        struct Failure: Error {}
        #expect(try await withTimeout(.seconds(10)) { 42 } == 42)
        await #expect(throws: Failure.self) {
            try await withTimeout(.seconds(10)) { throw Failure() }
        }
    }

    @Test func aWholeImageDeadlineAlsoBoundsTheWaitForABusyVisionSlot() async throws {
        let gate = Gate()
        defer { gate.open() }
        let runs = Runs()
        let holder = Task {
            try await RecognitionSlots.shared.run {
                runs.start()
                await gate.wait()
                runs.finish()
            }
        }
        try await Self.settle { runs.counts.withLock { $0.running == 1 } }
        let context = try #require(CGContext(
            data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ))
        let image = try #require(context.makeImage())
        // The individual request would wait five seconds, but the image's entire budget is shorter.
        let pipeline = VisionPipeline(options: .init(timeout: .seconds(5), overallTimeout: .milliseconds(40)))
        let started = ContinuousClock.now
        await #expect(throws: OCRError.timedOut) { try await pipeline.recognize(image) }
        #expect(ContinuousClock.now - started < .seconds(1))
        #expect(runs.counts.withLock { $0.running == 1 })
        gate.open()
        try await holder.value
        // The timed-out queued recognition must not run when the holder finally releases the slot.
        #expect(try await withTimeout(.seconds(1)) { try await RecognitionSlots.shared.run { 42 } } == 42)
    }
}
