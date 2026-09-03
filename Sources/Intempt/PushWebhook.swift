//
//  PushWebhook.swift
//  Intempt
//
//  Copyright © 2026 Intempt Technologies, Inc.
//  Licensed under the Apache License, Version 2.0.
//
//  No mixpanel-swift equivalent: Mixpanel removed push from its Android SDK in
//  v6.0.0 and never shipped it on Apple, so there is nothing upstream to adapt.
//
//  The wire contract is the Android SDK's, verified end to end rather than
//  designed here:
//
//    android-sdk  push/.../PushNotificationWebhookRequest.kt   the eleven body fields
//    android-sdk  core/.../ConfigManagerService.kt:164          POST {root}/webhooks/events/push-notification
//    gateway      PushSourceDataRoutes.java:35        route -> lb://push-source-intempt-com
//    push-source  PushNotificationEventHandler        binds PushNotificationEvent
//    push-source  PushNotificationEventService        status -> Type -> Kafka WebhookGeneratedEvent
//
//  Two things differ from Android and both are deliberate.
//
//  `destinationType` and `subject` are "apns", the string both backends already
//  use for Apple (destinations-processor DestinationTypes.APNS,
//  single-metadata RSocketConnectorName.APNS). Android sends
//  "firebase_cloud_messaging" in the same two fields.
//
//  The metadata arrives as a nested JSON OBJECT, not a string. Firebase carries
//  flat string `data` entries so Android parses `data["metadata"]` out of a
//  string; APNs carries real JSON and PushNotificationHandler.createApnsPayload:352
//  sets `root.set("metadata", ...)`. Both shapes are accepted here, because a
//  notification service extension may hand on either.
//
import Foundation

#if canImport(UserNotifications)
    import UserNotifications
#endif

/// The three outcomes the push webhook records.
///
/// Raw values are the server's own `PushNotificationEvent.Type.receivedType`.
/// `PushNotificationEventService` matches the request's `status` against them
/// and silently records NOTHING when nothing matches, so a typo here is a
/// report that vanishes with a 200.
enum PushWebhookStatus: String, CaseIterable {
    case delivered
    case bounced
    case opened
}

/// The eight identifiers a send stamps into its notification so a report can be
/// attributed back to the campaign that produced it.
///
/// Every field is required. A report missing one cannot be joined to a send, and
/// the server declares all eight `@NotNull`, so a partial report is rejected
/// after the request has already been made.
struct PushMetadata: Equatable {

    let orgId: String
    let projectId: String
    let transformerId: String
    let pipelineId: String
    let destinationId: String
    let masterId: String
    let accountId: String
    let templateId: String

    /// Order is the server's field order, not alphabetical, so a diff against
    /// `PushNotificationEvent.java` reads straight down.
    static let requiredKeys = [
        "orgId", "projectId", "destinationId", "masterId",
        "accountId", "pipelineId", "transformerId", "templateId",
    ]

    /// Reads the `metadata` entry of an APNs payload.
    ///
    /// Returns nil rather than a half-filled value: an unattributable report is
    /// worse than no report, because it lands in the campaign's numbers without
    /// belonging to any campaign.
    init?(userInfo: [AnyHashable: Any]) {
        guard let fields = Self.metadataFields(in: userInfo) else { return nil }

        var read: [String: String] = [:]
        for key in Self.requiredKeys {
            guard let value = Self.scalar(fields[key]), !value.isEmpty else { return nil }
            read[key] = value
        }

        orgId = read["orgId"]!
        projectId = read["projectId"]!
        destinationId = read["destinationId"]!
        masterId = read["masterId"]!
        accountId = read["accountId"]!
        pipelineId = read["pipelineId"]!
        transformerId = read["transformerId"]!
        templateId = read["templateId"]!
    }

    /// Accepts the APNs object form and the Firebase string form.
    static func metadataFields(in userInfo: [AnyHashable: Any]) -> [String: Any]? {
        guard let raw = userInfo["metadata"] else { return nil }

        if let object = raw as? [String: Any] { return object }

        if let string = raw as? String {
            return JSONHandler.deserializeData(Data(string.utf8)) as? [String: Any]
        }
        return nil
    }

    /// Ids cross the wire as JSON numbers from APNs and as strings from
    /// Firebase. The server's `LongFromStringDeserializer` takes either, so both
    /// are read and both are emitted as strings.
    ///
    /// A boolean is rejected outright. `CFBoolean` bridges to `NSNumber`, so an
    /// unguarded `NSNumber` branch turns `true` into the id "1".
    static func scalar(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            return string
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
            return number.stringValue
        default:
            return nil
        }
    }
}

/// Builds the request body the push-source service binds to.
enum PushWebhookBody {

    /// Apple's provider string, matching `DestinationTypes.APNS` and
    /// `RSocketConnectorName.APNS`.
    static let destinationType = "apns"

    /// The eleven fields of `PushNotificationEvent`.
    ///
    /// `type` is not sent. The server declares it `@JsonIgnore` and derives it
    /// from `status`, so sending it is decoration that can disagree with the
    /// field that actually decides the outcome.
    ///
    /// `subject` repeats the provider rather than carrying the notification's
    /// title. Android does the same with "firebase_cloud_messaging", and a
    /// campaign whose Android rows say one thing and whose iOS rows say another
    /// cannot be read as one report.
    static func make(metadata: PushMetadata, status: PushWebhookStatus) -> [String: Any] {
        [
            "orgId": metadata.orgId,
            "projectId": metadata.projectId,
            "destinationId": metadata.destinationId,
            "masterId": metadata.masterId,
            "accountId": metadata.accountId,
            "pipelineId": metadata.pipelineId,
            "transformerId": metadata.transformerId,
            "templateId": metadata.templateId,
            "subject": destinationType,
            "destinationType": destinationType,
            "status": status.rawValue,
        ]
    }
}

/// Posts one report, retrying a transient failure a bounded number of times.
///
/// Not fire-and-forget, and not durable either. The Android SDK settled this:
/// `WebhookService.kt` retries four times with a doubling delay because
/// "journeys branch on these — a dropped DELIVERED makes a journey believe the
/// push never arrived and send the wrong follow-up to a real person". That is
/// a worse outcome than a lost analytics event, and it is the same webhook.
///
/// Bounded and in-process rather than routed through the durable event queue,
/// for the reason Android gives: the queue posts a different body to a different
/// endpoint, and a second persistence layer is a large thing to add for three
/// reports. A retry that outlives the process would also never run — iOS
/// suspends the app, and a notification service extension, within seconds.
///
/// Only a retryable outcome is retried. A 400 means the body is wrong and will
/// be wrong again; repeating it wastes the little wall-clock the process has.
final class PushWebhookSender {

    static let maxAttempts = 4
    static let initialRetryDelay: TimeInterval = 1

    private let network: Network
    private let credentials: IntemptCredentials
    private let scheduler: (TimeInterval, @escaping () -> Void) -> Void

    /// - Parameter scheduler: how a retry is deferred. Replaced in tests so the
    ///   backoff is exercised without spending seven real seconds sleeping.
    init(
        network: Network,
        credentials: IntemptCredentials,
        scheduler: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay, execute: work)
        }
    ) {
        self.network = network
        self.credentials = credentials
        self.scheduler = scheduler
    }

    /// - Returns: whether a request was made. False means the payload carried no
    ///   usable metadata, which is the normal answer for a notification Intempt
    ///   did not send.
    @discardableResult
    func report(
        _ status: PushWebhookStatus,
        userInfo: [AnyHashable: Any],
        completion: ((HTTPOutcome) -> Void)? = nil
    ) -> Bool {
        guard let metadata = PushMetadata(userInfo: userInfo) else {
            IntemptLogger.shared.log(
                .debug,
                "push \(status.rawValue) not reported: the notification carries no Intempt "
                    + "metadata, so it is not one of ours")
            return false
        }
        return report(status, metadata: metadata, completion: completion)
    }

    @discardableResult
    func report(
        _ status: PushWebhookStatus,
        metadata: PushMetadata,
        completion: ((HTTPOutcome) -> Void)? = nil
    ) -> Bool {
        let request: URLRequest
        do {
            request = try network.makeRequest(
                endpoint: .pushNotificationWebhook,
                credentials: credentials,
                body: PushWebhookBody.make(metadata: metadata, status: status))
        } catch {
            IntemptLogger.shared.log(.error, "push \(status.rawValue) not reported: \(error)")
            return false
        }

        attempt(request, status: status, number: 1, delay: Self.initialRetryDelay, completion: completion)
        return true
    }

    private func attempt(
        _ request: URLRequest,
        status: PushWebhookStatus,
        number: Int,
        delay: TimeInterval,
        completion: ((HTTPOutcome) -> Void)?
    ) {
        network.send(request) { [weak self] outcome in
            guard let self else {
                completion?(outcome)
                return
            }
            guard !outcome.isSuccess else {
                completion?(outcome)
                return
            }
            guard Self.isWorthRetrying(outcome), number < Self.maxAttempts else {
                IntemptLogger.shared.log(
                    .warning,
                    "push \(status.rawValue) report failed after \(number) "
                        + "attempt\(number == 1 ? "" : "s"): \(outcome). A journey branching on "
                        + "this signal will not see it.")
                completion?(outcome)
                return
            }

            self.scheduler(delay) {
                self.attempt(
                    request, status: status, number: number + 1,
                    delay: delay * 2, completion: completion)
            }
        }
    }

    /// A rejection is not retried.
    ///
    /// `.terminal` is 400/401/403/422 — a malformed body or a bad key, identical
    /// on the next attempt. `Network.classify` has already separated those from
    /// the statuses worth repeating.
    static func isWorthRetrying(_ outcome: HTTPOutcome) -> Bool {
        switch outcome {
        case .retryable, .transport: return true
        case .success, .terminal: return false
        }
    }
}

/// Whether the system will actually put a notification on screen.
///
/// This is the iOS half of Android's bounce check. `FirebaseService.notifySafely`
/// tests `POST_NOTIFICATIONS` before rendering and reports BOUNCED when it is
/// denied; iOS never renders the notification itself, so the equivalent question
/// is whether authorization was granted at the moment the payload arrived.
///
/// It is a stored closure rather than a direct call so it can be replaced in
/// tests. `UNUserNotificationCenter.current()` raises when the process has no
/// bundle identifier, which is exactly the case under `swift test`.
enum PushAuthorization {

    /// Replaced in tests. Called on an arbitrary queue and answers on one too.
    static var probe: (@escaping (Bool) -> Void) -> Void = defaultProbe

    static func reset() {
        probe = defaultProbe
    }

    /// Assumes displayable when it cannot ask.
    ///
    /// The alternative is to report every push from an unbundled or unsupported
    /// process as bounced, which would invent failures rather than observe them.
    static func defaultProbe(_ completion: @escaping (Bool) -> Void) {
        #if canImport(UserNotifications)
            guard Bundle.main.bundleIdentifier != nil else { return completion(true) }
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                completion(settings.authorizationStatus != .denied)
            }
        #else
            completion(true)
        #endif
    }
}
