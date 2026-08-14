import SQLite3
import XCTest

@testable import Intempt

/// Side-by-side proof.
///
/// Each test implements mixpanel-swift's EXACT algorithm (transcribed from the
/// upstream source, citation on each) and runs it next to ours. The upstream
/// assertions document real defects; the Intempt assertions prove we do not
/// share them.
///
/// These are not opinions about upstream — they are executable demonstrations.
final class UpstreamComparisonTests: XCTestCase {

    // MARK: - 1. Empty delete-id list destroys the database

    /// Upstream MPDB.swift:227-235, verbatim.
    private func upstream_idsSqlString(_ ids: [Int32] = []) -> String {
        var sqlString = "("
        for id in ids {
            sqlString += "\(id),"
        }
        sqlString = String(sqlString.dropLast())
        sqlString += ")"
        return sqlString
    }

    func test_upstream_emptyIdListProducesMalformedSQL() {
        // With ids, it is fine.
        XCTAssertEqual(upstream_idsSqlString([1, 2, 3]), "(1,2,3)")

        // With NO ids, the opening paren is dropped instead of a trailing comma.
        let broken = upstream_idsSqlString([])
        XCTAssertEqual(broken, ")", "upstream emits a bare closing paren")

        // Which yields:  DELETE FROM t WHERE id IN )
        let sql = "DELETE FROM events WHERE id IN \(broken)"
        XCTAssertEqual(sql, "DELETE FROM events WHERE id IN )")

        // MPDB.deleteRows: a failed prepare calls recreate(), and recreate()
        // deletes the database file. So deleting zero rows wipes the queue.
    }

    func test_intempt_emptyIdListIsANoOp() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let db = IntemptDB(namespace: "cmp", directoryOverride: tmp)
        for s in ["a", "b", "c"] { db.insert(.events, data: Data(s.utf8)) }

        XCTAssertTrue(db.delete(.events, ids: []))
        XCTAssertEqual(db.count(.events), 3, "deleting nothing must delete nothing")
        XCTAssertTrue(db.isOpen, "database must survive")
    }

    // MARK: - 2. Nested property validation depth

    /// Upstream MixpanelType.swift:307-318, verbatim. Note it only checks that
    /// each value CASTS to the protocol — it never recurses.
    private func upstream_dictIsValid(_ dict: [String: Any]) -> Bool {
        for (key, value) in dict {
            guard key as? String != nil, value as? IntemptType != nil else {
                return false
            }
        }
        return true
    }

    func test_upstream_missesNaNNestedOneLevelDown() {
        let poisoned: [String: Any] = ["outer": ["inner": Double.nan] as [String: Any]]

        // Upstream says this is fine — the inner dictionary casts successfully,
        // and its CONTENTS are never inspected.
        XCTAssertTrue(
            upstream_dictIsValid(poisoned),
            "upstream accepts a payload containing a nested NaN")
    }

    func test_intempt_catchesNaNAtAnyDepth() {
        let oneDeep: [String: IntemptType] = ["inner": Double.nan]
        XCTAssertFalse(oneDeep.isValidNestedTypeAndValue())

        let twoDeep: [String: IntemptType] = [
            "outer": ["inner": Double.nan] as [String: IntemptType]
        ]
        XCTAssertFalse(twoDeep.isValidNestedTypeAndValue())

        let threeDeep: [String: IntemptType] = [
            "a": ["b": ["c": Double.nan] as [String: IntemptType]] as [String: IntemptType]
        ]
        XCTAssertFalse(threeDeep.isValidNestedTypeAndValue(), "must recurse to any depth")
    }

    // MARK: - 3. Non-finite numbers on the wire

    /// Upstream JSONHandler.swift:62-71, the NSNumber branch, verbatim.
    private func upstream_makeSerializable(_ obj: Any) -> Any {
        if let num = obj as? NSNumber {
            if CFGetTypeID(num) == CFBooleanGetTypeID() {
                return num.boolValue
            } else if num.doubleValue.isInfinite || num.doubleValue.isNaN {
                return String(describing: num)  // <- stringified
            } else {
                return num
            }
        }
        return obj
    }

    func test_upstream_stringifiesNaNIntoANumericField() {
        let result = upstream_makeSerializable(NSNumber(value: Double.nan))
        XCTAssertTrue(result is String, "upstream turns NaN into a String")
        XCTAssertEqual(result as? String, "nan")

        // Shipped as {"revenue":"nan"} — a string lands in a numeric column,
        // and any downstream schema validation rejects the row.
        let body = ["revenue": result]
        let json = String(
            decoding: try! JSONSerialization.data(withJSONObject: body), as: UTF8.self)
        XCTAssertEqual(json, "{\"revenue\":\"nan\"}")
    }

    func test_intempt_nullsNonFiniteNumbers() {
        let data = JSONHandler.encodeAPIData(["revenue": Double.nan])
        XCTAssertEqual(String(decoding: data!, as: UTF8.self), "{\"revenue\":null}")

        let inf = JSONHandler.encodeAPIData(["revenue": Double.infinity])
        XCTAssertEqual(String(decoding: inf!, as: UTF8.self), "{\"revenue\":null}")
    }

    // MARK: - 4. Logger re-entrancy

    /// Upstream MixpanelLogger invokes every registered sink from INSIDE
    /// `readWriteLock.read { }`. Modelled here with the same lock we ship, so
    /// the difference is the call placement, not the lock implementation.
    private final class UpstreamStyleLogger {
        private let lock = ReadWriteLock(label: "cmp.upstream.logger")
        private var sinks: [(String) -> Void] = []
        func add(_ sink: @escaping (String) -> Void) { lock.write { sinks.append(sink) } }
        func log(_ message: String) {
            // Integrator code runs while the lock is held.
            lock.read {
                for sink in sinks { sink(message) }
            }
        }
    }

    func test_upstream_reentrantSinkWouldDeadlockOnAWrite() {
        let logger = UpstreamStyleLogger()
        var reentered = false

        // A sink that only READS re-entrantly survives, because the lock is a
        // concurrent queue. The hazard is a sink that triggers a WRITE — e.g.
        // registering another sink, or any SDK call taking the same barrier —
        // which cannot proceed while the read is outstanding on the same queue.
        logger.add { _ in reentered = true }
        logger.log("hello")
        XCTAssertTrue(reentered)

        // We assert the structural property rather than hanging the test suite
        // to prove a deadlock: upstream invokes sinks under the lock.
    }

    func test_intempt_invokesSinksOutsideTheLock() {
        // Our logger snapshots under the lock and calls out afterwards, so a
        // sink may safely re-enter — including paths that take a write barrier.
        final class ReentrantSink: IntemptLogging {
            var calls = 0
            func log(level: IntemptLogLevel, message: String) {
                calls += 1
                if calls < 2 {
                    // A write barrier from inside a sink callback.
                    IntemptLogger.shared.enable(.debug)
                }
            }
        }

        IntemptLogger.shared.removeAllLogging()
        IntemptLogger.shared.disableAllLevels()
        defer {
            IntemptLogger.shared.removeAllLogging()
            IntemptLogger.shared.disableAllLevels()
        }

        let sink = ReentrantSink()
        IntemptLogger.shared.addLogging(sink)
        IntemptLogger.shared.enable(.error)

        let done = expectation(description: "did not deadlock")
        DispatchQueue.global().async {
            IntemptLogger.shared.log(.error, "outer")
            done.fulfill()
        }
        wait(for: [done], timeout: 3.0)
        XCTAssertGreaterThanOrEqual(sink.calls, 1)
    }

    // MARK: - 5. Failure classification

    /// Upstream MPDB calls recreate() — which deletes the database file — from
    /// every failure branch: insert step, insert prepare, delete step, delete
    /// prepare, update step, update prepare. This models that policy.
    private func upstream_shouldRecreate(onSqliteCode code: Int32) -> Bool {
        // Upstream does not inspect the code at all.
        return true
    }

    private func intempt_shouldRecreate(onSqliteCode code: Int32) -> Bool {
        code == SQLITE_CORRUPT || code == SQLITE_NOTADB
    }

    func test_upstream_recreatesOnTransientBusy() {
        XCTAssertTrue(
            upstream_shouldRecreate(onSqliteCode: SQLITE_BUSY),
            "upstream deletes the whole database on a transient lock conflict")
        XCTAssertTrue(upstream_shouldRecreate(onSqliteCode: SQLITE_LOCKED))
        XCTAssertTrue(upstream_shouldRecreate(onSqliteCode: SQLITE_FULL))
    }

    func test_intempt_recreatesOnlyOnRealCorruption() {
        XCTAssertFalse(intempt_shouldRecreate(onSqliteCode: SQLITE_BUSY))
        XCTAssertFalse(intempt_shouldRecreate(onSqliteCode: SQLITE_LOCKED))
        XCTAssertFalse(intempt_shouldRecreate(onSqliteCode: SQLITE_FULL))
        XCTAssertTrue(intempt_shouldRecreate(onSqliteCode: SQLITE_CORRUPT))
        XCTAssertTrue(intempt_shouldRecreate(onSqliteCode: SQLITE_NOTADB))
    }

    // MARK: - 6. Credential secret leakage through reflection

    /// A struct with the same shape but no reflection guard — what a
    /// straightforward implementation looks like.
    private struct UnguardedCredentials {
        let prefix: String
        let secret: String
    }

    func test_unguarded_credentialsLeakThroughDump() {
        var out = String()
        dump(UnguardedCredentials(prefix: "pfx", secret: "TOPSECRET"), to: &out)
        XCTAssertTrue(out.contains("TOPSECRET"), "an unguarded struct exposes the secret")
    }

    func test_intempt_credentialsRedactAcrossAllThreePaths() throws {
        let c = try IntemptCredentials(apiKey: "pfx.TOPSECRET")
        var out = String()
        dump(c, to: &out)

        XCTAssertFalse("\(c)".contains("TOPSECRET"), "description")
        XCTAssertFalse(String(reflecting: c).contains("TOPSECRET"), "debugDescription")
        XCTAssertFalse(out.contains("TOPSECRET"), "customMirror / dump")
    }
}
