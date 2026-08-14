import Foundation
import XCTest

@testable import Intempt

// MARK: - Network double

/// Records every request and replies with a scripted sequence of outcomes.
/// Thread-safe: `Flush` calls it from its own serial queue and the reply may
/// be delivered from anywhere, so both sides of the mock lock.
final class MockSession: URLSessionProtocol {

    struct Reply {
        var status: Int
        var body: Data?
        var headers: [String: String]
        var error: Error?

        static func ok(_ body: String = "{}") -> Reply {
            Reply(status: 200, body: Data(body.utf8), headers: [:], error: nil)
        }
        static func status(_ code: Int, headers: [String: String] = [:]) -> Reply {
            Reply(status: code, body: nil, headers: headers, error: nil)
        }
        static func offline() -> Reply {
            Reply(
                status: 0, body: nil, headers: [:],
                error: NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet))
        }
    }

    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    private var _replies: [Reply]
    /// Used when the script runs out, so a test needn't script every attempt.
    private let fallback: Reply
    /// When set, the mock holds the completion instead of calling it, so a test
    /// can assert on state while a request is genuinely in flight.
    var deferCompletions = false
    private var pending: [() -> Void] = []

    init(replies: [Reply] = [], fallback: Reply = .ok()) {
        self._replies = replies
        self.fallback = fallback
    }

    var requests: [URLRequest] { lock.withLock { _requests } }
    var requestCount: Int { lock.withLock { _requests.count } }

    /// Decoded JSON bodies of every request, in order.
    var bodies: [[String: Any]] {
        requests.compactMap {
            guard let d = $0.httpBody else { return nil }
            return JSONHandler.deserializeData(d) as? [String: Any]
        }
    }

    func perform(
        _ request: URLRequest,
        completion: @escaping (Data?, URLResponse?, Error?) -> Void
    ) {
        let reply: Reply = lock.withLock {
            _requests.append(request)
            return _replies.isEmpty ? fallback : _replies.removeFirst()
        }

        let fire = {
            if let error = reply.error {
                completion(nil, nil, error)
                return
            }
            let response = HTTPURLResponse(
                url: request.url!, statusCode: reply.status,
                httpVersion: "HTTP/1.1", headerFields: reply.headers)!
            completion(reply.body, response, nil)
        }

        if deferCompletions {
            lock.withLock { pending.append(fire) }
        } else {
            fire()
        }
    }

    /// Releases every held completion.
    func releaseDeferred() {
        let held: [() -> Void] = lock.withLock {
            let p = pending
            pending = []
            return p
        }
        held.forEach { $0() }
    }
}

// MARK: - Fixtures

/// Per-test scratch directory and UserDefaults, torn down in `tearDown`.
class IntemptTestCase: XCTestCase {

    private(set) var tempDir: URL!
    private(set) var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("intempt-tests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true)

        suiteName = "com.intempt.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: tempDir)
        IntemptInstance.removeAllInstances()
        super.tearDown()
    }

    func makeDB(namespace: String = "flushtest") -> IntemptDB {
        IntemptDB(namespace: namespace, directoryOverride: tempDir)
    }

    /// Inserts `count` well-formed track events directly into the store.
    @discardableResult
    func seedEvents(_ db: IntemptDB, count: Int, prefix: String = "e") -> [String] {
        var names: [String] = []
        for i in 0..<count {
            let name = "\(prefix)\(i)"
            let model = TrackModel(
                envelope: EventEnvelope(
                    eventId: "ev_\(name)", profileId: "pr_1",
                    sessionId: "se_1", pageId: "pa_1"),
                name: name, data: nil)
            let data = JSONHandler.encodeAPIData(model.toEnvelopeEntry())!
            XCTAssertTrue(db.insert(.events, data: data))
            names.append(name)
        }
        return names
    }

    /// Waits for a condition without blocking the main run loop's ability to
    /// service the timers under test.
    func waitUntil(
        _ description: String,
        timeout: TimeInterval = 3,
        _ condition: @escaping () -> Bool
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(condition(), "timed out waiting for: \(description)")
    }
}

extension NSLock {
    fileprivate func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}

/// Names of the events inside a `{"track":[…]}` request body, in order.
func trackedNames(in body: [String: Any]) -> [String] {
    guard let entries = body["track"] as? [[String: Any]] else { return [] }
    return entries.compactMap { $0["name"] as? String }
}
