//
//  IntemptLogger.swift
//  Intempt
//
//  Adapted from mixpanel-swift's MixpanelLogger.swift
//  (https://github.com/mixpanel/mixpanel-swift)
//  Copyright © 2016 Mixpanel. All rights reserved.
//  Licensed under the Apache License, Version 2.0.
//
//  Modifications by Intempt Technologies, Inc. (Apache License 2.0, §4(b)):
//    - Renamed to the Intempt module namespace.
//    - Registered loggers are snapshotted under the lock and invoked OUTSIDE
//      it. Upstream calls integrator code while holding the lock, so a logger
//      that re-enters (logs, or touches SDK state) deadlocks against itself.
//    - Public surface: integrators can register and remove sinks. Upstream's
//      logger is internal, which makes its logging protocol unusable.
//
import Foundation

public enum IntemptLogLevel: Int, CaseIterable, Sendable {
    case debug = 0
    case info
    case warning
    case error
}

/// Implement this to receive SDK diagnostics. Nothing is emitted until a level
/// is explicitly enabled — the SDK is silent by default.
public protocol IntemptLogging: AnyObject {
    func log(level: IntemptLogLevel, message: String)
}

/// Writes to stdout. Not registered by default.
public final class IntemptPrintLogger: IntemptLogging {
    public init() {}
    public func log(level: IntemptLogLevel, message: String) {
        print("[Intempt/\(level)] \(message)")
    }
}

public final class IntemptLogger {
    public static let shared = IntemptLogger()

    private let lock = ReadWriteLock(label: "com.intempt.logger")
    private var loggers: [IntemptLogging] = []
    /// Silent by default. The old Obj-C SDK logged the database path
    /// unconditionally on every launch; nothing is emitted here until asked.
    private var enabledLevels: Set<IntemptLogLevel> = []

    private init() {}

    public func addLogging(_ logging: IntemptLogging) {
        lock.write { self.loggers.append(logging) }
    }

    public func removeAllLogging() {
        lock.write { self.loggers.removeAll() }
    }

    public func enable(_ level: IntemptLogLevel) {
        lock.write { _ = self.enabledLevels.insert(level) }
    }

    public func enableAllLevels() {
        lock.write { self.enabledLevels = Set(IntemptLogLevel.allCases) }
    }

    public func disable(_ level: IntemptLogLevel) {
        lock.write { _ = self.enabledLevels.remove(level) }
    }

    public func disableAllLevels() {
        lock.write { self.enabledLevels.removeAll() }
    }

    func isEnabled(_ level: IntemptLogLevel) -> Bool {
        lock.read { enabledLevels.contains(level) }
    }

    /// Snapshot under the lock, invoke outside it — integrator callbacks must
    /// never run while this lock is held.
    func log(_ level: IntemptLogLevel, _ message: @autoclosure () -> String) {
        let (shouldLog, sinks) = lock.read { (enabledLevels.contains(level), loggers) }
        guard shouldLog else { return }
        let rendered = message()
        for sink in sinks {
            sink.log(level: level, message: rendered)
        }
    }
}
