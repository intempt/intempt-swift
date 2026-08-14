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

    /// All off. Autocapture is opt-in: an SDK that starts writing events the
    /// integrator never asked for surprises people with an event bill, and on
    /// iOS it also means swizzling their view controllers uninvited.
    public init(screens: Bool = false, taps: Bool = false, controlChanges: Bool = false) {
        self.screens = screens
        self.taps = taps
        self.controlChanges = controlChanges
    }

    public static let all = AutocaptureOptions(screens: true, taps: true, controlChanges: true)
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

                // One hook covers both taps and value changes: every control
                // action funnels through sendAction, so hooking UIControl's own
                // touch handling separately would double-count.
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
                    if token.selector == #selector(UIViewController.viewDidAppear(_:)) {
                        replacement = #selector(UIViewController.intempt_viewDidAppear(_:))
                    } else {
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
        emit(EventNames.viewScreen, [EventKeys.screenName: name])
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
                name: isValueChange ? EventNames.editField : EventNames.touch,
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
        static func isValueChange(_ control: UIControl) -> Bool {
            control is UISwitch || control is UISlider || control is UIStepper
                || control is UISegmentedControl || control is UIDatePicker
                || control is UITextField || control is UIPageControl
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

        /// Structural facts only — never the user's content.
        static func properties(for control: UIControl) -> [String: IntemptType] {
            var properties: [String: IntemptType] = [
                EventKeys.elementType: String(describing: type(of: control))
            ]

            if let identifier = control.accessibilityIdentifier, !identifier.isEmpty {
                properties[EventKeys.elementIdentifier] = identifier
            }

            // A button's title is developer-authored copy ("Add to cart") and is
            // the single most useful label. A text field's CONTENTS are the
            // user's data and are never read — note this asks the button for its
            // title and never asks a field for its text.
            if let button = control as? UIButton,
                let title = button.title(for: .normal),
                !title.isEmpty
            {
                properties[EventKeys.elementLabel] = title
            } else if let label = control.accessibilityLabel, !label.isEmpty,
                !(control is UITextField)
            {
                properties[EventKeys.elementLabel] = label
            }

            if let hierarchy = viewHierarchy(for: control) {
                properties[EventKeys.viewHierarchy] = hierarchy
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
