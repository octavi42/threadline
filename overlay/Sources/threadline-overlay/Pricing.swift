import Foundation

/// Approximate per-million-token USD prices for known Claude models.
/// Override at runtime by writing JSON to `~/.threadline/pricing.json`:
///   { "claude-opus-4-7": { "input": 15, "output": 75,
///                          "cacheCreate": 18.75, "cacheRead": 1.50 } }
enum Pricing {
    struct Rate {
        let input: Double
        let output: Double
        let cacheCreate: Double
        let cacheRead: Double
    }

    private static var cache: [String: Rate] = builtIn
    private static var customLoaded = false

    private static let builtIn: [String: Rate] = [
        "claude-opus-4-7":   Rate(input: 15, output: 75, cacheCreate: 18.75, cacheRead: 1.50),
        "claude-opus-4-6":   Rate(input: 15, output: 75, cacheCreate: 18.75, cacheRead: 1.50),
        "claude-opus-4-5":   Rate(input: 15, output: 75, cacheCreate: 18.75, cacheRead: 1.50),
        "claude-sonnet-4-6": Rate(input:  3, output: 15, cacheCreate:  3.75, cacheRead: 0.30),
        "claude-sonnet-4-5": Rate(input:  3, output: 15, cacheCreate:  3.75, cacheRead: 0.30),
        "claude-haiku-4-5":  Rate(input: 0.80, output: 4, cacheCreate: 1.00, cacheRead: 0.08),
    ]

    static func rate(for model: String) -> Rate? {
        if !customLoaded { loadCustom() }
        if let exact = cache[model] { return exact }
        // Loose prefix match: "claude-opus-4-7-20260514" → "claude-opus-4-7".
        for (k, v) in cache where model.hasPrefix(k) { return v }
        return nil
    }

    /// Sum tokens × rate → USD.
    static func usd(model: String,
                    input: Int, output: Int,
                    cacheCreate: Int, cacheRead: Int) -> Double? {
        guard let r = rate(for: model) else { return nil }
        let perM = 1_000_000.0
        return (Double(input)       * r.input)       / perM
             + (Double(output)      * r.output)      / perM
             + (Double(cacheCreate) * r.cacheCreate) / perM
             + (Double(cacheRead)   * r.cacheRead)   / perM
    }

    private static func loadCustom() {
        customLoaded = true
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = "\(home)/.threadline/pricing.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Double]]
        else { return }
        for (k, v) in obj {
            cache[k] = Rate(input: v["input"] ?? 0,
                            output: v["output"] ?? 0,
                            cacheCreate: v["cacheCreate"] ?? 0,
                            cacheRead: v["cacheRead"] ?? 0)
        }
    }
}

/// Known Claude model context windows. Codex passes its own value via
/// `session_meta.model_context_window`, so this is Claude-side only.
enum ContextLimits {
    private static let limits: [String: Int] = [
        "claude-opus-4-7":   200_000,
        "claude-opus-4-6":   200_000,
        "claude-opus-4-5":   200_000,
        "claude-sonnet-4-6": 200_000,
        "claude-sonnet-4-5": 200_000,
        "claude-haiku-4-5":  200_000,
    ]
    static func limit(for model: String) -> Int? {
        if let exact = limits[model] { return exact }
        for (k, v) in limits where model.hasPrefix(k) { return v }
        return nil
    }
}
