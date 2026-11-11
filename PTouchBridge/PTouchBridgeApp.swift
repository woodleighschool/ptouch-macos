import AppKit
import OSLog

@main
enum PTouchBridgeApp {
    static func main() {
        let application = NSApplication.shared
        let delegate = ServiceDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}

final class ServiceDelegate: NSObject, NSApplicationDelegate {
    private let service = BridgeService()

    func applicationDidFinishLaunching(_: Notification) {
        guard NSClassFromString("XCTestCase") == nil else { return }
        do { try service.start() }
        catch {
            Logger.bridge.error("Could not start: \(error.localizedDescription, privacy: .public)")
            exit(1)
        }
    }
}

extension Logger {
    static let bridge = Logger(subsystem: "au.edu.vic.woodleigh.PTouchBridge", category: "Service")
}
