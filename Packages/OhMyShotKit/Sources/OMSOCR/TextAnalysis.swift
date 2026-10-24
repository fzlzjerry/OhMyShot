import CoreGraphics
import Foundation
import Vision

/// A QR code or barcode found in an image.
public struct OCRCode: Sendable, Equatable {
    public enum Kind: String, Sendable {
        case qr, aztec, dataMatrix, pdf417, ean13, ean8, upce, code128, code39, other

        /// A two-dimensional code rather than a row of bars.
        public var isMatrix: Bool {
            switch self {
            case .qr, .aztec, .dataMatrix, .pdf417: true
            default: false
            }
        }
    }

    public var payload: String
    public var kind: Kind
    /// In image pixels, top-left origin.
    public var box: CGRect
}

/// Everything the OCR panel shows about an image: its text read by L1, tables, and codes.
public struct TextAnalysis: Sendable {
    public var result: OCRResult
    /// Structure from Vision's document request, cells filled from the L1 lines where they fit.
    public var tables: [OCRTable]
    public var codes: [OCRCode]
}

extension VisionPipeline {
    /// Reads the text with L1, then finds codes alongside the document request for tables.
    /// The document request waits for L1 and uses the same process-wide recognition slot. It runs
    /// on every image: a table whose columns sit close reads as one line per row, so the lines alone
    /// cannot rule a table out, and skipping it saved only about 80 ms and 15 MB.
    ///
    /// The lines are read in pieces when the image is large (`recognize`). Tables and codes are not: a table
    /// or a code taller than a piece's overlap would be cut in two, and the whole image's request finds the
    /// 281-cell table 7000 pixels tall that its pieces' requests split (Docs/ocr.md › Large pictures); the
    /// cells take their text from the pieces' lines all the same.
    @concurrent
    public func analyze(_ image: CGImage) async throws -> TextAnalysis {
        let started = ContinuousClock.now
        let result = try await recognize(image)
        let remaining = options.overallTimeout - (ContinuousClock.now - started)
        try Task.checkCancellation()
        guard remaining > .zero else { return TextAnalysis(result: result, tables: [], codes: []) }
        // Once the text is read, optional table/code detection cannot keep it hidden indefinitely.
        let extra = try? await withTimeout(remaining) {
            async let codes = detectCodes(in: image)
            let tables = ((try? await documentTables(in: image)) ?? []).map { $0.filled(from: result.lines) }
            return TextAnalysis(result: result, tables: tables, codes: (try? await codes) ?? [])
        }
        try Task.checkCancellation()
        return extra ?? TextAnalysis(result: result, tables: [], codes: [])
    }

    private func detectCodes(in image: CGImage) async throws -> [OCRCode] {
        let size = CGSize(width: image.width, height: image.height)
        let request = DetectBarcodesRequest()
        let observations = try await withTimeout(options.timeout) { try await request.perform(on: image) }
        return observations.compactMap { observation in
            guard let payload = observation.payloadString, !payload.isEmpty else { return nil }
            return OCRCode(
                payload: payload,
                kind: Self.kind(of: observation.symbology),
                box: observation.boundingBox.toImageCoordinates(size, origin: .upperLeft)
            )
        }
    }

    private func documentTables(in image: CGImage) async throws -> [OCRTable] {
        var request = RecognizeDocumentsRequest()
        request.textRecognitionOptions.recognitionLanguages = options.primaryLanguages
        request.textRecognitionOptions.useLanguageCorrection = false
        request.barcodeDetectionOptions.enabled = false
        let configured = request
        let timeout = options.timeout
        let observations = try await withTimeout(timeout) {
            try await RecognitionSlots.shared.run { try await configured.perform(on: image) }
        }
        let size = CGSize(width: image.width, height: image.height)
        return observations.first?.document.tables.map { table in
            OCRTable(
                rows: table.rows.map { row in row.map(\.content.text.transcript) },
                cellBoxes: table.rows.map { row in row.map { Self.pixelBox(of: $0.content.boundingRegion, in: size) } }
            )
        } ?? []
    }

    /// A region's bounding box in pixels with a top-left origin (Vision's is normalized, bottom-left).
    private static func pixelBox(of region: NormalizedRegion, in size: CGSize) -> CGRect {
        let box = region.normalizedPath.boundingBoxOfPath
        return CGRect(x: box.minX * size.width, y: (1 - box.maxY) * size.height, width: box.width * size.width, height: box.height * size.height)
    }

    private static func kind(of symbology: BarcodeSymbology) -> OCRCode.Kind {
        switch symbology {
        case .qr, .microQR: .qr
        case .aztec: .aztec
        case .dataMatrix: .dataMatrix
        case .pdf417, .microPDF417: .pdf417
        case .ean13: .ean13
        case .ean8: .ean8
        case .upce: .upce
        case .code128: .code128
        case .code39, .code39Checksum, .code39FullASCII, .code39FullASCIIChecksum: .code39
        default: .other
        }
    }
}
