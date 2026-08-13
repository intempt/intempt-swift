//
//  ReadWriteLock.swift
//  Intempt
//
//  Adapted from mixpanel-swift (https://github.com/mixpanel/mixpanel-swift)
//  Created by Hairuo Sang on 8/9/17.
//  Copyright © 2017 Mixpanel. All rights reserved.
//  Licensed under the Apache License, Version 2.0.
//
//  Modifications by Intempt Technologies, Inc. (Apache License 2.0, §4(b)):
//    - Renamed to the Intempt module namespace.
//    - `read` is generic and returns a value (upstream returns Void), so
//      callers can snapshot state under the lock and act on it outside —
//      the pattern the logger needs to avoid re-entrant deadlock.
//
import Foundation

/// Concurrent queue with barrier writes — the standard GCD reader/writer lock.
/// `qos` and `autoreleaseFrequency` are retained from upstream: the latter is a
/// real guard against unbounded autorelease growth on a long-lived queue.
final class ReadWriteLock {
    private let concurrentQueue: DispatchQueue

    init(label: String) {
        concurrentQueue = DispatchQueue(
            label: label, qos: .utility, attributes: .concurrent,
            autoreleaseFrequency: .workItem)
    }

    func read<T>(_ closure: () -> T) -> T {
        concurrentQueue.sync {
            closure()
        }
    }

    /// Synchronous barrier write, matching upstream. Callers needing
    /// fire-and-forget must dispatch themselves — this never silently
    /// goes async on you.
    @discardableResult
    func write<T>(_ closure: () -> T) -> T {
        concurrentQueue.sync(
            flags: .barrier,
            execute: {
                closure()
            })
    }
}
