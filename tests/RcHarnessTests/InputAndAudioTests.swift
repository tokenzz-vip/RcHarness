import CoreAudio
import CoreGraphics
import XCTest
@testable import RcHarness

@MainActor
final class InputAndAudioTests: XCTestCase {
    func testInstanceLockExcludesAnotherProcessAndReleasesOnExit() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("application.lock").path
        var first: SingleInstanceLock? = try SingleInstanceLock(path: path)
        XCTAssertNotNil(first)
        XCTAssertThrowsError(try SingleInstanceLock(path: path)) { error in
            guard case SingleInstanceLock.Failure.alreadyRunning = error else { return XCTFail("Unexpected lock failure: \(error)") }
        }
        first = nil
        let next = try SingleInstanceLock(path: path)
        withExtendedLifetime(next) {}
    }

    func testNativeModeStopsMappedGesturesUntilReenabledFromTheApp() {
        let clock = TestClock()
        let gestures = RemoteGestureController(schedule: clock.schedule)
        var mode: ControllerOperationMode = .mapping
        var events: [RemoteAction] = []
        let mapping = RemoteMapping.defaults
        gestures.onOutput = { value, down, _ in
            guard down else { return }
            events.append(value.action)
            if value.action == .switchToNativeMode {
                mode = .native
                gestures.setOperationMode(mode)
            }
        }
        gestures.handle(.menu, pressed: true, mapping: mapping)
        gestures.handle(.menu, pressed: false, mapping: mapping)
        XCTAssertEqual(mode, .native)
        XCTAssertEqual(events, [.switchToNativeMode])

        // Neither the original gesture nor a changed profile runs in native mode.
        var changed = mapping
        changed[.buttonA, .double] = ButtonMapping(action: .switchToNativeMode)
        changed[.buttonA, .long] = ButtonMapping(action: .copy)
        for input in ControllerInput.allCases {
            gestures.handle(input, pressed: true, mapping: changed)
            clock.advance(RemoteGestureController.longPressDelay)
            gestures.handle(input, pressed: false, mapping: changed)
            gestures.handle(input, pressed: true, mapping: changed)
            gestures.handle(input, pressed: false, mapping: changed)
            clock.advance(RemoteGestureController.doubleTapWindow)
        }
        XCTAssertEqual(mode, .native)
        XCTAssertEqual(events, [.switchToNativeMode])

        // The app's mode control restores the current profile's mappings.
        mode = .mapping
        gestures.setOperationMode(mode)
        gestures.handle(.buttonB, pressed: true, mapping: changed)
        gestures.handle(.buttonB, pressed: false, mapping: changed)
        XCTAssertEqual(events, [.switchToNativeMode, .backspace])
    }

    func testLegacyModeActionDecodesAsSwitchToNativeMode() throws {
        let data = Data("\"toggleMode\"".utf8)
        let action = try JSONDecoder().decode(RemoteAction.self, from: data)
        XCTAssertEqual(action, .switchToNativeMode)
        XCTAssertEqual(action.label, "切换到原生模式")
        XCTAssertEqual(try JSONEncoder().encode(action), data)
    }

    func testSecondPressCanBecomeALongPressInsteadOfADoubleClick() {
        let clock = TestClock()
        let gestures = RemoteGestureController(schedule: clock.schedule)
        var mapping = RemoteMapping.defaults
        mapping[.buttonA, .double] = ButtonMapping(action: .copy)
        mapping[.buttonA, .long] = ButtonMapping(action: .paste)
        var events: [RemoteAction] = []
        gestures.onOutput = { value, pressed, _ in if pressed { events.append(value.action) } }
        gestures.handle(.buttonA, pressed: true, mapping: mapping)
        gestures.handle(.buttonA, pressed: false, mapping: mapping)
        gestures.handle(.buttonA, pressed: true, mapping: mapping)
        clock.advance(0.65)
        gestures.handle(.buttonA, pressed: false, mapping: mapping)
        XCTAssertEqual(events, [.paste])
    }

    func testMouseEventsAndMovementShareQuartzCoordinatesAcrossDisplays() {
        let location = CGPoint(x: -900, y: 400)
        var clicks: [CGEvent] = []
        var movements: [CGPoint] = []
        let sender = SystemEventSender(cursorLocation: { location }, postEvent: { clicks.append($0) }, movePointer: { movements.append($0) })
        sender.send(ButtonMapping(action: .mouseLeft), pressed: true)
        sender.send(ButtonMapping(action: .mouseLeft), pressed: false)
        sender.send(ButtonMapping(action: .pointerUp), pressed: true)
        sender.send(ButtonMapping(action: .pointerRight), pressed: true)
        sender.send(ButtonMapping(action: .pointerRight), pressed: false)
        XCTAssertEqual(clicks.map(\.location), [location, location])
        XCTAssertEqual(clicks.map(\.type), [.leftMouseDown, .leftMouseUp])
        XCTAssertEqual(movements, [CGPoint(x: -900, y: 388), CGPoint(x: -888, y: 400)])
    }

    func testShowAllWindowsPreservesArrowFlagsRequiredBySystemShortcutMatching() throws {
        var events: [CGEvent] = []
        let sender = SystemEventSender(postEvent: { events.append($0) })
        sender.send(ButtonMapping(action: .showAllWindows), pressed: true)

        let down = try XCTUnwrap(events.first)
        let up = try XCTUnwrap(events.last)
        let arrowFlags: CGEventFlags = [.maskSecondaryFn, .maskNumericPad]
        XCTAssertTrue(down.flags.contains(arrowFlags.union(.maskControl)),
                      "Mission Control must receive Control plus the native arrow-key flags")
        XCTAssertTrue(up.flags.contains(arrowFlags), "The release must remain an arrow-key event")
        XCTAssertFalse(up.flags.contains(.maskControl))
    }

    func testShowAllWindowsTapsControlUpWithoutHoldingModifiersOrRetriggeringOnRelease() {
        var events: [CGEvent] = []
        let sender = SystemEventSender(postEvent: { events.append($0) })
        let mapping = ButtonMapping(action: .showAllWindows)

        sender.send(mapping, pressed: true)
        XCTAssertEqual(events.map(\.type), [.keyDown, .keyUp])
        XCTAssertEqual(events.map { $0.getIntegerValueField(.keyboardEventKeycode) },
                       [Int64(VirtualKey.upArrow), Int64(VirtualKey.upArrow)])
        let arrowFlags: CGEventFlags = [.maskSecondaryFn, .maskNumericPad]
        XCTAssertEqual(events.map(\.flags), [arrowFlags.union(.maskControl), arrowFlags])

        sender.send(mapping, pressed: false)
        XCTAssertEqual(events.count, 2)

        sender.send(ButtonMapping(action: .arrowUp), pressed: true)
        sender.send(ButtonMapping(action: .arrowUp), pressed: false)
        XCTAssertEqual(events.map(\.type), [.keyDown, .keyUp, .keyDown, .keyUp])
        XCTAssertTrue(events.suffix(2).allSatisfy { $0.flags == arrowFlags })
        sender.send(ButtonMapping(action: .enter), pressed: true)
        sender.send(ButtonMapping(action: .enter), pressed: false)
        XCTAssertTrue(events.suffix(2).allSatisfy { $0.flags.isEmpty })
    }

    func testRecordedArrowShortcutsKeepNativeFlagsWithoutLeakingThemToOtherKeys() {
        for code in [VirtualKey.upArrow, VirtualKey.downArrow, VirtualKey.leftArrow, VirtualKey.rightArrow] {
            var events: [CGEvent] = []
            let sender = SystemEventSender(postEvent: { events.append($0) })
            let mapping = ButtonMapping(action: .recordedShortcut,
                shortcut: RecordedShortcut(keyCode: code, modifiers: CGEventFlags.maskControl.rawValue, label: "Control + Arrow"))
            sender.send(mapping, pressed: true)
            sender.send(mapping, pressed: false)
            let arrowFlags: CGEventFlags = [.maskSecondaryFn, .maskNumericPad]
            XCTAssertEqual(events.map(\.type), [.keyDown, .keyUp])
            XCTAssertEqual(events.map(\.flags), [arrowFlags.union(.maskControl), arrowFlags])
            sender.send(ButtonMapping(action: .enter), pressed: true)
            sender.send(ButtonMapping(action: .enter), pressed: false)
            XCTAssertTrue(events.suffix(2).allSatisfy { $0.flags.isEmpty })
        }
    }

    func testLoopbackCandidatesRejectPhysicalDuplexAndOneWayVirtualDevices() {
        for transport in [kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeBuiltIn, kAudioDeviceTransportTypeBluetooth] {
            XCTAssertFalse(RemoteAudioDevice.isLoopbackCandidate(uid: "physical", transport: transport, hasInput: true, hasOutput: true))
        }
        XCTAssertTrue(RemoteAudioDevice.isLoopbackCandidate(uid: "virtual", transport: kAudioDeviceTransportTypeVirtual, hasInput: true, hasOutput: true))
        XCTAssertFalse(RemoteAudioDevice.isLoopbackCandidate(uid: "virtual", transport: kAudioDeviceTransportTypeVirtual, hasInput: true, hasOutput: false))
        XCTAssertTrue(RemoteAudioDevice.isLoopbackCandidate(uid: "MiRemoteV2ch_UID", transport: kAudioDeviceTransportTypeUSB, hasInput: true, hasOutput: true))
        XCTAssertFalse(RemoteAudioDevice.isLoopbackCandidate(uid: "MiRemoteV2ch_UID", transport: kAudioDeviceTransportTypeUSB, hasInput: false, hasOutput: true))
    }

    func testAsyncPreparationKeepsFirstSpeechAndStopUntilPlaybackIsReady() async throws {
        let playback = Playback()
        var prepared: ((Result<Void, Error>) -> Void)?
        playback.prepareHandler = { prepared = $0 }
        let clock = TestClock()
        let output = RemoteMicrophoneOutput(schedule: clock.schedule, makePlayback: { playback })
        output.prepareForPress()
        output.begin()
        output.append([1, 2])
        XCTAssertEqual(output.state, .preparing)
        XCTAssertTrue(playback.packets.isEmpty)
        output.end()
        var releases = 0
        output.releaseWhenFinished { releases += 1 }
        prepared?(.success(()))
        XCTAssertEqual(output.state, .draining)
        XCTAssertEqual(playback.packets, [[1, 2]])
        XCTAssertEqual(releases, 0)
        playback.completeAll()
        await drainMainQueue()
        clock.advance(0.049)
        XCTAssertEqual(output.state, .draining)
        XCTAssertEqual(releases, 0)
        clock.advance(0.001)
        XCTAssertEqual(output.state, .idle)
        XCTAssertEqual(output.deliveredSamples, 2)
        XCTAssertEqual(releases, 1)
    }

    func testCancelledPreparationCannotAffectReplacementSession() {
        let old = Playback()
        let replacement = Playback()
        var prepared: ((Result<Void, Error>) -> Void)?
        old.prepareHandler = { prepared = $0 }
        var creations = 0
        let output = RemoteMicrophoneOutput(makePlayback: {
            creations += 1
            return creations == 1 ? old : replacement
        })
        output.begin()
        output.append([1])
        output.stop()
        output.begin()
        output.append([2])
        prepared?(.failure(NSError(domain: "stale", code: 1)))
        prepared?(.success(()))
        XCTAssertEqual(output.state, .streaming)
        XCTAssertNil(output.failure)
        XCTAssertTrue(old.packets.isEmpty)
        XCTAssertEqual(replacement.packets, [[2]])
        XCTAssertEqual(output.queuedSamples, 1)
        output.stop()
    }

    func testStartupSentenceSurvivesCatchUpAndHasEnoughTimeToDrain() async {
        let playback = Playback()
        let clock = TestClock()
        var prepared: ((Result<Void, Error>) -> Void)?
        playback.prepareHandler = { prepared = $0 }
        let output = RemoteMicrophoneOutput(schedule: clock.schedule, makePlayback: { playback })
        output.prepareForPress()
        output.begin()
        for packet in 1...176 { output.append(Array(repeating: Int16(packet), count: 240)) }
        clock.advance(3)
        prepared?(.success(()))
        output.append(Array(repeating: 177, count: 240))
        XCTAssertEqual(output.droppedSamples, 0, "New packets must not trim the retained startup sentence during catch-up")
        output.end()
        var releases = 0
        output.releaseWhenFinished { releases += 1 }
        clock.advance(2)
        XCTAssertNil(output.failure, "The old one-second drain deadline must not cut off a multi-second sentence")
        XCTAssertEqual(releases, 0)
        // Finish each batch on the main queue without using real timer waits.
        while !playback.completions.isEmpty {
            playback.completeAll()
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
        clock.advance(0.05)
        XCTAssertEqual(output.state, .idle)
        XCTAssertEqual(output.deliveredSamples, 42_480)
        XCTAssertEqual(output.droppedSamples, 0)
        XCTAssertEqual(playback.packets.map { $0.first! }, (1...177).map(Int16.init))
        XCTAssertEqual(releases, 1)
        output.stop()
    }

    func testStartupTimeoutAndOverflowFailClearlyAndIgnoreLatePreparation() {
        for overflow in [false, true] {
            let playback = Playback()
            let clock = TestClock()
            var prepared: ((Result<Void, Error>) -> Void)?
            playback.prepareHandler = { prepared = $0 }
            let output = RemoteMicrophoneOutput(schedule: clock.schedule, makePlayback: { playback })
            output.prepareForPress()
            output.begin()
            var releases = 0
            output.releaseWhenFinished { releases += 1 }
            if overflow { output.append(Array(repeating: 1, count: 80_001)) }
            else { clock.advance(5) }
            XCTAssertNotNil(output.failure)
            XCTAssertEqual(output.queuedSamples, 0)
            XCTAssertEqual(releases, 1)
            prepared?(.success(()))
            clock.advance(10)
            XCTAssertTrue(playback.packets.isEmpty)
            XCTAssertNotNil(output.failure)
            XCTAssertEqual(releases, 1)
        }
    }

    func testPreparationRequiresAHealthyPlayerAndReleasesVoiceKeyOnFailure() {
        let playback = Playback()
        var prepared: ((Result<Void, Error>) -> Void)?
        playback.prepareHandler = { prepared = $0 }
        playback.ready = false
        let output = RemoteMicrophoneOutput(makePlayback: { playback })
        output.prepareForPress()
        output.begin()
        output.append([1])
        var releases = 0
        output.releaseWhenFinished { releases += 1 }
        prepared?(.success(()))
        XCTAssertEqual(output.state, .failed("遥控器音频设备尚未就绪"))
        XCTAssertEqual(releases, 1)
        XCTAssertEqual(output.queuedSamples, 0)
        XCTAssertTrue(playback.packets.isEmpty)
    }

    func testSynchronousPreparationFailureCannotBeOverwrittenByStreamingOrWarmUp() {
        let playback = Playback()
        playback.prepareHandler = { $0(.failure(NSError(domain: "test", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "播放图无效"]))) }
        let output = RemoteMicrophoneOutput(makePlayback: { playback })
        output.warmUp()
        XCTAssertEqual(output.state, .failed("播放图无效"))
        XCTAssertEqual(output.failure, "播放图无效")
        output.begin()
        output.append([1])
        XCTAssertEqual(output.state, .failed("播放图无效"))
        XCTAssertEqual(output.queuedSamples, 0)
    }

    func testOutputCreationFailurePublishesFailureInsteadOfStreaming() {
        let output = RemoteMicrophoneOutput { throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "权限不足"]) }
        var states: [RemoteAudioOutputState] = []
        output.onStateChange = { states.append($0) }
        output.handle(.started)
        output.append([1, 2, 3])
        XCTAssertEqual(states, [.failed("权限不足")])
        XCTAssertEqual(output.queuedSamples, 0)
    }

    func testVoiceKeyWaitsForBleStopAndPlaybackBeforeRelease() async throws {
        let playback = Playback()
        let clock = TestClock()
        let output = RemoteMicrophoneOutput(schedule: clock.schedule, makePlayback: { playback })
        var releases = 0
        output.prepareForPress()
        output.begin()
        output.append([1, 2, 3])
        output.releaseWhenFinished { releases += 1 }
        XCTAssertEqual(releases, 0)
        XCTAssertEqual(output.state, .streaming)
        output.handle(.ended)
        XCTAssertEqual(output.state, .draining)
        playback.completeAll()
        await drainMainQueue()
        clock.advance(0.049)
        XCTAssertEqual(releases, 0)
        clock.advance(0.001)
        XCTAssertEqual(releases, 1)
        XCTAssertEqual(output.state, .idle)
        XCTAssertEqual(output.deliveredSamples, 3)
        output.stop()
    }

    func testVoiceKeyReleaseWaitsForLateBleStart() async throws {
        let playback = Playback()
        let clock = TestClock()
        let output = RemoteMicrophoneOutput(streamEndTimeout: 0.05, schedule: clock.schedule, makePlayback: { playback })
        var released = false

        output.prepareForPress()
        output.releaseWhenFinished { released = true }
        XCTAssertFalse(released)

        output.handle(.started)
        output.append([1, 2, 3])
        output.handle(.ended)
        playback.completeAll()
        await drainMainQueue()
        clock.advance(0.05)
        XCTAssertTrue(released)
        output.stop()
    }

    func testReplacementBleStreamWhileKeyIsHeldStillWaitsForItsTail() async throws {
        let playback = Playback()
        let clock = TestClock()
        let output = RemoteMicrophoneOutput(schedule: clock.schedule, makePlayback: { playback })
        output.prepareForPress()
        output.begin()
        output.append([1, 2])
        output.begin() // A new BLE session can arrive before the HID key-up.
        output.append([3, 4])
        var releases = 0
        output.releaseWhenFinished { releases += 1 }
        XCTAssertEqual(releases, 0)
        output.end()
        playback.completeAll()
        await drainMainQueue()
        clock.advance(0.05)
        XCTAssertEqual(releases, 1)
        XCTAssertEqual(output.deliveredSamples, 2)
        output.stop()
    }

    func testMissingBleStopCannotKeepTheVoiceKeyHeld() {
        let playback = Playback()
        let clock = TestClock()
        let output = RemoteMicrophoneOutput(streamEndTimeout: 0.02, schedule: clock.schedule, makePlayback: { playback })
        output.prepareForPress()
        output.begin()
        var released = false
        output.releaseWhenFinished { released = true }
        clock.advance(0.019)
        XCTAssertEqual(output.state, .streaming)
        XCTAssertFalse(released)
        clock.advance(0.001)
        XCTAssertEqual(output.state, .draining)
        XCTAssertFalse(released)
        clock.advance(0.049)
        XCTAssertFalse(released)
        clock.advance(0.001)
        XCTAssertTrue(released)
        XCTAssertEqual(output.state, .idle)
        output.stop()
    }

    func testStopFlushesAndOldCallbacksCannotConsumeNewSessions() async throws {
        let first = Playback()
        let second = Playback()
        var attempts = 0
        let clock = TestClock()
        let output = RemoteMicrophoneOutput(schedule: clock.schedule, makePlayback: {
            defer { attempts += 1 }
            return attempts == 0 ? first : second
        })
        var releases = 0
        output.prepareForPress()
        output.begin()
        output.append([1, 2, 3])
        output.releaseWhenFinished { releases += 1 }
        output.stop()
        XCTAssertEqual(first.flushCount, 2) // session start and cancellation
        XCTAssertEqual(releases, 1)
        output.prepareForPress()
        output.begin()
        output.append([4, 5])
        first.completeAll()
        await drainMainQueue()
        XCTAssertEqual(output.queuedSamples, 2)
        XCTAssertEqual(output.deliveredSamples, 0)
        XCTAssertEqual(output.state, .streaming)
        output.stop()
    }

    func testBacklogIsBoundedAndFailedWritesReleaseTheVoiceKey() {
        let playback = Playback()
        let output = RemoteMicrophoneOutput(makePlayback: { playback })
        output.begin()
        for _ in 0..<8 { output.append(Array(repeating: 100, count: 2_000)) }
        XCTAssertEqual(output.queuedSamples, 8_000)
        XCTAssertEqual(output.droppedSamples, 8_000)
        XCTAssertEqual(playback.completions.count, 4)
        output.stop()

        playback.acceptsAudio = false
        output.prepareForPress()
        output.begin()
        output.append([1])
        var released = false
        output.releaseWhenFinished { released = true }
        XCTAssertTrue(released)
        XCTAssertEqual(output.state, .failed("无法写入遥控器音频"))
        XCTAssertEqual(output.queuedSamples, 0)
    }

    func testInterruptedPlaybackEndsSessionAndNextPressRecreatesAudioGraph() {
        let interrupted = Playback()
        let replacement = Playback()
        var creations = 0
        let output = RemoteMicrophoneOutput(makePlayback: {
            creations += 1
            return creations == 1 ? interrupted : replacement
        })
        output.prepareForPress()
        output.begin()
        var releases = 0
        output.releaseWhenFinished { releases += 1 }
        interrupted.acceptsAudio = false
        output.append([1, 2])

        XCTAssertEqual(releases, 1)
        XCTAssertEqual(output.state, .failed("无法写入遥控器音频"))

        output.prepareForPress()
        output.begin()
        output.append([3, 4])
        XCTAssertEqual(creations, 2)
        XCTAssertEqual(replacement.completions.count, 1)
        XCTAssertEqual(output.state, .streaming)
        XCTAssertEqual(output.queuedSamples, 2)
        output.stop()
    }

    func testConfigurationInterruptionReplaysPendingAudioWithoutReleasingVoiceKey() async throws {
        let interrupted = Playback()
        let replacement = Playback()
        var creations = 0
        let clock = TestClock()
        let output = RemoteMicrophoneOutput(schedule: clock.schedule, makePlayback: {
            creations += 1
            return creations == 1 ? interrupted : replacement
        })
        output.prepareForPress()
        output.begin()
        output.append([1, 2])
        var releases = 0
        output.releaseWhenFinished { releases += 1 }
        interrupted.isInterrupted = true
        output.append([3, 4])
        output.append([5, 6]) // BLE keeps arriving while the graph is replaced.
        output.end()
        interrupted.completeAll() // Stopping a player can complete discarded buffers.
        clock.advance(0.05)
        await drainMainQueue()

        XCTAssertNil(output.failure)
        XCTAssertEqual(creations, 2)
        XCTAssertEqual(replacement.packets, [[1, 2], [3, 4], [5, 6]])
        XCTAssertEqual(output.queuedSamples, 6)
        XCTAssertEqual(output.deliveredSamples, 0)
        XCTAssertEqual(releases, 0)
        replacement.completeAll()
        await drainMainQueue()
        clock.advance(0.05)
        XCTAssertEqual(output.deliveredSamples, 6)
        XCTAssertEqual(releases, 1)
        XCTAssertEqual(output.state, .idle)
        output.stop()
    }

    func testInterruptionNotificationRecoversTailWithoutAnotherAudioPacket() async throws {
        let interrupted = Playback()
        let replacement = Playback()
        var creations = 0
        let clock = TestClock()
        let output = RemoteMicrophoneOutput(schedule: clock.schedule, makePlayback: {
            creations += 1
            return creations == 1 ? interrupted : replacement
        })
        output.begin()
        output.append([1, 2])
        output.end()
        interrupted.isInterrupted = true
        interrupted.onInterruption?()
        clock.advance(0.05)
        await drainMainQueue()
        XCTAssertEqual(replacement.packets, [[1, 2]])
        XCTAssertEqual(output.state, .draining)
        replacement.completeAll()
        await drainMainQueue()
        clock.advance(0.05)
        XCTAssertEqual(output.state, .idle)
        output.stop()
    }

    func testStopDuringRecoveryCancelsReplacementAndReleasesVoiceKeyOnce() async throws {
        let interrupted = Playback()
        var creations = 0
        let clock = TestClock()
        let output = RemoteMicrophoneOutput(schedule: clock.schedule, makePlayback: { creations += 1; return interrupted })
        output.prepareForPress()
        output.begin()
        output.append([1])
        var releases = 0
        output.releaseWhenFinished { releases += 1 }
        interrupted.isInterrupted = true
        interrupted.onInterruption?()
        output.stop()
        interrupted.completeAll()
        await drainMainQueue()
        clock.advance(0.15)
        XCTAssertEqual(creations, 1)
        XCTAssertEqual(output.deliveredSamples, 0)
        XCTAssertEqual(output.queuedSamples, 0)
        XCTAssertEqual(releases, 1)
        XCTAssertEqual(output.state, .idle)
    }

    func testRepeatedConfigurationChangesHaveABoundedRecoveryBudget() {
        let playbacks = (0..<4).map { _ in Playback() }
        var creations = 0
        let clock = TestClock()
        let output = RemoteMicrophoneOutput(schedule: clock.schedule, makePlayback: {
            defer { creations += 1 }
            return playbacks[min(creations, 3)]
        })
        output.prepareForPress()
        output.begin()
        output.append([1])
        var releases = 0
        output.releaseWhenFinished { releases += 1 }
        for index in 0..<3 {
            playbacks[index].isInterrupted = true
            playbacks[index].onInterruption?()
            clock.advance(0.05)
        }
        XCTAssertEqual(creations, 3)
        XCTAssertNotNil(output.failure)
        XCTAssertEqual(releases, 1)
        XCTAssertEqual(output.queuedSamples, 0)
        output.prepareForPress()
        output.begin()
        output.append([2])
        XCTAssertEqual(creations, 4)
        XCTAssertNil(output.failure)
        XCTAssertEqual(output.state, .streaming)
        output.stop()
    }

    func testDelayedStartupBuffersSpeechAndAnEmptyStreamCanDrain() {
        let playback = Playback()
        playback.startupDelay = 0.02
        let clock = TestClock()
        let output = RemoteMicrophoneOutput(schedule: clock.schedule, makePlayback: { playback })
        output.begin()
        output.append([1, 2])
        XCTAssertEqual(playback.startCount, 0)
        XCTAssertTrue(playback.packets.isEmpty)
        clock.advance(0.019)
        XCTAssertEqual(playback.startCount, 0)
        XCTAssertTrue(playback.packets.isEmpty)
        clock.advance(0.001)
        XCTAssertEqual(playback.startCount, 1)
        XCTAssertEqual(playback.packets, [[1, 2]])
        output.stop()

        output.begin()
        output.end()
        clock.advance(0.15)
        XCTAssertEqual(output.state, .idle)
        XCTAssertNil(output.failure)
        output.stop()
    }

    func testStopBeforeDelayedStartupNeverStartsTheCancelledGraph() {
        let playback = Playback()
        playback.startupDelay = 0.02
        let clock = TestClock()
        let output = RemoteMicrophoneOutput(schedule: clock.schedule, makePlayback: { playback })
        output.begin()
        output.append([1])
        output.stop()
        clock.advance(0.05)
        XCTAssertEqual(playback.startCount, 0)
        XCTAssertTrue(playback.packets.isEmpty)
        XCTAssertEqual(output.state, .idle)
    }

    func testHealthyDeviceNotificationKeepsTheCurrentPlayerAndPendingAudio() {
        let playback = Playback()
        let clock = TestClock()
        var creations = 0
        let output = RemoteMicrophoneOutput(schedule: clock.schedule, makePlayback: {
            creations += 1
            return playback
        })
        output.begin()
        output.append([1, 2])
        output.audioDevicesChanged()
        clock.advance(0.1)
        XCTAssertEqual(creations, 1)
        XCTAssertEqual(output.state, .streaming)
        XCTAssertEqual(output.queuedSamples, 2)
        XCTAssertEqual(playback.packets, [[1, 2]])
        output.stop()
    }

    func testUnhealthyDeviceNotificationReplaysAudioAndRetiresOldCallbacks() async {
        let old = Playback()
        let replacement = Playback()
        let clock = TestClock()
        old.healthHandler = { $0(false) }
        var creations = 0
        let output = RemoteMicrophoneOutput(schedule: clock.schedule, makePlayback: {
            creations += 1
            return creations == 1 ? old : replacement
        })
        output.prepareForPress()
        output.begin()
        output.append([1, 2])
        output.audioDevicesChanged()
        output.append([3, 4])
        output.end()
        var releases = 0
        output.releaseWhenFinished { releases += 1 }
        old.completeAll()
        await drainMainQueue()
        XCTAssertEqual(output.queuedSamples, 4)
        XCTAssertEqual(output.deliveredSamples, 0)
        clock.advance(0.049)
        XCTAssertEqual(creations, 1)
        clock.advance(0.001)
        XCTAssertEqual(creations, 2)
        XCTAssertEqual(replacement.packets, [[1, 2], [3, 4]])
        XCTAssertEqual(releases, 0)
        replacement.completeAll()
        await drainMainQueue()
        clock.advance(0.05)
        XCTAssertEqual(output.deliveredSamples, 4)
        XCTAssertEqual(output.droppedSamples, 0)
        XCTAssertEqual(output.state, .idle)
        XCTAssertEqual(releases, 1)
        output.stop()
    }

    func testLateDeviceHealthFailureCannotRebuildAReplacementSession() throws {
        let old = Playback()
        let replacement = Playback()
        let clock = TestClock()
        var healthReply: ((Bool) -> Void)?
        old.healthHandler = { healthReply = $0 }
        var creations = 0
        let output = RemoteMicrophoneOutput(schedule: clock.schedule, makePlayback: {
            creations += 1
            return creations == 1 ? old : replacement
        })
        output.begin()
        output.audioDevicesChanged()
        let reply = try XCTUnwrap(healthReply)
        output.stop()
        output.begin()
        output.append([7, 8])
        reply(false)
        clock.advance(10)
        XCTAssertEqual(creations, 2)
        XCTAssertEqual(output.state, .streaming)
        XCTAssertEqual(output.queuedSamples, 2)
        XCTAssertEqual(replacement.packets, [[7, 8]])
        XCTAssertNil(output.failure)
        output.stop()
    }

    func testIdleDeviceChangeDiscardsWarmPlayerAndNextPressCreatesAnother() {
        let clock = TestClock()
        var creations = 0
        let output = RemoteMicrophoneOutput(schedule: clock.schedule, makePlayback: {
            creations += 1
            return Playback()
        })
        output.warmUp()
        XCTAssertEqual(creations, 1)
        output.audioDevicesChanged()
        clock.advance(10)
        XCTAssertEqual(creations, 1)
        XCTAssertEqual(output.state, .idle)
        output.begin()
        XCTAssertEqual(creations, 2)
        XCTAssertEqual(output.state, .streaming)
        output.stop()
    }

    func testDrainDeadlineFailsAndReleasesOnceEvenIfPlaybackCompletesLate() async {
        let playback = Playback()
        let clock = TestClock()
        let output = RemoteMicrophoneOutput(schedule: clock.schedule, makePlayback: { playback })
        output.prepareForPress()
        output.begin()
        output.append(Array(repeating: 1, count: 1_600))
        output.end()
        var releases = 0
        output.releaseWhenFinished { releases += 1 }
        clock.advance(1.099)
        XCTAssertEqual(output.state, .draining)
        XCTAssertEqual(releases, 0)
        clock.advance(0.001)
        XCTAssertEqual(output.state, .failed("遥控器音频输出超时"))
        XCTAssertEqual(releases, 1)
        XCTAssertEqual(output.queuedSamples, 0)
        playback.completeAll()
        await drainMainQueue()
        clock.advance(10)
        XCTAssertEqual(output.deliveredSamples, 0)
        XCTAssertEqual(releases, 1)
        output.stop()
    }

    func testFlushFailureDuringPreparationOrWarmReuseFailsWithoutSchedulingAudio() {
        for reuseWarmPlayer in [false, true] {
            let playback = Playback()
            let clock = TestClock()
            let output = RemoteMicrophoneOutput(schedule: clock.schedule, makePlayback: { playback })
            if reuseWarmPlayer { output.warmUp() }
            playback.flushError = RemoteMicrophoneOutput.outputError("无法清除旧音频")
            output.prepareForPress()
            output.begin()
            output.append([1, 2])
            var releases = 0
            output.releaseWhenFinished { releases += 1 }
            clock.advance(10)
            XCTAssertEqual(output.state, .failed("无法清除旧音频"))
            XCTAssertEqual(output.queuedSamples, 0)
            XCTAssertTrue(playback.packets.isEmpty)
            XCTAssertEqual(releases, 1)
            output.stop()
        }
    }

    func testDuplicatePlaybackCompletionCannotConsumeAnotherBuffersSamples() async throws {
        let playback = Playback()
        let clock = TestClock()
        let output = RemoteMicrophoneOutput(schedule: clock.schedule, makePlayback: { playback })
        output.begin()
        output.append([1, 2])
        output.append([3, 4, 5])
        let first = try XCTUnwrap(playback.completions.first)
        first()
        first()
        await drainMainQueue()
        XCTAssertEqual(output.deliveredSamples, 2)
        XCTAssertEqual(output.queuedSamples, 3)
        output.end()
        playback.completeAll()
        await drainMainQueue()
        clock.advance(0.05)
        XCTAssertEqual(output.deliveredSamples, 5)
        XCTAssertEqual(output.queuedSamples, 0)
        XCTAssertEqual(output.state, .idle)
        output.stop()
    }

    func testEnhancementIsPacketIndependentAndLimitsAfterGain() {
        let pcm = (0..<1600).map { Int16(sin(Double($0) * 2 * .pi * 440 / 16000) * 24_000) }
        var whole = RemoteVoiceEnhancer(gainDB: 24)
        var chunks = RemoteVoiceEnhancer(gainDB: 24)
        let expected = whole.process(pcm)
        let actual = chunks.process(Array(pcm.prefix(123))) + chunks.process(Array(pcm.dropFirst(123)))
        XCTAssertEqual(actual, expected)
        XCTAssertTrue(actual.allSatisfy { $0.isFinite && abs($0) <= 0.999 })
        var zero = RemoteVoiceEnhancer()
        var explicitZero = RemoteVoiceEnhancer(gainDB: 0)
        XCTAssertEqual(zero.process(pcm), explicitZero.process(pcm))
        chunks.setGainDB(.infinity)
        chunks.reset()
        zero.reset()
        XCTAssertEqual(chunks.process(pcm), zero.process(pcm))
    }

    func testAdpcmVectorsAndFragmentedFrames() {
        var decoder = RemoteADPCMDecoder()
        XCTAssertEqual(decoder.decode(Data([0x7F])), [11, -19])
        var whole = RemoteVoiceStream()
        var chunks = RemoteVoiceStream()
        whole.start(session: 1)
        chunks.start(session: 1)
        let packet = Data(repeating: 0x17, count: 120)
        let expected = whole.append(packet, frameBytes: 120)
        XCTAssertTrue(chunks.append(packet.prefix(17), frameBytes: 120).isEmpty)
        XCTAssertEqual(chunks.append(packet.dropFirst(17), frameBytes: 120), expected)
        chunks.stop()
        XCTAssertTrue(chunks.append(packet, frameBytes: 120).isEmpty)
    }
}

private final class Playback: RemoteMicrophonePlayback {
    var ready = true
    var isReady: Bool { ready && !isInterrupted }
    var prepareHandler: ((@escaping (Result<Void, Error>) -> Void) -> Void)?
    var healthHandler: ((@escaping (Bool) -> Void) -> Void)?
    func prepare(completion: @escaping (Result<Void, Error>) -> Void) {
        if let prepareHandler { prepareHandler(completion) }
        else { start(); completion(.success(())) }
    }
    func checkHealth(completion: @escaping (Bool) -> Void) {
        if let healthHandler { healthHandler(completion) }
        else { completion(isReady) }
    }
    var completions: [() -> Void] = []
    var packets: [[Int16]] = []
    var isInterrupted = false
    var onInterruption: (() -> Void)?
    var startupDelay: TimeInterval = 0
    var startCount = 0
    func start() { startCount += 1 }
    var acceptsAudio = true
    var flushCount = 0
    var flushError: Error?
    func schedule(_ pcm: [Int16], completion: @escaping () -> Void) -> Bool {
        guard acceptsAudio, !isInterrupted else { return false }
        packets.append(pcm)
        completions.append(completion)
        return true
    }
    func stop() {}
    func flush() throws {
        flushCount += 1
        if let flushError { throw flushError }
    }
    func completeAll() {
        let pending = completions
        completions.removeAll()
        for completion in pending { completion() }
    }
}
