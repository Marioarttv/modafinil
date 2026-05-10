import AppKit

protocol StatusPopoverViewControllerDelegate: AnyObject {
    func statusPopoverDidToggleSleepPrevention(_ viewController: StatusPopoverViewController)
    func statusPopoverDidToggleCodexRuntimeLimit(_ viewController: StatusPopoverViewController)
    func statusPopoverDidOpenBackgroundSettings(_ viewController: StatusPopoverViewController)
    func statusPopoverDidQuit(_ viewController: StatusPopoverViewController)
}

final class StatusPopoverViewController: NSViewController {
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
        let lastError: String?
    }

    weak var delegate: StatusPopoverViewControllerDelegate?

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
    private let quitButton = NSButton(title: "Quit Modafinil", target: nil, action: nil)

    override func loadView() {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 320))
        self.view = view

        let contentStack = NSStackView()
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.distribution = .fill
        contentStack.spacing = 12
        view.addSubview(contentStack)

        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            contentStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            contentStack.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            contentStack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16)
        ])

        contentStack.addArrangedSubview(makeHeaderView())

        explanationLabel.font = .systemFont(ofSize: 13)
        explanationLabel.textColor = .secondaryLabelColor
        explanationLabel.lineBreakMode = .byWordWrapping
        explanationLabel.maximumNumberOfLines = 0
        explanationLabel.preferredMaxLayoutWidth = 328
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
        errorLabel.preferredMaxLayoutWidth = 328
        contentStack.addArrangedSubview(errorLabel)

        contentStack.addArrangedSubview(makeSeparator())

        primaryButton.target = self
        primaryButton.action = #selector(primaryButtonClicked)
        primaryButton.bezelStyle = .rounded
        primaryButton.keyEquivalent = "\r"

        codexLimitButton.target = self
        codexLimitButton.action = #selector(codexLimitButtonClicked)

        settingsButton.target = self
        settingsButton.action = #selector(settingsButtonClicked)
        settingsButton.bezelStyle = .rounded

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

        primaryButton.title = viewModel.primaryActionTitle
        primaryButton.isEnabled = viewModel.isPrimaryActionEnabled
        codexLimitButton.state = viewModel.isCodexRuntimeLimitEnabled ? .on : .off

        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        preferredContentSize = NSSize(width: 360, height: max(260, view.fittingSize.height))
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

    @objc private func quitButtonClicked() {
        delegate?.statusPopoverDidQuit(self)
    }
}
