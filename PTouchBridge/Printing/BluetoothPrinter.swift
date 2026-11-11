import Foundation
import IOBluetooth

@MainActor
final class BluetoothPrinter: NSObject, @preconcurrency IOBluetoothRFCOMMChannelDelegate {
    let device: PrinterDescriptor

    init(device: PrinterDescriptor) {
        self.device = device
    }

    var onProgress: (String) -> Void = { print($0) }
    private var channel: IOBluetoothRFCOMMChannel?
    private var received = Data()
    private var continuation: CheckedContinuation<Tape, Error>?
    private var timeout: Task<Void, Never>?
    private var labels: [Label] = []
    private var printing = false
    private var tape: Tape?

    func perform(labels: [Label] = []) async throws -> Tape {
        guard continuation == nil else { throw LabelError("The printer is busy.") }
        self.labels = labels
        printing = false
        received.removeAll()
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            timeout = Task {
                do { try await Task.sleep(for: .seconds(60 + labels.count * 15)) } catch { return }
                fail("The printer did not respond. Check its power and Bluetooth connection before retrying.")
                channel?.close()
                channel = nil
            }
            if let channel, channel.isOpen() {
                requestStatus(channel)
                return
            }
            guard let device = IOBluetoothDevice(addressString: self.device.address), device.isPaired(),
                  let service = device.getServiceRecord(for: IOBluetoothSDPUUID(uuid16: 0x1101))
            else {
                return fail("The printer is no longer paired. Check macOS Bluetooth settings.")
            }
            // The macOS 27.3 IOBluetooth shim does not deliver the SDP completion callback.
            // The paired Serial Port record supplies the advertised channel without that query.
            var channelID: BluetoothRFCOMMChannelID = 0
            guard service.getRFCOMMChannelID(&channelID) == kIOReturnSuccess else {
                return fail("The printer does not advertise a Bluetooth serial channel.")
            }
            onProgress("Connecting to \(device.name ?? "printer")")
            let result = device.openRFCOMMChannelAsync(&channel, withChannelID: channelID, delegate: self)
            if result != kIOReturnSuccess {
                fail("Bluetooth connection failed (\(result)).")
            }
        }
    }

    func rfcommChannelOpenComplete(_ channel: IOBluetoothRFCOMMChannel!, status: IOReturn) {
        guard continuation != nil else { channel?.close(); return }
        guard status == kIOReturnSuccess else { return fail("Bluetooth connection failed (\(status)).") }
        requestStatus(channel)
    }

    private func requestStatus(_ channel: IOBluetoothRFCOMMChannel) {
        onProgress("Checking printer")
        send([0x1B, 0x69, 0x53], channel: channel)
    }

    private func send(_ bytes: [UInt8], channel: IOBluetoothRFCOMMChannel) {
        var bytes = bytes
        let mtu = Int(channel.getMTU())
        guard mtu > 0 else { return fail("Bluetooth channel has no transmit capacity.") }
        let result: IOReturn = bytes.withUnsafeMutableBytes { buffer in
            for offset in stride(from: 0, to: buffer.count, by: mtu) {
                let result = channel.writeSync(buffer.baseAddress!.advanced(by: offset), length: UInt16(min(mtu, buffer.count - offset)))
                if result != kIOReturnSuccess {
                    return result
                }
            }
            return kIOReturnSuccess
        }
        if result != kIOReturnSuccess {
            fail("Bluetooth write failed (\(result)). Check the printer before retrying.")
        }
    }

    func rfcommChannelData(_ channel: IOBluetoothRFCOMMChannel!, data pointer: UnsafeMutableRawPointer!, length: Int) {
        guard continuation != nil, let pointer else { return }
        received.append(pointer.assumingMemoryBound(to: UInt8.self), count: length)
        while received.count >= 32, continuation != nil {
            let status = Array(received.prefix(32))
            received.removeFirst(32)
            guard status[0] == 0x80, status[1] == 0x20, status[2] == 0x42 else {
                return fail("The printer returned an unexpected status packet.")
            }
            guard status[8] == 0, status[9] == 0 else {
                return fail("Printer error \(status[8])/\(status[9]). Check tape, cover and battery.")
            }
            guard let tape = device.profile.tapes.first(where: { $0.statusCode == status[10] }),
                  [1, 3].contains(status[11])
            else {
                return fail("The loaded cassette is not supported by this printer profile.")
            }
            self.tape = tape
            if printing {
                if status[18] == 1 {
                    printNext(channel)
                }
            } else if !labels.isEmpty {
                do { try Label.validate(labels, loadedTape: tape) }
                catch { return fail(error.localizedDescription) }
                printing = true
                printNext(channel)
            } else {
                complete()
            }
        }
    }

    private func printNext(_ channel: IOBluetoothRFCOMMChannel) {
        guard !labels.isEmpty else { return complete() }
        onProgress("Printing over Bluetooth")
        let label = labels.removeFirst()
        send(label.commands(), channel: channel)
    }

    func rfcommChannelClosed(_: IOBluetoothRFCOMMChannel!) {
        channel = nil
        if continuation != nil {
            fail("Bluetooth disconnected. Check the printed labels before retrying.")
        }
    }

    private func complete() {
        timeout?.cancel()
        timeout = nil
        let pending = continuation
        continuation = nil
        onProgress(printing ? "Print completed" : "Printer ready")
        if let tape {
            pending?.resume(returning: tape)
        } else {
            pending?.resume(throwing: LabelError("The printer did not report a cassette."))
        }
    }

    private func fail(_ message: String) {
        timeout?.cancel()
        timeout = nil
        labels.removeAll()
        let pending = continuation
        continuation = nil
        onProgress(message)
        pending?.resume(throwing: LabelError(message))
    }
}
