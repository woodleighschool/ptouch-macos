import CoreGraphics
import Foundation

nonisolated struct LabelError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) {
        errorDescription = message
    }
}

struct Label {
    let width: Int
    let pixels: [UInt8]
    let tape: Tape
    let profile: PrinterProfile

    static func validate(_ labels: [Label], loadedTape: Tape) throws {
        guard labels.allSatisfy({ $0.tape == loadedTape }) else {
            throw LabelError("The document's paper width does not match the loaded \(loadedTape.name) mm tape.")
        }
    }

    func commands() -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 100)
        bytes += [0x1B, 0x40, 0x1B, 0x69, 0x61, 1]
        bytes += [0x1B, 0x69, 0x7A, 0x84, 1, tape.statusCode, 0]
        bytes += (0 ..< 4).map { UInt8(truncatingIfNeeded: width >> ($0 * 8)) }
        bytes += [0, 0, 0x1B, 0x69, 0x4D, 0x40, 0x1B, 0x69, 0x4B, 8]
        bytes += [0x1B, 0x69, 0x64, UInt8(truncatingIfNeeded: profile.feedDots), UInt8(truncatingIfNeeded: profile.feedDots >> 8), 0x4D, 0]
        let byteCount = profile.headDots / 8
        for line in 0 ..< width {
            bytes += [0x47, UInt8(truncatingIfNeeded: byteCount), UInt8(truncatingIfNeeded: byteCount >> 8)]
            var raster = [UInt8](repeating: 0, count: byteCount)
            // Head order: rotate clockwise, then reverse the raster lines.
            for dot in 0 ..< profile.headDots where pixels[(profile.headDots - 1 - dot) * width + width - 1 - line] == 0 {
                raster[dot / 8] |= 1 << (7 - dot % 8)
            }
            bytes += raster
        }
        bytes.append(0x1A)
        return bytes
    }
}

func render(_ path: String, profile: PrinterProfile) throws -> [Label] {
    guard let pdf = CGPDFDocument(URL(fileURLWithPath: path) as CFURL), !pdf.isEncrypted, pdf.numberOfPages > 0 else {
        throw LabelError("Cannot read the PDF.")
    }
    return try (1 ... pdf.numberOfPages).map { pageNumber in
        guard let page = pdf.page(at: pageNumber) else { throw LabelError("Missing PDF page.") }
        let box = page.getBoxRect(.mediaBox)
        let rotated = page.rotationAngle % 180 != 0
        let pageWidth = (rotated ? box.height : box.width) * 25.4 / 72
        let pageHeight = (rotated ? box.width : box.height) * 25.4 / 72
        let landscapeTape = profile.tapes.first { abs($0.widthMM - pageHeight) < 0.1 }
        let portraitTape = profile.tapes.first { abs($0.widthMM - pageWidth) < 0.1 }
        guard let tape = landscapeTape ?? portraitTape else {
            throw LabelError("Page \(pageNumber) does not match a supported tape width. Select the loaded tape's paper size.")
        }
        let length = landscapeTape == nil ? pageHeight : pageWidth
        guard profile.lengthMM.contains(length) else {
            throw LabelError("Page \(pageNumber) exceeds this printer's label length limits.")
        }
        let scale = Double(profile.dpi) / 25.4
        let width = Int((length * scale).rounded())
        let height = Int((tape.widthMM * scale).rounded())
        guard let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: width,
                  space: CGColorSpaceCreateDeviceGray(),
                  bitmapInfo: 0
              ),
              let data = context.data else { throw LabelError("Cannot render PDF page.") }
        let target = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(target)
        context.scaleBy(x: Double(profile.dpi) / 72, y: Double(profile.dpi) / 72)
        let paper = CGRect(x: 0, y: 0, width: length * 72 / 25.4, height: tape.widthMM * 72 / 25.4)
        context.concatenate(page.getDrawingTransform(.mediaBox, rect: paper, rotate: landscapeTape == nil ? 90 : 0, preserveAspectRatio: true))
        context.drawPDFPage(page)
        let source = data.bindMemory(to: UInt8.self, capacity: width * height)
        let top = (height - tape.printableDots) / 2
        let headOffset = (profile.headDots - tape.printableDots) / 2
        var pixels = [UInt8](repeating: 255, count: width * profile.headDots)
        for y in 0 ..< height {
            for x in 0 ..< width where source[y * width + x] < 128 {
                guard (top ..< top + tape.printableDots).contains(y) else {
                    throw LabelError("Page \(pageNumber) has content outside the printable area of \(tape.name) mm tape.")
                }
                pixels[(y - top + headOffset) * width + x] = 0
            }
        }
        return Label(width: width, pixels: pixels, tape: tape, profile: profile)
    }
}
