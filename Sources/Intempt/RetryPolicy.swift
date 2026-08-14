//
//  RetryPolicy.swift
//  Intempt
//
//  Adapted from mixpanel-swift's FlushRequest.swift
//  (https://github.com/mixpanel/mixpanel-swift)
//  Copyright © 2016 Mixpanel. All rights reserved.
//  Licensed under the Apache License, Version 2.0.
//
//  Modifications by Intempt Technologies, Inc. (Apache License 2.0, §4(b)):
//    - Extracted as a pure, injectable value type. Upstream couples backoff
//      state to the network class and reads `Date()` internally, so its own
//      documented behaviour ("honors Retry-After") cannot be unit-tested.
//      Here the clock and jitter are injected, so every branch is provable.
//    - Failure counting is reset only on success, matching upstream.
//    - Backup-host failover is deliberately NOT ported: no Intempt backend
//      support for it exists.
//
import Foundation

/// Decides whether a flush may proceed, and how long to wait after a failure.
///
/// Shape retained from upstream: exponential 2^(n-1)·60s with jitter, clamped
/// to [60s, 600s], engaged only after 2 consecutive failures, and never
/// shorter than a server-supplied `Retry-After`.
struct RetryPolicy {

    private let now: () -> Date
    private let jitter: () -> TimeInterval

    /// Requests are suppressed until this instant.
    private(set) var allowedAfter: Date
    private(set) var consecutiveFailures: Int = 0

    init(
        now: @escaping () -> Date = Date.init,
        jitter: @escaping () -> TimeInterval = { TimeInterval(arc4random_uniform(30)) }
    ) {
        self.now = now
        self.jitter = jitter
        self.allowedAfter = now()
    }

    /// True while a backoff window is open. The old Obj-C SDK had no gate at
    /// all and hammered the endpoint every timer tick regardless of failures.
    var requestNotAllowed: Bool { now() < allowedAfter }

    mutating func recordSuccess() {
        consecutiveFailures = 0
        allowedAfter = now()
    }

    /// - Parameter retryAfter: server instruction, if any. Always respected as
    ///   a floor even before backoff engages.
    mutating func recordFailure(retryAfter: TimeInterval? = nil) {
        consecutiveFailures += 1

        var wait = retryAfter ?? 0
        if consecutiveFailures >= APIConstants.failuresTillBackoff {
            wait = max(wait, backoff(for: consecutiveFailures))
        }
        allowedAfter = now().addingTimeInterval(wait)
    }

    /// 2^(n-1)·60 + jitter, clamped to the configured window.
    func backoff(for failureCount: Int) -> TimeInterval {
        let raw = pow(2.0, Double(failureCount) - 1) * 60 + jitter()
        return min(max(APIConstants.minRetryBackoff, raw), APIConstants.maxRetryBackoff)
    }

    /// Applies an outcome and reports whether the batch may be deleted.
    /// Deletion is permitted ONLY on success — the single most important
    /// invariant in the delivery path.
    mutating func apply(_ outcome: HTTPOutcome) -> Disposition {
        switch outcome {
        case .success:
            recordSuccess()
            return .deleteBatch
        case .retryable(_, let retryAfter):
            recordFailure(retryAfter: retryAfter)
            return .keepAndRetry
        case .terminal:
            recordFailure()
            // Kept, not deleted: a 401 means the integration is misconfigured,
            // not that the data is bad. Dropping it would lose real events.
            return .keepAndStop
        case .transport:
            recordFailure()
            return .keepAndRetry
        }
    }

    enum Disposition: Equatable {
        /// Server acknowledged. Delete exactly the rows that were sent.
        case deleteBatch
        /// Keep the rows; try again after the backoff window.
        case keepAndRetry
        /// Keep the rows; stop attempting until reconfigured.
        case keepAndStop
    }
}
