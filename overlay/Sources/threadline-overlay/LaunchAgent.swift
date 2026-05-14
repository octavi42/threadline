import Foundation

enum LaunchAgent {
    static let label = "com.threadline.overlay"

    static var plistPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/LaunchAgents/\(label).plist"
    }

    /// Where the installed binary lives. Stable across rebuilds so the plist
    /// doesn't need rewriting.
    static var installedBinaryPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.local/bin/threadline-overlay"
    }

    /// Absolute path of the currently running binary.
    static func currentBinaryPath() -> String {
        let argv0 = CommandLine.arguments[0]
        if argv0.hasPrefix("/") { return argv0 }
        let cwd = FileManager.default.currentDirectoryPath
        return (cwd as NSString).appendingPathComponent(argv0)
    }

    /// True if our LaunchAgent plist is on disk.
    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: plistPath)
    }

    /// Idempotent: copy the binary to a stable path, write the plist, bootstrap launchd.
    static func install() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let target = installedBinaryPath
        let targetDir = (target as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: targetDir,
                                                 withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: "\(home)/.threadline",
                                                 withIntermediateDirectories: true)

        // Copy ourselves to the install path (replace if newer / different).
        let current = currentBinaryPath()
        if current != target {
            if FileManager.default.fileExists(atPath: target) {
                try? FileManager.default.removeItem(atPath: target)
            }
            do {
                try FileManager.default.copyItem(atPath: current, toPath: target)
                _ = chmod(target, 0o755)
                // macOS Sequoia+ rejects ad-hoc signed binaries after `cp`
                // because the signature is tied to the originating inode.
                // Re-sign the copy so AppleSystemPolicy allows it to launch.
                resignAdHoc(at: target)
            } catch {
                FileHandle.standardError.write(Data("failed to copy binary to \(target): \(error)\n".utf8))
            }
        }

        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [target, "daemon"],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "ProcessType": "Interactive",
            "StandardOutPath": "\(home)/.threadline/overlay.log",
            "StandardErrorPath": "\(home)/.threadline/overlay.log"
        ]
        let plistDir = (plistPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: plistDir,
                                                 withIntermediateDirectories: true)
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: plist,
                                                          format: .xml, options: 0)
            try data.write(to: URL(fileURLWithPath: plistPath))
        } catch {
            FileHandle.standardError.write(Data("failed to write plist: \(error)\n".utf8))
            exit(1)
        }

        let uid = getuid()
        _ = runLaunchctl(["bootout",   "gui/\(uid)/\(label)"])
        let rc = runLaunchctl(["bootstrap", "gui/\(uid)", plistPath])
        if rc != 0 {
            FileHandle.standardError.write(Data("launchctl bootstrap failed (rc=\(rc))\n".utf8))
        }
        _ = runLaunchctl(["kickstart", "-k", "gui/\(uid)/\(label)"])
        print("installed → \(target)")
        print("plist     → \(plistPath)")

        let modifiedShellFiles = ShellHook.install(binaryPath: target)
        if !modifiedShellFiles.isEmpty {
            print("shell hook → \(modifiedShellFiles.joined(separator: ", "))")
            print("            (open a new shell to activate it)")
        }

        print("\nadd ~/.local/bin to PATH if you haven't:")
        print("  echo 'export PATH=\"$HOME/.local/bin:$PATH\"' >> ~/.zshrc")
    }

    static func uninstall() {
        let uid = getuid()
        _ = runLaunchctl(["bootout", "gui/\(uid)/\(label)"])
        try? FileManager.default.removeItem(atPath: plistPath)
        let removedFrom = ShellHook.uninstall()
        if !removedFrom.isEmpty {
            print("removed shell hook from: \(removedFrom.joined(separator: ", "))")
        }
        print("uninstalled")
    }

    private static func resignAdHoc(at path: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        p.arguments = ["--force", "--sign", "-", path]
        p.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
        p.standardError = FileHandle(forWritingAtPath: "/dev/null")
        do { try p.run() } catch { return }
        p.waitUntilExit()
    }

    @discardableResult
    private static func runLaunchctl(_ args: [String]) -> Int32 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = args
        task.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
        task.standardError = FileHandle(forWritingAtPath: "/dev/null")
        do { try task.run() } catch { return -1 }
        task.waitUntilExit()
        return task.terminationStatus
    }
}
