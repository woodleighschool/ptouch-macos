import CCUPS
import Foundation
import Network
import OSLog

@MainActor
final class BridgeService {
    private var listener: NWListener?
    private var discovery: Task<Void, Never>?
    private var printers: [String: PrintServer] = [:]

    func start() throws {
        guard listener == nil else { return }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: 8632)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(connection) }
        }
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready:
                    Logger.bridge.info("IPP service ready")
                    self?.discoverPrinters()
                case let .failed(error):
                    Logger.bridge.error("IPP listener failed: \(error.localizedDescription, privacy: .public)")
                    exit(1)
                default: break
                }
            }
        }
        self.listener = listener
        listener.start(queue: .main)
    }

    private func discoverPrinters() {
        guard discovery == nil else { return }
        discovery = Task {
            while !Task.isCancelled {
                for descriptor in await BluetoothDiscovery.pairedPrinters() {
                    if printers[descriptor.id] == nil {
                        printers[descriptor.id] = PrintServer(device: descriptor)
                    }
                    do { try await PrinterQueue.ensure(descriptor) }
                    catch { Logger.bridge.error("Queue setup: \(error.localizedDescription, privacy: .public)") }
                }
                do { try await Task.sleep(for: .seconds(30)) }
                catch { return }
            }
        }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .main)
        Task {
            defer { connection.cancel() }
            do {
                let http = HTTPConnection(connection)
                let (path, data) = try await http.request()
                let request = try IPPMessage(data: data)
                let id = path.split(separator: "/").dropFirst(2).first.map(String.init) ?? ""
                let response: IPPMessage
                if let printer = printers[id] {
                    response = printer.handle(request)
                } else {
                    response = IPPMessage(responseTo: request)
                    response.error(IPP_STATUS_ERROR_NOT_FOUND, "Printer not found. Check Bluetooth pairing and model support.")
                }
                try await http.respond(response.data())
            } catch HTTPError.closed {
                // CUPS opens empty connections to check reachability.
            } catch {
                Logger.bridge.error("IPP request: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
