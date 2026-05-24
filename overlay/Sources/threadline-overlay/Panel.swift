import AppKit
import SwiftUI

final class ThreadlineWindow: NSWindow {
    var onReturnKey: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {
        // Return and keypad Enter jump back to the selected agent. Keep this
        // at the panel level so it works while focus is in the sidebar list.
        if OverlayController.isBareReturn(event) {
            onReturnKey?()
            return
        }
        super.keyDown(with: event)
    }
}

final class OverlayController {
    let panel: ThreadlineWindow
    let model: SessionModel
    private var returnKeyMonitor: Any?

    private static let frameDefaultsKey = "threadline.panel.frame"
    private static let defaultSize = NSSize(width: 880, height: 520)

    init(model: SessionModel) {
        self.model = model
        let initialFrame = OverlayController.restoredFrame()
        let panel = ThreadlineWindow(
            contentRect: initialFrame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "Threadline · local 4"
        panel.level = .normal
        panel.collectionBehavior = [.fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.titlebarAppearsTransparent = true
        panel.minSize = NSSize(width: 520, height: 320)
        panel.setFrameAutosaveName("ThreadlinePanel")
        panel.delegate = OverlayController.persistenceDelegate

        self.panel = panel
        let host = NSHostingView(rootView: ContentView(model: model) { [weak self] snap in
            _ = self?.jump(to: snap, hidePanel: false)
        })
        host.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = host
        panel.onReturnKey = { [weak self] in
            _ = self?.jumpToSelection()
        }
        returnKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self,
                  self.panel.isVisible,
                  event.window === self.panel,
                  Self.isBareReturn(event)
            else { return event }
            _ = self.jumpToSelection()
            return nil
        }
    }

    deinit {
        if let monitor = returnKeyMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    func toggle() {
        _ = focusFrontmostTerminalContext()
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if panel.isVisible && frontmostPID == getpid() {
            hidePanel(reason: "toggle-frontmost")
        } else {
            ensureOnScreen()
            OverlayLog.write("window show reason=toggle visibleBefore=\(panel.isVisible)")
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func show() {
        _ = focusFrontmostTerminalContext()
        ensureOnScreen()
        OverlayLog.write("window show reason=show visibleBefore=\(panel.isVisible)")
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func focus(cwd: String) -> Bool {
        model.selectSnapshot(cwd: cwd)
    }

    func focusFrontmostTerminalMessage() -> String {
        focusFrontmostTerminalContext()
    }

    func hide() {
        hidePanel(reason: "command-hide")
    }

    @discardableResult
    func jump(to snapshot: SourceSnapshot, hidePanel: Bool = true) -> Bool {
        guard let result = JumpBack.jump(to: snapshot) else {
            NSSound.beep()
            FileHandle.standardError.write(Data("jump failed: no exact terminal route\n".utf8))
            return false
        }
        guard result.exactTab else {
            NSSound.beep()
            FileHandle.standardError.write(Data("jump failed via \(result.detail)\n".utf8))
            return false
        }
        if hidePanel {
            self.hidePanel(reason: "jump")
        }
        FileHandle.standardError.write(Data("jumped to \(result.appName) via \(result.detail)\n".utf8))
        return true
    }

    @discardableResult
    func jumpToSelection() -> Bool {
        guard let snap = model.selectedSnapshot ?? model.selectedFolder?.latestSnapshot else {
            NSSound.beep()
            return false
        }
        return jump(to: snap)
    }

    func jumpToSelectionMessage() -> String {
        guard let snap = model.selectedSnapshot ?? model.selectedFolder?.latestSnapshot else {
            NSSound.beep()
            return "no jump target"
        }
        guard let result = JumpBack.jump(to: snap) else {
            NSSound.beep()
            return "no jump target"
        }
        guard result.exactTab else {
            NSSound.beep()
            return "jump failed via \(result.detail)"
        }
        hidePanel(reason: "jump-message")
        return "jumped to \(result.appName) via \(result.detail)"
    }

    func jumpDebugMessage() -> String {
        guard let snap = model.selectedSnapshot ?? model.selectedFolder?.latestSnapshot else {
            return "no jump target"
        }
        return JumpBack.debugDescription(for: snap)
    }

    @discardableResult
    private func focusFrontmostTerminalContext() -> String {
        guard let target = WindowFinder.frontmostTarget() else { return "no frontmost target" }
        if let terminal = TerminalIdentityResolver.focusedTerminal(for: target) {
            let before = model.selectedID
            let label = terminal.tty ?? terminal.surfaceID ?? terminal.cwd ?? "unknown"
            let ok = model.selectSnapshot(terminal: terminal)
            let after = model.selectedID ?? "none"
            return ok
                ? "selected focused terminal \(label) id=\(after)"
                : "no snapshot for focused terminal \(label) previous=\(before ?? "none")"
        }
        if let scope = ShellRegistry.shared.scope(terminalPid: target.pid) {
            return model.selectSnapshot(scope: scope)
                ? "selected \(scope.cwd) via touch"
                : "no session for touched cwd \(scope.cwd)"
        }
        if let match = ShellDiscovery.activeMatches(under: target.pid).first {
            return model.selectSnapshot(cwd: match.cwd, tool: match.activeTool)
                ? "selected \(match.cwd) via \(match.activeTool)"
                : "no snapshot for discovered cwd \(match.cwd)"
        }
        return "no shell scope for \(target.appName) pid=\(target.pid)"
    }

    private func persistFrame() {
        let f = panel.frame
        UserDefaults.standard.set(NSStringFromRect(f),
                                  forKey: OverlayController.frameDefaultsKey)
    }

    private func hidePanel(reason: String) {
        persistFrame()
        OverlayLog.write("window hide reason=\(reason) visibleBefore=\(panel.isVisible)")
        panel.orderOut(nil)
    }

    /// Saved frames from a disconnected monitor leave the window off-screen.
    private func ensureOnScreen() {
        let visible = NSScreen.screens.map(\.visibleFrame)
        guard !visible.contains(where: { $0.intersects(panel.frame) }) else { return }
        let target = NSScreen.main?.visibleFrame ?? visible[0]
        var frame = panel.frame
        frame.origin.x = target.midX - frame.width / 2
        frame.origin.y = target.midY - frame.height / 2
        panel.setFrame(frame, display: true)
    }

    fileprivate static func isBareReturn(_ event: NSEvent) -> Bool {
        event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty &&
        (event.keyCode == 36 || event.keyCode == 76)
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

    /// Hide instead of closing — keeps the daemon running for the next show/toggle.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        OverlayLog.write("window hide reason=close-button visibleBefore=\(sender.isVisible)")
        sender.orderOut(nil)
        return false
    }

    func windowDidMove(_ notification: Notification) { save(notification) }
    func windowDidResize(_ notification: Notification) { save(notification) }
    func windowWillClose(_ notification: Notification) { save(notification) }

    private func save(_ note: Notification) {
        guard let w = note.object as? NSWindow else { return }
        UserDefaults.standard.set(NSStringFromRect(w.frame),
                                  forKey: FramePersistenceDelegate.key)
    }
}
