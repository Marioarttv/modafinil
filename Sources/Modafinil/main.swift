import AppKit

// The app delegate drives SwiftUI views and is main-actor isolated.
MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = AppDelegate()

    application.setActivationPolicy(.accessory)
    application.delegate = delegate
    application.run()
}
