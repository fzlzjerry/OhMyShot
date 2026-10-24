import CoreGraphics
import CoreText
import Foundation
import Vision

/// L1 OCR: Apple Vision plus OhMyShot's own post-processing.
///
/// One Vision request runs one recognition model, picked by its first language (Chinese and Japanese
/// share one that also reads English; Korean has its own), and a model drops what it cannot read without
/// a word. So the pipeline reads the image with the primary model, finds text regions it left empty, and
/// reads only those again with the fallback models. See Docs/ocr.md for the measurements behind this.
public struct VisionPipeline: OCREngine {
    public struct Options: Sendable {
        /// The first pass: a Chinese or Japanese language, then English.
        public var primaryLanguages: [Locale.Language]
        /// Passes for regions the first one missed, each its own model, in order.
        public var fallbackLanguages: [[Locale.Language]]
        public var assembly: TextAssembler.Options
        /// Per Vision request.
        public var timeout: Duration
        /// The entire image, including queued requests, pieces and language/repair passes.
        public var overallTimeout: Duration
        /// Told how long each step and each Vision request took, for the benchmark's `--trace`.
        public var trace: (@Sendable (String) -> Void)?

        public init(
            primaryLanguages: [Locale.Language] = [Locale.Language(identifier: "zh-Hans"), Locale.Language(identifier: "en-US")],
            fallbackLanguages: [[Locale.Language]] = [[Locale.Language(identifier: "en-US")]],
            assembly: TextAssembler.Options = .init(),
            timeout: Duration = .seconds(10),
            overallTimeout: Duration = .seconds(60)
        ) {
            self.primaryLanguages = primaryLanguages
            self.fallbackLanguages = fallbackLanguages
            self.assembly = assembly
            self.timeout = timeout
            self.overallTimeout = overallTimeout
        }
    }

    public let name: String
    public var options: Options

    public init(name: String = "l1", options: Options = .init()) {
        self.name = name
        self.options = options
    }

    private static let english = [Locale.Language(identifier: "en-US")]

    /// Runs off the caller's actor: besides Vision's requests, the pipeline scans pixels.
    ///
    /// A large image is read in overlapping pieces (`PictureText.pieces`), one after another, and the pieces'
    /// lines are put together in the whole image's coordinates: one Vision request over a large image shrinks
    /// it and loses small text (Docs/ocr.md › Large pictures, in bands).
    @concurrent
    public func recognize(_ image: CGImage) async throws -> OCRResult {
        let started = ContinuousClock.now
        return try await withTimeout(options.overallTimeout) {
            assembled(try await readImage(image), started: started)
        }
    }

    /// The picture in the file at `url`: a tall PNG's pieces are read from the file a band at a time
    /// (`PictureText.Bands`), the picture never decoded whole; any other picture is decoded and read as above.
    @concurrent
    public func recognize(fileAt url: URL) async throws -> OCRResult {
        try await withTimeout(options.overallTimeout) { try await recognizeFile(at: url) }
    }

    private func recognizeFile(at url: URL) async throws -> OCRResult {
        let started = ContinuousClock.now
        if let bands = PictureText.Bands(fileAt: url) {
            do {
                let merged = try await readPieces(bands.pieces, size: CGSize(width: bands.width, height: bands.height)) { piece in
                    guard let band = bands.image(of: piece) else { throw PictureText.Bands.Ended() }
                    return band
                }
                // Bands run across the whole width: no line is cut across them (`joinedAcrossColumns`).
                return assembled(LineNumbers.removed(from: merged), started: started)
            } catch is PictureText.Bands.Ended {
                // Decoded, the picture is read as far as ImageIO makes it out.
            }
        }
        return try await recognize(PictureText.image(at: url))
    }

    private func assembled(_ lines: [OCRLine], started: ContinuousClock.Instant) -> OCRResult {
        let assembling = ContinuousClock.now
        let ordered = ReadingOrder.sorted(lines)
        let text = TextAssembler.assemble(ordered, options: options.assembly)
        options.trace?("assembly: \(Self.milliseconds(ContinuousClock.now - assembling)) ms")
        return OCRResult(lines: ordered, text: text, duration: ContinuousClock.now - started)
    }

    /// The lines of an image, whole or in pieces, not yet in reading order.
    private func readImage(_ image: CGImage) async throws -> [OCRLine] {
        let size = CGSize(width: image.width, height: image.height)
        let pieces = PictureText.pieces(width: image.width, height: image.height)
        guard pieces.count > 1 else { return try await readPiece(image) }
        let merged = try await readPieces(pieces, size: size) { image.cropping(to: $0) }
        let joined = try await joinedAcrossColumns(merged, pieces: pieces, in: image)
        // A gutter of line numbers is found only with three numbers in view: a piece with fewer left its own.
        return LineNumbers.removed(from: joined)
    }

    /// The lines of `pieces` of a picture of `size`, each read as a picture of its own (`part` gives it; none when it
    /// can't), put together in the picture's coordinates.
    private func readPieces(_ pieces: [CGRect], size: CGSize, part: (CGRect) throws -> CGImage?) async throws -> [OCRLine] {
        var readings: [[OCRLine]] = []
        for (number, piece) in pieces.enumerated() {
            try Task.checkCancellation()
            guard let part = try part(piece) else {
                readings.append([])
                continue
            }
            options.trace?("piece \(number + 1) of \(pieces.count): \(Int(piece.minX)),\(Int(piece.minY)) \(part.width)×\(part.height)")
            readings.append(try await readPiece(part).map { $0.moved(by: piece.origin) })
        }
        return PieceMerge.merged(readings, pieces: pieces, size: size)
    }

    /// A line that runs across a whole overlap of two columns is cut in both (`PieceMerge.crossings`); each
    /// such line is read again whole, many of them stacked in a strip (a few strips, when there are dozens, since
    /// Vision shrinks a tall strip as it does a tall picture), and replaces its pieces if it reads about as long as
    /// they do together.
    private func joinedAcrossColumns(_ lines: [OCRLine], pieces: [CGRect], in image: CGImage) async throws -> [OCRLine] {
        let groups = PieceMerge.crossings(in: lines, pieces: pieces)
        guard !groups.isEmpty else { return lines }
        let wholes = groups.map { group in group.dropFirst().reduce(lines[group[0]].box) { $0.union(lines[$1].box) } }
        let first = lines.count
        let crops = LineStrip.crops(
            for: Array(first..<(first + wholes.count)),
            of: lines + wholes.map { OCRLine(text: "", box: $0, confidence: 1) },
            in: CGSize(width: image.width, height: image.height)
        )
        let latin = groups.allSatisfy { group in group.allSatisfy { !Script.containsCJK(lines[$0].text) } }
        var found = [Int: [OCRLine]]()
        for batch in LineStrip.batches(of: crops) {
            guard let strip = LineStrip(source: image, crops: Array(crops[batch])) else { continue }
            for read in try await readLines(in: strip.image, languages: latin ? Self.english : options.primaryLanguages) {
                if let row = strip.row(of: read.box) { found[batch.lowerBound + row, default: []].append(read) }
            }
        }
        var replaced = Set<Int>()
        var whole: [OCRLine] = []
        for (row, group) in groups.enumerated() {
            let parts = group.map { lines[$0] }
            guard let read = found[row]?.sorted(by: { $0.box.minX < $1.box.minX }) else { continue }
            let text = read.map(\.text).joined(separator: " ")
            guard PieceMerge.isWhole(text, of: parts) else { continue }
            replaced.formUnion(group)
            whole.append(OCRLine(
                text: text, box: wholes[row], confidence: read.map(\.confidence).min() ?? parts[0].confidence,
                direction: parts[0].direction, wrapsToNextLine: parts.last?.wrapsToNextLine
            ))
        }
        options.trace?("  column cuts: \(replaced.count) pieces of \(whole.count) lines read whole, \(groups.count - whole.count) left cut")
        return lines.indices.filter { !replaced.contains($0) }.map { lines[$0] } + whole
    }

    /// The lines of an image read as one piece: both models, the gaps between them, and the repairs.
    private func readPiece(_ image: CGImage) async throws -> [OCRLine] {
        var mark = ContinuousClock.now
        func lap(_ step: String) {
            guard let trace = options.trace else { return }
            let now = ContinuousClock.now
            trace("\(step): \(Self.milliseconds(now - mark)) ms")
            mark = now
        }
        // Finish the primary model before starting other requests: simultaneous model initialization
        // can stall Vision. The Latin reading still serves both English pages and English lines in CJK.
        options.trace?("primary pass started")
        var lines = try await readLines(in: image, languages: options.primaryLanguages)
        async let latinPage = readLines(in: image, languages: Self.english)
        async let detected = textRectangles(in: image)
        let latin = (try? await latinPage) ?? []
        let rectangles = try await detected
        lap("first pass")

        // Text that is all but free of CJK (a stray misread glyph aside) reads better with the Latin
        // model: English UI, code. It cannot be the first pass: next to CJK its text detection misses
        // whole lines.
        let all = lines.flatMap(\.text).filter { !$0.isWhitespace }
        let cjk = all.filter(Script.isCJK).count
        var fallbacks = options.fallbackLanguages
        var readByLatinModel = false
        options.trace?("  decision: \(cjk) CJK of \(all.count) characters; Latin page read \(characterCount(latin)) against \(characterCount(lines))")
        if !all.isEmpty, cjk <= 2, Double(cjk) < Double(all.count) * 0.05,
           characterCount(latin) >= characterCount(lines) * 4 / 5 {
            lines = latin
            readByLatinModel = true
            // The Latin model drops the odd Chinese word (a name, a file name); let the primary model have
            // the regions it leaves empty first.
            fallbacks.insert(options.primaryLanguages, at: 0)
        }

        lines = try await fillGaps(in: image, lines: lines, rectangles: rectangles, fallbacks: fallbacks, page: latin)
        lap("gaps")
        lines = LineNumbers.removed(from: lines)
        lines = try await rereadCodeWithLatinModel(in: image, lines: lines)
        lap("code")
        if !readByLatinModel {
            lines = try await readLatinLines(lines, page: latin, in: image)
        }
        lap("latin lines")
        lines = inferLoneBrackets(in: lines, image: image)
        lap("lone brackets")
        return lines
    }

    // MARK: Reading

    /// Lines in `region` (the whole image when nil), in image pixels with a top-left origin, with spaces
    /// restored where the image shows them.
    private func readLines(in image: CGImage, languages: [Locale.Language], region: CGRect? = nil) async throws -> [OCRLine] {
        try Task.checkCancellation()
        let size = CGSize(width: image.width, height: image.height)
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = languages
        let regionOfInterest = region.map { Self.normalized($0, in: size) }
        if let regionOfInterest {
            request.regionOfInterest = regionOfInterest
        }
        let configured = request
        let timeout = options.timeout
        let requested = ContinuousClock.now
        let observations = try await withTimeout(timeout) {
            try await RecognitionSlots.shared.run { try await configured.perform(on: image) }
        }
        let read = ContinuousClock.now
        defer {
            if let trace = options.trace {
                let area = region.map { "\(Int($0.width))×\(Int($0.height))" } ?? "\(image.width)×\(image.height)"
                trace("  request \(languages.map(\.minimalIdentifier).joined(separator: "+")) \(area): \(Self.milliseconds(read - requested)) ms, lines \(Self.milliseconds(ContinuousClock.now - read)) ms")
            }
        }
        let place: (NormalizedRect) -> CGRect = { rect in
            if let regionOfInterest {
                rect.toImageCoordinates(from: regionOfInterest, imageSize: size, origin: .upperLeft)
            } else {
                rect.toImageCoordinates(size, origin: .upperLeft)
            }
        }
        return observations.compactMap { observation -> OCRLine? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            var box = place(observation.boundingBox)
            // Slices of the candidate's string keep its indices, so Vision's glyph boxes still apply.
            var kept = candidate.string[...]
            var text = candidate.string
            if box.width > box.height, let ink = InkProfile(image: image, box: box) {
                let glyphs = { (range: Range<String.Index>) in candidate.boundingBox(for: range).map { place($0.boundingBox) } }
                if let trimmed = Icons.trimmed(kept, ink: ink, lineHeight: box.height, glyph: glyphs) {
                    kept = trimmed.text
                    text = String(kept)
                    box = CGRect(x: trimmed.span.lowerBound, y: box.minY, width: trimmed.span.upperBound - trimmed.span.lowerBound, height: box.height)
                }
                if Spacing.mayNeedSpaces(kept), let em = Spacing.em(of: kept, glyphs: glyphs) {
                    text = Spacing.restored(kept, ink: ink, em: em) { glyphs($0)?.maxX }
                }
            }
            return OCRLine(
                text: text,
                box: box,
                confidence: candidate.confidence,
                direction: OCRLine.Direction(observation.textDirection),
                wrapsToNextLine: observation.shouldWrapToNextLine
            )
        }
    }

    // MARK: Gaps

    /// Reads again, with each fallback model, the text regions the lines leave empty. The regions of one
    /// model are read side by side (two at a time, as `RecognitionSlots` allows): a request costs about
    /// the same whatever its size, 60–170 ms, so read one after another they added up. The Latin model
    /// has read the whole page already (`page`), so its fallback takes that reading of each region
    /// instead of asking again: on the benchmark and the real screenshots, no region it read again was
    /// ever kept, and each such request cost 20–120 ms.
    private func fillGaps(
        in image: CGImage, lines: [OCRLine], rectangles: [CGRect], fallbacks: [[Locale.Language]], page: [OCRLine]
    ) async throws -> [OCRLine] {
        var lines = lines
        let size = CGSize(width: image.width, height: image.height)
        var gaps = padded(merged(rectangles.filter { isMissing($0, given: lines) }), in: size)
        for languages in fallbacks where !gaps.isEmpty {
            var remaining: [CGRect] = []
            let reads = languages == Self.english
                ? gaps.map { region in page.filter { overlapFraction(of: $0.box, in: region) > 0.5 } }
                : try await readLines(in: image, languages: languages, regions: gaps)
            for (region, found) in zip(gaps, reads) {
                let earlier = lines.filter { overlapFraction(of: $0.box, in: region) > 0.5 }
                options.trace?("  gap \(languages.map(\.minimalIdentifier).joined(separator: "+")) \(Int(region.width))×\(Int(region.height)): read \(characterCount(found)) against \(characterCount(earlier))\(characterCount(found) > characterCount(earlier) ? ", kept" : "")")
                // Keep whichever pass read more of the region.
                if characterCount(found) > characterCount(earlier) {
                    lines.removeAll { overlapFraction(of: $0.box, in: region) > 0.5 }
                    lines += found
                } else {
                    remaining.append(region)
                }
            }
            gaps = remaining
        }
        return lines
    }

    /// Each region read with `languages`, side by side, in the regions' order.
    private func readLines(in image: CGImage, languages: [Locale.Language], regions: [CGRect]) async throws -> [[OCRLine]] {
        guard regions.count > 1 else {
            var reads: [[OCRLine]] = []
            for region in regions { reads.append(try await readLines(in: image, languages: languages, region: region)) }
            return reads
        }
        return try await withThrowingTaskGroup(of: (Int, [OCRLine]).self) { group in
            for (index, region) in regions.enumerated() {
                group.addTask { (index, try await readLines(in: image, languages: languages, region: region)) }
            }
            var reads = [[OCRLine]](repeating: [], count: regions.count)
            for try await (index, found) in group { reads[index] = found }
            return reads
        }
    }

    /// Where text is in the image, whatever its script, in pixels with a top-left origin.
    private func textRectangles(in image: CGImage) async throws -> [CGRect] {
        let size = CGSize(width: image.width, height: image.height)
        let request = DetectTextRectanglesRequest()
        return try await withTimeout(options.timeout) { try await request.perform(on: image) }
            .map { $0.boundingBox.toImageCoordinates(size, origin: .upperLeft) }
    }

    /// Whether the lines leave a text region empty, or cover it with far fewer characters than it holds
    /// (a model reading a script it does not know returns a few stray glyphs).
    private func isMissing(_ rectangle: CGRect, given lines: [OCRLine]) -> Bool {
        guard rectangle.width > 0, rectangle.height > 0 else { return false }
        var coveredWidth: CGFloat = 0
        var characters: CGFloat = 0
        for line in lines where line.box.intersects(rectangle) {
            let shared = line.box.intersection(rectangle)
            coveredWidth += shared.width
            characters += CGFloat(line.text.count) * shared.width / max(line.box.width, 1)
        }
        // Square CJK glyphs are about as wide as the line is tall; Latin text packs more characters.
        let expected = rectangle.width / (rectangle.height * 0.9)
        return coveredWidth < rectangle.width * 0.5 || characters < expected * 0.5
    }

    /// Vision never returns a line holding a single glyph, and its text detector skips such lines too, so
    /// the closing brackets of code, alone on their lines, go missing in every pass. The pixels still show
    /// them; in a code listing, each such glyph becomes the closer of the bracket left open on the line
    /// above it that starts in the same column. Nothing is guessed where no open bracket lines up.
    private func inferLoneBrackets(in lines: [OCRLine], image: CGImage) -> [OCRLine] {
        let ordered = ReadingOrder.sorted(lines)
        guard TextAssembler.isCodeListing(ordered) else { return lines }
        let widths = ordered.filter { !Script.containsCJK($0.text) && $0.text.count >= 4 }.map { $0.box.width / CGFloat($0.text.count) }.sorted()
        guard !widths.isEmpty else { return lines }
        let characterWidth = widths[widths.count / 2]
        let glyphs = LoneGlyphs.find(in: image, around: ordered, characterWidth: characterWidth)
        guard !glyphs.isEmpty else { return lines }

        enum Event {
            case line(OCRLine)
            case glyph(CGRect)
            var top: CGFloat {
                switch self {
                case .line(let line): line.box.minY
                case .glyph(let rectangle): rectangle.minY
                }
            }
        }
        let pairs: [Character: Character] = ["{": "}", "[": "]", "(": ")"]
        let closers = Set(pairs.values)
        var open: [(bracket: Character, x: CGFloat)] = []
        var inferred: [OCRLine] = []
        for event in (ordered.map(Event.line) + glyphs.map(Event.glyph)).sorted(by: { $0.top < $1.top }) {
            switch event {
            case .line(let line):
                for character in TextAssembler.asCode(line.text) {
                    if pairs[character] != nil {
                        open.append((character, line.box.minX))
                    } else if closers.contains(character), let index = open.lastIndex(where: { pairs[$0.bracket] == character }) {
                        open.removeSubrange(index...)
                    }
                }
            case .glyph(let rectangle):
                guard let index = open.lastIndex(where: { abs($0.x - rectangle.minX) < characterWidth * 0.6 }),
                      let closer = pairs[open[index].bracket] else { continue }
                open.removeSubrange(index...)
                inferred.append(OCRLine(text: String(closer), box: rectangle, confidence: 0.3, direction: .leftToRight))
            }
        }
        return lines + inferred
    }

    // MARK: Latin lines on a CJK page

    /// On a page with CJK, the lines written in English alone are read by the Chinese model too, which has
    /// no language correction and confuses letter case ("Quick" as "QuICK", "copied" as "copiea"). Each
    /// such line takes the Latin model's reading of the same box from the page pass (Vision's two models
    /// find the same lines in prose). A line the page pass missed is read again in a strip that holds
    /// nothing else (`LineStrip`): with CJK in view, the Latin model's detector can miss whole lines. A
    /// line keeps its box, and its text changes only when the Latin reading is about as long. Code
    /// listings keep their own pass (`rereadCodeWithLatinModel`), which also finds lines the first missed.
    private func readLatinLines(_ lines: [OCRLine], page: [OCRLine], in image: CGImage) async throws -> [OCRLine] {
        guard !TextAssembler.isCodeListing(ReadingOrder.sorted(lines)) else { return lines }
        var lines = lines
        var unread: [Int] = []
        for index in lines.indices where lines[index].box.width > lines[index].box.height && Script.isLatinLine(lines[index].text) {
            if let pieces = Self.pieces(of: lines[index].box, in: page) {
                Self.adopt(pieces, at: index, in: &lines)
            } else {
                unread.append(index)
            }
        }
        let size = CGSize(width: image.width, height: image.height)
        guard !unread.isEmpty, let strip = LineStrip(source: image, crops: LineStrip.crops(for: unread, of: lines, in: size)) else {
            return lines
        }
        var rows = [Int: [OCRLine]]()
        for line in try await readLines(in: strip.image, languages: Self.english) {
            if let row = strip.row(of: line.box) { rows[row, default: []].append(line) }
        }
        for (row, index) in unread.enumerated() {
            if let pieces = rows[row] { Self.adopt(pieces, at: index, in: &lines) }
        }
        return lines
    }

    /// The page reading's lines that make up a box: those lying mostly inside it, when together they span
    /// most of its width.
    static func pieces(of box: CGRect, in page: [OCRLine]) -> [OCRLine]? {
        let inside = page.filter { candidate in
            let shared = candidate.box.intersection(box)
            guard !shared.isNull, candidate.box.width > 0, candidate.box.height > 0 else { return false }
            return shared.width * shared.height >= candidate.box.width * candidate.box.height * 0.7
        }
        let covered = inside.reduce(0) { $0 + $1.box.intersection(box).width }
        return inside.isEmpty || covered < box.width * 0.8 ? nil : inside
    }

    /// Puts the Latin reading in place of a line's text, left to right, if it is about as long (between
    /// 80% and 125% of the characters): a reading much shorter or longer is a misread of its own.
    static func adopt(_ pieces: [OCRLine], at index: Int, in lines: inout [OCRLine]) {
        let ordered = pieces.sorted { $0.box.minX < $1.box.minX }
        let text = ordered.map(\.text).joined(separator: " ")
        let before = lines[index].text.filter { !$0.isWhitespace }.count
        let after = text.filter { !$0.isWhitespace }.count
        guard !Script.containsCJK(text), after * 5 >= before * 4, after * 4 <= before * 5 else { return }
        let line = lines[index]
        lines[index] = OCRLine(
            text: text,
            box: line.box,
            confidence: ordered.map(\.confidence).min() ?? line.confidence,
            direction: line.direction,
            wrapsToNextLine: line.wrapsToNextLine
        )
    }

    // MARK: Code

    /// In code with CJK comments, the CJK model reads the code itself poorly (`url` as `ur1`, full-width
    /// brackets, braces as 子) and the Latin model cannot see past the comments. So each run of code lines
    /// between CJK lines is read again on its own with the Latin model, the runs side by side.
    private func rereadCodeWithLatinModel(in image: CGImage, lines: [OCRLine]) async throws -> [OCRLine] {
        let ordered = ReadingOrder.sorted(lines)
        guard TextAssembler.isCodeListing(ordered), ordered.contains(where: { Script.containsCJK($0.text) }) else { return lines }
        let size = CGSize(width: image.width, height: image.height)

        var blocks: [[OCRLine]] = [[]]
        for line in ordered {
            if Script.containsCJK(line.text) {
                blocks.append([])
            } else {
                blocks[blocks.count - 1].append(line)
            }
        }
        let cjkLines = ordered.filter { Script.containsCJK($0.text) }
        var kept = ordered.filter { Script.containsCJK($0.text) }
        var runs: [(block: [OCRLine], region: CGRect)] = []
        for block in blocks where !block.isEmpty {
            // The block's rows with some margin, but never reaching the CJK lines above or below.
            let union = block.dropFirst().reduce(block[0].box) { $0.union($1.box) }
            let rowHeight = block.map(\.box.height).min() ?? 0
            let ceiling = cjkLines.filter { $0.box.maxY <= union.minY }.map(\.box.maxY).max() ?? 0
            let floor = cjkLines.filter { $0.box.minY >= union.maxY }.map(\.box.minY).min() ?? size.height
            let top = max(ceiling, union.minY - rowHeight * 0.4)
            let bottom = min(floor, union.maxY + rowHeight * 0.4)
            let region = CGRect(x: union.minX - rowHeight, y: top, width: union.width + rowHeight * 2, height: bottom - top)
                .intersection(CGRect(origin: .zero, size: size))
            if region.isNull || region.height <= 0 {
                kept += block
            } else {
                runs.append((block, region))
            }
        }
        let reads = try await readLines(in: image, languages: Self.english, regions: runs.map(\.region))
        for ((block, _), found) in zip(runs, reads) {
            kept += Self.isLatinReading(found, of: block) ? found : block
        }
        return kept
    }

    /// Whether `found` is a Latin reading of `block`: no CJK, and about as much text.
    private static func isLatinReading(_ found: [OCRLine], of block: [OCRLine]) -> Bool {
        func count(_ lines: [OCRLine]) -> Int { lines.reduce(0) { $0 + $1.text.filter { !$0.isWhitespace }.count } }
        return !found.contains(where: { Script.containsCJK($0.text) }) && count(found) >= count(block) * 9 / 10
    }

    // MARK: Geometry

    /// Regions one line apart or closer, overlapping sideways, become one.
    private func merged(_ rectangles: [CGRect]) -> [CGRect] {
        var merged: [CGRect] = []
        for rectangle in rectangles.sorted(by: { $0.minY < $1.minY }) {
            if let last = merged.last,
               rectangle.minY - last.maxY < rectangle.height * 1.5,
               rectangle.minX < last.maxX, rectangle.maxX > last.minX {
                merged[merged.count - 1] = last.union(rectangle)
            } else {
                merged.append(rectangle)
            }
        }
        return merged
    }

    private func padded(_ rectangles: [CGRect], in size: CGSize) -> [CGRect] {
        let bounds = CGRect(origin: .zero, size: size)
        return rectangles.map { rectangle in
            let padding = min(rectangle.height, 40) * 0.5
            return rectangle.insetBy(dx: -padding, dy: -padding).intersection(bounds)
        }
    }

    private func characterCount(_ lines: [OCRLine]) -> Int {
        lines.reduce(0) { $0 + $1.text.filter { !$0.isWhitespace }.count }
    }

    /// How much of `box` lies inside `region`, from 0 to 1.
    private func overlapFraction(of box: CGRect, in region: CGRect) -> CGFloat {
        let shared = box.intersection(region)
        guard !shared.isNull, box.width > 0, box.height > 0 else { return 0 }
        return (shared.width * shared.height) / (box.width * box.height)
    }

    static func milliseconds(_ duration: Duration) -> Int {
        let (seconds, attoseconds) = duration.components
        return Int(Double(seconds) * 1000 + Double(attoseconds) / 1e15)
    }

    /// A pixel rect with a top-left origin as Vision's normalized rect (bottom-left origin).
    private static func normalized(_ rect: CGRect, in size: CGSize) -> NormalizedRect {
        NormalizedRect(
            x: rect.minX / size.width,
            y: (size.height - rect.maxY) / size.height,
            width: rect.width / size.width,
            height: rect.height / size.height
        )
    }
}

/// Which pixel columns of a line hold ink, measured against the line's own background, so it works on
/// light and dark backgrounds alike.
struct InkProfile {
    /// The image x of the first column.
    let originX: Int
    let ink: [Bool]

    init(originX: Int, ink: [Bool]) {
        self.originX = originX
        self.ink = ink
    }

    /// The runs of columns with ink, in image x, left to right.
    var runs: [Range<Int>] {
        var runs: [Range<Int>] = []
        var start: Int?
        for (column, hasInk) in ink.enumerated() {
            if hasInk, start == nil { start = column }
            if !hasInk, let first = start {
                runs.append((originX + first)..<(originX + column))
                start = nil
            }
        }
        if let first = start { runs.append((originX + first)..<(originX + ink.count)) }
        return runs
    }

    init?(image: CGImage, box: CGRect) {
        let rect = box.integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !rect.isNull, rect.width >= 2, rect.height >= 2, let cropped = image.cropping(to: rect) else { return nil }
        let width = Int(rect.width)
        let height = Int(rect.height)
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        // The background is what the box's top and bottom rows mostly show.
        let edges = (Array(pixels[0..<width]) + Array(pixels[(height - 1) * width..<height * width])).sorted()
        let background = Int(edges[edges.count / 2])
        originX = Int(rect.minX)
        ink = (0..<width).map { x in
            (0..<height).contains { y in abs(Int(pixels[y * width + x]) - background) > 48 }
        }
    }

    /// The widest run of empty columns between `from` and `to` (image x).
    func widestGap(from: CGFloat, to: CGFloat) -> CGFloat {
        let start = max(0, Int(from) - originX)
        let end = min(ink.count, Int(to.rounded(.up)) - originX)
        guard start < end else { return 0 }
        var widest = 0
        var run = 0
        for column in start..<end {
            run = ink[column] ? 0 : run + 1
            widest = max(widest, run)
        }
        return CGFloat(widest)
    }
}

/// Puts back the spaces Vision drops where Chinese meets Latin letters or digits ("下午 3 点" read as
/// "下午3点", "24 px" as "24px"), going by the empty pixel columns at that spot rather than a style rule.
///
/// macOS text layout already leaves a gap of up to about 0.25 em between CJK and Latin where nobody
/// typed a space, while a typed space leaves 0.32 em or more (measured with the benchmark), so the cut
/// is at 0.3 em. Japanese gets no spaces back at all: its automatic gap reaches 0.29 em, and Japanese
/// rarely puts spaces there anyway.
enum Spacing {
    /// Whether the text has a boundary Vision drops spaces at.
    static func mayNeedSpaces(_ text: Substring) -> Bool {
        text.contains(where: Script.isCJK) && text.contains(where: Script.isLatinOrDigit) && !text.contains(where: Script.isKana)
    }

    /// The width of a full-width character in this line: the median width Vision gives its CJK
    /// characters.
    static func em(of text: Substring, glyphs: (Range<String.Index>) -> CGRect?) -> CGFloat? {
        let widths = text.indices
            .filter { Script.isCJK(text[$0]) }
            .compactMap { glyphs($0..<text.index(after: $0))?.width }
            .sorted()
        return widths.isEmpty ? nil : widths[widths.count / 2]
    }

    /// Spaces at a CJK–Latin boundary follow the image both ways: one is added where the gap is a typed
    /// space (over 0.3 em), and one Vision put in is dropped where the glyphs nearly touch (under 0.2 em).
    ///
    /// - Parameter boundary: the image x where a range of the text ends, if Vision knows it.
    static func restored(_ text: Substring, ink: InkProfile, em: CGFloat, boundary: (Range<String.Index>) -> CGFloat?) -> String {
        var output = ""
        var previous: (character: Character, range: Range<String.Index>)?
        var spaceAfterPrevious = false
        for index in text.indices {
            let character = text[index]
            if character.isWhitespace {
                if previous == nil { output.append(character) } else { spaceAfterPrevious = true }
                continue
            }
            let range = index..<text.index(after: index)
            if let last = previous, isBoundary(last.character, character), let x = boundary(last.range) {
                // Vision's own spaces are usually right, so one goes only where the glyphs clearly touch.
                let window = em * 0.45
                let gap = ink.widestGap(from: x - window, to: x + window)
                if gap > em * (spaceAfterPrevious ? 0.2 : 0.3) {
                    output.append(" ")
                }
            } else if spaceAfterPrevious {
                output.append(" ")
            }
            spaceAfterPrevious = false
            output.append(character)
            previous = (character, range)
        }
        if spaceAfterPrevious { output.append(" ") }
        return output
    }

    /// CJK next to a Latin letter or digit, or a digit next to a letter ("24px"), in either order.
    static func isBoundary(_ a: Character, _ b: Character) -> Bool {
        if Script.isCJK(a) && Script.isLatinOrDigit(b) || Script.isLatinOrDigit(a) && Script.isCJK(b) { return true }
        guard Script.isLatinOrDigit(a), Script.isLatinOrDigit(b) else { return false }
        return a.isNumber != b.isNumber
    }
}

extension VisionPipeline.Options {
    /// Options for a person's preferred languages, most preferred first (`Locale.preferredLanguages`
    /// gives identifiers such as `zh-Hans-CN`): the first Chinese or Japanese language leads the primary
    /// pass (Simplified Chinese when none is preferred), Korean gets a fallback pass when it is
    /// preferred, and English is always the last resort.
    public static func preferred(_ identifiers: [String] = Locale.preferredLanguages) -> Self {
        let english = Locale.Language(identifier: "en-US")
        let languages = identifiers.map { Locale.Language(identifier: Locale.Language(identifier: $0).maximalIdentifier) }
        let cjk = languages.first { $0.languageCode == .chinese || $0.languageCode == .japanese }
        let primary: Locale.Language = switch (cjk?.languageCode, cjk?.script) {
        case (.japanese?, _): Locale.Language(identifier: "ja-JP")
        case (.chinese?, .hanTraditional?): Locale.Language(identifier: "zh-Hant")
        default: Locale.Language(identifier: "zh-Hans")
        }
        var fallbacks: [[Locale.Language]] = []
        if languages.contains(where: { $0.languageCode == .korean }) {
            fallbacks.append([Locale.Language(identifier: "ko-KR"), english])
        }
        fallbacks.append([english])
        return Self(primaryLanguages: [primary, english], fallbackLanguages: fallbacks)
    }
}

extension VisionPipeline {
    /// Loads both models a recognition uses, the primary and the Latin, before the first real request by
    /// reading a few rendered characters (a blank image might never reach the recognizer). Run it while
    /// the person is still selecting. Warmups never queue behind recognition or repeat successful work.
    @concurrent
    public func prewarm() async {
        guard let image = Self.warmupImage() else { return }
        for languages in [options.primaryLanguages, Self.english] {
            do {
                let warmed = try await RecognitionWarmup.shared.run(for: languages.map(\.minimalIdentifier)) {
                    var request = RecognizeTextRequest()
                    request.recognitionLevel = .accurate
                    request.usesLanguageCorrection = false
                    request.recognitionLanguages = languages
                    let configured = request
                    return try await withTimeout(options.timeout) {
                        try await RecognitionSlots.shared.runIfAvailable {
                            _ = try await configured.perform(on: image)
                            return true
                        } ?? false
                    }
                }
                guard warmed else { return }
            } catch {
                // A cancelled, busy, or failed primary warmup must not add a Latin warmup behind it.
                return
            }
        }
    }

    private static func warmupImage() -> CGImage? {
        let width = 240
        let height = 64
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateUIFontForLanguage(.system, 28, "zh-Hans" as CFString) ?? CTFontCreateWithName("Helvetica" as CFString, 28, nil)
        let text = NSAttributedString(string: "文字 Text", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
        ])
        context.textPosition = CGPoint(x: 16, y: 20)
        CTLineDraw(CTLineCreateWithAttributedString(text), context)
        return context.makeImage()
    }
}

extension VisionPipeline {
    /// `lines` (of `image`) with `formulas` in them, in reading order (`FormulaMerge`): what Vision made of each formula
    /// gives way to its LaTeX, and the text beside a formula is read again without it. The lines as they were when the
    /// pieces can't be read.
    @concurrent
    public func lines(_ lines: [OCRLine], with formulas: [FormulaMerge.Formula], in image: CGImage) async -> [OCRLine] {
        let plan = FormulaMerge.plan(lines, formulas: formulas)
        guard plan.changes else { return lines }
        let size = CGSize(width: image.width, height: image.height)
        let crops = FormulaMerge.crops(plan, lines: lines, formulas: formulas, size: size) { InkProfile(image: image, box: $0) }
        do {
            let read = try await withTimeout(options.overallTimeout) {
                try await self.read(crops: crops.compactMap(\.self), in: image, latin: plan.latin)
            }
            var texts = read.makeIterator()
            let pieces = crops.map { $0 == nil ? "" : texts.next() ?? "" }
            return ReadingOrder.sorted(FormulaMerge.lines(lines, formulas: formulas, plan: plan, pieces: pieces))
        } catch {
            options.trace?("formulas: the pieces beside them couldn't be read: \(error)")
            return lines
        }
    }

    /// The text of each of `crops` of `image` (its pixels, top-left origin), each read alone: stacked in strips
    /// (`LineStrip`), a request a strip, with the Latin model when `latin`. Within a crop, what Vision reads as two lines
    /// is joined left to right.
    func read(crops: [CGRect], in image: CGImage, latin: Bool) async throws -> [String] {
        guard !crops.isEmpty else { return [] }
        var found = [Int: [OCRLine]]()
        for batch in LineStrip.batches(of: crops) {
            guard let strip = LineStrip(source: image, crops: Array(crops[batch])) else { continue }
            for read in try await readLines(in: strip.image, languages: latin ? Self.english : options.primaryLanguages) {
                if let row = strip.row(of: read.box) { found[batch.lowerBound + row, default: []].append(read) }
            }
        }
        return crops.indices.map { index in
            let read = (found[index] ?? []).sorted { $0.box.minX < $1.box.minX }.map(\.text)
            return FormulaMerge.joined(read.map { ($0, false) })
        }
    }
}
