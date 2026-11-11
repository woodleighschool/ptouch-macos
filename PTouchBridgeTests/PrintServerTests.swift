import CCUPS
import Foundation
@testable import PTouchBridge
import Testing

@MainActor
struct PrintServerTests {
    @Test func bindsQueueIdentityToDeviceAddress() {
        let second = PrinterDescriptor(address: "00-11-22-33-44-66", name: testPrinter.name, profile: testPrinter.profile)
        #expect(second.queue != testPrinter.queue)
        #expect(second.uri != testPrinter.uri)
        #expect(second.uuid != testPrinter.uuid)
    }

    @Test func advertisesProfileInsteadOfTestLabel() throws {
        let response = try PrintServer(device: testPrinter).handle(request(operation: 11))
        #expect(response.text("printer-name") == testPrinter.queue)
        #expect(response.text("printer-uri-supported") == testPrinter.uri)
        #expect(response.text("media-ready") == nil)
        #expect(response.text("media-default") == "custom_100x24mm_100x24mm")
        #expect(ippValidateAttributes(response.pointer) != 0)
        let sizes = try #require(ippFindAttribute(response.pointer, "media-size-supported", IPP_TAG_BEGIN_COLLECTION))
        #expect(ippGetCount(sizes) == testPrinter.profile.tapes.count)
    }

    @Test func rejectsUnsupportedFormat() throws {
        let request = try request(operation: 4)
        request.string("document-format", "text/plain")
        let response = PrintServer(device: testPrinter).handle(request)
        #expect(status(response) == 0x040A)
    }

    @Test func rejectsInvalidCopies() throws {
        let request = try request(operation: 2)
        request.integer("copies", 0)
        let response = PrintServer(device: testPrinter).handle(request)
        #expect(status(response) == 0x040B)
    }

    @Test func rejectsA4WithoutOpeningBluetooth() throws {
        let request = try request(operation: 2)
        request.document = try withPDF(width: 210, height: 297) { try Data(contentsOf: $0) }
        let response = PrintServer(device: testPrinter).handle(request)
        #expect(status(response) == 0x0411)
        #expect(response.number("job-state") == 8)
    }

    @Test func cancelsJobWaitingForDocument() throws {
        let server = PrintServer(device: testPrinter)
        let created = try server.handle(request(operation: 5))
        let id = try #require(created.number("job-id"))
        let cancel = try request(operation: 8)
        cancel.integer("job-id", id)
        #expect(status(server.handle(cancel)) == 0)
        let query = try request(operation: 9)
        query.integer("job-id", id)
        #expect(server.handle(query).number("job-state") == 7)
    }

    private func request(operation: UInt8) throws -> IPPMessage {
        try IPPMessage(data: Data([2, 0, 0, operation, 0, 0, 0, 1, 3]))
    }

    private func status(_ response: IPPMessage) -> Int {
        let bytes = response.data()
        return Int(bytes[2]) << 8 | Int(bytes[3])
    }
}

@MainActor
let testPrinter = PrinterDescriptor(address: "00:11:22:33:44:55", name: "Test Printer", profile: PrinterProfile.profiles[0])
