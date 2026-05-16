import AppKit

/// Locates the frontmost "target" window (terminals + Cursor + VS Code) and
/// returns its on-screen bounds. Uses CGWindowListCopyWindowInfo which exposes
/// owner PID and bounds without Accessibility or Screen Recording permission.
struct WindowFinder {
    /// Bundle IDs we treat as terminal/editor surfaces for shell scoping and
    /// jump-back behavior. Order doesn't matter.
    static let targetBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable",
        "io.alacritty",
        "org.alacritty",
        "net.kovidgoyal.kitty",
        "com.github.wez.wezterm",
        "co.zeit.hyper",
        "com.eugene.Tabby",
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.todesktop.230313mzl4w4u92",   // Cursor stable
        "com.todesktop.230313mzl4w4u92.helper", // (defensive)
    ]

    struct Target {
        let bundleID: String
        let appName: String
        let pid: pid_t
        let frame: CGRect       // CGWindow-space (top-left origin)
    }

    static func frontmostTarget() -> Target? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bid = app.bundleIdentifier,
              targetBundleIDs.contains(bid)
        else { return nil }

        let pid = app.processIdentifier
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        // Take the lowest-layer (= topmost in z-order) normal window owned by the app.
        var best: (rect: CGRect, layer: Int)?
        for w in raw {
            guard let owner = w[kCGWindowOwnerPID as String] as? Int32, owner == pid else { continue }
            guard let layer = w[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            guard let boundsDict = w[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { continue }
            // Filter tiny tooltips/utility windows.
            if rect.width < 200 || rect.height < 80 { continue }
            if best == nil || layer < best!.layer {
                best = (rect, layer)
            }
        }
        guard let pick = best else { return nil }
        return Target(bundleID: bid,
                      appName: app.localizedName ?? bid,
                      pid: pid,
                      frame: pick.rect)
    }

    /// Converts a CGWindow-space rect (top-left origin) into an AppKit screen rect
    /// (bottom-left origin), using the primary screen's height as anchor.
    static func appKitFrame(from cg: CGRect) -> NSRect {
        let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.main
        let primaryHeight = primary?.frame.height ?? cg.maxY
        return NSRect(x: cg.origin.x,
                      y: primaryHeight - cg.origin.y - cg.height,
                      width: cg.width,
                      height: cg.height)
    }
}
