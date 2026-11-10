import Foundation
import CoreGraphics
import XCTest
@testable import RcHarness

@MainActor
final class VoiceSessionTests: XCTestCase {
    private let fn = ButtonMapping(action: .fn)

    func testToggleIgnoresPhysicalReleaseAndBLEStopUntilNextRemotePress() {
        let h = VoiceHarness()
        let mapping = ButtonMapping(action: .recordedShortcut, shortcut: .voiceTapDefault)
        h.controller.press(mapping: mapping, fnTap: false, toggle: true)
        h.controller.release()
        h.controller.handle(.started)
        h.controller.append([1, 2, 3])
        h.clock.advance(0.28)
        XCTAssertEqual(h.edges, [true, false])
        h.controller.handle(.ended)
        h.output.completeDrain()
        XCTAssertEqual(h.edges, [true, false], "A remote release/STOP must not simulate the stop shortcut")
        XCTAssertTrue(h.controller.finishToggle())
        XCTAssertFalse(h.controller.finishToggle(), "The stop press must be consumed once")
        h.clock.advance(0.12)
        XCTAssertEqual(h.edges, [true, false, true, false])
        XCTAssertEqual(h.output.packets, [[1, 2, 3]])
    }

    func testToggleStopDuringStartupDrainsBufferedSpeechAndPairsShortcut() {
        let h = VoiceHarness()
        h.controller.press(mapping: ButtonMapping(action: .recordedShortcut, shortcut: .voiceTapDefault), fnTap: false, toggle: true)
        h.controller.release()
        h.controller.handle(.started)
        h.controller.append([4, 5])
        XCTAssertTrue(h.controller.finishToggle())
        h.clock.advance(0.28)
        XCTAssertEqual(h.output.packets, [[4, 5]])
        h.output.completeDrain()
        h.clock.advance(0.12)
        XCTAssertEqual(h.edges, [true, false, true, false])
    }

    func testShortPressStartsWithoutWaitingForBLEAndClosesAfterPlayback() {
        let h = VoiceHarness()
        h.controller.press(mapping: fn, fnTap: true)
        XCTAssertEqual(h.edges, [true], "HID alone must start the target, even when BLE START is late")
        h.controller.release()
        h.clock.advance(0.119)
        XCTAssertEqual(h.edges, [true])
        h.clock.advance(0.001)
        XCTAssertEqual(h.edges, [true, false])
        h.controller.handle(.started)
        h.controller.append([1, 2, 3])
        XCTAssertTrue(h.output.packets.isEmpty, "Keep first speech while the target starts")
        h.controller.handle(.ended)
        h.clock.advance(0.15)
        XCTAssertEqual(h.output.packets, [[1, 2, 3]])
        XCTAssertEqual(h.output.ends, 1)
        h.output.completeDrain()
        XCTAssertEqual(h.edges, [true, false, true])
        h.clock.advance(0.12)
        XCTAssertEqual(h.edges, [true, false, true, false])
    }

    func testBLEBeforeHIDKeepsFirstAudioAndStillStartsTheTarget() {
        let h = VoiceHarness()
        h.controller.handle(.started)
        h.controller.append([1, 2])
        h.controller.press(mapping: fn, fnTap: true)
        h.controller.append([3])
        h.clock.advance(0.28)
        XCTAssertEqual(h.edges, [true, false])
        XCTAssertEqual(h.output.packets.flatMap { $0 }, [1, 2, 3])
        h.controller.release()
        h.controller.handle(.ended)
        h.output.completeDrain()
        h.clock.advance(0.12)
        XCTAssertEqual(h.edges, [true, false, true, false])
    }

    func testDuplicateHIDEdgesAndBLEStartDoNotCreateExtraTaps() {
        let h = VoiceHarness()
        h.controller.press(mapping: fn, fnTap: true)
        h.controller.press(mapping: fn, fnTap: true)
        h.controller.handle(.started)
        h.controller.handle(.started)
        h.clock.advance(0.28)
        h.controller.release()
        h.controller.release()
        h.controller.handle(.ended)
        h.output.completeDrain()
        h.clock.advance(0.12)
        XCTAssertEqual(h.edges, [true, false, true, false])
        XCTAssertEqual(h.output.begins, 1)
    }

    func testNextPressDuringDrainIsQueuedAndOldCompletionCannotReleaseIt() {
        let h = VoiceHarness()
        h.controller.press(mapping: fn, fnTap: true)
        h.controller.handle(.started)
        h.clock.advance(0.28)
        h.controller.release()
        h.controller.handle(.ended)
        let stale = h.output.releases.first
        let next = ButtonMapping(action: .rightCommand)
        h.controller.press(mapping: next, fnTap: false)
        h.controller.handle(.started)
        h.controller.append([8, 9])
        h.controller.release()
        h.controller.handle(.ended)
        h.output.completeDrain()
        h.clock.advance(0.12)
        XCTAssertEqual(h.keys.map { $0.0 }, [.fn, .fn, .fn, .fn, .rightCommand])
        stale?()
        XCTAssertEqual(h.keys.count, 5)
        XCTAssertEqual(h.output.packets.last, [8, 9])
        h.output.completeDrain()
        XCTAssertEqual(h.keys.last?.0, .rightCommand)
        XCTAssertEqual(h.keys.last?.1, false)
    }

    func testCancelDuringStartTapClosesTheTargetExactlyOnce() {
        let h = VoiceHarness()
        h.controller.press(mapping: fn, fnTap: true)
        h.controller.handle(.started)
        h.clock.advance(0.05)
        h.controller.cancel()
        h.controller.cancel()
        h.controller.append([99])
        h.clock.advance(2)
        XCTAssertEqual(h.edges, [true, false, true, false])
        XCTAssertTrue(h.output.packets.isEmpty)
        let count = h.keys.count
        h.output.completeDrain()
        h.clock.advance(2)
        XCTAssertEqual(h.keys.count, count)
    }

    func testHoldMappingWaitsForTheAudioTailAndCapturesTheOriginalMapping() {
        let h = VoiceHarness()
        h.controller.press(mapping: ButtonMapping(action: .rightCommand), fnTap: false)
        h.controller.handle(.started)
        h.controller.append([1])
        h.controller.release()
        XCTAssertEqual(h.keys.count, 1)
        h.controller.handle(.ended)
        h.output.completeDrain()
        XCTAssertEqual(h.keys.map { $0.0 }, [.rightCommand, .rightCommand])
        XCTAssertEqual(h.edges, [true, false])
    }

    func testCancellationWithoutAStartedTargetDoesNotWakeIt() {
        let h = VoiceHarness()
        h.controller.handle(.started)
        h.controller.append([1])
        h.controller.cancel()
        h.clock.advance(2)
        XCTAssertTrue(h.keys.isEmpty)
        XCTAssertTrue(h.output.packets.isEmpty)
    }

    func testModifierKeysUseRealFlagsChangedEventsWithoutPostingIntoTheSystem() {
        var events: [CGEvent] = []
        let sender = SystemEventSender(postEvent: { events.append($0) })
        for action: RemoteAction in [.fn, .rightCommand, .leftCommand, .leftOption, .rightOption] {
            sender.send(ButtonMapping(action: action), pressed: true)
            sender.send(ButtonMapping(action: action), pressed: false)
        }
        XCTAssertEqual(events.count, 10)
        XCTAssertTrue(events.allSatisfy { $0.type == .flagsChanged })
        XCTAssertTrue(events.first?.flags.contains(.maskSecondaryFn) == true)
        XCTAssertEqual(events[1].flags, [])
        XCTAssertTrue(events[2].flags.contains(.maskCommand))
    }

    func testFnUsesHIDSourceStateWithoutChangingCommandEvents() {
        // The captured, working physical Fn uses source state 1. A nil source
        // uses session state 0, even when posted at the HID event tap.
        var events: [CGEvent] = []
        let sender = SystemEventSender(postEvent: { events.append($0) })
        for action: RemoteAction in [.fn, .rightCommand, .fn] {
            sender.send(ButtonMapping(action: action), pressed: true)
            sender.send(ButtonMapping(action: action), pressed: false)
        }
        XCTAssertEqual(events.count, 6)
        guard events.count == 6 else { return }
        for index in [0, 1, 4, 5] {
            XCTAssertEqual(events[index].type, .flagsChanged)
            XCTAssertEqual(events[index].getIntegerValueField(.keyboardEventKeycode), 63)
            XCTAssertEqual(events[index].getIntegerValueField(.eventSourceStateID),
                           Int64(CGEventSourceStateID.hidSystemState.rawValue))
            XCTAssertEqual(events[index].flags.contains(.maskSecondaryFn), index.isMultiple(of: 2))
        }
        for index in [2, 3] {
            XCTAssertEqual(events[index].getIntegerValueField(.eventSourceStateID),
                           Int64(CGEventSourceStateID.combinedSessionState.rawValue))
        }
    }

    func testVoiceModifiersIdentifyTheSelectedSideForShortcutListeners() {
        // Shortcut listeners can determine down/up from the NX_DEVICE* mask,
        // rather than the shared Command/Option flag, even with a key code.
        let cases: [(RemoteAction, CGKeyCode, CGEventFlags, UInt64)] = [
            (.leftCommand, 0x37, .maskCommand, 0x08),
            (.rightCommand, 0x36, .maskCommand, 0x10),
            (.leftOption, 0x3A, .maskAlternate, 0x20),
            (.rightOption, 0x3D, .maskAlternate, 0x40),
        ]
        for (action, keyCode, sharedFlag, sideFlag) in cases {
            var events: [CGEvent] = []
            let sender = SystemEventSender(postEvent: { events.append($0) })
            sender.send(ButtonMapping(action: action), pressed: true)
            sender.send(ButtonMapping(action: action), pressed: false)
            XCTAssertEqual(events.count, 2)
            guard events.count == 2 else { continue }
            XCTAssertEqual(events.map(\.type), [.flagsChanged, .flagsChanged])
            XCTAssertEqual(events[0].getIntegerValueField(.keyboardEventKeycode), Int64(keyCode))
            XCTAssertTrue(events[0].flags.contains(sharedFlag))
            XCTAssertEqual(events[0].flags.rawValue & 0x78, sideFlag, "\(action) must be recognized as down")
            XCTAssertEqual(events[1].flags.rawValue & 0x78, 0, "\(action) must be recognized as up")
        }
    }

    func testEveryLegalHIDAndBLEOrderingRetainsSpeechAndPairsBothTaps() {
        func interleave(_ a: [Int], _ b: [Int]) -> [[Int]] {
            if a.isEmpty { return [b] }
            if b.isEmpty { return [a] }
            return interleave(Array(a.dropFirst()), b).map { [a[0]] + $0 }
                + interleave(a, Array(b.dropFirst())).map { [b[0]] + $0 }
        }
        let orders = interleave([0, 1], [2, 3, 4])
        XCTAssertEqual(orders.count, 10)
        for order in orders {
            for interval in [0.0, 0.01, 0.13] {
                for fnTap in [false, true] {
                let h = VoiceHarness()
                for event in order {
                    switch event {
                    case 0: h.controller.press(mapping: fn, fnTap: fnTap)
                    case 1: h.controller.release()
                    case 2: h.controller.handle(.started)
                    case 3: h.controller.append([7, 8])
                    case 4: h.controller.handle(.ended)
                    default: break
                    }
                    h.clock.advance(interval)
                }
                h.clock.advance(0.4)
                h.output.completeDrain()
                h.clock.advance(0.4)
                let expectedEdges = fnTap ? [true, false, true, false] : [true, false]
                XCTAssertEqual(h.edges, expectedEdges, "order=\(order) interval=\(interval) tap=\(fnTap)")
                XCTAssertEqual(h.output.packets.flatMap { $0 }, [7, 8], "order=\(order)")
                XCTAssertEqual(h.output.begins, 1)
                XCTAssertEqual(h.output.ends, 1)
                }
            }
        }
    }

    func testSeededEventStressNeverLeavesAKeyDownOrReleasesAnotherMapping() {
        let h = VoiceHarness()
        var seed: UInt64 = 0x52434841524e4553
        for _ in 0..<2000 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            switch (seed >> 32) % 8 {
            case 0: h.controller.press(mapping: fn, fnTap: true)
            case 1: h.controller.press(mapping: ButtonMapping(action: .rightCommand), fnTap: false)
            case 2: h.controller.release()
            case 3: h.controller.handle(.started)
            case 4: h.controller.append([1, 2, 3])
            case 5: h.controller.handle(.ended)
            case 6: h.output.completeDrain()
            default: h.controller.cancel()
            }
            h.clock.advance(Double(seed % 20) / 100)
        }
        h.controller.cancel()
        h.clock.advance(2)
        var held: RemoteAction?
        for (action, down) in h.keys {
            if down {
                XCTAssertNil(held, "No overlapping or duplicate key down")
                held = action
            } else {
                XCTAssertEqual(held, action, "Release the captured original mapping")
                held = nil
            }
        }
        XCTAssertNil(held)
    }

    func testShutdownCompletionWaitsForTheFinalKeyUp() {
        let h = VoiceHarness()
        h.controller.press(mapping: fn, fnTap: true)
        var completed = 0
        h.controller.cancel { completed += 1 }
        h.clock.advance(0.28)
        XCTAssertEqual(completed, 0)
        XCTAssertEqual(h.edges, [true, false, true])
        h.clock.advance(0.12)
        XCTAssertEqual(completed, 1)
        XCTAssertEqual(h.edges, [true, false, true, false])
    }

    func testPreparationFailureDoesNotStartTheTarget() {
        let h = VoiceHarness()
        h.output.onBegin = { h.controller.cancel() }
        h.controller.press(mapping: fn, fnTap: true)
        h.clock.advance(2)
        XCTAssertTrue(h.keys.isEmpty)
    }

    func testBufferedSpeechIsBoundedWhileTheTargetStarts() {
        let h = VoiceHarness()
        h.controller.press(mapping: fn, fnTap: true)
        h.controller.handle(.started)
        h.controller.append(Array(repeating: 1, count: 5000))
        h.controller.append(Array(repeating: 2, count: 7000))
        XCTAssertTrue(h.output.packets.isEmpty)
        h.clock.advance(0.28)
        let samples = h.output.packets.flatMap { $0 }
        XCTAssertEqual(samples.count, 8000)
        XCTAssertEqual(samples.prefix(1000), Array(repeating: Int16(1), count: 1000)[...])
        XCTAssertEqual(samples.suffix(7000), Array(repeating: Int16(2), count: 7000)[...])
        h.controller.cancel()
        h.clock.advance(1)
    }

    @MainActor
    func testRealOutputDrainsBeforeTheStopTapWhenHIDReleasePrecedesBLEStart() async throws {
        let playback = SessionPlayback()
        let clock = TestClock()
        let output = RemoteMicrophoneOutput(schedule: clock.schedule, makePlayback: { playback })
        var edges: [Bool] = []
        let controller = RemoteVoiceSessionController(output: output, schedule: clock.schedule, logger: { _ in }) {
            _, down in edges.append(down)
        }
        controller.press(mapping: fn, fnTap: true)
        controller.release()
        controller.handle(.started)
        controller.append([1, 2, 3])
        controller.handle(.ended)
        clock.advance(0.28)
        XCTAssertEqual(edges, [true, false])
        XCTAssertEqual(output.queuedSamples, 3)
        XCTAssertEqual(playback.packets, [[1, 2, 3]])
        playback.completions.forEach { $0() }
        await drainMainQueue()
        clock.advance(0.049)
        XCTAssertEqual(edges, [true, false])
        clock.advance(0.001)
        XCTAssertEqual(output.deliveredSamples, 3)
        XCTAssertEqual(edges, [true, false, true])
        clock.advance(0.12)
        XCTAssertEqual(edges, [true, false, true, false])
        controller.cancel()
    }

    @MainActor
    func testPlaybackFailureReleasesAHeldFnAndDoesNotStartAnotherTap() {
        let playback = SessionPlayback()
        playback.acceptsAudio = false
        let output = RemoteMicrophoneOutput(makePlayback: { playback })
        let clock = TestClock()
        var edges: [Bool] = []
        let controller = RemoteVoiceSessionController(output: output, schedule: clock.schedule, logger: { _ in }) {
            _, down in edges.append(down)
        }
        output.onStateChange = { [weak controller] state in
            if case .failed = state { controller?.cancel() }
        }
        controller.press(mapping: fn, fnTap: false)
        controller.handle(.started)
        controller.append([1])
        XCTAssertNotNil(output.failure)
        XCTAssertEqual(edges, [true, false])
        clock.advance(2)
        XCTAssertEqual(edges, [true, false])
        output.onStateChange = nil
    }

    func testColdOutputPreparationRetainsTheCapturedFirstUtterance() {
        let playback = SessionPlayback()
        var prepared: ((Result<Void, Error>) -> Void)?
        playback.prepareHandler = { prepared = $0 }
        let output = RemoteMicrophoneOutput(makePlayback: { playback })
        let clock = TestClock()
        var edges: [Bool] = []
        let controller = RemoteVoiceSessionController(output: output, schedule: clock.schedule, logger: { _ in }) {
            _, down in edges.append(down)
        }
        controller.handle(.started)
        controller.press(mapping: fn, fnTap: false)
        XCTAssertEqual(edges, [true])
        // Replay the production trace: 176 decoded packets, 240 samples each,
        // arrive while a cold graph is still preparing (2.64 seconds of PCM).
        for packet in 0..<176 {
            controller.append(Array(repeating: Int16(packet + 1), count: 240))
        }
        controller.release()
        controller.handle(.ended)
        XCTAssertEqual(output.droppedSamples, 0, "The first utterance must reach dictation instead of being trimmed to its final half second")
        XCTAssertEqual(output.queuedSamples, 42_240)
        prepared?(.success(()))
        XCTAssertEqual(playback.packets.first?.first, 1, "Retain the beginning of the sentence")
        XCTAssertEqual(edges, [true], "Keep Fn held while the captured sentence drains")
        controller.cancel()
    }

    func testTapWithMissingBLEStartStillHasAMatchedStop() {
        let h = VoiceHarness()
        h.controller.press(mapping: fn, fnTap: true)
        h.controller.release()
        h.clock.advance(0.28)
        h.output.completeDrain() // The output's missing-STOP timeout resolved.
        h.clock.advance(0.12)
        XCTAssertEqual(h.edges, [true, false, true, false])
        h.controller.handle(.started) // A stale stream must not emit another tap.
        h.clock.advance(2)
        XCTAssertEqual(h.edges, [true, false, true, false])
    }
}

@MainActor
private final class VoiceHarness {
    let output = VoiceOutput()
    let clock = TestClock()
    var keys: [(RemoteAction, Bool)] = []
    var edges: [Bool] { keys.map { $0.1 } }
    lazy var controller = RemoteVoiceSessionController(output: output, schedule: clock.schedule, logger: { _ in }) { [weak self] mapping, down in
        self?.keys.append((mapping.action, down))
    }
}

@MainActor
private final class VoiceOutput: RemoteVoiceAudioOutput {
    var onBegin: (() -> Void)?
    var packets: [[Int16]] = []
    var releases: [() -> Void] = []
    var begins = 0
    var ends = 0
    func prepareForPress() {}
    func begin() { begins += 1; onBegin?() }
    func append(_ pcm: [Int16]) { packets.append(pcm) }
    func end() { ends += 1 }
    func stop() {
        let completions = releases
        releases.removeAll()
        completions.forEach { $0() }
    }
    func releaseWhenFinished(completion: @escaping () -> Void) { releases.append(completion) }
    func completeDrain() {
        let completions = releases
        releases.removeAll()
        completions.forEach { $0() }
    }
}

private final class SessionPlayback: RemoteMicrophonePlayback {
    var prepareHandler: ((@escaping (Result<Void, Error>) -> Void) -> Void)?
    func prepare(completion: @escaping (Result<Void, Error>) -> Void) {
        if let prepareHandler { prepareHandler(completion) }
        else { completion(.success(())) }
    }
    var acceptsAudio = true
    var packets: [[Int16]] = []
    var completions: [() -> Void] = []
    func schedule(_ pcm: [Int16], completion: @escaping () -> Void) -> Bool {
        guard acceptsAudio else { return false }
        packets.append(pcm)
        completions.append(completion)
        return true
    }
    func stop() {}
}
