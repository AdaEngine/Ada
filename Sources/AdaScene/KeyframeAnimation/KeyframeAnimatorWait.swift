//
//  KeyframeAnimatorWait.swift
//  AdaScene
//

import AdaECS
import AdaUtils
import Foundation

/// Internal helper that bridges an ``EventManager`` subscription to a single
/// `CheckedContinuation`. Resumes exactly once when a matching
/// ``KeyframeAnimatorRunDidFinish`` event arrives.
///
/// Kept in a separate file so the `Foundation` import (needed for `NSLock`)
/// does not collide with ``AdaUtils/TimeInterval`` in
/// `KeyframeAnimator.swift`.
@usableFromInline
enum KeyframeAnimatorWaitOnce {
    @usableFromInline
    static func wait(entityID: Entity.ID, runToken: UInt64) async {
        let box = OnceBox()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let cancellable = EventManager.default.subscribe(to: KeyframeAnimatorRunDidFinish.self) { event in
                guard event.entityID == entityID, event.runToken == runToken else {
                    return
                }
                if box.fire() {
                    cont.resume()
                }
            }
            box.store(cancellable)
        }
    }
}

/// Thread-safe "fire once" gate with an owned ``Cancellable``.
/// Resuming a `CheckedContinuation` more than once traps, so the gate
/// enforces single-shot semantics; the cancellable is released the moment the
/// gate fires so the event subscription does not outlive the waiter.
@usableFromInline
final class OnceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var didFire = false
    private var cancellable: (any Cancellable)?

    @usableFromInline
    init() {}

    @usableFromInline
    func store(_ cancellable: any Cancellable) {
        lock.lock()
        defer { lock.unlock() }
        if didFire {
            cancellable.cancel()
        } else {
            self.cancellable = cancellable
        }
    }

    @usableFromInline
    func fire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if didFire {
            return false
        }
        didFire = true
        if let cancellable {
            cancellable.cancel()
            self.cancellable = nil
        }
        return true
    }
}
