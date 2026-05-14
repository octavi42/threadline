import AppKit
import SwiftUI

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class OverlayController {
    let panel: FloatingPanel
    let model: SessionModel

    private static let frameDefaultsKey = "threadline.panel.frame"
    private static let defaultSize = NSSize(width: 880, height: 520)

    init(model: SessionModel) {
        self.model = model
        let initialFrame = OverlayController.restoredFrame()
        let panel = FloatingPanel(
            contentRect: initialFrame,
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "Threadline"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        let host = NSHostingView(rootView: ContentView(model: model))
        host.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = host
        panel.minSize = NSSize(width: 520, height: 320)
        panel.setFrameAutosaveName("ThreadlinePanel")
        panel.delegate = OverlayController.persistenceDelegate

        self.panel = panel
    }

    func toggle() {
        if panel.isVisible {
            persistFrame()
            panel.orderOut(nil)
        } else {
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func show() {
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hide() {
        persistFrame()
        panel.orderOut(nil)
    }

    private func persistFrame() {
        let f = panel.frame
        UserDefaults.standard.set(NSStringFromRect(f),
                                  forKey: OverlayController.frameDefaultsKey)
    }

    // MARK: - frame persistence

    private static func restoredFrame() -> NSRect {
        if let s = UserDefaults.standard.string(forKey: frameDefaultsKey) {
            let r = NSRectFromString(s)
            if r.width > 200 && r.height > 200 { return r }
        }
        // Center on the main screen by default.
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let x = screen.midX - defaultSize.width / 2
        let y = screen.midY - defaultSize.height / 2
        return NSRect(origin: NSPoint(x: x, y: y), size: defaultSize)
    }

    /// Window delegate that writes the frame on every move/resize so we never
    /// drop a position the user just set.
    private static let persistenceDelegate = FramePersistenceDelegate()
}

private final class FramePersistenceDelegate: NSObject, NSWindowDelegate {
    private static let key = "threadline.panel.frame"

    func windowDidMove(_ notification: Notification) { save(notification) }
    func windowDidResize(_ notification: Notification) { save(notification) }
    func windowWillClose(_ notification: Notification) { save(notification) }

    private func save(_ note: Notification) {
        guard let w = note.object as? NSWindow else { return }
        UserDefaults.standard.set(NSStringFromRect(w.frame),
                                  forKey: FramePersistenceDelegate.key)
    }
}
