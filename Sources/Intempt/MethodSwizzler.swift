//
//  MethodSwizzler.swift
//  Intempt
//
//  Copyright © 2026 Intempt Technologies, Inc.
//  Licensed under the Apache License, Version 2.0.
//
//  mixpanel-swift has no equivalent in its SDK target: its swizzling lives in
//  the DEMO app (MixpanelDemo/AppDelegate.swift), not the library. The old
//  Intempt Objective-C SDK swizzled directly with
//  `method_exchangeImplementations` and had three defects this type exists to
//  make impossible:
//
//    1. IT DROPPED THE ORIGINAL IMPLEMENTATION. When the host app's method did
//       not exist on the class itself but was inherited, the exchange installed
//       the SDK's version on the subclass and the original was never called —
//       silently breaking the app's own behaviour (audit F-11).
//
//    2. IT SWIZZLED MORE THAN ONCE. Nothing guarded against a second
//       `initialize` re-exchanging the same pair, which restores the original
//       and un-swizzles — so autocapture worked or not depending on how many
//       times the SDK was initialised.
//
//    3. IT COULD NOT BE UNDONE. There was no unswizzle path, so a test could
//       not clean up after itself and opting out at runtime left the hooks in.
//
//  This type is pure Objective-C runtime and carries no UIKit dependency, so
//  every guarantee above is unit-tested on the macOS host rather than asserted.
//
import Foundation
import ObjectiveC.runtime

/// Installs and removes method hooks safely.
///
/// The added-then-exchanged approach is what makes inherited methods safe:
/// `class_addMethod` first attempts to install the replacement directly. If it
/// succeeds, the class did NOT implement the selector itself — it inherited it
/// — and exchanging would have corrupted the superclass's implementation for
/// every other subclass. In that case the original is reached through `super`
/// and no exchange happens at all.
enum MethodSwizzler {

    /// One installed hook, retained so it can be removed.
    struct Token {
        let className: String
        let selector: Selector
        /// False when the replacement was ADDED to a class that inherited the
        /// selector rather than implementing it.
        let didExchange: Bool
        /// The implementation in place before the hook. Required to undo the
        /// added case: `class_addMethod` cannot be un-added, so removal
        /// restores this IMP in place instead.
        let originalIMP: IMP?
        let typeEncoding: UnsafePointer<CChar>?
        /// The hook's own implementation. The added path repoints the
        /// REPLACEMENT selector at the original IMP so the hook can call
        /// through; removal has to put this back, or both selectors are left
        /// holding the original and a re-install silently hooks nothing.
        let replacementIMP: IMP?
        let replacementTypeEncoding: UnsafePointer<CChar>?
        let replacementSelector: Selector?
    }

    private static let lock = ReadWriteLock(label: "com.intempt.swizzler")
    private static var installed: Set<String> = []

    private static func key(_ cls: AnyClass, _ selector: Selector) -> String {
        "\(NSStringFromClass(cls)).\(NSStringFromSelector(selector))"
    }

    /// True when this exact class/selector pair is already hooked.
    static func isSwizzled(_ cls: AnyClass, _ selector: Selector) -> Bool {
        lock.read { installed.contains(key(cls, selector)) }
    }

    /// Exchanges `original` with `replacement` on `cls`.
    ///
    /// - Returns: a token to pass to `remove`, or nil if the hook could not be
    ///   installed or was already present. Never installs twice — a second
    ///   exchange of the same pair restores the original and silently disables
    ///   the hook.
    @discardableResult
    static func swizzle(
        class cls: AnyClass,
        original: Selector,
        replacement: Selector
    ) -> Token? {
        let identifier = key(cls, original)

        let shouldProceed: Bool = lock.write {
            guard !installed.contains(identifier) else { return false }
            installed.insert(identifier)
            return true
        }
        guard shouldProceed else {
            IntemptLogger.shared.log(.debug, "already swizzled: \(identifier)")
            return nil
        }

        guard let originalMethod = class_getInstanceMethod(cls, original),
            let replacementMethod = class_getInstanceMethod(cls, replacement)
        else {
            lock.write { installed.remove(identifier) }
            IntemptLogger.shared.log(.warning, "cannot swizzle missing method: \(identifier)")
            return nil
        }

        let originalIMP = method_getImplementation(originalMethod)
        let originalTypes = method_getTypeEncoding(originalMethod)

        // Defect 1. If this succeeds the class INHERITED the selector rather
        // than implementing it, and exchanging would have rewritten the
        // SUPERCLASS's implementation — affecting every other subclass in the
        // process, including classes belonging to the host app and to Apple.
        let added = class_addMethod(
            cls, original,
            method_getImplementation(replacementMethod),
            method_getTypeEncoding(replacementMethod))

        if added {
            // The class now owns `original` with the hook's implementation.
            // Point the REPLACEMENT selector at the inherited implementation so
            // the hook's `intempt_foo()` self-call still reaches the original
            // behaviour. Without this the hook's call to itself recurses
            // infinitely on any class that inherited the method.
            let replacementIMP = method_getImplementation(replacementMethod)
            let replacementTypes = method_getTypeEncoding(replacementMethod)
            class_replaceMethod(cls, replacement, originalIMP, originalTypes)
            return Token(
                className: NSStringFromClass(cls), selector: original,
                didExchange: false, originalIMP: originalIMP, typeEncoding: originalTypes,
                replacementIMP: replacementIMP, replacementTypeEncoding: replacementTypes,
                replacementSelector: replacement)
        }

        method_exchangeImplementations(originalMethod, replacementMethod)
        return Token(
            className: NSStringFromClass(cls), selector: original,
            didExchange: true, originalIMP: originalIMP, typeEncoding: originalTypes,
            replacementIMP: nil, replacementTypeEncoding: nil, replacementSelector: nil)
    }

    /// Restores the original implementation.
    @discardableResult
    static func remove(_ token: Token, replacement: Selector) -> Bool {
        guard let cls = NSClassFromString(token.className) else { return false }
        let identifier = key(cls, token.selector)

        let wasInstalled: Bool = lock.write {
            guard installed.contains(identifier) else { return false }
            installed.remove(identifier)
            return true
        }
        guard wasInstalled else { return false }

        guard token.didExchange else {
            // `class_addMethod` cannot be un-added — the method now exists on
            // this class forever. Restoring the original IMP in place is the
            // correct undo: the class keeps a method that behaves exactly as
            // the inherited one did. Treating this case as a no-op, as an
            // earlier version did, left the hook permanently installed and made
            // "stop autocapture" a lie.
            guard let originalIMP = token.originalIMP else { return false }
            class_replaceMethod(cls, token.selector, originalIMP, token.typeEncoding)
            // Put the hook's own implementation back on the replacement
            // selector. Skipping this leaves BOTH selectors pointing at the
            // original, so a later re-install exchanges original-with-original
            // and hooks nothing while reporting success.
            if let replacementIMP = token.replacementIMP,
                let replacementSelector = token.replacementSelector
            {
                class_replaceMethod(
                    cls, replacementSelector, replacementIMP, token.replacementTypeEncoding)
            }
            return true
        }

        guard let originalMethod = class_getInstanceMethod(cls, token.selector),
            let replacementMethod = class_getInstanceMethod(cls, replacement)
        else { return false }

        // Exchanging a second time is precisely what restores the original.
        method_exchangeImplementations(originalMethod, replacementMethod)
        return true
    }

    /// Test seam — forgets bookkeeping without touching the runtime.
    static func forgetAll() {
        lock.write { installed.removeAll() }
    }

    static var installedCount: Int { lock.read { installed.count } }
}
