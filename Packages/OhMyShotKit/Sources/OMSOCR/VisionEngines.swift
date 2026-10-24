import CoreGraphics
import Foundation
import Synchronization
import Vision

/// Apple Vision's line recognizer (`RecognizeTextRequest`): lines with boxes, no document structure.
public struct VisionTextEngine: OCREngine {
    public struct Configuration: Sendable {
        /// Languages in priority order; empty leaves Vision's default.
        public var languages: [Locale.Language]
        public var automaticallyDetectsLanguage: Bool
        public var usesLanguageCorrection: Bool
        public var level: RecognizeTextRequest.RecognitionLevel

        public init(
            languages: [Locale.Language] = [],
            automaticallyDetectsLanguage: Bool = false,
            usesLanguageCorrection: Bool = false,
            level: RecognizeTextRequest.RecognitionLevel = .accurate
        ) {
            self.languages = languages
            self.automaticallyDetectsLanguage = automaticallyDetectsLanguage
            self.usesLanguageCorrection = usesLanguageCorrection
            self.level = level
        }
    }

    public let name: String
    public let configuration: Configuration
    /// How long to wait before giving up on Vision. A model's first use can take several seconds.
    public var timeout: Duration

    public init(name: String, configuration: Configuration, timeout: Duration = .seconds(10)) {
        self.name = name
        self.configuration = configuration
        self.timeout = timeout
    }

    /// The languages this request can recognize on this Mac.
    public static var supportedLanguages: [Locale.Language] {
        RecognizeTextRequest().supportedRecognitionLanguages
    }

    public func recognize(_ image: CGImage) async throws -> OCRResult {
        var request = RecognizeTextRequest()
        request.recognitionLevel = configuration.level
        request.usesLanguageCorrection = configuration.usesLanguageCorrection
        request.automaticallyDetectsLanguage = configuration.automaticallyDetectsLanguage
        if !configuration.languages.isEmpty {
            request.recognitionLanguages = configuration.languages
        }
        let configured = request
        let started = ContinuousClock.now
        let observations = try await withTimeout(timeout) { try await configured.perform(on: image) }
        let duration = ContinuousClock.now - started
        let size = CGSize(width: image.width, height: image.height)
        let lines = observations.compactMap { observation -> OCRLine? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return OCRLine(
                text: candidate.string,
                box: observation.boundingBox.toImageCoordinates(size, origin: .upperLeft),
                confidence: candidate.confidence,
                direction: OCRLine.Direction(observation.textDirection),
                wrapsToNextLine: observation.shouldWrapToNextLine
            )
        }
        let ordered = ReadingOrder.sorted(lines)
        return OCRResult(lines: ordered, text: ordered.map(\.text).joined(separator: "\n"), duration: duration)
    }
}

/// Apple Vision's document recognizer (`RecognizeDocumentsRequest`): paragraphs, lists, and tables.
public struct VisionDocumentEngine: OCREngine {
    public let name: String
    /// Languages in priority order; empty leaves Vision's default.
    public var languages: [Locale.Language]
    public var usesLanguageCorrection: Bool?
    public var timeout: Duration

    public init(name: String, languages: [Locale.Language] = [], usesLanguageCorrection: Bool? = nil, timeout: Duration = .seconds(10)) {
        self.name = name
        self.languages = languages
        self.usesLanguageCorrection = usesLanguageCorrection
        self.timeout = timeout
    }

    /// The languages this request can recognize on this Mac.
    public static var supportedLanguages: [Locale.Language] {
        RecognizeDocumentsRequest().supportedRecognitionLanguages
    }

    public func recognize(_ image: CGImage) async throws -> OCRResult {
        var request = RecognizeDocumentsRequest()
        if !languages.isEmpty {
            request.textRecognitionOptions.recognitionLanguages = languages
        }
        if let usesLanguageCorrection {
            request.textRecognitionOptions.useLanguageCorrection = usesLanguageCorrection
        }
        let configured = request
        let started = ContinuousClock.now
        let observations = try await withTimeout(timeout) { try await configured.perform(on: image) }
        let duration = ContinuousClock.now - started
        guard let document = observations.first?.document else {
            return OCRResult(lines: [], text: "", duration: duration)
        }
        let size = CGSize(width: image.width, height: image.height)
        let lines = document.text.lines.compactMap { observation -> OCRLine? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return OCRLine(
                text: candidate.string,
                box: observation.boundingBox.toImageCoordinates(size, origin: .upperLeft),
                confidence: candidate.confidence,
                direction: OCRLine.Direction(observation.textDirection),
                wrapsToNextLine: observation.shouldWrapToNextLine
            )
        }
        let tables = document.tables.map { table in
            OCRTable(rows: table.rows.map { row in row.map(\.content.text.transcript) })
        }
        return OCRResult(lines: lines, tables: tables, text: document.text.transcript, duration: duration)
    }
}

extension OCRLine.Direction {
    init?(_ direction: RecognizedTextObservation.Direction?) {
        switch direction {
        case .leftToRight: self = .leftToRight
        case .rightToLeft: self = .rightToLeft
        case .topToBottom: self = .topToBottom
        default: return nil
        }
    }
}

/// Runs `operation`, or throws `OCRError.timedOut` once `limit` passes. Whichever finishes first cancels
/// the other, so no timer outlives a request. Cancellation also releases the caller immediately. The
/// operation may still be running if it ignores cancellation; any concurrency slot must be held inside it.
func withTimeout<T: Sendable>(_ limit: Duration, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    let race = TimeoutRace<T>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            guard race.begin(continuation) else { return }
            let work = Task {
                do {
                    try Task.checkCancellation()
                    race.finish(.success(try await operation()))
                } catch {
                    race.finish(.failure(error))
                }
            }
            let timer = Task {
                try? await Task.sleep(for: limit)
                if !Task.isCancelled { race.finish(.failure(OCRError.timedOut)) }
            }
            race.track([work, timer])
        }
    } onCancel: {
        race.finish(.failure(CancellationError()))
    }
}

/// The shared state of `withTimeout`: the first result resumes the caller and cancels both tasks.
private final class TimeoutRace<T: Sendable>: Sendable {
    private struct State {
        var continuation: CheckedContinuation<T, Error>?
        var tasks: [Task<Void, Never>] = []
        var result: Result<T, Error>?
    }

    private let state = Mutex(State())

    /// Cancellation can win before the caller has installed its continuation.
    func begin(_ continuation: CheckedContinuation<T, Error>) -> Bool {
        let result = state.withLock { state in
            if state.result == nil { state.continuation = continuation }
            return state.result
        }
        if let result {
            continuation.resume(with: result)
            return false
        }
        return true
    }

    func track(_ tasks: [Task<Void, Never>]) {
        let finishedAlready = state.withLock { state in
            if state.result == nil { state.tasks = tasks }
            return state.result != nil
        }
        // A result that arrived before the tasks were tracked could not cancel them.
        if finishedAlready { tasks.forEach { $0.cancel() } }
    }

    func finish(_ result: Result<T, Error>) {
        let (continuation, tasks) = state.withLock { state -> (CheckedContinuation<T, Error>?, [Task<Void, Never>]) in
            guard state.result == nil else { return (nil, []) }
            state.result = result
            defer { state.continuation = nil; state.tasks = [] }
            return (state.continuation, state.tasks)
        }
        tasks.forEach { $0.cancel() }
        continuation?.resume(with: result)
    }
}
