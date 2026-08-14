import XCTest

@testable import Intempt

final class IntemptDBTests: XCTestCase {

    private var tmpDir: URL!
    private var db: IntemptDB!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("intempt-db-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        db = IntemptDB(namespace: "test", directoryOverride: tmpDir)
    }

    override func tearDownWithError() throws {
        db = nil
        try? FileManager.default.removeItem(at: tmpDir)
        try super.tearDownWithError()
    }

    private func payload(_ s: String) -> Data { Data(s.utf8) }

    func testOpensAndCreatesTables() {
        XCTAssertTrue(db.isOpen)
        XCTAssertEqual(db.count(.events), 0)
        XCTAssertEqual(db.count(.consents), 0)
    }

    func testInsertThenReadRoundTrip() {
        XCTAssertTrue(db.insert(.events, data: payload("a")))
        XCTAssertTrue(db.insert(.events, data: payload("b")))
        let rows = db.read(.events, limit: 10)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.map { String(decoding: $0.data, as: UTF8.self) }, ["a", "b"])
    }

    func testReadIsOldestFirstAndRespectsLimit() {
        for s in ["1", "2", "3", "4"] { db.insert(.events, data: payload(s)) }
        let rows = db.read(.events, limit: 2)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(String(decoding: rows[0].data, as: UTF8.self), "1")
    }

    /// The core fix for the old SDK's F-09: delete exactly the acked ids,
    /// never a blanket delete that destroys other in-flight batches.
    func testDeleteRemovesOnlyTheGivenIds() {
        for s in ["a", "b", "c"] { db.insert(.events, data: payload(s)) }
        let rows = db.read(.events, limit: 10)
        XCTAssertTrue(db.delete(.events, ids: [rows[0].id, rows[2].id]))
        let left = db.read(.events, limit: 10)
        XCTAssertEqual(left.count, 1)
        XCTAssertEqual(String(decoding: left[0].data, as: UTF8.self), "b")
    }

    /// Upstream builds `WHERE id IN )` for an empty list, which fails to
    /// prepare and cascades into recreate() — wiping every queued event.
    /// Deleting nothing must delete nothing.
    func testDeletingEmptyIdListDoesNotWipeTheDatabase() {
        for s in ["a", "b", "c"] { db.insert(.events, data: payload(s)) }
        XCTAssertEqual(db.count(.events), 3)

        XCTAssertTrue(db.delete(.events, ids: []))

        XCTAssertEqual(db.count(.events), 3, "an empty delete must not destroy the queue")
        XCTAssertTrue(db.isOpen)
    }

    func testFlagRoundTripSeparatesClaimedRows() {
        for s in ["a", "b"] { db.insert(.events, data: payload(s)) }
        let rows = db.read(.events, limit: 10)
        XCTAssertTrue(db.setFlag(.events, ids: [rows[0].id], to: true))

        XCTAssertEqual(db.read(.events, limit: 10, flag: false).count, 1)
        XCTAssertEqual(db.read(.events, limit: 10, flag: true).count, 1)
    }

    func testEventsAndConsentsAreSeparateStores() {
        db.insert(.events, data: payload("e"))
        db.insert(.consents, data: payload("c"))
        XCTAssertEqual(db.count(.events), 1)
        XCTAssertEqual(db.count(.consents), 1)
        db.deleteAll(.events)
        XCTAssertEqual(db.count(.events), 0)
        XCTAssertEqual(db.count(.consents), 1, "consents must be untouched")
    }

    /// Survives process restart — the old SDK marked rows sent before the POST
    /// and lost them on force-quit.
    func testDataSurvivesReopen() {
        db.insert(.events, data: payload("persisted"))
        db = nil
        db = IntemptDB(namespace: "test", directoryOverride: tmpDir)
        let rows = db.read(.events, limit: 10)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(String(decoding: rows[0].data, as: UTF8.self), "persisted")
    }

    func testTrimEvictsOldestBeyondCeiling() {
        for i in 1...10 { db.insert(.events, data: payload("\(i)")) }
        let evicted = db.trim(.events, to: 4)
        XCTAssertEqual(evicted, 6)
        XCTAssertEqual(db.count(.events), 4)
        let left = db.read(.events, limit: 10).map { String(decoding: $0.data, as: UTF8.self) }
        XCTAssertEqual(left, ["7", "8", "9", "10"], "oldest rows must be the ones evicted")
    }

    func testTrimIsNoOpUnderCeiling() {
        db.insert(.events, data: payload("a"))
        XCTAssertEqual(db.trim(.events, to: 100), 0)
        XCTAssertEqual(db.count(.events), 1)
    }

    /// Concurrent writers must not lose rows or corrupt the store.
    func testConcurrentInsertsAllLand() {
        let group = DispatchGroup()
        for i in 0..<200 {
            group.enter()
            DispatchQueue.global().async {
                self.db.insert(.events, data: self.payload("row-\(i)"))
                group.leave()
            }
        }
        group.wait()
        XCTAssertEqual(db.count(.events), 200)
    }

    func testEmptyNamespaceDoesNotOpen() {
        let bad = IntemptDB(namespace: "", directoryOverride: tmpDir)
        XCTAssertFalse(bad.isOpen)
        XCTAssertFalse(bad.insert(.events, data: payload("x")))
    }
}
