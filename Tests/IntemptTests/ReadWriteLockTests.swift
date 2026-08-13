import XCTest

@testable import Intempt

final class ReadWriteLockTests: XCTestCase {

    func testConcurrentReadsAllComplete() {
        let lock = ReadWriteLock(label: "test.rwlock.reads")
        let expectation = expectation(description: "all reads complete")
        expectation.expectedFulfillmentCount = 50
        for _ in 0..<50 {
            DispatchQueue.global().async {
                _ = lock.read { 1 + 1 }
                expectation.fulfill()
            }
        }
        wait(for: [expectation], timeout: 5.0)
    }

    /// Detects a torn read: a paired write must never be observed half-applied.
    /// The earlier draft of this test only ever wrote, so it passed even against
    /// a no-op lock. This writes a two-field invariant and reads it back.
    func testPairedWriteIsNeverObservedTorn() {
        let lock = ReadWriteLock(label: "test.rwlock.torn")
        var a = 0
        var b = 0
        let group = DispatchGroup()

        for i in 1...300 {
            group.enter()
            DispatchQueue.global().async {
                lock.write {
                    a = i
                    b = i  // must always equal `a` when observed under the lock
                }
                let (ra, rb) = lock.read { (a, b) }
                XCTAssertEqual(ra, rb, "observed a torn write: a=\(ra) b=\(rb)")
                group.leave()
            }
        }
        group.wait()
    }

    func testWriteReturnsValue() {
        let lock = ReadWriteLock(label: "test.rwlock.return")
        let result: Int = lock.write { 42 }
        XCTAssertEqual(result, 42)
    }
}
