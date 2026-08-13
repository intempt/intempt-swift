import XCTest

@testable import Intempt

/// Phase 0 harness check: proves the package builds, the test target links,
/// and the bundled privacy manifest resource is present on every platform.
final class SmokeTests: XCTestCase {

    func testPackageBuildsAndLinks() {
        XCTAssertFalse(Intempt.sdkVersion.isEmpty)
    }

    func testPrivacyManifestIsBundled() {
        // The manifest is declared in Package.swift's `resources:`. If it is
        // missing the build fails outright, but this asserts it is actually
        // reachable at runtime rather than merely declared.
        let url = Bundle.module.url(forResource: "PrivacyInfo", withExtension: "xcprivacy")
        XCTAssertNotNil(url, "PrivacyInfo.xcprivacy must ship inside the SDK bundle")
    }
}
