import Foundation
@testable import PTouchBridge
import Testing

@MainActor
struct BluetoothPrinterTests {
    @Test func reconnectsAfterIdleDisconnectAndClearsLoadedMedia() async throws {
        let connection = TestConnection()
        let printer = BluetoothPrinter(device: testPrinter, connection: connection)
        try await printer.perform()
        #expect(printer.state == .ready(testTape))
        connection.drop()
        #expect(printer.state.reason == "offline-report")
        #expect(printer.state.tape == nil)
        #expect(printer.knownTape == testTape)
        connection.openError = LabelError("Out of range")
        await #expect(throws: LabelError.self) { try await printer.perform() }
        connection.openError = nil
        try await printer.perform()
        #expect(printer.state == .ready(testTape))
        #expect(connection.opens == 3)
        #expect(connection.prints.isEmpty)
    }

    @Test func timeoutDiscardsConnectionAndCanReconnect() async throws {
        let connection = TestConnection()
        connection.replyToStatus = false
        let printer = BluetoothPrinter(device: testPrinter, connection: connection, responseTimeout: .milliseconds(20))
        await #expect(throws: LabelError.self) { try await printer.perform() }
        #expect(!connection.connected)
        #expect(printer.state.reason == "offline-report")
        connection.replyToStatus = true
        try await printer.perform()
        #expect(connection.opens == 2)
        #expect(printer.state == .ready(testTape))
    }

    @Test(arguments: [false, true])
    func cancellationReleasesPendingCallback(stallOpen: Bool) async throws {
        let connection = TestConnection()
        connection.stallOpen = stallOpen
        connection.replyToStatus = false
        let printer = BluetoothPrinter(device: testPrinter, connection: connection)
        let operation = Task { try await printer.perform() }
        try await eventually { stallOpen ? connection.opens == 1 : connection.writes.count == 1 }
        operation.cancel()
        await #expect(throws: (any Error).self) { try await operation.value }
        #expect(!connection.connected)
        connection.stallOpen = false
        connection.replyToStatus = true
        try await printer.perform()
        await Task.yield()
        #expect(printer.state == .ready(testTape))
    }

    @Test func ignoresNotificationsUntilRequestedStatusAndPrintCompletion() async throws {
        let connection = TestConnection()
        connection.replyToStatus = false
        let printer = BluetoothPrinter(device: testPrinter, connection: connection)
        let label = try makeLabel()
        let operation = Task { try await printer.perform(labels: [label, label]) }
        try await eventually { connection.writes.count == 1 }
        connection.emit(statusPacket(kind: 1) + statusPacket(kind: 5))
        await Task.yield()
        #expect(connection.prints.isEmpty)
        let reply = statusPacket()
        connection.emit(reply.prefix(5))
        connection.emit(reply.dropFirst(5))
        try await eventually { connection.prints.count == 1 }
        connection.emit(statusPacket(kind: 0) + statusPacket(kind: 5))
        await Task.yield()
        #expect(connection.prints.count == 1)
        connection.emit(statusPacket(kind: 1) + statusPacket(kind: 1))
        try await eventually { connection.prints.count == 2 }
        #expect(printer.state == .printing(testTape))
        connection.emit(statusPacket(kind: 1))
        try await operation.value
        #expect(printer.state == .ready(testTape))
    }

    @Test func validatesWholeBatchBeforeSendingRaster() async throws {
        let connection = TestConnection()
        let printer = BluetoothPrinter(device: testPrinter, connection: connection)
        let first = try makeLabel()
        let second = try makeLabel(width: 12)
        await #expect(throws: LabelError.self) { try await printer.perform(labels: [first, second]) }
        #expect(connection.prints.isEmpty)
        #expect(printer.state == .ready(testTape))
    }

    @Test func disconnectDuringBatchNeverReplaysRemainingPages() async throws {
        let connection = TestConnection()
        connection.onWrite = { bytes in
            guard bytes != statusRequest else { return }
            if connection.prints.count == 1 {
                connection.emit(statusPacket(kind: 1))
            } else {
                connection.drop()
            }
        }
        let printer = BluetoothPrinter(device: testPrinter, connection: connection)
        let label = try makeLabel()
        await #expect(throws: LabelError.self) { try await printer.perform(labels: [label, label, label]) }
        #expect(connection.prints.count == 2)
        connection.onWrite = { _ in }
        try await printer.perform()
        try await printer.perform()
        #expect(connection.prints.count == 2)
        #expect(printer.state == .ready(testTape))
    }

    @Test func idleErrorsAreVisibleAndRecoverThroughStatusCheck() async throws {
        let connection = TestConnection()
        let printer = BluetoothPrinter(device: testPrinter, connection: connection)
        try await printer.perform()
        connection.emit(statusPacket(kind: 2, error2: 0x10))
        #expect(printer.state.reason == "cover-open-error")
        #expect(!connection.connected)
        try await printer.perform()
        #expect(printer.state == .ready(testTape))
        connection.emit(statusPacket(kind: 4))
        #expect(printer.state.reason == "offline-report")
    }

    @Test(arguments: [(UInt8(0x01), true), (0x03, true), (0x14, true), (0x11, false), (0x17, false), (0xFF, false)])
    func acceptsOnlyTZeCassettes(media: UInt8, supported: Bool) throws {
        let status = try PrinterStatus([UInt8](statusPacket(media: media)), profile: testPrinter.profile)
        #expect(status.tape == (supported ? testTape : nil))
        #expect(status.issue?.reason == (supported ? nil : "media-needed-error"))
    }

    @Test func malformedStatusClosesConnection() async throws {
        let connection = TestConnection()
        connection.replyToStatus = false
        connection.onWrite = { _ in connection.emit(Data(repeating: 0, count: 32)) }
        let printer = BluetoothPrinter(device: testPrinter, connection: connection)
        await #expect(throws: LabelError.self) { try await printer.perform() }
        #expect(!connection.connected)
        #expect(printer.state.reason == "offline-report")
    }
}

@MainActor
final class TestConnection: PrinterConnection {
    var onData: (Data) -> Void = { _ in }
    var onClose: (String) -> Void = { _ in }
    var onWrite: ([UInt8]) throws -> Void = { _ in }
    var replyToStatus = true
    var tapeWidth: UInt8 = 24
    var openError: (any Error)?
    var stallOpen = false
    var connected = false
    var opens = 0
    var writes: [[UInt8]] = []
    private var opening: CheckedContinuation<Void, Error>?

    var prints: [[UInt8]] {
        writes.filter { $0 != statusRequest }
    }

    func open() async throws {
        if connected {
            return
        }
        opens += 1
        if let openError {
            throw openError
        }
        if stallOpen {
            try await withCheckedThrowingContinuation { opening = $0 }
        }
        connected = true
    }

    func write(_ bytes: [UInt8]) async throws {
        guard connected else { throw LabelError("Disconnected") }
        writes.append(bytes)
        if bytes == statusRequest, replyToStatus {
            emit(statusPacket(width: tapeWidth))
        }
        try onWrite(bytes)
    }

    func close() {
        connected = false
        let pending = opening
        opening = nil
        pending?.resume(throwing: LabelError("Closed"))
    }

    func drop() {
        close()
        onClose("Bluetooth disconnected.")
    }

    func emit(_ bytes: Data) {
        onData(bytes)
    }
}

let statusRequest: [UInt8] = [0x1B, 0x69, 0x53]
let testTape = PrinterProfile.profiles[0].tapes.last!

func statusPacket(kind: UInt8 = 0, width: UInt8 = 24, media: UInt8 = 0x01, error1: UInt8 = 0, error2: UInt8 = 0) -> Data {
    var bytes = [UInt8](repeating: 0, count: 32)
    bytes[0] = 0x80
    bytes[1] = 0x20
    bytes[2] = 0x42
    bytes[8] = error1
    bytes[9] = error2
    bytes[10] = width
    bytes[11] = media
    bytes[18] = kind
    return Data(bytes)
}

@MainActor
func makeLabel(width: Double = 24) throws -> Label {
    try withPDF(width: 60, height: width) { try render($0.path, profile: testPrinter.profile)[0] }
}

@MainActor
func eventually(_ condition: () throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(2)
    while try !condition(), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(1))
    }
    try #require(try condition())
}
