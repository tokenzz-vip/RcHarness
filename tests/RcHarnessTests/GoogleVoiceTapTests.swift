import XCTest
@testable import RcHarness

@MainActor
final class GoogleVoiceTapTests: XCTestCase {
    func testNativeTapOpensOnlyAfterReleaseAndSecondTapEndsWithoutReopening() {
        let h = Harness()
        h.start(session: 26, reason: 3)
        h.search()
        h.audio()
        XCTAssertEqual(h.commands.count, 1, "Keep the native stream until the user releases the key")
        XCTAssertEqual(h.buttons, [true, false], "START and SEARCH describe one physical press")
        h.clock.advance(0.15)
        h.stop(reason: 2)
        XCTAssertEqual(h.commands.last, [0x0C, 0])
        h.start()
        h.audio()
        h.clock.advance(0.4)
        XCTAssertEqual(h.keys, [true, false], "The release must not toggle the input method off")
        XCTAssertEqual(h.output.samples, 640, "Preserve native audio and the requested stream")
        h.start(session: 27, reason: 3)
        h.search()
        h.audio()
        h.clock.advance(0.15)
        h.stop(reason: 2)
        h.output.drain()
        h.clock.advance(0.12)
        XCTAssertEqual(h.keys, [true, false, true, false])
        XCTAssertEqual(h.commands.filter { $0.first == 0x0C }.count, 1)
        XCTAssertTrue(h.failures.isEmpty)
    }

    func testDuplicateReleaseCannotEndHostOpenedStreamOrItsStartup() {
        let h = Harness()
        h.start(session: 26, reason: 3)
        h.search()
        h.clock.advance(0.15)
        h.stop(reason: 2)
        h.stop(reason: 2)
        h.start()
        h.stop(reason: 2)
        h.audio()
        h.clock.advance(0.4)
        h.output.drain()
        XCTAssertEqual(h.keys, [true, false])
        XCTAssertEqual(h.output.samples, 320)
        h.voice.cancelActiveStream()
        h.clock.advance(0.12)
    }

    func testNativeTapStartupRequiresAudioWithinOneSecondEvenAfterStart() {
        for receivesStart in [false, true] {
            let h = Harness()
            h.start(session: 26, reason: 3)
            h.search()
            h.clock.advance(0.15)
            h.stop(reason: 2)
            if receivesStart { h.start() }
            h.clock.advance(0.99)
            XCTAssertTrue(h.failures.isEmpty)
            h.clock.advance(0.01)
            h.output.drain()
            h.clock.advance(0.12)
            XCTAssertEqual(h.failures.count, 1)
            XCTAssertEqual(h.keys, [true, false, true, false])
            XCTAssertEqual(h.commands.last, [0x0D, 0])
            h.start()
            h.audio()
            h.clock.advance(5)
            XCTAssertEqual(h.commands.filter { $0.first == 0x0C }.count, 1)
            XCTAssertEqual(h.output.samples, 0)
        }
    }

    func testRepeatedNativeStartDoesNotResetTapDurationAndLongPressDoesNotLatch() {
        for held in [0.15, 0.55, 0.9] {
            let h = Harness()
            h.start(session: 26, reason: 3)
            h.search()
            h.clock.advance(held / 2)
            h.start(session: 26, reason: 3)
            h.clock.advance(held / 2)
            h.stop(reason: 2)
            let opens = h.commands.filter { $0.first == 0x0C }.count
            XCTAssertEqual(opens, held < 0.55 ? 1 : 0)
            h.voice.cancelActiveStream()
            h.clock.advance(0.4)
        }
    }

    func testPartialAudioAndDuplicateReleaseDoNotDefeatFirstFrameDeadline() {
        let h = Harness()
        h.start(session: 26, reason: 3)
        h.clock.advance(0.15)
        h.stop(reason: 2)
        h.start()
        h.voice.receiveAudio(Data([0x17]))
        h.clock.advance(0.8)
        h.stop(reason: 2)
        h.start() // Duplicate acknowledgement must not renew the deadline.
        h.clock.advance(0.2)
        h.output.drain()
        h.clock.advance(0.12)
        XCTAssertEqual(h.failures.count, 1)
        XCTAssertEqual(h.keys, [true, false, true, false])
    }

    func testNativeAndHIDReportsForBothClicksOnlyToggleOnce() {
        let h = Harness()
        for session: UInt8 in [26, 27] {
            h.voice.receiveTapButton(pressed: true)
            h.start(session: session, reason: 3)
            h.search()
            h.audio()
            h.clock.advance(0.15)
            h.voice.receiveTapButton(pressed: false)
            h.stop(reason: 2)
            h.search() // Late duplicate START_SEARCH from this same press.
            h.clock.advance(0.05)
            if session == 26 {
                h.start()
                h.audio()
                h.clock.advance(0.4)
                XCTAssertEqual(h.keys, [true, false])
            }
        }
        h.output.drain()
        h.clock.advance(0.12)
        XCTAssertEqual(h.keys, [true, false, true, false])
        XCTAssertEqual(h.commands.filter { $0.first == 0x0C }.count, 1)
    }

    func testRejectedNativePressAndCancellationNeverOpenAfterRelease() {
        for reject in [true, false] {
            let h = Harness()
            h.acceptPress = !reject
            h.start(session: 26, reason: 3)
            h.search()
            if !reject { h.voice.cancelActiveStream() }
            h.clock.advance(0.15)
            h.stop(reason: 2)
            h.clock.advance(3)
            XCTAssertFalse(h.commands.contains { $0.first == 0x0C })
            XCTAssertEqual(h.keys, reject ? [] : [true, false, true, false])
        }
    }

    func testNativeTapAfterNoAudioTimeoutCanStartFresh() {
        let h = Harness()
        h.start(session: 26, reason: 3)
        h.clock.advance(0.15)
        h.stop(reason: 2)
        h.start()
        h.clock.advance(1)
        h.output.drain()
        h.clock.advance(0.12)
        h.start(session: 27, reason: 3)
        h.search()
        h.audio()
        h.clock.advance(0.15)
        h.stop(reason: 2)
        h.start()
        h.audio()
        h.clock.advance(0.4)
        XCTAssertEqual(h.commands.filter { $0.first == 0x0C }.count, 2)
        XCTAssertEqual(h.keys, [true, false, true, false, true, false])
        XCTAssertEqual(h.output.samples, 640)
        h.voice.cancelActiveStream()
        h.clock.advance(0.12)
    }

    func testSecondSearchClosesCaptureAfterReceivingTheTailAndPairsTheShortcut() {
        let h = Harness()
        XCTAssertEqual(h.commands, [[0x0A, 1, 0, 0, 2, 3]])
        h.search()
        XCTAssertEqual(h.buttons, [true, false])
        XCTAssertEqual(h.commands.last, [0x0C, 0])
        h.start()
        h.audio()
        h.clock.advance(0.4)
        XCTAssertEqual(h.keys, [true, false])
        XCTAssertEqual(h.output.samples, 320)
        h.search()
        XCTAssertEqual(h.buttons, [true, false, true, false])
        XCTAssertEqual(h.commands.last, [0x0D, 0])
        XCTAssertEqual(h.output.ends, 0, "Wait for the remote's actual tail and STOP")
        h.audio()
        XCTAssertEqual(h.output.samples, 640)
        h.stop()
        XCTAssertEqual(h.output.ends, 1)
        XCTAssertEqual(h.keys, [true, false])
        h.output.drain()
        h.clock.advance(0.12)
        XCTAssertEqual(h.keys, [true, false, true, false])
        let count = h.output.samples
        h.audio()
        h.clock.advance(10)
        XCTAssertEqual(h.output.samples, count, "Late audio must not restart tap capture")
        XCTAssertEqual(h.commands.filter { $0.first == 0x0E }.count, 0)
    }

    func testHIDAndSearchForOneClickAreMergedAndHIDCanCarrySecondClick() {
        let h = Harness()
        let parser = XiaomiRemoteHIDParser(profile: RemoteProfiles.googleG9N9N)
        parser.voiceMode = .tap
        func hid(_ pressed: Bool) {
            for event in parser.parse(usagePage: 0x0C, usage: 0xCF, value: pressed ? 1 : 0) {
                h.voice.receiveTapButton(pressed: event.isPressed)
            }
        }
        hid(true)
        h.search()
        hid(false)
        h.clock.advance(0.1)
        XCTAssertEqual(h.buttons, [true, false])
        h.start()
        h.audio()
        h.clock.advance(0.3)
        hid(true)
        hid(false)
        h.clock.advance(0.05)
        XCTAssertEqual(h.commands.last, [0x0D, 0])
        h.search() // Duplicate BLE notification for the same second click.
        XCTAssertEqual(h.buttons, [true, false, true, false])
        h.stop()
        h.output.drain()
        h.clock.advance(0.12)
        XCTAssertEqual(h.keys, [true, false, true, false])
    }

    func testHIDOnlyClickCanOpenThenStopWithoutWaitingForAnAudioKeyRelease() {
        let h = Harness()
        h.voice.receiveTapButton(pressed: true)
        h.voice.receiveTapButton(pressed: false)
        h.clock.advance(0.05)
        h.start()
        h.audio()
        h.clock.advance(0.4)
        h.voice.receiveTapButton(pressed: true)
        h.voice.receiveTapButton(pressed: false)
        h.clock.advance(0.05)
        XCTAssertEqual(h.commands.last, [0x0D, 0])
        h.stop()
        h.output.drain()
        h.clock.advance(0.12)
        XCTAssertEqual(h.keys, [true, false, true, false])
    }

    func testNoPhysicalReleaseIsNeededAndCaptureIsExtendedWithinTotalLimit() {
        let h = Harness()
        h.search()
        h.start()
        for _ in 0..<11 {
            h.audio()
            h.clock.advance(1)
        }
        XCTAssertEqual(h.commands.filter { $0.first == 0x0E }, [[0x0E, 0], [0x0E, 0]])
        XCTAssertEqual(h.keys, [true, false], "The target stays recording after the start click")
        h.search()
        h.stop()
        h.output.drain()
        h.clock.advance(20)
        XCTAssertEqual(h.commands.filter { $0.first == 0x0E }.count, 2)
        XCTAssertEqual(h.keys, [true, false, true, false])
    }

    func testStopBeforeStartClosesTheLateActualSessionAndBoundsMissingStop() {
        let h = Harness()
        h.search()
        h.clock.advance(0.3)
        h.search()
        XCTAssertEqual(h.commands.last, [0x0D, 0])
        h.start(session: 9)
        XCTAssertEqual(h.commands.last, [0x0D, 9])
        h.audio()
        h.clock.advance(0.49)
        XCTAssertEqual(h.output.ends, 0)
        h.clock.advance(0.01)
        XCTAssertEqual(h.output.ends, 1)
        h.output.drain()
        h.clock.advance(0.12)
        XCTAssertEqual(h.keys, [true, false, true, false])
        h.start(session: 9)
        h.audio()
        h.clock.advance(10)
        XCTAssertEqual(h.output.begins, 1)
    }

    func testStopWithoutAnyStartStillEndsTheTargetAndCanStartAnotherSession() {
        let h = Harness()
        h.search()
        h.clock.advance(0.3)
        h.search()
        h.clock.advance(0.5)
        h.output.drain()
        h.clock.advance(0.12)
        XCTAssertEqual(h.keys, [true, false, true, false])
        h.search()
        h.start()
        h.audio()
        h.clock.advance(0.28)
        XCTAssertEqual(h.output.begins, 2)
        XCTAssertEqual(h.keys, [true, false, true, false, true, false])
        h.voice.cancelActiveStream()
        h.clock.advance(0.12)
    }

    func testQuickSecondClickDuringStartupStopsAndDuplicateSearchDoesNot() {
        let h = Harness()
        h.search()
        h.search()
        XCTAssertEqual(h.buttons, [true, false])
        h.clock.advance(0.1)
        h.search()
        XCTAssertEqual(h.buttons, [true, false, true, false])
        XCTAssertEqual(h.commands.last, [0x0D, 0])
        h.clock.advance(0.5)
        h.output.drain()
        h.clock.advance(0.12)
        XCTAssertEqual(h.keys, [true, false, true, false])
    }

    func testNewClickDuringTailDrainCannotOpenAnUnmatchedCapture() {
        let h = Harness()
        h.search()
        h.start()
        h.audio()
        h.clock.advance(0.4)
        h.search()
        h.stop()
        h.clock.advance(0.3)
        h.search()
        XCTAssertEqual(h.commands.filter { $0.first == 0x0C }.count, 1)
        h.output.drain()
        h.clock.advance(0.4)
        h.search()
        XCTAssertEqual(h.commands.filter { $0.first == 0x0C }.count, 2)
        h.voice.cancelActiveStream()
        h.clock.advance(0.4)
    }

    func testUnsolicitedAudioCannotOpenTapCaptureOrWakeTheTarget() {
        let h = Harness()
        h.audio()
        h.start()
        h.clock.advance(3)
        XCTAssertTrue(h.buttons.isEmpty)
        XCTAssertTrue(h.keys.isEmpty)
        XCTAssertEqual(h.output.samples, 0)
        XCTAssertEqual(h.commands.last, [0x0D, 0])
    }

    func testPermissionRejectionCannotSendMicOpenOrStartATarget() {
        let h = Harness()
        h.acceptPress = false
        h.search()
        h.clock.advance(3)
        XCTAssertTrue(h.keys.isEmpty)
        XCTAssertFalse(h.commands.contains { $0.first == 0x0C })
        h.start()
        h.audio()
        XCTAssertEqual(h.output.samples, 0)
    }

    func testOpenTimeoutAndOpenErrorPairTheTargetAndDoNotReopen() {
        for timeout in [true, false] {
            let h = Harness()
            h.search()
            h.clock.advance(0.28)
            if timeout { h.clock.advance(1.72) }
            else { h.voice.receiveControl(Data([0x0C, 0x0F, 0x01])) }
            h.clock.advance(0.12)
            XCTAssertEqual(h.failures.count, 1)
            XCTAssertEqual(h.keys, [true, false, true, false])
            h.start()
            h.audio()
            h.clock.advance(20)
            XCTAssertEqual(h.commands.filter { $0.first == 0x0C }.count, 1)
            XCTAssertEqual(h.output.samples, 0)
        }
    }

    func testUnexpectedRemoteStopAndWatchdogStopAlsoCloseTheInputMethod() {
        for explicitStop in [true, false] {
            let h = Harness()
            h.search()
            h.start()
            h.audio()
            h.clock.advance(0.28)
            if explicitStop { h.stop(reason: 8) }
            else { h.clock.advance(1.72) }
            h.output.drain()
            h.clock.advance(0.12)
            XCTAssertEqual(h.keys, [true, false, true, false])
            h.audio()
            h.clock.advance(10)
            XCTAssertEqual(h.output.begins, 1)
        }
    }

    func testMaximumDurationCannotBeExtendedForever() {
        let h = Harness()
        h.search()
        h.start()
        for _ in 0..<120 {
            h.audio()
            h.clock.advance(1)
        }
        XCTAssertEqual(h.output.ends, 1)
        XCTAssertEqual(h.commands.last, [0x0D, 0])
        h.output.drain()
        h.clock.advance(0.12)
        XCTAssertEqual(h.keys, [true, false, true, false])
    }

    func testCancellationModeSwitchAndDisableCancelAllTapTimersAndKeys() {
        for operation in 0..<4 {
            let h = Harness()
            h.search()
            h.start()
            h.audio()
            h.clock.advance(0.28)
            switch operation {
            case 0: h.voice.cancelActiveStream()
            case 1: h.voice.setVoiceMode(.hold)
            case 2: h.voice.enabled = false
            default: h.voice.stop()
            }
            h.clock.advance(0.12)
            XCTAssertEqual(h.keys, [true, false, true, false])
            let commands = h.commands
            h.clock.advance(130)
            XCTAssertEqual(h.commands, commands)
        }
    }

    func testCapabilitiesAndActualStartReasonAreValidatedWithoutChangingHold() {
        for model: UInt8 in [0, 1, 2, 3] {
            let h = Harness(model: model)
            XCTAssertTrue(h.voice.isReady, "The response may describe a superset of on-request")
            h.search()
            h.start(reason: 1)
            h.clock.advance(0.4)
            XCTAssertEqual(h.failures.count, 1)
            XCTAssertEqual(h.keys, [true, false, true, false])
            XCTAssertEqual(h.output.samples, 0)
        }
        let unsupported = Harness(model: 0xFF)
        XCTAssertFalse(unsupported.voice.isReady)
        XCTAssertEqual(unsupported.failures.count, 1)
        unsupported.search()
        XCTAssertTrue(unsupported.keys.isEmpty)
    }

    func testXiaomiCannotEnableTapAndGoogleHoldKeepsItsOriginalWireAndKeyEdges() {
        for profile in RemoteProfiles.all {
            let clock = TestClock()
            var commands: [[UInt8]] = [], buttons: [Bool] = []
            let voice = XiaomiRemoteVoice(profile: profile, schedule: clock.schedule, now: { clock.time },
                                          commandWriter: { commands.append($0) })
            if profile.adapter == .xiaomi { voice.setVoiceMode(.tap) }
            XCTAssertEqual(voice.voiceMode, .hold)
            voice.onVoiceButtonInput = { buttons.append($0) }
            voice.requestCapabilities()
            XCTAssertEqual(commands, [profile.voiceCapabilitiesRequest])
            voice.receiveControl(Data([0x0B, 1, 0, 2, 3, 0, 160]))
            voice.receiveControl(Data([0x08]))
            XCTAssertEqual(commands.last, [0x0C, 0])
            voice.receiveControl(Data([0x04, 3, 2, 7]))
            voice.receiveControl(Data([0x00, 2]))
            XCTAssertEqual(buttons, profile.adapter == .chromecast ? [true, false] : [])
            clock.advance(130)
            XCTAssertEqual(commands.count, 2, "Legacy hold must not get tap keepalive commands")
        }
        let parser = XiaomiRemoteHIDParser(profile: RemoteProfiles.googleG9N9N)
        XCTAssertTrue(parser.parse(usagePage: 0x0C, usage: 0xCF, value: 1).isEmpty)
        parser.voiceMode = .tap
        XCTAssertEqual(parser.parse(usagePage: 0x0C, usage: 0xCF, value: 1).first?.input, .options)
        parser.voiceMode = .hold
        XCTAssertEqual(parser.parse(usagePage: 0x0C, usage: 0xCF, value: 0).first?.isPressed, false)
    }

    @MainActor
    private final class Harness {
        let clock = TestClock()
        let output = Output()
        var commands: [[UInt8]] = []
        var keys: [Bool] = []
        var buttons: [Bool] = []
        var failures: [String] = []
        var acceptPress = true
        lazy var session = RemoteVoiceSessionController(output: output, schedule: clock.schedule, logger: { _ in }) {
            [weak self] _, down in self?.keys.append(down)
        }
        lazy var voice = XiaomiRemoteVoice(profile: RemoteProfiles.googleG9N9N, schedule: clock.schedule,
            now: { [unowned self] in self.clock.time }, commandWriter: { [weak self] in self?.commands.append($0) })

        init(model: UInt8 = 0) {
            voice.setVoiceMode(.tap)
            voice.onCaptureFailure = { [weak self] in self?.failures.append($0) }
            voice.canStartCapture = { [unowned self] in self.session.isIdle }
            voice.onVoiceButtonInput = { [unowned self] down in
                self.buttons.append(down)
                if !down { self.session.release(); return }
                guard self.acceptPress else { self.voice.cancelActiveStream(); return }
                if self.session.finishToggle(waitForStreamEnd: true) {
                    self.voice.releaseRemappedPress()
                } else {
                    self.voice.prepareForPress()
                    self.session.press(mapping: ButtonMapping(action: .recordedShortcut, shortcut: .voiceTapDefault),
                                       fnTap: false, toggle: true, endToggleWithStream: true)
                }
            }
            voice.onStreamEvent = { [unowned self] in self.session.handle($0) }
            voice.onSamples = { [unowned self] in self.session.append($0) }
            voice.requestCapabilities()
            voice.receiveControl(Data([0x0B, 1, 0, 2, model, 0, 160]))
        }
        func search() { voice.receiveControl(Data([0x08])) }
        func start(session: UInt8 = 0, reason: UInt8 = 0) { voice.receiveControl(Data([0x04, reason, 2, session])) }
        func stop(reason: UInt8 = 0) { voice.receiveControl(Data([0x00, reason])) }
        func audio() { voice.receiveAudio(Data(repeating: 0x17, count: 160)) }
    }

    @MainActor
    private final class Output: RemoteVoiceAudioOutput {
        var begins = 0, ends = 0, samples = 0
        var completion: (() -> Void)?
        func prepareForPress() {}
        func begin() { begins += 1 }
        func append(_ pcm: [Int16]) { samples += pcm.count }
        func end() { ends += 1 }
        func stop() { drain() }
        func releaseWhenFinished(completion: @escaping () -> Void) { self.completion = completion }
        func drain() {
            let callback = completion
            completion = nil
            callback?()
        }
    }
}
