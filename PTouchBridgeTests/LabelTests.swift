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
        #expect(label.commands(first: true, last: true)[111] == label.tape.statusCode)
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
        #expect(label.commands(first: true, last: true)[135] == 32)
    }

    @Test func rendersLabelAtNativeResolution() throws {
        let labels = try withPDF(width: 60, height: 24) { try render($0.path, profile: testPrinter.profile) }
        #expect(labels.count == 1)
        #expect(labels[0].width == 425)
        #expect(labels[0].pixels.count == 425 * 128)
    }

    @Test func singleLabelInitializesAndFeeds() throws {
        let label = try withPDF(width: 60, height: 24) { try render($0.path, profile: testPrinter.profile)[0] }
        let commands = label.commands(first: true, last: true)
        #expect(Array(commands.prefix(106)) == [UInt8](repeating: 0, count: 100) + [0x1B, 0x40, 0x1B, 0x69, 0x61, 1])
        #expect(commands[117] == 0)
        #expect(commands.last == 0x1A)
    }

    @Test func batchContinuesWithoutFeedingBetweenLabels() throws {
        let label = try withPDF(width: 60, height: 24) { try render($0.path, profile: testPrinter.profile)[0] }
        let first = label.commands(first: true, last: false)
        let middle = label.commands(first: false, last: false)
        let last = label.commands(first: false, last: true)

        #expect(first[117] == 0)
        #expect(first.last == 0x0C)
        for continuation in [middle, last] {
            // Continuations start with print information, without invalidating or initializing the batch.
            #expect(Array(continuation.prefix(3)) == [0x1B, 0x69, 0x7A])
            #expect(continuation[11] == 1)
            #expect(Array(continuation[13 ..< 21]) == [0x1B, 0x69, 0x4D, 0x40, 0x1B, 0x69, 0x4B, 8])
        }
        #expect(middle.last == 0x0C)
        #expect(last.last == 0x1A)
        #expect(Array(first.dropFirst(119).dropLast()) == Array(middle.dropFirst(13).dropLast()))
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
