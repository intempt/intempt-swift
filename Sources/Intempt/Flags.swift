import Foundation

/// Feature flags, experiments and personalizations, read by key.
///
/// The cross-SDK surface is defined in `docs/SDK-API-CONTRACT.md`, which every Intempt SDK
/// conforms to. Four of its rules shape this file:
///
/// 1. The caller asks for a KEY, never a mode. The older surface put the mode in the method name,
///    which forced an integrator to know whether a key was an experiment before reading it and
///    grew combinatorially with every new mode. The platform resolves mode itself: its serving
///    query filters on channel and status and never on mode.
/// 2. `defaultValue` is REQUIRED. It is what a caller receives on a network failure, a timeout, an
///    unknown key or a malformed response.
/// 3. `variationDetail` is public (INT-7454, round-2 CONTRACT S3). A failed request now reads
///    `.error` with a `FlagError`, so it is no longer confused with a deliberate off state. The
///    platform still sends no `reason` for a served value: that reads `.unanswered`, not a guess.
/// 4. Evaluation is REMOTE only. There is no local rule engine and no flag store to poll.

/// Why an evaluation returned the value it did.
///
/// `unanswered` and `error` are SDK-local and never arrive on the wire. `error`: the request
/// failed, see `FlagDetail.error`. `off`: the service answered and served nothing for the key.
/// `unanswered`: a value was served without a reason this SDK knows, which is every served value
/// until the serving response carries one. Aliasing either onto `.off` is the collapse
/// `EXP-SERVE-001` forbids.
public enum FlagReason: String, Sendable, Equatable {
    case targeted
    case holdout
    case notTargeted = "not_targeted"
    case off
    case unanswered
    case error
}

/// Why a flag request failed (INT-7454). The caller still receives its default value.
public struct FlagError: Error, Sendable, Equatable {

    public enum Kind: String, Sendable, Equatable {
        /// 401 or 403: the API key or the source is wrong.
        case auth
        /// Any other 4xx, or a request the SDK refused to send (a key the service would reject).
        case badRequest = "bad_request"
        /// 5xx.
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
/// was served), why, and the failure when `reason` is `.error`.
public struct FlagDetail: Sendable, Equatable {
    public let value: JSONValue
    public let reason: FlagReason
    public let error: FlagError?
}

/// One key's evaluation before the caller's default is applied. `value` is nil when nothing was
/// served.
struct FlagEvaluation: Sendable, Equatable {
    let value: JSONValue?
    let reason: FlagReason
    let error: FlagError?

    init(value: JSONValue?, reason: FlagReason, error: FlagError? = nil) {
        self.value = value
        self.reason = reason
        self.error = error
    }
}

// MARK: - Client

/// Fetch-and-return, like `Personalization`. Nothing is queued or retried: a flag answer is only
/// useful while the caller is deciding what to render.
final class Flags {

    private let network: Network
    private let credentials: IntemptCredentials
    private let orgId: String
    private let projectId: String
    private let sourceId: String

    private let lock = ReadWriteLock(label: "com.intempt.flags")
    private var _onFlagError: ((FlagError) -> Void)?
    private var authFailureLogged = false

    /// See `IntemptInstance.onFlagError`.
    var onFlagError: ((FlagError) -> Void)? {
        get { lock.read { _onFlagError } }
        set { lock.write { _onFlagError = newValue } }
    }

    init(
        network: Network,
        credentials: IntemptCredentials,
        orgId: String,
        projectId: String,
        sourceId: String
    ) {
        self.network = network
        self.credentials = credentials
        self.orgId = orgId
        self.projectId = projectId
        self.sourceId = sourceId
    }

    /// The characters the SERVER accepts in a flag key.
    ///
    /// `ExperienceApiChooseRequest.names` is `Set<@Pattern(regexp: "^[a-zA-Z0-9_-]*$") String>`,
    /// and `HandlerUtils.requestToMono` runs a real validator over every request body — it builds
    /// a `Validator` and throws `IntemptException` on any violation — so a key outside this set is
    /// refused before a single experience is looked up. Verified against `audience-service`
    /// `origin/main` @ `97fa27d`.
    ///
    /// Checking it here costs nothing and buys the one thing the wire cannot give back: without
    /// it the SDK spends a round trip to be told no, and the caller cannot distinguish that
    /// refusal from "no flag is configured" — both arrive as the default. It is the same
    /// indistinguishability that let the tvOS `device: "tv"` defect ship unnoticed.
    static let allowedKeyCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")

    /// Pure and total, so it is checkable without a transport.
    ///
    /// Stricter than the server's regex in one place: `*` there admits the empty string, which can
    /// only ever be a mistake, so it is rejected here.
    static func isValidKey(_ key: String) -> Bool {
        !key.isEmpty && key.unicodeScalars.allSatisfy(allowedKeyCharacters.contains)
    }

    /// - Parameter exposure: false evaluates without recording an exposure (INT-7456).
    func detail(
        key: String,
        context: FlagContext,
        sessionId: String?,
        exposure: Bool = true,
        completion: @escaping (FlagEvaluation) -> Void
    ) {
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // A programming error, not a runtime condition. `assertionFailure` is compiled out
            // under -O, so this is a DEBUG-only signal: in a release build a blank key is
            // silently the caller's default. That is deliberate — trapping a shipped app over a
            // flag key is worse than the flag reading its default — and docs/CONVENTIONS.md says
            // so rather than promising a throw the code does not make.
            assertionFailure("variation: key must not be empty")
            return completion(
                FlagEvaluation(
                    value: nil, reason: .error, error: failed(.badRequest, status: nil, key: key)))
        }

        guard Flags.isValidKey(key) else {
            // Deliberately NOT an assertionFailure. An empty key is structural and the guard
            // above traps it in DEBUG; a dotted or spaced key is a realistic naming mistake, and
            // aborting someone's debug build over one is worse than the flag reading its default.
            // The service refuses it either way, so this skips a round trip that could only fail.
            // Reported as the 400 it would have been, so the caller can tell it from "not set".
            return completion(
                FlagEvaluation(
                    value: nil, reason: .error, error: failed(.badRequest, status: nil, key: key)))
        }

        choose(context: context, sessionId: sessionId, names: [key], exposure: exposure) {
            choices, error in
            if let error {
                return completion(FlagEvaluation(value: nil, reason: .error, error: error))
            }
            guard let choice = choices.first(where: { Flags.string($0["name"]) == key }) else {
                return completion(FlagEvaluation(value: nil, reason: .off))
            }
            completion(
                FlagEvaluation(
                    value: Flags.servedValue(choice["body"]),
                    reason: FlagReason(rawValue: Flags.string(choice["reason"]) ?? "")
                        ?? .unanswered))
        }
    }

    /// Every key this person qualifies for.
    ///
    /// Evaluation only: sends `exposure: false` (INT-7456, round-2 CONTRACT S4), so the service
    /// spends no `ONCE` display and records no exposure for experiences the app may never
    /// render. Before that field, a single `all()` burned the once-only display for every
    /// qualifying experience and inflated the exposure counts `EXP-SERVE-003` relies on. A
    /// service that predates the field ignores it and still records; the exposure for a value
    /// the app does use is recorded by the single-key read that renders it.
    func all(
        context: FlagContext,
        sessionId: String?,
        completion: @escaping ([String: JSONValue]) -> Void
    ) {
        choose(context: context, sessionId: sessionId, names: nil, exposure: false) { choices, _ in
            var out: [String: JSONValue] = [:]
            for choice in choices {
                guard let name = Flags.string(choice["name"]), !name.isEmpty else { continue }
                // Same rule as `detail`, and the same function, so the two cannot drift again:
                // the pair reported different answers for one key until this shared a body.
                guard let value = Flags.servedValue(choice["body"]) else { continue }
                out[name] = value
            }
            completion(out)
        }
    }

    /// A failure yields no choices plus a `FlagError`, never a throw.
    ///
    /// This is the entire reason `defaultValue` is required: a network failure, a 5xx or a timeout
    /// must resolve to the value the caller chose. A flag SDK that throws when the service is
    /// unreachable pushes every call site into writing the same fallback by hand — which is the
    /// opposite of what a kill switch is for. The error goes to `onFlagError` and to
    /// `variationDetail`, so the failure is visible without being in the way (INT-7454).
    private func choose(
        context: FlagContext,
        sessionId: String?,
        names: [String]?,
        exposure: Bool,
        completion: @escaping ([[String: Any]], FlagError?) -> Void
    ) {
        let key = names?.first
        var identification: [String: Any] = ["sourceId": sourceId]
        if let userId = context.userId, !userId.isEmpty { identification["userId"] = userId }
        if let profileId = context.profileId, !profileId.isEmpty {
            identification["profileId"] = profileId
        }

        var body: [String: Any] = [
            "identification": identification,
            "device": Personalization.deviceClass,
        ]
        // Without it `ChooserHelper.allowOncePerSession` stores the literal "default" and every
        // later call fails its `sessionId != null` clause, so a ONCE_PER_VISIT experience is
        // served once EVER per profile rather than once per visit. It also stamps every Kafka
        // `ExperienceChoose` with "default", which makes session-level analysis unattributable.
        if let sessionId, !sessionId.isEmpty { body["sessionId"] = sessionId }
        if let names { body["names"] = names }
        // Absent means "record", the service's default, so a true is never sent.
        if !exposure { body["exposure"] = false }

        let request: URLRequest
        do {
            request = try network.makeRequest(
                endpoint: .chooseApi(org: orgId, project: projectId),
                credentials: credentials,
                body: body)
        } catch {
            return completion([], failed(.badRequest, status: nil, key: key))
        }

        network.send(request) { outcome in
            guard case .success(let data) = outcome else {
                let (kind, status) = Flags.errorKind(for: outcome)
                return completion([], self.failed(kind, status: status, key: key))
            }
            guard
                let data,
                let json = JSONHandler.deserializeData(data) as? [String: Any],
                let choices = json["choices"] as? [[String: Any]]
            else {
                return completion([], self.failed(.parse, status: nil, key: key))
            }
            completion(choices, nil)
        }
    }

    static func errorKind(for outcome: HTTPOutcome) -> (FlagError.Kind, Int?) {
        switch outcome {
        case .retryable(let status, _), .terminal(let status, _):
            switch status {
            case 401, 403: return (.auth, status)
            case 408: return (.timeout, status)
            case 400..<500: return (.badRequest, status)
            default: return (.server, status)
            }
        case .unanswered: return (.timeout, nil)
        case .transport: return (.network, nil)
        case .success: return (.parse, nil)
        }
    }

    /// Logs, notifies `onFlagError`, and returns the error. A rejected key is logged at error
    /// level once per instance (CONTRACT S3): every flag read on a bad key fails the same way,
    /// and one line naming the key prefix and source is what an integrator needs.
    private func failed(_ kind: FlagError.Kind, status: Int?, key: String?) -> FlagError {
        let error = FlagError(key: key, kind: kind, status: status)
        let what = "flag evaluation failed (\(kind.rawValue)\(status.map { " \($0)" } ?? "")); using the default"
        if kind == .auth {
            let first: Bool = lock.write {
                defer { authFailureLogged = true }
                return !authFailureLogged
            }
            IntemptLogger.shared.log(
                first ? .error : .debug,
                "\(what). The service rejected API key prefix \(credentials.prefix) for source "
                    + "\(sourceId): check the key and that it belongs to this source.")
        } else {
            IntemptLogger.shared.log(.debug, what)
        }
        onFlagError?(error)
        return error
    }

    /// A JSON null body is ABSENT, not a served value.
    ///
    /// `.map` alone produces `.some(.null)`, and `?? defaultValue` upstream does not fire on that,
    /// so a null body reached the caller as `JSONValue.null` instead of the default they supplied.
    /// Every other SDK in this effort treats null as absent; this one did not, and no test had
    /// ever exercised the path. `detail` and `all` share this so they cannot answer differently
    /// about one key — they did, until 2026-08-31.
    static func servedValue(_ raw: Any?) -> JSONValue? {
        guard let value = raw.map(JSONValue.from), value != .null else { return nil }
        return value
    }

    static func string(_ value: Any?) -> String? {
        value as? String
    }
}
