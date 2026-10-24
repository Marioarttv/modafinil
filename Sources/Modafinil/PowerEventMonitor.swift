import Foundation
import IOKit
import IOKit.pwr_mgt

private func iokitCommonMessage(_ message: UInt32) -> natural_t {
    natural_t(((0x38 & 0x3f) << 26) | message)
}

/// Receives every system wake, including dark (background) wakes, which
/// NSWorkspace does not report. Sleep requests are acknowledged immediately
/// on a private queue, so this never delays sleep.
final class PowerEventMonitor {
    var onDidWake: (() -> Void)?

    private static let canSystemSleep = iokitCommonMessage(0x270)
    private static let systemWillSleep = iokitCommonMessage(0x280)
    private static let systemHasPoweredOn = iokitCommonMessage(0x300)

    private let queue = DispatchQueue(label: "com.narcotic.modafinil.power-events")
    private var rootPort: io_connect_t = 0
    private var notificationPort: IONotificationPortRef?
    private var notifier: io_object_t = 0

    deinit { stop() }

    func start() throws {
        guard rootPort == 0 else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        var port: IONotificationPortRef?
        let connection = IORegisterForSystemPower(refcon, &port, { refcon, _, messageType, argument in
            guard let refcon else { return }
            Unmanaged<PowerEventMonitor>.fromOpaque(refcon).takeUnretainedValue()
                .handle(messageType: messageType, argument: argument)
        }, &notifier)
        guard connection != 0, let port else {
            throw MonitorError("Could not subscribe to system sleep and wake notifications.")
        }
        rootPort = connection
        notificationPort = port
        IONotificationPortSetDispatchQueue(port, queue)
    }

    func stop() {
        if notifier != 0 {
            IODeregisterForSystemPower(&notifier)
            notifier = 0
        }
        if rootPort != 0 {
            IOServiceClose(rootPort)
            rootPort = 0
        }
        if let notificationPort {
            IONotificationPortDestroy(notificationPort)
            self.notificationPort = nil
        }
    }

    private func handle(messageType: natural_t, argument: UnsafeMutableRawPointer?) {
        switch messageType {
        case Self.canSystemSleep, Self.systemWillSleep:
            IOAllowPowerChange(rootPort, Int(bitPattern: argument))
        case Self.systemHasPoweredOn:
            DispatchQueue.main.async { [weak self] in self?.onDidWake?() }
        default:
            break
        }
    }

    struct MonitorError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
