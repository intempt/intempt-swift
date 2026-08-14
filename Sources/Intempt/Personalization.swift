//
//  Personalization.swift
//  Intempt
//
//  Copyright © 2026 Intempt Technologies, Inc.
//  Licensed under the Apache License, Version 2.0.
//
//  No mixpanel-swift equivalent: Mixpanel has no content-serving product, and
//  its feature-flag module is a different thing that Intempt does not offer.
//
//  Every request and response shape here was verified against production
//  (docs/CONTRACT.md), not derived from a spec:
//
//    - choose-api takes a nested `identification` object. An earlier draft of
//      our plan had an `optimizationType` discriminator and a `names` array;
//      neither exists. The live endpoint 400s with "Identification is required"
//      when the wrapper is missing.
//    - feeds/{id}/data takes a FLAT body — profileId and sourceId at the top
//      level, NOT identification-wrapped. The two endpoints genuinely differ.
//    - `fields` is defaulted, never omitted. A feed request without it returns
//      every column, including raw ML embedding vectors: 222,919 bytes versus
//      503 for the same 10 products. 443x, on a cellular connection, for a
//      recommendation strip.
//
import Foundation

// MARK: - Experiments

/// One active experiment or personalization assignment.
public struct ExperimentChoice: Equatable, Sendable {
    /// Experience id the assignment belongs to.
    public let experience: String
    /// Assigned variant id. This is what a caller branches on.
    public let variant: String
    /// Server-side target the experience was configured against.
    public let target: String?
    /// The experiment or experience NAME, when the server returns one.
    ///
    /// Present when the request asked for specific `names`. A `choose-web`
    /// response carries no name — only ids — so this is nil there. The
    /// deprecated Objective-C SDK's consumers matched on this field, so it is
    /// surfaced rather than discarded.
    public let name: String?
    /// Variant payload the server attached, when present. Untyped for the same
    /// reason as `changes`: the shape is authored server-side.
    public let body: JSONValue?
    /// Change descriptors. Native has no DOM to mutate, so these are passed
    /// through rather than applied — a caller reads them to drive its own UI.
    ///
    /// `JSONValue` rather than `[String: Any]`: the shape is owned by the web
    /// editor and modelling it as a struct would go stale silently, but `Any`
    /// cannot be `Sendable`, so this type could not cross a concurrency
    /// boundary and would be a hard error under the Swift 6 language mode.
    public let changes: [JSONValue]
    public let updatedAt: Date?
}

// MARK: - Products

/// One recommended product. Attributes are whatever `fields` asked for, so the
/// payload is exposed as a dictionary rather than a fixed struct — a feed can
/// be configured with arbitrary catalog columns.
public struct ProductRecommendation: Equatable, Sendable {
    public let attributes: [String: String]

    public var productId: String? { attributes["productId"] }
    public var title: String? { attributes["title"] }
    public var imageURL: String? { attributes["imageUrl"] }
    public var url: String? { attributes["url"] }
    public var price: Double? { attributes["price"].flatMap(Double.init) }

    public subscript(key: String) -> String? { attributes[key] }
}

// MARK: - Client

/// Fetch-and-return. Nothing here is queued or retried: a personalization
/// response is only useful while the user is looking at the screen, so a stale
/// one delivered minutes later is worse than none.
final class Personalization {

    private let network: Network
    private let credentials: IntemptCredentials
    private let orgId: String
    private let projectId: String
    private let sourceId: String

    /// Omitting `fields` returns raw embedding vectors — see the header note.
    /// Declared publicly on `Intempt` so it can be a default argument on the
    /// public API; aliased here for the internal call sites.
    static var defaultFields: [String] { Intempt.defaultFeedFields }

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

    // MARK: Experiments

    func experiments(
        profileId: String,
        sessionId: String,
        names: [String]? = nil,
        groups: [String]? = nil,
        optimizationType: OptimizationType? = nil,
        productId: String? = nil,
        completion: @escaping (Result<[ExperimentChoice], IntemptError>) -> Void
    ) {
        var body: [String: Any] = [
            "identification": [
                "sourceId": sourceId,
                "profileId": profileId,
            ],
            "sessionId": sessionId,
            "device": Self.deviceClass,
        ]
        if let productId { body["productId"] = productId }
        // Verified accepted by production (200). intemptjs does not send these —
        // it asks for everything matching the current URL — but the deprecated
        // Objective-C SDK did, via chooseExperimentsByNames /
        // choosePersonalizationsByNames, and apps built on it select by name.
        // Omitted entirely when nil so the intemptjs behaviour stays the default.
        if let names, !names.isEmpty { body["names"] = names }
        if let groups, !groups.isEmpty { body["groups"] = groups }
        if let optimizationType { body["optimizationType"] = optimizationType.rawValue }

        send(endpoint: .chooseApi(org: orgId, project: projectId), body: body) { result in
            completion(result.map(Self.parseChoices))
        }
    }

    static func parseChoices(_ json: [String: Any]) -> [ExperimentChoice] {
        guard let raw = json["choices"] as? [[String: Any]] else { return [] }
        return raw.compactMap { item in
            // A choice with no variant carries no assignment, so it cannot be
            // branched on. Dropping it beats handing back a half-built value.
            guard let variant = Self.string(item["variant"]),
                let experience = Self.string(item["experience"])
            else { return nil }
            return ExperimentChoice(
                experience: experience,
                variant: variant,
                target: Self.string(item["target"]),
                name: Self.string(item["name"]),
                body: item["body"].map(JSONValue.from),
                changes: (item["changes"] as? [Any])?.map(JSONValue.from) ?? [],
                updatedAt: (item["updatedAt"] as? NSNumber).map {
                    // Server sends epoch milliseconds.
                    Date(timeIntervalSince1970: $0.doubleValue / 1000)
                })
        }
    }

    // MARK: Products

    func products(
        feedId: String,
        profileId: String,
        count: Int,
        fields: [String],
        productId: String? = nil,
        completion: @escaping (Result<[ProductRecommendation], IntemptError>) -> Void
    ) {
        // An empty `fields` would be serialised as `[]`, which the server treats
        // the same as absent — and absent means embedding vectors. Fall back.
        let resolved = fields.isEmpty ? Self.defaultFields : fields

        var body: [String: Any] = [
            "profileId": profileId,
            "sourceId": sourceId,
            "limit": max(1, count),
            "fields": resolved,
        ]
        if let productId { body["productId"] = productId }

        send(
            endpoint: .feed(org: orgId, project: projectId, feedId: feedId),
            body: body
        ) { result in
            completion(result.map(Self.parseProducts))
        }
    }

    static func parseProducts(_ json: [String: Any]) -> [ProductRecommendation] {
        guard let raw = json["products"] as? [[String: Any]] else { return [] }
        return raw.map { item in
            var attributes: [String: String] = [:]
            for (key, value) in item {
                // Nulls are omitted rather than rendered "<null>", and vector
                // columns are skipped: if a caller widened `fields` far enough
                // to include one, it is megabytes of no use to a UI.
                switch value {
                case is NSNull: continue
                case let s as String: attributes[key] = s
                case let n as NSNumber: attributes[key] = Self.plain(n)
                case is [Any]: continue
                case is [String: Any]: continue
                default: attributes[key] = String(describing: value)
                }
            }
            return ProductRecommendation(attributes: attributes)
        }
    }

    /// Renders a JSON number the way a label should show it.
    ///
    /// `NSNumber.stringValue` already does the right thing for every numeric
    /// case: 0.0 → "0", 8458.0 → "8458", 129.99 → "129.99". An explicit
    /// integer branch here produced byte-identical output on every input
    /// tested, so it was removed rather than kept as code no test could
    /// distinguish. What `stringValue` gets *wrong* is booleans.
    static func plain(_ n: NSNumber) -> String {
        // CFBoolean bridges to NSNumber, and its stringValue is "1"/"0" —
        // rendering `true` identically to the integer 1 and losing the type.
        if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
        return n.stringValue
    }

    // MARK: Transport

    private func send(
        endpoint: Endpoint,
        body: [String: Any],
        completion: @escaping (Result<[String: Any], IntemptError>) -> Void
    ) {
        let request: URLRequest
        do {
            request = try network.makeRequest(
                endpoint: endpoint, credentials: credentials, body: body)
        } catch let error as IntemptError {
            return completion(.failure(error))
        } catch {
            return completion(.failure(.encodingFailed))
        }

        network.send(request) { outcome in
            switch outcome {
            case .success(let data):
                guard let data, let json = JSONHandler.deserializeData(data) as? [String: Any]
                else {
                    // 2xx with an unreadable body: nothing to serve, but not a
                    // failure the caller can act on either.
                    return completion(.success([:]))
                }
                completion(.success(json))

            case .retryable(let status, let after):
                completion(.failure(.retryable(status: status, retryAfter: after)))

            case .terminal(let status, let body):
                // "Invalid feed id: nonexistent" is actionable; "400" is not.
                if let messages = IntemptError.serverMessages(from: body) {
                    completion(.failure(.server(status: status, messages: messages)))
                } else {
                    completion(.failure(.terminal(status: status)))
                }

            case .transport(let description):
                completion(.failure(.transport(description: description)))
            }
        }
    }

    /// The value the server's targeting rules expect. intemptjs sends
    /// "desktop"/"mobile"; a phone and a watch are both "mobile" to it.
    static var deviceClass: String {
        #if os(tvOS)
            return "tv"
        #elseif os(macOS)
            return "desktop"
        #else
            return "mobile"
        #endif
    }

    static func string(_ value: Any?) -> String? {
        switch value {
        case let s as String: return s
        case let n as NSNumber: return plain(n)
        default: return nil
        }
    }
}
