//
//  IntemptDemoApp.swift
//  IntemptDemo
//
//  Copyright © 2026 Intempt Technologies, Inc.
//  Licensed under the Apache License, Version 2.0.
//
//  Exercises every public API of the Intempt SDK on a real device or
//  simulator. Two jobs:
//
//    1. A worked integration an engineer can read and copy.
//    2. The only place autocapture, APNs and the UIKit conditionals actually
//       RUN. The package's 285 unit tests run on the macOS host, where every
//       `#if os(iOS)` branch is excluded from the build — so UIKit code can be
//       type-correct and still be wrong, and only this app can show that.
//
import Intempt
import SwiftUI
import UIKit

@main
struct IntemptDemoApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        DemoConfig.start()
        return true
    }

    // MARK: - APNs
    //
    // APNs only. There is no Firebase or FCM dependency anywhere in this SDK
    // or in this app.

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        // The raw Data, never `deviceToken.description`. That idiom has
        // produced the literal string "32 bytes" since iOS 13.
        Intempt.shared?.setPushToken(deviceToken)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        DemoLog.append("push registration failed: \(error.localizedDescription)")
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        Intempt.shared?.trackPushReceived(userInfo)
        completionHandler(.noData)
    }
}

// MARK: - Configuration

/// Credentials come from the environment so nothing is committed.
///
/// In Xcode: Product → Scheme → Edit Scheme → Run → Arguments → Environment
/// Variables. The UI test scheme passes them through `launchEnvironment`.
enum DemoConfig {

    static func start() {
        let environment = ProcessInfo.processInfo.environment
        guard
            let apiKey = environment["INTEMPT_API_KEY"],
            let orgId = environment["INTEMPT_ORG_ID"],
            let projectId = environment["INTEMPT_PROJECT_ID"],
            let sourceId = environment["INTEMPT_SOURCE_ID"]
        else {
            DemoLog.append("no credentials — set INTEMPT_* in the scheme's environment")
            return
        }

        do {
            let instance = try Intempt.initializeShared(
                apiKey: apiKey, orgId: orgId, projectId: projectId, sourceId: sourceId)

            // Short interval so the demo shows delivery without a 60s wait.
            instance.flushInterval = 10

            instance.automaticEvents = AutomaticEventOptions(
                sessions: true, versionChanges: true, appStateChanges: true)

            instance.autocapture.configure(.all)
            instance.autocapture.start()

            DemoLog.append("initialized — profile \(instance.getProfileId())")
        } catch {
            // `initialize` throws rather than logging and continuing. The old
            // Obj-C SDK asserted, and NSAssert compiles out in Release, so
            // blank credentials shipped requests to `.../(null)/projects/...`
            // forever.
            DemoLog.append("initialize failed: \(error)")
        }
    }
}

/// Shared accessor so the demo does not thread an instance through every view.
extension Intempt {
    private static let sharedLock = NSLock()
    nonisolated(unsafe) private static var _shared: IntemptInstance?

    static var shared: IntemptInstance? {
        sharedLock.lock()
        defer { sharedLock.unlock() }
        return _shared
    }

    @discardableResult
    static func initializeShared(
        apiKey: String, orgId: String, projectId: String, sourceId: String
    ) throws -> IntemptInstance {
        let instance = try IntemptInstance.initialize(
            apiKey: apiKey, orgId: orgId, projectId: projectId, sourceId: sourceId)
        sharedLock.lock()
        _shared = instance
        sharedLock.unlock()
        return instance
    }
}

// MARK: - On-screen log

/// A visible record of what the SDK did, so the UI test can assert on it and a
/// human can see delivery happen.
final class DemoLog: ObservableObject {
    static let shared = DemoLog()

    @Published private(set) var lines: [String] = []

    static func append(_ line: String) {
        DispatchQueue.main.async {
            shared.lines.insert(line, at: 0)
            if shared.lines.count > 100 { shared.lines.removeLast() }
        }
    }

    static func clear() {
        DispatchQueue.main.async { shared.lines.removeAll() }
    }
}
