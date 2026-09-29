import AppKit
import ModafinilShared
import ModafinilRemoteProtocol
import ServiceManagement

final class AppDelegate: NSObject,
    NSApplicationDelegate,
    CompanionServerDelegate,
    CompanionSetupWindowControllerDelegate,
    StatusPopoverViewControllerDelegate,
    StatusWindowControllerDelegate
{
    private let helperClient = PrivilegedHelperClient()
    private let helperInstaller = PrivilegedHelperInstaller()
    private let lidMonitor = LidMonitor()
    private let codexRuntimeMonitor = CodexRuntimeMonitor()
    private let companionConfigurationStore = CompanionConfigurationStore()
    private let statusPopover = NSPopover()

    private var companionServer: CompanionServer?
    private var companionSetupWindowController: CompanionSetupWindowController?
    private var statusItem: NSStatusItem!
    private var statusPopoverViewController: StatusPopoverViewController?
    private var statusWindowController: StatusWindowController?
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
    private var isProvisionalWakeLeaseActive = false
    private var provisionalWakeLeaseTimer: Timer?
    private var sleepStatusTimer: Timer?
    private var sleepAttempt: SleepAttempt?
    private var lastHandledSleepAttemptID = (try? SleepJournalStore.read())?.attempt?.id
    private var sleepHistoryError: String?
    private var scheduledSleepDate: Date?
    private var scheduledWakeTimer: Timer?
    private var scheduledWakeDate: Date?
    private var isWakeScheduleInFlight = false
    private static let scheduledWakeDefaultsKey = "companion.scheduledWakeAt"

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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(companionConfigurationDidChange),
            name: .modafinilCompanionConfigurationDidChange,
            object: companionConfigurationStore
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(workspaceDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )

        do {
            try lidMonitor.start()
        } catch {
            lastError = error.localizedDescription
        }

        refreshCodexRuntimeState(shouldReconcile: false)
        updateCodexRuntimeMonitoring()
        refreshHelperStatus()
        refreshSleepStatus()
        synchronizeSleepJournal()
        let statusTimer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.synchronizeSleepJournal()
            self.refreshIcon()
        }
        sleepStatusTimer = statusTimer
        RunLoop.main.add(statusTimer, forMode: .common)
        restoreScheduledWake()
        startCompanionServer()
        refreshIcon()
        showStatusWindow()

        if companionConfigurationStore.isWakeArmed {
            activateProvisionalWakeLease()
        }
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        showStatusWindow()
        return true
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
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        codexRuntimeTimer?.invalidate()
        provisionalWakeLeaseTimer?.invalidate()
        sleepStatusTimer?.invalidate()
        scheduledWakeTimer?.invalidate()
        statusPopover.performClose(nil)
        statusWindowController?.close()
        companionSetupWindowController?.close()
        companionServer?.stop()
        helperClient.invalidate()
        lidMonitor.stop()
    }

    @objc private func screenParametersDidChange() {
        refreshIcon()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.refreshIcon()
        }
    }

    private func startCompanionServer() {
        let server = CompanionServer(secret: companionConfigurationStore.secret)
        server.delegate = self
        server.errorHandler = { [weak self] message in
            self?.lastError = message
            self?.refreshIcon()
        }

        do {
            try server.start()
            companionServer = server
        } catch {
            lastError = "Could not start companion access: \(error.localizedDescription)"
        }
    }

    @objc private func companionConfigurationDidChange() {
        companionServer?.updateSecret(companionConfigurationStore.secret)
        companionSetupWindowController?.refresh()
    }

    @objc private func workspaceDidWake() {
        if !completeScheduledWakeIfDue() {
            activateProvisionalWakeLease()
        }
    }

    private func activateProvisionalWakeLease() {
        guard companionConfigurationStore.isWakeArmed else { return }

        companionConfigurationStore.isWakeArmed = false
        isProvisionalWakeLeaseActive = true
        scheduleProvisionalWakeLeaseExpiration()
        reconcileSleepPreventionWithCurrentMode()
    }

    private func scheduleProvisionalWakeLeaseExpiration() {
        provisionalWakeLeaseTimer?.invalidate()
        let timer = Timer(timeInterval: 90, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.isProvisionalWakeLeaseActive = false
            self.provisionalWakeLeaseTimer = nil
            self.reconcileSleepPreventionWithCurrentMode()
        }
        provisionalWakeLeaseTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func cancelProvisionalWakeLease() {
        provisionalWakeLeaseTimer?.invalidate()
        provisionalWakeLeaseTimer = nil
        isProvisionalWakeLeaseActive = false
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

        let nextState = !isAwakeRequestedForStatus

        cancelProvisionalWakeLease()
        companionConfigurationStore.isWakeArmed = false
        isSleepPreventionRequested = nextState
        refreshHelperStatus()
        reconcileSleepPreventionWithCurrentMode()
    }

    private func setSleepPreventionEnabled(
        _ enabled: Bool,
        completion: ((Result<Void, Error>) -> Void)? = nil
    ) {
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
                    self.lastHandledSleepAttemptID = (try? SleepJournalStore.read())?.attempt?.id
                    self.lidMonitor.turnDisplayOffIfNeeded()
                }
            case .failure(let error):
                self.isSleepPreventionEnabled = previousState
                self.lidMonitor.setEnabled(previousState)
                self.lastError = error.localizedDescription
            }

            self.isToggleInFlight = false
            self.refreshIcon()
            completion?(result)

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
        isProvisionalWakeLeaseActive ||
            (isSleepPreventionRequested &&
                (!isCodexRuntimeLimitEnabled || isCodexRunning))
    }

    private var isWaitingForCodex: Bool {
        !isProvisionalWakeLeaseActive &&
            isSleepPreventionRequested &&
            isCodexRuntimeLimitEnabled &&
            !isCodexRunning
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

    @objc private func showCompanionSetup() {
        statusPopover.performClose(nil)

        let windowController: CompanionSetupWindowController
        if let existing = companionSetupWindowController {
            windowController = existing
            windowController.refresh()
        } else {
            windowController = CompanionSetupWindowController(
                configurationStore: companionConfigurationStore
            )
            windowController.setupDelegate = self
            companionSetupWindowController = windowController
        }

        NSApp.setActivationPolicy(.regular)
        windowController.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        windowController.window?.makeKeyAndOrderFront(nil)
    }

    func companionSetupWindowControllerDidClose(
        _ windowController: CompanionSetupWindowController
    ) {
        guard companionSetupWindowController === windowController else { return }
        companionSetupWindowController = nil

        if statusWindowController?.window?.isVisible != true {
            NSApp.setActivationPolicy(.accessory)
        }
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
        guard helperStatus == .enabled else {
            finishRestoringNormalSleepBehavior(completion: completion)
            return
        }
        helperClient.setSleepTimer(after: -1) { [weak self] result in
            switch result {
            case .failure(let error): completion(.failure(error))
            case .success: self?.finishRestoringNormalSleepBehavior(completion: completion)
            }
        }
    }

    private func finishRestoringNormalSleepBehavior(completion: @escaping (Result<Void, Error>) -> Void) {
        cancelProvisionalWakeLease()
        companionConfigurationStore.isWakeArmed = false
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
        companionConfigurationStore.deleteSecrets()
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
        statusWindowController?.window?.ignoresMouseEvents = !enabled
    }

    @objc private func showStatusWindow() {
        refreshHelperStatus()
        refreshCodexRuntimeState(shouldReconcile: false)
        statusPopover.performClose(nil)

        let windowController: StatusWindowController
        if let existingWindowController = statusWindowController {
            windowController = existingWindowController
        } else {
            let viewController = StatusPopoverViewController(presentation: .window)
            viewController.delegate = self

            windowController = StatusWindowController(statusViewController: viewController)
            windowController.statusWindowDelegate = self
            statusWindowController = windowController
        }

        windowController.update(with: makeStatusViewModel())
        NSApp.setActivationPolicy(.regular)
        windowController.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        windowController.window?.makeKeyAndOrderFront(nil)
    }

    func statusWindowControllerDidClose(_ windowController: StatusWindowController) {
        guard statusWindowController === windowController else { return }

        statusWindowController = nil
        if companionSetupWindowController?.window?.isVisible != true {
            NSApp.setActivationPolicy(.accessory)
        }
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

    private func refreshStatusWindow() {
        guard statusWindowController?.window?.isVisible == true else { return }
        statusWindowController?.update(with: makeStatusViewModel())
    }

    func statusPopoverDidToggleSleepPrevention(_ viewController: StatusPopoverViewController) {
        toggleSleepPrevention()
    }

    func statusPopoverDidToggleCodexRuntimeLimit(_ viewController: StatusPopoverViewController) {
        toggleCodexRuntimeLimit()
    }

    func statusPopover(_ viewController: StatusPopoverViewController, didScheduleSleepAfter seconds: Int) {
        scheduleSleep(argument: String(seconds)) { [weak self] result in
            switch result {
            case .success:
                self?.lastError = nil
            case .failure(let error):
                self?.lastError = error.localizedDescription
            }
            self?.refreshIcon()
        }
    }

    func statusPopoverDidCancelScheduledSleep(_ viewController: StatusPopoverViewController) {
        cancelScheduledSleep()
    }

    func statusPopoverDidOpenCompanionSetup(_ viewController: StatusPopoverViewController) {
        showCompanionSetup()
    }

    func statusPopoverDidOpenBackgroundSettings(_ viewController: StatusPopoverViewController) {
        openSettings()
    }

    func statusPopoverDidQuit(_ viewController: StatusPopoverViewController) {
        statusPopover.performClose(nil)
        quit()
    }

    func companionServerCurrentState(_ server: CompanionServer) -> RemoteState {
        if !isToggleInFlight,
           let enabled = readLocalSleepPreventionStatus(),
           enabled != isSleepPreventionEnabled
        {
            isSleepPreventionEnabled = enabled
            lidMonitor.setEnabled(enabled)
            refreshIcon()
        }
        return makeRemoteState()
    }

    func companionServer(
        _ server: CompanionServer,
        perform command: RemoteCommand,
        argument: String,
        completion: @escaping (Result<(RemoteState, String), Error>) -> Void
    ) {
        switch command {
        case .status:
            completion(.success((makeRemoteState(), "Status updated.")))
        case .keepAwake:
            performRemoteKeepAwake(completion: completion)
        case .sleep:
            performRemoteSleep(completion: completion)
        case .scheduleSleep:
            scheduleSleep(argument: argument, completion: completion)
        case .cancelScheduledSleep:
            cancelScheduledSleep(completion: completion)
        case .scheduleWake:
            guard let timestamp = Int64(argument) else {
                completion(.failure(CompanionRemoteError("The wake time is invalid.")))
                return
            }
            setScheduledWake(Date(timeIntervalSince1970: TimeInterval(timestamp)), completion: completion)
        case .cancelScheduledWake:
            setScheduledWake(nil, completion: completion)
        case .wake:
            completion(.failure(
                CompanionRemoteError("Wake requests must be sent to the iPhone relay.")
            ))
        }
    }

    private func scheduleSleep(
        argument: String,
        completion: @escaping (Result<(RemoteState, String), Error>) -> Void
    ) {
        guard let seconds = Int64(argument), (60...86_400).contains(seconds) else {
            completion(.failure(
                CompanionRemoteError("The sleep timer must be between 1 minute and 24 hours.")
            ))
            return
        }

        refreshHelperStatus()
        guard helperStatus == .enabled else {
            completion(.failure(
                CompanionRemoteError(
                    "The privileged helper is not enabled. Open Modafinil on the Mac to approve it."
                )
            ))
            return
        }

        helperClient.setSleepTimer(after: Double(seconds)) { [weak self] result in
            guard let self else { return }
            self.synchronizeSleepJournal()
            self.refreshIcon()
            switch result {
            case .success: completion(.success((self.makeRemoteState(), "Sleep timer saved on the Mac.")))
            case .failure(let error): completion(.failure(error))
            }
        }
    }

    private func cancelScheduledSleep(completion: ((Result<(RemoteState, String), Error>) -> Void)? = nil) {
        helperClient.setSleepTimer(after: 0) { [weak self] result in
            guard let self else { return }
            self.synchronizeSleepJournal()
            self.refreshIcon()
            switch result {
            case .success: completion?(.success((self.makeRemoteState(), "The sleep timer is off.")))
            case .failure(let error):
                self.lastError = error.localizedDescription
                self.refreshIcon()
                completion?(.failure(error))
            }
        }
    }

    private func synchronizeSleepJournal() {
        do {
            let journal = try SleepJournalStore.read()
            sleepHistoryError = nil
            scheduledSleepDate = journal.schedule?.date
            sleepAttempt = journal.attempt
            if let attempt = sleepAttempt {
                if !isToggleInFlight && (attempt.phase == .pending || (attempt.id != lastHandledSleepAttemptID && attempt.phase != .cancelled)) {
                    // The helper's timer is authoritative even while this UI is suspended.
                    // A fast failure may be observed without ever seeing its pending phase.
                    isSleepPreventionRequested = false
                    cancelProvisionalWakeLease()
                    if let enabled = readLocalSleepPreventionStatus() {
                        isSleepPreventionEnabled = enabled
                        lidMonitor.setEnabled(enabled)
                    }
                }
                lastHandledSleepAttemptID = attempt.id
            }
        } catch {
            sleepHistoryError = "Sleep history is unavailable: \(error.localizedDescription)"
        }
    }

    private var sleepAttemptDescription: String {
        if let sleepHistoryError { return sleepHistoryError }
        guard let attempt = sleepAttempt else { return "No sleep request recorded yet." }
        var text = attempt.detail
        if let date = attempt.sleptAt { text += " Last sleep: \(date.formatted(date: .omitted, time: .standard))." }
        if let date = attempt.wokeAt { text += " Wake: \(date.formatted(date: .omitted, time: .standard))." }
        return text
    }

    private func performRemoteKeepAwake(
        completion: @escaping (Result<(RemoteState, String), Error>) -> Void
    ) {
        guard !isToggleInFlight else {
            completion(.failure(
                CompanionRemoteError("Modafinil is already updating the sleep setting.")
            ))
            return
        }

        refreshHelperStatus()
        guard helperStatus == .enabled else {
            completion(.failure(
                CompanionRemoteError(
                    "The privileged helper is not enabled. Open Modafinil on the Mac to approve it."
                )
            ))
            return
        }

        let previousRequestedState = isSleepPreventionRequested
        let previousCodexLimit = isCodexRuntimeLimitEnabled
        let previousProvisionalLease = isProvisionalWakeLeaseActive

        companionConfigurationStore.isWakeArmed = false
        cancelProvisionalWakeLease()
        isSleepPreventionRequested = true

        if isCodexRuntimeLimitEnabled {
            isCodexRuntimeLimitEnabled = false
            UserDefaults.standard.set(
                false,
                forKey: Self.codexRuntimeLimitEnabledDefaultsKey
            )
            updateCodexRuntimeMonitoring()
        }

        lastError = nil
        setSleepPreventionEnabled(true) { [weak self] result in
            guard let self else { return }

            switch result {
            case .success:
                completion(.success((
                    self.makeRemoteState(),
                    "Modafinil is keeping the Mac awake."
                )))
            case .failure(let error):
                self.isSleepPreventionRequested = previousRequestedState
                self.isCodexRuntimeLimitEnabled = previousCodexLimit
                UserDefaults.standard.set(
                    previousCodexLimit,
                    forKey: Self.codexRuntimeLimitEnabledDefaultsKey
                )
                self.updateCodexRuntimeMonitoring()
                if previousProvisionalLease {
                    self.isProvisionalWakeLeaseActive = true
                    self.scheduleProvisionalWakeLeaseExpiration()
                }
                self.refreshIcon()
                completion(.failure(error))
            }
        }
    }

    private func performRemoteSleep(
        completion: @escaping (Result<(RemoteState, String), Error>) -> Void
    ) {
        guard !isToggleInFlight else {
            completion(.failure(
                CompanionRemoteError("Modafinil is already updating the sleep setting.")
            ))
            return
        }

        refreshHelperStatus()
        guard helperStatus == .enabled else {
            completion(.failure(
                CompanionRemoteError(
                    "The privileged helper is not enabled. Open Modafinil on the Mac to approve it."
                )
            ))
            return
        }

        let previousRequestedState = isSleepPreventionRequested
        let previousProvisionalLease = isProvisionalWakeLeaseActive

        lastError = nil
        companionConfigurationStore.isWakeArmed = true
        cancelProvisionalWakeLease()
        isSleepPreventionRequested = false
        isToggleInFlight = true
        sleepStatusGeneration += 1
        refreshIcon()

        helperClient.sleepAfterDisablingSleepPrevention { [weak self] result in
            guard let self else { return }

            self.isToggleInFlight = false
            switch result {
            case .success:
                self.isSleepPreventionEnabled = false
                self.lidMonitor.setEnabled(false)
                self.refreshIcon()
                completion(.success((
                    self.makeRemoteState(),
                    "Sleep request accepted. Check sleep history for confirmation or failure."
                )))
            case .failure(let error):
                self.companionConfigurationStore.isWakeArmed = false
                self.isSleepPreventionRequested = previousRequestedState
                if previousProvisionalLease {
                    self.isProvisionalWakeLeaseActive = true
                    self.scheduleProvisionalWakeLeaseExpiration()
                }
                self.lastError = error.localizedDescription
                self.refreshIcon()
                completion(.failure(error))
            }
        }
    }

    private func makeRemoteState() -> RemoteState {
        synchronizeSleepJournal()
        synchronizeWakeSchedule()
        return RemoteState(
            awakeRequested: isAwakeRequestedForStatus,
            sleepPreventionEffective: isSleepPreventionEnabled,
            serverName: Host.current().localizedName ?? "Mac",
            scheduledSleepAt: scheduledSleepDate.map { Int64($0.timeIntervalSince1970) },
            scheduledWakeAt: scheduledWakeDate.map { Int64($0.timeIntervalSince1970) },
            sleepAttempt: sleepAttempt.map {
                RemoteSleepAttempt(requestedAt: Int64($0.requestedAt.timeIntervalSince1970),
                    phase: RemoteSleepAttempt.Phase(rawValue: $0.phase.rawValue)!,
                    sleptAt: $0.sleptAt.map { Int64($0.timeIntervalSince1970) },
                    wokeAt: $0.wokeAt.map { Int64($0.timeIntervalSince1970) }, detail: $0.detail)
            }
        )
    }

    private func setScheduledWake(
        _ date: Date?,
        completion: @escaping (Result<(RemoteState, String), Error>) -> Void
    ) {
        guard !isWakeScheduleInFlight else {
            completion(.failure(CompanionRemoteError("The wake schedule is being updated.")))
            return
        }
        do {
            if let date { try WakeScheduler.validate(date) }
        } catch {
            completion(.failure(error))
            return
        }
        refreshHelperStatus()
        guard helperStatus == .enabled else {
            completion(.failure(CompanionRemoteError("Enable the privileged helper in Modafinil on the Mac first.")))
            return
        }
        isWakeScheduleInFlight = true
        refreshIcon()
        helperClient.setScheduledWake(date?.timeIntervalSince1970 ?? 0) { [weak self] result in
            guard let self else { return }
            self.isWakeScheduleInFlight = false
            self.synchronizeWakeSchedule(force: true)
            self.refreshIcon()
            switch result {
            case .success:
                completion(.success((self.makeRemoteState(), date == nil
                    ? "The wake timer is off."
                    : "Wake scheduled on the Mac. Keep Modafinil open to stay awake afterward.")))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    private func restoreScheduledWake() {
        let saved = UserDefaults.standard.double(forKey: Self.scheduledWakeDefaultsKey)
        if saved > 0 { scheduledWakeDate = Date(timeIntervalSince1970: saved) }
        synchronizeWakeSchedule()
        if !completeScheduledWakeIfDue() { armScheduledWakeTimer() }
    }

    private func synchronizeWakeSchedule(force: Bool = false) {
        let systemDate = WakeScheduler().scheduledDate()
        // Preserve a just-fired alarm until the wake handler can consume it.
        if !force, let date = scheduledWakeDate, date <= Date(),
           Date().timeIntervalSince(date) <= 300 { return }
        guard force || systemDate != scheduledWakeDate else { return }
        scheduledWakeDate = systemDate
        saveScheduledWake()
        armScheduledWakeTimer()
    }

    private func saveScheduledWake() {
        if let date = scheduledWakeDate {
            UserDefaults.standard.set(date.timeIntervalSince1970, forKey: Self.scheduledWakeDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.scheduledWakeDefaultsKey)
        }
    }

    private func armScheduledWakeTimer() {
        scheduledWakeTimer?.invalidate()
        scheduledWakeTimer = nil
        guard let date = scheduledWakeDate else { return }
        let timer = Timer(fire: date, interval: 0, repeats: false) { [weak self] _ in
            _ = self?.completeScheduledWakeIfDue()
        }
        scheduledWakeTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @discardableResult
    private func completeScheduledWakeIfDue() -> Bool {
        guard let date = scheduledWakeDate, date <= Date() else { return false }
        let overdue = Date().timeIntervalSince(date)
        scheduledWakeDate = nil
        scheduledWakeTimer?.invalidate()
        scheduledWakeTimer = nil
        saveScheduledWake()
        refreshIcon()
        // A wake alarm missed hours ago must not unexpectedly change the mode.
        guard overdue <= 300 else { return false }
        performRemoteKeepAwake { [weak self] result in
            if case .failure(let error) = result {
                self?.lastError = "Scheduled wake keep-awake failed: \(error.localizedDescription)"
                self?.refreshIcon()
            }
        }
        return true
    }

    func statusPopover(_ viewController: StatusPopoverViewController, didScheduleWakeAt date: Date) {
        setScheduledWake(date) { [weak self] result in
            if case .failure(let error) = result { self?.lastError = error.localizedDescription }
            self?.refreshIcon()
        }
    }

    func statusPopoverDidCancelScheduledWake(_ viewController: StatusPopoverViewController) {
        setScheduledWake(nil) { [weak self] result in
            if case .failure(let error) = result { self?.lastError = error.localizedDescription }
            self?.refreshIcon()
        }
    }

    private func updateCodexRuntimeMonitoring() {
        codexRuntimeTimer?.invalidate()
        codexRuntimeTimer = nil

        guard isCodexRuntimeLimitEnabled else { return }

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

        updateCodexRuntimeMonitoring()
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
        refreshStatusWindow()
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
            title: "Open Modafinil",
            action: #selector(showStatusWindow),
            keyEquivalent: ""
        )
        showStatusItem.target = self
        menu.addItem(showStatusItem)

        let toggleItem = NSMenuItem(
            title: isAwakeRequestedForStatus ? "Turn Off" : "Turn On",
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

        let companionSetupItem = NSMenuItem(
            title: "Companion Setup…",
            action: #selector(showCompanionSetup),
            keyEquivalent: ""
        )
        companionSetupItem.target = self
        menu.addItem(companionSetupItem)

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
        synchronizeSleepJournal()
        synchronizeWakeSchedule()
        return StatusPopoverViewController.ViewModel(
            symbolName: statusSymbolName,
            symbolColor: statusSymbolColor,
            title: statusTitle,
            explanation: statusExplanation,
            requestedStatus: isAwakeRequestedForStatus ? "On" : "Off",
            effectiveStatus: effectiveSleepPreventionStatus,
            codexLimitStatus: isCodexRuntimeLimitEnabled ? "Enabled" : "Disabled",
            codexStatus: isCodexRunning ? "Running" : "Not running",
            helperStatus: helperStatusDescription,
            primaryActionTitle: isAwakeRequestedForStatus ? "Turn Off" : "Turn On",
            isPrimaryActionEnabled: !isToggleInFlight,
            isCodexRuntimeLimitEnabled: isCodexRuntimeLimitEnabled,
            scheduledSleepDate: scheduledSleepDate,
            sleepAttemptDescription: sleepAttemptDescription,
            canScheduleSleep: helperStatus == .enabled && !isToggleInFlight && !isQuitInProgress,
            scheduledWakeDate: scheduledWakeDate,
            canScheduleWake: helperStatus == .enabled && !isWakeScheduleInFlight && !isQuitInProgress,
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

        if sleepAttempt?.phase == .pending { return "Sleep requested — verifying" }
        if sleepAttempt?.phase == .failed { return "Sleep was not confirmed" }
        return "Keep-awake is off"
    }

    private var statusExplanation: String {
        if isToggleInFlight {
            return "Modafinil is asking the privileged helper to update the system sleep setting."
        }

        if isSleepPreventionEnabled, isProvisionalWakeLeaseActive {
            return "The Mac woke from a companion request. Modafinil is keeping it awake temporarily while the iPhone reconnects."
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

        if let attempt = sleepAttempt, [.pending, .failed].contains(attempt.phase) { return attempt.detail }
        return "Modafinil is not preventing sleep. This does not mean the Mac is currently asleep."
    }

    private var isAwakeRequestedForStatus: Bool {
        isSleepPreventionRequested || isProvisionalWakeLeaseActive
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

        if sleepAttempt?.phase == .failed { return "exclamationmark.triangle.fill" }
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

        if sleepAttempt?.phase == .failed { return .systemOrange }
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

    private struct CompanionRemoteError: LocalizedError {
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
