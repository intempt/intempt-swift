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
//       here the first retryable failure stops the pass and the backoff window
//       decides when to try again.
//
//    5. CONSENT GOES FIRST, ON ITS OWN ENDPOINT. A withdrawal reaching the
//       server matters more than analytics throughput. A *terminal* consent
//       failure does not block events, though — a consent-specific
//       misconfiguration must not strand every event in the queue.
//
//    6. NO GZIP. Upstream compresses. Verified against production: the
//       endpoint returns HTTP 400 for `Content-Encoding: gzip`
//       (docs/CONTRACT.md), so porting that path would fail every request.
//
import Foundation

/// Drives delivery: claims batches, sends them, and applies the disposition
/// `RetryPolicy` decides.
final class Flush {

    private let db: IntemptDB
    private let network: Network
    private let credentials: IntemptCredentials
    private let trackEndpoint: Endpoint
    private let consentEndpoint: Endpoint

    /// Sole owner of `policy`, `inFlight` and `waiters`. Every private method
    /// below must be called on it, and every completion is invoked on it.
    private let queue = DispatchQueue(label: "com.intempt.flush", qos: .utility)
    private var policy: RetryPolicy
    private var inFlight = false
    private var waiters: [(Int) -> Void] = []

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
        policy: RetryPolicy = RetryPolicy()
    ) {
        self.db = db
        self.network = network
        self.credentials = credentials
        self.trackEndpoint = .track(org: orgId, project: projectId, sourceId: sourceId)
        self.consentEndpoint = .consents(org: orgId, project: projectId)
        self.policy = policy

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

    /// Sends everything queued, oldest first, stopping at the first retryable
    /// failure or when the backoff window is closed.
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
        guard !policy.requestNotAllowed else { return done(sent) }

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

        network.send(request) { [weak self] outcome in
            guard let self else { return }
            self.queue.async {
                switch self.policy.apply(outcome) {
                case .deleteBatch:
                    self.db.delete(.events, ids: goodIds)
                    self.strikes.removeValue(forKey: goodIds[0])
                    self.drainEvents(sent: sent + goodIds.count, done: done)

                case .keepAndRetry:
                    // Modifications 1 and 4: release the claim so the rows are
                    // visible to the next pass, and stop rather than hammer.
                    self.db.setFlag(.events, ids: goodIds, to: false)
                    self.strikes.removeValue(forKey: goodIds[0])
                    done(sent)

                case .keepAndStop:
                    self.db.setFlag(.events, ids: goodIds, to: false)
                    self.recordTerminal(outcome, ids: goodIds)
                    done(sent)
                }
            }
        }
    }

    /// Consecutive terminal rejections for the batch starting at a given row id.
    private var strikes: [Int32: Int] = [:]

    /// Statuses that mean "these bytes will never be accepted" as opposed to
    /// "your credentials are wrong". A misconfigured key must never cost data;
    /// a permanently malformed batch must never block the queue forever.
    private static let payloadRejections: Set<Int> = [400, 413, 422]

    /// How many terminal rejections a batch may take before it is discarded.
    private static let maxStrikes = 3

    /// Decides whether a terminally-rejected batch should be dropped.
    ///
    /// Without this a batch the server will never accept sits at the head of
    /// the queue and fails every flush forever, blocking every event behind it
    /// — the same shape as the poison-row problem, one level up. Neither
    /// upstream nor the old Obj-C SDK has any notion of it.
    ///
    /// 401 and 403 are deliberately exempt: those mean the integration is
    /// misconfigured, the data is fine, and dropping it would destroy real
    /// events over a fixable mistake.
    ///
    /// Three strikes rather than one because production has been observed
    /// returning a transient 400 to a payload it accepts on the next attempt
    /// (docs/CONTRACT.md).
    private func recordTerminal(_ outcome: HTTPOutcome, ids: [Int32]) {
        guard case .terminal(let status, let body) = outcome,
            Self.payloadRejections.contains(status),
            let head = ids.first
        else { return }

        let count = (strikes[head] ?? 0) + 1
        strikes[head] = count

        guard count >= Self.maxStrikes else {
            IntemptLogger.shared.log(
                .warning,
                "batch rejected with \(status) (attempt \(count)/\(Self.maxStrikes)); keeping")
            return
        }

        let detail = IntemptError.serverMessages(from: body)?.joined(separator: "; ")
            ?? "no message"
        IntemptLogger.shared.log(
            .error,
            "dropping \(ids.count) event(s) after \(count) rejections with \(status): \(detail). "
                + "These events will never be accepted; keeping them would block the queue.")
        db.delete(.events, ids: ids)
        strikes.removeValue(forKey: head)
    }

    // MARK: - Consents

    /// One request per consent record — the endpoint takes a flat body, not a
    /// batch. Must be called on `queue`; `done` is invoked on `queue`.
    private func drainConsents(done: @escaping () -> Void) {
        guard !policy.requestNotAllowed else { return done() }

        let rows = db.read(.consents, limit: 1, flag: false)
        guard let row = rows.first else { return done() }

        guard let body = JSONHandler.deserializeData(row.data) as? [String: Any] else {
            IntemptLogger.shared.log(.warning, "dropping undecodable consent record")
            db.delete(.consents, ids: [row.id])
            return drainConsents(done: done)
        }

        let request: URLRequest
        do {
            request = try network.makeRequest(
                endpoint: consentEndpoint, credentials: credentials, body: body)
        } catch {
            IntemptLogger.shared.log(.error, "dropping unsendable consent record: \(error)")
            db.delete(.consents, ids: [row.id])
            return drainConsents(done: done)
        }

        db.setFlag(.consents, ids: [row.id], to: true)

        network.send(request) { [weak self] outcome in
            guard let self else { return }
            self.queue.async {
                switch self.policy.apply(outcome) {
                case .deleteBatch:
                    self.db.delete(.consents, ids: [row.id])
                    self.drainConsents(done: done)

                case .keepAndRetry:
                    // Server-side or transport trouble: events would fail too.
                    self.db.setFlag(.consents, ids: [row.id], to: false)
                    done()

                case .keepAndStop:
                    // Modification 5: a terminal consent failure is specific to
                    // consent. Keep the record, but let events proceed rather
                    // than stranding the entire queue behind it.
                    self.db.setFlag(.consents, ids: [row.id], to: false)
                    done()
                }
            }
        }
    }

    // MARK: - Test seams

    var consecutiveFailures: Int { queue.sync { policy.consecutiveFailures } }
    /// Test seam. Also the reason success clears its entry: ids are never
    /// reused (the table is AUTOINCREMENT), so an entry left behind after a
    /// batch is deleted can never match again and would accumulate for the life
    /// of the process.
    var trackedStrikeCount: Int { queue.sync { strikes.count } }
    /// Reads the intent flag, not the `Timer` — see `startTimer`.
    var isTimerRunning: Bool { timerLock.read { armed } }
}
