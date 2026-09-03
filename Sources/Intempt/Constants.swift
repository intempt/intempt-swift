//
//  Constants.swift
//  Intempt
//
//  Structure adapted from mixpanel-swift's Constants.swift
//  (https://github.com/mixpanel/mixpanel-swift)
//  Copyright © 2016 Mixpanel. All rights reserved.
//  Licensed under the Apache License, Version 2.0.
//
//  Modifications by Intempt Technologies, Inc. (Apache License 2.0, §4(b)):
//    - All values are Intempt's: endpoints, batch sizing and the event-id
//      prefix come from the verified intemptjs wire contract, not upstream.
//    - Retry/backoff numbers are retained from upstream, which has run them
//      in production for years.
//
import Foundation

enum APIConstants {
    /// Production ingestion host. Every path below is appended to this.
    static let host = "https://api.intempt.com/v1"

    /// Matches intemptjs's RequestBatcher batch size.
    static let maxBatchSize = 50

    /// Seconds between timer-driven flushes.
    static let flushInterval: TimeInterval = 60

    // Retained from upstream — production-proven backoff shape.
    static let minRetryBackoff: TimeInterval = 60
    static let maxRetryBackoff: TimeInterval = 600
    static let failuresTillBackoff = 2

    /// Statuses worth retrying. Everything else non-2xx is terminal —
    /// the old Obj-C SDK treated all of them as success and deleted the batch.
    static let retryableStatuses: Set<Int> = [408, 429, 500, 502, 503, 504]
}

enum QueueConstants {
    /// Hard ceiling on locally-stored events. Beyond this the oldest are
    /// evicted, so an offline device cannot fill the user's disk.
    static let maxQueueSize = 5000
}

enum EventConstants {
    /// intemptjs generates ids as `ev_<uuid>`; ingestion and downstream
    /// dedup rely on that prefix.
    static let eventIdPrefix = "ev_"
}

/// The four endpoints a client SDK talks to, enumerated from every `fetch(`
/// call site in intemptjs. There are no others.
enum Endpoint {
    /// Batched events — identify, group, record, track, product all
    /// funnel here as one mixed-type `{"track":[...]}` envelope.
    case track(org: String, project: String, sourceId: String)
    /// Consent is separate, unbatched and sent immediately.
    case consents(org: String, project: String)
    /// Experiments and personalizations, distinguished by an
    /// `optimizationType` discriminator. Native uses choose-api;
    /// intemptjs uses choose-web because it is web.
    /// Product recommendation feeds.
    case feed(org: String, project: String, feedId: String)

    var path: String {
        switch self {
        case .track(let org, let project, let sourceId):
            return "/\(org)/projects/\(project)/sources/\(sourceId)/track"
        case .consents(let org, let project):
            return "/\(org)/projects/\(project)/consents/data"
        case .feed(let org, let project, let feedId):
            return "/\(org)/projects/\(project)/feeds/\(feedId)/data"
        }
    }

    func url(host: String = APIConstants.host) -> URL? {
        URL(string: host + path)
    }
}
