import Foundation
import os

final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = OSAllocatedUnfairLock()

    init(_ value: Value) {
        self.value = value
    }

    func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}

/// Boxes a value whose type is immutable and thread-safe but not annotated `Sendable`
/// (CoreText / CoreGraphics objects).
struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// Waits until `task` finishes, but at most `timeout`. The task goes on either way.
func waitForCompletion<Success: Sendable>(of task: Task<Success, Never>, timeout: Duration) async {
    let resumed = Locked(false)
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        @Sendable func resume() {
            let first = resumed.withLock { resumed in
                defer { resumed = true }
                return !resumed
            }
            if first { continuation.resume() }
        }
        let timer = Task {
            try? await Task.sleep(for: timeout)
            resume()
        }
        Task {
            _ = await task.value
            timer.cancel()
            resume()
        }
    }
}
