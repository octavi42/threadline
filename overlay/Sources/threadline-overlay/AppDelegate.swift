import AppKit

/// Keeps the daemon alive when the window is closed and reopens it from the Dock.
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var controller: OverlayController?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            controller?.show()
        }
        return true
    }
}
