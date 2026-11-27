import Foundation

/// What `allFlags` returns: every flag served to this person, key to value.
///
/// `/flags/all` records no exposure (F32 hybrid exposure): counting the prefetch would mark every
/// screen load as exposed and dilute the experiment. Instead the FIRST read of each served key
/// through `subscript` or `dictionary` sends `/flags/expose` once for this map. `keys`, `count`
/// and `isEmpty` read nothing and expose nothing. A reference type because the exposure is state
/// the map carries; a plain dictionary cannot notice being read.
public final class FlagValues: @unchecked Sendable {

    static let empty = FlagValues(values: [:], served: [:]) { _, _ in }

    private let values: [String: JSONValue]
    private let lock = NSLock()
    private var unexposed: [String: Int]
    private let expose: (String, Int) -> Void

    init(
        values: [String: JSONValue],
        served: [String: Int],
        expose: @escaping (_ key: String, _ variationId: Int) -> Void
    ) {
        self.values = values
        self.unexposed = served
        self.expose = expose
    }

    public var keys: [String] { Array(values.keys) }
    public var count: Int { values.count }
    public var isEmpty: Bool { values.isEmpty }

    /// The served value, or nil when nothing was served. Reports the exposure on first read.
    public subscript(key: String) -> JSONValue? {
        report(key)
        return values[key]
    }

    /// Every value at once. Exposes EVERY served key, as reading each one would: use it only
    /// where every value is shown.
    public var dictionary: [String: JSONValue] {
        values.keys.forEach(report)
        return values
    }

    private func report(_ key: String) {
        lock.lock()
        let variationId = unexposed.removeValue(forKey: key)
        lock.unlock()
        if let variationId { expose(key, variationId) }
    }
}
