import CoreGraphics
import Foundation
@testable import PTouchBridge
import Testing

@MainActor
struct LabelTests {
    @Test(arguments: [3.5, 6, 9, 12, 18, 24])
    func rendersSupportedWidths(_ width: Double) throws {
        let label = try withPDF(width: 80, height: width) { try render($0.path, profile: testPrinter.profile)[0] }
        #expect(label.tape.widthMM == width)
        #expect(label.pixels.count == label.width * testPrinter.profile.headDots)
        #expect(label.commands()[111] == label.tape.statusCode)
    }

    @Test func acceptsPortraitDocuments() throws {
        let label = try withPDF(width: 12, height: 80) { try render($0.path, profile: testPrinter.profile)[0] }
        #expect(label.tape.widthMM == 12)
        #expect(label.width == 567)
    }

    @Test func rejectsMixedCassetteJobBeforePrinting() throws {
        let first = try withPDF(width: 80, height: 12) { try render($0.path, profile: testPrinter.profile)[0] }
        let second = try withPDF(width: 80, height: 24) { try render($0.path, profile: testPrinter.profile)[0] }
        #expect(throws: LabelError.self) { try Label.validate([first, second], loadedTape: first.tape) }
    }

    @Test func followsProfileResolutionAndHeadGeometry() throws {
        let profile = PrinterProfile(
            model: "Test",
            dpi: 360,
            headDots: 256,
            tapes: [Tape(widthMM: 20, statusCode: 20, printableDots: 200)],
            lengthMM: 10 ... 500,
            feedDots: 28
        )
        let label = try withPDF(width: 80, height: 20) { try render($0.path, profile: profile)[0] }
        #expect(label.width == 1134)
        #expect(label.pixels.count == 1134 * 256)
        #expect(label.commands()[135] == 32)
    }

    @Test func rendersLabelAtNativeResolution() throws {
        let labels = try withPDF(width: 60, height: 24) { try render($0.path, profile: testPrinter.profile) }
        #expect(labels.count == 1)
        #expect(labels[0].width == 425)
        #expect(labels[0].pixels.count == 425 * 128)
    }

    @Test func rejectsOfficePaper() throws {
        _ = try withPDF(width: 210, height: 297) { url in
            #expect(throws: LabelError.self) { try render(url.path, profile: testPrinter.profile) }
        }
    }

    @Test func rejectsInkOutsidePrintHead() throws {
        _ = try withPDF(width: 60, height: 24, edgeInk: true) { url in
            #expect(throws: LabelError.self) { try render(url.path, profile: testPrinter.profile) }
        }
    }
}

@MainActor
func withPDF<T>(width: Double, height: Double, edgeInk: Bool = false, body: (URL) throws -> T) throws -> T {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
    defer { try? FileManager.default.removeItem(at: url) }
    var box = CGRect(x: 0, y: 0, width: width * 72 / 25.4, height: height * 72 / 25.4)
    let context = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
    context.beginPDFPage(nil)
    if edgeInk {
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 10, height: 2))
    }
    context.endPDFPage()
    context.closePDF()
    return try body(url)
}
