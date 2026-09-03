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
    /// Gateway root. Webhook routes are registered directly under it, with no
    /// version segment — `PushSourceDataRoutes.java` lists
    /// `/webhooks/events/push-notification` alongside `/v1/{orgName}/...`, so
    /// the two families genuinely differ by more than a path.
    static let rootHost = "https://api.intempt.com"

    /// Production ingestion host. Every versioned path below is appended to this.
    static let host = rootHost + "/v1"

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

/// Every endpoint a client SDK talks to: the four ingestion routes enumerated
/// from intemptjs's `fetch(` call sites, plus the push webhook the Android SDK
/// already posts to.
enum Endpoint {
    /// Batched events — identify, group, record, track, product all
    /// funnel here as one mixed-type `{"track":[...]}` envelope.
    case track(org: String, project: String, sourceId: String, useIPForGeolocation: Bool)
    /// Consent is separate, unbatched and sent immediately.
    case consents(org: String, project: String)
    /// Flags, experiments and personalizations, read by key.
    ///
    /// A native SDK runs on a device and is still an `api`-channel consumer, because there is no
    /// visual editor for a native surface: the value is authored as a payload and the integrator
    /// writes the branch. `choose-web` is intemptjs alone, where a change is applied against the
    /// DOM and the caller never branches.
    case chooseApi(org: String, project: String)
    /// Product recommendation feeds.
    case feed(org: String, project: String, feedId: String)
    /// Push delivery, bounce and open reports.
    ///
    /// Org and project are not in the path: they travel in the body, because
    /// the ids come from the notification's own payload rather than from the
    /// SDK's configuration. A notification service extension reporting a
    /// delivery has the payload and may not have an initialised instance.
    case pushNotificationWebhook

    var path: String {
        switch self {
        case .track(let org, let project, let sourceId, let useIPForGeolocation):
            // `?ip=1` lets Intempt derive country, region and city from the address the request
            // already arrives on; `?ip=0` asks it not to. The device never handles its own address
            // and no third party is involved. Copied from mixpanel-swift's
            // `useIPAddressForGeolocation`, so a customer migrating does not have to look it up.
            return "/\(org)/projects/\(project)/sources/\(sourceId)/track?ip="
                + (useIPForGeolocation ? "1" : "0")
        case .consents(let org, let project):
            return "/\(org)/projects/\(project)/consents/data"
        case .chooseApi(let org, let project):
            return "/\(org)/projects/\(project)/optimization/choose-api"
        case .feed(let org, let project, let feedId):
            return "/\(org)/projects/\(project)/feeds/\(feedId)/data"
        case .pushNotificationWebhook:
            return "/webhooks/events/push-notification"
        }
    }

    /// `/v1` for the ingestion routes, nothing for the webhook.
    ///
    /// Kept apart from `path` so `path` stays the org/project-scoped string the
    /// wire tests already assert, and so the difference is a value a test can
    /// read rather than a string two call sites have to remember to concatenate
    /// differently.
    var versionPrefix: String {
        switch self {
        case .pushNotificationWebhook: return ""
        case .track, .consents, .chooseApi, .feed: return "/v1"
        }
    }

    func url(host: String = APIConstants.rootHost) -> URL? {
        URL(string: host + versionPrefix + path)
    }
}
