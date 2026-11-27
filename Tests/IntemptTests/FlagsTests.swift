import XCTest

@testable import Intempt

/// The cross-SDK flag surface, per `docs/SDK-API-CONTRACT.md` and intempt-node's flag evaluator.
///
/// The assertions that matter are the failure ones. A flag SDK is judged on what it returns when
/// the service is unreachable, not on the happy path.
final class FlagsTests: XCTestCase {

    // These strings are the WIRE vocabulary of audience-service `FlagValue.reason`; a raw value
    // edited to match the Swift case name would silently stop matching the server.
    func testReasonWireValues() {
        XCTAssertEqual(FlagReason.targeted.rawValue, "targeted")
        XCTAssertEqual(FlagReason.off.rawValue, "off")
        XCTAssertEqual(FlagReason.killed.rawValue, "killed")
        XCTAssertEqual(FlagReason.notTargeted.rawValue, "not_targeted")
        XCTAssertEqual(FlagReason.notInRollout.rawValue, "not_in_rollout")
        XCTAssertEqual(FlagReason.notClientSide.rawValue, "not_client_side")
        XCTAssertEqual(FlagErrorCode.flagNotFound.rawValue, "FLAG_NOT_FOUND")
        XCTAssertEqual(FlagErrorCode.typeMismatch.rawValue, "TYPE_MISMATCH")
        XCTAssertEqual(FlagErrorCode.targetingKeyMissing.rawValue, "TARGETING_KEY_MISSING")
        XCTAssertEqual(FlagErrorCode.general.rawValue, "GENERAL")
    }

    func testUnansweredIsNotOff() {
        // EXP-SERVE-001: a caller must be able to tell a deliberate off state from a request the
        // service did not answer.
        XCTAssertNotEqual(FlagReason.unanswered, FlagReason.off)
        XCTAssertNotEqual(FlagReason.unanswered, FlagReason.notTargeted)
    }

    func testAKeyTheServerWouldRefuseIsRejectedBeforeTheRoundTrip() {
        XCTAssertFalse(Flags.isValidKey("checkout.new"), "a dot is outside ^[a-zA-Z0-9_-]*$")
        XCTAssertFalse(Flags.isValidKey("new checkout"), "a space is outside it")
        XCTAssertFalse(Flags.isValidKey("pricing:cta"), "a colon is outside it")
        XCTAssertFalse(Flags.isValidKey("flag/one"), "a slash is outside it")
        XCTAssertFalse(Flags.isValidKey("café"), "the pattern is ASCII; é is not in it")
        XCTAssertFalse(Flags.isValidKey(""), "stricter than the server on purpose — * admits empty")
    }

    func testTheKeysIntegratorsActuallyWriteAreAccepted() {
        XCTAssertTrue(Flags.isValidKey("new_checkout"))
        XCTAssertTrue(Flags.isValidKey("pricing-cta"))
        XCTAssertTrue(Flags.isValidKey("Flag2"))
        XCTAssertTrue(Flags.isValidKey("_leading"))
        XCTAssertTrue(Flags.isValidKey("-leading"))
        XCTAssertTrue(Flags.isValidKey("a"))
    }
}

/// A scripted flag transport, stream and clock. Every reply is delivered synchronously unless
/// `hold` is set, so a read's result is available when `detail` returns.
final class FakeFlagRemote {

    struct Call {
        let route: FlagRoute
        let body: [String: Any]
    }

    private let lock = NSLock()
    private var _calls: [Call] = []
    var replies: [FlagRoute: [FlagReply]] = [:]
    var fallback: FlagReply = .failed(.server, status: 500)
    var hold = false
    private var held: [() -> Void] = []

    private(set) var streams: [StreamHandlers] = []
    private(set) var streamCloses = 0
    private(set) var scheduled: [(delay: TimeInterval, work: () -> Void)] = []
    var now = Date(timeIntervalSince1970: 1_000_000)

    var calls: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return _calls
    }

    func calls(to route: FlagRoute) -> [Call] { calls.filter { $0.route == route } }

    func reply(_ route: FlagRoute, _ replies: FlagReply...) {
        self.replies[route, default: []].append(contentsOf: replies)
    }

    static func ok(_ json: String) -> FlagReply { .answered(Data(json.utf8)) }

    func post(_ route: FlagRoute, _ body: [String: Any], _ done: @escaping (FlagReply) -> Void) {
        lock.lock()
        _calls.append(Call(route: route, body: body))
        let reply = (replies[route]?.isEmpty == false) ? replies[route]!.removeFirst() : fallback
        let fire = { done(reply) }
        if hold { held.append(fire) }
        lock.unlock()
        if !hold { fire() }
    }

    func release() {
        lock.lock()
        let pending = held
        held = []
        hold = false
        lock.unlock()
        pending.forEach { $0() }
    }

    func deps(sourceId: String = "s", cacheMax: Int = Flags.cacheMax) -> Flags.Deps {
        Flags.Deps(
            sourceId: sourceId,
            device: "mobile",
            keyPrefix: "examplePrefix123",
            post: { [unowned self] route, body, done in self.post(route, body, done) },
            openStream: { [unowned self] handlers in
                self.streams.append(handlers)
                return StreamHandle { [unowned self] in self.streamCloses += 1 }
            },
            schedule: { [unowned self] delay, work in self.scheduled.append((delay, work)) },
            now: { [unowned self] in self.now },
            cacheMax: cacheMax)
    }

    /// Opens the most recent stream connection.
    func connect() { streams.last?.onOpen() }
    func dropStream() { streams.last?.onClose() }
    func changed(_ keys: [String]) {
        let json = String(
            decoding: try! JSONSerialization.data(withJSONObject: ["reason": "change", "keys": keys]),
            as: UTF8.self)
        streams.last?.onMessage("flags_changed", json)
    }
}

/// Written from the network callback's thread, read from the test thread.
final class HookCalls {
    private let lock = NSLock()
    private var _errors: [FlagError] = []

    var errors: [FlagError] {
        lock.lock()
        defer { lock.unlock() }
        return _errors
    }

    func append(_ error: FlagError) {
        lock.lock()
        _errors.append(error)
        lock.unlock()
    }
}

final class FlagLogSink: IntemptLogging {
    private let lock = NSLock()
    private var _lines: [(IntemptLogLevel, String)] = []
    var lines: [(IntemptLogLevel, String)] {
        lock.lock()
        defer { lock.unlock() }
        return _lines
    }
    func log(level: IntemptLogLevel, message: String) {
        lock.lock()
        _lines.append((level, message))
        lock.unlock()
    }
}

class FlagEvaluatorTestCase: XCTestCase {

    var remote: FakeFlagRemote!
    var hooks: HookCalls!
    var sink: FlagLogSink!

    override func setUp() {
        super.setUp()
        remote = FakeFlagRemote()
        hooks = HookCalls()
        sink = FlagLogSink()
        IntemptLogger.shared.addLogging(sink)
        IntemptLogger.shared.enable(.debug)
        IntemptLogger.shared.enable(.warning)
        IntemptLogger.shared.enable(.error)
    }

    override func tearDown() {
        IntemptLogger.shared.removeAllLogging()
        IntemptLogger.shared.disableAllLevels()
        super.tearDown()
    }

    func makeFlags(sourceId: String = "s", cacheMax: Int = Flags.cacheMax) -> Flags {
        let flags = Flags(deps: remote.deps(sourceId: sourceId, cacheMax: cacheMax))
        let hooks = self.hooks!
        flags.onFlagError = { hooks.append($0) }
        return flags
    }

    func detail(
        _ flags: Flags,
        _ key: String = "k",
        context: FlagContext = FlagContext(userId: "u-1"),
        sessionId: String? = "se-1",
        default defaultValue: JSONValue = .string("fallback"),
        disableExposure: Bool = false
    ) -> FlagDetail? {
        var out: FlagDetail?
        flags.detail(
            key: key, context: context, sessionId: sessionId, defaultValue: defaultValue,
            disableExposure: disableExposure
        ) { out = $0 }
        return out
    }

    func all(
        _ flags: Flags, context: FlagContext = FlagContext(userId: "u-1"), sessionId: String? = "se-1"
    ) -> FlagValues? {
        var out: FlagValues?
        flags.all(context: context, sessionId: sessionId) { out = $0 }
        return out
    }

    func warnings(containing text: String) -> Int {
        sink.lines.filter { $0.0 == .warning && $0.1.contains(text) }.count
    }
}

// MARK: - Single read (/flags/evaluate)

final class FlagEvaluateTests: FlagEvaluatorTestCase {

    func testAReadIsOneEvaluateCallForThatKey() {
        let flags = makeFlags()
        remote.reply(.evaluate, FakeFlagRemote.ok(#"{"key":"k","value":true}"#))
        _ = detail(flags, context: FlagContext(userId: "u-1", profileId: "p-1"))

        XCTAssertEqual(remote.calls.map(\.route), [.evaluate])
        let body = remote.calls[0].body
        XCTAssertEqual(body["key"] as? String, "k")
        XCTAssertEqual(body["sessionId"] as? String, "se-1")
        XCTAssertEqual(body["device"] as? String, "mobile")
        let identification = body["identification"] as? [String: Any]
        XCTAssertEqual(identification?["userId"] as? String, "u-1")
        XCTAssertEqual(identification?["profileId"] as? String, "p-1")
        XCTAssertEqual(identification?["sourceId"] as? String, "s")
        XCTAssertNil(body["names"], "choose-api's field: the flag route takes one key")
        XCTAssertNil(body["exposure"], "/flags/evaluate always records; it has no exposure field")
    }

    func testABlankSessionIdIsOmittedRatherThanSentEmpty() {
        let flags = makeFlags()
        _ = detail(flags, sessionId: "")
        XCTAssertNil(remote.calls.first?.body["sessionId"])
    }

    func testTheDefaultContextDerivesOnProfileIdNotUserId() {
        // EXP-ASSIGN-005: a context carrying only profileId must not smuggle a userId onto the
        // wire; the server buckets on USER when userId is present, so the person would re-bucket.
        let flags = makeFlags()
        _ = detail(flags, context: FlagContext(profileId: "p-1"))
        let identification = remote.calls.first?.body["identification"] as? [String: Any]
        XCTAssertEqual(identification?["profileId"] as? String, "p-1")
        XCTAssertNil(identification?["userId"])
    }

    func testAServedValueCarriesTheAnswerFields() {
        let flags = makeFlags()
        remote.reply(
            .evaluate,
            FakeFlagRemote.ok(
                #"{"key":"k","value":"B","variationId":42,"valueType":"string","reason":"targeted","rule":2,"variant":"blue"}"#
            ))
        let result = detail(flags)
        XCTAssertEqual(
            result,
            FlagDetail(
                value: .string("B"), reason: .targeted, variationId: 42, valueType: "string",
                rule: 2, variant: "blue"))
        XCTAssertTrue(hooks.errors.isEmpty)
    }

    func testAKilledFlagReturnsTheDefaultWithTheServersReason() {
        let flags = makeFlags()
        remote.reply(
            .evaluate,
            FakeFlagRemote.ok(#"{"key":"k","value":null,"valueType":"string","reason":"killed"}"#))
        let result = detail(flags)
        XCTAssertEqual(result?.value, .string("fallback"))
        XCTAssertEqual(result?.reason, .killed)
        XCTAssertNil(result?.errorCode, "an answered off state is not an error")
    }

    func testEveryServerReasonPassesThrough() {
        for reason in ["targeted", "not_targeted", "not_in_rollout", "off", "killed", "not_client_side"] {
            let flags = makeFlags()
            remote.reply(.evaluate, FakeFlagRemote.ok(#"{"key":"k","reason":"\#(reason)"}"#))
            XCTAssertEqual(detail(flags)?.reason.rawValue, reason)
        }
    }

    func testAMissingOrUnknownReasonReadsUnansweredNeverOff() {
        // F6 #4: an older server sends no reason and the SDK behaves as it did. SDK-local reasons
        // arriving on the wire are not trusted either.
        for body in [
            #"{"key":"k","value":true}"#, #"{"key":"k","value":true,"reason":"invented_later"}"#,
            #"{"key":"k","value":true,"reason":"cached"}"#, #"{"key":"k","value":true,"reason":"error"}"#,
            #"{"key":"k","value":true,"reason":7}"#,
        ] {
            let flags = makeFlags()
            remote.reply(.evaluate, FakeFlagRemote.ok(body))
            XCTAssertEqual(detail(flags, default: .bool(false))?.reason, .unanswered, body)
        }
    }

    func testAFieldOfTheWrongTypeIsDroppedNotTrusted() {
        let flags = makeFlags()
        remote.reply(
            .evaluate,
            FakeFlagRemote.ok(#"{"key":"k","value":1,"variationId":"42","rule":1.5,"variant":3}"#))
        let result = detail(flags, default: .number(0))
        XCTAssertEqual(result?.value, .number(1))
        XCTAssertNil(result?.variationId)
        XCTAssertNil(result?.rule)
        XCTAssertNil(result?.variant)
    }

    func testA404IsFlagNotFoundWithTheDefault() {
        let flags = makeFlags()
        remote.reply(.evaluate, .failed(.badRequest, status: 404))
        let result = detail(flags)
        XCTAssertEqual(result?.value, .string("fallback"))
        XCTAssertEqual(result?.reason, .error)
        XCTAssertEqual(result?.errorCode, .flagNotFound)
        XCTAssertEqual(result?.error, FlagError(key: "k", kind: .badRequest, status: 404))
        XCTAssertEqual(hooks.errors, [FlagError(key: "k", kind: .badRequest, status: 404)])
    }

    func testA500IsGeneralWithTheDefault() {
        let flags = makeFlags()
        remote.reply(.evaluate, .failed(.server, status: 500))
        let result = detail(flags)
        XCTAssertEqual(result?.value, .string("fallback"))
        XCTAssertEqual(result?.errorCode, .general)
        XCTAssertEqual(result?.error, FlagError(key: "k", kind: .server, status: 500))
    }

    func testAnUnreachableServiceIsANetworkError() {
        let flags = makeFlags()
        remote.reply(.evaluate, .failed(.network, status: nil))
        XCTAssertEqual(detail(flags)?.error, FlagError(key: "k", kind: .network, status: nil))
    }

    func testABodyThatIsNotAFlagValueIsAParseError() {
        for body in ["not json at all", "[1,2]", "\"k\"", ""] {
            let flags = makeFlags()
            remote.reply(.evaluate, FakeFlagRemote.ok(body))
            let result = detail(flags)
            XCTAssertEqual(result?.value, .string("fallback"), body)
            XCTAssertEqual(result?.error, FlagError(key: "k", kind: .parse, status: nil), body)
        }
    }

    /// S11: a key the platform's pattern refuses returns the default, never traps, never reaches
    /// the server, and warns once per key however often it is read.
    func testAnInvalidKeyIsFlagNotFoundWithoutARequestAndWarnsOnce() {
        let flags = makeFlags()
        for key in ["checkout.new", "checkout.new", "", "  "] {
            let result = detail(flags, key)
            XCTAssertEqual(result?.value, .string("fallback"))
            XCTAssertEqual(result?.reason, .error)
            XCTAssertEqual(result?.errorCode, .flagNotFound)
        }
        XCTAssertTrue(remote.calls.isEmpty)
        XCTAssertEqual(warnings(containing: "checkout.new"), 1)
        XCTAssertTrue(hooks.errors.isEmpty, "a caller mistake is not a failed request")
    }

    func testAContextNamingNoVisitorIsTargetingKeyMissing() {
        let cases: [(FlagContext, String)] = [
            (FlagContext(), "s"),
            (FlagContext(userId: " "), "s"),
            (FlagContext(profileId: "p-1"), ""),
        ]
        for (context, sourceId) in cases {
            let flags = makeFlags(sourceId: sourceId)
            let result = detail(flags, context: context)
            XCTAssertEqual(result?.errorCode, .targetingKeyMissing, "\(context) / \(sourceId)")
            XCTAssertEqual(result?.value, .string("fallback"))
        }
        XCTAssertTrue(remote.calls.isEmpty)
    }

    func testARejectedKeyLogsAnErrorOnceNamingThePrefixNeverTheSecret() {
        let flags = makeFlags()
        remote.reply(.evaluate, .failed(.auth, status: 401), .failed(.auth, status: 403))
        XCTAssertEqual(detail(flags)?.error, FlagError(key: "k", kind: .auth, status: 401))
        XCTAssertEqual(detail(flags)?.error, FlagError(key: "k", kind: .auth, status: 403))
        XCTAssertEqual(hooks.errors.map(\.kind), [.auth, .auth])
        let errors = sink.lines.filter { $0.0 == .error && $0.1.contains("examplePrefix123") }
        XCTAssertEqual(errors.count, 1, "\(sink.lines)")
    }
}

// MARK: - Typed reads (F30)

final class FlagTypeTests: FlagEvaluatorTestCase {

    private func read(_ body: String, default defaultValue: JSONValue) -> FlagDetail? {
        let flags = makeFlags()
        remote.reply(.evaluate, FakeFlagRemote.ok(body))
        return detail(flags, default: defaultValue)
    }

    func testAValueOfAnotherTypeIsTheDefaultWithTypeMismatch() {
        let result = read(#"{"key":"k","value":"true","variationId":1}"#, default: .bool(false))
        XCTAssertEqual(result?.value, .bool(false), "never coerced: \"true\" is not true")
        XCTAssertEqual(result?.reason, .error)
        XCTAssertEqual(result?.errorCode, .typeMismatch)
        XCTAssertEqual(result?.variationId, 1)
    }

    func testTheDeclaredValueTypeDecidesWhenSent() {
        let result = read(#"{"key":"k","value":true,"valueType":"string"}"#, default: .bool(false))
        XCTAssertEqual(result?.errorCode, .typeMismatch)
        XCTAssertEqual(
            read(#"{"key":"k","value":true,"valueType":"boolean"}"#, default: .bool(false))?.value,
            .bool(true))
    }

    func testEachTypeAcceptsItsOwnValue() {
        XCTAssertEqual(read(#"{"key":"k","value":"x"}"#, default: .string(""))?.value, .string("x"))
        XCTAssertEqual(read(#"{"key":"k","value":2.5}"#, default: .number(0))?.value, .number(2.5))
        XCTAssertEqual(read(#"{"key":"k","value":true}"#, default: .bool(false))?.value, .bool(true))
        XCTAssertEqual(read(#"{"key":"k","value":1}"#, default: .bool(false))?.errorCode, .typeMismatch)
        XCTAssertEqual(read(#"{"key":"k","value":"1"}"#, default: .number(0))?.errorCode, .typeMismatch)
    }

    func testAnyJSONValueIsAJsonValueArraysIncluded() {
        XCTAssertEqual(
            read(#"{"key":"k","value":[1,2],"valueType":"json"}"#, default: .object([:]))?.value,
            .array([.number(1), .number(2)]))
        XCTAssertEqual(
            read(#"{"key":"k","value":"s"}"#, default: .array([]))?.value, .string("s"))
    }

    func testANullDefaultAcceptsAnyServedValue() {
        XCTAssertEqual(
            read(#"{"key":"k","value":"x","valueType":"string"}"#, default: .null)?.value, .string("x"))
    }
}

// MARK: - disableExposure (/flags/all with one key)

final class FlagUnexposedReadTests: FlagEvaluatorTestCase {

    func testDisableExposureReadsThroughAllWithThatOneKey() {
        let flags = makeFlags()
        remote.reply(.all, FakeFlagRemote.ok(#"{"flags":[{"key":"k","value":"B","variationId":3}]}"#))
        let result = detail(flags, disableExposure: true)

        XCTAssertEqual(remote.calls.map(\.route), [.all], "/flags/evaluate would record the exposure")
        XCTAssertEqual(remote.calls[0].body["keys"] as? [String], ["k"])
        XCTAssertNil(remote.calls[0].body["sessionId"], "/flags/all records nothing")
        XCTAssertEqual(result?.value, .string("B"))
        XCTAssertEqual(result?.variationId, 3)
    }

    func testAKeyAllLeavesOutIsFlagNotFound() {
        let flags = makeFlags()
        remote.reply(.all, FakeFlagRemote.ok(#"{"flags":[{"key":"other","value":true}]}"#))
        let result = detail(flags, disableExposure: true)
        XCTAssertEqual(result?.errorCode, .flagNotFound)
        XCTAssertEqual(result?.value, .string("fallback"))
        XCTAssertNil(result?.error)
    }

    func testAFailedUnexposedReadNamesItsKey() {
        let flags = makeFlags()
        remote.reply(.all, .failed(.server, status: 503))
        XCTAssertEqual(
            detail(flags, disableExposure: true)?.error, FlagError(key: "k", kind: .server, status: 503))
    }
}

// MARK: - Cache and stream (F15)

final class FlagCacheTests: FlagEvaluatorTestCase {

    private let served = FakeFlagRemote.ok(#"{"key":"k","value":"B","variationId":1,"reason":"targeted"}"#)

    func testTheFirstReadOpensOneStream() {
        let flags = makeFlags()
        _ = detail(flags)
        _ = detail(flags)
        XCTAssertEqual(remote.streams.count, 1)
    }

    func testWithoutAConnectedStreamEveryReadAsksTheServer() {
        let flags = makeFlags()
        remote.reply(.evaluate, served, served)
        _ = detail(flags)
        _ = detail(flags)
        XCTAssertEqual(remote.calls(to: .evaluate).count, 2)
    }

    func testWhileConnectedAFreshAnswerIsServedFromMemoryFor60s() {
        let flags = makeFlags()
        _ = detail(flags, "warmup")
        remote.connect()
        remote.reply(.evaluate, served, served)

        XCTAssertEqual(detail(flags)?.value, .string("B"))
        remote.now += 60
        XCTAssertEqual(detail(flags)?.value, .string("B"))
        XCTAssertEqual(remote.calls(to: .evaluate).count, 2, "warmup + the first read only")

        remote.now += 1
        _ = detail(flags)
        XCTAssertEqual(remote.calls(to: .evaluate).count, 3, "older than 60 s asks again")
    }

    func testTheCacheIsPerPerson() {
        let flags = makeFlags()
        _ = detail(flags, "warmup")
        remote.connect()
        remote.reply(.evaluate, served, served)
        _ = detail(flags, context: FlagContext(profileId: "p-1"))
        _ = detail(flags, context: FlagContext(profileId: "p-2"))
        XCTAssertEqual(remote.calls(to: .evaluate).count, 3)
    }

    func testAChangedKeyIsDroppedAtOnce() {
        let flags = makeFlags()
        _ = detail(flags, "warmup")
        remote.connect()
        remote.reply(.evaluate, served)
        _ = detail(flags)

        remote.changed(["other"])
        _ = detail(flags)
        XCTAssertEqual(remote.calls(to: .evaluate).count, 2, "another key's change keeps this entry")

        remote.changed(["k"])
        remote.reply(.evaluate, FakeFlagRemote.ok(#"{"key":"k","value":null,"reason":"killed"}"#))
        XCTAssertEqual(detail(flags)?.reason, .killed)
        XCTAssertEqual(remote.calls(to: .evaluate).count, 3)
    }

    func testAnUnreadableChangeEventDropsEverything() {
        let flags = makeFlags()
        _ = detail(flags, "warmup")
        remote.connect()
        remote.reply(.evaluate, served)
        _ = detail(flags)
        remote.streams.last?.onMessage("flags_changed", "{not json")
        _ = detail(flags)
        XCTAssertEqual(remote.calls(to: .evaluate).count, 3)
    }

    func testAnAnswerFromBeforeTheCurrentConnectionIsNotFresh() {
        let flags = makeFlags()
        _ = detail(flags, "warmup")
        remote.connect()
        remote.reply(.evaluate, served)
        _ = detail(flags)

        remote.dropStream()
        remote.scheduled.last?.work()
        remote.now += 1
        remote.connect()
        _ = detail(flags)
        XCTAssertEqual(remote.calls(to: .evaluate).count, 3, "a change may have been missed while down")
    }

    func testOnceTheStreamDropsEveryReadAsksAgain() {
        let flags = makeFlags()
        _ = detail(flags, "warmup")
        remote.connect()
        remote.reply(.evaluate, served)
        _ = detail(flags)
        remote.dropStream()
        _ = detail(flags)
        XCTAssertEqual(remote.calls(to: .evaluate).count, 3, "nothing would tell it of a change")
    }

    func testAReadStartedWhileDisconnectedIsNeverFresh() {
        let flags = makeFlags()
        remote.reply(.evaluate, served)
        _ = detail(flags)
        remote.connect()
        _ = detail(flags)
        XCTAssertEqual(remote.calls(to: .evaluate).count, 2)
    }

    func testAChangeLandingMidRequestKeepsThatAnswerFromBeingTrusted() {
        let flags = makeFlags()
        _ = detail(flags, "warmup")
        remote.connect()
        remote.hold = true
        remote.reply(.evaluate, served)
        var first: FlagDetail?
        flags.detail(key: "k", context: FlagContext(userId: "u-1"), sessionId: nil, defaultValue: .null) {
            first = $0
        }
        remote.changed(["k"])
        remote.release()
        XCTAssertEqual(first?.value, .string("B"), "the answer itself is still returned")

        _ = detail(flags)
        XCTAssertEqual(remote.calls(to: .evaluate).count, 3)
    }

    func testARecoverableFailureServesTheLastKnownValueAsCached() {
        for failure: FlagReply in [
            .failed(.server, status: 500), .failed(.timeout, status: nil), .failed(.network, status: nil),
            FakeFlagRemote.ok("garbage"),
        ] {
            let flags = makeFlags()
            remote.reply(.evaluate, served, failure)
            _ = detail(flags)
            let result = detail(flags)
            XCTAssertEqual(result?.value, .string("B"), "\(failure)")
            XCTAssertEqual(result?.reason, .cached, "\(failure)")
            XCTAssertEqual(result?.variationId, 1)
        }
    }

    func testAnAuthFailureIsNotServedFromTheCache() {
        let flags = makeFlags()
        remote.reply(.evaluate, served, .failed(.auth, status: 401))
        _ = detail(flags)
        XCTAssertEqual(detail(flags)?.value, .string("fallback"))
    }

    func testADeletedFlagNeverComesBackFromTheCache() {
        let flags = makeFlags()
        remote.reply(.evaluate, served, .failed(.badRequest, status: 404), .failed(.server, status: 500))
        _ = detail(flags)
        XCTAssertEqual(detail(flags)?.errorCode, .flagNotFound)
        XCTAssertEqual(detail(flags)?.value, .string("fallback"), "the 404 forgot it")
    }

    func testAnOffAnswerIsForgotten() {
        let flags = makeFlags()
        remote.reply(
            .evaluate, served, FakeFlagRemote.ok(#"{"key":"k","value":null,"reason":"off"}"#),
            .failed(.server, status: 500))
        _ = detail(flags)
        _ = detail(flags)
        XCTAssertEqual(detail(flags)?.value, .string("fallback"))
    }

    func testTheLastKnownValueExpiresAfter24h() {
        let flags = makeFlags()
        remote.reply(.evaluate, served, .failed(.server, status: 500))
        _ = detail(flags)
        remote.now += Flags.cacheTTL + 1
        XCTAssertEqual(detail(flags)?.value, .string("fallback"))
    }

    func testTheCacheDropsItsOldestEntryWhenFull() {
        let flags = makeFlags(cacheMax: 2)
        for key in ["a", "b", "c"] {
            remote.reply(.evaluate, FakeFlagRemote.ok(#"{"key":"\#(key)","value":"\#(key)"}"#))
            _ = detail(flags, key)
            remote.now += 1
        }
        XCTAssertEqual(flags.cacheCount, 2)
        XCTAssertEqual(detail(flags, "a")?.value, .string("fallback"), "a was the oldest")
        XCTAssertEqual(detail(flags, "c")?.value, .string("c"))
    }

    func testCloseEndsTheStreamForGood() {
        let flags = makeFlags()
        _ = detail(flags)
        remote.connect()
        flags.close()
        XCTAssertEqual(remote.streamCloses, 1)
        _ = detail(flags)
        XCTAssertEqual(remote.streams.count, 1)
    }

    func testPausingTheStreamReconnectsOnTheNextRead() {
        let flags = makeFlags()
        _ = detail(flags)
        remote.connect()
        flags.pauseStream()
        XCTAssertEqual(remote.streamCloses, 1)
        _ = detail(flags)
        XCTAssertEqual(remote.streams.count, 2)
    }
}

// MARK: - Prefetch (/flags/all + /flags/expose)

final class FlagPrefetchTests: FlagEvaluatorTestCase {

    private let twoServed = FakeFlagRemote.ok(
        #"{"flags":[{"key":"a","value":true,"variationId":11},{"key":"b","value":"x","variationId":12},{"key":"off","value":null,"reason":"off"},{"key":"bare","value":1}]}"#
    )

    func testAllFlagsIsOneAllCallThatNamesNoKeyAndRecordsNothing() {
        let flags = makeFlags()
        remote.reply(.all, twoServed)
        let values = all(flags)

        XCTAssertEqual(remote.calls.map(\.route), [.all])
        let body = remote.calls[0].body
        XCTAssertNil(body["keys"], "absent returns every served flag; [] would filter to none")
        XCTAssertNil(body["sessionId"])
        XCTAssertEqual((body["identification"] as? [String: Any])?["userId"] as? String, "u-1")
        XCTAssertEqual(Set(values?.keys ?? []), ["a", "b", "bare"], "nothing served is not a value")
        XCTAssertEqual(values?.count, 3)
        XCTAssertTrue(remote.calls(to: .expose).isEmpty, "listing keys reads no value")
    }

    func testTheFirstReadOfAServedKeyExposesItOnce() {
        let flags = makeFlags()
        remote.reply(.all, twoServed)
        let values = all(flags)

        XCTAssertEqual(values?["a"], .bool(true))
        XCTAssertEqual(values?["a"], .bool(true))
        let exposes = remote.calls(to: .expose)
        XCTAssertEqual(exposes.count, 1)
        let body = exposes[0].body
        XCTAssertEqual(body["key"] as? String, "a")
        XCTAssertEqual(body["variationId"] as? Int, 11)
        XCTAssertEqual(body["sessionId"] as? String, "se-1")
        XCTAssertEqual(body["device"] as? String, "mobile", "expose re-runs assignment with it")
        XCTAssertEqual((body["identification"] as? [String: Any])?["userId"] as? String, "u-1")
    }

    func testAKeyWithoutAVariationOrValueIsNeverExposed() {
        let flags = makeFlags()
        remote.reply(.all, twoServed)
        let values = all(flags)
        XCTAssertEqual(values?["bare"], .number(1))
        XCTAssertNil(values?["off"])
        XCTAssertNil(values?["missing"])
        XCTAssertTrue(remote.calls(to: .expose).isEmpty)
    }

    func testEachMapExposesItsOwnFirstRead() {
        let flags = makeFlags()
        remote.reply(.all, twoServed, twoServed)
        _ = all(flags)?["a"]
        _ = all(flags)?["a"]
        XCTAssertEqual(remote.calls(to: .expose).count, 2)
    }

    func testDictionaryExposesEveryServedKey() {
        let flags = makeFlags()
        remote.reply(.all, twoServed)
        let values = all(flags)
        XCTAssertEqual(values?.dictionary.count, 3)
        XCTAssertEqual(
            Set(remote.calls(to: .expose).compactMap { $0.body["key"] as? String }), ["a", "b"])
        _ = values?["b"]
        XCTAssertEqual(remote.calls(to: .expose).count, 2)
    }

    // A bridge (React Native) cannot hand JS a map that notices being read, so it copies the
    // values without exposing and calls expose(_:) for each key JS actually reads (PLAN §7 item 5).

    func testPeekAndSnapshotReadValuesWithoutExposing() {
        let flags = makeFlags()
        remote.reply(.all, twoServed)
        let values = all(flags)

        XCTAssertEqual(values?.peek("a"), .bool(true))
        XCTAssertEqual(values?.peek("bare"), .number(1))
        XCTAssertNil(values?.peek("off"))
        XCTAssertNil(values?.peek("missing"))
        XCTAssertEqual(values?.snapshot(), ["a": .bool(true), "b": .string("x"), "bare": .number(1)])
        XCTAssertTrue(remote.calls(to: .expose).isEmpty)
    }

    func testAPeekLeavesTheFirstReadToExpose() {
        let flags = makeFlags()
        remote.reply(.all, twoServed)
        let values = all(flags)
        _ = values?.peek("a")
        _ = values?.snapshot()
        _ = values?["a"]
        XCTAssertEqual(remote.calls(to: .expose).map { $0.body["key"] as? String }, ["a"])
    }

    func testExposeSendsTheServedVariationOnceAndSharesTheReadsDedup() {
        let flags = makeFlags()
        remote.reply(.all, twoServed)
        let values = all(flags)

        values?.expose("b")
        values?.expose("b")
        XCTAssertEqual(remote.calls(to: .expose).count, 1, "expose alone records, with no read")
        _ = values?["b"]
        _ = values?.dictionary
        let exposes = remote.calls(to: .expose)
        XCTAssertEqual(exposes.map { $0.body["key"] as? String }, ["b", "a"])
        XCTAssertEqual(exposes.first?.body["variationId"] as? Int, 12)
        XCTAssertEqual(exposes.first?.body["sessionId"] as? String, "se-1")
    }

    func testExposeAfterAReadSendsNothingMore() {
        let flags = makeFlags()
        remote.reply(.all, twoServed)
        let values = all(flags)
        _ = values?["a"]
        values?.expose("a")
        XCTAssertEqual(remote.calls(to: .expose).count, 1)
    }

    func testExposeOfAKeyNotServedWithAVariationSendsNothing() {
        let flags = makeFlags()
        remote.reply(.all, twoServed)
        let values = all(flags)
        values?.expose("missing")
        values?.expose("off")
        values?.expose("bare")
        values?.expose("")
        XCTAssertTrue(remote.calls(to: .expose).isEmpty)
    }

    func testAFailedExposeWarnsOncePerKindAndNeverReachesTheHook() {
        let flags = makeFlags()
        remote.reply(.all, twoServed)
        remote.reply(.expose, .failed(.server, status: 500), .failed(.server, status: 500))
        let values = all(flags)
        _ = values?["a"]
        _ = values?["b"]
        XCTAssertEqual(warnings(containing: "exposure"), 1)
        XCTAssertTrue(hooks.errors.isEmpty)
    }

    func testAfterCloseNoExposureIsSent() {
        let flags = makeFlags()
        remote.reply(.all, twoServed)
        let values = all(flags)
        flags.close()
        _ = values?["a"]
        XCTAssertTrue(remote.calls(to: .expose).isEmpty)
    }

    func testAFailureIsAnEmptyMapReportedWithNoKey() {
        let flags = makeFlags()
        remote.reply(.all, .failed(.server, status: 500))
        XCTAssertEqual(all(flags)?.isEmpty, true)
        XCTAssertEqual(hooks.errors, [FlagError(key: nil, kind: .server, status: 500)])
    }

    func testAReplyWithoutAFlagsArrayIsAParseError() {
        let flags = makeFlags()
        remote.reply(.all, FakeFlagRemote.ok(#"{"choices":[]}"#))
        XCTAssertEqual(all(flags)?.isEmpty, true)
        XCTAssertEqual(hooks.errors, [FlagError(key: nil, kind: .parse, status: nil)])
    }

    func testAContextNamingNoVisitorAsksNothing() {
        let flags = makeFlags()
        XCTAssertEqual(all(flags, context: FlagContext())?.isEmpty, true)
        XCTAssertTrue(remote.calls.isEmpty)
    }
}
