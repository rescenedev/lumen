import Foundation

/// Cross-lane in-flight decode dedupe. The display, viewport-prefetch, and
/// warming lanes each decode originals independently; on a cold cache they
/// could issue up to three simultaneous multi-MB reads of the SAME file.
/// The first caller for a key becomes the owner and decodes; concurrent
/// callers block (bounded) until the owner finishes, then serve themselves
/// from the memory/disk cache the owner just filled.
///
/// Ownership contract: only a caller that got `true` may call `release(_:)`.
/// A timed-out waiter proceeds without ownership (duplicate decode — rare,
/// harmless) and must NOT release the key.
final class DecodeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [String: [DispatchSemaphore]] = [:]

    /// True → caller owns the decode for `key`. False → an owner was already
    /// in flight and has since finished (or `timeout` elapsed); re-check the
    /// caches before doing any work.
    func acquireOrWait(_ key: String, timeout: TimeInterval = 30) -> Bool {
        lock.lock()
        if waiters[key] == nil {
            waiters[key] = []
            lock.unlock()
            return true
        }
        let sem = DispatchSemaphore(value: 0)
        waiters[key]?.append(sem)
        lock.unlock()
        _ = sem.wait(timeout: .now() + timeout)
        return false
    }

    func release(_ key: String) {
        lock.lock()
        let pending = waiters.removeValue(forKey: key) ?? []
        lock.unlock()
        for sem in pending { sem.signal() }
    }
}

/// Suspends background warming for as long as user-facing thumbnail work is
/// in flight (plus a short trailing grace), instead of a fixed one-shot pause.
/// `begin()`/`end()` bracket each display/viewport decode; `touch()` is the
/// legacy "user opened a folder" nudge with no matching end.
final class BrowsingActivityGate: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private var resumeWork: DispatchWorkItem?
    private let grace: TimeInterval
    private let queue: DispatchQueue
    private let setSuspended: (Bool) -> Void

    /// `setSuspended` is called with the lock held — it must not call back
    /// into this gate (in practice it just flips `OperationQueue.isSuspended`).
    init(grace: TimeInterval = 2.5,
         queue: DispatchQueue = DispatchQueue(label: "lumen.browsing-gate"),
         setSuspended: @escaping (Bool) -> Void) {
        self.grace = grace
        self.queue = queue
        self.setSuspended = setSuspended
    }

    func begin() {
        lock.lock()
        active += 1
        resumeWork?.cancel()
        resumeWork = nil
        setSuspended(true)
        lock.unlock()
    }

    func end() {
        lock.lock()
        active = max(0, active - 1)
        if active == 0 { scheduleResumeLocked() }
        lock.unlock()
    }

    /// Suspend now and auto-resume after the grace period if no bracketed
    /// work is (or becomes) active.
    func touch() {
        lock.lock()
        setSuspended(true)
        if active == 0 { scheduleResumeLocked() }
        lock.unlock()
    }

    private func scheduleResumeLocked() {
        resumeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock()
            if self.active == 0 { self.setSuspended(false) }
            self.lock.unlock()
        }
        resumeWork = work
        queue.asyncAfter(deadline: .now() + grace, execute: work)
    }
}
