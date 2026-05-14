import AppKit
import Foundation
import Combine
import SwiftUI

enum SourceState: String, Equatable {
    case running    // assistant turn in progress
    case awaiting   // user input expected
    case idle       // recently finished
    case error      // approval pending / error
    case stale      // not updated for a while
    case none       // no session found
}

struct SourceSnapshot: Identifiable, Equatable {
    let id: String              // tool name, used as identifier
    let tool: String            // "Claude", "Codex", "Cursor"
    let badge: String           // "CLD" | "CDX" | "CUR"
    var state: SourceState = .none
    var cwd: String?
    var model: String?
    var currentTask: String?    // active TODO item, if any
    var lastTool: String?       // "Edit Panel.swift"
    var lastText: String?       // fallback when there's no task/tool
    var branch: String?
    var dirtyCount: Int?        // git status --porcelain count
    var contextPercent: Double? // 0.0…1.0
    var costUSD: Double?
    var updatedAt: Date?
    var note: String?           // "no session" / "error: …" surfaced inline

    /// The most informative single-line label to show on the activity row.
    var activityLine: String {
        if let task = currentTask, !task.isEmpty { return task }
        if let tool = lastTool, !tool.isEmpty { return tool }
        if let text = lastText, !text.isEmpty {
            return text.replacingOccurrences(of: "\n", with: " ")
        }
        if let note = note { return note }
        return "—"
    }

    /// Right-side metadata strip, middle-dot separated.
    var metricsLine: String {
        var parts: [String] = []
        if let m = model           { parts.append(shortModel(m)) }
        if let b = branch {
            parts.append(dirtyCount.map { $0 > 0 ? "\(b)+\($0)" : b } ?? b)
        }
        if let p = contextPercent  { parts.append(String(format: "%.0f%%", p * 100)) }
        if let c = costUSD, c > 0  { parts.append(String(format: "$%.2f", c)) }
        return parts.joined(separator: " · ")
    }

    /// Trailing short time-since-update marker.
    var timeAgoShort: String {
        guard let t = updatedAt else { return "—" }
        let s = Int(-t.timeIntervalSinceNow)
        if s < 5            { return "now" }
        if s < 60           { return "\(s)s" }
        if s < 3600         { return "\(s / 60)m" }
        if s < 86_400       { return "\(s / 3600)h" }
        return "\(s / 86_400)d"
    }

    private func shortModel(_ m: String) -> String {
        // "claude-opus-4-7" → "opus-4-7", "gpt-5-turbo" → "gpt-5"
        let lower = m.lowercased()
        if let r = lower.range(of: "claude-") { return String(lower[r.upperBound...]) }
        if let r = lower.range(of: "anthropic/") { return String(lower[r.upperBound...]) }
        return lower
    }
}

final class SessionModel: ObservableObject {
    @Published var snapshots: [SourceSnapshot] = []
    /// Background NSColor matching the currently anchored terminal.
    @Published var themeBackground: NSColor = TerminalTheme.fallback
    /// Whether the theme background is dark — drives text contrast in the view.
    @Published var themeIsDark: Bool = true
    /// Active scope cwd resolved from ShellRegistry; nil = global.
    @Published var scopeCwd: String?
    /// Tool currently foregrounded in the scope shell's TTY (Claude/Codex);
    /// nil when only a shell is foregrounded.
    @Published var activeTool: String?
    private var timer: Timer?

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func refresh() {
        let scope = scopeCwd
        let claude = ClaudeSource.read(scopeCwd: scope)
        let codex = CodexSource.read(scopeCwd: scope)
        let cursor = CursorSource.read(scopeCwd: scope)
        let next = [claude, codex, cursor]
        DispatchQueue.main.async { [weak self] in
            self?.snapshots = next
        }
    }

    /// Called by the controller each tick with the frontmost terminal PID.
    /// Resolves both the scope cwd AND the foregrounded tool in that tab.
    /// Falls back to passive discovery when the shell hook hasn't yet pinged.
    func setScope(terminalPid: pid_t?) {
        guard let pid = terminalPid else {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if self.scopeCwd != nil { self.scopeCwd = nil; self.refresh() }
                self.activeTool = nil
            }
            return
        }

        var nextCwd: String?
        var nextTool: String?

        if let scope = ShellRegistry.shared.scope(terminalPid: pid) {
            nextCwd = scope.cwd
            nextTool = ForegroundProcess.toolName(shellPid: scope.shellPid)
        }

        // If touch didn't tell us what tool is active, scan descendant shells
        // for a foregrounded AI tool. Cwd from registry still wins; tool from
        // discovery fills in when only the cwd was touched.
        if nextTool == nil {
            let matches = ShellDiscovery.activeMatches(under: pid)
            if let m = matches.first {
                nextTool = m.activeTool
                if nextCwd == nil { nextCwd = m.cwd }
            }
        }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            var cwdChanged = false
            if self.scopeCwd != nextCwd { self.scopeCwd = nextCwd; cwdChanged = true }
            if self.activeTool != nextTool { self.activeTool = nextTool }
            if cwdChanged { self.refresh() }
        }
    }

    /// Called by the controller whenever the anchor changes. Resolves the
    /// terminal's background color from its config and publishes it.
    func setAnchor(bundleID: String?) {
        let color = bundleID.map(TerminalTheme.backgroundColor(for:)) ?? TerminalTheme.fallback
        let dark = isDark(color)
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.themeBackground != color { self.themeBackground = color }
            if self.themeIsDark != dark      { self.themeIsDark = dark }
        }
    }

    private func isDark(_ c: NSColor) -> Bool {
        guard let srgb = c.usingColorSpace(.sRGB) else { return true }
        // Rec. 709 luminance.
        let lum = 0.2126 * srgb.redComponent
                + 0.7152 * srgb.greenComponent
                + 0.0722 * srgb.blueComponent
        return lum < 0.5
    }
}
