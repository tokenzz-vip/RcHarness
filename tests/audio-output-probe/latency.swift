import Foundation

/// Exercises real HAL calls on the main thread, without keys or live speech.
/// This is a hardware probe, not a unit test with synthetic scheduler time.
@MainActor
func runAudioLatencyProbe() -> Int32 {
    var measurements: [String: [Double]] = [:]
    var failures = 0
    func timed<T>(_ operation: String, _ body: () throws -> T) rethrows -> T {
        let start = DispatchTime.now().uptimeNanoseconds
        defer {
            let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            measurements[operation, default: []].append(ms)
        }
        return try body()
    }

    for attempt in 1...12 {
        // Force actual enumeration, then measure the warm snapshot separately.
        _ = timed("catalog.reload") { AudioDeviceCatalog.shared.reload() }
        _ = timed("catalog.cached") { AudioDeviceCatalog.shared.devices() }
        do {
            let playback = try CoreAudioRemoteMicrophonePlayback(outputUID: RemoteMicrophoneOutput.deviceUID)
            defer { timed("playback.stop.cleanup") { playback.stop() } }
            var prepared: Result<Void, Error>?
            playback.prepare { prepared = $0 }
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            while prepared == nil, ProcessInfo.processInfo.systemUptime < deadline { pump(0.01) }
            guard let prepared else {
                failures += 1
                print("FAIL latency session=\(attempt): preparation timeout")
                continue
            }
            try prepared.get()
            guard timed("playback.isReady", { playback.isReady }),
                  !timed("playback.isInterrupted", { playback.isInterrupted }) else {
                failures += 1
                print("FAIL latency session=\(attempt): graph not healthy")
                continue
            }
            try timed("playback.flush") { try playback.flush() }
            // Four seconds of silence in four buffers, stopped while still
            // pending. The production output also caps in-flight buffers at 4.
            for _ in 0..<4 {
                let accepted = timed("playback.schedule") {
                    playback.schedule(Array(repeating: 0, count: 16_000), completion: {})
                }
                if !accepted {
                    failures += 1
                    print("FAIL latency session=\(attempt): schedule rejected")
                    break
                }
            }
            timed("playback.stop.pending") { playback.stop() }
        } catch {
            failures += 1
            print("FAIL latency session=\(attempt): \(error.localizedDescription)")
        }
        pump(0.05)
    }

    print("Main-thread wall time (ms); 50 ms is a measurement budget, not proof of a HAL fault:")
    for operation in measurements.keys.sorted() {
        let values = measurements[operation]!.sorted()
        let p95 = values[Int(ceil(Double(values.count) * 0.95)) - 1]
        let slow = values.filter { $0 >= 50 }.count
        print(String(format: "%@ n=%d p50=%.3f p95=%.3f max=%.3f over_50ms=%d",
                     operation, values.count, values[(values.count - 1) / 2], p95, values.last!, slow))
        if slow > 0 { failures += 1 }
    }
    print("\(failures == 0 ? "PASS" : "FAIL"): latency budget / functional failures=\(failures)")
    return failures == 0 ? 0 : 1
}
