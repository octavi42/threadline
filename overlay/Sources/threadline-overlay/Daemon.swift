import AppKit
import Foundation
import Darwin

enum Daemon {
    private static var controller: OverlayController?
    private static var model: SessionModel?
    private static var listenerFD: Int32 = -1

    static func run() {
        // Single-instance guard: if a daemon is already listening, bail out.
        let probe = IPC.connect()
        if probe >= 0 {
            close(probe)
            FileHandle.standardError.write(Data("daemon already running\n".utf8))
            exit(0)
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let m = SessionModel()
        m.start()
        let c = OverlayController(model: m)
        model = m
        controller = c

        startSocketListener()

        app.run()
    }

    private static func startSocketListener() {
        let fd = IPC.listen()
        guard fd >= 0 else {
            FileHandle.standardError.write(Data("failed to bind socket at \(IPC.socketPath)\n".utf8))
            exit(1)
        }
        listenerFD = fd

        // Accept loop on a background dispatch queue.
        DispatchQueue.global(qos: .utility).async {
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 { continue }
                DispatchQueue.global(qos: .userInitiated).async {
                    handleClient(client)
                }
            }
        }
    }

    private static func handleClient(_ client: Int32) {
        guard let line = IPC.readLine(client) else {
            close(client); return
        }
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        let cmd = parts.first ?? ""
        let rest = parts.count > 1 ? parts[1] : ""
        // `touch` is the hot path (every shell prompt) — handle off the main
        // thread to avoid any UI contention.
        if cmd == "touch" {
            handleTouch(payload: rest)
            IPC.writeLine(client, "ok")
            close(client)
            return
        }
        DispatchQueue.main.async {
            let reply = dispatch(cmd: cmd)
            IPC.writeLine(client, reply)
            close(client)
        }
    }

    private static func handleTouch(payload: String) {
        guard let data = payload.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        guard let cwd = obj["cwd"] as? String,
              let pidNum = obj["pid"] as? Int
        else { return }
        ShellRegistry.shared.touch(pid: pid_t(pidNum), cwd: cwd)
    }

    private static func dispatch(cmd: String) -> String {
        guard let c = controller else { return "no controller" }
        switch cmd {
        case "toggle":
            c.toggle();   return "ok"
        case "show":
            c.show();     return "ok"
        case "hide":
            c.hide();     return "ok"
        case "refresh":
            model?.refresh(); return "ok"
        case "status":
            let f = c.panel.frame
            let target = WindowFinder.frontmostTarget()
            let anchorPid = target.map { "\($0.appName)(pid=\($0.pid))" } ?? "no-anchor"
            let scope = target.flatMap { ShellRegistry.shared.scopeCwd(terminalPid: $0.pid) } ?? "—"
            let reg = ShellRegistry.shared.count()
            return "running pid=\(getpid()) visible=\(c.panel.isVisible) panel=\(Int(f.origin.x)),\(Int(f.origin.y)),\(Int(f.width))x\(Int(f.height)) anchor=\(anchorPid) scope=\(scope) shells=\(reg)"
        case "quit":
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
            return "bye"
        default:
            return "unknown: \(cmd)"
        }
    }
}
