import XCTest

@testable import Intempt

/// The `/flags/stream` connection state machine (F15), ported from intempt-node
/// tests/flag-stream.test.ts in spirit.
final class FlagStreamTests: XCTestCase {

    private var opened: [StreamHandlers] = []
    private var closes = 0
    private var scheduled: [(delay: TimeInterval, work: () -> Void)] = []
    private var changes: [[String]] = []
    private var states: [Bool] = []

    private func makeStream() -> FlagStream {
        FlagStream(
            open: { [unowned self] handlers in
                self.opened.append(handlers)
                return StreamHandle { [unowned self] in self.closes += 1 }
            },
            schedule: { [unowned self] delay, work in self.scheduled.append((delay, work)) },
            onChange: { [unowned self] in self.changes.append($0) },
            onState: { [unowned self] in self.states.append($0) })
    }

    /// Fails the live connection and runs the reconnect it schedules; returns the wait used.
    private func failAndReconnect() -> TimeInterval? {
        opened.last?.onClose()
        guard let next = scheduled.popLast() else { return nil }
        next.work()
        return next.delay
    }

    func testStartOpensOneConnection() {
        let stream = makeStream()
        stream.start()
        stream.start()
        XCTAssertEqual(opened.count, 1)
        XCTAssertFalse(stream.connected, "connected only once the server answers 200")
        opened[0].onOpen()
        XCTAssertTrue(stream.connected)
        XCTAssertEqual(states, [true])
    }

    func testReconnectBacksOffFrom1sDoublingTo60s() {
        let stream = makeStream()
        stream.start()
        var waits: [TimeInterval] = []
        for _ in 0..<9 { waits.append(failAndReconnect() ?? -1) }
        XCTAssertEqual(waits, [1, 2, 4, 8, 16, 32, 60, 60, 60])
        XCTAssertEqual(opened.count, 10)
    }

    func testASuccessfulOpenResetsTheBackoff() {
        let stream = makeStream()
        stream.start()
        _ = failAndReconnect()
        _ = failAndReconnect()
        opened.last?.onOpen()
        XCTAssertEqual(failAndReconnect(), 1)
    }

    func testWhileAReconnectIsPendingStartDoesNotOpenAnother() {
        let stream = makeStream()
        stream.start()
        opened[0].onClose()
        stream.start()
        XCTAssertEqual(opened.count, 1)
        XCTAssertEqual(scheduled.count, 1)
    }

    func testADroppedConnectionReportsDisconnected() {
        let stream = makeStream()
        stream.start()
        opened[0].onOpen()
        opened[0].onClose()
        XCTAssertFalse(stream.connected)
        XCTAssertEqual(states, [true, false])
    }

    func testOnlyFlagsChangedEventsReachTheCache() {
        let stream = makeStream()
        stream.start()
        opened[0].onMessage("flags_changed", #"{"reason":"kill","keys":["a","b"]}"#)
        opened[0].onMessage("message", #"{"keys":["c"]}"#)
        XCTAssertEqual(changes, [["a", "b"]])
    }

    func testCallbacksFromAReplacedConnectionAreIgnored() {
        let stream = makeStream()
        stream.start()
        let old = opened[0]
        _ = failAndReconnect()
        old.onOpen()
        old.onMessage("flags_changed", #"{"keys":["a"]}"#)
        old.onClose()
        XCTAssertFalse(stream.connected)
        XCTAssertTrue(changes.isEmpty)
        XCTAssertTrue(scheduled.isEmpty, "a stale close must not schedule a second reconnect")
    }

    func testCloseIsFinal() {
        let stream = makeStream()
        stream.start()
        opened[0].onOpen()
        opened[0].onClose()
        stream.close()
        scheduled.last?.work()
        stream.start()
        XCTAssertEqual(opened.count, 1)
        XCTAssertFalse(stream.connected)
    }

    func testCloseClosesTheLiveConnectionWithoutReconnecting() {
        let stream = makeStream()
        stream.start()
        opened[0].onOpen()
        stream.close()
        XCTAssertEqual(closes, 1)
        XCTAssertEqual(states, [true, false])
        opened[0].onClose()
        XCTAssertTrue(scheduled.isEmpty)
    }

    func testPauseCancelsAPendingReconnectAndStartResumes() {
        let stream = makeStream()
        stream.start()
        opened[0].onClose()
        stream.pause()
        scheduled.last?.work()
        XCTAssertEqual(opened.count, 1, "the cancelled timer must not reconnect")
        stream.start()
        XCTAssertEqual(opened.count, 2)
    }

    func testAConnectionThatClosesWhileOpeningStillReconnects() {
        let stream = FlagStream(
            open: { [unowned self] handlers in
                self.opened.append(handlers)
                handlers.onClose()
                return StreamHandle { [unowned self] in self.closes += 1 }
            },
            schedule: { [unowned self] delay, work in self.scheduled.append((delay, work)) },
            onChange: { _ in }, onState: { _ in })
        stream.start()
        XCTAssertEqual(scheduled.count, 1)
        scheduled[0].work()
        XCTAssertEqual(opened.count, 2)
    }

    func testChangedKeysAreReadFromTheEvent() {
        XCTAssertEqual(FlagStream.keys(of: #"{"reason":"change","keys":["a"]}"#), ["a"])
        XCTAssertEqual(FlagStream.keys(of: #"{"keys":[]}"#), [])
        XCTAssertEqual(FlagStream.keys(of: #"{"keys":["a",1]}"#), [], "a mixed list is not trusted")
        XCTAssertEqual(FlagStream.keys(of: "nope"), [])
        XCTAssertEqual(FlagStream.keys(of: #"{"reason":"kill"}"#), [])
    }
}

final class SSEParserTests: XCTestCase {

    private func parse(_ chunks: [String]) -> [String] {
        var parser = SSEParser()
        return chunks.flatMap { parser.feed(Data($0.utf8)) }.map { "\($0.event)|\($0.data)" }
    }

    func testANamedEventIsDispatchedOnTheBlankLine() {
        XCTAssertEqual(
            parse(["event:flags_changed\ndata:{\"keys\":[\"a\"]}\n\n"]),
            [#"flags_changed|{"keys":["a"]}"#])
    }

    func testTheHeartbeatCommentDispatchesNothing() {
        XCTAssertEqual(parse([":keepalive\n\n", ":keepalive\n\n"]), [])
    }

    func testCRLFAndOneLeadingSpaceAreStripped() {
        XCTAssertEqual(parse(["event: flags_changed\r\ndata:  x\r\n\r\n"]), ["flags_changed| x"])
    }

    func testMultipleDataLinesJoinWithNewlines() {
        XCTAssertEqual(parse(["data:a\ndata:b\n\n"]), ["message|a\nb"])
    }

    func testAnEventSplitAcrossChunksIsReassembled() {
        XCTAssertEqual(
            parse(["even", "t:flags_changed\nda", "ta:x\n", "\n"]), ["flags_changed|x"])
    }

    func testAUTF8SequenceSplitAcrossChunksIsNotMangled() {
        var parser = SSEParser()
        let bytes = Array("data:é\n\n".utf8)
        let split = bytes.firstIndex(of: 0xC3)! + 1
        XCTAssertTrue(parser.feed(Data(bytes[..<split])).isEmpty)
        XCTAssertEqual(parser.feed(Data(bytes[split...])).map(\.data), ["é"])
    }

    func testTheEventNameResetsAfterDispatch() {
        XCTAssertEqual(
            parse(["event:flags_changed\ndata:1\n\ndata:2\n\n"]), ["flags_changed|1", "message|2"])
    }
}
