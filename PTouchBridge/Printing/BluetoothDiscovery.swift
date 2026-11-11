import Foundation
import IOBluetooth

enum BluetoothDiscovery {
    @concurrent
    static func pairedPrinters() async -> [PrinterDescriptor] {
        // The macOS IOBluetooth shim synchronously waits for CoreBluetooth during first use.
        // Discover away from the main actor so its callbacks can finish that initialization.
        let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
        return devices.compactMap { device in
            guard let name = device.name, let address = device.addressString,
                  let profile = PrinterProfile.matching(name),
                  device.getServiceRecord(for: IOBluetoothSDPUUID(uuid16: 0x1101)) != nil else { return nil }
            return PrinterDescriptor(address: address, name: name, profile: profile)
        }
    }
}
