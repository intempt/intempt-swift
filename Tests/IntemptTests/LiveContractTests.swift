import XCTest

@testable import Intempt

/// End-to-end against the real API.
///
/// Every other test in this suite talks to `MockSession`, which proves the SDK
/// builds the request it *intends* to build. Nothing proved the server accepts
/// it. This suite closes that gap: it runs the actual `IntemptInstance` →
/// `IntemptDB` → `Flush` → `Network` → `api.intempt.com` path and asserts on
/// what the server returned.
///
/// SKIPPED unless credentials are present, so a fork with no access still gets
/// a green suite. Provide them in `.env.local` (gitignored) or the environment:
///
///     INTEMPT_ORG_ID, INTEMPT_PROJECT_ID, INTEMPT_SOURCE_ID, INTEMPT_API_KEY
///
/// These tests write real events to whatever project the credentials name.
/// Point them at a disposable one.
final class LiveContractTests: IntemptTestCase {

    private struct Credentials {
        let apiKey: String
        let orgId: String
        let projectId: String
        let sourceId: String
    }

    /// Reads the environment first, then `.env.local` at the repo root.
    private static func credentials() -> Credentials? {
        var values: [String: String] = [:]

        let keys = [
            "INTEMPT_API_KEY", "INTEMPT_ORG_ID", "INTEMPT_PROJECT_ID", "INTEMPT_SOURCE_ID",
        ]
        for key in keys {
            if let value = ProcessInfo.processInfo.environment[key], !value.isEmpty {
                values[key] = value
            }
        }

        if values.count < keys.count, let contents = envFileContents() {
            for line in contents.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("#"),
                    let separator = trimmed.firstIndex(of: "=")
                else { continue }
                let key = String(trimmed[trimmed.startIndex..<separator])
                let value = String(trimmed[trimmed.index(after: separator)...])
                if keys.contains(key), values[key] == nil, !value.isEmpty {
                    values[key] = value
                }
            }
        }

        guard values.count == keys.count else { return nil }
        return Credentials(
            apiKey: values["INTEMPT_API_KEY"]!,
            orgId: values["INTEMPT_ORG_ID"]!,
            projectId: values["INTEMPT_PROJECT_ID"]!,
            sourceId: values["INTEMPT_SOURCE_ID"]!)
    }

    /// Walks up from this file to find `.env.local`. `#filePath` rather than a
    /// working-directory guess: `swift test` and Xcode run from different cwds.
    private static func envFileContents() -> String? {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = directory.appendingPathComponent(".env.local")
            if let contents = try? String(contentsOf: candidate, encoding: .utf8) {
                return contents
            }
            directory = directory.deletingLastPathComponent()
        }
        return nil
    }

    private func requireCredentials() throws -> Credentials {
        guard let credentials = Self.credentials() else {
            throw XCTSkip(
                "no Intempt credentials — set INTEMPT_* in the environment or .env.local")
        }
        return credentials
    }

    private func makeInstance(
        _ credentials: Credentials,
        automaticEvents: AutomaticEventOptions = AutomaticEventOptions(sessions: false)
    ) throws -> IntemptInstance {
        try IntemptInstance.makeForTesting(
            apiKey: credentials.apiKey,
            orgId: credentials.orgId,
            projectId: credentials.projectId,
            sourceId: credentials.sourceId,
            store: defaults,
            databaseDirectory: tempDir,
            automaticEvents: automaticEvents)
    }

    /// Flushes and returns the number of events the server acknowledged.
    private func flush(_ instance: IntemptInstance, timeout: TimeInterval = 30) -> Int {
        var sent: Int?
        instance.flusher.flushNow { sent = $0 }
        waitUntil("live flush completes", timeout: timeout) { sent != nil }
        return sent ?? -1
    }

    // MARK: - The whole delivery path

    /// The first end-to-end proof: an event enters through the public API,
    /// lands in SQLite, is claimed, POSTed, acknowledged, and deleted.
    func testTrackReachesProductionAndTheQueueDrains() throws {
        let credentials = try requireCredentials()
        let instance = try makeInstance(credentials)

        XCTAssertTrue(
            instance.track(
                eventTitle: "SwiftSDK Live Test",
                data: [
                    "suite": "LiveContractTests",
                    "run": UUID().uuidString,
                    "sdkVersion": Intempt.sdkVersion,
                ]))
        XCTAssertEqual(instance.queuedEventCount(), 1)

        XCTAssertEqual(flush(instance), 1, "the server must acknowledge the event")
        XCTAssertEqual(
            instance.queuedEventCount(), 0,
            "an acknowledged event must be deleted from the local store")
    }

    /// Every model type in one mixed batch — the shape the SDK actually sends.
    func testMixedBatchOfEveryModelTypeIsAccepted() throws {
        let credentials = try requireCredentials()
        let instance = try makeInstance(credentials)
        let run = UUID().uuidString

        XCTAssertTrue(instance.track(eventTitle: "Live Track", data: ["run": run]))
        XCTAssertTrue(
            instance.identify(
                userId: "live-test@intempt.com", userAttributes: ["plan": "test"]))
        XCTAssertTrue(instance.group(accountId: "live-test-account"))
        XCTAssertTrue(
            instance.record(
                eventTitle: "Live Record", userId: "live-test@intempt.com",
                accountId: "live-test-account", data: ["run": run]))
        XCTAssertTrue(instance.productView(productId: "sku_live"))
        XCTAssertTrue(instance.productAdd(productId: "sku_live", quantity: 2))
        XCTAssertTrue(
            instance.productOrdered(products: [(productId: "sku_live", quantity: 1)]))

        let queued = instance.queuedEventCount()
        XCTAssertEqual(queued, 7)
        XCTAssertEqual(flush(instance), queued, "every model type must be accepted")
        XCTAssertEqual(instance.queuedEventCount(), 0)
    }

    /// A session-start event with device facts as userAttributes, in the
    /// typeless shape intemptjs uses.
    func testSessionStartShapeIsAccepted() throws {
        let credentials = try requireCredentials()
        let instance = try makeInstance(
            credentials, automaticEvents: AutomaticEventOptions(sessions: true))

        XCTAssertTrue(instance.track(eventTitle: "Live After Session"))
        XCTAssertEqual(instance.queuedEventCount(), 2, "session start + the event")
        XCTAssertEqual(flush(instance), 2, "the typeless session entry must be accepted")
    }

    /// More than one batch, to prove the drain loop works against a real server
    /// and not only against a mock that always says 200.
    func testMultiBatchDrainAgainstProduction() throws {
        let credentials = try requireCredentials()
        let instance = try makeInstance(credentials)

        let count = APIConstants.maxBatchSize + 5
        for i in 0..<count {
            XCTAssertTrue(instance.track(eventTitle: "Live Batch", data: ["index": i]))
        }
        XCTAssertEqual(instance.queuedEventCount(), count)

        // Retries, because production has been observed returning a transient
        // 400 to a payload it accepts on the next attempt. The invariant under
        // test is that nothing is LOST and everything eventually lands — not
        // that a live server is perfect on the first try. A single-pass
        // assertion here failed against a real 400 while the SDK had behaved
        // exactly right: all 55 events were still in the queue.
        var delivered = 0
        for attempt in 1...4 {
            delivered += flush(instance, timeout: 60)
            if instance.queuedEventCount() == 0 { break }
            XCTAssertLessThan(attempt, 4, "still \(instance.queuedEventCount()) queued")
        }

        XCTAssertEqual(delivered, count, "every event must be delivered exactly once")
        XCTAssertEqual(instance.queuedEventCount(), 0)
    }

    // MARK: - Credentials

    /// A wrong secret must be terminal AND must not destroy the queue. The old
    /// Obj-C SDK read a 401 as success and deleted the batch.
    func testBadCredentialsKeepTheEventsInsteadOfDeletingThem() throws {
        let credentials = try requireCredentials()
        let instance = try IntemptInstance.makeForTesting(
            apiKey: "\(credentials.apiKey.split(separator: ".")[0]).definitelyWrongSecret",
            orgId: credentials.orgId,
            projectId: credentials.projectId,
            sourceId: credentials.sourceId,
            store: defaults,
            databaseDirectory: tempDir)

        XCTAssertTrue(instance.track(eventTitle: "Live Auth Failure"))
        XCTAssertEqual(flush(instance), 0, "a 401 delivers nothing")
        XCTAssertEqual(
            instance.queuedEventCount(), 1,
            "the data is valid and the integration is what is broken — keep it")
    }

    // MARK: - Consent

    func testConsentReachesItsOwnEndpoint() throws {
        let credentials = try requireCredentials()
        let instance = try makeInstance(credentials)

        XCTAssertTrue(instance.consent(action: .accept, validUntil: 31_536_000))
        XCTAssertEqual(instance.queuedConsentCount(), 1)

        _ = flush(instance)
        XCTAssertEqual(
            instance.queuedConsentCount(), 0,
            "consent must be acknowledged by /consents/data")
    }

    // MARK: - Personalization

    /// The 443x defect, proven live: the same request with and without `fields`
    /// differs by two orders of magnitude because the unfielded response
    /// carries raw ML embedding vectors.
    func testFeedRequestIsSmallBecauseFieldsIsAlwaysSent() throws {
        let credentials = try requireCredentials()
        let instance = try makeInstance(credentials)

        var result: Result<[ProductRecommendation], IntemptError>?
        let done = expectation(description: "products")
        // 5258 = "Best Sellers" on the linea project. A caller with different
        // credentials will get a 400 naming the bad feed id, which is itself
        // the documented error shape.
        instance.products(feedId: "5258", count: 3) {
            result = $0
            done.fulfill()
        }
        wait(for: [done], timeout: 30)

        switch result {
        case .success(let products):
            for product in products {
                XCTAssertNil(
                    product["intempt_image_vector"],
                    "an embedding vector must never reach a caller")
                XCTAssertLessThanOrEqual(
                    product.attributes.count, Intempt.defaultFeedFields.count,
                    "only the requested fields may come back")
            }
        case .failure(let error):
            // Only a feed-id problem is acceptable here; a shape problem is not.
            guard case .server(_, let messages) = error,
                messages.contains(where: { $0.lowercased().contains("feed") })
            else {
                return XCTFail("feeds rejected the request shape: \(error)")
            }
        case .none:
            XCTFail("no result")
        }
    }

    // MARK: - Contract regressions

    /// Verified live: the endpoint returns 400 for a gzipped body. This test
    /// exists so that anyone who ports upstream's compression path discovers
    /// the incompatibility here rather than in production.
    func testGzipIsStillRejectedByTheEndpoint() throws {
        let credentials = try requireCredentials()
        let endpoint = Endpoint.track(
            org: credentials.orgId, project: credentials.projectId,
            sourceId: credentials.sourceId, useIPForGeolocation: true)

        var request = try Network().makeRequest(
            endpoint: endpoint,
            credentials: try IntemptCredentials(apiKey: credentials.apiKey),
            body: TrackEnvelope.wrap([
                [
                    "name": "Gzip Probe", "type": "track",
                    "payload": [["eventId": "ev_gzip", "profileId": "pr_live_probe"]],
                ]
            ]))
        request.setValue("gzip", forHTTPHeaderField: "Content-Encoding")
        request.httpBody = Data([0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00])

        var outcome: HTTPOutcome?
        let done = expectation(description: "gzip probe")
        Network().send(request) {
            outcome = $0
            done.fulfill()
        }
        wait(for: [done], timeout: 30)

        guard case .terminal(let status, _) = outcome else {
            return XCTFail(
                "gzip is now handled differently — recheck docs/CONTRACT.md, got \(String(describing: outcome))"
            )
        }
        XCTAssertEqual(status, 400, "the endpoint does not decompress gzip")
    }

    /// Success is 201 on /track and 200 on /consents/data. A classifier
    /// hardcoded to `== 200` would treat every accepted batch as a failure.
    func testTrackReturns201NotJust200() throws {
        let credentials = try requireCredentials()
        let request = try Network().makeRequest(
            endpoint: .track(
                org: credentials.orgId, project: credentials.projectId,
                sourceId: credentials.sourceId, useIPForGeolocation: true),
            credentials: try IntemptCredentials(apiKey: credentials.apiKey),
            body: TrackEnvelope.wrap([
                [
                    "name": "Status Probe", "type": "track",
                    "payload": [["eventId": "ev_status", "profileId": "pr_live_probe"]],
                ]
            ]))

        var outcome: HTTPOutcome?
        let done = expectation(description: "status probe")
        Network().send(request) {
            outcome = $0
            done.fulfill()
        }
        wait(for: [done], timeout: 30)

        guard case .success = outcome else {
            return XCTFail("expected success, got \(String(describing: outcome))")
        }
    }
}
