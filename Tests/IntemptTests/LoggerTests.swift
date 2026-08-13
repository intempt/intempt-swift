import XCTest

@testable import Intempt

final class CollectingLogger: IntemptLogging {
    var messages: [String] = []
    func log(level: IntemptLogLevel, message: String) { messages.append(message) }
}

/// Re-entrant sink: logs again from inside its own callback. Against upstream's
/// invoke-under-lock design this deadlocks.
final class ReentrantLogger: IntemptLogging {
    var depth = 0
    func log(level: IntemptLogLevel, message: String) {
        depth += 1
        if depth < 2 {
            IntemptLogger.shared.log(.error, "re-entrant call")
        }
    }
}

final class LoggerTests: XCTestCase {

    override func setUp() {
        super.setUp()
        IntemptLogger.shared.removeAllLogging()
        IntemptLogger.shared.disableAllLevels()
    }

    override func tearDown() {
        IntemptLogger.shared.removeAllLogging()
        IntemptLogger.shared.disableAllLevels()
        super.tearDown()
    }

    func testSilentByDefault() {
        let sink = CollectingLogger()
        IntemptLogger.shared.addLogging(sink)
        IntemptLogger.shared.log(.debug, "should not appear")
        IntemptLogger.shared.log(.error, "should not appear either")
        XCTAssertTrue(sink.messages.isEmpty, "SDK must emit nothing until a level is enabled")
    }

    func testEmitsOnlyEnabledLevels() {
        let sink = CollectingLogger()
        IntemptLogger.shared.addLogging(sink)
        IntemptLogger.shared.enable(.error)
        IntemptLogger.shared.log(.debug, "no")
        IntemptLogger.shared.log(.error, "yes")
        XCTAssertEqual(sink.messages, ["yes"])
    }

    /// Regression guard for the deadlock upstream's design allows.
    func testReentrantLoggerDoesNotDeadlock() {
        let sink = ReentrantLogger()
        IntemptLogger.shared.addLogging(sink)
        IntemptLogger.shared.enableAllLevels()

        let done = expectation(description: "re-entrant log returned")
        DispatchQueue.global().async {
            IntemptLogger.shared.log(.error, "outer")
            done.fulfill()
        }
        wait(for: [done], timeout: 3.0)
        XCTAssertGreaterThanOrEqual(sink.depth, 1)
    }

    func testMessageIsNotBuiltWhenLevelDisabled() {
        var built = false
        IntemptLogger.shared.log(.debug, { built = true; return "expensive" }())
        XCTAssertFalse(built, "autoclosure must not evaluate when the level is off")
    }
}
