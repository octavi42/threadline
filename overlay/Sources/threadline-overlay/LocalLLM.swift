import Foundation

/// Optional local summarizer/classifier via Ollama (`http://127.0.0.1:11434`).
///
/// Configure with env vars or `~/.threadline/config.json`: `ollama_host`, `ollama_model`.
/// Set `THREADLINE_DISABLE_OLLAMA=1` to skip entirely.
enum LocalLLM {
    private static let lock = NSLock()
    private static let probeLock = NSLock()
    private static var availability: Availability = .unknown
    private static var probeFinished = false
    private static var probeSucceeded = false
    private static var unavailableUntil: Date?
    /// Re-probe after a failed reachability check or chat HTTP failure.
    private static let retryInterval: TimeInterval = 5 * 60

    private enum Availability {
        case unknown
        case available
        case unavailable
    }

    static var statusLabel: String {
        if isExplicitlyDisabled { return "disabled" }
        lock.lock()
        let state = availability
        let retrying = unavailableUntil
        lock.unlock()
        switch state {
        case .available: return "on (\(model))"
        case .unavailable:
            if let until = retrying, Date() < until {
                return "unreachable"
            }
            return "off"
        case .unknown: return "checking"
        }
    }

    static func complete(system: String,
                         user: String,
                         maxTokens: Int,
                         timeout: TimeInterval = 15) -> String? {
        guard !isExplicitlyDisabled else { return nil }
        guard ensureAvailable(probeTimeout: 2) else { return nil }

        guard let url = URL(string: "\(host)/api/chat") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "content-type")

        let payload: [String: Any] = [
            "model": model,
            "stream": false,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
            "options": [
                "temperature": 0,
                "num_predict": maxTokens,
            ],
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        req.httpBody = body

        let semaphore = DispatchSemaphore(value: 0)
        var responseText: String?
        var httpOK = false
        URLSession.shared.dataTask(with: req) { data, response, _ in
            defer { semaphore.signal() }
            guard let http = response as? HTTPURLResponse else { return }
            httpOK = (200...299).contains(http.statusCode)
            guard httpOK,
                  let data = data,
                  let text = parseChatResponse(data) else { return }
            responseText = text
        }.resume()
        _ = semaphore.wait(timeout: .now() + timeout + 1)

        if !httpOK {
            markUnreachable()
            return nil
        }

        guard let text = responseText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return text
    }

    // MARK: - availability

    private static var isExplicitlyDisabled: Bool {
        let env = ProcessInfo.processInfo.environment["THREADLINE_DISABLE_OLLAMA"] ?? ""
        return env == "1" || env.lowercased() == "true"
    }

    private static func ensureAvailable(probeTimeout: TimeInterval) -> Bool {
        lock.lock()
        if availability == .available {
            lock.unlock()
            return true
        }
        if availability == .unavailable,
           let until = unavailableUntil, Date() < until {
            lock.unlock()
            return false
        }
        if availability == .unavailable {
            availability = .unknown
            probeFinished = false
        }
        lock.unlock()

        probeLock.lock()
        if !probeFinished {
            let ok = probe(timeout: probeTimeout)
            probeSucceeded = ok
            probeFinished = true
            lock.lock()
            if ok {
                availability = .available
                unavailableUntil = nil
            } else {
                availability = .unavailable
                unavailableUntil = Date().addingTimeInterval(retryInterval)
            }
            lock.unlock()
        }
        let result = probeSucceeded
        probeLock.unlock()
        return result
    }

    private static func markUnreachable() {
        lock.lock()
        availability = .unavailable
        unavailableUntil = Date().addingTimeInterval(retryInterval)
        probeFinished = true
        probeSucceeded = false
        lock.unlock()
    }

    private static func probe(timeout: TimeInterval) -> Bool {
        guard let url = URL(string: "\(host)/api/tags") else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = timeout

        let semaphore = DispatchSemaphore(value: 0)
        var ok = false
        URLSession.shared.dataTask(with: req) { _, response, _ in
            defer { semaphore.signal() }
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else { return }
            ok = true
        }.resume()
        _ = semaphore.wait(timeout: .now() + timeout + 0.5)
        return ok
    }

    // MARK: - config

    private static var host: String {
        if let env = ProcessInfo.processInfo.environment["THREADLINE_OLLAMA_HOST"],
           !env.isEmpty {
            return env.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        if let cfg = configString("ollama_host"), !cfg.isEmpty {
            return cfg.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        return "http://127.0.0.1:11434"
    }

    private static var model: String {
        if let env = ProcessInfo.processInfo.environment["THREADLINE_OLLAMA_MODEL"],
           !env.isEmpty {
            return env
        }
        if let cfg = configString("ollama_model"), !cfg.isEmpty {
            return cfg
        }
        return "qwen2.5:3b"
    }

    private static func configString(_ key: String) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let configPath = "\(home)/.threadline/config.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = obj[key] as? String,
              !value.isEmpty
        else { return nil }
        return value
    }

    // MARK: - parsing (testable)

    static func parseChatResponse(_ data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let message = obj["message"] as? [String: Any],
           let content = message["content"] as? String {
            return content
        }
        return nil
    }
}
