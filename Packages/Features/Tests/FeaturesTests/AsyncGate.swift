import Foundation

/// A reusable async gate: `wait()` suspends until `open()` is called.
///
/// Cancellation-aware, and that is the point of it (#212): cancelling a task
/// parked in `wait()` resumes that waiter — alone — by throwing
/// `CancellationError`, exactly as a cancelled `URLSession` request unwinds
/// in production. Without this, a mock hook parked here turns
/// `Task.cancel()` into a no-op and any code that cancels-then-awaits its
/// predecessor deadlocks against the very gate the test is holding.
///
/// The two spellings at a call site are both deliberate:
/// - `try await gate.wait()` — the cancel kills the request mid-flight; the
///   caller unwinds through its `catch`/guards like a torn-down network call.
/// - `try? await gate.wait()` — the request survives the cancel and
///   completes anyway; the caller must discard the result at its own
///   supersede guards. This is the only way to exercise paths that clean up
///   after a request that lost the race but still landed.
actor AsyncGate {
    private var isOpen = false
    private var nextID = 0
    private var waiters: [Int: CheckedContinuation<Void, any Error>] = [:]
    private var cancelledIDs: Set<Int> = []

    func wait() async throws {
        if isOpen {
            return
        }
        let id = nextID
        nextID += 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                register(id: id, continuation: continuation)
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: id) }
        }
    }

    func open() {
        isOpen = true
        for continuation in waiters.values {
            continuation.resume()
        }
        waiters.removeAll()
    }

    /// Runs synchronously inside the actor from `wait()`, but a cancellation
    /// that fired before the continuation landed here must still win — hence
    /// the `cancelledIDs` check rather than assuming registration came first.
    private func register(id: Int, continuation: CheckedContinuation<Void, any Error>) {
        if cancelledIDs.remove(id) != nil {
            continuation.resume(throwing: CancellationError())
        } else if isOpen {
            continuation.resume()
        } else {
            waiters[id] = continuation
        }
    }

    private func cancelWaiter(id: Int) {
        if let continuation = waiters.removeValue(forKey: id) {
            continuation.resume(throwing: CancellationError())
        } else {
            cancelledIDs.insert(id)
        }
    }
}
