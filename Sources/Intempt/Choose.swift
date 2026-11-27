import Foundation

/// One served experience or personalization. Production choose-api returns only `name`, `group`
/// and `body`; `experienceId`, `variantId` and `reason` are present only on audience-service builds
/// that send them.
public struct Choice: Sendable, Equatable {
    public let name: String
    public let group: String?
    /// `.null` when the row carried no body.
    public let body: JSONValue
    public let experienceId: Int?
    public let variantId: Int?
    public let reason: String?

    init(
        name: String, group: String? = nil, body: JSONValue, experienceId: Int? = nil,
        variantId: Int? = nil, reason: String? = nil
    ) {
        self.name = name
        self.group = group
        self.body = body
        self.experienceId = experienceId
        self.variantId = variantId
        self.reason = reason
    }
}

/// Experiments and personalizations over `POST /optimization/choose-api`, ported from
/// intempt-node `src/choose.ts` (D13: one `choose()`, no per-mode methods). Shares only the
/// transport's `FlagReply` with the flag evaluator; flags never come through here (D20).
///
/// Every failure, a malformed call included, completes with `[]` after one log line: the caller
/// renders its fallback, which is what an unserved experiment looks like anyway. Node rejects a
/// malformed call instead; a completion-handler API has no throw to give the caller.
final class Choose {

    struct Deps {
        var sourceId: String
        var device: String
        var post: ([String: Any], @escaping (FlagReply) -> Void) -> Void
    }

    private let deps: Deps

    init(deps: Deps) {
        self.deps = deps
    }

    /// Leaving out `names` AND `groups` is not "ask for everything", it is "evaluate everything":
    /// on this endpoint an evaluation is an exposure and spends every `once` gate the person is
    /// eligible for. `disableExposure` sends `exposure: false`, which the service honours since
    /// CONTRACT-R2 §S4; an older backend ignores it and records anyway.
    func choose(
        context: FlagContext,
        sessionId: String?,
        names: [String]?,
        groups: [String]?,
        disableExposure: Bool,
        completion: @escaping ([Choice]) -> Void
    ) {
        if let problem = invalid(context, names: names, groups: groups) {
            IntemptLogger.shared.log(.error, "choose: \(problem); returning no choices")
            return completion([])
        }

        var identification: [String: Any] = ["sourceId": deps.sourceId]
        if let userId = context.userId, !userId.isEmpty { identification["userId"] = userId }
        if let profileId = context.profileId, !profileId.isEmpty {
            identification["profileId"] = profileId
        }
        var body: [String: Any] = ["identification": identification, "device": deps.device]
        if let names { body["names"] = names }
        if let groups { body["groups"] = groups }
        // Without it `ChooserHelper.allowOncePerSession` stores the literal "default", and a
        // ONCE_PER_VISIT experience is served once ever per profile rather than once per visit.
        if let sessionId, !sessionId.isEmpty { body["sessionId"] = sessionId }
        if disableExposure { body["exposure"] = false }

        deps.post(body) { reply in
            switch reply {
            case .failed(let kind, let status):
                IntemptLogger.shared.log(
                    kind == .auth ? .error : .warning,
                    "choose: request failed (\(kind.rawValue)\(status.map { " \($0)" } ?? "")), "
                        + "returning no choices")
                completion([])
            case .answered(let data):
                guard
                    let data,
                    let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                    let rows = object["choices"] as? [Any]
                else {
                    IntemptLogger.shared.log(
                        .warning, "choose: reply has no choices array, returning no choices")
                    return completion([])
                }
                completion(rows.compactMap(Choose.choice))
            }
        }
    }

    /// `ExperienceApiChooseRequest.names`: `^[a-zA-Z0-9_-]*$`, tightened to reject the empty string.
    static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name.unicodeScalars.allSatisfy(nameCharacters.contains)
    }

    private static let nameCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")

    static func choice(_ raw: Any) -> Choice? {
        guard case .object(let row) = JSONValue.from(raw), case .string(let name)? = row["name"]
        else { return nil }
        func string(_ field: String) -> String? {
            if case .string(let s)? = row[field] { return s }
            return nil
        }
        func integer(_ field: String) -> Int? {
            if case .number(let n)? = row[field] { return Int(exactly: n) }
            return nil
        }
        return Choice(
            name: name, group: string("group"), body: row["body"] ?? .null,
            experienceId: integer("experienceId"), variantId: integer("variantId"),
            reason: string("reason"))
    }

    /// Same identity rule as the flag routes, and the server's own name pattern, checked before the
    /// round trip: `requestToMono` refuses the whole body on one bad entry.
    private func invalid(_ context: FlagContext, names: [String]?, groups: [String]?) -> String? {
        let present = { (v: String?) in
            !(v ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if !present(context.userId) && !(present(context.profileId) && present(deps.sourceId)) {
            return "context needs either userId, or profileId together with a sourceId"
        }
        for (field, values) in [("names", names), ("groups", groups)] {
            if let bad = values?.first(where: { !Choose.isValidName($0) }) {
                return "\(field) entries must match ^[a-zA-Z0-9_-]+$, got \"\(bad)\""
            }
        }
        return nil
    }
}
