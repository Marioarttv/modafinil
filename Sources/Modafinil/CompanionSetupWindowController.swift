import AppKit
import CoreImage
import ModafinilRemoteProtocol

protocol CompanionSetupWindowControllerDelegate: AnyObject {
    func companionSetupWindowControllerDidClose(
        _ windowController: CompanionSetupWindowController
    )
}

final class CompanionSetupWindowController: NSWindowController, NSWindowDelegate {
    weak var setupDelegate: CompanionSetupWindowControllerDelegate?

    init(configurationStore: CompanionConfigurationStore) {
        let viewController = CompanionSetupViewController(
            configurationStore: configurationStore
        )
        let window = NSWindow(
            contentRect: NSRect(
                origin: .zero,
                size: NSSize(width: 560, height: 760)
            ),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Modafinil Companion Setup"
        window.contentViewController = viewController
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.setFrameAutosaveName("ModafinilCompanionSetupWindow")

        super.init(window: window)

        window.delegate = self
        if !window.setFrameUsingName("ModafinilCompanionSetupWindow") {
            window.center()
        }
    }

    required init?(coder: NSCoder) {
        nil
    }

    func refresh() {
        (window?.contentViewController as? CompanionSetupViewController)?.refresh()
    }

    func windowWillClose(_ notification: Notification) {
        setupDelegate?.companionSetupWindowControllerDidClose(self)
    }
}

private final class CompanionSetupViewController: NSViewController {
    private let configurationStore: CompanionConfigurationStore
    private var networkInformation: CompanionNetworkInformation
    private let qrImageView = NSImageView()
    private let macHostField = NSTextField()
    private let relayHostField = NSTextField()
    private let relayPortField = NSTextField()
    private let targetMACsField = NSTextField()
    private let pairingLinkField = NSTextField()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let copyButton = NSButton(
        title: "Copy Pairing Link",
        target: nil,
        action: nil
    )

    init(configurationStore: CompanionConfigurationStore) {
        self.configurationStore = configurationStore
        networkInformation = .discover()
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        let view = NSView(
            frame: NSRect(origin: .zero, size: NSSize(width: 560, height: 720))
        )
        self.view = view

        let content = NSStackView()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.orientation = .vertical
        content.alignment = .leading
        content.distribution = .fill
        content.spacing = 14
        view.addSubview(content)

        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28),
            content.topAnchor.constraint(equalTo: view.topAnchor, constant: 24),
            content.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -24)
        ])

        let title = NSTextField(labelWithString: "Pair an iPhone")
        title.font = .systemFont(ofSize: 22, weight: .bold)
        content.addArrangedSubview(title)

        let explanation = NSTextField(
            wrappingLabelWithString: """
            Enter the jailbroken XR's Tailscale address, then scan this private QR code in the companion app. Commands are accepted only from Tailscale or this Mac and are authenticated with the secret embedded in the code.
            """
        )
        explanation.textColor = .secondaryLabelColor
        explanation.maximumNumberOfLines = 0
        explanation.preferredMaxLayoutWidth = 504
        content.addArrangedSubview(explanation)

        content.addArrangedSubview(makeSeparator())
        content.addArrangedSubview(
            makeRow(title: "Mac Tailscale IP", field: macHostField)
        )
        macHostField.isEditable = false
        macHostField.isSelectable = true

        content.addArrangedSubview(
            makeRow(title: "XR Tailscale host", field: relayHostField)
        )
        relayHostField.placeholderString = "100.x.y.z or MagicDNS name"

        content.addArrangedSubview(
            makeRow(title: "XR relay port", field: relayPortField)
        )

        content.addArrangedSubview(
            makeRow(title: "Wake MAC address(es)", field: targetMACsField)
        )
        targetMACsField.placeholderString = "aa:bb:cc:dd:ee:ff"

        let macHint = NSTextField(
            wrappingLabelWithString: """
            Prefilled from the active Wi-Fi interface. You can enter 1–4 comma-separated MAC addresses when macOS uses different private addresses.
            """
        )
        macHint.font = .systemFont(ofSize: 11)
        macHint.textColor = .secondaryLabelColor
        macHint.maximumNumberOfLines = 0
        macHint.preferredMaxLayoutWidth = 504
        content.addArrangedSubview(macHint)

        let saveButton = NSButton(
            title: "Save and Refresh QR",
            target: self,
            action: #selector(saveAndRefresh)
        )
        saveButton.bezelStyle = .rounded

        let resetButton = NSButton(
            title: "Generate New Secret…",
            target: self,
            action: #selector(resetSecret)
        )
        resetButton.bezelStyle = .rounded

        let editActions = NSStackView(views: [saveButton, resetButton])
        editActions.orientation = .horizontal
        editActions.spacing = 8
        content.addArrangedSubview(editActions)

        content.addArrangedSubview(makeSeparator())

        qrImageView.imageScaling = .scaleProportionallyUpOrDown
        qrImageView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            qrImageView.widthAnchor.constraint(equalToConstant: 220),
            qrImageView.heightAnchor.constraint(equalToConstant: 220)
        ])

        let qrContainer = NSStackView()
        qrContainer.orientation = .horizontal
        qrContainer.alignment = .centerY
        qrContainer.distribution = .fill
        qrContainer.addArrangedSubview(NSView())
        qrContainer.addArrangedSubview(qrImageView)
        qrContainer.addArrangedSubview(NSView())
        content.addArrangedSubview(qrContainer)
        qrContainer.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true

        pairingLinkField.isEditable = false
        pairingLinkField.isSelectable = true
        pairingLinkField.lineBreakMode = .byTruncatingMiddle
        content.addArrangedSubview(pairingLinkField)
        pairingLinkField.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true

        copyButton.target = self
        copyButton.action = #selector(copyPairingLink)
        copyButton.bezelStyle = .rounded
        content.addArrangedSubview(copyButton)

        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.maximumNumberOfLines = 0
        statusLabel.preferredMaxLayoutWidth = 504
        content.addArrangedSubview(statusLabel)

        refresh()
    }

    func refresh() {
        networkInformation = .discover()
        let configuration = configurationStore.pairingConfiguration(
            networkInformation: networkInformation
        )
        macHostField.stringValue = configuration.macHost
        relayHostField.stringValue = configuration.relayHost
        relayPortField.stringValue = String(configuration.relayPort)
        targetMACsField.stringValue = configuration.targetMAC
        updatePairingOutput(configuration)
    }

    private func makeRow(title: String, field: NSTextField) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.widthAnchor.constraint(equalToConstant: 148).isActive = true

        let row = NSStackView(views: [label, field])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.distribution = .fill
        row.spacing = 10
        field.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        return row
    }

    private func makeSeparator() -> NSBox {
        let separator = NSBox()
        separator.boxType = .separator
        return separator
    }

    @objc private func saveAndRefresh() {
        do {
            let relayPort = try validatedRelayPort()
            let targetMACs = try validatedTargetMACs()
            let relayHost = relayHostField.stringValue.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !relayHost.isEmpty else {
                throw SetupError("Enter the XR's Tailscale address.")
            }

            configurationStore.updatePairing(
                relayHost: relayHost,
                relayPort: relayPort,
                targetMACs: targetMACs
            )
            statusLabel.textColor = .systemGreen
            statusLabel.stringValue = "Pairing settings saved locally."
            refresh()
        } catch {
            statusLabel.textColor = .systemRed
            statusLabel.stringValue = error.localizedDescription
        }
    }

    @objc private func resetSecret() {
        let alert = NSAlert()
        alert.messageText = "Generate a new pairing secret?"
        alert.informativeText = """
        Existing iPhone pairings will stop working until you scan the new QR code.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Generate")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        configurationStore.resetSecret()
        statusLabel.textColor = .systemGreen
        statusLabel.stringValue = "A new secret was generated locally."
        refresh()
    }

    @objc private func copyPairingLink() {
        let value = pairingLinkField.stringValue
        guard !value.isEmpty else { return }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        statusLabel.textColor = .systemGreen
        statusLabel.stringValue = "Private pairing link copied."
    }

    private func updatePairingOutput(_ configuration: PairingConfiguration) {
        let targetMACsAreValid = (try? validateTargetMACs(configuration.targetMAC)) != nil
        let isComplete = !configuration.macHost.isEmpty &&
            !configuration.relayHost.isEmpty &&
            targetMACsAreValid

        guard isComplete else {
            pairingLinkField.stringValue = ""
            qrImageView.image = NSImage(
                systemSymbolName: "qrcode",
                accessibilityDescription: "Pairing QR code unavailable"
            )
            qrImageView.contentTintColor = .tertiaryLabelColor
            copyButton.isEnabled = false

            if configuration.macHost.isEmpty {
                statusLabel.textColor = .systemOrange
                statusLabel.stringValue = """
                Tailscale IPv4 could not be detected. Connect Tailscale on this Mac, then reopen this window.
                """
            } else if configuration.relayHost.isEmpty {
                statusLabel.textColor = .secondaryLabelColor
                statusLabel.stringValue = "Enter the XR's Tailscale address to create the QR code."
            } else {
                statusLabel.textColor = .systemRed
                statusLabel.stringValue = "Enter 1–4 valid comma-separated MAC addresses."
            }
            return
        }

        let link = configuration.pairingURL.absoluteString
        pairingLinkField.stringValue = link
        qrImageView.image = makeQRCode(from: link)
        qrImageView.contentTintColor = nil
        copyButton.isEnabled = true
    }

    private func validatedRelayPort() throws -> UInt16 {
        guard let port = UInt16(relayPortField.stringValue), port != 0 else {
            throw SetupError("Enter a valid XR relay port.")
        }
        return port
    }

    private func validatedTargetMACs() throws -> String {
        try validateTargetMACs(targetMACsField.stringValue)
    }

    private func validateTargetMACs(_ value: String) throws -> String {
        let candidates = value
            .split(separator: ",", omittingEmptySubsequences: false)
            .map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            }

        guard (1...4).contains(candidates.count),
              candidates.allSatisfy(isMACAddress)
        else {
            throw SetupError("Enter 1–4 valid comma-separated MAC addresses.")
        }

        return candidates.joined(separator: ",")
    }

    private func isMACAddress(_ value: String) -> Bool {
        let bytes = value.split(separator: ":")
        return bytes.count == 6 && bytes.allSatisfy {
            $0.count == 2 && UInt8($0, radix: 16) != nil
        }
    }

    private func makeQRCode(from value: String) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else {
            return nil
        }
        filter.setValue(Data(value.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")

        guard let outputImage = filter.outputImage else { return nil }
        let scale = 8.0
        let transformed = outputImage.transformed(
            by: CGAffineTransform(scaleX: scale, y: scale)
        )
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let cgImage = context.createCGImage(
            transformed,
            from: transformed.extent
        ) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: 220, height: 220))
    }

    private struct SetupError: LocalizedError {
        let message: String

        init(_ message: String) {
            self.message = message
        }

        var errorDescription: String? { message }
    }
}
