import Foundation

/// Feature flags over the `/flags/*` routes (F32), the client half of intempt-node's flag
/// evaluator (`src/flag-evaluator.ts` @ ffc4df6). Experiments and personalizations are NOT read
/// here: they are `choose()` (`Choose.swift`), the only caller of `/optimization/choose-api` (D20).
///
/// F33: this file, `FlagStream.swift` and `FlagValues.swift` import Foundation only. The transport
/// is injected (`Flags.Deps`), so nothing here reaches tracking, the queue or URLSession.
///
/// Rules carried over from `docs/SDK-API-CONTRACT.md`: `defaultValue` is required and is what the
/// caller receives on any failure; no flag call throws or traps (S11); evaluation is remote, and the
/// only local state is the F15 answer cache below.

/// Why an evaluation returned the value it did.
///
/// The wire reasons are the server's `FlagValue.reason`, passed through (F6). `cached`,
/// `unanswered` and `error` are SDK-local. `unanswered` is an answer without a reason this SDK
/// knows; Node maps that to `off`, this SDK keeps it distinct because aliasing it onto `.off` is
/// the collapse `EXP-SERVE-001` forbids (F6 #4: an older server behaves as before).
public enum FlagReason: String, Sendable, Equatable {
    case targeted
    case holdout
    case notTargeted = "not_targeted"
    case notInRollout = "not_in_rollout"
    case off
    case killed
    case notClientSide = "not_client_side"
    /// The read failed and the last-known value (at most 24 h old) was served instead (F15).
    case cached
    case unanswered
    case error

    /// SDK-local reasons arriving on the wire are not trusted as answers.
    static func wire(_ raw: String?) -> FlagReason {
        guard let raw, let reason = FlagReason(rawValue: raw) else { return .unanswered }
        switch reason {
        case .cached, .unanswered, .error: return .unanswered
        default: return reason
        }
    }
}

/// OpenFeature error codes, set with `reason == .error` when the default came back for a known
/// cause (S11, F30).
public enum FlagErrorCode: String, Sendable, Equatable {
    case flagNotFound = "FLAG_NOT_FOUND"
    case typeMismatch = "TYPE_MISMATCH"
    case targetingKeyMissing = "TARGETING_KEY_MISSING"
    case general = "GENERAL"
}

/// Why a flag request failed (INT-7454). The caller still receives its default value.
public struct FlagError: Error, Sendable, Equatable {

    public enum Kind: String, Sendable, Equatable {
        /// 401 or 403: the API key or the source is wrong.
        case auth
        /// Any other 4xx except 408 and 429, or a request the SDK could not build.
        case badRequest = "bad_request"
        /// 5xx, or 429: the service's capacity, not the caller's request.
        case server
        /// 408, or a request sent and never answered.
        case timeout
        /// The request never reached the service.
        case network
        /// A 2xx whose body is not the evaluation response.
        case parse
    }

    /// Nil for `allFlags`, which names no key.
    public let key: String?
    public let kind: Kind
    public let status: Int?
}

/// Who is being evaluated.
///
/// `profileId` is the device identifier the SDK already holds. It is present before and after a
/// person signs in, which is what keeps their assignment stable across the transition — deriving
/// on the user id instead re-buckets them mid-session.
public struct FlagContext: Sendable, Equatable {
    public let userId: String?
    public let profileId: String?

    public init(userId: String? = nil, profileId: String? = nil) {
        self.userId = userId
        self.profileId = profileId
    }
}

/// What `variationDetail` returns: the value the caller should use (their default when nothing
/// was served), why, and the served variation's details when the server sent them.
public struct FlagDetail: Sendable, Equatable {
    public let value: JSONValue
    public let reason: FlagReason
    /// Set only with `reason == .error`.
    public let errorCode: FlagErrorCode?
    /// Set only when a request failed.
    public let error: FlagError?
    public let variationId: Int?
    /// The flag's declared type: `boolean`, `string`, `number` or `json`.
    public let valueType: String?
    /// The matched rule's 1-based position; 0 when a shipped flag served everyone.
    public let rule: Int?
    /// The served variant's name.
    public let variant: String?

    init(
        value: JSONValue,
        reason: FlagReason,
        errorCode: FlagErrorCode? = nil,
        error: FlagError? = nil,
        variationId: Int? = nil,
        valueType: String? = nil,
        rule: Int? = nil,
        variant: String? = nil
    ) {
        self.value = value
        self.reason = reason
        self.errorCode = errorCode
        self.error = error
        self.variationId = variationId
        self.valueType = valueType
        self.rule = rule
        self.variant = variant
    }
}

/// Route suffixes under `/v1/{org}/projects/{project}`, as audience-service
/// `OptimizationChooserRoutes` declares them.
enum FlagRoute: String, CaseIterable, Sendable {
    case evaluate = "/flags/evaluate"
    case all = "/flags/all"
    case expose = "/flags/expose"
    case stream = "/flags/stream"
}

/// What the injected transport hands back: a 2xx body, or the failure already classified.
enum FlagReply: Equatable {
    case answered(Data?)
    case failed(FlagError.Kind, status: Int?)
}

/// audience-service `FlagValue`. Every field optional: an older or partial answer must not trap,
/// and a field of the wrong type is dropped rather than trusted.
struct FlagAnswer: Equatable, Sendable {
    let key: String?
    /// Nil when absent or JSON null: nothing was served, so the caller's default applies.
    let value: JSONValue?
    let variationId: Int?
    let valueType: String?
    let reason: String?
    let rule: Int?
    let variant: String?

    init(
        key: String? = nil, value: JSONValue? = nil, variationId: Int? = nil,
        valueType: String? = nil, reason: String? = nil, rule: Int? = nil, variant: String? = nil
    ) {
        self.key = key
        self.value = value
        self.variationId = variationId
        self.valueType = valueType
        self.reason = reason
        self.rule = rule
        self.variant = variant
    }

    init?(_ raw: Any) {
        guard case .object(let o) = JSONValue.from(raw) else { return nil }
        self.init(
            key: o["key"]?.stringIfString,
            value: o["value"].flatMap { $0 == .null ? nil : $0 },
            variationId: o["variationId"]?.integer,
            valueType: o["valueType"]?.stringIfString,
            reason: o["reason"]?.stringIfString,
            rule: o["rule"]?.integer,
            variant: o["variant"]?.stringIfString)
    }
}

extension JSONValue {
    /// `stringValue` renders numbers and booleans; a wire field typed as a string must BE one.
    fileprivate var stringIfString: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    fileprivate var integer: Int? {
        if case .number(let n) = self { return Int(exactly: n) }
        return nil
    }
}

/// The type a read expects, taken from its default (F30 #2). A `.null` default expects nothing in
/// particular, so any served value is returned.
enum FlagValueType: String {
    case boolean, string, number, json

    init?(expectedBy defaultValue: JSONValue) {
        switch defaultValue {
        case .bool: self = .boolean
        case .string: self = .string
        case .number: self = .number
        case .object, .array: self = .json
        case .null: return nil
        }
    }

    /// The server's declared `valueType` decides when sent (F30 #3); the JSON type is checked as
    /// well, so a malformed answer cannot pass as its declared type. Any JSON value is `json` (F30 #4).
    func accepts(_ value: JSONValue, declared: String?) -> Bool {
        if let declared, declared != rawValue { return false }
        switch (self, value) {
        case (.json, _): return true
        case (.boolean, .bool), (.string, .string): return true
        case (.number, .number(let n)): return n.isFinite
        default: return false
        }
    }
}

// MARK: - Evaluator

final class Flags {

    /// F15: the last-known value is served when a read fails, for up to 24 h. While the stream is
    /// connected an answer younger than `freshTTL` is served without asking, because the stream
    /// drops a changed key at once; without a stream the server is asked on every call.
    static let cacheTTL: TimeInterval = 24 * 60 * 60
    static let freshTTL: TimeInterval = 60
    static let cacheMax = 10_000
    static let warnedMax = 1_000

    struct Deps {
        var sourceId: String
        /// Sent on evaluate, all and expose alike: `/flags/expose` re-runs the assignment with it,
        /// so a different value there could disagree with the read it reports.
        var device: String
        /// Named in the 401/403 log; the secret half never reaches this class.
        var keyPrefix: String
        var post: (FlagRoute, [String: Any], @escaping (FlagReply) -> Void) -> Void
        var openStream: (StreamHandlers) -> StreamHandle
        var schedule: (TimeInterval, @escaping () -> Void) -> Void
        var now: () -> Date
        var cacheMax: Int = Flags.cacheMax
    }

    /// The identity the server buckets on: source + profile when both are present, else the user
    /// (`Identification.hasProfile`). An equality key only: nothing here derives a bucket.
    struct CacheID: Hashable {
        let key: String
        let profile: Bool
        let id: String?
    }

    private struct Entry {
        let key: String
        let answer: FlagAnswer
        let at: Date
        /// When the read that produced it began: an answer older than the current connection is
        /// not fresh.
        let started: Date
        /// False when the stream was down, or dropped the key, while the read was in flight.
        let trusted: Bool
    }

    /// Reads in flight, so a drop that lands mid-request keeps its answer from being trusted.
    private final class PendingRead {
        let key: String
        var stale = false
        init(key: String) { self.key = key }
    }

    /// Failures the service may recover from. Not a 400/404 (the request or the flag is wrong, and
    /// a deleted flag must stop serving) and not a 401/403 (a misconfigured key is not an outage).
    private static let fallbackKinds: Set<FlagError.Kind> = [.timeout, .network, .server, .parse]

    private let deps: Deps
    private let lock = NSLock()
    private var cache: [CacheID: Entry] = [:]
    private var pending: [ObjectIdentifier: PendingRead] = [:]
    private var connectedAt = Date.distantPast
    private var warned = Set<String>()
    private var authFailureLogged = false
    private var closed = false
    private var _onFlagError: ((FlagError) -> Void)?
    private(set) var stream: FlagStream!

    /// See `IntemptInstance.onFlagError`.
    var onFlagError: ((FlagError) -> Void)? {
        get { locked { _onFlagError } }
        set { locked { _onFlagError = newValue } }
    }

    init(deps: Deps) {
        self.deps = deps
        self.stream = FlagStream(
            open: deps.openStream,
            schedule: deps.schedule,
            onChange: { [weak self] keys in self?.drop(keys) },
            onState: { [weak self] connected in self?.streamState(connected) })
    }

    /// The characters the server accepts in a flag key: `FlagEvaluateRequest.key` is
    /// `@Pattern(regexp = "^[a-zA-Z0-9_-]*$")`, tightened here to reject the empty string.
    static let allowedKeyCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")

    static func isValidKey(_ key: String) -> Bool {
        !key.isEmpty && key.unicodeScalars.allSatisfy(allowedKeyCharacters.contains)
    }

    /// Ends the stream for good; later reads ask the server every time.
    func close() {
        locked { closed = true }
        stream.close()
    }

    /// Ends the connection without ending the client: the next read reconnects. A suspended app
    /// cannot hold a socket open, and a reconnect loop there only spends battery.
    func pauseStream() {
        stream.pause()
    }

    // MARK: Single read

    /// - Parameter disableExposure: read through `/flags/all` with this one key, which records
    ///   nothing; otherwise `/flags/evaluate`, which records the exposure on the server.
    func detail(
        key: String,
        context: FlagContext,
        sessionId: String?,
        defaultValue: JSONValue,
        disableExposure: Bool = false,
        completion: @escaping (FlagDetail) -> Void
    ) {
        // S11: a caller mistake returns the default and never traps; one warning per key keeps a
        // typo visible without one line per call.
        guard Flags.isValidKey(key) else {
            warnOnce(
                "key:\(key)",
                "flag key \"\(key)\" is empty or does not match ^[a-zA-Z0-9_-]+$ (the platform's "
                    + "own pattern); returning the default")
            return completion(
                FlagDetail(value: defaultValue, reason: .error, errorCode: .flagNotFound))
        }
        guard answerable(context, key: key) else {
            return completion(
                FlagDetail(value: defaultValue, reason: .error, errorCode: .targetingKeyMissing))
        }

        stream.start()
        let id = cacheID(key, context)
        if let fresh = fresh(id) {
            return completion(Flags.typed(fresh, defaultValue))
        }

        let read = PendingRead(key: key)
        let started = deps.now()
        let trusted = stream.connected
        locked { pending[ObjectIdentifier(read)] = read }

        let finish: (FlagAnswer?, FlagError?) -> Void = { [weak self] answer, error in
            guard let self else { return completion(FlagDetail(value: defaultValue, reason: .error)) }
            let stale: Bool = self.locked {
                self.pending[ObjectIdentifier(read)] = nil
                return read.stale
            }
            completion(
                self.settle(
                    id: id, key: key, answer: answer, error: error, defaultValue: defaultValue,
                    started: started, trusted: trusted && !stale))
        }

        if disableExposure {
            requestAll(context, keys: [key], errorKey: key) { answers, error in
                finish(answers.first { $0.key == key }, error)
            }
        } else {
            evaluate(context, key: key, sessionId: sessionId, completion: finish)
        }
    }

    private func settle(
        id: CacheID, key: String, answer: FlagAnswer?, error: FlagError?,
        defaultValue: JSONValue, started: Date, trusted: Bool
    ) -> FlagDetail {
        if let error {
            if Flags.fallbackKinds.contains(error.kind), let cached = recall(id) {
                return Flags.typed(cached, defaultValue, reason: .cached)
            }
            let notFound = error.status == 404
            // A deleted flag must not come back from the cache during a later outage.
            if notFound { forget(id) }
            return FlagDetail(
                value: defaultValue, reason: .error,
                errorCode: notFound ? .flagNotFound : .general, error: error)
        }
        guard let answer else {
            // Only a disableExposure read lands here: `/flags/all` leaves an unknown key out where
            // `/flags/evaluate` would answer 404.
            forget(id)
            return FlagDetail(value: defaultValue, reason: .error, errorCode: .flagNotFound)
        }
        if answer.value == nil {
            // Off, killed or not targeted: forgotten, so an outage cannot serve the old value.
            forget(id)
        } else {
            remember(id, key: key, answer: answer, started: started, trusted: trusted)
        }
        return Flags.typed(answer, defaultValue)
    }

    /// The detail for an answered (or cached) flag, with the F30 type check against the default.
    static func typed(
        _ answer: FlagAnswer, _ defaultValue: JSONValue, reason: FlagReason? = nil
    ) -> FlagDetail {
        let resolved = reason ?? FlagReason.wire(answer.reason)
        let make = { (value: JSONValue, reason: FlagReason, code: FlagErrorCode?) in
            FlagDetail(
                value: value, reason: reason, errorCode: code, variationId: answer.variationId,
                valueType: answer.valueType, rule: answer.rule, variant: answer.variant)
        }
        guard let value = answer.value else { return make(defaultValue, resolved, nil) }
        if let expected = FlagValueType(expectedBy: defaultValue),
            !expected.accepts(value, declared: answer.valueType)
        {
            return make(defaultValue, .error, .typeMismatch)
        }
        return make(value, resolved, nil)
    }

    // MARK: Prefetch

    /// Every flag served to this person. `/flags/all` records nothing (F32 hybrid exposure), so the
    /// returned `FlagValues` reports the exposure itself on the first read of each served key.
    func all(context: FlagContext, sessionId: String?, completion: @escaping (FlagValues) -> Void) {
        guard answerable(context, key: nil) else { return completion(FlagValues.empty) }
        requestAll(context, keys: nil, errorKey: nil) { [weak self] answers, _ in
            var values: [String: JSONValue] = [:]
            var served: [String: Int] = [:]
            for answer in answers {
                guard let key = answer.key, !key.isEmpty, let value = answer.value else { continue }
                values[key] = value
                // /flags/expose requires a variationId; without one there is nothing to record.
                if let variationId = answer.variationId { served[key] = variationId }
            }
            let request = self?.identified(context) ?? [:]
            completion(
                FlagValues(values: values, served: served) { [weak self] key, variationId in
                    self?.expose(request, key: key, variationId: variationId, sessionId: sessionId)
                })
        }
    }

    /// Fire-and-forget: the read has already been answered, so a lost exposure costs one data
    /// point and never a value or a wait. Not an `onFlagError`: no read failed.
    private func expose(
        _ request: [String: Any], key: String, variationId: Int, sessionId: String?
    ) {
        guard !locked({ closed }) else { return }
        var body = request
        body["key"] = key
        body["variationId"] = variationId
        if let sessionId, !sessionId.isEmpty { body["sessionId"] = sessionId }
        deps.post(.expose, body) { [weak self] reply in
            guard case .failed(let kind, let status) = reply else { return }
            self?.warnOnce(
                "expose:\(kind.rawValue)",
                "flag exposure for \"\(key)\" was not recorded (\(kind.rawValue)"
                    + "\(status.map { " \($0)" } ?? "")); further \(kind.rawValue) failures are not logged")
        }
    }

    // MARK: Requests

    private func evaluate(
        _ context: FlagContext, key: String, sessionId: String?,
        completion: @escaping (FlagAnswer?, FlagError?) -> Void
    ) {
        var body = identified(context)
        body["key"] = key
        if let sessionId, !sessionId.isEmpty { body["sessionId"] = sessionId }
        deps.post(.evaluate, body) { [weak self] reply in
            guard let self else { return }
            switch reply {
            case .failed(let kind, let status):
                completion(nil, self.failed(FlagError(key: key, kind: kind, status: status)))
            case .answered(let data):
                guard let answer = Flags.json(data).flatMap(FlagAnswer.init) else {
                    return completion(nil, self.failed(FlagError(key: key, kind: .parse, status: nil)))
                }
                completion(answer, nil)
            }
        }
    }

    private func requestAll(
        _ context: FlagContext, keys: [String]?, errorKey: String?,
        completion: @escaping ([FlagAnswer], FlagError?) -> Void
    ) {
        var body = identified(context)
        if let keys { body["keys"] = keys }
        deps.post(.all, body) { [weak self] reply in
            guard let self else { return }
            switch reply {
            case .failed(let kind, let status):
                completion([], self.failed(FlagError(key: errorKey, kind: kind, status: status)))
            case .answered(let data):
                guard
                    let object = Flags.json(data) as? [String: Any],
                    let flags = object["flags"] as? [Any]
                else {
                    return completion(
                        [], self.failed(FlagError(key: errorKey, kind: .parse, status: nil)))
                }
                completion(flags.compactMap(FlagAnswer.init), nil)
            }
        }
    }

    /// choose-api's `Identification`, which the flag routes share.
    private func identified(_ context: FlagContext) -> [String: Any] {
        var identification: [String: Any] = ["sourceId": deps.sourceId]
        if let userId = context.userId, !userId.isEmpty { identification["userId"] = userId }
        if let profileId = context.profileId, !profileId.isEmpty {
            identification["profileId"] = profileId
        }
        return ["identification": identification, "device": deps.device]
    }

    /// The flag routes answer 400 unless the context names a visitor: a non-blank `userId`, or a
    /// non-blank `profileId` with a `sourceId`. Checked here so the caller is told why, once per
    /// key, instead of a 400 per call (S11).
    private func answerable(_ context: FlagContext, key: String?) -> Bool {
        if Flags.present(context.userId) { return true }
        if Flags.present(context.profileId) && Flags.present(deps.sourceId) { return true }
        warnOnce(
            "identity:\(key ?? "")",
            "flag \"\(key ?? "(allFlags)")\": context needs either userId, or profileId together "
                + "with a sourceId configured on the client; returning the default")
        return false
    }

    private static func present(_ value: String?) -> Bool {
        guard let value else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func json(_ data: Data?) -> Any? {
        guard let data, !data.isEmpty else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    // MARK: Cache

    private func cacheID(_ key: String, _ context: FlagContext) -> CacheID {
        if Flags.present(context.profileId) {
            return CacheID(key: key, profile: true, id: context.profileId)
        }
        return CacheID(key: key, profile: false, id: context.userId)
    }

    private func fresh(_ id: CacheID) -> FlagAnswer? {
        guard stream.connected else { return nil }
        let now = deps.now()
        return locked {
            guard let entry = cache[id], entry.trusted else { return nil }
            if entry.started < connectedAt || now.timeIntervalSince(entry.at) > Flags.freshTTL {
                return nil
            }
            return entry.answer
        }
    }

    private func recall(_ id: CacheID) -> FlagAnswer? {
        let now = deps.now()
        return locked {
            guard let entry = cache[id] else { return nil }
            if now.timeIntervalSince(entry.at) > Flags.cacheTTL {
                cache[id] = nil
                return nil
            }
            return entry.answer
        }
    }

    private func remember(
        _ id: CacheID, key: String, answer: FlagAnswer, started: Date, trusted: Bool
    ) {
        let at = deps.now()
        locked {
            cache[id] = Entry(key: key, answer: answer, at: at, started: started, trusted: trusted)
            if cache.count > deps.cacheMax,
                let oldest = cache.min(by: { $0.value.at < $1.value.at })?.key
            {
                cache[oldest] = nil
            }
        }
    }

    private func forget(_ id: CacheID) {
        locked { cache[id] = nil }
    }

    /// `[]` drops everything: an event that cannot be read cannot be trusted to name its keys.
    private func drop(_ keys: [String]) {
        locked {
            for read in pending.values where keys.isEmpty || keys.contains(read.key) {
                read.stale = true
            }
            if keys.isEmpty {
                cache.removeAll()
            } else {
                cache = cache.filter { !keys.contains($0.value.key) }
            }
        }
    }

    private func streamState(_ connected: Bool) {
        let now = deps.now()
        locked {
            if connected { connectedAt = now }
            for read in pending.values { read.stale = true }
        }
    }

    var cacheCount: Int { locked { cache.count } }

    // MARK: Reporting

    /// Bounded so a stream of distinct bad keys cannot grow memory: when full it starts over, and
    /// a key seen long ago may warn once more rather than never.
    private func warnOnce(_ id: String, _ message: String) {
        let first: Bool = locked {
            if warned.contains(id) { return false }
            if warned.count >= Flags.warnedMax { warned.removeAll() }
            warned.insert(id)
            return true
        }
        if first { IntemptLogger.shared.log(.warning, message) }
    }

    /// A 401/403 is a misconfigured key that every later read repeats, so it is logged at error
    /// level once per client and at debug after.
    private func failed(_ error: FlagError) -> FlagError {
        let what =
            "flag evaluation failed (\(error.kind.rawValue)\(error.status.map { " \($0)" } ?? "")); using the default"
        if error.kind == .auth {
            let first: Bool = locked {
                defer { authFailureLogged = true }
                return !authFailureLogged
            }
            IntemptLogger.shared.log(
                first ? .error : .debug,
                "\(what). The service rejected API key prefix \(deps.keyPrefix) for source "
                    + "\(deps.sourceId): check the key and that it belongs to this source.")
        } else {
            IntemptLogger.shared.log(.debug, what)
        }
        onFlagError?(error)
        return error
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
