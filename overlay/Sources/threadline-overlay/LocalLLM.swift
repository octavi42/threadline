import Foundation

/// Optional local summarizer/classifier via Ollama (`http://127.0.0.1:11434`).
///
/// Disabled when Ollama is unreachable (probed once per app launch) or when
/// `THREADLINE_DISABLE_OLLAMA=1`. Configure with env vars or `~/.threadline/config.json`:
/// `ollama_host`, `ollama_model`.
enum LocalLLM {
    private static let lock = NSLock()
    private static var availability: Availability = .unknown

    private enum Availability {
        case unknown
        case available
        case unavailable
    }

    static var statusLabel: String {
        guard !isExplicitlyDisabled else { return "off" }
        lock.lock()
        let state = availability
        lock.unlock()
        switch state {
        case .available: return "on (\(model))"
        case .unavailable: return "off"
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
        URLSession.shared.dataTask(with: req) { data, response, _ in
            defer { semaphore.signal() }
            guard let data = data,
                  let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  let text = parseChatResponse(data)
            else { return }
            responseText = text
        }.resume()
        _ = semaphore.wait(timeout: .now() + timeout + 1)
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
        switch availability {
        case .available:
            lock.unlock()
            return true
        case .unavailable:
            lock.unlock()
            return false
        case .unknown:
            lock.unlock()
            let ok = probe(timeout: probeTimeout)
            lock.lock()
            availability = ok ? .available : .unavailable
            lock.unlock()
            return ok
        }
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
