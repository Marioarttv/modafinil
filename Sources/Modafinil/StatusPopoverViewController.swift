import AppKit

protocol StatusPopoverViewControllerDelegate: AnyObject {
    func statusPopoverDidToggleSleepPrevention(_ viewController: StatusPopoverViewController)
    func statusPopoverDidToggleCodexRuntimeLimit(_ viewController: StatusPopoverViewController)
    func statusPopover(_ viewController: StatusPopoverViewController, didScheduleSleepAfter seconds: Int)
    func statusPopoverDidCancelScheduledSleep(_ viewController: StatusPopoverViewController)
    func statusPopover(_ viewController: StatusPopoverViewController, didScheduleWakeAt date: Date)
    func statusPopoverDidCancelScheduledWake(_ viewController: StatusPopoverViewController)
    func statusPopoverDidOpenCompanionSetup(_ viewController: StatusPopoverViewController)
    func statusPopoverDidOpenBackgroundSettings(_ viewController: StatusPopoverViewController)
    func statusPopoverDidQuit(_ viewController: StatusPopoverViewController)
}

final class StatusPopoverViewController: NSViewController {
    enum Presentation {
        case popover
        case window

        var width: CGFloat {
            switch self {
            case .popover:
                return 360
            case .window:
                return 440
            }
        }

        var contentInset: CGFloat {
            switch self {
            case .popover:
                return 16
            case .window:
                return 24
            }
        }
    }

    struct ViewModel {
        let symbolName: String
        let symbolColor: NSColor
        let title: String
        let explanation: String
        let requestedStatus: String
        let effectiveStatus: String
        let codexLimitStatus: String
        let codexStatus: String
        let helperStatus: String
        let primaryActionTitle: String
        let isPrimaryActionEnabled: Bool
        let isCodexRuntimeLimitEnabled: Bool
        let scheduledSleepDate: Date?
        let canScheduleSleep: Bool
        let scheduledWakeDate: Date?
        let canScheduleWake: Bool
        let lastError: String?
    }

    weak var delegate: StatusPopoverViewControllerDelegate?

    private let presentation: Presentation
    private let symbolImageView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let explanationLabel = NSTextField(labelWithString: "")
    private let requestedValueLabel = NSTextField(labelWithString: "")
    private let effectiveValueLabel = NSTextField(labelWithString: "")
    private let codexLimitValueLabel = NSTextField(labelWithString: "")
    private let codexValueLabel = NSTextField(labelWithString: "")
    private let helperValueLabel = NSTextField(labelWithString: "")
    private let errorLabel = NSTextField(labelWithString: "")
    private let primaryButton = NSButton(title: "", target: nil, action: nil)
    private let codexLimitButton = NSButton(
        checkboxWithTitle: "Only while Codex is running",
        target: nil,
        action: nil
    )
    private let settingsButton = NSButton(title: "Background Activity Settings", target: nil, action: nil)
    private let companionSetupButton = NSButton(
        title: "Companion Setup…",
        target: nil,
        action: nil
    )
    private let sleepDurationInput = NSComboBox()
    private let sleepTimerLabel = NSTextField(labelWithString: "Sleep timer is off")
    private let sleepTimerErrorLabel = NSTextField(labelWithString: "")
    private let startSleepTimerButton = NSButton(title: "Start Timer", target: nil, action: nil)
    private let cancelSleepTimerButton = NSButton(title: "Cancel Timer", target: nil, action: nil)
    private var scheduledSleepDate: Date?
    private let wakeDatePicker = NSDatePicker()
    private let wakeTimerLabel = NSTextField(wrappingLabelWithString: "No wake scheduled")
    private let scheduleWakeButton = NSButton(title: "Schedule Wake", target: nil, action: nil)
    private let cancelWakeButton = NSButton(title: "Cancel Wake", target: nil, action: nil)
    private var presentedWakeDate: Date?
    private var countdownTimer: Timer?
    private var isPresenting = false

    private let quitButton = NSButton(title: "Quit Modafinil", target: nil, action: nil)

    init(presentation: Presentation = .popover) {
        self.presentation = presentation
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        presentation = .popover
        super.init(coder: coder)
    }

    override func loadView() {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: presentation.width, height: 320))
        self.view = view

        let contentStack = NSStackView()
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.distribution = .fill
        contentStack.spacing = 12
        view.addSubview(contentStack)

        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: presentation.contentInset),
            contentStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -presentation.contentInset),
            contentStack.topAnchor.constraint(equalTo: view.topAnchor, constant: presentation.contentInset),
            contentStack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -presentation.contentInset)
        ])

        contentStack.addArrangedSubview(makeHeaderView())

        explanationLabel.font = .systemFont(ofSize: 13)
        explanationLabel.textColor = .secondaryLabelColor
        explanationLabel.lineBreakMode = .byWordWrapping
        explanationLabel.maximumNumberOfLines = 0
        explanationLabel.preferredMaxLayoutWidth = presentation.width - (presentation.contentInset * 2)
        contentStack.addArrangedSubview(explanationLabel)

        contentStack.addArrangedSubview(makeSeparator())

        let detailsStack = NSStackView()
        detailsStack.orientation = .vertical
        detailsStack.alignment = .leading
        detailsStack.distribution = .fill
        detailsStack.spacing = 7
        detailsStack.addArrangedSubview(makeStatusRow(title: "Requested", valueLabel: requestedValueLabel))
        detailsStack.addArrangedSubview(makeStatusRow(title: "Sleep prevention", valueLabel: effectiveValueLabel))
        detailsStack.addArrangedSubview(makeStatusRow(title: "Codex limit", valueLabel: codexLimitValueLabel))
        detailsStack.addArrangedSubview(makeStatusRow(title: "Codex", valueLabel: codexValueLabel))
        detailsStack.addArrangedSubview(makeStatusRow(title: "Helper", valueLabel: helperValueLabel))
        contentStack.addArrangedSubview(detailsStack)

        errorLabel.font = .systemFont(ofSize: 12)
        errorLabel.textColor = .systemRed
        errorLabel.lineBreakMode = .byWordWrapping
        errorLabel.maximumNumberOfLines = 0
        errorLabel.preferredMaxLayoutWidth = presentation.width - (presentation.contentInset * 2)
        contentStack.addArrangedSubview(errorLabel)

        contentStack.addArrangedSubview(makeSeparator())

        contentStack.addArrangedSubview(makeSleepTimerView())
        contentStack.addArrangedSubview(makeSeparator())
        contentStack.addArrangedSubview(makeWakeTimerView())
        contentStack.addArrangedSubview(makeSeparator())

        primaryButton.target = self
        primaryButton.action = #selector(primaryButtonClicked)
        primaryButton.bezelStyle = .rounded
        primaryButton.keyEquivalent = "\r"
        if presentation == .window {
            primaryButton.controlSize = .large
        }

        codexLimitButton.target = self
        codexLimitButton.action = #selector(codexLimitButtonClicked)

        settingsButton.target = self
        settingsButton.action = #selector(settingsButtonClicked)
        settingsButton.bezelStyle = .rounded

        companionSetupButton.target = self
        companionSetupButton.action = #selector(companionSetupButtonClicked)
        companionSetupButton.bezelStyle = .rounded

        quitButton.target = self
        quitButton.action = #selector(quitButtonClicked)
        quitButton.bezelStyle = .rounded

        let actionStack = NSStackView()
        actionStack.orientation = .vertical
        actionStack.alignment = .leading
        actionStack.distribution = .fill
        actionStack.spacing = 8
        actionStack.addArrangedSubview(primaryButton)
        actionStack.addArrangedSubview(codexLimitButton)
        actionStack.addArrangedSubview(companionSetupButton)

        let secondaryActionStack = NSStackView()
        secondaryActionStack.orientation = .horizontal
        secondaryActionStack.alignment = .centerY
        secondaryActionStack.spacing = 8
        secondaryActionStack.addArrangedSubview(settingsButton)
        secondaryActionStack.addArrangedSubview(quitButton)
        actionStack.addArrangedSubview(secondaryActionStack)

        contentStack.addArrangedSubview(actionStack)
    }

    func update(with viewModel: ViewModel) {
        _ = view
        let configuration = NSImage.SymbolConfiguration(pointSize: 20, weight: .semibold)
        symbolImageView.image = NSImage(
            systemSymbolName: viewModel.symbolName,
            accessibilityDescription: viewModel.title
        )?.withSymbolConfiguration(configuration)
        symbolImageView.contentTintColor = viewModel.symbolColor

        titleLabel.stringValue = viewModel.title
        explanationLabel.stringValue = viewModel.explanation
        requestedValueLabel.stringValue = viewModel.requestedStatus
        effectiveValueLabel.stringValue = viewModel.effectiveStatus
        codexLimitValueLabel.stringValue = viewModel.codexLimitStatus
        codexValueLabel.stringValue = viewModel.codexStatus
        helperValueLabel.stringValue = viewModel.helperStatus

        if let lastError = viewModel.lastError {
            errorLabel.stringValue = "Error: \(lastError)"
            errorLabel.isHidden = false
        } else {
            errorLabel.stringValue = ""
            errorLabel.isHidden = true
        }

        scheduledSleepDate = viewModel.scheduledSleepDate
        startSleepTimerButton.title = scheduledSleepDate == nil ? "Start Timer" : "Update Timer"
        startSleepTimerButton.isEnabled = viewModel.canScheduleSleep
        cancelSleepTimerButton.isEnabled = scheduledSleepDate != nil
        if presentedWakeDate != viewModel.scheduledWakeDate {
            presentedWakeDate = viewModel.scheduledWakeDate
            if let date = presentedWakeDate { wakeDatePicker.dateValue = date }
        }
        wakeTimerLabel.stringValue = viewModel.scheduledWakeDate.map {
            "Wake & keep awake: \($0.formatted(date: .abbreviated, time: .shortened))"
        } ?? "No wake scheduled"
        scheduleWakeButton.title = viewModel.scheduledWakeDate == nil ? "Schedule Wake" : "Update Wake"
        scheduleWakeButton.isEnabled = viewModel.canScheduleWake
        cancelWakeButton.isEnabled = viewModel.canScheduleWake && viewModel.scheduledWakeDate != nil
        updateCountdown()
        updateCountdownTimer()

        primaryButton.title = viewModel.primaryActionTitle
        primaryButton.isEnabled = viewModel.isPrimaryActionEnabled
        codexLimitButton.state = viewModel.isCodexRuntimeLimitEnabled ? .on : .off

        resizeToFitContent()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        isPresenting = true
        updateCountdown()
        updateCountdownTimer()
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        isPresenting = false
        countdownTimer?.invalidate()
        countdownTimer = nil
    }

    deinit {
        countdownTimer?.invalidate()
    }

    private func updateCountdownTimer() {
        guard isPresenting, scheduledSleepDate != nil else {
            countdownTimer?.invalidate()
            countdownTimer = nil
            return
        }
        guard countdownTimer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.updateCountdown()
        }
        countdownTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func updateCountdown() {
        guard let scheduledSleepDate else {
            sleepTimerLabel.stringValue = "Sleep timer is off"
            sleepTimerLabel.toolTip = nil
            return
        }
        let remaining = max(0, Int(ceil(scheduledSleepDate.timeIntervalSinceNow)))
        let countdown = String(format: "%02d:%02d:%02d", remaining / 3600, (remaining / 60) % 60, remaining % 60)
        sleepTimerLabel.stringValue = "Mac sleeps in \(countdown)"
        sleepTimerLabel.toolTip = "Scheduled for \(scheduledSleepDate.formatted(date: .omitted, time: .shortened))"
    }

    private func makeWakeTimerView() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        let heading = NSTextField(labelWithString: "Wake Timer")
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        stack.addArrangedSubview(heading)
        wakeTimerLabel.font = .systemFont(ofSize: 12)
        wakeTimerLabel.preferredMaxLayoutWidth = presentation.width - presentation.contentInset * 2
        wakeTimerLabel.setAccessibilityIdentifier("wakeTimerStatus")
        stack.addArrangedSubview(wakeTimerLabel)
        wakeDatePicker.datePickerStyle = .textFieldAndStepper
        wakeDatePicker.datePickerElements = [.yearMonthDay, .hourMinute]
        wakeDatePicker.dateValue = Date(timeIntervalSince1970: floor(Date().addingTimeInterval(3600).timeIntervalSince1970 / 60) * 60)
        wakeDatePicker.setAccessibilityLabel("Scheduled wake date and time")
        wakeDatePicker.setAccessibilityIdentifier("wakeDateTime")
        stack.addArrangedSubview(wakeDatePicker)
        scheduleWakeButton.target = self
        scheduleWakeButton.action = #selector(scheduleWakeClicked)
        cancelWakeButton.target = self
        cancelWakeButton.action = #selector(cancelWakeClicked)
        for button in [scheduleWakeButton, cancelWakeButton] { button.bezelStyle = .rounded }
        stack.addArrangedSubview(NSStackView(views: [scheduleWakeButton, cancelWakeButton]))
        let hint = NSTextField(wrappingLabelWithString: "One-time wake, up to 30 days ahead. Keep your Mac on power and Modafinil open to stay awake afterward. Scheduling does not put it to sleep.")
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .secondaryLabelColor
        hint.preferredMaxLayoutWidth = presentation.width - presentation.contentInset * 2
        stack.addArrangedSubview(hint)
        return stack
    }

    @objc private func scheduleWakeClicked() {
        view.window?.makeFirstResponder(nil)
        let date = Date(timeIntervalSince1970: floor(wakeDatePicker.dateValue.timeIntervalSince1970 / 60) * 60)
        delegate?.statusPopover(self, didScheduleWakeAt: date)
    }

    @objc private func cancelWakeClicked() {
        delegate?.statusPopoverDidCancelScheduledWake(self)
    }

    private func makeSleepTimerView() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8

        let heading = NSTextField(labelWithString: "Sleep Timer")
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        stack.addArrangedSubview(heading)

        sleepTimerLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        sleepTimerLabel.setAccessibilityIdentifier("sleepTimerStatus")
        stack.addArrangedSubview(sleepTimerLabel)

        sleepDurationInput.addItems(withObjectValues: ["15", "30", "45", "60", "90", "120"])
        sleepDurationInput.selectItem(at: 1)
        sleepDurationInput.stringValue = "30"
        sleepDurationInput.widthAnchor.constraint(equalToConstant: 80).isActive = true
        sleepDurationInput.setAccessibilityLabel("Sleep timer duration in minutes")
        sleepDurationInput.setAccessibilityIdentifier("sleepTimerMinutes")
        let units = NSTextField(labelWithString: "minutes (1–1440)")
        units.font = .systemFont(ofSize: 12)
        units.textColor = .secondaryLabelColor
        let durationRow = NSStackView(views: [sleepDurationInput, units])
        durationRow.spacing = 8
        durationRow.alignment = .centerY
        stack.addArrangedSubview(durationRow)

        startSleepTimerButton.target = self
        startSleepTimerButton.action = #selector(startSleepTimerClicked)
        startSleepTimerButton.bezelStyle = .rounded
        cancelSleepTimerButton.target = self
        cancelSleepTimerButton.action = #selector(cancelSleepTimerClicked)
        cancelSleepTimerButton.bezelStyle = .rounded
        let buttons = NSStackView(views: [startSleepTimerButton, cancelSleepTimerButton])
        buttons.spacing = 8
        stack.addArrangedSubview(buttons)

        sleepTimerErrorLabel.font = .systemFont(ofSize: 12)
        sleepTimerErrorLabel.textColor = .systemRed
        sleepTimerErrorLabel.isHidden = true
        stack.addArrangedSubview(sleepTimerErrorLabel)

        let hint = NSTextField(wrappingLabelWithString: "Puts your Mac to sleep when the timer ends. Keep Modafinil open; quitting cancels the timer.")
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .secondaryLabelColor
        hint.preferredMaxLayoutWidth = presentation.width - (presentation.contentInset * 2)
        stack.addArrangedSubview(hint)
        return stack
    }

    @objc private func startSleepTimerClicked() {
        let value = sleepDurationInput.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let minutes = Int(value), (1...1440).contains(minutes) else {
            sleepTimerErrorLabel.stringValue = "Enter a whole number from 1 to 1440."
            sleepTimerErrorLabel.isHidden = false
            resizeToFitContent()
            return
        }
        sleepTimerErrorLabel.isHidden = true
        delegate?.statusPopover(self, didScheduleSleepAfter: minutes * 60)
        resizeToFitContent()
    }

    @objc private func cancelSleepTimerClicked() {
        sleepTimerErrorLabel.isHidden = true
        delegate?.statusPopoverDidCancelScheduledSleep(self)
        resizeToFitContent()
    }

    private func resizeToFitContent() {
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        preferredContentSize = NSSize(width: presentation.width, height: max(260, view.fittingSize.height))
        if presentation == .window {
            view.window?.setContentSize(preferredContentSize)
        }
    }

    private func makeHeaderView() -> NSView {
        symbolImageView.setContentHuggingPriority(.required, for: .horizontal)
        symbolImageView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            symbolImageView.widthAnchor.constraint(equalToConstant: 24),
            symbolImageView.heightAnchor.constraint(equalToConstant: 24)
        ])

        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byWordWrapping
        titleLabel.maximumNumberOfLines = 2

        let headerStack = NSStackView()
        headerStack.orientation = .horizontal
        headerStack.alignment = .centerY
        headerStack.distribution = .fill
        headerStack.spacing = 10
        headerStack.addArrangedSubview(symbolImageView)
        headerStack.addArrangedSubview(titleLabel)
        return headerStack
    }

    private func makeStatusRow(title: String, valueLabel: NSTextField) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 12)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.widthAnchor.constraint(equalToConstant: 118).isActive = true

        valueLabel.font = .systemFont(ofSize: 12, weight: .medium)
        valueLabel.textColor = .labelColor
        valueLabel.lineBreakMode = .byTruncatingTail

        let rowStack = NSStackView()
        rowStack.orientation = .horizontal
        rowStack.alignment = .firstBaseline
        rowStack.distribution = .fill
        rowStack.spacing = 8
        rowStack.addArrangedSubview(titleLabel)
        rowStack.addArrangedSubview(valueLabel)
        return rowStack
    }

    private func makeSeparator() -> NSBox {
        let separator = NSBox()
        separator.boxType = .separator
        return separator
    }

    @objc private func primaryButtonClicked() {
        delegate?.statusPopoverDidToggleSleepPrevention(self)
    }

    @objc private func codexLimitButtonClicked() {
        delegate?.statusPopoverDidToggleCodexRuntimeLimit(self)
    }

    @objc private func settingsButtonClicked() {
        delegate?.statusPopoverDidOpenBackgroundSettings(self)
    }

    @objc private func companionSetupButtonClicked() {
        delegate?.statusPopoverDidOpenCompanionSetup(self)
    }

    @objc private func quitButtonClicked() {
        delegate?.statusPopoverDidQuit(self)
    }
}
