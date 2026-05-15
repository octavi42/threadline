import Foundation

enum XRayError: Error, LocalizedError {
    case notInGitRepo
    case noChanges
    case noSession
    case binaryMissing
    case fetchFailed(String)
    case decodeFailed(String)

    var errorDescription: String? {
        switch self {
        case .notInGitRepo: return "Not inside a git repo."
        case .noChanges:    return "No changes vs HEAD."
        case .noSession:    return "No session JSONL found for this repo."
        case .binaryMissing:return "`threadline` CLI not on PATH. Install with: pip install -e ."
        case .fetchFailed(let s): return "Fetch failed: \(s)"
        case .decodeFailed(let s): return "Decode failed: \(s)"
        }
    }
}

enum XRayFetcher {
    /// Run `threadline xray --json` in the given cwd and decode the report.
    /// Uses a login shell so user PATH (pip-installed `threadline`) is picked up.
    static func fetch(
        cwd: String,
        base: String? = nil,
        session: String? = nil
    ) -> Result<XRayReport, XRayError> {
        var command = "threadline xray --json"
        if let base = base {
            command += " --base \(shellEscape(base))"
        }
        if let session = session {
            command += " --session \(shellEscape(session))"
        }

        let process = Process()
        process.launchPath = "/bin/bash"
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.arguments = ["-lc", command]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            return .failure(.fetchFailed(error.localizedDescription))
        }
        process.waitUntilExit()

        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errString = String(
            data: stderr.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""

        if errString.lowercased().contains("command not found") {
            return .failure(.binaryMissing)
        }
        if errString.contains("not inside a git repo") {
            return .failure(.notInGitRepo)
        }
        if errString.contains("no changes") {
            return .failure(.noChanges)
        }
        if errString.contains("no session JSONL found") {
            return .failure(.noSession)
        }
        if process.terminationStatus != 0 && outData.isEmpty {
            return .failure(.fetchFailed(errString.isEmpty ? "exit \(process.terminationStatus)" : errString))
        }
        if outData.isEmpty {
            return .failure(.fetchFailed("empty output"))
        }

        do {
            let report = try JSONDecoder().decode(XRayReport.self, from: outData)
            return .success(report)
        } catch {
            return .failure(.decodeFailed(error.localizedDescription))
        }
    }

    private static func shellEscape(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
