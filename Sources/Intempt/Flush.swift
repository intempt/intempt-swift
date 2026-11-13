//
//  Flush.swift
//  Intempt
//
//  Adapted from mixpanel-swift's Flush.swift
//  (https://github.com/mixpanel/mixpanel-swift)
//  Copyright © 2016 Mixpanel. All rights reserved.
//  Licensed under the Apache License, Version 2.0.
//
//  Modifications by Intempt Technologies, Inc. (Apache License 2.0, §4(b)):
//
//    1. CLAIM / RELEASE, NOT MARK-AND-HOPE. A batch is claimed (flag=1) before
//       the POST so a concurrent flush cannot pick up the same rows, and the
//       claim is RELEASED on failure. Rows are deleted only after the server
//       acknowledges them. The old Obj-C SDK marked rows sent before the POST
//       and then blanket-deleted on any success, destroying sibling batches.
//
//    2. STALE CLAIMS ARE RECOVERED AT STARTUP. A crash mid-flight leaves rows
//       flagged, and a flagged row is invisible to the reader forever. Upstream
//       never releases them, so one crash strands those events permanently.
//
//    3. POISON ROWS ARE DROPPED. An undecodable blob at the head of the queue
//       fails its batch on every attempt, blocking all delivery behind it
//       forever. Undecodable rows are deleted and the drain continues.
//
//    4. ONE FAILURE ENDS THE DRAIN. Upstream keeps walking batches after a
//       failure. Against a server that is down that is 100 pointless requests;
//       here the first failed batch stops the pass and the next flush resumes.
//
//    5. CONSENT GOES FIRST, ON ITS OWN ENDPOINT. A withdrawal reaching the
//       server matters more than analytics throughput. A failed consent does
//       not block events, though: they drain after it either way.
//
//    6. NO GZIP. Upstream compresses. Verified against production: the
//       endpoint returns HTTP 400 for `Content-Encoding: gzip`
//       (docs/CONTRACT.md), so porting that path would fail every request.
//
//    7. ONE RESEND, THEN A VERDICT (INT-7436). Upstream keeps and retries
//       every non-2xx with exponential backoff. Here 503/429 get one resend
//       after Retry-After, every other answer drops the batch, and only a
//       request that never reached the server is kept (`RetryPolicy`). Each
//       final failure is reported once through `onDeliveryFailure` (INT-7444).
//
import Foundation

/// Drives delivery: claims batches, sends them, and applies the disposition
/// `RetryPolicy` decides.
final class Flush {

    private let db: IntemptDB
    private let network: Network
    private let credentials: IntemptCredentials
    /// The endpoint every batch is posted to, carrying the geolocation flag as `?ip=`.
    ///
    /// Not private: the flag reaches the wire through this and nothing else, so a test asserting
    /// on the instance property proves only that the property was set. Hardcoding the argument
    /// that feeds this left all 311 tests green while every request carried `?ip=1`.
    let trackEndpoint: Endpoint
    private let consentEndpoint: Endpoint

    /// Sole owner of `inFlight`, `waiters` and the two `transportReported` sets.
    /// Every private method below must be called on it, and every completion is
    /// invoked on it.
    private let queue = DispatchQueue(label: "com.intempt.flush", qos: .utility)
    private var inFlight = false
    private var waiters: [(Int) -> Void] = []

    /// Defers the one 503/429 resend. Injected so a test does not spend a real
    /// Retry-After of up to 60 s; the work it runs hops back onto `queue`.
    private let resendScheduler: (TimeInterval, @escaping () -> Void) -> Void

    /// Head row ids of kept batches (and consent row ids) whose transport
    /// failure was already reported. S2 reports it once per batch: an offline
    /// device would otherwise report the same batch on every flush.
    private var transportReported: Set<Int32> = []
    private var consentTransportReported: Set<Int32> = []

    private let listenerLock = ReadWriteLock(label: "com.intempt.flush.listener")
    private var _onDeliveryFailure: ((DeliveryFailure) -> Void)?

    /// Called on this class's delivery queue, once per batch, on its final
    /// outcome. See `IntemptInstance.onDeliveryFailure`.
    var onDeliveryFailure: ((DeliveryFailure) -> Void)? {
        get { listenerLock.read { _onDeliveryFailure } }
        set { listenerLock.write { _onDeliveryFailure = newValue } }
    }

    /// Only ever touched on the main thread — a `Timer` must be invalidated on
    /// the run loop that scheduled it.
    private var timer: Timer?
    /// The intent, readable from any thread. Separate from `timer` because
    /// answering "is it running?" must never require hopping to main.
    private let timerLock = ReadWriteLock(label: "com.intempt.flush.timer")
    private var armed = false

    /// Seconds between automatic flushes. 0 disables the timer. Assigning while
    /// the timer is running re-arms it rather than leaving the old interval.
    var flushInterval: TimeInterval = APIConstants.flushInterval {
        didSet {
            guard oldValue != flushInterval, isTimerRunning else { return }
            startTimer()
        }
    }

    init(
        db: IntemptDB,
        network: Network,
        credentials: IntemptCredentials,
        orgId: String,
        projectId: String,
        sourceId: String,
        useIPAddressForGeolocation: Bool = true,
        resendScheduler: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay, execute: work)
        }
    ) {
        self.db = db
        self.network = network
        self.credentials = credentials
        self.trackEndpoint = .track(
            org: orgId, project: projectId, sourceId: sourceId,
            useIPForGeolocation: useIPAddressForGeolocation)
        self.consentEndpoint = .consents(org: orgId, project: projectId)
        self.resendScheduler = resendScheduler

        // Modification 2: recover anything a previous process left claimed.
        db.releaseAllClaims(.events)
        db.releaseAllClaims(.consents)
    }

    deinit {
        // No hop to main: deinit may already be on it, and the timer holds no
        // strong reference back to self (the closure is [weak self]).
        timer?.invalidate()
    }

    // MARK: - Timer

    /// Arms the repeating flush timer on the main run loop.
    ///
    /// Every hop to main is `async`, never `sync`. `initialize` may be called
    /// from a background queue while the main thread waits on that work — a
    /// `DispatchQueue.main.sync` here deadlocks the app on launch. The existing
    /// concurrent-initialize test caught exactly that.
    func startTimer() {
        let interval = flushInterval
        timerLock.write { armed = interval > 0 }
        guard interval > 0 else { return stopTimer() }

        onMain { [weak self] in
            guard let self else { return }
            self.timer?.invalidate()
            // Re-check: a stopTimer() queued behind this one would otherwise be
            // undone by an arm that was already in flight.
            guard self.timerLock.read({ self.armed }) else {
                self.timer = nil
                return
            }
            let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
                guard let self, self.timerLock.read({ self.armed }) else { return }
                self.flushNow()
            }
            // .common, not .default: a scroll or a modal presentation puts the
            // main run loop into tracking mode, and a .default-mode timer stops
            // firing for as long as the user's finger is down.
            RunLoop.main.add(t, forMode: .common)
            self.timer = t
        }
    }

    func stopTimer() {
        timerLock.write { armed = false }
        onMain { [weak self] in
            self?.timer?.invalidate()
            self?.timer = nil
        }
    }

    /// Runs `work` on the main thread, inline when already there.
    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    // MARK: - Entry point

    /// Sends everything queued, oldest first, stopping at the first batch that
    /// fails.
    ///
    /// - Parameter completion: receives the number of **events** delivered.
    ///   Overlapping calls coalesce: the second caller's completion fires with
    ///   the first pass's result rather than starting a parallel drain.
    func flushNow(completion: ((Int) -> Void)? = nil) {
        queue.async {
            if self.inFlight {
                if let completion { self.waiters.append(completion) }
                return
            }
            self.inFlight = true

            self.drainConsents {
                self.drainEvents(sent: 0) { total in
                    self.inFlight = false
                    let pending = self.waiters
                    self.waiters = []
                    completion?(total)
                    pending.forEach { $0(total) }
                }
            }
        }
    }

    // MARK: - Events

    /// Recursive one-batch-at-a-time drain. Must be called on `queue`;
    /// `done` is invoked on `queue`.
    private func drainEvents(sent: Int, done: @escaping (Int) -> Void) {
        let rows = db.read(.events, limit: APIConstants.maxBatchSize, flag: false)
        guard !rows.isEmpty else { return done(sent) }

        // Modification 3: separate the decodable from the poison.
        var entries: [[String: Any]] = []
        var goodIds: [Int32] = []
        var poisonIds: [Int32] = []
        for row in rows {
            if let entry = JSONHandler.deserializeData(row.data) as? [String: Any] {
                entries.append(entry)
                goodIds.append(row.id)
            } else {
                poisonIds.append(row.id)
            }
        }
        if !poisonIds.isEmpty {
            IntemptLogger.shared.log(
                .warning, "dropping \(poisonIds.count) undecodable event(s) from the queue")
            db.delete(.events, ids: poisonIds)
        }
        guard !entries.isEmpty else {
            // The whole batch was poison. Continue — the next read sees fresh rows.
            return drainEvents(sent: sent, done: done)
        }

        let request: URLRequest
        do {
            request = try network.makeRequest(
                endpoint: trackEndpoint,
                credentials: credentials,
                body: TrackEnvelope.wrap(entries))
        } catch {
            // Cannot be built, so it can never be sent. Dropping avoids an
            // infinite retry on rows that will never serialise.
            IntemptLogger.shared.log(.error, "dropping unsendable batch: \(error)")
            db.delete(.events, ids: goodIds)
            return drainEvents(sent: sent, done: done)
        }

        // Modification 1: claim before the POST, never mark as sent.
        db.setFlag(.events, ids: goodIds, to: true)

        // The id lives in the payload item, not on the entry (`toEnvelopeEntry`).
        let eventIds = entries.compactMap {
            ($0["payload"] as? [[String: Any]])?.first?["eventId"] as? String
        }
        let head = goodIds[0]

        deliver(request) { outcome in
            switch RetryPolicy.disposition(for: outcome) {
            case .deleteBatch:
                self.db.delete(.events, ids: goodIds)
                self.transportReported.remove(head)
                self.drainEvents(sent: sent + goodIds.count, done: done)

            case .keepForNextFlush:
                // Modifications 1 and 4: release the claim so the rows are
                // visible to the next pass, and stop rather than hammer.
                self.db.setFlag(.events, ids: goodIds, to: false)
                if self.transportReported.insert(head).inserted {
                    self.report(
                        .transport, outcome: outcome, eventCount: goodIds.count, eventIds: eventIds)
                }
                done(sent)

            case .drop(let kind):
                self.db.delete(.events, ids: goodIds)
                self.transportReported.remove(head)
                self.report(kind, outcome: outcome, eventCount: goodIds.count, eventIds: eventIds)
                done(sent)
            }
        }
    }

    /// Sends `request` and, for a first 503/429 only, once more after the
    /// clamped Retry-After. The claim stays held through the wait, so no other
    /// pass can pick the rows up. `done` receives the final outcome, on `queue`.
    private func deliver(
        _ request: URLRequest,
        isResend: Bool = false,
        done: @escaping (HTTPOutcome) -> Void
    ) {
        network.send(request) { [weak self] outcome in
            guard let self else { return }
            self.queue.async {
                guard let delay = RetryPolicy.resendDelay(after: outcome, isResend: isResend)
                else { return done(outcome) }
                self.resendScheduler(delay) { [weak self] in
                    guard let self else { return }
                    self.queue.async { self.deliver(request, isResend: true, done: done) }
                }
            }
        }
    }

    /// Logs and hands one final failure to the listener. Must be called on `queue`.
    private func report(
        _ kind: DeliveryFailure.Kind,
        outcome: HTTPOutcome,
        eventCount: Int,
        eventIds: [String]
    ) {
        var status: Int?
        var retryAfter: TimeInterval?
        var detail = ""
        switch outcome {
        case .retryable(let s, let after):
            status = s
            retryAfter = after
        case .terminal(let s, let body):
            status = s
            detail = IntemptError.serverMessages(from: body).map { ": " + $0.joined(separator: "; ") } ?? ""
        case .transport(let description), .unanswered(let description):
            detail = ": " + description
        case .success:
            break
        }

        let what = status.map { "\(kind.rawValue) \($0)" } ?? kind.rawValue
        if kind == .transport {
            IntemptLogger.shared.log(
                .warning, "\(eventCount) event(s) not delivered (\(what)\(detail)); kept for the next flush")
        } else {
            IntemptLogger.shared.log(
                .error, "dropping \(eventCount) event(s) (\(what)\(detail)); they will not be resent")
        }

        onDeliveryFailure?(
            DeliveryFailure(
                kind: kind, status: status, eventCount: eventCount, eventIds: eventIds,
                retryAfter: retryAfter))
    }

    // MARK: - Consents

    /// One request per consent record — the endpoint takes a flat body, not a
    /// batch. Must be called on `queue`; `done` is invoked on `queue`.
    private func drainConsents(done: @escaping () -> Void) {
        let rows = db.read(.consents, limit: 1, flag: false)
        guard let row = rows.first else { return done() }

        if let inserted = db.insertedAt(.consents, id: row.id),
            Date().timeIntervalSince(inserted) > QueueConstants.consentMaxAge
        {
            db.delete(.consents, ids: [row.id])
            consentTransportReported.remove(row.id)
            reportConsentDropped(
                "undelivered for over \(Int(QueueConstants.consentMaxAge / 86_400)) days")
            return drainConsents(done: done)
        }

        guard let body = JSONHandler.deserializeData(row.data) as? [String: Any] else {
            db.delete(.consents, ids: [row.id])
            reportConsentDropped("undecodable")
            return drainConsents(done: done)
        }

        let request: URLRequest
        do {
            request = try network.makeRequest(
                endpoint: consentEndpoint, credentials: credentials, body: body)
        } catch {
            db.delete(.consents, ids: [row.id])
            reportConsentDropped("unsendable: \(error)")
            return drainConsents(done: done)
        }

        db.setFlag(.consents, ids: [row.id], to: true)

        deliver(request) { outcome in
            switch RetryPolicy.disposition(for: outcome) {
            case .deleteBatch:
                self.db.delete(.consents, ids: [row.id])
                self.consentTransportReported.remove(row.id)
                self.drainConsents(done: done)

            case .keepForNextFlush:
                self.db.setFlag(.consents, ids: [row.id], to: false)
                if self.consentTransportReported.insert(row.id).inserted {
                    self.report(.transport, outcome: outcome, eventCount: 1, eventIds: [])
                }
                done()

            case .drop(let kind):
                // Consents follow the same table as events (CONTRACT S1). Dropping
                // also unblocks every consent queued behind this one, a later
                // withdrawal included.
                self.db.delete(.consents, ids: [row.id])
                self.consentTransportReported.remove(row.id)
                self.report(kind, outcome: outcome, eventCount: 1, eventIds: [])
                done()
            }
        }
    }

    /// A consent dropped before any request is still a failed consent, so it reaches the listener
    /// like one the server refused (ruling R2: reported, never silent). Must be called on `queue`.
    private func reportConsentDropped(_ reason: String) {
        IntemptLogger.shared.log(.error, "dropping consent record (\(reason)); it will not be sent")
        onDeliveryFailure?(
            DeliveryFailure(kind: .dropped, status: nil, eventCount: 1, eventIds: [], retryAfter: nil))
    }

    // MARK: - Test seams

    /// Test seam. Also the reason delivery and drop clear their entry: ids are
    /// never reused (the table is AUTOINCREMENT), so an entry left behind after
    /// its rows are deleted can never match again and would accumulate for the
    /// life of the process.
    var trackedTransportReportCount: Int {
        queue.sync { transportReported.count + consentTransportReported.count }
    }
    /// Reads the intent flag, not the `Timer` — see `startTimer`.
    var isTimerRunning: Bool { timerLock.read { armed } }
}
