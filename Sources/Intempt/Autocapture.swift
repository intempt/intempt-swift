//
//  Autocapture.swift
//  Intempt
//
//  Copyright © 2026 Intempt Technologies, Inc.
//  Licensed under the Apache License, Version 2.0.
//
//  mixpanel-swift ships no autocapture in its SDK target — its swizzling lives
//  in the demo app. The old Intempt Objective-C SDK did autocapture and had the
//  defects `MethodSwizzler` now prevents structurally.
//
//  Event names come from the iOS SOURCE schema, not from intemptjs: a screen
//  appearing is "View screen", a tap is "Touch", a field edit is "Edit Field".
//  The backend provisions those collections for every iOS source
//  (IosSourceInitialization.java:38-46). The web SDK's "Click On" would match
//  no collection here and leave the provisioned `Touch` collection empty.
//
//  WHAT IS DELIBERATELY NOT CAPTURED
//
//    - The contents of any UITextField / UITextView. That is the user's typed
//      text: passwords, card numbers, messages. Autocapture that harvests it is
//      a breach with an analytics label on it. Only whether the field changed.
//    - Any view marked `isSecureTextEntry`, which is skipped entirely.
//    - Any view whose `accessibilityIdentifier` begins with `intempt-ignore`,
//      the opt-out for a screen containing sensitive controls.
//    - Cell contents in a table or collection view. The index path is
//      structural; the text in the row is the user's data.
//
import Foundation

#if canImport(UIKit) && !os(watchOS)
    import UIKit
#endif

/// Which interactions the SDK captures without an explicit call.
public struct AutocaptureOptions: Equatable, Sendable {
    /// `UIViewController` appearances, as "View screen".
    public var screens: Bool
    /// Control taps, as "Touch".
    public var taps: Bool
    /// Control value changes, as "Edit Field".
    public var controlChanges: Bool
    /// `UIViewController` disappearances, as "Leave screen", carrying how long
    /// the screen was visible.
    public var screenExits: Bool
    /// Taps that do NOT land on a UIControl, as "Touch".
    ///
    /// Separate from `taps` on purpose. A tap on a button already produces
    /// "Action", so counting it as a Touch as well would double-count every
    /// button press.
    public var rawTouches: Bool

    /// All off. Autocapture is opt-in: an SDK that starts writing events the
    /// integrator never asked for surprises people with an event bill, and on
    /// iOS it also means swizzling their view controllers uninvited.
    public init(
        screens: Bool = false,
        taps: Bool = false,
        controlChanges: Bool = false,
        screenExits: Bool = false,
        rawTouches: Bool = false
    ) {
        self.screens = screens
        self.taps = taps
        self.controlChanges = controlChanges
        self.screenExits = screenExits
        self.rawTouches = rawTouches
    }

    /// Everything the iOS source provisions a collection for.
    public static let all = AutocaptureOptions(
        screens: true, taps: true, controlChanges: true,
        screenExits: true, rawTouches: true)
    public static let none = AutocaptureOptions()
}

/// Installs UIKit hooks and turns them into events.
public final class Autocapture {

    /// The receiver for hook callbacks. Static because a swizzled UIKit method
    /// runs on the UIKit class, not on this object, so there is nowhere else to
    /// reach the SDK from. Weak so an abandoned instance cannot keep tracking.
    private static let activeLock = ReadWriteLock(label: "com.intempt.autocapture.active")
    private static weak var active: Autocapture?

    /// Identifier prefix a host app can use to exclude a control entirely.
    public static let ignoreIdentifierPrefix = "intempt-ignore"

    private let emit: (String, [String: IntemptType]) -> Void
    private let lock = ReadWriteLock(label: "com.intempt.autocapture")
    private var tokens: [MethodSwizzler.Token] = []
    private var running = false
    /// When each screen appeared, so "Leave screen" can report `timeOnScreen`.
    /// Keyed by reported name rather than by instance: holding view controllers
    /// here, even weakly, is not worth the lifetime questions for a duration.
    private var screenEntryTimes: [String: Date] = [:]

    public private(set) var options: AutocaptureOptions

    init(options: AutocaptureOptions = .none, emit: @escaping (String, [String: IntemptType]) -> Void)
    {
        self.options = options
        self.emit = emit
    }

    deinit { stop() }

    // MARK: - Lifecycle

    /// Installs the hooks for the current options.
    ///
    /// Idempotent: calling twice does not double-install, and `MethodSwizzler`
    /// refuses a duplicate even if this guard were bypassed.
    public func start() {
        let shouldStart: Bool = lock.write {
            guard !running else { return false }
            running = true
            return true
        }
        guard shouldStart else { return }

        Self.activeLock.write { Self.active = self }

        #if canImport(UIKit) && !os(watchOS)
            onMain {
                var installed: [MethodSwizzler.Token] = []

                if self.options.screens,
                    let token = MethodSwizzler.swizzle(
                        class: UIViewController.self,
                        original: #selector(UIViewController.viewDidAppear(_:)),
                        replacement: #selector(UIViewController.intempt_viewDidAppear(_:)))
                {
                    installed.append(token)
                }

                if self.options.screenExits,
                    let token = MethodSwizzler.swizzle(
                        class: UIViewController.self,
                        original: #selector(UIViewController.viewDidDisappear(_:)),
                        replacement: #selector(UIViewController.intempt_viewDidDisappear(_:)))
                {
                    installed.append(token)
                }

                // Raw taps come from UIWindow.sendEvent, which sees the touch
                // before any control does. Hooking it is the only way to notice
                // a tap on a plain view.
                if self.options.rawTouches,
                    let token = MethodSwizzler.swizzle(
                        class: UIWindow.self,
                        original: #selector(UIWindow.sendEvent(_:)),
                        replacement: #selector(UIWindow.intempt_sendEvent(_:)))
                {
                    installed.append(token)
                }

                // One hook covers both control actions and value changes: every
                // control action funnels through sendAction, so hooking
                // UIControl's own touch handling separately would double-count.
                if self.options.taps || self.options.controlChanges,
                    let token = MethodSwizzler.swizzle(
                        class: UIApplication.self,
                        original: #selector(UIApplication.sendAction(_:to:from:for:)),
                        replacement: #selector(UIApplication.intempt_sendAction(_:to:from:for:)))
                {
                    installed.append(token)
                }

                self.lock.write { self.tokens = installed }
            }
        #endif
    }

    /// Removes every hook. The host app's methods are left exactly as found.
    public func stop() {
        let wasRunning: Bool = lock.write {
            guard running else { return false }
            running = false
            return true
        }
        guard wasRunning else { return }

        Self.activeLock.write { if Self.active === self { Self.active = nil } }

        #if canImport(UIKit) && !os(watchOS)
            let toRemove: [MethodSwizzler.Token] = lock.write {
                let t = tokens
                tokens = []
                return t
            }
            onMain {
                for token in toRemove {
                    let replacement: Selector
                    switch token.selector {
                    case #selector(UIViewController.viewDidAppear(_:)):
                        replacement = #selector(UIViewController.intempt_viewDidAppear(_:))
                    case #selector(UIViewController.viewDidDisappear(_:)):
                        replacement = #selector(UIViewController.intempt_viewDidDisappear(_:))
                    case #selector(UIWindow.sendEvent(_:)):
                        replacement = #selector(UIWindow.intempt_sendEvent(_:))
                    default:
                        replacement = #selector(UIApplication.intempt_sendAction(_:to:from:for:))
                    }
                    MethodSwizzler.remove(token, replacement: replacement)
                }
            }
        #endif
    }

    /// Sets what to capture. Applied on the next `start()`; if already running,
    /// the hooks are reinstalled so the change takes effect immediately.
    public func configure(_ newOptions: AutocaptureOptions) {
        let wasRunning = isRunning
        if wasRunning { stop() }
        lock.write { options = newOptions }
        if wasRunning { start() }
    }

    public var isRunning: Bool { lock.read { running } }

    private func onMain(_ work: @escaping () -> Void) {
        // Never `sync`: `start()` may be called from a background queue while
        // main waits on it, and UIKit swizzling must happen on main.
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    // MARK: - Hook receivers

    fileprivate static func current() -> Autocapture? { activeLock.read { active } }

    fileprivate func screenAppeared(name: String) {
        guard lock.read({ running && options.screens }) else { return }
        lock.write { screenEntryTimes[name] = Date() }
        emit(EventNames.viewScreen, [EventKeys.viewController: name])
    }

    fileprivate func screenDisappeared(name: String) {
        guard lock.read({ running && options.screenExits }) else { return }

        // Only reported when we saw the matching appearance, so a screen that
        // was already on-screen when capture started does not produce a
        // fabricated duration.
        let entered: Date? = lock.write {
            let value = screenEntryTimes[name]
            screenEntryTimes[name] = nil
            return value
        }

        var properties: [String: IntemptType] = [EventKeys.viewController: name]
        if let entered {
            properties[EventKeys.timeOnScreen] = Date().timeIntervalSince(entered)
        }
        emit(EventNames.leaveScreen, properties)
    }

    fileprivate func rawTouch(properties: [String: IntemptType]) {
        guard lock.read({ running && options.rawTouches }) else { return }
        emit(EventNames.touch, properties)
    }

    fileprivate func interaction(name: String, properties: [String: IntemptType]) {
        guard lock.read({ running }) else { return }
        emit(name, properties)
    }
}

// MARK: - UIKit hooks

#if canImport(UIKit) && !os(watchOS)

    extension UIViewController {
        @objc dynamic func intempt_viewDidAppear(_ animated: Bool) {
            // Reaches the original implementation after the swizzle.
            intempt_viewDidAppear(animated)

            guard let capture = Autocapture.current() else { return }
            guard !Autocapture.isIgnored(self.view) else { return }

            capture.screenAppeared(name: Autocapture.screenName(for: self))
        }
    }

    extension UIViewController {
        @objc dynamic func intempt_viewDidDisappear(_ animated: Bool) {
            intempt_viewDidDisappear(animated)

            guard let capture = Autocapture.current() else { return }
            guard !Autocapture.isIgnored(self.view) else { return }

            capture.screenDisappeared(name: Autocapture.screenName(for: self))
        }
    }

    extension UIWindow {
        @objc dynamic func intempt_sendEvent(_ event: UIEvent) {
            // Original first, always: swallowing an event here would freeze the
            // host app's entire touch handling.
            intempt_sendEvent(event)

            guard let capture = Autocapture.current(),
                let touch = event.allTouches?.first,
                touch.phase == .ended,
                let hit = touch.view
            else { return }

            // A UIControl already reports through sendAction as "Action", so
            // counting it here too would double-count every button press.
            guard !(hit is UIControl), !Autocapture.isIgnored(hit) else { return }

            capture.rawTouch(properties: Autocapture.properties(for: hit))
        }
    }

    extension UIApplication {
        @objc dynamic func intempt_sendAction(
            _ action: Selector,
            to target: Any?,
            from sender: Any?,
            for event: UIEvent?
        ) -> Bool {
            // Original first: the app's own action must run even if anything
            // below throws or the SDK is misconfigured.
            let handled = intempt_sendAction(action, to: target, from: sender, for: event)

            guard let capture = Autocapture.current(),
                let control = sender as? UIControl,
                !Autocapture.isIgnored(control)
            else { return handled }

            let isValueChange = Autocapture.isValueChange(control)
            guard
                (isValueChange && capture.options.controlChanges)
                    || (!isValueChange && capture.options.taps)
            else { return handled }

            capture.interaction(
                name: isValueChange ? EventNames.editField : EventNames.action,
                properties: Autocapture.properties(for: control))
            return handled
        }
    }

#endif

// MARK: - Element description

extension Autocapture {

    #if canImport(UIKit) && !os(watchOS)

        /// A `UIViewController`'s reported name. The class name, not the title:
        /// a title is user-facing copy and on a detail screen it is frequently
        /// the user's own content ("Chat with Dr Adeyemi").
        static func screenName(for controller: UIViewController) -> String {
            if let identifier = controller.view?.accessibilityIdentifier,
                !identifier.isEmpty,
                !identifier.hasPrefix(ignoreIdentifierPrefix)
            {
                return identifier
            }
            // Strips the module prefix Swift adds, so "MyApp.CartViewController"
            // reports as "CartViewController" and matches across builds where
            // the module name differs (app vs extension vs test host).
            let raw = NSStringFromClass(type(of: controller))
            return raw.components(separatedBy: ".").last ?? raw
        }

        /// Whether a control reports a value change rather than a plain tap.
        ///
        /// tvOS ships a much smaller UIKit: `UISwitch`, `UISlider`, `UIStepper`
        /// and `UIDatePicker` do not exist there at all, so naming them
        /// unconditionally fails to compile for tvOS. The platform type-check
        /// gate caught this; a macOS-only test run never would have, because
        /// none of this file is compiled there.
        static func isValueChange(_ control: UIControl) -> Bool {
            if control is UISegmentedControl || control is UITextField
                || control is UIPageControl
            {
                return true
            }
            #if os(iOS)
                if control is UISwitch || control is UISlider || control is UIStepper
                    || control is UIDatePicker
                {
                    return true
                }
            #endif
            return false
        }

        /// True when the SDK must not record anything about this view.
        static func isIgnored(_ view: UIView?) -> Bool {
            guard let view else { return false }

            // Never record a secure field, not even that it changed: on a login
            // screen the timing alone is more than analytics needs.
            if let field = view as? UITextField, field.isSecureTextEntry { return true }

            // Walk up: marking a container excludes everything inside it, which
            // is what a host app expects from a screen-level opt-out.
            var node: UIView? = view
            while let current = node {
                if let identifier = current.accessibilityIdentifier,
                    identifier.hasPrefix(ignoreIdentifierPrefix)
                {
                    return true
                }
                node = current.superview
            }
            return false
        }

        /// Structural facts for any view, used by raw touch capture.
        ///
        /// A plain view has no action and no title, so this is the subset of the
        /// control version that applies to everything.
        static func properties(for view: UIView) -> [String: IntemptType] {
            var properties: [String: IntemptType] = [
                EventKeys.targetViewClass: String(describing: type(of: view))
            ]
            if let identifier = view.accessibilityIdentifier, !identifier.isEmpty {
                properties[EventKeys.targetAccessibilityIdentifier] = identifier
                properties[EventKeys.targetViewName] = identifier
            }
            if let label = view.accessibilityLabel, !label.isEmpty {
                properties[EventKeys.targetAccessibilityLabel] = label
            }
            if let hierarchy = viewHierarchy(for: view) {
                properties[EventKeys.hierarchy] = hierarchy
            }
            return properties
        }

        /// Structural facts only — never the user's content.
        static func properties(for control: UIControl) -> [String: IntemptType] {
            var properties: [String: IntemptType] = [
                EventKeys.targetViewClass: String(describing: type(of: control))
            ]

            if let identifier = control.accessibilityIdentifier, !identifier.isEmpty {
                properties[EventKeys.targetAccessibilityIdentifier] = identifier
                properties[EventKeys.targetViewName] = identifier
            }

            // A button's title is developer-authored copy ("Add to cart") and is
            // the single most useful label. A text field's CONTENTS are the
            // user's data and are never read — note this asks the button for its
            // title and never asks a field for its text.
            if let button = control as? UIButton,
                let title = button.title(for: .normal),
                !title.isEmpty
            {
                properties[EventKeys.targetText] = title
            }
            if let label = control.accessibilityLabel, !label.isEmpty,
                !(control is UITextField)
            {
                properties[EventKeys.targetAccessibilityLabel] = label
            }

            if let hierarchy = viewHierarchy(for: control) {
                properties[EventKeys.hierarchy] = hierarchy
            }
            return properties
        }

        /// Class names from the control up to its window, so a tap can be
        /// attributed to a screen. Capped: a deep hierarchy would otherwise
        /// produce a property longer than the event it describes.
        static func viewHierarchy(for view: UIView, limit: Int = 6) -> String? {
            var names: [String] = []
            var node: UIView? = view.superview
            while let current = node, names.count < limit {
                names.append(String(describing: type(of: current)))
                node = current.superview
            }
            return names.isEmpty ? nil : names.reversed().joined(separator: " > ")
        }

    #endif
}
