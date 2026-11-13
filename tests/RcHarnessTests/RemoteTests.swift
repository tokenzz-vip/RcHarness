import XCTest
@testable import RcHarness

final class RemoteTests: XCTestCase {
    func testCancelledAndStoppedVoiceEventsCannotRestartTheOldRecording() {
        var gate = RemoteVoiceSessionGate()
        XCTAssertTrue(gate.acceptsImplicitStart(at: 10))
        gate.stop(cancelled: true, at: 10)
        XCTAssertFalse(gate.acceptsStart(at: 10.2))
        XCTAssertFalse(gate.acceptsImplicitStart(at: 10.2))
        gate.prepareForPress()
        XCTAssertTrue(gate.acceptsStart(at: 10.21))
        XCTAssertTrue(gate.acceptsImplicitStart(at: 10.21))
        gate.stop(cancelled: false, at: 11)
        XCTAssertFalse(gate.acceptsImplicitStart(at: 11.1))
        XCTAssertTrue(gate.acceptsStart(at: 11.1))
        XCTAssertTrue(gate.acceptsImplicitStart(at: 11.31))
        gate.stop(cancelled: true, at: 12)
        XCTAssertTrue(gate.acceptsImplicitStart(at: 13.01))
    }

    func testLateStartPreservesImplicitAudioDecoderAndPartialFrame() {
        let first = Data(repeating: 0x17, count: 130)
        let second = Data(repeating: 0x32, count: 110)
        var implicit = RemoteVoiceStream()
        implicit.start(session: 0, implicit: true)
        let prefix = implicit.append(first, frameBytes: 120)
        implicit.confirmImplicitSession(7)
        let suffix = implicit.append(second, frameBytes: 120)
        var normal = RemoteVoiceStream()
        normal.start(session: 7)
        XCTAssertEqual(prefix + suffix, normal.append(first + second, frameBytes: 120))
        XCTAssertEqual(implicit.session, 7)
        XCTAssertFalse(implicit.isImplicit)
        XCTAssertEqual(implicit.receivedPackets, 2)
        XCTAssertEqual(implicit.receivedBytes, 240)
        XCTAssertEqual(implicit.decodedFrames, 2)
        XCTAssertEqual(implicit.sampleCount, 480)
        _ = implicit.append(Data([1, 2, 3]), frameBytes: 120)
        implicit.synchronize(sample: 0, index: 0)
        XCTAssertEqual(implicit.synchronizationDiscardedBytes, 3)
        XCTAssertEqual(implicit.pendingBytes, 0)
        implicit.stop()
        XCTAssertFalse(implicit.isImplicit)
    }

    func testPowerPressAndReleaseAreSeparateFromHome() {
        let parser = XiaomiRemoteHIDParser()
        for (page, usage): (UInt32, UInt32) in [(0x01, 0x81), (0x0C, 0x30), (0x07, 0x66)] {
            for value in [1, 0] {
                XCTAssertEqual(parser.parse(usagePage: page, usage: usage, value: value),
                               [XiaomiRemoteParsedEvent(input: .power, isPressed: value != 0)])
            }
        }
        XCTAssertEqual(parser.parse(usagePage: 0x0C, usage: 0x223, value: 1),
                       [XiaomiRemoteParsedEvent(input: .home, isPressed: true)])
        XCTAssertEqual(parser.parse(usagePage: 0x07, usage: 0x4A, value: 1),
                       [XiaomiRemoteParsedEvent(input: .home, isPressed: true)])
    }

    func testPowerNativeMappingsAreSuppressedAndRestored() {
        let powerSources: [UInt64] = [0x700000066, 0xC00000030, 0x100000081]
        let original = powerSources.map { RemoteKeyMapping(source: $0, destination: 0x700000004) }
            + [RemoteKeyMapping(source: 0x700000005, destination: 0x700000006)]
        let suppressed = RemoteVolumeSuppression.suppress(original)
        for source in powerSources {
            XCTAssertEqual(suppressed.filter { $0.source == source },
                           [RemoteKeyMapping(source: source, destination: 0)])
        }
        XCTAssertEqual(Set(RemoteVolumeSuppression.restore(suppressed, original: original)), Set(original))
    }

    func testRC003KeyboardMappings() {
        let parser = XiaomiRemoteHIDParser()
        XCTAssertEqual(parser.parse(usagePage: 0x07, usage: 0x28, value: 1),
                       [XiaomiRemoteParsedEvent(input: .buttonA, isPressed: true)])
        XCTAssertEqual(parser.parse(usagePage: 0x07, usage: 0x3E, value: 1),
                       [XiaomiRemoteParsedEvent(input: .options, isPressed: true)])
        XCTAssertEqual(parser.parse(usagePage: 0x07, usage: 0xF1, value: 1),
                       [XiaomiRemoteParsedEvent(input: .buttonB, isPressed: true)])
    }

    func testHatSwitchReleasesPreviousDirection() {
        let parser = XiaomiRemoteHIDParser()
        XCTAssertEqual(parser.parse(usagePage: 0x01, usage: 0x39, value: 0),
                       [XiaomiRemoteParsedEvent(input: .dpadUp, isPressed: true)])
        XCTAssertEqual(parser.parse(usagePage: 0x01, usage: 0x39, value: 8),
                       [XiaomiRemoteParsedEvent(input: .dpadUp, isPressed: false)])
    }

    func testRemovingADeviceReleasesAnyHeldKeyboardOrConsumerInput() {
        for profile in RemoteProfiles.all {
            let parser = XiaomiRemoteHIDParser(profile: profile)
            let page: UInt32 = profile.adapter == .xiaomi ? 0x07 : 0x0C
            let usage: UInt32 = profile.adapter == .xiaomi ? 0x28 : 0x41
            _ = parser.parse(usagePage: page, usage: usage, value: 1)
            XCTAssertEqual(parser.reset(), [.init(input: .buttonA, isPressed: false)], profile.id)
            XCTAssertTrue(parser.reset().isEmpty)
        }
    }

    func testRemoteVoiceCapabilityContract() {
        XCTAssertEqual(RemoteVoiceCapabilities(Data([0x0B, 1, 0, 2, 3, 0, 120, 0, 0]))?.frameBytes, 120)
        XCTAssertNil(RemoteVoiceCapabilities(Data([0x0B, 2, 0, 2, 3, 0, 120, 0, 0])))
    }

    func testRemoteVoiceRecognizesKnownBluetoothNames() {
        let supported = [
            "MI RC",
            "小米蓝牙语音遥控器",
            "小米蓝牙遥控器 2 Pro",
            "Xiaomi Bluetooth Remote 2 Pro",
            " Xiaomi Bluetooth Remote 2 "
        ]
        for name in supported {
            XCTAssertTrue(XiaomiRemoteVoice.matchesName(name), "expected supported name: \(name)")
        }
        XCTAssertFalse(XiaomiRemoteVoice.matchesName("Other Bluetooth Remote"))
    }
}

final class RemoteInputBoundaryTests: XCTestCase {
    func testMultipleDevicesOwnTheInputUntilTheLastDeviceReleasesOrDisappears() {
        var state = RemoteInputState<Int>()
        let down = XiaomiRemoteParsedEvent(input: .buttonA, isPressed: true)
        let up = XiaomiRemoteParsedEvent(input: .buttonA, isPressed: false)
        XCTAssertEqual(state.update(down, source: 1), down)
        XCTAssertNil(state.update(down, source: 1))
        XCTAssertNil(state.update(down, source: 2))
        XCTAssertTrue(state.remove(1).isEmpty)
        XCTAssertNil(state.update(up, source: 1), "A stale up cannot release another device")
        XCTAssertEqual(state.remove(2), [.buttonA])
        XCTAssertNil(state.update(up, source: 2))
        XCTAssertEqual(state.update(down, source: 3), down)
        XCTAssertEqual(state.update(up, source: 3), up)
    }

    func testAliasesAndHatDirectionsRetainTheirIndependentSourceState() {
        let parser = XiaomiRemoteHIDParser()
        _ = parser.parse(usagePage: 7, usage: 0x52, value: 1)
        _ = parser.parse(usagePage: 1, usage: 0x39, value: 0)
        XCTAssertTrue(parser.parse(usagePage: 1, usage: 0x39, value: 8).isEmpty)
        XCTAssertEqual(parser.reset(), [.init(input: .dpadUp, isPressed: false)])
        _ = parser.parse(usagePage: 7, usage: 0x28, value: 1)
        _ = parser.parse(usagePage: 0x0C, usage: 0x41, value: 1)
        XCTAssertTrue(parser.parse(usagePage: 7, usage: 0x28, value: 0).isEmpty)
        XCTAssertEqual(parser.parse(usagePage: 0x0C, usage: 0x41, value: 0), [.init(input: .buttonA, isPressed: false)])
    }

    func testEveryAcceptedScalarUsageHasANativeSuppressionEntry() {
        for profile in RemoteProfiles.all {
            for binding in RemoteHIDUsages.bindings(for: profile) {
                let parser = XiaomiRemoteHIDParser(profile: profile)
                XCTAssertEqual(parser.parse(usagePage: binding.page, usage: binding.usage, value: 1),
                               [.init(input: binding.input, isPressed: true)])
                let suppressed = RemoteVolumeSuppression.suppress([])
                XCTAssertTrue(suppressed.contains(.init(source: binding.source, destination: 0)))
                XCTAssertEqual(parser.reset(), [.init(input: binding.input, isPressed: false)])
            }
        }
    }

    @MainActor
    func testCancelledDeviceCannotFireAPendingTapOrReleaseOtherGestures() {
        let clock = TestClock()
        let gestures = RemoteGestureController(schedule: clock.schedule)
        var mapping = RemoteMapping.defaults
        mapping[.buttonA, .double] = ButtonMapping(action: .paste)
        mapping[.buttonB] = ButtonMapping(action: .leftCommand)
        var events: [(RemoteAction, Bool)] = []
        gestures.onOutput = { value, pressed, _ in events.append((value.action, pressed)) }
        gestures.handle(.buttonA, pressed: true, mapping: mapping)
        gestures.handle(.buttonB, pressed: true, mapping: mapping)
        gestures.cancel(.buttonA)
        gestures.handle(.buttonA, pressed: false, mapping: mapping)
        clock.advance(1)
        XCTAssertEqual(events.map { $0.0 }, [.leftCommand])
        XCTAssertEqual(events.map { $0.1 }, [true])
        gestures.handle(.buttonB, pressed: false, mapping: mapping)
        XCTAssertEqual(events.map { $0.1 }, [true, false])
    }
}
