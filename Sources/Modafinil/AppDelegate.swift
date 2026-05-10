import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, StatusPopoverViewControllerDelegate {
    private let helperClient = PrivilegedHelperClient()
    private let helperInstaller = PrivilegedHelperInstaller()
    private let lidMonitor = LidMonitor()
    private let codexRuntimeMonitor = CodexRuntimeMonitor()
    private let statusPopover = NSPopover()

    private var statusItem: NSStatusItem!
    private var statusPopoverViewController: StatusPopoverViewController?
    private var isSleepPreventionEnabled = false
    private var isSleepPreventionRequested = false
    private var hasLoadedInitialSleepRequest = false
    private var isToggleInFlight = false
    private var needsReconcileAfterToggle = false
    private var helperStatus: SMAppService.Status = .notRegistered
    private var lastError: String?
    private var sleepStatusGeneration = 0
    private var isQuitInProgress = false
    private var isTerminatingAfterCleanup = false
    private var isCodexRuntimeLimitEnabled = UserDefaults.standard.bool(
        forKey: AppDelegate.codexRuntimeLimitEnabledDefaultsKey
    )
    private var isCodexRunning = false
    private var codexRuntimeTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("Modafinil applicationDidFinishLaunching")

        guard ensureRunningFromApplicationsAtLaunch() else {
            return
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageLeft
            button.imageScaling = .scaleProportionallyDown
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        do {
            try lidMonitor.start()
        } catch {
            lastError = error.localizedDescription
        }

        refreshCodexRuntimeState(shouldReconcile: false)
        startCodexRuntimeMonitoring()
        refreshHelperStatus()
        refreshSleepStatus()
        refreshIcon()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if isTerminatingAfterCleanup {
            return .terminateNow
        }

        if isQuitInProgress {
            return .terminateCancel
        }

        quit()
        return .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self)
        codexRuntimeTimer?.invalidate()
        statusPopover.performClose(nil)
        helperClient.invalidate()
        lidMonitor.stop()
    }

    @objc private func screenParametersDidChange() {
        refreshIcon()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.refreshIcon()
        }
    }

    @objc private func statusItemClicked() {
        guard let event = NSApp.currentEvent else {
            showMenu()
            return
        }

        if event.type == .rightMouseUp || event.modifierFlags.contains(.option) {
            showMenu()
            return
        }

        showStatusPopover()
    }

    @objc private func toggleSleepPrevention() {
        guard !isToggleInFlight else { return }

        lastError = nil

        let nextState = !isSleepPreventionRequested

        isSleepPreventionRequested = nextState
        refreshHelperStatus()
        reconcileSleepPreventionWithCurrentMode()
    }

    private func setSleepPreventionEnabled(_ enabled: Bool) {
        let previousState = isSleepPreventionEnabled
        isToggleInFlight = true
        sleepStatusGeneration += 1
        isSleepPreventionEnabled = enabled
        lidMonitor.setEnabled(enabled)
        refreshIcon()

        helperClient.setSleepPreventionEnabled(enabled) { [weak self] result in
            guard let self else { return }

            switch result {
            case .success:
                if enabled {
                    self.lidMonitor.turnDisplayOffIfNeeded()
                }
            case .failure(let error):
                self.isSleepPreventionEnabled = previousState
                self.lidMonitor.setEnabled(previousState)
                self.lastError = error.localizedDescription
            }

            self.isToggleInFlight = false
            self.refreshIcon()

            if self.needsReconcileAfterToggle {
                self.needsReconcileAfterToggle = false
                self.reconcileSleepPreventionWithCurrentMode()
            }
        }
    }

    private func reconcileSleepPreventionWithCurrentMode() {
        if isToggleInFlight {
            needsReconcileAfterToggle = true
            return
        }

        let enabled = shouldEnableSleepPreventionNow

        guard isSleepPreventionEnabled != enabled else {
            refreshIcon()
            return
        }

        refreshHelperStatus()
        guard helperStatus == .enabled else {
            if enabled || isSleepPreventionEnabled {
                installHelper(stateAfterInstall: enabled)
            } else {
                refreshIcon()
            }
            return
        }

        setSleepPreventionEnabled(enabled)
    }

    private var shouldEnableSleepPreventionNow: Bool {
        isSleepPreventionRequested && (!isCodexRuntimeLimitEnabled || isCodexRunning)
    }

    private var isWaitingForCodex: Bool {
        isSleepPreventionRequested && isCodexRuntimeLimitEnabled && !isCodexRunning
    }

    @objc private func installHelper() {
        installHelper(stateAfterInstall: nil)
    }

    private func installHelper(stateAfterInstall: Bool?) {
        lastError = nil

        do {
            try helperInstaller.register()
        } catch {
            if helperInstaller.status != .enabled {
                lastError = error.localizedDescription
            }
        }

        refreshHelperStatus()

        if let stateAfterInstall, helperStatus == .enabled {
            setSleepPreventionEnabled(stateAfterInstall)
            return
        }

        if helperStatus == .requiresApproval {
            helperInstaller.openApprovalSettings()
        }

        refreshIcon()
    }

    @objc private func uninstallApp() {
        let alert = NSAlert()
        alert.messageText = "Uninstall Modafinil?"
        alert.informativeText = "Modafinil will be completely uninstalled, and your Mac's regular sleep behavior will be restored."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        lastError = nil
        setControlsEnabled(false)

        disableSleepPreventionForUninstall { [weak self] result in
            guard let self else { return }

            if case .failure(let error) = result {
                self.lastError = error.localizedDescription
                self.setControlsEnabled(true)
                self.refreshHelperStatus()
                self.refreshIcon()
                self.showError(title: "Uninstall Failed", message: error.localizedDescription)
                return
            }

            do {
                try self.unregisterHelperIfRegistered()
                self.clearPreferences()
                self.deleteAppBundleIfInstalledInApplications()
                self.isTerminatingAfterCleanup = true
                NSApp.terminate(nil)
            } catch {
                self.lastError = error.localizedDescription
                self.setControlsEnabled(true)
                self.refreshHelperStatus()
                self.refreshIcon()
                self.showError(title: "Uninstall Failed", message: error.localizedDescription)
            }
        }
    }

    private func unregisterHelperIfRegistered() throws {
        switch helperInstaller.status {
        case .enabled, .requiresApproval:
            try helperInstaller.unregister()
        case .notRegistered, .notFound:
            break
        @unknown default:
            break
        }
    }

    @objc private func openSettings() {
        helperInstaller.openApprovalSettings()
    }

    @objc private func quit() {
        guard !isQuitInProgress else { return }

        lastError = nil
        isQuitInProgress = true
        setControlsEnabled(false)

        restoreNormalSleepBehavior { [weak self] result in
            guard let self else { return }

            if case .failure(let error) = result {
                self.isQuitInProgress = false
                self.lastError = error.localizedDescription
                self.setControlsEnabled(true)
                self.refreshHelperStatus()
                self.refreshIcon()
                self.showError(title: "Could Not Quit", message: "Modafinil could not restore regular sleep behavior: \(error.localizedDescription)")
                return
            }

            self.isTerminatingAfterCleanup = true
            NSApp.terminate(nil)
        }
    }

    private func disableSleepPreventionForUninstall(completion: @escaping (Result<Void, Error>) -> Void) {
        restoreNormalSleepBehavior(completion: completion)
    }

    private func restoreNormalSleepBehavior(completion: @escaping (Result<Void, Error>) -> Void) {
        refreshHelperStatus()
        let localSleepPreventionStatus = readLocalSleepPreventionStatus()

        if localSleepPreventionStatus == false {
            isSleepPreventionEnabled = false
            isSleepPreventionRequested = false
            lidMonitor.setEnabled(false)
            completion(.success(()))
            return
        }

        guard helperStatus == .enabled else {
            if localSleepPreventionStatus == true {
                completion(.failure(SleepRestoreError("Sleep prevention is still enabled, but the privileged helper is not enabled.")))
            } else {
                completion(.failure(SleepRestoreError("Modafinil could not confirm or restore regular sleep behavior because the privileged helper is not enabled.")))
            }
            return
        }

        helperClient.setSleepPreventionEnabled(false) { [weak self] result in
            guard let self else {
                completion(result)
                return
            }

            if case .success = result {
                self.isSleepPreventionEnabled = false
                self.isSleepPreventionRequested = false
                self.lidMonitor.setEnabled(false)
            }

            completion(result)
        }
    }

    private func readLocalSleepPreventionStatus() -> Bool? {
        do {
            let output = try Shell.run("/usr/bin/pmset", ["-g"])
            return output
                .split(separator: "\n")
                .first { $0.contains("SleepDisabled") }?
                .split(whereSeparator: { $0 == " " || $0 == "\t" })
                .last == "1"
        } catch {
            return nil
        }
    }

    private func clearPreferences() {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return }
        UserDefaults.standard.removePersistentDomain(forName: bundleIdentifier)
        UserDefaults.standard.synchronize()
    }

    private func deleteAppBundleIfInstalledInApplications() {
        let bundleURL = Bundle.main.bundleURL.standardizedFileURL
        let applicationsURL = Self.applicationsDirectoryURL

        guard bundleURL.path.hasPrefix(applicationsURL.path + "/") else {
            return
        }

        let remover = Process()
        remover.executableURL = URL(fileURLWithPath: "/bin/sh")
        remover.arguments = [
            "-c",
            "sleep 1; /bin/rm -rf \"$1\"",
            "modafinil-remover",
            bundleURL.path
        ]

        do {
            try remover.run()
        } catch {
            NSLog("Modafinil could not start app bundle remover: \(error.localizedDescription)")
        }
    }

    private func ensureRunningFromApplicationsAtLaunch() -> Bool {
        if isRunningFromApplications {
            return true
        }

        let alert = NSAlert()
        alert.messageText = "Move Modafinil to Applications"
        alert.informativeText = "Modafinil must be run from /Applications. Move Modafinil.app to /Applications, then open it again."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Quit")
        alert.runModal()

        isTerminatingAfterCleanup = true
        NSApp.terminate(nil)
        return false
    }

    private var isRunningFromApplications: Bool {
        let bundleURL = Bundle.main.bundleURL.standardizedFileURL.resolvingSymlinksInPath()
        let applicationsURL = Self.applicationsDirectoryURL.resolvingSymlinksInPath()
        return bundleURL.path.hasPrefix(applicationsURL.path + "/")
    }

    private static let applicationsDirectoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true).standardizedFileURL

    private func setControlsEnabled(_ enabled: Bool) {
        statusItem?.button?.isEnabled = enabled
        statusPopoverViewController?.view.window?.ignoresMouseEvents = !enabled
    }

    @objc private func showStatusPopover() {
        refreshHelperStatus()
        refreshCodexRuntimeState(shouldReconcile: false)

        guard let button = statusItem.button else { return }

        if statusPopover.isShown {
            statusPopover.performClose(nil)
            return
        }

        let viewController = statusPopoverViewController ?? StatusPopoverViewController()
        viewController.delegate = self
        viewController.update(with: makeStatusViewModel())
        statusPopoverViewController = viewController

        statusPopover.behavior = .transient
        statusPopover.animates = true
        statusPopover.contentViewController = viewController
        statusPopover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    private func refreshStatusPopover() {
        guard statusPopover.isShown else { return }
        statusPopoverViewController?.update(with: makeStatusViewModel())
    }

    func statusPopoverDidToggleSleepPrevention(_ viewController: StatusPopoverViewController) {
        toggleSleepPrevention()
    }

    func statusPopoverDidToggleCodexRuntimeLimit(_ viewController: StatusPopoverViewController) {
        toggleCodexRuntimeLimit()
    }

    func statusPopoverDidOpenBackgroundSettings(_ viewController: StatusPopoverViewController) {
        openSettings()
    }

    func statusPopoverDidQuit(_ viewController: StatusPopoverViewController) {
        statusPopover.performClose(nil)
        quit()
    }

    private func startCodexRuntimeMonitoring() {
        codexRuntimeTimer?.invalidate()

        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            self?.refreshCodexRuntimeState()
        }
        codexRuntimeTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func refreshCodexRuntimeState(shouldReconcile: Bool = true) {
        let wasCodexRunning = isCodexRunning
        isCodexRunning = codexRuntimeMonitor.isCodexRunning()

        guard shouldReconcile, isCodexRuntimeLimitEnabled else {
            refreshIcon()
            return
        }

        if wasCodexRunning != isCodexRunning {
            reconcileSleepPreventionWithCurrentMode()
        } else {
            refreshIcon()
        }
    }

    @objc private func toggleCodexRuntimeLimit() {
        lastError = nil
        isCodexRuntimeLimitEnabled.toggle()
        UserDefaults.standard.set(
            isCodexRuntimeLimitEnabled,
            forKey: Self.codexRuntimeLimitEnabledDefaultsKey
        )

        refreshCodexRuntimeState(shouldReconcile: false)
        reconcileSleepPreventionWithCurrentMode()
    }

    private func refreshHelperStatus() {
        helperStatus = helperInstaller.status
    }

    private func refreshSleepStatus() {
        refreshHelperStatus()
        sleepStatusGeneration += 1
        let generation = sleepStatusGeneration

        if let localSleepPreventionStatus = readLocalSleepPreventionStatus() {
            isSleepPreventionEnabled = localSleepPreventionStatus
            syncInitialSleepRequestIfNeeded(localSleepPreventionStatus)
            lidMonitor.setEnabled(localSleepPreventionStatus)
            if localSleepPreventionStatus {
                lidMonitor.turnDisplayOffIfNeeded()
            }
        } else if helperStatus != .enabled {
            isSleepPreventionEnabled = false
            syncInitialSleepRequestIfNeeded(false)
            lidMonitor.setEnabled(false)
        }

        guard helperStatus == .enabled else {
            reconcileSleepPreventionWithCurrentMode()
            return
        }

        helperClient.getSleepPreventionStatus { [weak self] result in
            guard let self else { return }
            guard generation == self.sleepStatusGeneration else { return }

            switch result {
            case .success(let enabled):
                self.isSleepPreventionEnabled = enabled
                self.syncInitialSleepRequestIfNeeded(enabled)
                self.lidMonitor.setEnabled(enabled)
                if enabled {
                    self.lidMonitor.turnDisplayOffIfNeeded()
                }
            case .failure(let error):
                self.lastError = error.localizedDescription
            }

            self.reconcileSleepPreventionWithCurrentMode()
        }
    }

    private func syncInitialSleepRequestIfNeeded(_ enabled: Bool) {
        guard !hasLoadedInitialSleepRequest else { return }

        isSleepPreventionRequested = enabled
        hasLoadedInitialSleepRequest = true
    }

    private func refreshIcon() {
        let symbolName = isSleepPreventionEnabled ? "eye.fill" : Self.inactiveSymbolName
        let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        let accessibilityDescription = if isSleepPreventionEnabled {
            "Modafinil active"
        } else if isWaitingForCodex {
            "Modafinil waiting for Codex"
        } else {
            "Modafinil inactive"
        }
        let image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: accessibilityDescription
        )?.withSymbolConfiguration(configuration)
        image?.size = NSSize(width: 18, height: 18)
        image?.isTemplate = true

        statusItem.button?.image = image
        statusItem.button?.imageScaling = .scaleProportionallyDown
        statusItem.button?.title = image == nil ? "M" : ""
        statusItem.length = NSStatusItem.squareLength
        statusItem.button?.toolTip = if isSleepPreventionEnabled {
            "Mac is on Modafinil"
        } else if isWaitingForCodex {
            "Modafinil will turn on when Codex is running"
        } else {
            "Mac is not on Modafinil"
        }

        refreshStatusPopover()
    }

    private func showMenu() {
        refreshHelperStatus()
        refreshCodexRuntimeState(shouldReconcile: false)

        let menu = NSMenu()

        let statusText = if isSleepPreventionEnabled {
            "Status: On Modafinil"
        } else if isWaitingForCodex {
            "Status: Waiting for Codex"
        } else {
            "Status: Not on Modafinil"
        }
        let stateItem = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        stateItem.isEnabled = false
        menu.addItem(stateItem)

        if let lastError {
            let errorItem = NSMenuItem(title: "Error: \(lastError)", action: nil, keyEquivalent: "")
            errorItem.isEnabled = false
            menu.addItem(errorItem)
        }

        menu.addItem(.separator())

        let showStatusItem = NSMenuItem(
            title: "Show Status",
            action: #selector(showStatusPopover),
            keyEquivalent: ""
        )
        showStatusItem.target = self
        menu.addItem(showStatusItem)

        let toggleItem = NSMenuItem(
            title: isSleepPreventionRequested ? "Turn Off" : "Turn On",
            action: #selector(toggleSleepPrevention),
            keyEquivalent: ""
        )
        toggleItem.target = self
        menu.addItem(toggleItem)

        let codexLimitItem = NSMenuItem(
            title: "Only While Codex Is Running",
            action: #selector(toggleCodexRuntimeLimit),
            keyEquivalent: ""
        )
        codexLimitItem.target = self
        codexLimitItem.state = isCodexRuntimeLimitEnabled ? .on : .off
        menu.addItem(codexLimitItem)

        if isCodexRuntimeLimitEnabled {
            let codexStatusItem = NSMenuItem(
                title: isCodexRunning ? "Codex: Running" : "Codex: Not Running",
                action: nil,
                keyEquivalent: ""
            )
            codexStatusItem.isEnabled = false
            menu.addItem(codexStatusItem)
        }

        let settingsItem = NSMenuItem(
            title: "Open App Background Activity Settings",
            action: #selector(openSettings),
            keyEquivalent: ""
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let uninstallAppItem = NSMenuItem(
            title: "Uninstall Modafinil...",
            action: #selector(uninstallApp),
            keyEquivalent: ""
        )
        uninstallAppItem.target = self
        menu.addItem(uninstallAppItem)

        let quitItem = NSMenuItem(title: "Quit Modafinil", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func makeStatusViewModel() -> StatusPopoverViewController.ViewModel {
        StatusPopoverViewController.ViewModel(
            symbolName: statusSymbolName,
            symbolColor: statusSymbolColor,
            title: statusTitle,
            explanation: statusExplanation,
            requestedStatus: isSleepPreventionRequested ? "On" : "Off",
            effectiveStatus: effectiveSleepPreventionStatus,
            codexLimitStatus: isCodexRuntimeLimitEnabled ? "Enabled" : "Disabled",
            codexStatus: isCodexRunning ? "Running" : "Not running",
            helperStatus: helperStatusDescription,
            primaryActionTitle: isSleepPreventionRequested ? "Turn Off" : "Turn On",
            isPrimaryActionEnabled: !isToggleInFlight,
            isCodexRuntimeLimitEnabled: isCodexRuntimeLimitEnabled,
            lastError: lastError
        )
    }

    private var statusTitle: String {
        if isToggleInFlight {
            return "Updating Modafinil"
        }

        if isSleepPreventionEnabled {
            return "Sleep prevention is active"
        }

        if isWaitingForCodex {
            return "Waiting for Codex"
        }

        return "Normal sleep is active"
    }

    private var statusExplanation: String {
        if isToggleInFlight {
            return "Modafinil is asking the privileged helper to update the system sleep setting."
        }

        if isSleepPreventionEnabled, isCodexRuntimeLimitEnabled {
            return "Codex is running, so Modafinil is keeping your Mac awake. Sleep prevention will turn off when Codex stops."
        }

        if isSleepPreventionEnabled {
            return "Modafinil is keeping your Mac awake until you turn it off or quit the app."
        }

        if isWaitingForCodex {
            return "You asked Modafinil to turn on only for Codex. Codex is not running, so regular sleep behavior is restored for now."
        }

        if isSleepPreventionRequested {
            return "Modafinil is requested, but the current mode does not allow it to apply sleep prevention yet."
        }

        return "Modafinil is off and your Mac is using regular sleep behavior."
    }

    private var statusSymbolName: String {
        if isToggleInFlight {
            return "arrow.triangle.2.circlepath"
        }

        if isSleepPreventionEnabled {
            return "eye.fill"
        }

        if isWaitingForCodex {
            return "clock"
        }

        return Self.inactiveSymbolName
    }

    private var statusSymbolColor: NSColor {
        if isToggleInFlight {
            return .systemBlue
        }

        if isSleepPreventionEnabled {
            return .systemGreen
        }

        if isWaitingForCodex {
            return .systemOrange
        }

        return .secondaryLabelColor
    }

    private var effectiveSleepPreventionStatus: String {
        if isToggleInFlight {
            return "Updating"
        }

        return isSleepPreventionEnabled ? "Active" : "Inactive"
    }

    private var helperStatusDescription: String {
        switch helperStatus {
        case .enabled:
            return "Enabled"
        case .requiresApproval:
            return "Needs approval"
        case .notRegistered:
            return "Not registered"
        case .notFound:
            return "Not found"
        @unknown default:
            return "Unknown"
        }
    }

    private func showError(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private struct SleepRestoreError: LocalizedError {
        let message: String

        init(_ message: String) {
            self.message = message
        }

        var errorDescription: String? { message }
    }

    private static let inactiveSymbolName: String = {
        if NSImage(systemSymbolName: "eye.half.closed.fill", accessibilityDescription: nil) != nil {
            return "eye.half.closed.fill"
        }

        return "eye.slash.fill"
    }()

    private static let codexRuntimeLimitEnabledDefaultsKey = "CodexRuntimeLimitEnabled"
}
