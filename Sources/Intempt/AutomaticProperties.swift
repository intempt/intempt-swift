//
//  AutomaticProperties.swift
//  Intempt
//
//  Adapted from mixpanel-swift's AutomaticProperties.swift
//  (https://github.com/mixpanel/mixpanel-swift)
//  Copyright © 2016 Mixpanel. All rights reserved.
//  Licensed under the Apache License, Version 2.0.
//
//  Modifications by Intempt Technologies, Inc. (Apache License 2.0, §4(b)):
//
//    1. SENT ONCE PER SESSION AS `userAttributes`, NOT ON EVERY EVENT. This is
//       Intempt's model, not Mixpanel's. intemptjs collects platform and device
//       facts in UserAttributeComponent and sends them as `userAttributes` on a
//       session-start event (sessionTracker.module.ts:183-189). Mixpanel stamps
//       its device properties onto every single event. Following intemptjs is
//       both the consistent choice and the cheaper one: device facts do not
//       change mid-session, so repeating them per event is pure payload waste.
//
//    2. intemptjs KEY NAMES AND VOCABULARY. camelCase, and `platform` /
//       `deviceType` use intemptjs's exact formats — "iOS 18.2" (major.minor
//       only, per platformParser's ios formatter) and the DeviceTypeName
//       vocabulary "Mobile" / "Tablet" / "Desktop". Not Mixpanel's `$`-prefixed
//       reserved names, which mean nothing to Intempt ingestion.
//
//    3. NO CARRIER OR RADIO. Upstream reads CTTelephonyNetworkInfo, which on
//       iOS 16+ needs an entitlement most apps lack, returns junk without it,
//       and links CoreTelephony into every embedding app.
//
//    4. NO IDFA, NO IDFV. Reading IDFA requires an AppTrackingTransparency
//       prompt; collecting it silently is an App Store rejection. A customer
//       who wants it passes it as an attribute.
//
//    5. NO IP GEOLOCATION. intemptjs calls a geo-IP service to fill country /
//       region / city. A native SDK making an extra network call to a third
//       party to learn something the ingestion server already sees on the
//       request IP is a privacy cost with no benefit.
//
import Foundation

#if canImport(UIKit) && !os(watchOS)
    import UIKit
#elseif os(watchOS)
    import WatchKit
#elseif os(macOS)
    import AppKit
#endif

/// Device, OS and app facts describing the current install.
///
/// Nothing here identifies a person: no advertising identifier, no vendor
/// identifier, no carrier, no IP geolookup. See the header for why each was
/// refused rather than merely omitted.
enum AutomaticProperties {

    private static let lock = ReadWriteLock(label: "com.intempt.autoprops")
    private static var cached: [String: IntemptType]?
    /// Resolved on the main thread by `warm()`; nil until then.
    private static var resolvedScreen: (width: Int, height: Int)?

    /// Resolves the values that require the main thread, then caches the set.
    ///
    /// `UIApplication.connectedScenes` and `NSScreen.main` are main-thread-only,
    /// but the first event is enqueued on a background queue — so a naive
    /// `static let` computed on first use reads UIKit from the wrong thread.
    /// Upstream gets away with `UIScreen.main` at static-init time; that API is
    /// deprecated on current SDKs and is the wrong screen under iPad
    /// multitasking, so this resolves it properly instead.
    ///
    /// Called from `IntemptInstance.initialize`. Safe to call repeatedly.
    static func warm() {
        let resolve = {
            let size = screenSize
            lock.write {
                resolvedScreen = size
                cached = nil  // force a rebuild that includes the screen
            }
            _ = userAttributes()
        }
        if Thread.isMainThread {
            resolve()
        } else {
            // async, never sync: `initialize` may itself run on a background
            // queue with main blocked waiting on it.
            DispatchQueue.main.async(execute: resolve)
        }
    }

    /// Device and platform facts, shaped for the `userAttributes` field of a
    /// session-start event. Cached after the first build.
    static func userAttributes() -> [String: IntemptType] {
        if let existing = lock.read({ cached }) { return existing }
        let built = build()
        lock.write { cached = built }
        return built
    }

    /// Test seam.
    static func reset() {
        lock.write {
            cached = nil
            resolvedScreen = nil
        }
    }

    /// SessionStart.userAttributes accepts exactly `deviceType` and `platform`
    /// (plus geo, which the server derives from the request IP). Anything else
    /// sent here has no column and is silently dropped after a 201.
    private static func build() -> [String: IntemptType] {
        [
            "deviceType": deviceType,
            "platform": platform,
        ]
    }

    /// SessionStart.sessionAttributes — the schema's fixed set.
    ///
    /// `iosVendorId` and `iosAdvertiserId` have columns here and are
    /// deliberately left empty. IDFA needs an AppTrackingTransparency prompt
    /// the SDK must not trigger on the host app's behalf, and IDFV is a device
    /// identifier the SDK has no reason to collect by default. A customer who
    /// wants either can pass it explicitly.
    static func sessionAttributes() -> [String: IntemptType] {
        var p: [String: IntemptType] = [
            "source": platform,
            "device": deviceModel,
            "sessionStartEventName": EventNames.sessionStart,
        ]

        let info = Bundle.main.infoDictionary
        if let version = info?["CFBundleShortVersionString"] as? String {
            p["appVersion"] = version
        }
        if let name = info?["CFBundleName"] as? String ?? info?["CFBundleDisplayName"] as? String {
            p["appName"] = name
        }
        if let identifier = Bundle.main.bundleIdentifier {
            p["appIdentifier"] = identifier
        }
        return p
    }

    // MARK: - Platform

    /// intemptjs's exact format: its `ios` formatter emits `iOS <major>.<minor>`
    /// and deliberately drops the patch component
    /// (platformParser.ts:17-23). Matching it means a segment written against
    /// web data also matches iOS data.
    static var platform: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let short = "\(v.majorVersion).\(v.minorVersion)"

        #if os(iOS)
            #if targetEnvironment(macCatalyst)
                return "Mac Catalyst \(short)"
            #else
                return "iOS \(short)"
            #endif
        #elseif os(tvOS)
            return "tvOS \(short)"
        #elseif os(watchOS)
            return "watchOS \(short)"
        #elseif os(macOS)
            // intemptjs renders macOS as "Mac OS X <version>" with the full
            // version, not truncated.
            return "Mac OS X \(short).\(v.patchVersion)"
        #else
            return "Unknown"
        #endif
    }

    /// intemptjs's `DeviceTypeName` vocabulary: "Desktop", "Mobile", "Tablet",
    /// "Not Recognized". "TV" and "Watch" are additions — the web SDK cannot
    /// see those platforms, and reporting an Apple Watch as "Not Recognized"
    /// would discard information for the sake of a false consistency.
    static var deviceType: String {
        #if os(tvOS)
            return "TV"
        #elseif os(watchOS)
            return "Watch"
        #elseif os(macOS)
            return "Desktop"
        #elseif os(iOS)
            #if targetEnvironment(macCatalyst)
                return "Desktop"
            #else
                switch UIDevice.current.userInterfaceIdiom {
                case .pad: return "Tablet"
                case .phone: return "Mobile"
                case .mac: return "Desktop"
                case .tv: return "TV"
                default: return "Not Recognized"
                }
            #endif
        #else
            return "Not Recognized"
        #endif
    }

    static var osName: String {
        #if os(iOS)
            return "iOS"
        #elseif os(tvOS)
            return "tvOS"
        #elseif os(watchOS)
            return "watchOS"
        #elseif os(macOS)
            return "macOS"
        #else
            return "unknown"
        #endif
    }

    /// Full version including patch, unlike `platform`.
    static var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    /// The hardware identifier ("iPhone15,2"), not the marketing name.
    /// `UIDevice.model` returns "iPhone" for every iPhone ever shipped, which
    /// cannot be segmented on. On the simulator `utsname.machine` reports the
    /// host architecture, so the simulated model is read from the environment
    /// rather than reported as an x86_64 iPhone.
    static var deviceModel: String {
        #if targetEnvironment(simulator)
            if let identifier = ProcessInfo.processInfo
                .environment["SIMULATOR_MODEL_IDENTIFIER"]
            {
                return identifier
            }
            return "Simulator"
        #else
            var info = utsname()
            uname(&info)
            let machine = withUnsafePointer(to: &info.machine) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
            }
            return machine.isEmpty ? "unknown" : machine
        #endif
    }

    /// Points, not pixels: a caller comparing against layout values wants
    /// points.
    static var screenSize: (width: Int, height: Int)? {
        #if os(watchOS)
            let bounds = WKInterfaceDevice.current().screenBounds
            return (Int(bounds.width), Int(bounds.height))
        #elseif canImport(UIKit)
            guard let bounds = activeWindowScene()?.screen.bounds else { return nil }
            return (Int(bounds.width), Int(bounds.height))
        #elseif os(macOS)
            guard let frame = NSScreen.main?.frame else { return nil }
            return (Int(frame.width), Int(frame.height))
        #else
            return nil
        #endif
    }

    #if canImport(UIKit) && !os(watchOS)
        /// The foreground-active scene, falling back to any connected scene.
        /// `UIScreen.main` is deprecated and, under iPad multitasking or an
        /// external display, is the wrong screen.
        static func activeWindowScene() -> UIWindowScene? {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        }
    #endif
}
