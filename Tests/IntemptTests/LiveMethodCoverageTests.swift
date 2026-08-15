import XCTest

@testable import Intempt

/// Exercises EVERY public method against the real API and reports each one.
///
/// This exists because "the SDK is tested" and "the SDK works against your
/// project" are different claims. The unit suite proves the SDK builds the
/// request it means to; `LiveContractTests` proves the delivery path works.
/// Neither proves that every individual entry point is accepted by the
/// specific org, project and source an app is configured with — which is the
/// question that matters when pointing an app at new credentials.
///
/// Skipped without credentials. Reads the same `.env.local` the other live
/// tests use, so it runs against whatever the demo apps are pointed at.
final class LiveMethodCoverageTests: IntemptTestCase {

    /// One method's outcome, so a failure names the method rather than a line.
    private struct Outcome {
        let method: String
        let detail: String
        let ok: Bool
    }

    private var outcomes: [Outcome] = []

    private func check(_ method: String, _ detail: String = "", _ ok: Bool) {
        outcomes.append(Outcome(method: method, detail: detail, ok: ok))
    }

    private func report() {
        let width = outcomes.map(\.method.count).max() ?? 20
        print("\n  Live method coverage")
        print("  " + String(repeating: "-", count: width + 30))
        for o in outcomes {
            let pad = String(repeating: " ", count: width - o.method.count)
            print("  \(o.ok ? "PASS" : "FAIL")  \(o.method)\(pad)  \(o.detail)")
        }
        let failed = outcomes.filter { !$0.ok }
        print("  \(outcomes.count - failed.count)/\(outcomes.count) methods verified live\n")
        XCTAssertTrue(
            failed.isEmpty,
            "these methods failed against the live project: "
                + failed.map(\.method).joined(separator: ", "))
    }

    private func credentials() throws -> (
        apiKey: String, orgId: String, projectId: String, sourceId: String
    ) {
        let environment = ProcessInfo.processInfo.environment
        var values: [String: String] = [:]
        let keys = ["INTEMPT_API_KEY", "INTEMPT_ORG_ID", "INTEMPT_PROJECT_ID", "INTEMPT_SOURCE_ID"]
        for key in keys where !(environment[key] ?? "").isEmpty {
            values[key] = environment[key]
        }
        if values.count < keys.count {
            var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            for _ in 0..<6 {
                if let contents = try? String(
                    contentsOf: directory.appendingPathComponent(".env.local"), encoding: .utf8)
                {
                    for line in contents.split(separator: "\n") {
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        guard !trimmed.hasPrefix("#"), let eq = trimmed.firstIndex(of: "=") else {
                            continue
                        }
                        let key = String(trimmed[trimmed.startIndex..<eq])
                        let value = String(trimmed[trimmed.index(after: eq)...])
                        if keys.contains(key), values[key] == nil, !value.isEmpty {
                            values[key] = value
                        }
                    }
                    break
                }
                directory = directory.deletingLastPathComponent()
            }
        }
        guard values.count == keys.count else {
            throw XCTSkip("no Intempt credentials — set INTEMPT_* or provide .env.local")
        }
        return (
            values["INTEMPT_API_KEY"]!, values["INTEMPT_ORG_ID"]!,
            values["INTEMPT_PROJECT_ID"]!, values["INTEMPT_SOURCE_ID"]!
        )
    }

    /// Every public entry point, against the live project, in one pass.
    func testEveryPublicMethodAgainstTheLiveProject() throws {
        let c = try credentials()
        print("\n  org=\(c.orgId) project=\(c.projectId) source=\(c.sourceId)")

        let intempt = try IntemptInstance.makeForTesting(
            apiKey: c.apiKey, orgId: c.orgId, projectId: c.projectId, sourceId: c.sourceId,
            store: defaults, databaseDirectory: tempDir,
            automaticEvents: AutomaticEventOptions(sessions: false))

        // MARK: Identity — local, no network

        let profileId = intempt.getProfileId()
        check("getProfileId", profileId, profileId.hasPrefix("pr_"))
        let sessionId = intempt.getSessionId()
        check("getSessionId", sessionId, sessionId.hasPrefix("se_"))
        check("sdkVersion", intempt.sdkVersion, !intempt.sdkVersion.isEmpty)
        check("isOptedIn", "\(intempt.isOptedIn())", intempt.isOptedIn())
        check("hasOptedOut", "\(intempt.hasOptedOut())", !intempt.hasOptedOut())

        // MARK: Enqueue — every tracking method

        let run = UUID().uuidString.prefix(8)
        check("track", "", intempt.track(eventTitle: "Live track", data: ["run": String(run)]))
        check(
            "identify", "",
            intempt.identify(
                userId: "live-coverage@intempt.com", userAttributes: ["plan": "test"]))
        check(
            "group", "",
            intempt.group(accountId: "live-coverage-account", accountAttributes: ["tier": "t"]))
        check(
            "alias", "",
            intempt.alias(userId: "live-coverage@intempt.com", anotherUserId: "live-alias"))
        check(
            "record", "",
            intempt.record(
                eventTitle: "Live record", userId: "live-coverage@intempt.com",
                accountId: "live-coverage-account", data: ["run": String(run)]))
        check("productView", "", intempt.productView(productId: "sku_live"))
        check("productAdd", "", intempt.productAdd(productId: "sku_live", quantity: 2))
        check(
            "productOrdered", "",
            intempt.productOrdered(products: [
                (productId: "sku_live", quantity: 1), (productId: "sku_live_2", quantity: 3),
            ]))
        check("setPushToken", "", intempt.setPushToken(Data(repeating: 0xAB, count: 32)))
        check("trackPushOpen", "", intempt.trackPushOpen(["campaignId": "live_c1"]))
        check("trackPushReceived", "", intempt.trackPushReceived(["campaignId": "live_c1"]))
        check(
            "consent(.accept)", "",
            intempt.consent(action: .accept, validUntil: 31_536_000, category: "offers"))

        let queued = intempt.queuedEventCount()
        check("queued before flush", "\(queued) events", queued >= 11)

        // MARK: Delivery — the whole path to production

        var delivered = 0
        for _ in 0..<4 {
            var sent: Int?
            intempt.flusher.flushNow { sent = $0 }
            waitUntil("flush", timeout: 60) { sent != nil }
            delivered += sent ?? 0
            if intempt.queuedEventCount() == 0 { break }
        }
        check("flush", "\(delivered) delivered, \(intempt.queuedEventCount()) left", delivered == queued)
        check(
            "consent transmitted", "\(intempt.queuedConsentCount()) left",
            intempt.queuedConsentCount() == 0)

        // MARK: Personalization — real requests

        var productsOK = false
        var productsDetail = ""
        let e3 = expectation(description: "products")
        intempt.products(feedId: "5258", count: 3) { result in
            switch result {
            case .success(let products):
                productsOK = true
                productsDetail =
                    "\(products.count) product(s): "
                    + products.compactMap(\.title).joined(separator: ", ")
            case .failure(let error):
                // A feed-id problem is acceptable on a project without that feed;
                // a shape problem is not.
                if case .server(_, let messages) = error,
                    messages.contains(where: { $0.lowercased().contains("feed") })
                {
                    productsOK = true
                    productsDetail = "no such feed on this project (shape accepted)"
                } else {
                    productsDetail = "\(error)"
                }
            }
            e3.fulfill()
        }
        wait(for: [e3], timeout: 45)
        check("products", productsDetail, productsOK)

        // MARK: Privacy — local state transitions

        intempt.optOut()
        check("optOut", "gated=\(intempt.hasOptedOut())", intempt.hasOptedOut())
        check(
            "track refused while opted out", "",
            intempt.track(eventTitle: "must not be queued") == false)

        intempt.optIn()
        check("optIn", "gated=\(intempt.hasOptedOut())", !intempt.hasOptedOut())
        check("track resumes", "", intempt.track(eventTitle: "Live after opt-in"))

        let beforeLogOut = intempt.getProfileId()
        intempt.logOut()
        check("logOut", "rotated identity", intempt.getProfileId() != beforeLogOut)

        intempt.reset()
        check("reset", "queue=\(intempt.queuedEventCount())", intempt.queuedEventCount() == 0)

        // MARK: Configuration

        intempt.flushInterval = 30
        check("flushInterval", "\(intempt.flushInterval)s", intempt.flushInterval == 30)

        intempt.automaticEvents = AutomaticEventOptions(sessions: true, versionChanges: true)
        check(
            "automaticEvents", "sessions=\(intempt.automaticEvents.sessions)",
            intempt.automaticEvents.sessions && intempt.automaticEvents.versionChanges)

        check(
            "autocapture.configure", "",
            {
                intempt.autocapture.configure(.all)
                return intempt.autocapture.options == .all
            }())
        // start()/stop() are no-ops off iOS — the swizzles are UIKit-only — so
        // this asserts the state machine, not the hooks. The hooks are covered
        // by MethodSwizzlerTests and by the demo app's XCUITests.
        intempt.autocapture.start()
        check("autocapture.start", "running=\(intempt.autocapture.isRunning)", intempt.autocapture.isRunning)
        intempt.autocapture.stop()
        check("autocapture.stop", "running=\(intempt.autocapture.isRunning)", !intempt.autocapture.isRunning)

        report()
    }
}
