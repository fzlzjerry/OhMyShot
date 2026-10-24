import CoreGraphics
import Darwin
import Foundation
import OSLog
import Synchronization

/// A PP-OCR model pack the text reader reads with beside Vision (L2 beside L1, Docs/ocr.md › L2 beside L1).
public struct TextReaderPack: Sendable, Equatable {
    /// The installed pack's folder.
    public var folder: URL
    /// What a reading with it is called where its text is kept: "<id>/<version>/merge-<revision>", the revision of the
    /// rules that put its reading beside Vision's (`SecondReading.revision`).
    public var reading: String

    public init(folder: URL, reading: String) {
        self.folder = folder
        self.reading = reading
    }
}

/// One picture read by the text reader for someone waiting on the answer (the Shortcuts action Recognize Text in
/// Image, the OCR panel's second reading, Capture Formula), in a run of its own that exits once it has answered.
///
/// Vision keeps what a recognition used for as long as its process lives (Docs/perf.md, M2 and M5 — power gate:
/// the action read in the app left it 56 MB larger for good); read in the text reader, the app stays as it was.
/// The run holds an `ActiveResources` lease while its process lasts. Every operation has a complete-run
/// `timeout` (120 seconds by default to allow first-use compilation); cancellation or the deadline stops
/// waiting immediately and ends the helper, forcibly if native work ignores termination.
public enum TextReaderTool {
    public enum Failure: Error, Equatable {
        /// The reader didn't start.
        case unavailable(String)
        /// The reader answered that it couldn't read the picture.
        case unreadable(String)
        /// The reader ended without answering.
        case noAnswer(status: Int32)
        /// The complete run, including model loading and process exit, exceeded its deadline.
        case timedOut
    }

    /// A line a model pack read, in the picture's pixels with a top-left origin.
    public struct Line: Codable, Sendable, Equatable {
        public var text: String
        public var box: CGRect
        public var confidence: Float

        public init(text: String, box: CGRect, confidence: Float) {
            self.text = text
            self.box = box
            self.confidence = confidence
        }
    }

    /// The text in the picture at `url`, assembled as Capture Text assembles it.
    ///
    /// - Parameters:
    ///   - joinsWrappedLines: whether lines a paragraph wraps onto are joined into one.
    ///   - pack: an installed PP-OCR model pack's folder, to read with it beside Vision (L2 beside L1).
    ///   - formulas: the installed formula pack's folder, to put the formulas in the picture into the text as LaTeX
    ///     (Docs/ocr.md › Formulas among text).
    ///   - vlm: the installed VLM pack's folder, to put the tables and charts in the picture into the text, a row a line
    ///     (Docs/ocr.md › The VLM pack), reading them for `seconds` at most.
    ///   - helper: the text reader.
    @concurrent
    public static func text(
        ofPictureAt url: URL, joinsWrappedLines: Bool, pack: URL? = nil, formulas: URL? = nil, vlm: URL? = nil, seconds: Double? = nil,
        helper: URL, priority: QualityOfService = .userInitiated, resources: ActiveResources = .shared, timeout: Duration = .seconds(120)
    ) async throws -> String {
        let job = Job(
            id: UUID().uuidString, path: url.path(percentEncoded: false), joinsWrappedLines: joinsWrappedLines, pack: pack?.path(percentEncoded: false),
            formulas: formulas?.path(percentEncoded: false), vlm: vlm?.path(percentEncoded: false), seconds: seconds
        )
        let answer = try await run(job, helper: helper, priority: priority, resources: resources, timeout: timeout)
        if let text = answer.text { return text }
        throw Failure.unreadable(answer.error ?? "")
    }

    /// A formula the formula pack found in a picture and read whole.
    public struct FoundFormula: Codable, Sendable, Equatable {
        /// "display", set apart on a line of its own, or "inline", within text.
        public var kind: String
        /// In the picture's pixels, top-left origin.
        public var box: CGRect
        public var latex: String

        public init(kind: String, box: CGRect, latex: String) {
            self.kind = kind
            self.box = box
            self.latex = latex
        }
    }

    /// A table or chart the VLM pack read in a picture, as rows of cells (a chart's data).
    public struct FoundTable: Codable, Sendable, Equatable {
        /// "table" or "chart".
        public var kind: String
        /// In the picture's pixels, top-left origin.
        public var box: CGRect
        public var rows: [[String]]
        /// Whether the model said it was done, rather than stopping at its length or the deadline.
        public var whole: Bool

        public init(kind: String, box: CGRect, rows: [[String]], whole: Bool) {
            self.kind = kind
            self.box = box
            self.rows = rows
            self.whole = whole
        }
    }

    /// The formulas the formula pack installed in `pack` finds in the picture at `url`, each read as LaTeX (Docs/ocr.md ›
    /// Formulas among text). `found` is told how many there are to read, before they are.
    @concurrent
    public static func formulas(
        ofPictureAt url: URL, pack: URL, helper: URL, found: (@Sendable (Int) -> Void)? = nil, priority: QualityOfService = .userInitiated,
        resources: ActiveResources = .shared, timeout: Duration = .seconds(120)
    ) async throws -> [FoundFormula] {
        let counted: (@Sendable (Found) -> Void)? = found.map { found in { @Sendable counts in found(counts.formulas) } }
        return try await elements(ofPictureAt: url, formulas: pack, helper: helper, found: counted, priority: priority, resources: resources, timeout: timeout).formulas
    }

    /// How many formulas, and how many tables and charts, the reader found to read.
    public struct Found: Sendable, Equatable {
        public var formulas: Int
        public var tables: Int

        public init(formulas: Int, tables: Int) {
            self.formulas = formulas
            self.tables = tables
        }
    }

    /// The formulas the formula pack installed in `formulas` reads and the tables and charts the VLM pack installed in
    /// `vlm` reads in the picture at `url`, found in one run of the layout model (Docs/ocr.md › Formulas among text, ›
    /// The VLM pack); the VLM reads for `seconds` at most, and not at all while the system is short of memory, when
    /// `tablesLeft` says how many tables and charts were left to Vision (`pressure` stands in for the system's, to check
    /// that). `found` is told how many there are to read, before they are.
    @concurrent
    public static func elements(
        ofPictureAt url: URL, formulas: URL? = nil, vlm: URL? = nil, seconds: Double? = nil, pressure: MemoryPressure? = nil, helper: URL,
        found: (@Sendable (Found) -> Void)? = nil, priority: QualityOfService = .userInitiated, resources: ActiveResources = .shared, timeout: Duration = .seconds(120)
    ) async throws -> (formulas: [FoundFormula], tables: [FoundTable], tablesLeft: Int) {
        let job = Job(
            id: UUID().uuidString, path: url.path(percentEncoded: false), formulas: formulas?.path(percentEncoded: false),
            vlm: vlm?.path(percentEncoded: false), seconds: seconds, pressure: pressure?.name
        )
        let answer = try await run(job, helper: helper, priority: priority, resources: resources, timeout: timeout) { progress in
            if let count = progress.found { found?(Found(formulas: count - (progress.foundTables ?? 0), tables: progress.foundTables ?? 0)) }
        }
        if let formulas = answer.formulas { return (formulas, answer.tables ?? [], answer.tablesLeft ?? 0) }
        throw Failure.unreadable(answer.error ?? "")
    }

    /// The lines the pack in `pack` reads in the picture at `url`, alone, for the app to put beside its own reading.
    @concurrent
    public static func lines(
        ofPictureAt url: URL, pack: URL, helper: URL, priority: QualityOfService = .userInitiated, resources: ActiveResources = .shared, timeout: Duration = .seconds(120)
    ) async throws -> [Line] {
        let job = Job(id: UUID().uuidString, path: url.path(percentEncoded: false), pack: pack.path(percentEncoded: false), lines: true)
        let answer = try await run(job, helper: helper, priority: priority, resources: resources, timeout: timeout)
        if let lines = answer.lines { return lines }
        throw Failure.unreadable(answer.error ?? "")
    }

    /// Loads the pack in `pack` once, reading nothing: its first load compiles its models for the Neural Engine, which
    /// takes seconds, and later loads, in any run, find that done (Docs/ocr.md › The L2 pack).
    @concurrent
    public static func warm(pack: URL, helper: URL, priority: QualityOfService = .utility, resources: ActiveResources = .shared, timeout: Duration = .seconds(120)) async throws {
        let job = Job(id: UUID().uuidString, pack: pack.path(percentEncoded: false), warm: true)
        let answer = try await run(job, helper: helper, priority: priority, resources: resources, timeout: timeout)
        if let error = answer.error { throw Failure.unreadable(error) }
    }

    /// What the formula pack read in a picture.
    public struct Formula: Sendable, Equatable {
        public var latex: String
        /// How the reading ended: "end" when the model finished the formula; "repeats", "cacheFull", or "deadline"
        /// when it was stopped.
        public var ending: String

        public init(latex: String, ending: String) {
            self.latex = latex
            self.ending = ending
        }

        /// Whether this is a formula to give the person: a whole reading with something in it.
        public var isFormula: Bool {
            ending == "end" && !latex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// The formula the formula pack installed in `pack` reads in the picture at `url` (Capture Formula; Docs/ocr.md ›
    /// The formula pack). Without the spaces at its ends that upstream's tidying leaves where it unwraps `\text{}`.
    @concurrent
    public static func formula(
        ofPictureAt url: URL, pack: URL, helper: URL, priority: QualityOfService = .userInitiated, resources: ActiveResources = .shared, timeout: Duration = .seconds(120)
    ) async throws -> Formula {
        let job = Job(id: UUID().uuidString, path: url.path(percentEncoded: false), formula: pack.path(percentEncoded: false))
        let answer = try await run(job, helper: helper, priority: priority, resources: resources, timeout: timeout)
        if let latex = answer.latex, let ending = answer.ending {
            return Formula(latex: latex.trimmingCharacters(in: .whitespacesAndNewlines), ending: ending)
        }
        throw Failure.unreadable(answer.error ?? "")
    }

    /// Compiles the formula pack's models once, reading nothing, so the first Capture Formula doesn't wait on it.
    @concurrent
    public static func warm(formula pack: URL, helper: URL, priority: QualityOfService = .utility, resources: ActiveResources = .shared, timeout: Duration = .seconds(120)) async throws {
        let job = Job(id: UUID().uuidString, warm: true, formula: pack.path(percentEncoded: false))
        let answer = try await run(job, helper: helper, priority: priority, resources: resources, timeout: timeout)
        if let error = answer.error { throw Failure.unreadable(error) }
    }

    /// Removes what Core ML keeps in the reader's Caches folder of models that are gone (`CompiledModelCache`), after a
    /// pack was removed or replaced, reading nothing. Run in the reader, whose cache it is.
    /// - Returns: how many entries were removed.
    @concurrent
    @discardableResult
    public static func tidy(helper: URL, priority: QualityOfService = .utility, resources: ActiveResources = .shared, timeout: Duration = .seconds(120)) async throws -> Int {
        let job = Job(id: UUID().uuidString, tidy: true)
        let answer = try await run(job, helper: helper, priority: priority, resources: resources, timeout: timeout)
        if let removed = answer.removed { return removed }
        throw Failure.unreadable(answer.error ?? "")
    }

    /// Runs the reader on `job`. A line telling how far it got (`Answer.isProgress`) goes to `progress`; the answer is
    /// the last other line for the job.
    private static func run(
        _ job: Job, helper: URL, priority: QualityOfService, resources: ActiveResources, timeout: Duration,
        progress: (@Sendable (Answer) -> Void)? = nil
    ) async throws -> Answer {
        try Task.checkCancellation()
        var jobLine = try JSONEncoder().encode(job)
        jobLine.append(0x0A)
        let process = Process()
        process.executableURL = helper
        process.qualityOfService = priority
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let (events, event) = AsyncStream.makeStream(of: RunEvent.self)
        let lease = resources.acquire(.helperProcess)
        process.terminationHandler = { process in
            // Keep counting the actual helper, even after its caller stopped waiting.
            lease.end()
            event.yield(.exited(process.terminationStatus))
        }
        do {
            try process.run()
        } catch {
            lease.end()
            throw Failure.unavailable(error.localizedDescription)
        }
        let reader = output.fileHandleForReading
        let descriptor = reader.fileDescriptor
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        let closed = Mutex(false)
        reader.readabilityHandler = { handle in
            // Cancellation can close the handle while a dispatched callback is still queued. Guard
            // the descriptor and use a nonblocking read: neither a closed handle nor a stale readiness
            // notification can trap in Foundation or delay the caller's cleanup.
            let next = closed.withLock { closed -> RunEvent? in
                guard !closed else { return nil }
                var bytes = [UInt8](repeating: 0, count: 64 * 1024)
                let count = Darwin.read(descriptor, &bytes, bytes.count)
                if count > 0 { return .bytes(Data(bytes.prefix(count))) }
                if count == 0 || (errno != EAGAIN && errno != EINTR) { return .eof }
                return nil
            }
            if let next {
                event.yield(next)
                if case .eof = next { handle.readabilityHandler = nil }
            }
        }
        // A hung native prediction may ignore SIGTERM. A separate, short grace period then ends this
        // one-shot helper for good; its caller never waits for the helper or its stdout descendants.
        func stop() {
            guard process.isRunning else { return }
            process.terminate()
            Task.detached {
                try? await Task.sleep(for: .milliseconds(250))
                if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
            }
        }
        let timer = Task {
            do {
                try await Task.sleep(for: timeout)
                event.yield(.timedOut)
            } catch {}
        }
        defer {
            timer.cancel()
            reader.readabilityHandler = nil
            closed.withLock { closed in
                closed = true
                try? reader.close()
            }
            event.finish()
        }
        let writer = input.fileHandleForWriting
        // Job paths can exceed the pipe's capacity; writing must not hold up the deadline either.
        _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
        let bytes = jobLine
        Task.detached(priority: .utility) {
            try? writer.write(contentsOf: bytes)
            try? writer.close()
        }

        return try await withTaskCancellationHandler {
            var buffered = Data()
            var answer: Answer?
            var ended = false
            var status: Int32?
            func receive(_ data: Data) {
                guard let decoded = try? JSONDecoder().decode(Answer.self, from: data), decoded.id == job.id else { return }
                if decoded.isProgress { progress?(decoded) } else { answer = decoded }
            }
            for await next in events {
                switch next {
                case .bytes(let bytes):
                    buffered.append(bytes)
                    while let newline = buffered.firstIndex(of: 0x0A) {
                        receive(Data(buffered[..<newline]))
                        buffered.removeSubrange(...newline)
                    }
                case .eof:
                    if !buffered.isEmpty { receive(buffered); buffered.removeAll() }
                    ended = true
                case .exited(let code): status = code
                case .timedOut:
                    stop()
                    throw Failure.timedOut
                case .cancelled:
                    stop()
                    throw CancellationError()
                }
                if ended, let status {
                    try Task.checkCancellation()
                    guard let answer else { throw Failure.noAnswer(status: status) }
                    return answer
                }
            }
            // A cancelled iterator may end before its queued cancellation event is delivered.
            stop()
            throw CancellationError()
        } onCancel: {
            event.yield(.cancelled)
        }
    }

    private enum RunEvent: Sendable {
        case bytes(Data)
        case eof
        case exited(Int32)
        case timedOut
        case cancelled
    }

    private struct Job: Encodable {
        let id: String
        var path: String?
        var joinsWrappedLines: Bool?
        var pack: String?
        var lines: Bool?
        var warm: Bool?
        var formula: String?
        var formulas: String?
        var tidy: Bool?
        var vlm: String?
        var seconds: Double?
        var pressure: String?
    }

    private struct Answer: Decodable {
        let id: String
        let text: String?
        let lines: [Line]?
        let latex: String?
        let ending: String?
        let found: Int?
        let foundTables: Int?
        let formulas: [FoundFormula]?
        let tables: [FoundTable]?
        let tablesLeft: Int?
        let removed: Int?
        let error: String?

        /// How many formulas, tables, and charts the reader found, said before it reads them.
        var isProgress: Bool {
            found != nil && text == nil && lines == nil && latex == nil && formulas == nil && tables == nil && removed == nil && error == nil
        }
    }
}
