import SwiftUI

enum SetupStep: String, CaseIterable, Codable, Identifiable {
    case welcome, permissions, remote, audio, voice, test, complete

    var id: String { rawValue }
    var index: Int { Self.allCases.firstIndex(of: self)! }
    var title: String {
        switch self {
        case .welcome: "欢迎使用"
        case .permissions: "系统权限"
        case .remote: "连接遥控器"
        case .audio: "麦克风设置"
        case .voice: "语音快捷键"
        case .test: "试用语音"
        case .complete: "设置完成"
        }
    }
    var symbol: String {
        switch self {
        case .welcome: "hand.wave"
        case .permissions: "lock.shield"
        case .remote: "appletvremote.gen4"
        case .audio: "mic"
        case .voice: "keyboard"
        case .test: "waveform"
        case .complete: "checkmark.circle"
        }
    }
}

/// Live capabilities are checked again on every navigation action. A saved step
/// is a place to resume, never evidence that permissions or hardware still work.
struct SetupReadiness {
    var permissions = false
    var remote = false
    var audio = false
    var outputHealthy = true
    var ready: Bool { permissions && remote && audio }
}

@MainActor
final class SetupFlow: ObservableObject {
    private struct Progress: Codable {
        var step: SetupStep = .welcome
        var completed = false
    }

    @Published private(set) var step: SetupStep
    @Published private(set) var completed: Bool
    @Published private(set) var isPresented = false
    @Published private(set) var testedInputs: Set<ControllerInput> = []
    @Published private(set) var voiceStarted = false
    @Published private(set) var voiceSamplesReceived = false
    @Published private(set) var voiceEnded = false
    @Published var toolConfigured = false
    @Published var transcriptConfirmed = false
    var usesRemoteMicrophone = true
    private let defaults: UserDefaults
    private var voiceActive = false
    /// Release active actions whenever the input routing policy changes.
    var onRoutingChange: (() -> Void)?

    init(defaults: UserDefaults) {
        self.defaults = defaults
        let progress = SettingsStorage.load(Progress.self, SettingsKeys.Stored.setupProgress, defaults: defaults) ?? Progress()
        step = progress.step
        completed = progress.completed
        // Hardware evidence is deliberately not persisted across launches.
        if !completed && step.index > SetupStep.remote.index { step = .remote }
    }

    func startIfNeeded() { if !completed { present() } }

    func present() {
        guard !isPresented else { return }
        if completed { step = .welcome }
        resetEvidence()
        isPresented = true
        onRoutingChange?()
    }

    func pause() {
        guard isPresented else { return }
        isPresented = false
        onRoutingChange?()
        resetEvidence()
        if !completed && step.index > SetupStep.remote.index { step = .remote }
        save()
    }

    func canContinue(_ readiness: SetupReadiness) -> Bool {
        switch step {
        case .welcome: true
        case .permissions: readiness.permissions
        case .remote: readiness.permissions && readiness.remote && !testedInputs.isEmpty
        case .audio: readiness.permissions && readiness.remote && readiness.audio
        case .voice: readiness.ready && toolConfigured
        case .test, .complete: readiness.ready && readiness.outputHealthy && voiceTestSucceeded && transcriptConfirmed
        }
    }

    func advance(_ readiness: SetupReadiness) {
        guard isPresented, canContinue(readiness) else { return }
        if step == .complete {
            completed = true
            isPresented = false
        } else {
            step = SetupStep.allCases[step.index + 1]
        }
        onRoutingChange?()
        save()
    }

    func goBack(to destination: SetupStep) {
        guard isPresented, destination.index < step.index else { return }
        onRoutingChange?()
        step = destination
        resetVoiceTest()
        save()
    }

    /// Return true for input consumed by the guide. Only the voice key in the
    /// trial step may reach the normal runtime; ordinary mappings stay muted.
    func consumes(_ input: ControllerInput, pressed: Bool) -> Bool {
        guard isPresented else { return false }
        if step == .remote, pressed, input != .options { testedInputs.insert(input) }
        return !(step == .test && input == .options)
    }

    var allowsVoiceCapture: Bool { !isPresented || step == .test }
    var voiceTestSucceeded: Bool { voiceStarted && (!usesRemoteMicrophone || voiceSamplesReceived) && voiceEnded }

    func observeVoice(_ event: RemoteVoiceStreamEvent) {
        guard isPresented, step == .test else { return }
        switch event {
        case .started:
            resetVoiceTest()
            voiceActive = true
            voiceStarted = true
        case .ended:
            voiceEnded = voiceActive && (!usesRemoteMicrophone || voiceSamplesReceived)
            voiceActive = false
        case .cancelled:
            if voiceActive { resetVoiceTest() }
        }
    }

    func observeSamples(_ count: Int) {
        guard isPresented, step == .test, voiceActive, count > 0,
              !voiceSamplesReceived else { return }
        voiceSamplesReceived = true
    }

    func resetVoiceTest() {
        guard voiceActive || voiceStarted || voiceSamplesReceived || voiceEnded || transcriptConfirmed else { return }
        voiceActive = false
        voiceStarted = false
        voiceSamplesReceived = false
        voiceEnded = false
        transcriptConfirmed = false
    }

    func resetEvidence() {
        if !testedInputs.isEmpty { testedInputs = [] }
        if toolConfigured { toolConfigured = false }
        resetVoiceTest()
    }

    private func save() {
        SettingsStorage.save(Progress(step: step, completed: completed), SettingsKeys.Stored.setupProgress, defaults: defaults)
    }
}

extension RemoteDashboardModel {
    var setupReadiness: SetupReadiness {
        SetupReadiness(
            permissions: bluetoothGranted && inputGranted && accessibilityGranted
                && (!useRemoteMicrophone || microphoneGranted),
            remote: isConnected && (!useRemoteMicrophone || voiceReady),
            audio: !useRemoteMicrophone || (outputDevices.contains { $0.id == outputUID }
                && (outputUID != RemoteMicrophoneOutput.deviceUID || (microphoneInstalled && !microphoneUpdateAvailable))
                && !microphoneOperationInProgress),
            outputHealthy: !audioOutputFailed
        )
    }

    private var audioOutputFailed: Bool {
        if case .failed = audioOutputState { return true }
        return false
    }
}
