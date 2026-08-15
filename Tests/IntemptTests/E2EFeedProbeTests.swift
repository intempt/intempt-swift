import XCTest
@testable import Intempt

/// End-to-end against the live project, through the SDK's own code path.
final class E2EFeedProbeTests: XCTestCase {

    private func env(_ k: String) -> String { ProcessInfo.processInfo.environment[k] ?? "" }

    func testBothDemoAppFeedsReturnProductsThroughTheSDK() throws {
        let key = env("INTEMPT_API_KEY")
        try XCTSkipIf(key.isEmpty, "live credentials not present")

        let instance = try IntemptInstance.initialize(
            apiKey: key, orgId: env("INTEMPT_ORG_ID"),
            projectId: env("INTEMPT_PROJECT_ID"), sourceId: env("INTEMPT_SOURCE_ID"),
            instanceName: "e2e-feed-probe")

        // Music.ly: profile-input feed, no productId — the home screen case.
        let musicly = expectation(description: "musicly feed 4877")
        var musiclyCount = -1
        instance.products(feedId: "4877", count: 10) { result in
            if case .success(let p) = result { musiclyCount = p.count }
            musicly.fulfill()
        }

        // Thread.ly: product-input feed, with the product being viewed.
        let threadly = expectation(description: "threadly feed 4876")
        var threadlyCount = -1
        var firstTitle: String?
        instance.products(feedId: "4876", count: 10, productId: "246") { result in
            if case .success(let p) = result { threadlyCount = p.count; firstTitle = p.first?.title }
            threadly.fulfill()
        }

        wait(for: [musicly, threadly], timeout: 60)

        print("E2E musicly(4877) products = \(musiclyCount)")
        print("E2E threadly(4876) products = \(threadlyCount) first=\(firstTitle ?? "nil")")
        XCTAssertGreaterThan(musiclyCount, 0, "Music.ly home feed returned nothing")
        XCTAssertGreaterThan(threadlyCount, 0, "Thread.ly product feed returned nothing")
        XCTAssertNotNil(firstTitle, "a recommendation must carry a title to render")
    }
}
