import XCTest
@testable import Intempt

/// The privacy manifest is a shipped artefact Apple reads, so its contents are pinned here.
///
/// Intempt derives country, region and city server-side from the address the request arrives on.
/// Apple's rule is that anything derived from data sent off device counts separately from the data
/// itself, and the derived location is stored -- so the app collects Coarse Location and the
/// manifest has to say so. The address itself is discarded at ingestion and is therefore not
/// collected, which is why no identifier entry is needed for it.
///
/// These assert VALUES, not presence. An earlier version used `XCTAssertNotNil` on `Linked` and
/// `Tracking` and never read them, and checked only that a type name appeared somewhere in the
/// list. Five edits to the manifest left all four tests green: flipping Coarse Location's
/// `Tracking` to true (contradicting the top-level `NSPrivacyTracking false`), flipping `Linked`
/// to false, changing the purpose to third-party advertising, deleting the whole
/// `NSPrivacyAccessedAPITypes` block, and adding an unrelated collected type. This is the one
/// place in the SDK where a wrong value is a false declaration to Apple rather than a bug, so
/// "it parses and the key is there" is not a strong enough bar.
final class PrivacyManifestTests: XCTestCase {

    /// Every type the SDK declares. Asserted as a whole set, so an ADDED type fails too --
    /// a manifest that over-declares is as false as one that under-declares.
    private static let expectedCollectedTypes: Set<String> = [
        "NSPrivacyCollectedDataTypeProductInteraction",
        "NSPrivacyCollectedDataTypeUserID",
        "NSPrivacyCollectedDataTypeCoarseLocation",
        "NSPrivacyCollectedDataTypeDeviceID",
    ]

    private func manifest() throws -> [String: Any] {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"),
            "the manifest must ship in the bundle, or Apple never sees it")
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try XCTUnwrap(plist as? [String: Any])
    }

    /// Throws rather than defaulting to `[]`. The old version ended `?? []`, which made the
    /// precise-location negative satisfiable by an empty array -- it would have passed against a
    /// manifest with no collected types at all.
    private func collectedTypeDicts() throws -> [[String: Any]] {
        try XCTUnwrap(
            manifest()["NSPrivacyCollectedDataTypes"] as? [[String: Any]],
            "the manifest declares no collected types at all")
    }

    private func collectedTypes() throws -> [String] {
        try collectedTypeDicts().compactMap { $0["NSPrivacyCollectedDataType"] as? String }
    }

    private func entry(for type: String) throws -> [String: Any] {
        try XCTUnwrap(
            collectedTypeDicts().first { $0["NSPrivacyCollectedDataType"] as? String == type },
            "\(type) is not declared")
    }

    func testDeclaresExactlyTheExpectedCollectedTypes() throws {
        XCTAssertEqual(
            Set(try collectedTypes()), Self.expectedCollectedTypes,
            "the manifest must declare these and nothing else; an extra type is a false "
                + "declaration to Apple just as a missing one is")
        XCTAssertEqual(
            try collectedTypes().count, Self.expectedCollectedTypes.count,
            "a duplicated entry would satisfy the set comparison above")
    }

    /// The entry this PR adds, asserted whole. Each of these three was independently flippable
    /// while the old tests stayed green.
    func testCoarseLocationEntryIsDeclaredExactly() throws {
        let entry = try entry(for: "NSPrivacyCollectedDataTypeCoarseLocation")

        XCTAssertEqual(
            entry["NSPrivacyCollectedDataTypeLinked"] as? Bool, true,
            "location is stored against the profile, so it is linked")
        XCTAssertEqual(
            entry["NSPrivacyCollectedDataTypeTracking"] as? Bool, false,
            "true here would contradict the top-level NSPrivacyTracking false in the same file")
        XCTAssertEqual(
            entry["NSPrivacyCollectedDataTypePurposes"] as? [String],
            ["NSPrivacyCollectedDataTypePurposeAnalytics"],
            "analytics only; third-party advertising would be a false declaration")
    }

    func testDoesNotClaimPreciseLocation() throws {
        // Positive control first: without it this test passes against a manifest that collects
        // nothing, which is exactly how the old version carried no control of its own.
        XCTAssertTrue(
            try collectedTypes().contains("NSPrivacyCollectedDataTypeCoarseLocation"),
            "control: the list must be populated for the negative below to mean anything")
        XCTAssertFalse(
            try collectedTypes().contains("NSPrivacyCollectedDataTypePreciseLocation"),
            "nothing here reads CoreLocation; claiming precise location would be false")
    }

    func testDeclaresNoTracking() throws {
        XCTAssertEqual(try manifest()["NSPrivacyTracking"] as? Bool, false)
        XCTAssertEqual((try manifest()["NSPrivacyTrackingDomains"] as? [String])?.isEmpty, true)
    }

    /// The required-reason API block. Deleting it entirely left every old test green, and a
    /// missing or wrong reason code is an App Store rejection.
    func testDeclaresTheRequiredReasonAPIs() throws {
        let accessed = try XCTUnwrap(
            manifest()["NSPrivacyAccessedAPITypes"] as? [[String: Any]],
            "the required-reason API block is absent; Apple rejects the build")

        var reasons: [String: [String]] = [:]
        for api in accessed {
            guard let name = api["NSPrivacyAccessedAPIType"] as? String else { continue }
            reasons[name] = api["NSPrivacyAccessedAPITypeReasons"] as? [String]
        }

        XCTAssertEqual(
            reasons["NSPrivacyAccessedAPICategoryUserDefaults"], ["CA92.1"],
            "UserDefaults is read for the SDK's own state only")
        XCTAssertEqual(
            reasons["NSPrivacyAccessedAPICategoryDiskSpace"], ["E174.1"],
            "disk space is checked before writing the event queue")
        XCTAssertEqual(reasons.count, 2, "an undeclared accessed API is a rejection")
    }

    func testEveryCollectedTypeStatesItsPurpose() throws {
        let types = try collectedTypeDicts()
        XCTAssertFalse(types.isEmpty)
        for type in types {
            let name = type["NSPrivacyCollectedDataType"] as? String ?? "?"
            // Values, not presence: `NotNil` passed for any Bool, so a flipped flag was invisible.
            XCTAssertEqual(
                type["NSPrivacyCollectedDataTypeLinked"] as? Bool, true, "\(name) must be linked")
            XCTAssertEqual(
                type["NSPrivacyCollectedDataTypeTracking"] as? Bool, false,
                "\(name) claims tracking while NSPrivacyTracking is false")
            XCTAssertEqual(
                type["NSPrivacyCollectedDataTypePurposes"] as? [String],
                ["NSPrivacyCollectedDataTypePurposeAnalytics"],
                "\(name) states a purpose this SDK does not serve")
        }
    }
}
