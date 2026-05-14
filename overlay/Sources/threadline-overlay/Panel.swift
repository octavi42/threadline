import AppKit
import SwiftUI

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class OverlayController {
    let panel: FloatingPanel
    let model: SessionModel

    /// Height of the panel banner (width is taken from the terminal window).
    private let bannerHeight: CGFloat = 92

    /// Persistent on/off: when true, the panel follows the frontmost terminal.
    private var followEnabled: Bool = false
    /// One-shot peek: panel shows even if the next anchor would otherwise hide
    /// it, until `peekUntil`. Auto-dismiss on app switch is still handled by
    /// the follow loop (target disappears → panel hides).
    private var peekUntil: Date?

    private var tickTimer: Timer?

    init(model: SessionModel) {
        self.model = model
        let initialSize = NSSize(width: 600, height: bannerHeight)
        let panel = FloatingPanel(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: [.nonactivatingPanel, .hudWindow, .utilityWindow, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.worksWhenModal = true
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        let host = NSHostingView(rootView: ContentView(model: model))
        host.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = host

        self.panel = panel
        startTickTimer()
    }

    // MARK: - public commands

    func toggle() {
        followEnabled.toggle()
        peekUntil = nil
        if !followEnabled { panel.orderOut(nil) }
        applyState()
    }

    func show() {
        peekUntil = Date().addingTimeInterval(8)
        applyState()
    }

    func hide() {
        followEnabled = false
        peekUntil = nil
        panel.orderOut(nil)
    }

    // MARK: - tracking

    private func startTickTimer() {
        // 15 Hz is smooth enough for window drags without burning CPU on idle.
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in
            self?.applyState()
        }
    }

    private func shouldBeVisible() -> Bool {
        if followEnabled { return true }
        if let until = peekUntil, Date() < until { return true }
        return false
    }

    private func applyState() {
        guard shouldBeVisible() else {
            if panel.isVisible { panel.orderOut(nil) }
            return
        }
        guard let target = WindowFinder.frontmostTarget() else {
            // No terminal frontmost: hide while follow-mode is on; otherwise
            // (peek), show at top-of-screen as a fallback so the user sees
            // something during `show`.
            if followEnabled {
                if panel.isVisible { panel.orderOut(nil) }
            } else {
                if !panel.isVisible { panel.orderFrontRegardless() }
                positionTopOfScreen()
            }
            return
        }
        anchor(to: target)
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    /// Pin the panel to the top of the terminal window: same X, same width,
    /// top edges aligned. The panel overlays the top `bannerHeight` pixels of
    /// the terminal. Same z-order rule applies (panel is `.statusBar` level,
    /// so it stays visually on top).
    private func anchor(to t: WindowFinder.Target) {
        let cg = t.frame
        let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.main
        let primaryH = primary?.frame.height ?? cg.maxY
        let terminalTopAppKit = primaryH - cg.origin.y
        let newFrame = NSRect(x: cg.origin.x,
                              y: terminalTopAppKit - bannerHeight,
                              width: cg.width,
                              height: bannerHeight)
        if panel.frame != newFrame {
            panel.setFrame(newFrame, display: true, animate: false)
        }
    }

    private func positionTopOfScreen() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let w: CGFloat = max(520, panel.frame.width)
        let h = bannerHeight
        panel.setFrame(NSRect(x: visible.midX - w / 2,
                              y: visible.maxY - h - 8,
                              width: w, height: h),
                       display: true, animate: false)
    }
}
