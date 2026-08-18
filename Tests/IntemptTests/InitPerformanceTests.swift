//
//  InitPerformanceTests.swift
//  IntemptTests
//
//  Copyright © 2026 Intempt Technologies, Inc.
//  Licensed under the Apache License, Version 2.0.
//
//  What the SDK costs the app that embeds it, measured rather than assumed.
//
//  Nothing in this repo had ever measured this. The audit scored the SDK's
//  on-device runtime cost as zero — not "slow", but *never measured* — and a
//  blank is what this file removes.
//
//  Two rules this file exists to obey, both learned from the Android SDK's
//  equivalent work:
//
//    1. MEASURE THE SDK, NOT THE MACHINE. That report published "+340 ms of
//       cold start" for three revisions. The real figure was 27.8 ms; the rest
//       was emulator variance in a whole-app metric far too coarse to resolve a
//       component that small. So everything here brackets the SDK's own call
//       and nothing else — `startMeasuring()` is manual, and per-iteration
//       setup sits outside the bracket.
//
//    2. A THRESHOLD YOU INVENTED IS NOT A MEASUREMENT. `ceilingSeconds` below
//       is a catastrophe tripwire, not a budget. It is deliberately loose,
//       because no honest number for this SDK exists yet. Once CI has reported
//       real figures for a few runs, tighten it to something derived from them.
//       Setting a tight bound now would only teach everyone to re-run the job.
//
//  These tests SKIP by default. `swift test --parallel` runs suites
//  concurrently, and a wall-clock measurement taken while N other test bundles
//  compete for the same cores measures the scheduler. The `perf` CI job runs
//  them alone, without `--parallel`, with INTEMPT_PERF=1 set. Same
//  skip-unless-configured shape as LiveContractTests.
//
import XCTest

@testable import Intempt

final class InitPerformanceTests: IntemptTestCase {

    /// Per-init wall-clock ceiling. A tripwire for "something is structurally
    /// wrong" — an accidental synchronous network call, a full table scan on
    /// open — not a performance budget. See rule 2 in the file comment.
    private let ceilingSeconds: TimeInterval = 0.25

    /// Directories are created up front, one per iteration, so `mkdir` never
    /// lands inside the measured bracket.
    private var iterationDirs: [URL] = []

    private func makeIterationDirs(_ count: Int) -> [URL] {
        (0..<count).map { i in
            let dir = tempDir.appendingPathComponent("perf-\(i)-\(UUID().uuidString)")
            try! FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true)
            return dir
        }
    }

    private func skipUnlessEnabled() throws {
        guard ProcessInfo.processInfo.environment["INTEMPT_PERF"] == "1" else {
            throw XCTSkip(
                "performance tests skipped — set INTEMPT_PERF=1 and run without --parallel")
        }
    }

    // MARK: - Cold init

    /// The number that matters to an integrator: what `initialize` costs on a
    /// device that has never run the SDK before.
    ///
    /// A fresh directory per iteration means every run pays the real cold cost
    /// — `sqlite3_open_v2`, the `journal_mode=WAL` pragma, and `CREATE TABLE`
    /// — rather than the second iteration quietly measuring a warm open and
    /// halving the reported figure.
    func testColdInitializePerformance() throws {
        try skipUnlessEnabled()

        var next = 0
        let dirs = makeIterationDirs(12)

        measureMetrics([.wallClockTime], automaticallyStartMeasuring: false) {
            // Outside the bracket: picking a directory is the harness's cost,
            // not the SDK's.
            let dir = dirs[min(next, dirs.count - 1)]
            next += 1

            startMeasuring()
            let instance = try! IntemptInstance.makeForTesting(
                store: defaults, databaseDirectory: dir)
            stopMeasuring()

            // Teardown outside the bracket too. Held until after
            // stopMeasuring() so deinit — which removes AppLifecycle's
            // observers — cannot be attributed to init.
            withExtendedLifetime(instance) {}
        }
    }

    // MARK: - Warm init

    /// The relaunch case: the store already exists on disk. Every launch after
    /// the first one is this, so it is the figure most users actually
    /// experience. Compared against the cold number, the gap is the one-time
    /// cost of creating the store.
    func testWarmInitializePerformance() throws {
        try skipUnlessEnabled()

        let dir = makeIterationDirs(1)[0]
        // Prime the store so the measured inits all open an existing database.
        withExtendedLifetime(
            try IntemptInstance.makeForTesting(store: defaults, databaseDirectory: dir)
        ) {}

        measureMetrics([.wallClockTime], automaticallyStartMeasuring: false) {
            startMeasuring()
            let instance = try! IntemptInstance.makeForTesting(
                store: defaults, databaseDirectory: dir)
            stopMeasuring()
            withExtendedLifetime(instance) {}
        }
    }

    // MARK: - Enqueue cost

    /// What one `track()` costs on the calling thread.
    ///
    /// This is the call an app makes from a tap handler, so it is the one that
    /// can cost a frame if it is wrong. It writes to SQLite, so "it's just an
    /// append to an array" is an assumption worth checking rather than
    /// believing.
    func testTrackEnqueuePerformance() throws {
        try skipUnlessEnabled()

        let dir = makeIterationDirs(1)[0]
        let instance = try IntemptInstance.makeForTesting(
            store: defaults, databaseDirectory: dir)

        var counter = 0
        measureMetrics([.wallClockTime], automaticallyStartMeasuring: false) {
            let name = "perf_event_\(counter)"
            counter += 1

            startMeasuring()
            let queued = instance.track(eventTitle: name, data: ["index": counter])
            stopMeasuring()

            XCTAssertTrue(queued, "the event must actually be queued, or this times a no-op")
        }
    }

    // MARK: - Tripwire

    /// A hard assertion, separate from the `measure` blocks above.
    ///
    /// `measureMetrics` reports and compares against a stored baseline; with no
    /// baseline committed it cannot fail, so on its own it would report a
    /// regression to a log nobody reads. This one fails the build.
    ///
    /// Deliberately timed over several inits and compared against the mean, so
    /// a single scheduling hiccup on a shared CI runner cannot trip it.
    func testInitializeStaysUnderCatastropheCeiling() throws {
        try skipUnlessEnabled()

        let iterations = 10
        let dirs = makeIterationDirs(iterations)

        let started = Date()
        for dir in dirs {
            withExtendedLifetime(
                try IntemptInstance.makeForTesting(store: defaults, databaseDirectory: dir)
            ) {}
        }
        let mean = Date().timeIntervalSince(started) / Double(iterations)

        // Printed unconditionally: the value is the point of the test, and CI
        // logs are where the first real figures for this SDK will come from.
        print("[perf] cold IntemptInstance init mean: \(String(format: "%.2f", mean * 1000)) ms")

        XCTAssertLessThan(
            mean, ceilingSeconds,
            """
            cold init averaged \(String(format: "%.1f", mean * 1000)) ms over \(iterations) runs, \
            over the \(Int(ceilingSeconds * 1000)) ms tripwire. This bound is loose on purpose — \
            crossing it means something structural changed (a synchronous network call on the \
            init path, an unindexed query at open), not that the SDK drifted a few milliseconds.
            """)
    }
}
