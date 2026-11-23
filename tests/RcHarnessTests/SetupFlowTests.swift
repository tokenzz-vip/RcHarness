import XCTest
@testable import RcHarness

@MainActor
final class SetupFlowTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    private let ready = SetupReadiness(permissions: true, remote: true, audio: true)

    override func setUp() async throws {
        suite = "RcHarness.SetupFlowTests." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() async throws { defaults.removePersistentDomain(forName: suite) }

    private func reach(_ step: SetupStep, flow: SetupFlow) {
        flow.present()
        while flow.step.index < step.index {
            _ = flow.consumes(.dpadUp, pressed: true)
            flow.toolConfigured = true
            if flow.step == .test {
                flow.observeVoice(.started)
                flow.observeSamples(20)
                flow.observeVoice(.ended)
                flow.transcriptConfirmed = true
            }
            let before = flow.step
            flow.advance(ready)
            if before == flow.step { XCTFail("Cannot advance from \(before)"); return }
        }
    }

    func testFirstLaunchPausesAndResumesWithoutCompleting() {
        let flow = SetupFlow(defaults: defaults)
        XCTAssertFalse(flow.isPresented)
        flow.startIfNeeded()
        XCTAssertTrue(flow.isPresented)
        flow.advance(ready)
        XCTAssertEqual(flow.step, .permissions)
        flow.pause()
        XCTAssertFalse(flow.isPresented)
        XCTAssertFalse(flow.completed)
        let restored = SetupFlow(defaults: defaults)
        restored.startIfNeeded()
        XCTAssertTrue(restored.isPresented)
        XCTAssertEqual(restored.step, .permissions)
    }

    func testNavigationRechecksPermissionsConnectionsAndFreshButtonInput() {
        let flow = SetupFlow(defaults: defaults)
        reach(.permissions, flow: flow)
        flow.advance(SetupReadiness())
        XCTAssertEqual(flow.step, .permissions)
        flow.advance(ready)
        XCTAssertEqual(flow.step, .remote)
        XCTAssertFalse(flow.canContinue(ready))
        XCTAssertTrue(flow.consumes(.options, pressed: true))
        XCTAssertTrue(flow.testedInputs.isEmpty)
        XCTAssertTrue(flow.consumes(.dpadUp, pressed: false))
        XCTAssertTrue(flow.testedInputs.isEmpty)
        XCTAssertTrue(flow.consumes(.dpadUp, pressed: true))
        XCTAssertFalse(flow.canContinue(SetupReadiness(permissions: true, remote: false, audio: true)))
        XCTAssertTrue(flow.canContinue(ready))
    }

    func testOnlyVoiceTrialRoutesVoiceInputAndAllOrdinaryActionsStayMuted() {
        let flow = SetupFlow(defaults: defaults)
        XCTAssertFalse(flow.consumes(.home, pressed: true))
        reach(.test, flow: flow)
        for input in ControllerInput.allCases {
            XCTAssertEqual(flow.consumes(input, pressed: true), input != .options)
            XCTAssertEqual(flow.consumes(input, pressed: false), input != .options)
        }
        XCTAssertTrue(flow.allowsVoiceCapture)
        flow.goBack(to: .voice)
        XCTAssertFalse(flow.allowsVoiceCapture)
        XCTAssertTrue(flow.consumes(.options, pressed: true))
        flow.pause()
        XCTAssertFalse(flow.consumes(.home, pressed: true))
        XCTAssertTrue(flow.allowsVoiceCapture)
    }

    func testVoiceTrialNeedsOneCompleteFreshAudioSessionAndUserConfirmation() {
        let flow = SetupFlow(defaults: defaults)
        reach(.test, flow: flow)
        flow.observeSamples(100)
        flow.observeVoice(.ended)
        XCTAssertFalse(flow.voiceTestSucceeded)
        flow.observeVoice(.started)
        flow.observeVoice(.ended)
        XCTAssertFalse(flow.voiceTestSucceeded)
        flow.observeVoice(.started)
        flow.observeSamples(100)
        flow.observeVoice(.cancelled)
        XCTAssertFalse(flow.voiceTestSucceeded)
        flow.observeVoice(.started)
        flow.observeSamples(100)
        flow.observeVoice(.ended)
        XCTAssertTrue(flow.voiceTestSucceeded)
        XCTAssertFalse(flow.canContinue(ready))
        flow.transcriptConfirmed = true
        XCTAssertTrue(flow.canContinue(ready))
        flow.observeVoice(.started)
        XCTAssertFalse(flow.transcriptConfirmed)
        XCTAssertFalse(flow.voiceTestSucceeded)
    }

    func testCompletionPersistsAndRerunningDoesNotClearConfigurationOrCompletion() {
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        let backup = model.configurationBackup()
        reach(.complete, flow: model.setup)
        model.setup.advance(SetupReadiness())
        XCTAssertFalse(model.setup.completed)
        model.setup.advance(ready)
        XCTAssertTrue(model.setup.completed)
        XCTAssertFalse(model.setup.isPresented)
        let restored = SetupFlow(defaults: defaults)
        restored.startIfNeeded()
        XCTAssertFalse(restored.isPresented)
        restored.present()
        XCTAssertEqual(restored.step, .welcome)
        restored.pause()
        XCTAssertTrue(SetupFlow(defaults: defaults).completed)
        XCTAssertEqual(model.configurationBackup(), backup)
    }

    func testResumingLateStepRequiresNewHardwareEvidenceAndToolConfirmation() {
        let flow = SetupFlow(defaults: defaults)
        reach(.test, flow: flow)
        // Simulate termination without an orderly pause.
        let relaunched = SetupFlow(defaults: defaults)
        relaunched.startIfNeeded()
        XCTAssertEqual(relaunched.step, .remote)
        XCTAssertTrue(relaunched.testedInputs.isEmpty)
        XCTAssertFalse(relaunched.toolConfigured)
        XCTAssertFalse(relaunched.voiceTestSucceeded)
        flow.pause()
        flow.present()
        XCTAssertEqual(flow.step, .remote)
        XCTAssertTrue(flow.testedInputs.isEmpty)
    }

    func testEveryRoutingTransitionReleasesActionsAndGoingBackClearsTrial() {
        let flow = SetupFlow(defaults: defaults)
        var resets = 0
        flow.onRoutingChange = { resets += 1 }
        reach(.complete, flow: flow)
        XCTAssertEqual(resets, SetupStep.allCases.count)
        XCTAssertTrue(flow.voiceTestSucceeded)
        flow.goBack(to: .test)
        XCTAssertFalse(flow.voiceTestSucceeded)
        XCTAssertFalse(flow.transcriptConfirmed)
        XCTAssertEqual(resets, SetupStep.allCases.count + 1)
        flow.goBack(to: .complete)
        XCTAssertEqual(flow.step, .test)
        flow.pause()
        XCTAssertEqual(resets, SetupStep.allCases.count + 2)
    }

    func testCancellingRuntimeAfterAdvancingDoesNotInvalidateCompletedTrial() {
        let flow = SetupFlow(defaults: defaults)
        flow.onRoutingChange = { flow.observeVoice(.cancelled) }
        reach(.complete, flow: flow)
        XCTAssertTrue(flow.voiceTestSucceeded)
        XCTAssertTrue(flow.transcriptConfirmed)
        flow.advance(ready)
        XCTAssertTrue(flow.completed)
    }

    func testConnectionAndConfigurationChangesInvalidateEvidenceWithoutDependingOnTheView() {
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        reach(.complete, flow: model.setup)
        model.isConnected = true
        model.isConnected = false
        XCTAssertTrue(model.setup.testedInputs.isEmpty)
        XCTAssertFalse(model.setup.voiceTestSucceeded)
        XCTAssertFalse(model.setup.toolConfigured)

        model.setup.goBack(to: .test)
        model.setup.observeVoice(.started)
        model.setup.observeSamples(100)
        model.setup.observeVoice(.ended)
        model.setup.transcriptConfirmed = true
        model.outputUID = "different-receiver"
        XCTAssertFalse(model.setup.voiceTestSucceeded)
        XCTAssertFalse(model.setup.transcriptConfirmed)

        model.setup.observeVoice(.started)
        model.setup.observeSamples(100)
        model.setup.observeVoice(.ended)
        model.microphoneGranted = false
        XCTAssertFalse(model.setup.voiceTestSucceeded)
    }

    func testReadinessValidatesSelectedReceiverAndDriverUpdates() {
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        model.bluetoothGranted = true
        model.inputGranted = true
        model.accessibilityGranted = true
        model.microphoneGranted = true
        model.isConnected = true
        model.voiceReady = true
        model.outputUID = RemoteMicrophoneOutput.deviceUID
        model.outputDevices = [RemoteAudioDevice(id: model.outputUID, name: "Test receiver")]
        model.microphoneInstalled = true
        model.microphoneUpdateAvailable = false
        XCTAssertTrue(model.setupReadiness.ready)
        model.microphoneUpdateAvailable = true
        XCTAssertFalse(model.setupReadiness.audio)
        model.outputUID = "another-loopback"
        XCTAssertFalse(model.setupReadiness.audio)
        model.outputDevices = [RemoteAudioDevice(id: model.outputUID, name: "Other receiver")]
        XCTAssertTrue(model.setupReadiness.audio)
        model.microphoneOperationInProgress = true
        XCTAssertFalse(model.setupReadiness.audio)
        model.microphoneOperationInProgress = false
        model.audioOutputState = .failed("Test output failure")
        XCTAssertTrue(model.setupReadiness.audio, "Keep the audio setup reachable so the output can be retried")
        XCTAssertFalse(model.setupReadiness.outputHealthy)
        model.microphoneGranted = false
        XCTAssertFalse(model.setupReadiness.permissions)
    }

    func testHostMicrophoneModeDoesNotRequireRcHarnessPermissionVoiceOrLoopback() {
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        model.useRemoteMicrophone = false
        model.bluetoothGranted = true
        model.inputGranted = true
        model.accessibilityGranted = true
        model.microphoneGranted = false
        model.isConnected = true
        model.voiceReady = false
        model.outputUID = "missing-loopback"
        model.outputDevices = []

        XCTAssertTrue(model.setupReadiness.permissions)
        XCTAssertTrue(model.setupReadiness.remote)
        XCTAssertTrue(model.setupReadiness.audio)
    }
}
