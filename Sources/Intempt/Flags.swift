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
/// 3. `variationDetail` is NOT exposed. It would carry a `reason` the platform does not send, so
///    it could not tell a deliberate off state
///    from a request the service never answered — which is exactly why this SDK exposed no
///    assignment at all until the serving contract could distinguish the two.
/// 4. Evaluation is REMOTE only. There is no local rule engine and no flag store to poll.

/// Why an evaluation returned the value it did.
enum FlagReason: String, Sendable, Equatable {
    case targeted
    case holdout
    case notTargeted = "not_targeted"
    case off
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

/// A value and why it was returned. INTERNAL — see the note on `variationDetailInternal`.
struct FlagDetail: Sendable, Equatable {
    let value: JSONValue?
    let reason: FlagReason

    init(value: JSONValue?, reason: FlagReason) {
        self.value = value
        self.reason = reason
    }
}

// MARK: - Client

/// Fetch-and-return, like `Personalization`. Nothing is queued or retried: a flag answer is only
/// useful while the caller is deciding what to render.
final class Flags {

    /// A response the service did not answer is reported as such rather than guessed at.
    static let unanswered: FlagReason = .off

    private let network: Network
    private let credentials: IntemptCredentials
    private let orgId: String
    private let projectId: String
    private let sourceId: String

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

    func detail(
        key: String,
        context: FlagContext,
        completion: @escaping (FlagDetail?) -> Void
    ) {
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // A programming error, not a runtime condition: nil tells the caller to use its
            // default, and the precondition message names the mistake in a debug build.
            assertionFailure("variation: key must not be empty")
            return completion(nil)
        }

        choose(context: context, names: [key]) { choices in
            guard let choice = choices.first(where: { Flags.string($0["name"]) == key }) else {
                return completion(nil)
            }
            completion(
                FlagDetail(
                    value: choice["body"].map(JSONValue.from),
                    reason: FlagReason(rawValue: Flags.string(choice["reason"]) ?? "")
                        ?? Flags.unanswered))
        }
    }

    func all(context: FlagContext, completion: @escaping ([String: JSONValue]) -> Void) {
        choose(context: context, names: nil) { choices in
            var out: [String: JSONValue] = [:]
            for choice in choices {
                guard let name = Flags.string(choice["name"]), !name.isEmpty else { continue }
                out[name] = choice["body"].map(JSONValue.from) ?? .null
            }
            completion(out)
        }
    }

    /// A transport failure yields no choices rather than an error the caller must handle.
    ///
    /// This is the entire reason `defaultValue` is required: a network failure, a 5xx or a timeout
    /// must resolve to the value the caller chose. A flag SDK that surfaces an error when the
    /// service is unreachable pushes every call site into writing the same fallback by hand —
    /// which is the opposite of what a kill switch is for.
    private func choose(
        context: FlagContext,
        names: [String]?,
        completion: @escaping ([[String: Any]]) -> Void
    ) {
        var identification: [String: Any] = ["sourceId": sourceId]
        if let userId = context.userId, !userId.isEmpty { identification["userId"] = userId }
        if let profileId = context.profileId, !profileId.isEmpty {
            identification["profileId"] = profileId
        }

        var body: [String: Any] = [
            "identification": identification,
            "device": Personalization.deviceClass,
        ]
        if let names { body["names"] = names }

        let request: URLRequest
        do {
            request = try network.makeRequest(
                endpoint: .chooseApi(org: orgId, project: projectId),
                credentials: credentials,
                body: body)
        } catch {
            return completion([])
        }

        network.send(request) { outcome in
            guard
                case .success(let data) = outcome,
                let data,
                let json = JSONHandler.deserializeData(data) as? [String: Any],
                let choices = json["choices"] as? [[String: Any]]
            else {
                return completion([])
            }
            completion(choices)
        }
    }

    static func string(_ value: Any?) -> String? {
        value as? String
    }
}
