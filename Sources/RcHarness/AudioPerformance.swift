import Foundation
import os

/// Wall-clock intervals include queue/lock waits, which CPU samples alone miss.
/// Only slow completed calls enter the bounded metadata log; open intervals
/// remain visible in Instruments while a HAL call is still blocked.
enum AudioPerformance {
    private static let signposter = OSSignposter(logHandle: OSLog(subsystem: "vip.tokenzz.rcharness", category: .pointsOfInterest))
    private static let slowCallNanoseconds: UInt64 = 50_000_000

    static func measure<T>(_ operation: StaticString, _ body: () throws -> T) rethrows -> T {
        try interval(operation, id: signposter.makeSignpostID(), operation: operation, body)
    }

    static func sync<T>(on queue: DispatchQueue, operation: StaticString, _ body: () throws -> T) rethrows -> T {
        let id = signposter.makeSignpostID()
        return try interval("Playback.call", id: id, operation: operation) {
            try queue.sync {
                try interval("Playback.work", id: id, operation: operation, body)
            }
        }
    }

    private static func interval<T>(_ name: StaticString, id: OSSignpostID, operation: StaticString,
                                    _ body: () throws -> T) rethrows -> T {
        let main = Thread.isMainThread
        let state = signposter.beginInterval(name, id: id, "operation=\(operation.description, privacy: .public) main=\(main)")
        let start = DispatchTime.now().uptimeNanoseconds
        defer {
            let elapsed = DispatchTime.now().uptimeNanoseconds - start
            signposter.endInterval(name, state)
            if elapsed >= slowCallNanoseconds {
                AudioDiagnostics.log("[RcHarness] audio latency operation=\(operation) interval=\(name) main=\(main) elapsed_ms=\(Double(elapsed) / 1_000_000)")
            }
        }
        return try body()
    }
}
