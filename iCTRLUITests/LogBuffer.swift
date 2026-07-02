import Foundation

class LogBuffer {
    private var entries: [String] = []
    private let capacity: Int
    private let lock = NSLock()
    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    // Per-method timing aggregation (durations in milliseconds).
    private struct Stat {
        var count = 0
        var total = 0.0
        var min = Double.greatestFiniteMagnitude
        var max = 0.0
    }
    private var stats: [String: Stat] = [:]

    init(capacity: Int) {
        self.capacity = capacity
    }

    /// Record one action's execution time (ms) and log it.
    func recordTiming(method: String, ms: Double, ok: Bool) {
        lock.lock()
        var s = stats[method] ?? Stat()
        s.count += 1
        s.total += ms
        s.min = Swift.min(s.min, ms)
        s.max = Swift.max(s.max, ms)
        stats[method] = s
        lock.unlock()

        let marker = ok ? "✓" : "✗"
        append(String(format: "⏱ %@ %@ %.0fms", marker, method, ms))
    }

    /// Human-readable per-method timing summary.
    func timingSummary() -> String {
        lock.lock()
        let snapshot = stats
        lock.unlock()

        guard !snapshot.isEmpty else { return "(no timing data yet)" }
        var out = "method            count      avg      min      max\n"
        out += "-------------------------------------------------------\n"
        for (m, s) in snapshot.sorted(by: { $0.key < $1.key }) {
            let avg = s.total / Double(s.count)
            out += String(format: "%-16@ %5d  %7.0f  %7.0f  %7.0f\n",
                          m as NSString, s.count, avg, s.min, s.max)
        }
        return out
    }

    /// Machine-readable timing stats for the config/status response.
    func timingStats() -> [[String: Any]] {
        lock.lock()
        let snapshot = stats
        lock.unlock()
        return snapshot.sorted { $0.key < $1.key }.map { m, s in
            [
                "method": m,
                "count": s.count,
                "avg_ms": Int(s.total / Double(s.count)),
                "min_ms": Int(s.min),
                "max_ms": Int(s.max),
            ]
        }
    }

    func append(_ message: String) {
        let timestamp = dateFormatter.string(from: Date())
        let entry = "[\(timestamp)] \(message)"

        lock.lock()
        entries.append(entry)
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
        lock.unlock()

        print(entry)
    }

    /// Full, unredacted dump — used by the authenticated in-app "Copy Logs" action.
    func dump() -> String {
        lock.lock()
        defer { lock.unlock() }
        return entries.joined(separator: "\n")
    }

    /// Redacted dump for the public (no-auth) /logs endpoint.
    /// Masks tokens/UUIDs, quoted strings (client names, typed text), and IPv4 addresses.
    func dumpRedacted() -> String {
        lock.lock()
        let snapshot = entries
        lock.unlock()
        return snapshot.map { LogBuffer.redact($0) }.joined(separator: "\n")
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    // MARK: - Redaction

    private static let uuidRegex = try? NSRegularExpression(
        pattern: "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"
    )
    private static let quotedRegex = try? NSRegularExpression(pattern: "\"[^\"]*\"")
    private static let ipv4Regex = try? NSRegularExpression(
        pattern: "\\b(\\d{1,3})\\.(\\d{1,3})\\.(\\d{1,3})\\.(\\d{1,3})\\b"
    )

    static func redact(_ line: String) -> String {
        var s = line as NSString
        var result = s as String

        // 1. Mask UUID-shaped tokens/session ids
        if let re = uuidRegex {
            result = re.stringByReplacingMatches(
                in: result, range: NSRange(location: 0, length: (result as NSString).length),
                withTemplate: "<redacted-id>"
            )
        }

        // 2. Mask quoted strings (client names, typed text, messages)
        if let re = quotedRegex {
            result = re.stringByReplacingMatches(
                in: result, range: NSRange(location: 0, length: (result as NSString).length),
                withTemplate: "\"<redacted>\""
            )
        }

        // 3. Partially mask IPv4 (keep first octet for network context)
        if let re = ipv4Regex {
            s = result as NSString
            let matches = re.matches(in: result, range: NSRange(location: 0, length: s.length))
            for m in matches.reversed() {
                let first = s.substring(with: m.range(at: 1))
                s = s.replacingCharacters(in: m.range, with: "\(first).x.x.x") as NSString
            }
            result = s as String
        }

        return result
    }
}
