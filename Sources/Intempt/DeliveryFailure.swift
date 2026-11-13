import Foundation

/// A batch that did not reach Intempt, reported once on its final outcome (INT-7444, round-2
/// CONTRACT S2). The same shape in every Intempt SDK.
///
/// Delivered to `IntemptInstance.onDeliveryFailure`. `track` and the other recording calls only
/// say whether the event was queued; this is where a delivery problem surfaces.
public struct DeliveryFailure: Sendable, Equatable {

    public enum Kind: String, Sendable, Equatable {
        /// Never reached the server. The batch is KEPT for the next flush, and this is reported
        /// once for it, not on every flush an offline device attempts.
        case transport
        /// The server answered a status that drops the batch, or the one 503/429 resend failed.
        case terminal
        /// Dropped without a server verdict: sent, but never answered.
        case dropped
    }

    public let kind: Kind
    /// The HTTP status, when the server answered.
    public let status: Int?
    public let eventCount: Int
    /// Empty for a consent record, which carries no event id.
    public let eventIds: [String]
    /// Seconds, from the server's `Retry-After`.
    public let retryAfter: TimeInterval?

    /// False only for `transport`: those events are still queued.
    public var terminal: Bool { kind != .transport }
}
