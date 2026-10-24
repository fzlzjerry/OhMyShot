import AppKit
import Foundation
import OMSCapture
import OMSCore
import OMSOCR
import OMSUI
import OSLog
import UniformTypeIdentifiers

/// Capture Text: drag over text, or pick a window, and the text goes to the clipboard, any formula in it as LaTeX while
/// the formula pack is installed. The selection stays highlighted while the text is read and fades once it is copied; a
/// card with the text is optional. Unlike a screenshot there is no shutter sound and nothing goes to the history.
///
/// Also opens the OCR panel, for a closer look at an image's text: Option held when the drag ends, a
/// capture's Recognize Text, an image file, the clipboard, or an image dropped on the menu bar icon. And Capture
/// Formula: the same, for a formula, whose LaTeX goes to the clipboard.
final class TextCaptureCoordinator {
    private let settings: SettingsStore
    private let displays: DisplayTopology
    private let capturer: ScreenCapturer
    private let overlay: OverlayController
    /// A model's first use can take seconds; the highlight stays on meanwhile.
    private let pipeline: VisionPipeline = {
        var options = VisionPipeline.Options.preferred()
        options.timeout = .seconds(30)
        options.overallTimeout = .seconds(30)
        return VisionPipeline(options: options)
    }()
    /// Shared by the panel and Translate Area: a language pair's first translation loads its model.
    private let translator = Translator()
    private let highlight = TextSelectionHighlight()
    private let lens = TranslationLens()
    private let hud = TextResultHUD()
    private var warmup: Task<Void, Never>?
    private var captureReading: Task<Void, Never>?
    private var panel: TextRecognitionWindowController?
    /// The last recognition, so the card can switch between kept and joined line breaks.
    private var last: Recognition?
    /// The model pack the OCR panel reads with beside Vision, and the text reader that reads with it (L2 beside L1,
    /// Docs/ocr.md › L2 beside L1); nil while none is installed. Asked as each panel opens.
    var secondReader: (() -> (pack: TextReaderPack, helper: URL)?)?
    /// The formula pack's folder and the text reader that reads with it (Capture Formula, and the formulas among text;
    /// Docs/ocr.md › The formula pack); nil while the pack isn't installed.
    var formulaReader: (() -> (pack: URL, helper: URL)?)?
    /// The formula pack's and the VLM pack's folders, whichever are installed, and the text reader that reads with them
    /// (the formulas, tables, and charts among text; Docs/ocr.md › Formulas among text, › The VLM pack); nil while neither
    /// is installed.
    var elementReader: (() -> (formulas: URL?, vlm: URL?, helper: URL)?)?
    /// How long Capture Text lets the VLM read tables and charts before it copies Vision's reading of what is left: a
    /// table takes 0.2–1.2 s once the model's files are in memory, the first after a restart about 7 s
    /// (Docs/ocr.md › The VLM pack).
    nonisolated static let tableWait: Double = 10
    /// The same in the OCR panel, which shows Vision's reading meanwhile.
    nonisolated static let panelTableWait: Double = 60
    /// The cloud model the panel's Read with sends a picture to, and how; asked as each panel window opens.
    var cloud: (() -> TextRecognitionWindowController.Cloud?)?
    /// The cloud model Capture Text reads with while Settings says so, and how (joining lines or not); nil otherwise.
    /// Asked at each capture.
    var captureTextCloud: (() -> (model: CloudModel, read: @Sendable (CGImage, _ joinsLines: Bool) async throws -> CloudReading)?)?
    /// How long Capture Text waits for the cloud model before it copies this Mac's reading instead.
    nonisolated static let cloudWait: Duration = .seconds(60)
    /// Counts Capture Text's readings: one still waiting for the cloud model when another starts is let go, and leaves
    /// the clipboard and the highlight to the newer one.
    private var readings = 0
    /// The cloud model's reading Capture Text waits for, cancelled when another Capture Text starts.
    private var waitingForCloud: Task<CloudReading, any Error>?
    /// Text read but left off the clipboard, which changed while the cloud model read it; the card's Copy puts it there.
    private var uncopied: (text: String, note: String?, selection: CGRect)?

    private struct Recognition {
        let lines: [OCRLine]
        let selection: CGRect
        var joined: Bool
        let copiesToClipboard: Bool
        /// The card's line under the text: why this Mac's reading was copied instead of the cloud model's.
        var note: String?
    }

    init(settings: SettingsStore, displays: DisplayTopology, capturer: ScreenCapturer, overlay: OverlayController) {
        self.settings = settings
        self.displays = displays
        self.capturer = capturer
        self.overlay = overlay
        hud.onToggleJoin = { [weak self] in self?.toggleJoin() }
        hud.onCopy = { [weak self] in self?.copyUncopied() }
    }

    /// Where Quick Access's cards stand, for the result card to keep clear of in the bottom-left corner.
    var cardsInTheWay: () -> CGRect? {
        get { hud.cardsInTheWay }
        set { hud.cardsInTheWay = newValue }
    }

    /// Shows a result card by `selection`. The Close text card choice applies to a card the user asked for (Show the
    /// copied text); one shown only to say something (a note, or text left off the clipboard) keeps its own time.
    private func presentCard(_ state: TextResultHUD.State, near selection: CGRect, note: String? = nil) {
        hud.show(state, near: selection, position: settings.textResultPosition,
                 closeAfter: settings.showTextResult ? settings.textResultCloseAfter : nil, note: note)
    }

    /// Shows the overlay for text. `joinLines` joins the lines of each paragraph. `done` is told the text copied, or
    /// nil when none was: cancelled, nothing readable, or Option opened the OCR panel instead. `allowsCloud` false
    /// keeps the reading on this Mac, for the URL API and Shortcuts.
    func captureText(joinLines: Bool, allowsCloud: Bool = true, done: ((String?) -> Void)? = nil) {
        guard !overlay.isActive else { done?(nil); return }
        captureReading?.cancel()
        waitingForCloud?.cancel()
        highlight.hide()
        // The model loads while the person selects, which hides its first-use cost.
        let pipeline = pipeline
        warmup?.cancel()
        warmup = Task {
            let probe = LatencyProbe("ocr.prewarm")
            await pipeline.prewarm()
            probe.end()
        }
        overlay.freezesScreen = settings.freezeScreen
        overlay.begin(mode: .area, purpose: .text) { [weak self] outcome in
            // The highlight appears in the same turn the overlay closes, so no frame goes by without
            // the selection.
            guard let self else { done?(nil); return }
            warmup?.cancel()
            warmup = nil
            switch outcome {
            case .region(let rect, _, let modifiers, let frozen) where modifiers.contains(.option):
                done?(nil)
                Task { await self.openPanel(region: rect, frozen: frozen) }
            case .window(let target, let modifiers) where modifiers.contains(.option):
                done?(nil)
                Task { await self.openPanel(window: target) }
            case .region(let rect, _, _, let frozen):
                highlight.show(rect)
                captureReading = Task { await self.recognize(region: rect, frozen: frozen, joinLines: joinLines, allowsCloud: allowsCloud, done: done) }
            case .window(let target, _):
                highlight.show(target.frame)
                captureReading = Task { await self.recognize(window: target, joinLines: joinLines, allowsCloud: allowsCloud, done: done) }
            case .annotated, .color, .record, .scroll, .allInOne, .cancelled:
                done?(nil)
            }
        }
    }

    /// Reads a region of a display, as the overlay does after a drag. Also used by scripted checks.
    /// - Parameters:
    ///   - frozen: the region as the overlay held it still; nil captures it now.
    ///   - copiesToClipboard: false leaves the clipboard alone, so scripted checks never replace what
    ///     the user copied.
    ///   - allowsCloud: true for a person's own drag: it reads with the cloud model while Settings says Capture Text
    ///     does. The URL API never sends a capture to one.
    ///   - done: told the text copied, or nil when there was none.
    func recognize(
        region rect: CGRect, frozen: CapturedFrame? = nil, joinLines: Bool, copiesToClipboard: Bool = true, allowsCloud: Bool = false,
        done: ((String?) -> Void)? = nil
    ) async {
        guard !Task.isCancelled else { done?(nil); return }
        highlight.show(rect)
        do {
            let frame = try await capture(rect, frozen: frozen)
            try Task.checkCancellation()
            await recognize(
                frame.image, selection: rect, place: Self.place(of: frame), joinLines: joinLines, copiesToClipboard: copiesToClipboard,
                allowsCloud: allowsCloud, done: done
            )
        } catch {
            guard !Task.isCancelled else { done?(nil); return }
            Log.capture.error("Capture Text failed to capture: \(error.localizedDescription, privacy: .public)")
            highlight.finish(copied: nil, announces: !settings.showTextResult)
            done?(nil)
        }
    }

    private func recognize(window target: WindowTarget, joinLines: Bool, allowsCloud: Bool, done: ((String?) -> Void)? = nil) async {
        guard !Task.isCancelled else { done?(nil); return }
        highlight.show(target.frame)
        do {
            let frame = try await capturer.captureWindow(target, shadow: false, layout: displays.layout)
            try Task.checkCancellation()
            await recognize(
                frame.image, selection: target.frame, place: Self.place(of: frame, window: target), joinLines: joinLines, copiesToClipboard: true,
                allowsCloud: allowsCloud, done: done
            )
        } catch {
            guard !Task.isCancelled else { done?(nil); return }
            Log.capture.error("Capture Text failed to capture the window: \(error.localizedDescription, privacy: .public)")
            highlight.finish(copied: nil, announces: !settings.showTextResult)
            done?(nil)
        }
    }

    #if DEBUG
    /// Where a window is on screen, for asking its app for its text (the scale taken from the window's display). For
    /// scripted checks.
    func place(ofWindow target: WindowTarget) -> AppTextPlace? {
        let scale = displays.layout.display(at: CGPoint(x: target.frame.midX, y: target.frame.midY))?.pixelsPerPoint ?? 2
        guard let owner = WindowCatalog.owner(of: target.id), owner != ProcessInfo.processInfo.processIdentifier else { return nil }
        return AppTextPlace(frame: target.frame, scale: scale, pid: owner)
    }

    /// Capture Text over one window, as when it is picked, without touching the clipboard. For scripted checks.
    func previewRecognition(ofWindow target: WindowTarget, joinLines: Bool, done: @escaping (String?) -> Void) async {
        do {
            let frame = try await capturer.captureWindow(target, shadow: false, layout: displays.layout)
            await recognize(
                frame.image, selection: target.frame, place: Self.place(of: frame, window: target), joinLines: joinLines, copiesToClipboard: false,
                done: done
            )
        } catch {
            done(nil)
        }
    }
    #endif

    /// The URL API's `capture-text` with a file: its text goes to the clipboard as a selection's does, the card (when
    /// it is on) by the pointer. Nothing is highlighted: the picture is not on screen.
    /// - Parameter copiesToClipboard: false for a shortcut's action, which hands the text on instead.
    func recognize(fileAt url: URL, joinLines: Bool, copiesToClipboard: Bool = true, done: ((String?) -> Void)? = nil) async {
        guard let loaded = await Self.load(.file(url), fallbackScale: 1) else {
            Log.capture.error("Could not read \(url.lastPathComponent, privacy: .public) to recognize its text")
            highlight.finish(copied: nil, announces: true)
            done?(nil)
            return
        }
        let pointer = NSEvent.mouseLocation
        await recognize(
            loaded.image, selection: CGRect(origin: pointer, size: .zero), joinLines: joinLines, copiesToClipboard: copiesToClipboard, done: done
        )
    }

    /// A picture's text as Capture Text puts it together, or nil when it has none; nothing is copied or shown. For a
    /// shortcut's Recognize Text in Image.
    func text(in image: CGImage, joinLines: Bool) async -> String? {
        do {
            let lines = try await pipeline.recognize(image).lines
            let text = TextAssembler.assemble(lines, options: .init(joinsWrappedLines: joinLines))
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
        } catch {
            Log.capture.error("Recognizing a shortcut's picture failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// With the formula pack installed, the formulas in the picture are found and read in the text reader beside Vision's
    /// reading, and the text copied holds each as LaTeX (Docs/ocr.md › Formulas among text); with the VLM pack, its tables
    /// and charts, a row a line, where they bear themselves out (Docs/ocr.md › The VLM pack); the highlight stays on until
    /// they are in. While Settings has Capture Text read with the cloud model (and `allowsCloud`), the picture goes
    /// to it beside them, and its text is copied once it comes; when it can't read the picture (or takes over
    /// `cloudWait`), this Mac's reading is copied, and the card says so even when it is off.
    ///
    /// While Settings says so, the app under `place` (where the picture was on screen) is asked for the text it shows
    /// where Vision read its lines, and the lines it shows alike take its characters (L0, Docs/ocr.md › Text from apps);
    /// the card then says the text came from that app. The cloud model's text, when it comes, is copied as it reads.
    private func recognize(
        _ image: CGImage, selection: CGRect, place: AppTextPlace? = nil, joinLines: Bool, copiesToClipboard: Bool, allowsCloud: Bool = false,
        done: ((String?) -> Void)? = nil
    ) async {
        guard !Task.isCancelled else { done?(nil); return }
        let showsCard = settings.showTextResult
        let probe = LatencyProbe("ocr.recognize")
        readings += 1
        let reading = readings
        waitingForCloud?.cancel()
        waitingForCloud = nil
        let clipboard = NSPasteboard.general.changeCount
        let cloud = allowsCloud ? captureTextCloud?() : nil
        let cloudReading = cloud.map { cloud in Task { try await cloud.read(image, joinLines) } }
        waitingForCloud = cloudReading
        let reader = elementReader?()
        let vlm = reader?.vlm.flatMap { isTerminal(place) ? nil : $0 }
        if reader?.vlm != nil, vlm == nil { Log.capture.notice("Capture Text leaves the tables to Vision: the picture is of a terminal") }
        let formulas = reader.map { reader in
            Task { await Self.elements(in: image, formulas: reader.formulas, vlm: vlm, seconds: Self.tableWait, helper: reader.helper) }
        }
        defer {
            cloudReading?.cancel()
            formulas?.cancel()
        }
        let visionLines: [OCRLine]?
        do {
            visionLines = try await pipeline.recognize(image).lines
        } catch {
            Log.capture.error("Capture Text failed to recognize: \(String(describing: error), privacy: .public)")
            visionLines = nil
        }
        guard !Task.isCancelled, reading == readings else {
            cloudReading?.cancel()
            formulas?.cancel()
            done?(nil)
            return
        }
        // Asked at once, while the screen still shows what the picture does: before any wait for the cloud model.
        let appText = Self.appText(for: visionLines, in: settings.readsAppText ? place : nil, layout: displays.layout)

        var note: String?
        if let cloud, let cloudReading {
            let started = ContinuousClock.now
            let outcome = await Self.first(cloudReading, within: Self.cloudWait)
            guard !Task.isCancelled, reading == readings else {
                // Another Capture Text started meanwhile: the clipboard and the highlight are its.
                formulas?.cancel()
                Log.capture.notice("Capture Text let go of a reading another one replaced")
                done?(nil)
                return
            }
            waitingForCloud = nil
            switch outcome {
            case .success(let cloudText)?:
                let text = cloudText.text
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    formulas?.cancel()
                    probe.end()
                    last = nil
                    let readBy = String(localized: "Read by \(cloud.model.displayName)")
                    Log.capture.notice("Capture Text read \(text.count, privacy: .public) characters with the cloud model, \(String(describing: ContinuousClock.now - started), privacy: .public) after Vision's reading")
                    if copiesToClipboard, NSPasteboard.general.changeCount != clipboard {
                        keepUncopied(text, note: readBy, near: selection)
                        done?(nil)
                        return
                    }
                    if copiesToClipboard { copy(text) }
                    highlight.finish(copied: text, announces: !showsCard)
                    if showsCard { presentCard(.copied(text: text, joined: joinLines, canJoin: false), near: selection, note: readBy) }
                    done?(text)
                    return
                }
                note = String(localized: "\(cloud.model.displayName) found no text, so this Mac’s reading was copied.")
            case .failure(let error)?:
                note = String(localized: "\(cloud.model.displayName) couldn’t read it, so this Mac’s reading was copied: \(error.localizedDescription)")
            case nil:
                cloudReading.cancel()
                note = String(localized: "\(cloud.model.displayName) took too long, so this Mac’s reading was copied.")
            }
            Log.capture.notice("Capture Text falls back to this Mac's reading: the cloud model gave no text")
        }

        guard var lines = visionLines else {
            formulas?.cancel()
            highlight.finish(copied: nil, announces: !showsCard)
            if showsCard || note != nil { presentCard(.empty, near: selection, note: note) }
            done?(nil)
            return
        }
        var appNote: String?
        if let appText {
            let reading = await appText.value
            let merge = AppTextMerge.merged(lines, with: reading.lines.map { AppTextLine(box: $0.box, pieces: $0.pieces, app: $0.app) })
            Self.log(reading, merge, of: lines.count, in: "Capture Text")
            appNote = merge.source.map { String(localized: "Text from \($0)") }
            lines = merge.lines
        }
        if let formulas {
            let started = ContinuousClock.now
            let found = await formulas.value
            if !found.formulas.isEmpty {
                lines = await pipeline.lines(lines, with: found.formulas, in: image)
                Log.capture.notice("Capture Text put \(found.formulas.count, privacy: .public) formulas into its text, \(String(describing: ContinuousClock.now - started), privacy: .public) after Vision's reading")
            }
            if !found.tables.isEmpty {
                let merge = TableMerge.merged(lines, with: found.tables, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                lines = merge.lines
                Self.log(merge, of: found.tables, in: "Capture Text", after: ContinuousClock.now - started)
            }
        }
        probe.end()

        guard !Task.isCancelled, reading == readings else { done?(nil); return }

        // The card says where the text came from only when it shows anyway.
        var recognition = Recognition(lines: lines, selection: selection, joined: joinLines, copiesToClipboard: copiesToClipboard, note: note ?? (showsCard ? appNote : nil))
        let text = assemble(recognition)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            last = nil
            Log.capture.notice("Capture Text found no text")
            highlight.finish(copied: nil, announces: !showsCard)
            if showsCard || note != nil { presentCard(.empty, near: selection, note: note) }
            done?(nil)
            return
        }
        // After a wait for the cloud model, something copied meanwhile stays on the clipboard.
        if cloud != nil, copiesToClipboard, NSPasteboard.general.changeCount != clipboard {
            last = nil
            keepUncopied(text, note: note, near: selection)
            done?(nil)
            return
        }
        if copiesToClipboard { copy(text) }
        recognition.joined = joinLines
        last = recognition
        highlight.finish(copied: text, announces: !showsCard)
        Log.capture.notice("Capture Text copied \(text.count, privacy: .public) characters in \(lines.count, privacy: .public) lines")
        // The cloud model's failure is said even with the card off: Capture Text would otherwise read differently
        // without a word.
        if showsCard || note != nil {
            presentCard(.copied(text: text, joined: joinLines, canJoin: canJoin(recognition)), near: selection, note: recognition.note)
        }
        done?(text)
    }

    /// Where a picture of the screen was, for asking the apps there for their text; a window's own app for a window.
    /// Nil for a window of OhMyShot's own (Settings, History, an editor): it isn't asked about its own text.
    private static func place(of frame: CapturedFrame, window: WindowTarget? = nil) -> AppTextPlace? {
        let owner = window.flatMap { WindowCatalog.owner(of: $0.id) }
        if window != nil, owner == nil || owner == ProcessInfo.processInfo.processIdentifier { return nil }
        return AppTextPlace(frame: frame.frame, scale: scale(of: frame), pid: owner)
    }

    /// The apps' text at the lines' places (L0), being read for `budget` at most; nil while Settings leaves it off (no
    /// `place`), while Accessibility is off for OhMyShot, or with no lines to ask about.
    private nonisolated static func appText(
        for lines: [OCRLine]?, in place: AppTextPlace?, layout: DisplayLayout, within budget: Duration = .milliseconds(150)
    ) -> Task<AppTextReading, Never>? {
        guard let place, let lines, !lines.isEmpty, AppText.isAllowed else { return nil }
        let boxes = lines.map(\.box)
        return Task { await AppText.read(boxes, in: place, layout: layout, within: budget) }
    }

    /// What the apps said, in numbers alone: never their text.
    private nonisolated static func log(_ reading: AppTextReading, _ merge: AppTextMerge.Merged, of count: Int, in reader: String) {
        let apps = Set(reading.lines.map(\.app)).count
        var extra = ""
        if merge.dropped > 0 { extra += ", \(merge.dropped) scraps dropped" }
        if reading.outOfTime { extra += ", out of time after \(reading.asked) lines" }
        if reading.secure > 0 { extra += ", \(reading.secure) over password fields" }
        Log.capture.notice("\(reader, privacy: .public) took \(merge.taken.count, privacy: .public) of \(count, privacy: .public) lines from \(apps, privacy: .public) apps (\(merge.changed, privacy: .public) changed); \(reading.lines.count, privacy: .public) answered at \(reading.points, privacy: .public) points in \(String(describing: reading.duration), privacy: .public)\(extra, privacy: .public)")
    }

    /// The task's outcome, or nil when it takes longer than `limit` (the task goes on; the caller may cancel it).
    nonisolated static func first<Value: Sendable>(_ task: Task<Value, any Error>, within limit: Duration) async -> Result<Value, any Error>? {
        let (outcomes, outcome) = AsyncStream.makeStream(of: Result<Value, any Error>?.self)
        let waiting = Task {
            do {
                outcome.yield(.success(try await task.value))
            } catch {
                outcome.yield(.failure(error))
            }
            outcome.finish()
        }
        let timer = Task {
            try? await Task.sleep(for: limit)
            outcome.yield(nil)
            outcome.finish()
        }
        defer {
            waiting.cancel()
            timer.cancel()
        }
        for await first in outcomes { return first }
        return nil
    }

    /// Shows text read but not copied, because the clipboard changed while the cloud model read it: the card, with Copy,
    /// shows even while it is off.
    private func keepUncopied(_ text: String, note: String?, near selection: CGRect) {
        uncopied = (text, note, selection)
        highlight.finish(copied: text, announces: false)
        presentCard(.notCopied(text: text), near: selection, note: String(localized: "You copied something else while it was read."))
        Log.capture.notice("Capture Text left \(text.count, privacy: .public) characters off the clipboard, which changed meanwhile")
    }

    /// The card's Copy, for text that wasn't copied.
    private func copyUncopied() {
        guard let uncopied else { return }
        copy(uncopied.text)
        self.uncopied = nil
        presentCard(.copied(text: uncopied.text, joined: false, canJoin: false), near: uncopied.selection, note: uncopied.note)
    }

    /// The card's switch: copies the text again with the other line-break choice.
    private func toggleJoin() {
        guard var recognition = last else { return }
        recognition.joined.toggle()
        let text = assemble(recognition)
        if recognition.copiesToClipboard { copy(text) }
        last = recognition
        presentCard(.copied(text: text, joined: recognition.joined, canJoin: true), near: recognition.selection, note: recognition.note)
    }

    private func assemble(_ recognition: Recognition) -> String {
        TextAssembler.assemble(recognition.lines, options: .init(joinsWrappedLines: recognition.joined))
    }

    /// Whether joining lines would change the text at all.
    private func canJoin(_ recognition: Recognition) -> Bool {
        var other = recognition
        other.joined.toggle()
        return assemble(other) != assemble(recognition)
    }

    private func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    // MARK: Capture Formula

    /// Capture Formula: drag over a formula, or pick a window, and its LaTeX goes to the clipboard, as it is (no `$`
    /// around it). The selection stays highlighted while the formula pack reads it in the text reader, on the CPU, and
    /// fades once the LaTeX is copied; the card, when it is on, shows it. Option held as the drag ends opens the area
    /// in the OCR panel instead, its text with each formula in it as LaTeX. Without the pack there is nothing to read
    /// with: a beep. `done` is told the LaTeX copied, or nil. Scripted checks leave the clipboard alone
    /// (`copiesToClipboard`) and choose whether the screen freezes (`freezes`, else Settings').
    func captureFormula(copiesToClipboard: Bool = true, freezes: Bool? = nil, done: ((String?) -> Void)? = nil) {
        guard !overlay.isActive else { done?(nil); return }
        guard formulaReader?() != nil else {
            Log.capture.error("Capture Formula needs the formula pack, which isn't installed")
            NSSound.beep()
            done?(nil)
            return
        }
        overlay.freezesScreen = freezes ?? settings.freezeScreen
        overlay.begin(mode: .area, purpose: .text) { [weak self] outcome in
            guard let self else { done?(nil); return }
            switch outcome {
            case .region(let rect, _, let modifiers, let frozen) where modifiers.contains(.option):
                done?(nil)
                Task { await self.openPanel(region: rect, frozen: frozen) }
            case .window(let target, let modifiers) where modifiers.contains(.option):
                done?(nil)
                Task { await self.openPanel(window: target) }
            case .region(let rect, _, _, let frozen):
                highlight.show(rect)
                Task { await self.readFormula(region: rect, frozen: frozen, copiesToClipboard: copiesToClipboard, done: done) }
            case .window(let target, _):
                highlight.show(target.frame)
                Task { await self.readFormula(window: target, done: done) }
            case .annotated, .color, .record, .scroll, .allInOne, .cancelled:
                done?(nil)
            }
        }
    }

    /// Reads the formula in a region of a display, as the overlay does after a drag; from the frozen frame, at its
    /// pixels (a formula drawn at 2x reads better than at 1x: Docs/ocr.md › L3 spike). Also the URL API's
    /// `capture-formula` with an area. `copiesToClipboard` false leaves the clipboard alone, for scripted checks.
    func readFormula(region rect: CGRect, frozen: CapturedFrame? = nil, copiesToClipboard: Bool = true, done: ((String?) -> Void)? = nil) async {
        highlight.show(rect)
        do {
            let frame = try await capture(rect, frozen: frozen)
            await readFormula(frame.image, selection: rect, copiesToClipboard: copiesToClipboard, done: done)
        } catch {
            Log.capture.error("Capture Formula failed to capture: \(error.localizedDescription, privacy: .public)")
            highlight.finish(copied: nil, announces: !settings.showTextResult, formula: true)
            done?(nil)
        }
    }

    private func readFormula(window target: WindowTarget, done: ((String?) -> Void)?) async {
        highlight.show(target.frame)
        do {
            let frame = try await capturer.captureWindow(target, shadow: false, layout: displays.layout)
            await readFormula(frame.image, selection: target.frame, copiesToClipboard: true, done: done)
        } catch {
            Log.capture.error("Capture Formula failed to capture the window: \(error.localizedDescription, privacy: .public)")
            highlight.finish(copied: nil, announces: !settings.showTextResult, formula: true)
            done?(nil)
        }
    }

    /// The URL API's `capture-formula` with a file: its LaTeX goes to the clipboard, the card (when it is on) by the
    /// pointer.
    func readFormula(fileAt url: URL, copiesToClipboard: Bool = true, done: ((String?) -> Void)? = nil) async {
        guard let loaded = await Self.load(.file(url), fallbackScale: 1) else {
            Log.capture.error("Could not read \(url.lastPathComponent, privacy: .public) to read its formula")
            highlight.finish(copied: nil, announces: true, formula: true)
            done?(nil)
            return
        }
        await readFormula(loaded.image, selection: CGRect(origin: NSEvent.mouseLocation, size: .zero), copiesToClipboard: copiesToClipboard, done: done)
    }

    private func readFormula(_ image: CGImage, selection: CGRect, copiesToClipboard: Bool, done: ((String?) -> Void)?) async {
        let showsCard = settings.showTextResult
        guard let reader = formulaReader?() else {
            highlight.finish(copied: nil, announces: !showsCard, formula: true)
            if showsCard { presentCard(.noFormula, near: selection) }
            done?(nil)
            return
        }
        let probe = LatencyProbe("ocr.formula")
        let started = ContinuousClock.now
        let formula = await Self.formula(in: image, pack: reader.pack, helper: reader.helper)
        probe.end()
        guard let formula, formula.isFormula else {
            Log.capture.notice("Capture Formula found no formula (\(formula?.ending ?? "failed", privacy: .public)) in \(String(describing: ContinuousClock.now - started), privacy: .public)")
            highlight.finish(copied: nil, announces: !showsCard, formula: true)
            if showsCard { presentCard(.noFormula, near: selection) }
            done?(nil)
            return
        }
        if copiesToClipboard { copy(formula.latex) }
        highlight.finish(copied: formula.latex, announces: !showsCard, formula: true)
        Log.capture.notice("Capture Formula \(copiesToClipboard ? "copied" : "read", privacy: .public) \(formula.latex.count, privacy: .public) characters of LaTeX in \(String(describing: ContinuousClock.now - started), privacy: .public)")
        if showsCard { presentCard(.copiedFormula(latex: formula.latex), near: selection) }
        done?(formula.latex)
    }

    /// The formula the pack reads in `image`, in a run of the text reader, or nil when the reader couldn't read it.
    @concurrent
    private nonisolated static func formula(in image: CGImage, pack: URL, helper: URL) async -> TextReaderTool.Formula? {
        guard let file = formulaPicture(image) else { return nil }
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            return try await TextReaderTool.formula(ofPictureAt: file, pack: pack, helper: helper)
        } catch {
            Log.capture.error("Reading a formula failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// The formulas the formula pack reads and the tables and charts the VLM pack reads in `image`, in a run of the text
    /// reader (Docs/ocr.md › Formulas among text, › The VLM pack), the VLM reading for `seconds` at most; none when it
    /// can't, or in a picture too large to look in. `found` is told how many there are to read.
    @concurrent
    nonisolated static func elements(
        in image: CGImage, formulas: URL?, vlm: URL?, seconds: Double, helper: URL,
        found: (@Sendable (TextRecognitionWindowController.Elements.Counts) -> Void)? = nil
    ) async -> TextRecognitionWindowController.Elements.Found {
        guard formulas != nil || vlm != nil, LayoutFinder.finds(width: image.width, height: image.height), let file = formulaPicture(image) else { return .init() }
        defer { try? FileManager.default.removeItem(at: file) }
        let counted: (@Sendable (TextReaderTool.Found) -> Void)? = found.map { found in
            { @Sendable counts in found(.init(formulas: counts.formulas, tables: counts.tables)) }
        }
        var pressure: MemoryPressure?
        #if DEBUG
        // debug/memory-pressure: what the reader takes the system's memory pressure to be.
        pressure = UserDefaults.standard.string(forKey: "debugMemoryPressure").flatMap(MemoryPressure.init(name:))
        #endif
        do {
            let read = try await TextReaderTool.elements(
                ofPictureAt: file, formulas: formulas, vlm: vlm, seconds: seconds, pressure: pressure, helper: helper, found: counted,
                timeout: .milliseconds(Int64(seconds * 1000))
            )
            if read.tablesLeft > 0 {
                Log.capture.notice("Left \(read.tablesLeft, privacy: .public) tables and charts as Vision read them: the system is short of memory for the VLM pack")
            }
            return .init(
                formulas: read.formulas.map { formula in
                    FormulaMerge.Formula(kind: formula.kind == "display" ? .display : .inline, box: formula.box, latex: formula.latex)
                },
                tables: read.tables.map { table in
                    TableMerge.Table(kind: table.kind == "chart" ? .chart : .table, box: table.box, rows: table.rows, isWhole: table.whole)
                }
            )
        } catch {
            if !Task.isCancelled { Log.capture.error("Finding formulas and tables failed: \(String(describing: error), privacy: .public)") }
            return .init()
        }
    }

    /// What a merge of tables did, in numbers: how many were taken, and why each other was left.
    nonisolated static func log(_ merge: TableMerge.Merged, of tables: [TableMerge.Table], in surface: String, after elapsed: Duration) {
        let refusals = merge.refused.map { "\(tables[$0.index].kind.rawValue) \($0.refusal.rawValue)" }.joined(separator: ", ")
        let cut = merge.cutRows > 0 ? ", \(merge.cutRows) rows the picture's edge cut left as Vision read them" : ""
        Log.capture.notice("\(surface, privacy: .public) took \(merge.taken.count, privacy: .public) of \(tables.count, privacy: .public) tables and charts read with the VLM pack\(refusals.isEmpty ? "" : " (left: \(refusals))", privacy: .public)\(cut, privacy: .public), \(String(describing: elapsed), privacy: .public) after Vision's reading")
    }

    /// `image` as an uncompressed TIFF for the text reader, written and read in a few milliseconds; the caller removes it.
    private nonisolated static func formulaPicture(_ image: CGImage) -> URL? {
        let folder = FileManager.default.temporaryDirectory.appending(path: "Formula Readings", directoryHint: .isDirectory)
        let file = folder.appending(path: "\(UUID().uuidString).tiff")
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil,
              let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.tiff.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: file)
            return nil
        }
        return file
    }

    // MARK: Translate Area

    /// Translate Area: drag over text, or pick a window, and its translation covers it where it is.
    /// Option held when the drag ends opens the OCR panel, translated, instead.
    func translateArea() {
        guard !overlay.isActive else { return }
        lens.close(animated: false)
        let pipeline = pipeline
        warmup?.cancel()
        warmup = Task { await pipeline.prewarm() }
        overlay.freezesScreen = settings.freezeScreen
        overlay.begin(mode: .area, purpose: .text) { [weak self] outcome in
            self?.warmup?.cancel()
            self?.warmup = nil
            switch outcome {
            case .region(let rect, _, let modifiers, let frozen):
                self?.highlight.show(rect)
                Task { await self?.translate(region: rect, frozen: frozen, inPanel: modifiers.contains(.option)) }
            case .window(let target, let modifiers):
                self?.highlight.show(target.frame)
                Task { await self?.translate(window: target, inPanel: modifiers.contains(.option)) }
            case .annotated, .color, .record, .scroll, .allInOne, .cancelled:
                break
            }
        }
    }

    private func translate(region rect: CGRect, frozen: CapturedFrame?, inPanel: Bool) async {
        do {
            let frame = try await capture(rect, frozen: frozen)
            await translate(frame.image, scale: Self.scale(of: frame), over: rect, source: String(localized: "Screen Area"), inPanel: inPanel)
        } catch {
            Log.capture.error("Translate Area failed to capture: \(error.localizedDescription, privacy: .public)")
            highlight.finish(copied: nil, announces: true)
        }
    }

    private func translate(window target: WindowTarget, inPanel: Bool) async {
        do {
            let frame = try await capturer.captureWindow(target, shadow: false, layout: displays.layout)
            await translate(frame.image, scale: Self.scale(of: frame), over: target.frame, source: target.ownerName, inPanel: inPanel)
        } catch {
            Log.capture.error("Translate Area failed to capture the window: \(error.localizedDescription, privacy: .public)")
            highlight.finish(copied: nil, announces: true)
        }
    }

    /// Reads `image`, translates it, and lays the translation over `frame`. When nothing could be
    /// translated (a language still to download, text already in the target, code), the area opens in
    /// the OCR panel, translated, which says why and offers a download or another language: a beep alone
    /// said nothing anyone could act on.
    func translate(_ image: CGImage, scale: CGFloat, over frame: CGRect, source: String, inPanel: Bool) async {
        let place = AppTextPlace(frame: frame, scale: scale)
        if inPanel {
            highlight.hide()
            openPanel(image: image, scale: scale, source: source, translating: true, place: place)
            return
        }
        let probe = LatencyProbe("ocr.translate-area")
        let choice = settings.translationTarget
        do {
            let lines = try await pipeline.recognize(image).lines
            let units = TranslationUnits.group(lines)
            let outcome = try await translator.translate(units, to: choice.isEmpty ? nil : Locale.Language(identifier: choice))
            guard !outcome.translations.isEmpty else {
                let skipped = Dictionary(grouping: units.compactMap(\.skip), by: { "\($0)" }).map { "\($1.count) \($0)" }.sorted().joined(separator: ", ")
                Log.capture.notice("Translate Area translated nothing into \(outcome.target.minimalIdentifier, privacy: .public): \(units.count, privacy: .public) units, skipped \(skipped, privacy: .public), \(outcome.inTarget.count, privacy: .public) already in it, to download \(outcome.needsDownload.map(\.minimalIdentifier), privacy: .public); opening the panel")
                highlight.hide()
                openPanel(image: image, scale: scale, source: source, translating: true, place: place)
                return
            }
            guard let rendering = await TranslationOverlay.render(
                image, lines: lines, units: units, translations: outcome.translations, language: outcome.target, scale: scale
            ) else {
                highlight.finish(copied: nil, announces: true)
                return
            }
            probe.end()
            let (text, translated) = Translator.text(of: units, outcome)
            let sources = ListFormatter.localizedString(byJoining: outcome.sources.map { Translator.name(of: $0) })
            lens.show(
                rendering.image, original: image, scale: scale, over: frame, text: text, translated: translated,
                language: Translator.identifier(of: outcome.target), summary: "\(sources) → \(Translator.name(of: outcome.target))",
                shortened: !rendering.truncated.isEmpty
            )
            lens.onOpenInPanel = { [weak self] in self?.openPanel(image: image, scale: scale, source: source, translating: true, place: place) }
            highlight.hide()
            Log.capture.notice("Translate Area translated \(outcome.translations.count, privacy: .public) of \(units.count, privacy: .public) units into \(outcome.target.minimalIdentifier, privacy: .public), \(rendering.truncated.count, privacy: .public) shortened")
        } catch {
            Log.capture.error("Translate Area failed: \(String(describing: error), privacy: .public)")
            highlight.finish(copied: nil, announces: true)
        }
    }

    #if DEBUG
    func revealLensControls() { lens.revealControls() }

    func closeLens() { lens.close(animated: false) }
    #endif

    private func announce(_ message: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
            .announcement: message,
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }

    // MARK: OCR panel

    /// Opens the OCR panel on `image`, read in full: text, tables, links, and codes. `scale` is the
    /// image's pixels per point; `source` names it under the title.
    ///
    /// With a model pack installed, a picture whose text holds Chinese or Japanese is read again with it in the text
    /// reader, and the two readings are put together (`TextAnalysis.withSecondReading`) before the panel shows them.
    ///
    /// With the formula pack installed, the formulas in the picture are found and read in the text reader beside
    /// Vision's reading, and come into the text as LaTeX once read.
    ///
    /// A picture of the screen (`place`) takes the characters of the apps there for the lines they show alike, while
    /// Settings says so (L0, Docs/ocr.md › Text from apps); they are asked as soon as Vision has read, and their
    /// characters go over the second reading's.
    func openPanel(image: CGImage, scale: CGFloat, source: String, translating: Bool = false, place: AppTextPlace? = nil) {
        let controller = panel ?? makePanel()
        panel = controller
        controller.show(
            image: image, scale: scale, source: source, translating: translating, elements: panelElements(readsTables: !isTerminal(place)),
            analyze: analyzer(for: place)
        )
    }

    /// The terminals whose windows keep their text as the program printed it: a listing in columns there (`ls -l`) isn't
    /// read as a table, which the layout model takes it for (Docs/ocr.md › The VLM pack).
    nonisolated static let terminals: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable", "net.kovidgoyal.kitty",
        "org.alacritty", "io.alacritty", "com.github.wez.wezterm", "co.zeit.hyper", "com.raphaelamorim.rio", "dev.commandline.waveterm",
        "com.termius-dmg.mac", "org.tabby",
    ]

    /// Whether the picture at `place` (of the screen; none for a file or the clipboard) is of a terminal: a picked
    /// window's own app, else the app whose standard window is in front at the middle of the area, OhMyShot's own left out.
    func isTerminal(_ place: AppTextPlace?) -> Bool {
        guard let place else { return false }
        let pid = place.pid ?? Optional(place.frame).flatMap { area -> pid_t? in
            let middle = displays.layout.flipped(CGPoint(x: area.midX, y: area.midY))
            let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
            return list.lazy.compactMap { info -> pid_t? in
                guard (info[kCGWindowLayer as String] as? Int) == 0,
                      let owner = info[kCGWindowOwnerPID as String] as? pid_t, owner != ProcessInfo.processInfo.processIdentifier,
                      let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                      CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0, width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0).contains(middle)
                else { return nil }
                return owner
            }.first
        }
        guard let pid, let identifier = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier else { return false }
        return Self.terminals.contains(identifier)
    }

    /// How the panel reads a picture: Vision; the second reading while a pack is installed; and for a picture of the
    /// screen (`place`), the apps' characters while Settings says so.
    func analyzer(for place: AppTextPlace?) -> @Sendable (CGImage) async throws -> TextAnalysis {
        let pipeline = pipeline
        let second = secondReader?()
        let place = settings.readsAppText ? place : nil
        let layout = displays.layout
        return { image in
            let analysis = try await pipeline.analyze(image)
            // Longer than Capture Text: the window shows Vision's reading meanwhile.
            let asking = Self.appText(for: analysis.result.lines, in: place, layout: layout, within: .milliseconds(500))
            var shown = analysis
            if let second, SecondReading.wanted(analysis.result.lines), PPOCRReader.reads(width: image.width, height: image.height) {
                let started = ContinuousClock.now
                if let lines = await Self.secondReading(of: image, with: second.pack, helper: second.helper) {
                    let merged = analysis.withSecondReading(lines, assembly: pipeline.options.assembly)
                    // Vision's lines keep their boxes; the added ones are sorted in among them.
                    let first = Dictionary(analysis.result.lines.map { ("\($0.box)", $0.text) }) { a, _ in a }
                    let changed = merged.result.lines.count { line in first["\(line.box)"].map { $0 != line.text } ?? false }
                    Log.capture.notice("Second reading: \(lines.count, privacy: .public) lines read, \(changed, privacy: .public) of \(analysis.result.lines.count, privacy: .public) changed, \(merged.result.lines.count - analysis.result.lines.count, privacy: .public) added, in \(String(describing: ContinuousClock.now - started), privacy: .public)")
                    shown = merged
                }
            }
            if let asking {
                let reading = await asking.value
                let (merged, merge) = shown.withAppText(
                    reading.lines.map { AppTextLine(box: $0.box, pieces: $0.pieces, app: $0.app) }, assembly: pipeline.options.assembly
                )
                Self.log(reading, merge, of: shown.result.lines.count, in: "The Recognized Text window")
                shown = merged
            }
            return shown
        }
    }

    /// How the panel gets the formulas, tables, and charts into its text; nil while neither the formula pack nor the VLM
    /// pack is installed. Asked as each panel
    /// opens.
    private func panelElements(readsTables: Bool = true) -> TextRecognitionWindowController.Elements? {
        guard let found = elementReader?() else { return nil }
        let reader = (formulas: found.formulas, vlm: readsTables ? found.vlm : nil, helper: found.helper)
        guard reader.formulas != nil || reader.vlm != nil else { return nil }
        let pipeline = pipeline
        return .init(
            read: { image, found in
                await Self.elements(in: image, formulas: reader.formulas, vlm: reader.vlm, seconds: Self.panelTableWait, helper: reader.helper, found: found)
            },
            merge: { lines, formulas, image in await pipeline.lines(lines, with: formulas, in: image) }
        )
    }

    /// How long the panel waits for the second reading once Vision's is done. A pack whose models are compiled answers
    /// in about half a second (Docs/ocr.md › L2 beside L1); compiling them takes 11 s.
    nonisolated static let secondReadingWait: Duration = .seconds(3)

    /// The lines the pack reads in `image`, in a run of the text reader, or nil when it can't read them or hasn't
    /// answered within `secondReadingWait`. The run is not stopped when the wait ends: by then it is most likely
    /// compiling the pack's models for the Neural Engine (the first read after an install or a system update), and
    /// stopped, it would start over on every panel.
    @concurrent
    private nonisolated static func secondReading(of image: CGImage, with pack: TextReaderPack, helper: URL) async -> [OCRLine]? {
        let folder = FileManager.default.temporaryDirectory.appending(path: "Second Readings", directoryHint: .isDirectory)
        let file = folder.appending(path: "\(UUID().uuidString).tiff")
        // Uncompressed: written and read in a few milliseconds, where PNG takes a tenth of a second for a large picture.
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil,
              let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.tiff.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }

        let reading = Task.detached(priority: .userInitiated) { () -> [TextReaderTool.Line]? in
            defer { try? FileManager.default.removeItem(at: file) }
            do {
                return try await TextReaderTool.lines(ofPictureAt: file, pack: pack.folder, helper: helper)
            } catch {
                Log.capture.error("The second reading failed: \(String(describing: error), privacy: .public)")
                return nil
            }
        }
        // Whichever comes first: the reader's answer (nil when it failed), or the end of the wait (nil twice).
        let (answers, answer) = AsyncStream.makeStream(of: [TextReaderTool.Line]??.self)
        Task {
            answer.yield(.some(await reading.value))
            answer.finish()
        }
        Task {
            try? await Task.sleep(for: secondReadingWait)
            answer.yield(.none)
            answer.finish()
        }
        var first: [TextReaderTool.Line]??
        for await answered in answers {
            first = answered
            break
        }
        guard let answered = first else {
            // Also when the panel stopped waiting (closed, or read again).
            if !Task.isCancelled { Log.capture.notice("The second reading didn't answer in time; Vision's reading is shown alone") }
            return nil
        }
        return answered?.map { OCRLine(text: $0.text, box: $0.box, confidence: $0.confidence) }
    }

    private func makePanel() -> TextRecognitionWindowController {
        let controller = TextRecognitionWindowController(settings: settings, translator: translator, cloud: cloud?())
        controller.onClose = { [weak self] in
            // Released on the next turn so the window is not deallocated inside its own delegate call.
            Task { @MainActor in
                self?.panel = nil
                // Nothing translates until the next panel: the system's models need not stay loaded.
                await self?.translator.releaseSessions()
                MemoryRelief.returnFreedPages()
            }
        }
        return controller
    }

    /// Option held when a Capture Text or Capture Formula drag ends. Also used by scripted checks.
    func openPanel(region rect: CGRect, frozen: CapturedFrame? = nil) async {
        do {
            let frame = try await capture(rect, frozen: frozen)
            openPanel(image: frame.image, scale: Self.scale(of: frame), source: String(localized: "Screen Area"), place: Self.place(of: frame))
        } catch {
            Log.capture.error("Capture Text failed to capture: \(error.localizedDescription, privacy: .public)")
            NSSound.beep()
        }
    }

    private func openPanel(window target: WindowTarget) async {
        do {
            let frame = try await capturer.captureWindow(target, shadow: false, layout: displays.layout)
            let title = target.title.flatMap { $0.isEmpty ? nil : $0 }
            openPanel(
                image: frame.image, scale: Self.scale(of: frame), source: title.map { "\(target.ownerName) – \($0)" } ?? target.ownerName,
                place: Self.place(of: frame, window: target)
            )
        } catch {
            Log.capture.error("Capture Text failed to capture the window: \(error.localizedDescription, privacy: .public)")
            NSSound.beep()
        }
    }

    /// The region as the overlay held it still when the screen was frozen, else captured now, on one
    /// display or across several.
    private func capture(_ rect: CGRect, frozen: CapturedFrame?) async throws -> CapturedFrame {
        if let frozen { return frozen }
        return try await capturer.captureArea(rect, in: displays.layout)
    }

    private static func scale(of frame: CapturedFrame) -> CGFloat {
        frame.frame.width > 0 ? CGFloat(frame.image.width) / frame.frame.width : 1
    }

    /// Opens an image file. `fallbackScale` applies when the file does not record its resolution.
    func openPanel(forFileAt url: URL, fallbackScale: CGFloat = 1, source: String? = nil) async {
        guard let loaded = await Self.load(.file(url), fallbackScale: fallbackScale) else {
            Log.capture.error("Could not read \(url.lastPathComponent, privacy: .public) to recognize its text")
            showFailure(.unreadableFile, source: source ?? url.lastPathComponent)
            return
        }
        openPanel(image: loaded.image, scale: loaded.scale, source: source ?? url.lastPathComponent)
    }

    private func showFailure(_ failure: TextRecognitionWindowController.OpenFailure, source: String) {
        let controller = panel ?? makePanel()
        panel = controller
        controller.show(failure, source: source)
    }

    /// Opens the image on a pasteboard: an image file, or image data named `source`. Returns whether
    /// there was one; a drop without one is refused, as the drop target already checked.
    @discardableResult
    func openPanel(from pasteboard: NSPasteboard, source: String) -> Bool {
        guard let content = PasteboardImage.read(pasteboard) else { return false }
        Task {
            let fallbackScale = displays.layout.displays.map(\.pixelsPerPoint).max() ?? 1
            guard let loaded = await Self.load(content, fallbackScale: fallbackScale) else {
                Log.capture.error("Could not read the image on the pasteboard to recognize its text")
                if case .file(let url) = content {
                    showFailure(.unreadableFile, source: url.lastPathComponent)
                } else {
                    showFailure(.unreadableFile, source: source)
                }
                return
            }
            if case .file(let url) = content {
                openPanel(image: loaded.image, scale: loaded.scale, source: url.lastPathComponent)
            } else {
                openPanel(image: loaded.image, scale: loaded.scale, source: source)
            }
        }
        return true
    }

    /// The clipboard's image. Read only now that it was asked for; the menu looks at its types alone.
    func openClipboardImage() {
        let source = String(localized: "Clipboard")
        if !openPanel(from: .general, source: source) {
            showFailure(.noImageOnClipboard, source: source)
        }
    }

    /// Asks for an image file to open.
    func openImageFile() {
        let chooser = NSOpenPanel()
        chooser.allowedContentTypes = [.image]
        chooser.message = String(localized: "Choose an image to recognize its text.")
        chooser.prompt = String(localized: "Recognize Text")
        NSApp.activate()
        chooser.begin { [weak self] response in
            guard response == .OK, let url = chooser.url else { return }
            Task { await self?.openPanel(forFileAt: url) }
        }
        chooser.orderFrontRegardless()
    }

    /// Decodes off the main thread: a large photo takes a while.
    @concurrent private nonisolated static func load(_ content: PasteboardImage.Content, fallbackScale: CGFloat) async -> ImageLoader.Loaded? {
        switch content {
        case .file(let url): ImageLoader.load(contentsOf: url, fallbackScale: fallbackScale)
        case .data(let data): ImageLoader.load(data: data, fallbackScale: fallbackScale)
        }
    }

    // MARK: Debug

    #if DEBUG
    /// Shows the card in a given state with sample text, for screenshots of the card itself.
    func previewCard(_ state: String, near selection: CGRect) {
        switch state {
        case "highlight":
            highlight.show(selection)
        case "empty":
            presentCard(.empty, near: selection)
        case "single":
            presentCard(.copied(text: "7", joined: false, canJoin: false), near: selection)
        case "formula":
            presentCard(.copiedFormula(latex: #"\mathrm{Attention}(Q,K,V)=\mathrm{softmax}\left(\frac{QK^{T}}{\sqrt{d_{k}}}\right)V"#), near: selection)
        case "no-formula":
            presentCard(.noFormula, near: selection)
        case "not-copied":
            presentCard(.notCopied(text: "OhMyShot Release Notes\nCapture text from anything on screen."), near: selection, note: String(localized: "You copied something else while it was read."))
        case "cloud":
            presentCard(.copied(text: "OhMyShot Release Notes\nCapture text from anything on screen.", joined: false, canJoin: false), near: selection, note: String(localized: "Read by \("Claude")"))
        default:
            let sample = "截图完成后，卡片会出现在屏幕左下角，可以直接拖到其他应用里。\nPress Copy to put the capture on the clipboard.\n历史记录会保留一周，之后自动删除。\nVersion 0.1.0 (build 42)"
            presentCard(.copied(text: sample, joined: false, canJoin: true), near: selection)
        }
    }

    /// Opens the panel with a stand-in for recognition, to show the loading and failure states.
    func previewPanel(image: CGImage, scale: CGFloat, source: String, analyze: @escaping @Sendable (CGImage) async throws -> TextAnalysis) {
        let controller = panel ?? makePanel()
        panel = controller
        controller.show(image: image, scale: scale, source: source, elements: panelElements(), analyze: analyze)
    }

    /// Sets the open panel's pane, line breaks, selected or hovered line, and whether the text was edited.
    func previewPanelState(
        pane: String?, joinLines: Bool?, selectLine: Int?, hoverLine: Int?, edited: Bool, translate: Bool?, target: String?, cloud: String? = nil
    ) {
        panel?.preview(
            pane: pane, joinLines: joinLines, selectLine: selectLine, hoverLine: hoverLine, edited: edited, translate: translate, target: target,
            cloud: cloud
        )
    }

    /// Closes the panel, so the next one is made anew (with the cloud model then in place).
    func closePanel() {
        panel?.close()
    }

    /// Capture Text's reading of a picture, as after a person's drag over `selection` (the cloud model too, while
    /// Settings says so, with `allowsCloud`), without touching the clipboard.
    func previewRecognition(of image: CGImage, near selection: CGRect, joinLines: Bool, allowsCloud: Bool, done: ((String?) -> Void)? = nil) async {
        await recognize(image, selection: selection, joinLines: joinLines, copiesToClipboard: false, allowsCloud: allowsCloud, done: done)
    }

    /// Shows a failure to open, as a broken file or an empty clipboard would.
    func previewPanelFailure(_ failure: TextRecognitionWindowController.OpenFailure) {
        showFailure(failure, source: "Demo")
    }
    #endif
}
