//
//  IntemptInstance.swift
//  Intempt
//
//  Structure adapted from mixpanel-swift's MixpanelInstance.swift +
//  Mixpanel.swift (https://github.com/mixpanel/mixpanel-swift)
//  Copyright © 2016-2025 Mixpanel. All rights reserved.
//  Licensed under the Apache License, Version 2.0.
//
//  Modifications by Intempt Technologies, Inc. (Apache License 2.0, §4(b)):
//    - Intempt's public API surface and wire models throughout.
//    - `initialize` collects org / project / sourceId, which the endpoints
//      require, and THROWS on blank input. The old Obj-C SDK logged an error
//      and continued: NSAssert compiles out in Release, so blank credentials
//      produced requests to ".../(null)/projects/(null)/..." forever (F-04).
//    - Opt-out performs a full purge AND clears identity. intemptjs only
//      sets a flag and leaves the queue intact.
//    - consent(.reject) routes through the same gate as optOut. The old SDK
//      recorded the answer and gated nothing (F-42).
//
//  Retained from upstream: one serial queue owns all mutable state, and every
//  public entry point dispatches onto it. This is the structural reason the
//  old SDK's unsynchronised-ivar races cannot occur here.
//
import Foundation

public final class IntemptInstance {

    // MARK: - Manager

    private static var instances: [String: IntemptInstance] = [:]
    private static let instancesLock = ReadWriteLock(label: "com.intempt.instances")

    /// Creates or returns the named instance.
    ///
    /// - Throws: `IntemptError.malformedAPIKey` if the key is not
    ///   `prefix.secret`; `IntemptError.missingConfiguration` if any
    ///   identifier is blank.
    @discardableResult
    public static func initialize(
        apiKey: String,
        orgId: String,
        projectId: String,
        sourceId: String,
        instanceName: String = "default"
    ) throws -> IntemptInstance {
        let credentials = try IntemptCredentials(apiKey: apiKey)
        for (value, field) in [(orgId, "orgId"), (projectId, "projectId"), (sourceId, "sourceId")] {
            guard !value.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw IntemptError.missingConfiguration(field: field)
            }
        }
        return instancesLock.write {
            if let existing = instances[instanceName] { return existing }
            let created = IntemptInstance(
                credentials: credentials, orgId: orgId, projectId: projectId,
                sourceId: sourceId, instanceName: instanceName)
            instances[instanceName] = created
            return created
        }
    }

    public static func mainInstance() -> IntemptInstance? {
        instancesLock.read { instances["default"] }
    }

    public static func instance(named name: String) -> IntemptInstance? {
        instancesLock.read { instances[name] }
    }

    /// Test seam — drops all registered instances.
    static func removeAllInstances() {
        instancesLock.write { instances.removeAll() }
    }

    // MARK: - State

    let credentials: IntemptCredentials
    let orgId: String
    let projectId: String
    let sourceId: String
    let instanceName: String

    let identity: IdentityManager
    let db: IntemptDB
    private let network: Network

    /// Sole owner of mutable state. Every public method funnels through it.
    private let stateQueue: DispatchQueue
    private var optedOut = false

    private init(
        credentials: IntemptCredentials,
        orgId: String,
        projectId: String,
        sourceId: String,
        instanceName: String,
        storeOverride: UserDefaults = .standard,
        databaseDirectory: URL? = nil,
        network: Network = Network()
    ) {
        self.credentials = credentials
        self.orgId = orgId
        self.projectId = projectId
        self.sourceId = sourceId
        self.instanceName = instanceName
        self.stateQueue = DispatchQueue(label: "com.intempt.instance.\(instanceName)", qos: .utility)
        self.identity = IdentityManager(namespace: instanceName, store: storeOverride)
        self.db = IntemptDB(namespace: instanceName, directoryOverride: databaseDirectory)
        self.network = network
    }

    /// Test-only constructor: injects the store, database directory and network.
    static func makeForTesting(
        apiKey: String = "pfx.secret",
        orgId: String = "acme",
        projectId: String = "web",
        sourceId: String = "1",
        instanceName: String = "test-\(UUID().uuidString)",
        store: UserDefaults,
        databaseDirectory: URL,
        network: Network = Network()
    ) throws -> IntemptInstance {
        IntemptInstance(
            credentials: try IntemptCredentials(apiKey: apiKey),
            orgId: orgId, projectId: projectId, sourceId: sourceId,
            instanceName: instanceName, storeOverride: store,
            databaseDirectory: databaseDirectory, network: network)
    }

    // MARK: - Identity accessors

    public var sdkVersion: String { Intempt.sdkVersion }
    public func getProfileId() -> String { identity.profileId }
    public func getSessionId() -> String { identity.sessionId }

    // MARK: - Opt in / out

    public func hasOptedOut() -> Bool { stateQueue.sync { optedOut } }
    public func isUserOptIn() -> Bool { !hasOptedOut() }

    /// Stops collection AND discards everything already collected. Merely
    /// setting a flag — which is all intemptjs does — leaves queued events to
    /// be uploaded after the user has objected.
    ///
    /// Pending CONSENT records are deliberately preserved: they are the
    /// evidence of the user's decision and must still reach the server.
    /// Purging them would mean a withdrawal is never recorded anywhere — a
    /// test caught exactly that.
    public func optOut() {
        stateQueue.sync {
            optedOut = true
            db.deleteAll(.events)
            identity.reset()
        }
    }

    public func optIn() {
        stateQueue.sync { optedOut = false }
    }

    // MARK: - Lifecycle

    /// Rotates the anonymous identity so the next user on a shared device
    /// cannot inherit the previous one.
    public func logOut() {
        stateQueue.sync { identity.logOut() }
    }

    /// New anonymous identity and an empty queue.
    public func reset() {
        stateQueue.sync {
            db.deleteAll(.events)
            identity.reset()
        }
    }

    // MARK: - Tracking

    @discardableResult
    public func track(eventTitle: String, data: [String: IntemptType]? = nil) -> Bool {
        enqueue { env in
            TrackModel(envelope: env, name: eventTitle, data: data)
        }
    }

    @discardableResult
    public func identify(
        userId: String,
        eventTitle: String = "Identify",
        userAttributes: [String: IntemptType]? = nil,
        data: [String: IntemptType]? = nil
    ) -> Bool {
        enqueue { env in
            IdentifyModel(
                envelope: env, name: eventTitle, userId: userId,
                userAttributes: userAttributes, data: data)
        }
    }

    /// Intempt's account concept. Note `accountAttributes` — the old Obj-C
    /// SDK named this parameter `userAttributes` while sending an account.
    @discardableResult
    public func group(
        accountId: String,
        eventTitle: String = "Identify",
        accountAttributes: [String: IntemptType]? = nil
    ) -> Bool {
        enqueue { env in
            GroupModel(
                envelope: env, name: eventTitle, accountId: accountId,
                accountAttributes: accountAttributes)
        }
    }

    @discardableResult
    public func alias(userId: String, anotherUserId: String) -> Bool {
        enqueue { env in
            AliasModel(
                eventId: env.eventId, profileId: env.profileId,
                userId: userId, anotherUserId: anotherUserId)
        }
    }

    @discardableResult
    public func record(
        eventTitle: String,
        userId: String? = nil,
        accountId: String? = nil,
        data: [String: IntemptType]? = nil,
        userAttributes: [String: IntemptType]? = nil,
        accountAttributes: [String: IntemptType]? = nil
    ) -> Bool {
        enqueue { env in
            RecordModel(
                envelope: env, name: eventTitle, userId: userId, accountId: accountId,
                data: data, userAttributes: userAttributes, accountAttributes: accountAttributes)
        }
    }

    @discardableResult
    public func productAdd(productId: String, quantity: Int) -> Bool {
        enqueue { env in
            ProductModel(
                envelope: env, name: "Product Add", productId: productId, quantity: quantity)
        }
    }

    @discardableResult
    public func productView(productId: String) -> Bool {
        enqueue { env in
            ProductModel(
                envelope: env, name: "Product View", productId: productId, quantity: nil)
        }
    }

    @discardableResult
    public func productOrdered(products: [(productId: String, quantity: Int)]) -> Bool {
        var allOK = true
        for p in products {
            let ok = enqueue { env in
                ProductModel(
                    envelope: env, name: "Product Ordered", productId: p.productId,
                    quantity: p.quantity)
            }
            allOK = allOK && ok
        }
        return allOK
    }

    // MARK: - Consent

    /// Records the answer AND enforces it. `.reject` runs the same gate as
    /// `optOut()`: collection stops and queued events are purged.
    @discardableResult
    public func consent(
        action: ConsentAction,
        validUntil: TimeInterval,
        email: String? = nil,
        message: String? = nil,
        category: String? = nil
    ) -> Bool {
        let model = ConsentModel(
            action: action,
            profileId: identity.profileId,
            sourceId: sourceId,
            source: Self.platformName,
            validUntil: validUntil,
            email: email, message: message, category: category)

        // Consent is transmitted even when opted out — a withdrawal must reach
        // the server. It goes to its own endpoint, unbatched.
        let stored = stateQueue.sync { () -> Bool in
            guard let data = JSONHandler.encodeAPIData(model.toPayload()) else { return false }
            return db.insert(.consents, data: data)
        }

        switch action {
        case .reject: optOut()
        case .accept: optIn()
        }
        return stored
    }

    static var platformName: String {
        #if os(iOS)
            return "ios"
        #elseif os(tvOS)
            return "tvos"
        #elseif os(watchOS)
            return "watchos"
        #elseif os(macOS)
            return "macos"
        #else
            return "unknown"
        #endif
    }

    // MARK: - Enqueue

    /// Single choke point: opt-out gate, property validation, identity rule,
    /// encoding, then persistence. Every entry point above goes through it.
    private func enqueue(_ make: (EventEnvelope) -> IntemptModel) -> Bool {
        stateQueue.sync {
            guard !optedOut else { return false }

            identity.recordActivity()
            let model = make(identity.makeEnvelope())
            let payload = model.toPayload()

            // Reject NaN/unsupported values at the boundary rather than
            // discovering it at encode time.
            for (key, value) in payload {
                if let typed = value as? IntemptType, !typed.isValidNestedTypeAndValue() {
                    IntemptLogger.shared.log(
                        .warning, "\(model.type) dropped: invalid value for '\(key)'")
                    return false
                }
            }

            do {
                try PayloadValidator.validate(payload)
            } catch {
                IntemptLogger.shared.log(.warning, "\(model.type) dropped: \(error)")
                return false
            }

            guard let data = JSONHandler.encodeAPIData(model.toEnvelopeEntry()) else {
                IntemptLogger.shared.log(.warning, "\(model.type) dropped: encoding failed")
                return false
            }

            let inserted = db.insert(.events, data: data)
            db.trim(.events, to: QueueConstants.maxQueueSize)
            return inserted
        }
    }

    /// Test seam — queued event count.
    func queuedEventCount() -> Int { db.count(.events) }
    func queuedConsentCount() -> Int { db.count(.consents) }
}
