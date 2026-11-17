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
        let response = try PrintServer(device: testPrinter, synchronizeQueue: { _, _, _, _ in }).handle(request(operation: 11))
        #expect(response.text("printer-name") == testPrinter.queue)
        #expect(response.text("printer-uri-supported") == testPrinter.uri)
        #expect(response.text("media-ready") == nil)
        #expect(response.text("media-default") == "custom_100x24mm_100x24mm")
        #expect(ippValidateAttributes(response.pointer) != 0)
        let sizes = try #require(ippFindAttribute(response.pointer, "media-size-supported", IPP_TAG_BEGIN_COLLECTION))
        #expect(ippGetCount(sizes) == testPrinter.profile.tapes.count)
    }

    @Test(arguments: PrinterProfile.profiles[0].tapes)
    func advertisesLoadedWidthAsDefault(tape: Tape) throws {
        let response = try IPPMessage(responseTo: request(operation: 11))
        response.printerAttributes(device: testPrinter, status: QueueStatus(printer: .ready(tape), jobError: nil), knownTape: tape, queuedJobs: 0, uptime: 1)
        #expect(ippValidateAttributes(response.pointer) != 0)
        #expect(response.text("media-default") == tape.mediaName)
        #expect(response.text("media-ready") == tape.mediaName)
        let supported = try #require(ippFindAttribute(response.pointer, "media-supported", IPP_TAG_KEYWORD))
        #expect(ippGetCount(supported) == testPrinter.profile.tapes.count)
        for name in ["media-col-default", "media-col-ready"] {
            let attribute = try #require(ippFindAttribute(response.pointer, name, IPP_TAG_BEGIN_COLLECTION))
            #expect(ippGetCount(attribute) == 1)
        }
        let sizes = try #require(ippFindAttribute(response.pointer, "media-size-supported", IPP_TAG_BEGIN_COLLECTION))
        #expect(ippGetCount(sizes) == testPrinter.profile.tapes.count)
        let ready = try #require(ippFindAttribute(response.pointer, "media-col-ready", IPP_TAG_BEGIN_COLLECTION))
        let media = try #require(ippGetCollection(ready, 0))
        let sizeAttribute = try #require(ippFindAttribute(media, "media-size", IPP_TAG_BEGIN_COLLECTION))
        let size = try #require(ippGetCollection(sizeAttribute, 0))
        let width = try #require(ippFindAttribute(size, "y-dimension", IPP_TAG_INTEGER))
        #expect(ippGetInteger(width, 0) == Int32(tape.widthMM * 100))
    }

    @Test func rejectsUnsupportedFormat() throws {
        let request = try request(operation: 4)
        request.string("document-format", "text/plain")
        let response = PrintServer(device: testPrinter, synchronizeQueue: { _, _, _, _ in }).handle(request)
        #expect(status(response) == 0x040A)
    }

    @Test func rejectsInvalidCopies() throws {
        let request = try request(operation: 2)
        request.integer("copies", 0)
        let response = PrintServer(device: testPrinter, synchronizeQueue: { _, _, _, _ in }).handle(request)
        #expect(status(response) == 0x040B)
    }

    @Test func stopsInvalidDocumentWithVisibleErrorUntilCancelled() throws {
        let server = PrintServer(device: testPrinter, synchronizeQueue: { _, _, _, _ in })
        let request = try request(operation: 2)
        request.document = try withPDF(width: 210, height: 297) { try Data(contentsOf: $0) }
        let response = server.handle(request)
        #expect(status(response) == 0)
        #expect(response.number("job-state") == 6)
        #expect(response.text("job-state-reasons") == "printer-stopped")
        let error = try #require(response.text("job-state-message"))
        #expect(error.contains("supported tape width"))
        let printer = try server.handle(self.request(operation: 11))
        #expect(printer.number("printer-state") == 5)
        #expect(printer.text("printer-state-message")?.contains(error) == true)
        #expect(printer.text("printer-state-reasons") == "offline-error")

        let cancel = try self.request(operation: 8)
        try cancel.integer("job-id", #require(response.number("job-id")))
        #expect(status(server.handle(cancel)) == 0)
        let recovered = try server.handle(self.request(operation: 11))
        #expect(recovered.number("printer-state") == 5)
        #expect(recovered.text("printer-state-message") == "Waiting for printer connection.")
        #expect(recovered.text("printer-state-reasons") == "offline-error")
    }

    @Test func cancelsJobWaitingForDocument() throws {
        let server = PrintServer(device: testPrinter, synchronizeQueue: { _, _, _, _ in })
        let created = try server.handle(request(operation: 5))
        let id = try #require(created.number("job-id"))
        let cancel = try request(operation: 8)
        cancel.integer("job-id", id)
        #expect(status(server.handle(cancel)) == 0)
        let query = try request(operation: 9)
        query.integer("job-id", id)
        #expect(server.handle(query).number("job-state") == 7)
    }

    @Test func pollsWithoutReportingPrintingAndReconnectsAutomatically() async throws {
        let connection = TestConnection()
        let printer = BluetoothPrinter(device: testPrinter, connection: connection)
        var configured: [Tape] = []
        let server = PrintServer(device: testPrinter, printer: printer) {
            _, tape, _, configure in if configure, let tape {
                configured.append(tape)
            }
        }
        defer { server.stop() }
        server.startMonitoring(interval: .milliseconds(10))
        try await eventually { printer.state == .ready(testTape) }
        let ready = try server.handle(request(operation: 11))
        #expect(ready.number("printer-state") == 3)
        #expect(ready.number("queued-job-count") == 0)
        connection.drop()
        let offline = try server.handle(request(operation: 11))
        #expect(offline.number("printer-state") == 5)
        #expect(offline.text("printer-state-reasons") == "offline-error")
        #expect(offline.text("media-ready") == nil)
        #expect(offline.text("media-default") == testTape.mediaName)
        try await eventually { connection.opens == 2 && printer.state == .ready(testTape) }
        #expect(configured == [testTape])
        connection.tapeWidth = 12
        try await eventually { configured.count == 2 }
        #expect(configured.last?.widthMM == 12)
        let changed = try server.handle(request(operation: 11))
        #expect(changed.text("media-default") == "custom_100x12mm_100x12mm")
        #expect(connection.prints.isEmpty)
    }

    @Test func interruptedJobStaysStoppedAfterRecoveryUntilCancelled() async throws {
        let connection = TestConnection()
        let printer = BluetoothPrinter(device: testPrinter, connection: connection)
        let server = PrintServer(device: testPrinter, printer: printer, synchronizeQueue: { _, _, _, _ in })
        defer { server.stop() }
        await server.refresh()
        connection.onWrite = { bytes in
            if bytes != statusRequest {
                connection.drop()
            }
        }
        let submitted = try request(operation: 2)
        submitted.document = try withPDF(width: 60, height: 24) { try Data(contentsOf: $0) }
        let firstID = try #require(server.handle(submitted).number("job-id"))
        let query = try request(operation: 9)
        query.integer("job-id", firstID)
        try await eventually { server.handle(query).number("job-state") == 6 }
        #expect(connection.prints.count == 1)
        let secondID = try #require(server.handle(submitted).number("job-id"))
        connection.onWrite = { _ in }
        await server.refresh()
        #expect(printer.state == .ready(testTape))
        #expect(server.handle(query).number("job-state") == 6)
        #expect(connection.prints.count == 1)
        let stopped = try server.handle(request(operation: 11))
        #expect(stopped.number("printer-state") == 5)
        #expect(stopped.number("queued-job-count") == 2)

        connection.onWrite = { bytes in
            if bytes != statusRequest {
                connection.emit(statusPacket(kind: 1))
            }
        }
        let cancel = try request(operation: 8)
        cancel.integer("job-id", firstID)
        _ = server.handle(cancel)
        let secondQuery = try request(operation: 9)
        secondQuery.integer("job-id", secondID)
        try await eventually { server.handle(secondQuery).number("job-state") == 9 }
        #expect(connection.prints.count == 2)
        #expect(server.handle(query).number("job-state") == 7)
    }

    @Test func queuesOfflineJobAndWaitsForPrinterAcknowledgement() async throws {
        let connection = TestConnection()
        let printer = BluetoothPrinter(device: testPrinter, connection: connection)
        let server = PrintServer(device: testPrinter, printer: printer, synchronizeQueue: { _, _, _, _ in })
        defer { server.stop() }
        let submitted = try request(operation: 2)
        submitted.document = try withPDF(width: 60, height: 24) { try Data(contentsOf: $0) }
        let job = server.handle(submitted)
        #expect(job.number("job-state") == 3)
        #expect(connection.writes.isEmpty)
        let query = try request(operation: 9)
        try query.integer("job-id", #require(job.number("job-id")))
        await server.refresh()
        try await eventually { connection.prints.count == 1 }
        #expect(server.handle(query).number("job-state") == 5)
        let writes = connection.writes.count
        await server.refresh()
        #expect(connection.writes.count == writes)
        connection.emit(statusPacket(kind: 5))
        #expect(server.handle(query).number("job-state") == 5)
        connection.emit(statusPacket(kind: 1))
        try await eventually { server.handle(query).number("job-state") == 9 }
        #expect(server.handle(query).number("job-impressions-completed") == 1)
    }

    @Test func publishesOfflineStatusBeforeFirstCassetteRead() async throws {
        let connection = TestConnection()
        connection.openError = LabelError("Printer is off")
        let printer = BluetoothPrinter(device: testPrinter, connection: connection)
        var published: [QueueStatus] = []
        let server = PrintServer(device: testPrinter, printer: printer) { _, tape, status, configure in
            #expect(tape == nil)
            #expect(!configure)
            published.append(status)
        }
        defer { server.stop() }
        await server.refresh()
        try await eventually { published.last?.printer.reason == "offline-error" }
        #expect(published.last?.message == "Printer is off")
    }

    @Test func publishesLatestStatusAfterSlowQueueSetup() async throws {
        let connection = TestConnection()
        let printer = BluetoothPrinter(device: testPrinter, connection: connection)
        var finishSetup: CheckedContinuation<Void, Never>?
        var published: [QueueStatus] = []
        let server = PrintServer(device: testPrinter, printer: printer) { _, _, status, configure in
            if configure {
                await withCheckedContinuation { finishSetup = $0 }
            }
            published.append(status)
        }
        defer { server.stop() }
        await server.refresh()
        try await eventually { finishSetup != nil }
        connection.drop()
        finishSetup?.resume()
        try await eventually { published.last?.printer.reason == "offline-error" }
        #expect(published.last?.message == "Bluetooth disconnected.")
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
