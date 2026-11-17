import Foundation
import OSLog

@MainActor
final class BluetoothPrinter {
    private let address: String
    private let profile: PrinterProfile
    private let connection: any PrinterConnection
    private let responseTimeout: Duration
    private var operation: UUID?
    private var received = Data()
    private var expectedStatus: UInt8?
    private var responses: AsyncThrowingStream<PrinterStatus, Error>.Continuation?
    private var timeout: Task<Void, Never>?
    var onStateChange: () -> Void = {}
    private(set) var state: PrinterState = .offline("Waiting for printer connection.") {
        didSet {
            if state != oldValue {
                onStateChange()
                Logger.bridge.info("Printer \(self.address, privacy: .public): \(String(describing: self.state), privacy: .public)")
            }
        }
    }

    private(set) var knownTape: Tape?

    init(device: PrinterDescriptor, connection: (any PrinterConnection)? = nil, responseTimeout: Duration = .seconds(15)) {
        address = device.address
        profile = device.profile
        self.connection = connection ?? BluetoothConnection(address: device.address)
        self.responseTimeout = responseTimeout
        self.connection.onData = { [weak self] in self?.receive($0) }
        self.connection.onClose = { [weak self] in self?.disconnect($0) }
    }

    func perform(labels: [Label] = []) async throws {
        guard operation == nil else { throw LabelError("The printer is busy.") }
        try Task.checkCancellation()
        let id = UUID()
        operation = id
        let (stream, continuation) = AsyncThrowingStream<PrinterStatus, Error>.makeStream()
        responses = continuation
        defer {
            if Task.isCancelled {
                disconnect("Printer operation cancelled.")
            }
            timeout?.cancel()
            timeout = nil
            expectedStatus = nil
            responses?.finish()
            responses = nil
            operation = nil
        }
        try await withTaskCancellationHandler {
            var replies = stream.makeAsyncIterator()
            if state.tape == nil {
                state = .connecting
            }
            armTimeout(responseTimeout, operation: id)
            do {
                try await connection.open()
                expectedStatus = 0
                try await connection.write([0x1B, 0x69, 0x53])
            } catch {
                throw connectionFailed(error)
            }
            guard let status = try await replies.next(), let tape = status.tape else {
                throw LabelError("The printer did not report a cassette.")
            }
            guard !status.printing else { throw LabelError("The printer is already printing.") }
            // Validate every page before the first command that can move tape.
            try Label.validate(labels, loadedTape: tape)
            for (index, label) in labels.enumerated() {
                try Task.checkCancellation()
                state = .printing(tape)
                expectedStatus = 1
                armTimeout(.seconds(60), operation: id)
                do {
                    try await connection.write(label.commands(first: index == 0, last: index == labels.count - 1))
                    guard try await replies.next() != nil else { throw LabelError("Printing was interrupted.") }
                } catch {
                    let failure = connectionFailed(error)
                    throw LabelError("\(failure.localizedDescription) Check the printed labels, cancel this job and print again.")
                }
            }
            state = .ready(tape)
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, operation == id else { return }
                disconnect("Printer operation cancelled.")
            }
        }
    }

    private func connectionFailed(_ error: any Error) -> any Error {
        switch state {
        case let .stopped(issue): return issue
        case let .offline(message): return LabelError(message)
        default:
            disconnect(error.localizedDescription)
            return error
        }
    }

    func disconnect(_ message: String) {
        state = .offline(message)
        endConnection(throwing: LabelError(message))
    }

    private func endConnection(throwing error: any Error) {
        expectedStatus = nil
        received.removeAll()
        responses?.finish(throwing: error)
        connection.close()
    }

    private func armTimeout(_ duration: Duration, operation id: UUID) {
        timeout?.cancel()
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: duration) } catch { return }
            guard let self, operation == id else { return }
            disconnect("The printer did not respond. Check its power and Bluetooth connection.")
        }
    }

    private func receive(_ data: Data) {
        received.append(data)
        while received.count >= 32 {
            let bytes = Array(received.prefix(32))
            received.removeFirst(32)
            do {
                let status = try PrinterStatus(bytes, profile: profile)
                if status.kind == 4 {
                    return disconnect("The printer is turned off.")
                }
                if let issue = status.issue {
                    state = .stopped(issue)
                    return endConnection(throwing: issue)
                }
                if let tape = status.tape {
                    knownTape = tape
                    if operation == nil || expectedStatus == 0 {
                        state = status.printing ? .printing(tape) : .ready(tape)
                    }
                }
                if status.kind == expectedStatus {
                    expectedStatus = nil
                    responses?.yield(status)
                }
            } catch {
                return disconnect(error.localizedDescription)
            }
        }
    }
}
