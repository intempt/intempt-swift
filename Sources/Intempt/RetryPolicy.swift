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
//    - Extracted as a pure value type, so every branch is provable without IO.
//    - Upstream's exponential backoff, jitter and failure gate are NOT kept
//      (INT-7436, round-2 CONTRACT S1): they kept and resent every non-2xx,
//      which duplicated 500s the server had processed and held batches it had
//      refused for good. One resend for 503/429, then a verdict.
//    - Backup-host failover is deliberately NOT ported: no Intempt backend
//      support for it exists.
//
import Foundation

/// What happens to a batch after a request, per round-2 CONTRACT S1.
///
/// | outcome                                  | verdict                          |
/// |------------------------------------------|----------------------------------|
/// | 2xx                                      | delete (delivered)               |
/// | 503 / 429, first answer                  | one resend after `resendDelay`   |
/// | 503 / 429 again, or any other status     | drop, reported `terminal`        |
/// | sent but unanswered (timeout)            | drop, reported `dropped`         |
/// | never reached the server                 | keep for the next flush          |
enum RetryPolicy {

    enum Disposition: Equatable {
        case deleteBatch
        case keepForNextFlush
        case drop(DeliveryFailure.Kind)
    }

    /// The wait before the single resend, or nil when the outcome is final.
    static func resendDelay(after outcome: HTTPOutcome, isResend: Bool) -> TimeInterval? {
        guard !isResend, case .retryable(let status, let retryAfter) = outcome,
            APIConstants.deliveryResendStatuses.contains(status)
        else { return nil }
        return clampedDelay(retryAfter)
    }

    static func clampedDelay(_ retryAfter: TimeInterval?) -> TimeInterval {
        let requested = retryAfter ?? APIConstants.minResendDelay
        return min(max(requested, APIConstants.minResendDelay), APIConstants.maxResendDelay)
    }

    /// The verdict on a FINAL outcome. A `.retryable` here is a 429/503 whose resend was already
    /// spent, or a status only push and feeds retry (408, 500, 502, 504).
    static func disposition(for outcome: HTTPOutcome) -> Disposition {
        switch outcome {
        case .success: return .deleteBatch
        case .transport: return .keepForNextFlush
        case .unanswered: return .drop(.dropped)
        case .retryable, .terminal: return .drop(.terminal)
        }
    }
}
