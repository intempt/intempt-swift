//
//  AutomaticEvents.swift
//  Intempt
//
//  Adapted from mixpanel-swift's AutomaticEvents.swift
//  (https://github.com/mixpanel/mixpanel-swift)
//  Copyright © 2016 Mixpanel. All rights reserved.
//  Licensed under the Apache License, Version 2.0.
//
//  Modifications by Intempt Technologies, Inc. (Apache License 2.0, §4(b)):
//
//    1. INTEMPTJS EVENT NAMES AND SHAPE. Session start is "Session start"
//       carrying device facts as `userAttributes`, matching
//       sessionTracker.module.ts. Upstream's `$ae_session` / `$ae_first_open`
//       names mean nothing to Intempt reporting.
//
//    2. NO IN-APP PURCHASE TRACKING. Upstream observes SKPaymentQueue and emits
//       `$ae_iap`. That links StoreKit into every embedding app, and Intempt's
//       commerce model is the explicit product* calls, not App Store receipts.
//
//    3. VERSION STATE IS NAMESPACED PER INSTANCE. Upstream keys its
//       first-open/update flags globally, so two instances in one app each
//       believe they saw the install.
//
//    4. SESSION ROLL IS DRIVEN BY IdentityManager, NOT A SECOND TIMER.
//       Upstream tracks session length with its own timestamps in parallel with
//       its identity state; two clocks for one concept drift apart. Here the
//       session id and the session-start event come from the same source.
//
import Foundation

/// Emits lifecycle events. Owned by `IntemptInstance`; every emission goes
/// through the instance's normal `enqueue` path, so opt-out and validation
/// apply exactly as they do to a manual `track`.
final class AutomaticEvents {

    /// What the tracker is allowed to emit. All default OFF except session
    /// start, matching upstream's `trackAutomaticEvents` default of false —
    /// an SDK that starts writing events the integrator did not ask for is how
    /// event volume bills surprise people.
    struct Options {
        /// "Session start" with device facts as userAttributes.
        var sessions = true
        /// Installed / Updated, once per version.
        var versionChanges = false
        /// Opened / Backgrounded on every transition.
        var appStateChanges = false

        static let `default` = Options()
    }

    private let store: UserDefaults
    private let namespace: String
    private let emit: (_ name: String, _ data: [String: IntemptType]?, _ userAttributes: [String: IntemptType]?) -> Void

    private let lock = ReadWriteLock(label: "com.intempt.autoevents")
    private var lastSessionId: String?

    var options: Options

    private enum Key {
        static func version(_ namespace: String) -> String {
            "com.intempt.lastSeenVersion.\(namespace)"
        }
    }

    init(
        namespace: String,
        store: UserDefaults = .standard,
        options: Options = .default,
        emit: @escaping (String, [String: IntemptType]?, [String: IntemptType]?) -> Void
    ) {
        self.namespace = namespace
        self.store = store
        self.options = options
        self.emit = emit
    }

    // MARK: - Session

    /// Emits "Session start" when the session id differs from the last one seen.
    ///
    /// Called on every tracked event. `IdentityManager` rolls the session id
    /// after 30 minutes idle, so this reacts to that single source of truth
    /// rather than keeping a second clock that can disagree with it.
    func noteActivity(sessionId: String) {
        guard options.sessions else { return }

        let isNew: Bool = lock.write {
            guard lastSessionId != sessionId else { return false }
            lastSessionId = sessionId
            return true
        }
        guard isNew else { return }

        // SessionStart.json has no `data` field: the two groups it defines are
        // `sessionAttributes` and `userAttributes`. The first argument here is
        // the session block, not event data.
        emit(
            EventNames.sessionStart,
            AutomaticProperties.sessionAttributes(),
            // Device facts land on the profile, not the event — intemptjs's
            // model. See AutomaticProperties modification 1.
            AutomaticProperties.userAttributes())
    }

    // MARK: - Version changes

    /// Emits Installed on the first launch ever, or Updated when the short
    /// version string changed. Records the new version either way, so a given
    /// version reports once and not on every launch.
    func checkVersion() {
        guard options.versionChanges else { return }

        let current =
            Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        guard !current.isEmpty else { return }

        let key = Key.version(namespace)
        let previous = store.string(forKey: key)

        // Written before emitting: if the emit path throws or the process dies,
        // a duplicate Installed on next launch is worse than a missing one.
        store.set(current, forKey: key)

        // The backend provisions ONE collection, "App Install/Upgrade", for
        // both cases — not two — and its schema
        // (com.intempt.data.source.ios/AppInstallUpgrade.json) distinguishes
        // them with a BOOLEAN `isUpgrade`, plus two DOUBLE version codes. An
        // earlier version sent `installType: "install"` and string versions;
        // none of those names exists in the schema, so every one of them was
        // silently dropped after ingestion returned 201.
        let buildType = Self.currentBuildType

        switch previous {
        case .none:
            emit(
                EventNames.appInstallUpgrade,
                [
                    EventKeys.isUpgrade: false,
                    EventKeys.currentVersionCode: Self.versionCode(current),
                    EventKeys.currentBuildType: buildType,
                ], nil)
        case .some(let old) where old != current:
            emit(
                EventNames.appInstallUpgrade,
                [
                    EventKeys.isUpgrade: true,
                    EventKeys.previousVersionCode: Self.versionCode(old),
                    EventKeys.currentVersionCode: Self.versionCode(current),
                    EventKeys.previousBuildType: buildType,
                    EventKeys.currentBuildType: buildType,
                ], nil)
        default:
            break  // same version, nothing to report
        }
    }

    // MARK: - App state

    func note(_ transition: AppTransition) {
        guard options.appStateChanges else { return }
        switch transition {
        case .foreground:
            emit(EventNames.applicationOpened, nil, nil)
        case .background:
            emit(EventNames.applicationBackgrounded, nil, nil)
        case .terminate:
            break  // no event: the process is going away and it would not flush
        }
    }

    /// The schema types version codes as `double`, but iOS versions are dotted
    /// strings ("1.2.3") that no numeric parse can hold losslessly.
    ///
    /// Encodes major.minor as the integer and fractional part — 1.2.3 becomes
    /// 1.2 — which is monotonic across ordinary releases and is what a
    /// numeric comparison in a segment needs. The exact string is not
    /// recoverable from it, and there is no schema field that could hold one.
    static func versionCode(_ version: String) -> Double {
        let parts = version.split(separator: ".").compactMap { Int($0) }
        guard let major = parts.first else { return 0 }
        let minor = parts.count > 1 ? parts[1] : 0
        return Double(major) + Double(minor) / 100.0
    }

    /// Android's `buildType` vocabulary, which the shared schema inherited.
    static var currentBuildType: String {
        #if DEBUG
            return "debug"
        #else
            return "release"
        #endif
    }

    /// Test seam.
    func forgetSession() {
        lock.write { lastSessionId = nil }
    }
}
