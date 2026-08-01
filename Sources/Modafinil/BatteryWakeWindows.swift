import AppKit
import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt
import ModafinilRemoteProtocol
import Network

enum PowerSource {
    static func isRunningOnBattery() -> Bool {
        guard
            let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let providingType = IOPSGetProvidingPowerSourceType(snapshot)?
                .takeUnretainedValue()
        else {
            return false
        }
        return (providingType as String) == kIOPSBatteryPowerValue
    }
}

/// Delivers system wake notifications, including dark wakes, which
/// `NSWorkspace.didWakeNotification` does not reliably cover on battery.
final class SystemWakeMonitor {
    // The IOMessage.h macros do not import into Swift; these are the
    // expansions of iokit_common_msg(0x270/0x280/0x300).
    private static let messageCanSystemSleep: UInt32 = 0xE000_0270
    private static let messageSystemWillSleep: UInt32 = 0xE000_0280
    private static let messageSystemHasPoweredOn: UInt32 = 0xE000_0300

    var onWake: (() -> Void)?

    private var rootPort: io_connect_t = 0
    private var notifyPortRef: IONotificationPortRef?
    private var notifierObject: io_object_t = 0

    func start() {
        guard rootPort == 0 else { return }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        rootPort = IORegisterForSystemPower(
            refcon,
            &notifyPortRef,
            { refcon, _, messageType, messageArgument in
                guard let refcon else { return }
                let monitor = Unmanaged<SystemWakeMonitor>
                    .fromOpaque(refcon)
                    .takeUnretainedValue()
                monitor.handle(
                    messageType: messageType,
                    messageArgument: messageArgument
                )
            },
            &notifierObject
        )

        guard rootPort != 0, let notifyPortRef else {
            NSLog("Modafinil battery-wake: could not register for system power notifications")
            return
        }

        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            IONotificationPortGetRunLoopSource(notifyPortRef).takeUnretainedValue(),
            .defaultMode
        )
    }

    func stop() {
        guard rootPort != 0 else { return }

        if let notifyPortRef {
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                IONotificationPortGetRunLoopSource(notifyPortRef).takeUnretainedValue(),
                .defaultMode
            )
        }
        IODeregisterForSystemPower(&notifierObject)
        IOServiceClose(rootPort)
        if let notifyPortRef {
            IONotificationPortDestroy(notifyPortRef)
        }
        rootPort = 0
        notifyPortRef = nil
        notifierObject = 0
    }

    private func handle(
        messageType: UInt32,
        messageArgument: UnsafeMutableRawPointer?
    ) {
        switch messageType {
        case Self.messageCanSystemSleep, Self.messageSystemWillSleep:
            // Sleep must be acknowledged promptly or powerd delays it.
            IOAllowPowerChange(rootPort, Int(bitPattern: messageArgument))
        case Self.messageSystemHasPoweredOn:
            DispatchQueue.main.async { [weak self] in
                self?.onWake?()
            }
        default:
            break
        }
    }
}

/// Asks the XR relay whether an iPhone requested a wake since the Mac last
/// slept. The relay clears its pending flag when it answers.
enum RelayPendingWakeClient {
    static let pendingMessage = "A wake request is pending."
    static let nonePendingMessage = "No wake request is pending."

    static func collectPendingWake(
        host: String,
        port: UInt16,
        secret: Data,
        timeout: TimeInterval,
        completion: @escaping (Result<Bool, Error>) -> Void
    ) {
        guard !host.isEmpty, let endpointPort = NWEndpoint.Port(rawValue: port) else {
            completion(.failure(PollError("The relay is not configured.")))
            return
        }

        let request = RemoteRequest.signed(
            command: .collectPendingWake,
            secret: secret
        )
        let requestData: Data
        do {
            requestData = try RemoteWireCodec.encodeLine(request)
        } catch {
            completion(.failure(error))
            return
        }

        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: endpointPort,
            using: .tcp
        )
        let queue = DispatchQueue(label: "com.narcotic.modafinil.relay-poll")
        var didComplete = false
        let finish: (Result<Bool, Error>) -> Void = { result in
            queue.async {
                guard !didComplete else { return }
                didComplete = true
                connection.cancel()
                DispatchQueue.main.async {
                    completion(result)
                }
            }
        }

        queue.asyncAfter(deadline: .now() + timeout) {
            finish(.failure(PollError("The relay did not respond in time.")))
        }

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.send(
                    content: requestData,
                    completion: .contentProcessed { error in
                        if let error {
                            finish(.failure(error))
                        }
                    }
                )
                receiveResponse(
                    on: connection,
                    buffer: Data(),
                    requestID: request.requestID,
                    secret: secret,
                    finish: finish
                )
            case .failed(let error):
                finish(.failure(error))
            case .cancelled:
                finish(.failure(PollError("The relay connection was cancelled.")))
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private static func receiveResponse(
        on connection: NWConnection,
        buffer: Data,
        requestID: String,
        secret: Data,
        finish: @escaping (Result<Bool, Error>) -> Void
    ) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 4_096
        ) { data, _, isComplete, error in
            if let error {
                finish(.failure(error))
                return
            }

            var buffer = buffer
            if let data {
                buffer.append(data)
            }

            guard buffer.count <= RemoteWireCodec.maximumMessageSize else {
                finish(.failure(PollError("The relay response was too large.")))
                return
            }

            if buffer.firstIndex(of: 0x0a) != nil {
                finish(decodeResponse(buffer, requestID: requestID, secret: secret))
                return
            }

            guard !isComplete else {
                finish(.failure(PollError("The relay closed the connection early.")))
                return
            }

            receiveResponse(
                on: connection,
                buffer: buffer,
                requestID: requestID,
                secret: secret,
                finish: finish
            )
        }
    }

    private static func decodeResponse(
        _ data: Data,
        requestID: String,
        secret: Data
    ) -> Result<Bool, Error> {
        let response: RemoteResponse
        do {
            response = try RemoteWireCodec.decodeLine(RemoteResponse.self, from: data)
        } catch {
            return .failure(error)
        }

        guard response.requestID == requestID,
              response.isAuthentic(secret: secret)
        else {
            return .failure(PollError("The relay response failed authentication."))
        }
        guard response.ok else {
            return .failure(PollError(response.message))
        }

        return .success(response.message == pendingMessage)
    }

    struct PollError: LocalizedError {
        let message: String

        init(_ message: String) {
            self.message = message
        }

        var errorDescription: String? { message }
    }
}

protocol BatteryWakeWindowControllerDelegate: AnyObject {
    /// Keep the Mac awake (disablesleep lease) while a window is evaluated.
    func batteryWakeWindowControllerBeginAwakeHold(_ controller: BatteryWakeWindowController)

    /// The window found no pending wake; the Mac may sleep again.
    func batteryWakeWindowControllerEndAwakeHold(_ controller: BatteryWakeWindowController)

    /// A pending iPhone wake request was collected; hold the Mac awake so the
    /// companion can reconnect and issue keep-awake.
    func batteryWakeWindowControllerDidCollectPendingWake(_ controller: BatteryWakeWindowController)

    func batteryWakeWindowController(
        _ controller: BatteryWakeWindowController,
        scheduleWakeAt date: Date,
        completion: @escaping (Result<Void, Error>) -> Void
    )

    func batteryWakeWindowController(
        _ controller: BatteryWakeWindowController,
        cancelScheduledWakeAt date: Date,
        completion: @escaping (Result<Void, Error>) -> Void
    )
}

/// Implements periodic RTC wake windows so a sleeping Mac on battery, where
/// Wake-on-LAN is unavailable, can still collect queued wake requests.
final class BatteryWakeWindowController {
    static let windowInterval: TimeInterval = 20 * 60
    static let windowTolerance: TimeInterval = 180
    static let maximumWindows = 72
    private static let relayPollDeadline: TimeInterval = 60
    private static let relayAttemptTimeout: TimeInterval = 6
    private static let relayRetryDelay: TimeInterval = 5

    weak var delegate: BatteryWakeWindowControllerDelegate?

    private let configurationStore: CompanionConfigurationStore
    private let wakeMonitor = SystemWakeMonitor()
    private var assertionID = IOPMAssertionID(0)
    private var isEvaluatingWindow = false

    init(configurationStore: CompanionConfigurationStore) {
        self.configurationStore = configurationStore
    }

    func start() {
        wakeMonitor.onWake = { [weak self] in
            self?.handleWake()
        }
        wakeMonitor.start()

        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(screenWasUnlocked),
            name: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil
        )

        // Stale window state from before a restart means the user is present.
        if configurationStore.areBatteryWakeWindowsArmed {
            disarm(reason: "the app relaunched")
        }
    }

    func stop() {
        DistributedNotificationCenter.default().removeObserver(self)
        wakeMonitor.stop()
        releaseAssertion()
    }

    /// Arms wake windows before a remote sleep on battery power.
    func arm() {
        configurationStore.areBatteryWakeWindowsArmed = true
        configurationStore.batteryWakeWindowsRemaining = Self.maximumWindows
        NSLog("Modafinil battery-wake: arming wake windows every \(Int(Self.windowInterval / 60)) minutes")

        // Drain a stale pending flag so an old request cannot trigger the
        // first window. The result is intentionally ignored.
        collectFromRelay(timeout: 1.5) { result in
            if case .success(let wasPending) = result, wasPending {
                NSLog("Modafinil battery-wake: drained a stale pending wake flag before sleep")
            }
        }

        scheduleNextWindow()
    }

    func disarm(reason: String) {
        guard configurationStore.areBatteryWakeWindowsArmed ||
                configurationStore.batteryWakeNextWindowDate != nil
        else {
            return
        }

        NSLog("Modafinil battery-wake: disarming wake windows because \(reason)")
        configurationStore.areBatteryWakeWindowsArmed = false
        configurationStore.batteryWakeWindowsRemaining = 0

        if let scheduled = configurationStore.batteryWakeNextWindowDate {
            configurationStore.batteryWakeNextWindowDate = nil
            if scheduled.timeIntervalSinceNow > 0 {
                delegate?.batteryWakeWindowController(
                    self,
                    cancelScheduledWakeAt: scheduled
                ) { result in
                    if case .failure(let error) = result {
                        NSLog("Modafinil battery-wake: could not cancel the scheduled wake: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    @objc private func screenWasUnlocked() {
        guard configurationStore.areBatteryWakeWindowsArmed else { return }
        disarm(reason: "the screen was unlocked")
    }

    private func handleWake() {
        guard configurationStore.areBatteryWakeWindowsArmed,
              !isEvaluatingWindow
        else {
            return
        }

        guard let expected = configurationStore.batteryWakeNextWindowDate,
              abs(expected.timeIntervalSinceNow) <= Self.windowTolerance
        else {
            // A wake outside the window tolerance is user activity or an
            // unrelated dark wake; user presence is handled via screen unlock.
            return
        }

        isEvaluatingWindow = true
        configurationStore.batteryWakeNextWindowDate = nil
        NSLog("Modafinil battery-wake: window wake detected (scheduled for \(expected))")

        takeAssertion()
        promoteToFullWake()

        guard PowerSource.isRunningOnBattery() else {
            NSLog("Modafinil battery-wake: AC power detected during a window; Wake-on-LAN is available again")
            disarm(reason: "AC power was restored")
            releaseAssertion()
            isEvaluatingWindow = false
            return
        }

        delegate?.batteryWakeWindowControllerBeginAwakeHold(self)

        // Chain the next window before polling so a failure mid-window cannot
        // silently end the schedule.
        scheduleNextWindow()

        let deadline = Date().addingTimeInterval(Self.relayPollDeadline)
        pollRelay(deadline: deadline) { [weak self] pending in
            guard let self else { return }

            switch pending {
            case .some(true):
                NSLog("Modafinil battery-wake: collected a pending wake request; holding the Mac awake")
                self.delegate?.batteryWakeWindowControllerDidCollectPendingWake(self)
            case .some(false):
                NSLog("Modafinil battery-wake: no pending wake request; allowing sleep")
                self.delegate?.batteryWakeWindowControllerEndAwakeHold(self)
            case .none:
                NSLog("Modafinil battery-wake: the relay was unreachable during the window; allowing sleep")
                self.delegate?.batteryWakeWindowControllerEndAwakeHold(self)
            }

            self.releaseAssertion()
            self.isEvaluatingWindow = false
        }
    }

    private func scheduleNextWindow() {
        let remaining = configurationStore.batteryWakeWindowsRemaining
        guard remaining > 0 else {
            NSLog("Modafinil battery-wake: the window budget is exhausted; no further windows")
            configurationStore.areBatteryWakeWindowsArmed = false
            return
        }

        configurationStore.batteryWakeWindowsRemaining = remaining - 1
        let next = Date().addingTimeInterval(Self.windowInterval)
        delegate?.batteryWakeWindowController(self, scheduleWakeAt: next) { [weak self] result in
            switch result {
            case .success:
                self?.configurationStore.batteryWakeNextWindowDate = next
                NSLog("Modafinil battery-wake: next wake window scheduled for \(next)")
            case .failure(let error):
                NSLog("Modafinil battery-wake: scheduling the next window failed: \(error.localizedDescription)")
            }
        }
    }

    private func pollRelay(
        deadline: Date,
        completion: @escaping (Bool?) -> Void
    ) {
        collectFromRelay(timeout: Self.relayAttemptTimeout) { [weak self] result in
            guard let self else { return }

            switch result {
            case .success(let pending):
                completion(pending)
            case .failure(let error):
                let retryAt = Date().addingTimeInterval(Self.relayRetryDelay)
                guard retryAt < deadline else {
                    NSLog("Modafinil battery-wake: relay poll gave up: \(error.localizedDescription)")
                    completion(nil)
                    return
                }
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + Self.relayRetryDelay
                ) {
                    self.pollRelay(deadline: deadline, completion: completion)
                }
            }
        }
    }

    private func collectFromRelay(
        timeout: TimeInterval,
        completion: @escaping (Result<Bool, Error>) -> Void
    ) {
        RelayPendingWakeClient.collectPendingWake(
            host: configurationStore.relayHost,
            port: configurationStore.relayPort,
            secret: configurationStore.relaySecret,
            timeout: timeout,
            completion: completion
        )
    }

    private func takeAssertion() {
        guard assertionID == 0 else { return }

        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Modafinil battery wake window" as CFString,
            &assertionID
        )
        if result != kIOReturnSuccess {
            NSLog("Modafinil battery-wake: could not create the wake assertion (IOReturn \(result))")
            assertionID = 0
        }
    }

    private func promoteToFullWake() {
        // A battery dark wake keeps Wi-Fi down. Declaring user activity asks
        // powerd to promote to a full wake so the network can come up.
        var activityID = IOPMAssertionID(0)
        let result = IOPMAssertionDeclareUserActivity(
            "Modafinil battery wake window" as CFString,
            kIOPMUserActiveLocal,
            &activityID
        )
        if result != kIOReturnSuccess {
            NSLog("Modafinil battery-wake: could not declare user activity (IOReturn \(result))")
        }
    }

    private func releaseAssertion() {
        guard assertionID != 0 else { return }
        IOPMAssertionRelease(assertionID)
        assertionID = 0
    }
}
