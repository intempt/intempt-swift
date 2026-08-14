//
//  IdentityManager.swift
//  Intempt
//
//  Copyright © 2026 Intempt Technologies, Inc.
//  Licensed under the Apache License, Version 2.0.
//
//  Owns profileId / sessionId / pageId. Mixpanel splits this across
//  MixpanelInstance and SessionMetadata with different names (distinctId /
//  anonymousId), so this is Intempt's shape rather than a port — but the
//  discipline is upstream's: one owner, all mutation serialised.
//
//  Fixes carried from the old Obj-C SDK audit:
//    F-53  getSessionId() minted a fresh UUID on every call and never stored
//          it, so experiment requests carried ids no session ever had.
//    F-51  text input did not count as activity, so long-form typing tripped
//          a spurious session rollover mid-entry.
//    Android cross-user leak: logOut() restored the same profileId, so the
//          next user on a shared device inherited the previous identity.
//
import Foundation

/// Persisted identity and session state.
final class IdentityManager {

    /// Idle window before a new session starts. Matches the old Obj-C SDK's
    /// 30 minutes, which is also the convention across Intempt's platforms.
    static let sessionTimeout: TimeInterval = 1800

    /// Sessions shorter than this are still tracked — unlike upstream, which
    /// drops sub-10s sessions entirely. Intempt reports them because a bounce
    /// is a real signal, not noise.
    private let store: UserDefaults
    private let lock = ReadWriteLock(label: "com.intempt.identity")
    private let clock: () -> Date

    private enum Key {
        static let profileId = "com.intempt.profileId"
    }

    private var _sessionId: String
    private var _pageId: String
    private var _lastActivity: Date

    init(namespace: String, store: UserDefaults = .standard, clock: @escaping () -> Date = Date.init)
    {
        self.store = store
        self.clock = clock
        let key = "\(Key.profileId).\(namespace)"
        self.profileIdKey = key

        // Anonymous profile id persists across launches. Generated once.
        if let existing = store.string(forKey: key), !existing.isEmpty {
            self._profileId = existing
        } else {
            let fresh = "pr_" + UUID().uuidString
            store.set(fresh, forKey: key)
            self._profileId = fresh
        }

        self._sessionId = "se_" + UUID().uuidString
        self._pageId = "pg_" + UUID().uuidString
        self._lastActivity = clock()
    }

    private let profileIdKey: String
    private var _profileId: String

    // MARK: - Accessors

    var profileId: String { lock.read { _profileId } }

    /// Returns the *stored* session id, rolling it over only when the idle
    /// window has elapsed. It never fabricates an unstored value.
    var sessionId: String {
        lock.write {
            rollIfIdleLocked()
            return _sessionId
        }
    }

    var pageId: String { lock.read { _pageId } }

    // MARK: - Activity

    /// Marks user activity. Every capture path calls this — including text
    /// input, which the old SDK excluded, causing rollovers mid-typing.
    func recordActivity() {
        lock.write {
            rollIfIdleLocked()
            _lastActivity = clock()
        }
    }

    private func rollIfIdleLocked() {
        if clock().timeIntervalSince(_lastActivity) >= Self.sessionTimeout {
            _sessionId = "se_" + UUID().uuidString
            _pageId = "pg_" + UUID().uuidString
        }
        _lastActivity = clock()
    }

    /// New screen — a fresh pageId, same session.
    func newPage() {
        lock.write {
            _pageId = "pg_" + UUID().uuidString
            _lastActivity = clock()
        }
    }

    // MARK: - Lifecycle

    /// Logout. Rotates the anonymous identity so the next user on a shared
    /// device does not inherit the previous one.
    func logOut() {
        lock.write {
            let fresh = "pr_" + UUID().uuidString
            store.set(fresh, forKey: profileIdKey)
            _profileId = fresh
            _sessionId = "se_" + UUID().uuidString
            _pageId = "pg_" + UUID().uuidString
            _lastActivity = clock()
        }
    }

    /// Full reset — identical to `logOut()` for identity purposes; the queue
    /// purge is the caller's responsibility.
    func reset() { logOut() }

    /// Envelope for a new event, taking the current identity snapshot.
    func makeEnvelope() -> EventEnvelope {
        lock.write {
            rollIfIdleLocked()
            return EventEnvelope(
                eventId: EventConstants.eventIdPrefix + UUID().uuidString,
                profileId: _profileId,
                sessionId: _sessionId,
                pageId: _pageId)
        }
    }
}
