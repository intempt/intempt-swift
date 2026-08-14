import Foundation
import XCTest

@testable import Intempt

// MARK: - Fixtures
//
// Real Objective-C classes, so the runtime behaviour under test is the real
// runtime behaviour. `@objc dynamic` is required: without `dynamic` the
// compiler may devirtualise the call and the swizzle silently does nothing —
// which is itself a defect worth having fixtures prove.

class SwizzleBase: NSObject {
    @objc dynamic func greet() -> String { "base" }
    @objc dynamic func inherited() -> String { "from-base" }
}

/// Implements `greet` itself → swizzling must EXCHANGE.
class SwizzleOwner: SwizzleBase {
    @objc dynamic override func greet() -> String { "owner" }
}

/// Do NOT implement `inherited` → swizzling must ADD, never exchange, or the
/// superclass implementation is rewritten for every sibling subclass.
///
/// One class per test on purpose. `class_addMethod` permanently gives the class
/// its own implementation, so a class that has been through the added path once
/// is no longer an inheritor and the next test would silently exercise the
/// exchange path instead. Sharing a fixture here made this suite pass or fail
/// depending on alphabetical test order.
class SwizzleInheritorA: SwizzleBase {}
class SwizzleInheritorB: SwizzleBase {}
class SwizzleInheritorC: SwizzleBase {}

/// A second subclass, used to prove the superclass was left intact.
class SwizzleSibling: SwizzleBase {}

extension SwizzleOwner {
    @objc dynamic func intempt_greet() -> String {
        // After the exchange this call reaches the ORIGINAL implementation.
        "hooked+" + intempt_greet()
    }
}

extension SwizzleInheritorA {
    @objc dynamic func intempt_inherited() -> String { "hooked-A+" + intempt_inherited() }
}
extension SwizzleInheritorB {
    @objc dynamic func intempt_inherited() -> String { "hooked-B" }
}
extension SwizzleInheritorC {
    @objc dynamic func intempt_inherited() -> String { "hooked-C" }
}

final class MethodSwizzlerTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MethodSwizzler.forgetAll()
    }

    override func tearDown() {
        MethodSwizzler.forgetAll()
        super.tearDown()
    }

    // MARK: - Exchange path

    func testSwizzleInterceptsAndStillCallsTheOriginal() {
        XCTAssertEqual(SwizzleOwner().greet(), "owner")

        let token = MethodSwizzler.swizzle(
            class: SwizzleOwner.self,
            original: #selector(SwizzleBase.greet),
            replacement: #selector(SwizzleOwner.intempt_greet))
        XCTAssertNotNil(token)
        XCTAssertTrue(token!.didExchange, "the class implements greet, so it must exchange")

        XCTAssertEqual(
            SwizzleOwner().greet(), "hooked+owner",
            "the hook must run AND the original must still be reached")

        MethodSwizzler.remove(token!, replacement: #selector(SwizzleOwner.intempt_greet))
    }

    func testRemoveRestoresTheOriginal() {
        let token = MethodSwizzler.swizzle(
            class: SwizzleOwner.self,
            original: #selector(SwizzleBase.greet),
            replacement: #selector(SwizzleOwner.intempt_greet))!
        XCTAssertEqual(SwizzleOwner().greet(), "hooked+owner")

        XCTAssertTrue(
            MethodSwizzler.remove(token, replacement: #selector(SwizzleOwner.intempt_greet)))
        XCTAssertEqual(SwizzleOwner().greet(), "owner", "the hook must be fully undone")
    }

    // MARK: - Double-swizzle guard

    /// A second exchange of the same pair restores the original — so an SDK
    /// that swizzles twice silently DISABLES its own autocapture. The old
    /// Objective-C SDK had no guard against this.
    func testSwizzlingTwiceIsRefusedRatherThanUnswizzling() {
        let first = MethodSwizzler.swizzle(
            class: SwizzleOwner.self,
            original: #selector(SwizzleBase.greet),
            replacement: #selector(SwizzleOwner.intempt_greet))
        XCTAssertNotNil(first)
        XCTAssertEqual(SwizzleOwner().greet(), "hooked+owner")

        let second = MethodSwizzler.swizzle(
            class: SwizzleOwner.self,
            original: #selector(SwizzleBase.greet),
            replacement: #selector(SwizzleOwner.intempt_greet))
        XCTAssertNil(second, "a second swizzle must be refused")
        XCTAssertEqual(
            SwizzleOwner().greet(), "hooked+owner",
            "the hook must survive; a second exchange would have removed it")

        MethodSwizzler.remove(first!, replacement: #selector(SwizzleOwner.intempt_greet))
    }

    func testIsSwizzledReflectsState() {
        let selector = #selector(SwizzleBase.greet)
        XCTAssertFalse(MethodSwizzler.isSwizzled(SwizzleOwner.self, selector))

        let token = MethodSwizzler.swizzle(
            class: SwizzleOwner.self, original: selector,
            replacement: #selector(SwizzleOwner.intempt_greet))!
        XCTAssertTrue(MethodSwizzler.isSwizzled(SwizzleOwner.self, selector))

        MethodSwizzler.remove(token, replacement: #selector(SwizzleOwner.intempt_greet))
        XCTAssertFalse(MethodSwizzler.isSwizzled(SwizzleOwner.self, selector))
    }

    // MARK: - Inherited methods (the F-11 regression)

    /// The important one. `SwizzleInheritor` does not implement `inherited`.
    /// `method_exchangeImplementations` on it would rewrite `SwizzleBase`'s
    /// implementation — breaking every OTHER subclass, including the host
    /// app's classes and Apple's. `class_addMethod` must be used instead.
    func testSwizzlingAnInheritedMethodDoesNotCorruptTheSuperclass() {
        XCTAssertEqual(SwizzleSibling().inherited(), "from-base")
        XCTAssertEqual(SwizzleBase().inherited(), "from-base")

        let token = MethodSwizzler.swizzle(
            class: SwizzleInheritorA.self,
            original: #selector(SwizzleBase.inherited),
            replacement: #selector(SwizzleInheritorA.intempt_inherited))
        XCTAssertNotNil(token)
        XCTAssertFalse(
            token!.didExchange,
            "an inherited method must be ADDED to the subclass, never exchanged")

        // The hook runs AND reaches the inherited implementation. That only
        // works because the replacement selector is repointed at the original
        // IMP; without it this call recurses until the stack dies.
        XCTAssertEqual(SwizzleInheritorA().inherited(), "hooked-A+from-base")
        XCTAssertEqual(
            SwizzleSibling().inherited(), "from-base",
            "a sibling subclass must be untouched")
        XCTAssertEqual(
            SwizzleBase().inherited(), "from-base",
            "the superclass implementation must be untouched")

        MethodSwizzler.remove(token!, replacement: #selector(SwizzleInheritorA.intempt_inherited))
    }

    /// Removing an ADDED hook must genuinely restore the original behaviour.
    ///
    /// `class_addMethod` cannot be un-added, so an earlier version treated this
    /// case as a no-op and returned true. That left the hook permanently
    /// installed while reporting success — "stop autocapture" did nothing.
    /// Restoring the original IMP in place is the real undo.
    func testRemovingAnAddedHookRestoresTheOriginalBehaviour() {
        let token = MethodSwizzler.swizzle(
            class: SwizzleInheritorB.self,
            original: #selector(SwizzleBase.inherited),
            replacement: #selector(SwizzleInheritorB.intempt_inherited))!
        XCTAssertEqual(SwizzleInheritorB().inherited(), "hooked-B")

        XCTAssertTrue(
            MethodSwizzler.remove(
                token, replacement: #selector(SwizzleInheritorB.intempt_inherited)))

        XCTAssertEqual(
            SwizzleInheritorB().inherited(), "from-base",
            "the hook must be genuinely gone, not merely forgotten")
        XCTAssertEqual(SwizzleSibling().inherited(), "from-base")
        XCTAssertEqual(SwizzleBase().inherited(), "from-base")
    }

    /// After removal the pair must be hookable again.
    func testAnAddedHookCanBeReinstalledAfterRemoval() {
        let first = MethodSwizzler.swizzle(
            class: SwizzleInheritorC.self,
            original: #selector(SwizzleBase.inherited),
            replacement: #selector(SwizzleInheritorC.intempt_inherited))!
        MethodSwizzler.remove(first, replacement: #selector(SwizzleInheritorC.intempt_inherited))
        XCTAssertEqual(SwizzleInheritorC().inherited(), "from-base")

        let second = MethodSwizzler.swizzle(
            class: SwizzleInheritorC.self,
            original: #selector(SwizzleBase.inherited),
            replacement: #selector(SwizzleInheritorC.intempt_inherited))
        XCTAssertNotNil(second, "the pair must be hookable again after removal")
        XCTAssertEqual(SwizzleInheritorC().inherited(), "hooked-C")

        MethodSwizzler.remove(second!, replacement: #selector(SwizzleInheritorC.intempt_inherited))
    }

    // MARK: - Failure handling

    func testSwizzlingAMissingSelectorFailsCleanly() {
        let token = MethodSwizzler.swizzle(
            class: SwizzleOwner.self,
            original: NSSelectorFromString("noSuchMethodExists"),
            replacement: #selector(SwizzleOwner.intempt_greet))

        XCTAssertNil(token)
        XCTAssertEqual(
            MethodSwizzler.installedCount, 0,
            "a failed swizzle must not leave bookkeeping behind, or the pair can never be hooked")
    }

    func testRemovingAnUnknownTokenIsFalseNotACrash() {
        let bogus = MethodSwizzler.Token(
            className: "SwizzleOwner", selector: #selector(SwizzleBase.greet),
            didExchange: true, originalIMP: nil, typeEncoding: nil,
            replacementIMP: nil, replacementTypeEncoding: nil, replacementSelector: nil)
        XCTAssertFalse(MethodSwizzler.remove(bogus, replacement: #selector(SwizzleOwner.intempt_greet)))
    }

    func testRemovingATokenForAnUnloadableClassIsFalse() {
        let bogus = MethodSwizzler.Token(
            className: "NoSuchClassAnywhere", selector: #selector(SwizzleBase.greet),
            didExchange: true, originalIMP: nil, typeEncoding: nil,
            replacementIMP: nil, replacementTypeEncoding: nil, replacementSelector: nil)
        XCTAssertFalse(MethodSwizzler.remove(bogus, replacement: #selector(SwizzleOwner.intempt_greet)))
    }

    // MARK: - Concurrency

    /// Two threads racing to install the same hook must produce exactly one.
    /// Without the guard both exchange, the second undoes the first, and
    /// autocapture is off with no error anywhere.
    func testConcurrentSwizzleAttemptsInstallExactlyOne() {
        let attempts = 50
        let group = DispatchGroup()
        let resultLock = NSLock()
        var tokens: [MethodSwizzler.Token] = []

        for _ in 0..<attempts {
            group.enter()
            DispatchQueue.global().async {
                if let token = MethodSwizzler.swizzle(
                    class: SwizzleOwner.self,
                    original: #selector(SwizzleBase.greet),
                    replacement: #selector(SwizzleOwner.intempt_greet))
                {
                    resultLock.lock()
                    tokens.append(token)
                    resultLock.unlock()
                }
                group.leave()
            }
        }
        group.wait()

        XCTAssertEqual(tokens.count, 1, "exactly one of \(attempts) attempts may install the hook")
        XCTAssertEqual(SwizzleOwner().greet(), "hooked+owner")

        MethodSwizzler.remove(tokens[0], replacement: #selector(SwizzleOwner.intempt_greet))
        XCTAssertEqual(SwizzleOwner().greet(), "owner")
    }
}
