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
        // Resolves screen/scene facts on the main thread before any event is
        // enqueued on a background queue.
        AutomaticProperties.warm()

        return instancesLock.write {
            if let existing = instances[instanceName] { return existing }
            let created = IntemptInstance(
                credentials: credentials, orgId: orgId, projectId: projectId,
                sourceId: sourceId, instanceName: instanceName)
            instances[instanceName] = created
            created.automatic.checkVersion()
            created.flusher.startTimer()
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
    let flusher: Flush
    private let personalization: Personalization
    private let flags: Flags
    var automatic: AutomaticEvents!
    /// Held so its observers live as long as the instance; `deinit` removes them.
    private var lifecycle: AppLifecycle!

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
        let db = IntemptDB(namespace: instanceName, directoryOverride: databaseDirectory)
        self.db = db
        self.network = network
        self.flusher = Flush(
            db: db, network: network, credentials: credentials,
            orgId: orgId, projectId: projectId, sourceId: sourceId)
        self.personalization = Personalization(
            network: network, credentials: credentials,
            orgId: orgId, projectId: projectId, sourceId: sourceId)
        self.flags = Flags(
            network: network, credentials: credentials,
            orgId: orgId, projectId: projectId, sourceId: sourceId)

        // `automatic` needs to call back into `self`, so it is built after all
        // stored properties are initialised and captures self weakly.
        let identity = self.identity
        self.automatic = AutomaticEvents(
            namespace: instanceName, store: storeOverride
        ) { [weak self] name, data, userAttributes in
            guard let self else { return }
            self.enqueueAutomatic(
                name: name, data: data, userAttributes: userAttributes,
                sessionId: identity.sessionId)
        }

        self.automatic.emitSessionEnd = { [weak self] sessionId, data, userAttributes in
            guard let self else { return }
            self.enqueueSessionEnd(
                sessionId: sessionId, data: data, userAttributes: userAttributes)
        }

        self.lifecycle = AppLifecycle { [weak self] transition in
            guard let self else { return }
            self.automatic.note(transition)
            switch transition {
            case .background, .terminate:
                // Close the session deliberately rather than waiting for the
                // 30-minute idle rollover: leaving the app IS the end of the
                // session, and a duration that keeps counting while the app is
                // closed is not a session length.
                self.automatic.endSession(self.identity.closeCurrentSession())

                // Hold a background assertion so a flush that starts as the app
                // suspends is not frozen mid-request.
                BackgroundTask.perform { done in
                    self.flusher.flushNow { _ in done() }
                }
            case .foreground:
                self.flusher.startTimer()
            }
        }
    }

    /// Test-only constructor: injects the store, database directory and network.
    ///
    /// Automatic events default to ALL OFF here, unlike production where
    /// sessions are on. A test asserting "track() queued one event" should not
    /// silently also be asserting session-start behaviour; the automatic path
    /// has its own tests. Pass `automaticEvents:` to exercise it.
    static func makeForTesting(
        apiKey: String = "pfx.secret",
        orgId: String = "acme",
        projectId: String = "web",
        sourceId: String = "1",
        instanceName: String = "test-\(UUID().uuidString)",
        store: UserDefaults,
        databaseDirectory: URL,
        network: Network = Network(),
        automaticEvents: AutomaticEventOptions = AutomaticEventOptions(
            sessions: false, versionChanges: false, appStateChanges: false)
    ) throws -> IntemptInstance {
        let instance = IntemptInstance(
            credentials: try IntemptCredentials(apiKey: apiKey),
            orgId: orgId, projectId: projectId, sourceId: sourceId,
            instanceName: instanceName, storeOverride: store,
            databaseDirectory: databaseDirectory, network: network)
        instance.automaticEvents = automaticEvents
        return instance
    }

    // MARK: - Identity accessors

    public var sdkVersion: String { Intempt.sdkVersion }
    public func getProfileId() -> String { identity.profileId }
    public func getSessionId() -> String { identity.sessionId }

    // MARK: - Opt in / out

    public func hasOptedOut() -> Bool { stateQueue.sync { optedOut } }
    /// Whether collection is currently permitted.
    ///
    /// The name the cross-SDK contract settled on, so the same call reads the
    /// same way through a React Native bridge as it does here.
    public func isOptedIn() -> Bool { !hasOptedOut() }

    @available(*, deprecated, renamed: "isOptedIn()")
    public func isUserOptIn() -> Bool { isOptedIn() }

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
                envelope: env, name: EventNames.productAdd, productId: productId, quantity: quantity)
        }
    }

    @discardableResult
    public func productView(productId: String) -> Bool {
        enqueue { env in
            ProductModel(
                envelope: env, name: EventNames.productView, productId: productId, quantity: nil)
        }
    }

    @discardableResult
    public func productOrdered(products: [(productId: String, quantity: Int)]) -> Bool {
        var allOK = true
        for p in products {
            let ok = enqueue { env in
                ProductModel(
                    envelope: env, name: EventNames.productOrdered, productId: p.productId,
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

    // MARK: - Delivery

    /// Seconds between automatic flushes. 0 disables the timer.
    public var flushInterval: TimeInterval {
        get { flusher.flushInterval }
        set { flusher.flushInterval = newValue }
    }

    /// Sends everything queued now.
    /// - Parameter completion: number of events delivered.
    public func flush(completion: ((Int) -> Void)? = nil) {
        flusher.flushNow(completion: completion)
    }

    // MARK: - Personalization

    /// Recommended products from a configured feed.
    ///
    /// - Parameter fields: catalog columns to return. Defaults to a compact
    ///   set on purpose — an unfielded request returns every column including
    ///   raw ML embedding vectors, measured at 443x the payload size
    ///   (docs/CONTRACT.md). Widen it deliberately, never by omission.
    /// - Parameter productId: required by feeds whose input is `PRODUCT`.
    ///   Omitting it there returns an empty list, not an error.
    public func products(
        feedId: String,
        count: Int = 10,
        fields: [String] = Intempt.defaultFeedFields,
        productId: String? = nil,
        completion: @escaping (Result<[ProductRecommendation], IntemptError>) -> Void
    ) {
        personalization.products(
            feedId: feedId,
            profileId: identity.profileId,
            count: count,
            fields: fields,
            productId: productId,
            completion: completion)
    }

    // MARK: - Flags

    /// The value assigned to this person for `key`, or `defaultValue` if the service did not
    /// answer.
    ///
    /// Ask for a KEY, never a mode. Whether the key names an experiment, a personalization or a
    /// flag is the platform's business: its serving query filters on channel and status and never
    /// on mode.
    public func variation(
        key: String,
        context: FlagContext? = nil,
        defaultValue: JSONValue,
        completion: @escaping (JSONValue) -> Void
    ) {
        variationDetailInternal(key: key, context: context, defaultValue: defaultValue) {
            completion($0.value ?? defaultValue)
        }
    }

    /// Internal. NOT public, deliberately.
    ///
    /// It returns a `reason`, and the platform does not send one: a held-back person's experience
    /// is absent from the evaluation response entirely rather than present with a cause. So every
    /// reason would read `off` — including for someone who WAS targeted and did receive the
    /// variant. That is a wrong answer, not a missing one, and a method whose only job is
    /// explaining why must not guess.
    ///
    /// `variation` uses it for the value, which is correct either way. It becomes public when the
    /// serving contract carries a reason.
    func variationDetailInternal(
        key: String,
        context: FlagContext? = nil,
        defaultValue: JSONValue,
        completion: @escaping (FlagDetail) -> Void
    ) {
        // The device identifier is filled in from the SDK's own identity when the caller does not
        // supply one, because it is the value that survives sign-in.
        let resolved = context ?? FlagContext(profileId: identity.profileId)
        flags.detail(key: key, context: resolved, sessionId: identity.sessionId) { detail in
            guard let detail else {
                return completion(FlagDetail(value: defaultValue, reason: .unanswered))
            }
            completion(
                FlagDetail(
                    value: detail.value ?? defaultValue,
                    reason: detail.reason))
        }
    }

    /// Every key assigned to this person, in one call.
    ///
    /// One call, not one per key — and that is the cost as well as the point. The service records
    /// a display for every experience it retrieves, so on a project using the `ONCE` display mode
    /// this consumes the once-only display for every qualifying experience, including ones this
    /// app never renders. Those keys then read as "not enrolled" forever. Use `variation(key:)`
    /// per key where that matters; see the note on `Flags.all`.
    public func allFlags(
        context: FlagContext? = nil,
        completion: @escaping ([String: JSONValue]) -> Void
    ) {
        flags.all(
            context: context ?? FlagContext(profileId: identity.profileId),
            sessionId: identity.sessionId,
            completion: completion)
    }

    public func boolVariation(
        key: String,
        context: FlagContext? = nil,
        defaultValue: Bool,
        completion: @escaping (Bool) -> Void
    ) {
        variation(key: key, context: context, defaultValue: .bool(defaultValue)) { value in
            // A served value of the wrong type is a misconfiguration, not something to coerce:
            // the string "false" is truthy in most languages, and a silent coercion is
            // indistinguishable from a correct answer.
            if case .bool(let b) = value { completion(b) } else { completion(defaultValue) }
        }
    }

    public func stringVariation(
        key: String,
        context: FlagContext? = nil,
        defaultValue: String,
        completion: @escaping (String) -> Void
    ) {
        variation(key: key, context: context, defaultValue: .string(defaultValue)) { value in
            if case .string(let s) = value { completion(s) } else { completion(defaultValue) }
        }
    }

    public func numberVariation(
        key: String,
        context: FlagContext? = nil,
        defaultValue: Double,
        completion: @escaping (Double) -> Void
    ) {
        variation(key: key, context: context, defaultValue: .number(defaultValue)) { value in
            if case .number(let n) = value { completion(n) } else { completion(defaultValue) }
        }
    }

    public func jsonVariation(
        key: String,
        context: FlagContext? = nil,
        defaultValue: [String: JSONValue],
        completion: @escaping ([String: JSONValue]) -> Void
    ) {
        variation(key: key, context: context, defaultValue: .object(defaultValue)) { value in
            if case .object(let o) = value { completion(o) } else { completion(defaultValue) }
        }
    }

    /// Calls back immediately.
    ///
    /// Present so the cross-SDK surface is the same everywhere, and so a caller porting from an
    /// SDK that polls a local flag store does not have to remove the call. Evaluation here is
    /// remote: each `variation` is a request, so there is no local state to wait for.
    ///
    /// - Parameter timeoutMs: ACCEPTED AND IGNORED. It exists so a call site ported from an SDK
    ///   that does poll compiles unchanged. There is nothing to time out on, so passing a value
    ///   does not delay, cap or fail anything — the completion always runs on the calling thread
    ///   before this returns.
    public func waitForInitialization(
        timeoutMs: Int? = nil,
        completion: @escaping () -> Void
    ) {
        completion()
    }

    // MARK: - Enqueue

    /// Single choke point: opt-out gate, property validation, identity rule,
    /// encoding, then persistence. Every entry point above goes through it.
    private func enqueue(_ make: (EventEnvelope) -> IntemptModel) -> Bool {
        // Both of these run OUTSIDE stateQueue, and that is load-bearing.
        // `noteActivity` may emit a session-start event, which re-enters this
        // class's enqueue path — and `DispatchQueue.sync` on a serial queue
        // cannot be re-entered. Doing it inside the lock deadlocks on the first
        // event of every session. `IdentityManager` has its own lock, so
        // ordering these before the barrier is safe.
        identity.recordActivity()

        // A session that rolled on idle has to have its "Session end" emitted
        // BEFORE the new session's start, or the two arrive out of order.
        if let ended = identity.takeEndedSession() {
            automatic.endSession(ended)
        }
        automatic.noteActivity(sessionId: identity.sessionId)
        identity.countEvent()

        return stateQueue.sync {
            guard !optedOut else { return false }

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

    /// Path for events the SDK generates itself.
    ///
    /// Deliberately does NOT call `automatic.noteActivity` — that is what emits
    /// session start, and calling it here would recurse.
    private func enqueueAutomatic(
        name: String,
        data: [String: IntemptType]?,
        userAttributes: [String: IntemptType]?,
        sessionId: String
    ) {
        stateQueue.sync {
            guard !optedOut else { return }

            let model: IntemptModel
            if name == EventNames.sessionStart {
                // intemptjs's shape: no type, eventId == sessionId, no pageId.
                model = SessionModel(
                    sessionId: sessionId,
                    profileId: identity.profileId,
                    name: name,
                    sessionAttributes: data,
                    userAttributes: userAttributes)
            } else if let userAttributes {
                model = RecordModel(
                    envelope: identity.makeEnvelope(), name: name,
                    userId: nil, accountId: nil, data: data,
                    userAttributes: userAttributes, accountAttributes: nil)
            } else {
                model = TrackModel(
                    envelope: identity.makeEnvelope(), name: name, data: data)
            }

            guard let encoded = JSONHandler.encodeAPIData(model.toEnvelopeEntry()) else {
                IntemptLogger.shared.log(.warning, "automatic event '\(name)' dropped: encoding")
                return
            }
            db.insert(.events, data: encoded)
            db.trim(.events, to: QueueConstants.maxQueueSize)
        }
    }

    // MARK: - Autocapture

    /// UIKit autocapture. Off by default; call `start()` after configuring.
    ///
    /// ```swift
    /// intempt.autocapture.configure(.all)
    /// intempt.autocapture.start()
    /// ```
    public private(set) lazy var autocapture: Autocapture = {
        Autocapture { [weak self] name, properties in
            guard let self else { return }
            _ = self.track(eventTitle: name, data: properties)
        }
    }()

    // MARK: - Push (APNs)

    /// Registers the APNs device token from
    /// `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`.
    ///
    /// Pass the raw `Data`. Do not stringify it first — the widespread
    /// `token.description` idiom has produced the literal "32 bytes" since
    /// iOS 13.
    ///
    /// Sent as `apns_token_<sourceId>` on an "App Install/Upgrade" event, which
    /// is precisely how the Android SDK sends `fcm_token_<sourceId>`. The
    /// destinations job finds it by the `apns_token_` prefix.
    @discardableResult
    public func setPushToken(_ deviceToken: Data) -> Bool {
        guard Push.isPlausible(deviceToken) else {
            IntemptLogger.shared.log(
                .error,
                "push token rejected: \(deviceToken.count) bytes is too short to be an APNs token "
                    + "— pass the raw Data from the registration callback, not a string")
            return false
        }
        let hex = Push.hexString(from: deviceToken)
        // Per-source attribute name, exactly as the Android SDK builds
        // "fcm_token_<sourceId>". The source initialisation renames the
        // schema's placeholder `device_token` field to this, so a flat name
        // matches no column and the token is silently dropped after a 201.
        return record(
            eventTitle: EventNames.appInstallUpgrade,
            userAttributes: [EventKeys.apnsToken(sourceId: sourceId): hex])
    }

    /// Reports that a push was opened. Call from
    /// `userNotificationCenter(_:didReceive:withCompletionHandler:)`.
    ///
    /// The notification body is never read — only the campaign identifier and
    /// the developer-authored title.
    @discardableResult
    public func trackPushOpen(_ userInfo: [AnyHashable: Any]) -> Bool {
        track(eventTitle: EventNames.pushOpened, data: Push.attribution(from: userInfo))
    }

    /// Reports a silent or foreground push arrival. Call from
    /// `application(_:didReceiveRemoteNotification:fetchCompletionHandler:)`.
    @discardableResult
    public func trackPushReceived(_ userInfo: [AnyHashable: Any]) -> Bool {
        track(eventTitle: EventNames.pushReceived, data: Push.attribution(from: userInfo))
    }

    /// Enqueues a "Session end" for a session that has already finished.
    ///
    /// Takes the ended session's id explicitly: by the time this runs the
    /// current session is a different one, and stamping the event with that
    /// would attribute the duration to the wrong session.
    private func enqueueSessionEnd(
        sessionId: String,
        data: [String: IntemptType],
        userAttributes: [String: IntemptType]
    ) {
        stateQueue.sync {
            guard !optedOut else { return }
            let model = SessionEndModel(
                sessionId: sessionId,
                profileId: identity.profileId,
                name: EventNames.sessionEnd,
                data: data,
                userAttributes: userAttributes)
            guard let encoded = JSONHandler.encodeAPIData(model.toEnvelopeEntry()) else { return }
            db.insert(.events, data: encoded)
            db.trim(.events, to: QueueConstants.maxQueueSize)
        }
    }

    // MARK: - Autocapture configuration

    /// Which lifecycle events the SDK emits on its own.
    ///
    /// Only sessions are on by default. An SDK that silently starts writing
    /// events the integrator never asked for is how an event-volume bill
    /// surprises someone.
    public var automaticEvents: AutomaticEventOptions {
        get {
            AutomaticEventOptions(
                sessions: automatic.options.sessions,
                versionChanges: automatic.options.versionChanges,
                appStateChanges: automatic.options.appStateChanges)
        }
        set {
            automatic.options = AutomaticEvents.Options(
                sessions: newValue.sessions,
                versionChanges: newValue.versionChanges,
                appStateChanges: newValue.appStateChanges)
        }
    }

    /// Test seam — queued event count.
    func queuedEventCount() -> Int { db.count(.events) }
    func queuedConsentCount() -> Int { db.count(.consents) }
}
