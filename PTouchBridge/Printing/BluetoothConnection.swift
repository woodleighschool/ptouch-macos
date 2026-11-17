import Foundation
import IOBluetooth

@MainActor
protocol PrinterConnection: AnyObject {
    var onData: (Data) -> Void { get set }
    var onClose: (String) -> Void { get set }
    func open() async throws
    func write(_ bytes: [UInt8]) async throws
    func close()
}

/// IOBluetooth delivers these delegates on the run loop that opens the channel.
@MainActor
final class BluetoothConnection: NSObject, PrinterConnection, @preconcurrency IOBluetoothRFCOMMChannelDelegate {
    private let address: String
    private var channel: IOBluetoothRFCOMMChannel?
    private var opening: CheckedContinuation<Void, Error>?
    private var writing: CheckedContinuation<Void, Error>?
    var onData: (Data) -> Void = { _ in }
    var onClose: (String) -> Void = { _ in }

    init(address: String) {
        self.address = address
    }

    func open() async throws {
        try Task.checkCancellation()
        if let channel, channel.isOpen() {
            return
        }
        close()
        guard let device = IOBluetoothDevice(addressString: address), device.isPaired(),
              let service = device.getServiceRecord(for: IOBluetoothSDPUUID(uuid16: 0x1101))
        else {
            throw LabelError("Pair the printer in macOS Bluetooth settings.")
        }
        // The paired Serial Port record avoids an SDP query whose callback is missing in the macOS shim.
        var channelID: BluetoothRFCOMMChannelID = 0
        guard service.getRFCOMMChannelID(&channelID) == kIOReturnSuccess else {
            throw LabelError("The printer does not advertise a Bluetooth serial channel.")
        }
        try await withCheckedThrowingContinuation { continuation in
            opening = continuation
            let result = device.openRFCOMMChannelAsync(&channel, withChannelID: channelID, delegate: self)
            if result != kIOReturnSuccess {
                disconnect("Bluetooth connection failed (\(result)).")
            }
        }
    }

    func write(_ bytes: [UInt8]) async throws {
        guard let channel, channel.isOpen() else { throw LabelError("Bluetooth disconnected.") }
        let mtu = Int(channel.getMTU())
        guard mtu > 0 else { throw LabelError("Bluetooth channel has no transmit capacity.") }
        for offset in stride(from: 0, to: bytes.count, by: mtu) {
            try Task.checkCancellation()
            guard channel === self.channel else { throw LabelError("Bluetooth disconnected.") }
            let buffer = NSData(data: Data(bytes[offset ..< min(offset + mtu, bytes.count)]))
            defer { withExtendedLifetime(buffer) {} }
            try await withCheckedThrowingContinuation { continuation in
                writing = continuation
                let result = channel.writeAsync(UnsafeMutableRawPointer(mutating: buffer.bytes), length: UInt16(buffer.length), refcon: nil)
                if result != kIOReturnSuccess {
                    disconnect("Bluetooth write failed (\(result)).")
                }
            }
        }
    }

    func close() {
        let previous = channel
        channel = nil
        previous?.setDelegate(nil)
        previous?.close()
        let open = opening
        let write = writing
        opening = nil
        writing = nil
        open?.resume(throwing: LabelError("Bluetooth connection closed."))
        write?.resume(throwing: LabelError("Bluetooth connection closed."))
    }

    private func disconnect(_ message: String) {
        close()
        onClose(message)
    }

    func rfcommChannelOpenComplete(_ channel: IOBluetoothRFCOMMChannel!, status: IOReturn) {
        guard let channel, channel === self.channel else { return }
        guard status == kIOReturnSuccess else {
            return disconnect("Bluetooth connection failed (\(status)).")
        }
        let pending = opening
        opening = nil
        pending?.resume()
    }

    func rfcommChannelWriteComplete(_ channel: IOBluetoothRFCOMMChannel!, refcon _: UnsafeMutableRawPointer!, status: IOReturn) {
        guard let channel, channel === self.channel else { return }
        guard status == kIOReturnSuccess else {
            return disconnect("Bluetooth write failed (\(status)).")
        }
        let pending = writing
        writing = nil
        pending?.resume()
    }

    func rfcommChannelData(_ channel: IOBluetoothRFCOMMChannel!, data pointer: UnsafeMutableRawPointer!, length: Int) {
        guard let channel, channel === self.channel, let pointer else { return }
        onData(Data(bytes: pointer, count: length))
    }

    func rfcommChannelClosed(_ channel: IOBluetoothRFCOMMChannel!) {
        guard let channel, channel === self.channel else { return }
        disconnect("Bluetooth disconnected. Turn on the printer and keep it nearby.")
    }
}
