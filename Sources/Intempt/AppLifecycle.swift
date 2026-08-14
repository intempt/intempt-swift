//
//  AppLifecycle.swift
//  Intempt
//
//  Copyright © 2026 Intempt Technologies, Inc.
//  Licensed under the Apache License, Version 2.0.
//
//  No single mixpanel-swift equivalent: upstream scatters
//  `NotificationCenter.addObserver` calls with UIKit notification names through
//  MixpanelInstance, which means the whole file is iOS-shaped and the macOS and
//  watchOS paths are afterthoughts guarded inline.
//
//  Here every platform's notifications are mapped ONCE onto a neutral enum, so
//  the subscribers (Flush, AutomaticEvents) contain no `#if os(...)` at all.
//  That is the difference between four platforms being supported and three of
//  them being untested.
//
import Foundation

#if canImport(UIKit) && !os(watchOS)
    import UIKit
#elseif os(watchOS)
    import WatchKit
#elseif os(macOS)
    import AppKit
#endif

/// Platform-neutral application transitions.
enum AppTransition {
    /// App became active — first launch or return from background.
    case foreground
    /// App is leaving the foreground. Last chance to persist and flush.
    case background
    /// Process is about to exit.
    case terminate
}

/// Bridges each platform's notification names onto `AppTransition`.
final class AppLifecycle {

    private var observers: [NSObjectProtocol] = []
    private let center: NotificationCenter
    private let handler: (AppTransition) -> Void

    /// - Parameter handler: invoked on the main thread.
    init(center: NotificationCenter = .default, handler: @escaping (AppTransition) -> Void) {
        self.center = center
        self.handler = handler
        subscribe()
    }

    deinit {
        observers.forEach { center.removeObserver($0) }
    }

    private func subscribe() {
        for (name, transition) in Self.notificationMap {
            let token = center.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                self?.handler(transition)
            }
            observers.append(token)
        }
    }

    /// The one place platform differences live.
    ///
    /// watchOS is deliberately absent: `WKApplication`'s notification names
    /// moved across watchOS versions, and rather than guess at a name that
    /// would silently never fire, watchOS relies on the flush timer and
    /// explicit `flush()` calls. A lifecycle hook that looks present and does
    /// nothing is worse than one that is documented as missing.
    static var notificationMap: [(Notification.Name, AppTransition)] {
        #if os(iOS) || os(tvOS)
            return [
                (UIApplication.didBecomeActiveNotification, .foreground),
                (UIApplication.didEnterBackgroundNotification, .background),
                (UIApplication.willTerminateNotification, .terminate),
            ]
        #elseif os(macOS)
            return [
                (NSApplication.didBecomeActiveNotification, .foreground),
                (NSApplication.didResignActiveNotification, .background),
                (NSApplication.willTerminateNotification, .terminate),
            ]
        #else
            return []
        #endif
    }

    /// True when this platform reports transitions at all. Callers use it to
    /// decide whether the flush timer is the only delivery trigger.
    static var isSupported: Bool { !notificationMap.isEmpty }
}

// MARK: - Background task assertion

/// Asks the OS for time to finish a flush that started as the app suspends.
///
/// Without this the process is frozen mid-request, the URLSession task is
/// cancelled, and the batch is retried on next launch — so events arrive late
/// or, if the user never returns, not at all. Upstream wraps its flush in a
/// background task for exactly this reason; the difference here is that the
/// no-op path for tvOS/watchOS/macOS is explicit rather than an unbalanced
/// `begin` with no `end`.
enum BackgroundTask {

    /// Runs `work`, holding a background assertion until `done()` is called.
    ///
    /// - Parameter work: receives a completion it MUST call exactly once.
    static func perform(_ work: (@escaping () -> Void) -> Void) {
        #if os(iOS) || os(tvOS)
            var identifier: UIBackgroundTaskIdentifier = .invalid
            // `expirationHandler` fires if the OS runs out of patience. Ending
            // the task there is mandatory — leaking it terminates the app.
            identifier = UIApplication.shared.beginBackgroundTask(
                withName: "com.intempt.flush"
            ) {
                if identifier != .invalid {
                    UIApplication.shared.endBackgroundTask(identifier)
                    identifier = .invalid
                }
            }

            var finished = false
            work {
                // Guard against a double call: ending an already-ended task
                // traps, and a completion handler called twice is a common bug
                // in the code paths that lead here.
                guard !finished else { return }
                finished = true
                guard identifier != .invalid else { return }
                let toEnd = identifier
                identifier = .invalid
                DispatchQueue.main.async {
                    UIApplication.shared.endBackgroundTask(toEnd)
                }
            }
        #else
            work {}
        #endif
    }
}
