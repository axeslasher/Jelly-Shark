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
    private var arrivalCount = 0
    private var nextArrivalID = 0
    private var arrivalWaiters: [Int: (count: Int, continuation: CheckedContinuation<Void, Never>)] = [:]
    private var cancelledArrivalIDs: Set<Int> = []

    /// Suspends until at least `count` callers have parked here, so a test
    /// can act once work has provably reached the gate instead of sleeping
    /// and hoping it has. Only parked callers count: once the gate is open,
    /// `wait()` returns at once and never arrives.
    ///
    /// Cancellation returns early, so a test whose count is never reached
    /// ends at its time limit instead of leaving its task parked here.
    func arrivals(atLeast count: Int) async {
        if arrivalCount >= count {
            return
        }
        let id = nextArrivalID
        nextArrivalID += 1
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                registerArrivalWaiter(id: id, count: count, continuation: continuation)
            }
        } onCancel: {
            Task { await self.cancelArrivalWaiter(id: id) }
        }
    }

    private func arrive() {
        arrivalCount += 1
        for (id, waiter) in arrivalWaiters where waiter.count <= arrivalCount {
            arrivalWaiters[id] = nil
            waiter.continuation.resume()
        }
    }

    /// Same race as `register(id:continuation:)`: a cancel can land first.
    private func registerArrivalWaiter(id: Int, count: Int, continuation: CheckedContinuation<Void, Never>) {
        if cancelledArrivalIDs.remove(id) != nil || arrivalCount >= count {
            continuation.resume()
        } else {
            arrivalWaiters[id] = (count, continuation)
        }
    }

    private func cancelArrivalWaiter(id: Int) {
        if let waiter = arrivalWaiters.removeValue(forKey: id) {
            waiter.continuation.resume()
        } else {
            cancelledArrivalIDs.insert(id)
        }
    }

    func wait() async throws {
        if isOpen {
            return
        }
        arrive()
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
        for continuation in cancelImmuneWaiters {
            continuation.resume()
        }
        cancelImmuneWaiters.removeAll()
    }

    private var cancelImmuneWaiters: [CheckedContinuation<Void, Never>] = []

    /// Park ignoring cancellation — models a request that has not yet
    /// noticed the cancel and is still genuinely in flight, so anything
    /// serialized behind its build stays pending until the test decides.
    /// The caller MUST eventually `open()` this gate: nothing else can
    /// resume this waiter, which is exactly the property tests use it for —
    /// and exactly why production code must never park like this (#212).
    func waitIgnoringCancellation() async {
        if isOpen {
            return
        }
        arrive()
        await withCheckedContinuation { cancelImmuneWaiters.append($0) }
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
