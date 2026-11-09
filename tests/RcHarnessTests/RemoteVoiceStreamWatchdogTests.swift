import XCTest
@testable import RcHarness

@MainActor
final class RemoteVoiceStreamWatchdogTests: XCTestCase {
    func testMissingStopReleasesGoogleShortcutAfterDrainingItsAudio() {
        let clock = TestClock(), output = Output()
        var edges: [Bool] = []
        let session = RemoteVoiceSessionController(output: output, schedule: clock.schedule, logger: { _ in }) {
            _, down in edges.append(down)
        }
        let voice = XiaomiRemoteVoice(profile: RemoteProfiles.googleG9N9N,
            schedule: clock.schedule, now: { clock.time })
        var buttonEdges: [Bool] = []
        voice.onVoiceButtonInput = { down in
            buttonEdges.append(down)
            if down { session.press(mapping: ButtonMapping(action: .fn), fnTap: false) }
            else { session.release() }
        }
        voice.onStreamEvent = { session.handle($0) }
        voice.startStream(session: 7)
        session.append([1, 2, 3])
        clock.advance(RemoteVoiceStreamWatchdog.idleTimeout - 0.01)
        XCTAssertEqual(edges, [true])
        clock.advance(0.01)
        XCTAssertEqual(buttonEdges, [true, false])
        XCTAssertEqual(output.ends, 1)
        XCTAssertEqual(edges, [true], "Retain the shortcut until the received tail finishes playing")
        output.finishDrain()
        XCTAssertEqual(edges, [true, false])
        clock.advance(200)
        XCTAssertEqual(edges, [true, false], "The total deadline cannot release the same key twice")
    }

    func testXiaomiHoldKeepsUsingItsIndependentHIDRelease() {
        let clock = TestClock()
        let voice = XiaomiRemoteVoice(profile: RemoteProfiles.xiaomiRC003,
            schedule: clock.schedule, now: { clock.time })
        var ends = 0
        voice.onStreamEvent = { if case .ended = $0 { ends += 1 } }
        voice.startStream(session: 8)
        clock.advance(RemoteVoiceStreamWatchdog.maximumDuration + 1)
        XCTAssertEqual(ends, 0, "The BLE-only watchdog must not change Xiaomi's HID-controlled hold")
        voice.cancelActiveStream()
    }

    func testAudioRefreshesIdleDeadlineButCannotExtendTotalDuration() {
        let clock = TestClock()
        var expiries: [RemoteVoiceStreamWatchdog.Expiry] = []
        let watchdog = RemoteVoiceStreamWatchdog(schedule: clock.schedule) { expiries.append($0) }
        watchdog.start()
        for _ in 0..<Int(RemoteVoiceStreamWatchdog.maximumDuration) - 1 {
            clock.advance(1)
            watchdog.receivedAudio()
            XCTAssertTrue(expiries.isEmpty)
        }
        clock.advance(1)
        XCTAssertEqual(expiries, [.duration])
    }

    func testNormalStopAndReplacementInvalidateOldDeadlines() {
        let clock = TestClock()
        var expiries: [RemoteVoiceStreamWatchdog.Expiry] = []
        let watchdog = RemoteVoiceStreamWatchdog(schedule: clock.schedule) { expiries.append($0) }
        watchdog.start()
        clock.advance(1)
        watchdog.stop()
        clock.advance(200)
        XCTAssertTrue(expiries.isEmpty)
        watchdog.start()
        clock.advance(1)
        watchdog.start()
        clock.advance(1.5)
        XCTAssertTrue(expiries.isEmpty, "The replaced stream's idle deadline must be ignored")
        clock.advance(0.5)
        XCTAssertEqual(expiries, [.idle])
        watchdog.receivedAudio()
        clock.advance(200)
        XCTAssertEqual(expiries, [.idle], "Late packets cannot arm a stopped watchdog")
    }

    private final class Output: RemoteVoiceAudioOutput {
        var ends = 0
        var completion: (() -> Void)?
        func prepareForPress() {}
        func begin() {}
        func append(_ pcm: [Int16]) {}
        func end() { ends += 1 }
        func stop() { finishDrain() }
        func releaseWhenFinished(completion: @escaping () -> Void) { self.completion = completion }
        func finishDrain() {
            let callback = completion
            completion = nil
            callback?()
        }
    }
}
