import Foundation
import CryptoKit

struct SyncHTTPError: LocalizedError {
    let status: Int
    let message: String
    let retryAfter: TimeInterval?
    var errorDescription: String? { message }
}

/// Equal jitter spreads reconnects without permitting a zero-delay retry.
struct SyncRetrySchedule {
    private(set) var failures = 0
    private(set) var deadline = Date.distantPast
    func remaining(at now: Date = Date()) -> TimeInterval { max(0, deadline.timeIntervalSince(now)) }
    mutating func reset() { failures = 0; deadline = .distantPast }

    static func delay(attempt: Int, retryAfter: TimeInterval? = nil, sample: Double = Double.random(in: 0...1)) -> TimeInterval {
        let exponential = min(60, pow(2, Double(min(6, max(0, attempt - 1)))))
        let jitter = exponential * (0.5 + min(1, max(0, sample)) * 0.5)
        // Respect the server's lower bound and also spread clients at that boundary.
        return max(jitter, retryAfter ?? 0) + (retryAfter == nil ? 0 : min(1, max(0, sample)))
    }

    mutating func fail(_ error: Error, now: Date = Date(), sample: Double = Double.random(in: 0...1)) {
        failures = min(32, failures + 1)
        deadline = now.addingTimeInterval(Self.delay(attempt: failures,
            retryAfter: (error as? SyncHTTPError)?.retryAfter, sample: sample))
    }

    static func retryAfter(_ value: String?, now: Date = Date()) -> TimeInterval? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        if let seconds = Double(value), seconds.isFinite, seconds >= 0 { return seconds }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        guard let date = formatter.date(from: value) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }
}

/// A fresh Shortcut process must respect a previous 429/503 response too.
/// Store only a digest of origin + principal, never the bearer credential.
enum SyncRetryGate {
    private static let key = "syncRetryUntil"
    private static func identity(_ request: URLRequest) -> String {
        let url = request.url!
        let origin = "\(url.scheme ?? "")://\(url.host ?? ""):\(url.port ?? 0)"
        return SHA256.hash(data: Data((origin + "|" + (request.value(forHTTPHeaderField: "Authorization") ?? "anonymous")).utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    static func remaining(_ request: URLRequest, now: Date = Date(), defaults: UserDefaults = .standard) -> TimeInterval {
        let saved = defaults.dictionary(forKey: key) as? [String: Double] ?? [:]
        return max(0, (saved[identity(request)] ?? 0) - now.timeIntervalSince1970)
    }

    static func record(_ response: HTTPURLResponse, request: URLRequest, now: Date = Date(),
                       sample: Double = Double.random(in: 0...1), defaults: UserDefaults = .standard) {
        guard [429, 503].contains(response.statusCode),
              let delay = SyncRetrySchedule.retryAfter(response.value(forHTTPHeaderField: "Retry-After"), now: now) else { return }
        var saved = defaults.dictionary(forKey: key) as? [String: Double] ?? [:]
        saved = saved.filter { $0.value > now.timeIntervalSince1970 }
        let id = identity(request)
        saved[id] = max(saved[id] ?? 0, now.timeIntervalSince1970 + delay + min(1, max(0, sample)))
        // Bound stale entries from previously configured servers.
        if saved.count > 32 {
            saved = Dictionary(uniqueKeysWithValues: saved.sorted { $0.value > $1.value }.prefix(32).map { ($0.key, $0.value) })
        }
        defaults.set(saved, forKey: key)
    }
}
