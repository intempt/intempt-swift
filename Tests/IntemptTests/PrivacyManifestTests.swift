import XCTest
@testable import Intempt

/// The privacy manifest is a shipped artefact Apple reads, so its contents are pinned here.
///
/// Intempt derives country, region and city server-side from the address the request arrives on.
/// Apple's rule is that anything derived from data sent off device counts separately from the data
/// itself, and the derived location is stored -- so the app collects Coarse Location and the
/// manifest has to say so. The address itself is discarded at ingestion and is therefore not
/// collected, which is why no identifier entry is needed for it.
final class PrivacyManifestTests: XCTestCase {

    private func manifest() throws -> [String: Any] {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"),
            "the manifest must ship in the bundle, or Apple never sees it")
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try XCTUnwrap(plist as? [String: Any])
    }

    private func collectedTypes() throws -> [String] {
        let types = try manifest()["NSPrivacyCollectedDataTypes"] as? [[String: Any]] ?? []
        return types.compactMap { $0["NSPrivacyCollectedDataType"] as? String }
    }

    func testDeclaresCoarseLocation() throws {
        XCTAssertTrue(
            try collectedTypes().contains("NSPrivacyCollectedDataTypeCoarseLocation"),
            "location is derived from the request address and stored, so it is collected")
    }

    func testDoesNotClaimPreciseLocation() throws {
        XCTAssertFalse(
            try collectedTypes().contains("NSPrivacyCollectedDataTypePreciseLocation"),
            "nothing here reads CoreLocation; claiming precise location would be false")
    }

    func testDeclaresNoTracking() throws {
        XCTAssertEqual(try manifest()["NSPrivacyTracking"] as? Bool, false)
        XCTAssertEqual((try manifest()["NSPrivacyTrackingDomains"] as? [String])?.isEmpty, true)
    }

    func testEveryCollectedTypeStatesItsPurpose() throws {
        let types = try manifest()["NSPrivacyCollectedDataTypes"] as? [[String: Any]] ?? []
        XCTAssertFalse(types.isEmpty)
        for type in types {
            let name = type["NSPrivacyCollectedDataType"] as? String ?? "?"
            XCTAssertNotNil(type["NSPrivacyCollectedDataTypeLinked"], "\(name) omits Linked")
            XCTAssertNotNil(type["NSPrivacyCollectedDataTypeTracking"], "\(name) omits Tracking")
            let purposes = type["NSPrivacyCollectedDataTypePurposes"] as? [String] ?? []
            XCTAssertFalse(purposes.isEmpty, "\(name) states no purpose; Apple rejects that")
        }
    }
}
