import AppKit
import Darwin
import Foundation

enum JumpBack {
    struct Result {
        let appName: String
        let exactTab: Bool
        let detail: String
    }

    /// Resolved jump target after merging snapshot fields with live process identity.
    struct Route: Equatable {
        enum Kind: Equatable {
            case terminal
            case cursorWorkspace
        }

        let kind: Kind
        var bundleID: String?
        var appPID: pid_t?
        var tty: String?
        var cwd: String?
        var surfaceID: String?
        var agentPid: pid_t?
        var titleHint: String?
        var activityHint: String?
    }

    private static let cursorBundleIDs: Set<String> = [
        "com.todesktop.230313mzl4w4u92",
        "com.todesktop.230313mzl4w4u92-insider",
    ]

    private static let terminalJumpBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.googlecode.iterm2.beta",
        "com.mitchellh.ghostty",
    ]

    static func canJump(to snapshot: SourceSnapshot?) -> Bool {
        guard let snapshot = snapshot else { return false }
        let route = resolveRoute(for: snapshot)
        switch route.kind {
        case .terminal:
            return route.bundleID != nil && hasTerminalRoute(route)
        case .cursorWorkspace:
            if runningCursorApp() != nil { return true }
            guard let cwd = route.cwd, !cwd.isEmpty else { return false }
            return cursorIsInstalled()
        }
    }

    static func jumpLabel(for snapshot: SourceSnapshot) -> String {
        let route = resolveRoute(for: snapshot)
        switch route.kind {
        case .terminal:
            guard let bundleID = route.bundleID else { return "No terminal identity yet" }
            switch bundleID {
            case "com.mitchellh.ghostty":
                if route.surfaceID != nil { return "Open Ghostty tab (surface id)" }
                if route.tty != nil { return "Open Ghostty tab (tty)" }
                if route.agentPid != nil { return "Open Ghostty tab (agent pid)" }
                if route.cwd != nil {
                    return "Open Ghostty tab — focus it once if jump fails on duplicate tabs"
                }
                return "No Ghostty terminal identity yet"
            case "com.apple.Terminal",
                 "com.googlecode.iterm2",
                 "com.googlecode.iterm2.beta":
                if route.tty != nil { return "Open terminal tab (tty)" }
                return "No exact terminal TTY yet"
            default:
                return "Exact jump is not supported for this terminal"
            }
        case .cursorWorkspace:
            if let cwd = route.cwd, !cwd.isEmpty {
                return "Open Cursor workspace (\((cwd as NSString).lastPathComponent))"
            }
            return "Open Cursor"
        }
    }

    /// Human-readable route dump for CLI debugging (`jump-debug`).
    static func debugDescription(for snapshot: SourceSnapshot) -> String {
        let route = resolveRoute(for: snapshot)
        var lines = [
            "tool=\(snapshot.tool)",
            "kind=\(route.kind)",
            "agentPid=\(route.agentPid.map(String.init) ?? "-")",
            "bundle=\(route.bundleID ?? "-")",
            "appPid=\(route.appPID.map(String.init) ?? "-")",
            "tty=\(route.tty ?? "-")",
            "surface=\(route.surfaceID ?? "-")",
            "cwd=\(route.cwd ?? "-")",
            "canJump=\(canJump(to: snapshot))",
            "label=\(jumpLabel(for: snapshot))",
        ]
        if let preview = jump(to: snapshot, dryRun: true) {
            lines.append("dryRun=\(preview.detail) exact=\(preview.exactTab)")
        } else {
            lines.append("dryRun=nil")
        }
        return lines.joined(separator: "\n")
    }

    static func jump(to snapshot: SourceSnapshot?) -> Result? {
        jump(to: snapshot, dryRun: false)
    }

    static func jump(to snapshot: SourceSnapshot?, dryRun: Bool) -> Result? {
        guard let snapshot = snapshot else { return nil }
        let route = resolveRoute(for: snapshot)

        switch route.kind {
        case .terminal:
            guard let app = terminalApp(for: route),
                  let bundleID = route.bundleID,
                  hasTerminalRoute(route)
            else { return nil }

            let focus = focusExactTabIfPossible(bundleID: bundleID,
                                                tty: route.tty,
                                                cwd: route.cwd,
                                                titleHint: route.titleHint,
                                                activityHint: route.activityHint,
                                                surfaceID: route.surfaceID,
                                                agentPid: route.agentPid,
                                                dryRun: dryRun)
            let routeDetail = routeDebugSuffix(route)
            guard focus.exact else {
                return Result(appName: app.localizedName ?? bundleID,
                              exactTab: false,
                              detail: "\(focus.detail) \(routeDetail)")
            }
            if !dryRun {
                app.activate(options: [.activateIgnoringOtherApps])
            }
            return Result(appName: app.localizedName ?? bundleID,
                          exactTab: true,
                          detail: "\(focus.detail) \(routeDetail)")

        case .cursorWorkspace:
            return activateCursor(cwd: route.cwd, dryRun: dryRun)
        }
    }

    static func resolveRoute(for snapshot: SourceSnapshot) -> Route {
        var tty = TerminalIdentityResolver.normalizeTTY(snapshot.tty)
        var bundleID = snapshot.terminalBundleID
        var appPID = snapshot.terminalPID
        var surfaceID = snapshot.terminalSurfaceID
        let cwd = snapshot.cwd
        let agentPid = snapshot.livePid
        let titleHint = ghosttyTitleHint(for: snapshot)
        let activityHint = snapshot.activityLine == "—" ? nil : snapshot.activityLine

        if let agentPid = agentPid {
            if let shell = ShellRegistry.shared.shell(forDescendant: agentPid) {
                tty = tty ?? TerminalIdentityResolver.normalizeTTY(shell.tty)
                bundleID = bundleID ?? shell.terminal?.bundleID
                appPID = appPID ?? shell.terminal?.appPID
                surfaceID = surfaceID ?? shell.terminal?.surfaceID
            }
            if surfaceID == nil, let shellPid = directShellPid(for: agentPid),
               let shell = ShellRegistry.shared.shell(forShellPid: shellPid) {
                tty = tty ?? TerminalIdentityResolver.normalizeTTY(shell.tty)
                bundleID = bundleID ?? shell.terminal?.bundleID
                appPID = appPID ?? shell.terminal?.appPID
                surfaceID = surfaceID ?? shell.terminal?.surfaceID
            }
            if bundleID == nil || tty == nil || surfaceID == nil,
               let terminal = TerminalIdentityResolver.resolve(agentPid: agentPid, cwd: cwd) {
                bundleID = bundleID ?? terminal.bundleID
                appPID = appPID ?? terminal.appPID
                tty = tty ?? TerminalIdentityResolver.normalizeTTY(terminal.tty)
                surfaceID = surfaceID ?? terminal.surfaceID
            }
            if tty == nil {
                tty = TerminalIdentityResolver.normalizeTTY(TerminalIdentityResolver.processTTY(pid: agentPid))
            }
            if surfaceID == nil, let tty = tty {
                surfaceID = ShellRegistry.shared.terminalIdentity(matchingTTY: tty)?.surfaceID
            }
            if bundleID == nil, let app = owningTerminalApp(forDescendant: agentPid) {
                bundleID = app.bundleIdentifier
                appPID = appPID ?? app.processIdentifier
            }
        }

        if let bundleID = bundleID,
           terminalJumpBundleIDs.contains(bundleID),
           hasTerminalRoute(Route(kind: .terminal,
                                  bundleID: bundleID,
                                  appPID: appPID,
                                  tty: tty,
                                  cwd: cwd,
                                  surfaceID: surfaceID,
                                  agentPid: agentPid,
                                  titleHint: titleHint,
                                  activityHint: activityHint)) {
            return Route(kind: .terminal,
                         bundleID: bundleID,
                         appPID: appPID,
                         tty: tty,
                         cwd: cwd,
                         surfaceID: surfaceID,
                         agentPid: agentPid,
                         titleHint: titleHint,
                         activityHint: activityHint)
        }

        if snapshot.tool == "Cursor" || bundleID.map(cursorBundleIDs.contains) == true {
            return Route(kind: .cursorWorkspace,
                         bundleID: bundleID,
                         appPID: appPID,
                         tty: tty,
                         cwd: cwd,
                         surfaceID: surfaceID,
                         agentPid: agentPid,
                         titleHint: titleHint,
                         activityHint: activityHint)
        }

        if bundleID != nil {
            return Route(kind: .terminal,
                         bundleID: bundleID,
                         appPID: appPID,
                         tty: tty,
                         cwd: cwd,
                         surfaceID: surfaceID,
                         agentPid: agentPid,
                         titleHint: titleHint,
                         activityHint: activityHint)
        }

        return Route(kind: .cursorWorkspace,
                     bundleID: bundleID,
                     appPID: appPID,
                     tty: tty,
                     cwd: cwd,
                     surfaceID: surfaceID,
                     agentPid: agentPid,
                     titleHint: titleHint,
                     activityHint: activityHint)
    }

    private static func hasTerminalRoute(_ route: Route) -> Bool {
        guard let bundleID = route.bundleID else { return false }
        switch bundleID {
        case "com.apple.Terminal",
             "com.googlecode.iterm2",
             "com.googlecode.iterm2.beta":
            return route.tty != nil
        case "com.mitchellh.ghostty":
            return route.surfaceID != nil || route.tty != nil || route.agentPid != nil || route.cwd != nil
        default:
            return false
        }
    }

    private static func ghosttyTitleHint(for snapshot: SourceSnapshot) -> String? {
        let raw = snapshot.currentTask
            ?? snapshot.jsonlPath.flatMap(Summarizer.extractOpeningGoal)
            ?? snapshot.lastText
        guard let raw = raw else { return nil }
        let compact = SourceSnapshot.compactLine(raw, limit: 80, maxWords: 12, firstSentence: false)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return compact.isEmpty || compact == "—" ? nil : compact
    }

    private static func terminalApp(for route: Route) -> NSRunningApplication? {
        if let pid = route.appPID,
           let app = NSRunningApplication(processIdentifier: pid) {
            return app
        }
        if let agentPid = route.agentPid {
            return owningTerminalApp(forDescendant: agentPid)
        }
        return nil
    }

    private static func owningTerminalApp(forDescendant pid: pid_t) -> NSRunningApplication? {
        let running = NSWorkspace.shared.runningApplications
        var appsByPID: [pid_t: NSRunningApplication] = [:]
        for app in running where app.processIdentifier > 0 {
            appsByPID[app.processIdentifier] = app
        }
        var current = pid
        for _ in 0..<48 {
            if let app = appsByPID[current],
               let bid = app.bundleIdentifier,
               terminalJumpBundleIDs.contains(bid) || WindowFinder.targetBundleIDs.contains(bid) {
                return app
            }
            let parent = parentPID(of: current)
            if parent <= 1 { return nil }
            current = parent
        }
        return nil
    }

    private static func runningCursorApp() -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier.map(cursorBundleIDs.contains) ?? false
        }
    }

    private static func cursorIsInstalled() -> Bool {
        cursorBundleIDs.contains {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil
        }
    }

    private static func activateCursor(cwd: String?, dryRun: Bool) -> Result? {
        if dryRun {
            if cwd != nil {
                return Result(appName: "Cursor", exactTab: true, detail: "workspace")
            }
            if runningCursorApp() != nil {
                return Result(appName: "Cursor", exactTab: false, detail: "app-only")
            }
            return nil
        }

        var exact = false
        let detail = "workspace"

        if let cwd = cwd, !cwd.isEmpty {
            if openCursorWorkspace(cwd: cwd) || focusCursorWindow(matching: cwd) {
                exact = true
            }
            runningCursorApp()?.activate(options: [.activateIgnoringOtherApps])
            if exact {
                return Result(appName: "Cursor", exactTab: true, detail: detail)
            }
        }

        if let app = runningCursorApp() {
            app.activate(options: [.activateIgnoringOtherApps])
            return Result(appName: app.localizedName ?? "Cursor",
                          exactTab: false,
                          detail: "app-only")
        }

        guard let cwd = cwd else { return nil }
        for bundleID in cursorBundleIDs where openWorkspace(cwd: cwd, bundleID: bundleID) {
            return Result(appName: "Cursor", exactTab: false, detail: "workspace-open")
        }
        return nil
    }

    private static func openCursorWorkspace(cwd: String) -> Bool {
        let standardized = (cwd as NSString).standardizingPath
        for candidate in cursorCLIPaths() {
            guard FileManager.default.isExecutableFile(atPath: candidate) else { continue }
            let task = Process()
            task.executableURL = URL(fileURLWithPath: candidate)
            task.arguments = ["-r", standardized]
            task.standardOutput = Pipe()
            task.standardError = Pipe()
            do {
                try task.run()
                task.waitUntilExit()
                if task.terminationStatus == 0 { return true }
            } catch {
                continue
            }
        }
        return false
    }

    private static func cursorCLIPaths() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var paths = [
            "\(home)/.local/bin/cursor",
            "/Applications/Cursor.app/Contents/Resources/app/bin/cursor",
            "/usr/local/bin/cursor",
        ]
        if let which = runCommand("/usr/bin/which", args: ["cursor"]), !which.isEmpty {
            paths.insert(which, at: 0)
        }
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }

    private static func focusCursorWindow(matching cwd: String) -> Bool {
        let folder = appleScriptString((cwd as NSString).lastPathComponent)
        let tilde = appleScriptString((cwd as NSString).abbreviatingWithTildeInPath)
        let script = """
        tell application "System Events"
            if not (exists process "Cursor") then return "not found"
            tell process "Cursor"
                repeat with w in windows
                    set t to name of w
                    if t contains "\(folder)" or t contains "\(tilde)" then
                        perform action "AXRaise" of w
                        set frontmost to true
                        return "ok"
                    end if
                end repeat
            end tell
        end tell
        return "not found"
        """
        return runAppleScript(script)
    }

    private static func openWorkspace(cwd: String, bundleID: String) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-b", bundleID, (cwd as NSString).standardizingPath]
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return false
        }
    }

    @discardableResult
    private static func focusExactTabIfPossible(bundleID: String?,
                                                tty: String?,
                                                cwd: String?,
                                                titleHint: String?,
                                                activityHint: String?,
                                                surfaceID: String?,
                                                agentPid: pid_t?,
                                                dryRun: Bool) -> (exact: Bool, detail: String) {
        guard let bundleID = bundleID, !bundleID.isEmpty else { return (false, "missing-bundle") }
        if dryRun {
            switch bundleID {
            case "com.apple.Terminal", "com.googlecode.iterm2", "com.googlecode.iterm2.beta":
                return tty == nil ? (false, "missing-tty") : (true, "tty")
            case "com.mitchellh.ghostty":
                if surfaceID != nil { return (true, "surface-id") }
                if pickGhosttySurface(cwd: cwd, titleHint: titleHint, activityHint: activityHint) != nil {
                    return (true, "ghostty-disambiguated")
                }
                if let cwd = cwd, !cwd.isEmpty {
                    let matches = listGhosttyTerminals().filter {
                        ($0.cwd as NSString).standardizingPath == (cwd as NSString).standardizingPath
                    }
                    if matches.count == 1 { return (true, "unique-cwd") }
                }
                return (false, "ambiguous-ghostty")
            default:
                return (false, "unsupported-terminal")
            }
        }

        switch bundleID {
        case "com.apple.Terminal":
            guard let tty = tty else { return (false, "missing-tty") }
            return runTTYAppleScript({ terminalScript(tty: $0) }, tty: tty)
                ? (true, "tty") : (false, "tty-not-found")
        case "com.googlecode.iterm2":
            guard let tty = tty else { return (false, "missing-tty") }
            return runTTYAppleScript({ iTermScript(appName: "iTerm2", tty: $0) }, tty: tty)
                ? (true, "tty") : (false, "tty-not-found")
        case "com.googlecode.iterm2.beta":
            guard let tty = tty else { return (false, "missing-tty") }
            return runTTYAppleScript({ iTermScript(appName: "iTerm", tty: $0) }, tty: tty)
                ? (true, "tty") : (false, "tty-not-found")
        case "com.mitchellh.ghostty":
            if let surfaceID = surfaceID, !surfaceID.isEmpty,
               runAppleScript(ghosttySurfaceScript(surfaceID: surfaceID)) {
                return (true, "surface-id")
            }
            if let tty = tty,
               runTTYAppleScript({ ghosttyTTYScript(tty: $0) }, tty: tty) {
                return (true, "ghostty-tty")
            }
            if let agentPid = agentPid,
               runAppleScript(ghosttyAgentPidScript(agentPid: agentPid)) {
                return (true, "ghostty-agent-pid")
            }
            if let picked = pickGhosttySurface(cwd: cwd,
                                               titleHint: titleHint,
                                               activityHint: activityHint) {
                return runAppleScript(ghosttySurfaceScript(surfaceID: picked))
                    ? (true, "ghostty-disambiguated")
                    : (false, "ghostty-disambiguation-failed")
            }
            guard let cwd = cwd, !cwd.isEmpty else { return (false, "missing-ghostty-route") }
            if let titleHint = titleHint, !titleHint.isEmpty,
               runAppleScript(ghosttyTitleAndCwdScript(cwd: (cwd as NSString).standardizingPath,
                                                       titleHint: titleHint)) {
                return (true, "title+cwd")
            }
            return runAppleScript(ghosttyUniqueCwdScript(cwd: (cwd as NSString).standardizingPath))
                ? (true, "unique-cwd")
                : (false, "ambiguous-or-missing-cwd")
        default:
            return (false, "unsupported-terminal")
        }
    }

    private static func ttyForms(_ tty: String) -> [String] {
        let normalized = TerminalIdentityResolver.normalizeTTY(tty) ?? tty
        let stripped = normalized.hasPrefix("/dev/") ? String(normalized.dropFirst(5)) : normalized
        return Array(Set([normalized, stripped, "/dev/\(stripped)"]))
    }

    private static func runTTYAppleScript(_ builder: (String) -> String, tty: String) -> Bool {
        for form in ttyForms(tty) where runAppleScript(builder(form)) {
            return true
        }
        return false
    }

    private static func terminalScript(tty: String) -> String {
        let tty = appleScriptString(tty)
        return """
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "\(tty)" then
                        set selected tab of w to t
                        set index of w to 1
                        activate
                        return "ok"
                    end if
                end repeat
            end repeat
        end tell
        return "not found"
        """
    }

    private static func iTermScript(appName: String, tty: String) -> String {
        let appName = appleScriptString(appName)
        let tty = appleScriptString(tty)
        return """
        tell application "\(appName)"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s is "\(tty)" then
                            select t
                            select w
                            activate
                            return "ok"
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        return "not found"
        """
    }

    private static func ghosttySurfaceScript(surfaceID: String) -> String {
        let surfaceID = appleScriptString(surfaceID)
        return """
        tell application "Ghostty"
            repeat with term in terminals
                if id of term is "\(surfaceID)" then
                    focus term
                    activate
                    return "ok"
                end if
            end repeat
        end tell
        return "not found"
        """
    }

    private static func ghosttyTTYScript(tty: String) -> String {
        let tty = appleScriptString(tty)
        return """
        tell application "Ghostty"
            repeat with term in terminals
                try
                    if tty of term is "\(tty)" then
                        focus term
                        activate
                        return "ok"
                    end if
                end try
            end repeat
        end tell
        return "not found"
        """
    }

    private static func ghosttyAgentPidScript(agentPid: pid_t) -> String {
        """
        tell application "Ghostty"
            repeat with term in terminals
                try
                    if pid of term is \(agentPid) then
                        focus term
                        activate
                        return "ok"
                    end if
                end try
            end repeat
        end tell
        return "not found"
        """
    }

    private static func ghosttyUniqueCwdScript(cwd: String) -> String {
        let cwd = appleScriptString(cwd)
        return """
        tell application "Ghostty"
            set matches to {}
            repeat with term in terminals
                if working directory of term is "\(cwd)" then
                    set end of matches to term
                end if
            end repeat
            if (count of matches) is 1 then
                focus item 1 of matches
                activate
                return "ok"
            end if
        end tell
        return "not found"
        """
    }

    private static func listGhosttyTerminals() -> [(id: String, cwd: String, name: String)] {
        let script = """
        tell application "Ghostty"
            set out to {}
            repeat with term in terminals
                set end of out to ((id of term) & "|" & (working directory of term) & "|" & (name of term))
            end repeat
            set AppleScript's text item delimiters to linefeed
            return out as text
        end tell
        """
        guard let raw = runAppleScriptOutput(script) else { return [] }
        return raw.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 3 else { return nil }
            return (id: parts[0], cwd: parts[1], name: parts[2])
        }
    }

    private static func pickGhosttySurface(cwd: String?,
                                           titleHint: String?,
                                           activityHint: String?) -> String? {
        let candidates = listGhosttyTerminals()
        guard !candidates.isEmpty else { return nil }

        let expectedCwd = cwd.map { ($0 as NSString).standardizingPath }
        let scoped = expectedCwd.map { path in
            candidates.filter { ($0.cwd as NSString).standardizingPath == path }
        } ?? candidates

        if scoped.count == 1 { return scoped[0].id }

        let hints = [titleHint, activityHint]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        for hint in hints {
            let matches = scoped.filter { $0.name.localizedCaseInsensitiveContains(hint) }
            if matches.count == 1 { return matches[0].id }
        }

        let words = tokenWords(from: hints.joined(separator: " "))
        guard words.count >= 2 else { return nil }

        let scored = scoped.map { candidate -> (id: String, score: Int) in
            let nameWords = tokenWords(from: candidate.name)
            return (candidate.id, nameWords.intersection(words).count)
        }
        guard let best = scored.max(by: { $0.score < $1.score }), best.score >= 2 else { return nil }
        let ties = scored.filter { $0.score == best.score }
        guard ties.count == 1 else { return nil }
        return best.id
    }

    private static func tokenWords(from text: String) -> Set<String> {
        Set(
            text
                .lowercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
                .filter { $0.count > 3 }
        )
    }

    private static func directShellPid(for agentPid: pid_t) -> pid_t? {
        var current = agentPid
        for _ in 0..<48 {
            let comm = ProcTable.commName(forPID: current)?.lowercased() ?? ""
            if comm == "bash" || comm == "zsh" || comm == "fish" || comm == "sh" {
                return current
            }
            let parent = parentPID(of: current)
            if parent <= 1 { return nil }
            current = parent
        }
        return nil
    }

    private static func ghosttyTitleAndCwdScript(cwd: String, titleHint: String) -> String {
        let cwd = appleScriptString(cwd)
        let titleHint = appleScriptString(titleHint)
        return """
        tell application "Ghostty"
            set matches to {}
            repeat with term in terminals
                if working directory of term is "\(cwd)" and name of term contains "\(titleHint)" then
                    set end of matches to term
                end if
            end repeat
            if (count of matches) is 1 then
                focus item 1 of matches
                activate
                return "ok"
            end if
        end tell
        return "not found"
        """
    }

    private static func routeDebugSuffix(_ route: Route) -> String {
        [
            "pid=\(route.agentPid.map(String.init) ?? "-")",
            "bundle=\(route.bundleID ?? "-")",
            "tty=\(route.tty ?? "-")",
            "surface=\(route.surfaceID ?? "-")",
            "cwd=\(route.cwd ?? "-")",
        ].joined(separator: " ")
    }

    private static func runAppleScript(_ script: String) -> Bool {
        guard let out = runAppleScriptOutput(script) else { return false }
        return out.trimmingCharacters(in: .whitespacesAndNewlines) == "ok"
    }

    private static func runAppleScriptOutput(_ script: String) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
            let deadline = Date().addingTimeInterval(5.0)
            while task.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
            if task.isRunning {
                task.terminate()
                return nil
            }
            guard task.terminationStatus == 0 else { return nil }
            let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
            return String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    private static func runCommand(_ executable: String, args: [String]) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
            guard task.terminationStatus == 0 else { return nil }
            let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
            return String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    private static func appleScriptString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func parentPID(of pid: pid_t) -> pid_t {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var size = 0
        if sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) != 0 { return 0 }
        var info = kinfo_proc()
        size = MemoryLayout<kinfo_proc>.stride
        if sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) != 0 { return 0 }
        return info.kp_eproc.e_ppid
    }
}
