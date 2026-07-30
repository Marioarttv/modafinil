import AppKit

protocol StatusWindowControllerDelegate: AnyObject {
    func statusWindowControllerDidClose(_ windowController: StatusWindowController)
}

final class StatusWindowController: NSWindowController, NSWindowDelegate {
    weak var statusWindowDelegate: StatusWindowControllerDelegate?

    let statusViewController: StatusPopoverViewController

    init(statusViewController: StatusPopoverViewController) {
        self.statusViewController = statusViewController

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 440, height: 390)),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Modafinil"
        window.contentViewController = statusViewController
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.setFrameAutosaveName("ModafinilStatusWindow")

        super.init(window: window)

        window.delegate = self
        if !window.setFrameUsingName("ModafinilStatusWindow") {
            window.center()
        }
    }

    required init?(coder: NSCoder) {
        nil
    }

    func update(with viewModel: StatusPopoverViewController.ViewModel) {
        statusViewController.update(with: viewModel)

        guard let window else { return }

        let contentHeight = max(350, statusViewController.preferredContentSize.height)
        window.setContentSize(NSSize(width: 440, height: contentHeight))
    }

    func windowWillClose(_ notification: Notification) {
        statusWindowDelegate?.statusWindowControllerDidClose(self)
    }
}
