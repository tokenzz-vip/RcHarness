import Foundation
@testable import RcHarness

/// Deterministic scheduler for controllers that take a
/// `RemoteVoiceSessionController.Scheduler`; time only moves via `advance`.
final class TestClock {
    private var now: TimeInterval = 0
    var time: TimeInterval { now }
    private var tasks: [(TimeInterval, DispatchWorkItem)] = []

    func schedule(after delay: TimeInterval, operation: @escaping () -> Void) -> DispatchWorkItem {
        let work = DispatchWorkItem(block: operation)
        tasks.append((now + delay, work))
        return work
    }

    func advance(_ duration: TimeInterval) {
        let end = now + duration
        while let task = tasks.filter({ $0.0 <= end + 0.000001 }).min(by: { $0.0 < $1.0 }) {
            tasks.removeAll { $0.1 === task.1 }
            now = task.0
            if !task.1.isCancelled { task.1.perform() }
        }
        now = end
    }
}
