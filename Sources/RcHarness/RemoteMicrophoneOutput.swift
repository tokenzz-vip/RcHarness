import AVFoundation
import Foundation

enum RemoteAudioOutputState: Equatable {
    case idle, preparing, streaming, draining, failed(String)
}

protocol RemoteMicrophonePlayback: AnyObject {
    var isInterrupted: Bool { get }
    var isReady: Bool { get }
    var startupDelay: TimeInterval { get }
    var onInterruption: (() -> Void)? { get set }
    func prepare(completion: @escaping (Result<Void, Error>) -> Void)
    func checkHealth(completion: @escaping (Bool) -> Void)
    func start() throws
    func schedule(_ pcm: [Int16], completion: @escaping () -> Void) -> Bool
    func stop()
    func flush() throws
}

extension RemoteMicrophonePlayback {
    var isInterrupted: Bool { false }
    var isReady: Bool { !isInterrupted }
    var startupDelay: TimeInterval { 0 }
    var onInterruption: (() -> Void)? { get { nil } set {} }
    func prepare(completion: @escaping (Result<Void, Error>) -> Void) {
        do { try start(); completion(.success(())) }
        catch { completion(.failure(error)) }
    }
    func checkHealth(completion: @escaping (Bool) -> Void) { completion(isReady) }
    func start() throws {}
    func flush() throws {}
}

/// A dedicated loopback output, never the user's speakers. Codex (or another
/// dictation client) records RcHarness's own input as a normal microphone.
@MainActor
final class RemoteMicrophoneOutput {
    typealias Scheduler = (TimeInterval, @escaping () -> Void) -> DispatchWorkItem
    nonisolated static func mainQueue(after delay: TimeInterval, operation: @escaping () -> Void) -> DispatchWorkItem {
        let work = DispatchWorkItem(block: operation)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        return work
    }
    nonisolated static let deviceName = "RcHarness 遥控器麦克风"
    nonisolated static let deviceUID = "vip.tokenzz.rcharness.microphone.device"
    private static let maximumQueuedSamples = PCMBacklog.voiceLimit
    private static let maximumScheduledBuffers = 4
    private static let maximumRecoveryAttempts = 2
    private let makePlayback: () throws -> RemoteMicrophonePlayback
    private let schedule: Scheduler
    private let streamEndTimeout: TimeInterval
    private var playback: RemoteMicrophonePlayback?
    private var generation = 0
    private var buttonPressed = false
    private var buttonGeneration: Int?
    private var bufferedPCM = PCMBacklog()
    private var scheduledPCM: [(id: UUID, pcm: [Int16])] = []
    private var playbackGeneration = 0
    private var recoveryAttempts = 0
    private var recoveryWork: DispatchWorkItem?
    private var startupWork: DispatchWorkItem?
    private var preparing = false
    private var preparationTimeout: DispatchWorkItem?
    private(set) var queuedSamples = 0
    private var accepting = false
    private var draining = false
    private var drainCompletions: [() -> Void] = []
    private var releaseTimeout: DispatchWorkItem?
    private var startReleaseTimeout: DispatchWorkItem?
    private var drainTimeout: DispatchWorkItem?
    private var drainCompletion: DispatchWorkItem?
    private(set) var deliveredSamples = 0
    private(set) var droppedSamples = 0
    private(set) var failure: String? {
        didSet { if let failure { state = .failed(failure) } }
    }
    private(set) var state: RemoteAudioOutputState = .idle {
        didSet { if state != oldValue { onStateChange?(state) } }
    }
    var onStateChange: ((RemoteAudioOutputState) -> Void)?

    private var deviceObserver: NSObjectProtocol?

    /// Plays into the loopback device chosen in settings, read at the start
    /// of each session so a changed selection takes effect immediately.
    convenience init(streamEndTimeout: TimeInterval = 1, outputUID: @escaping () -> String = RemoteMicrophoneOutput.savedOutputUID) {
        self.init(streamEndTimeout: streamEndTimeout, makePlayback: {
            try RemoteMicrophoneOutput.makeAuthorizedPlayback { try CoreAudioRemoteMicrophonePlayback(outputUID: outputUID()) }
        })
    }

    init(streamEndTimeout: TimeInterval = 1, schedule: @escaping Scheduler = mainQueue,
         makePlayback: @escaping () throws -> RemoteMicrophonePlayback) {
        self.streamEndTimeout = streamEndTimeout
        self.schedule = schedule
        self.makePlayback = makePlayback
        deviceObserver = NotificationCenter.default.addObserver(
            forName: .rcHarnessAudioDevicesChanged, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.audioDevicesChanged() } }
    }

    deinit {
        if let deviceObserver { NotificationCenter.default.removeObserver(deviceObserver) }
        playback?.stop()
    }

    nonisolated static func savedOutputUID() -> String {
        UserDefaults.standard.string(forKey: SettingsKeys.outputUID) ?? deviceUID
    }

    nonisolated static var installed: Bool { AudioDeviceCatalog.shared.device(uid: deviceUID)?.isLoopback == true }

    nonisolated static func outputDevices() -> [RemoteAudioDevice] {
        AudioDeviceCatalog.shared.devices()
            .filter(\.isLoopback)
            .map { RemoteAudioDevice(id: $0.uid, name: $0.name) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The loopback device has both input and output streams. Selecting it can
    /// synchronously ask Core Audio/TCC for microphone access even though this
    /// backend only writes audio. Startup warm-up must never trigger that
    /// implicit permission prompt or block the main queue waiting for it.
    nonisolated static func makeAuthorizedPlayback(
        authorizationStatus: () -> AVAuthorizationStatus = { AVCaptureDevice.authorizationStatus(for: .audio) },
        makePlayback: () throws -> RemoteMicrophonePlayback
    ) throws -> RemoteMicrophonePlayback {
        try requireRecordingAuthorization(authorizationStatus())
        return try makePlayback()
    }

    nonisolated static func requireRecordingAuthorization(
        _ status: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    ) throws {
        guard status == .authorized else {
            throw outputError("遥控器麦克风需要录音权限。请前往设置 → 权限 → 麦克风，完成授权后重新按语音键。")
        }
    }

    func warmUp() {
        guard playback == nil, !accepting, !draining else { return }
        failure = nil
        do {
            try createPlayback()
        } catch {
            failure = error.localizedDescription
            AudioDiagnostics.log("[RcHarness] Xiaomi voice output: \(error.localizedDescription)")
        }
    }

    func begin() {
        let pendingReleases = startReleaseTimeout != nil ? drainCompletions : []
        if startReleaseTimeout != nil { drainCompletions.removeAll() }
        startReleaseTimeout?.cancel()
        startReleaseTimeout = nil
        if accepting || draining || queuedSamples > 0 || !scheduledPCM.isEmpty || !drainCompletions.isEmpty {
            stop()
        }
        generation += 1
        queuedSamples = 0
        deliveredSamples = 0
        droppedSamples = 0
        recoveryAttempts = 0
        failure = nil
        accepting = true
        do {
            if playback == nil { try createPlayback() }
            else if !preparing { try playback?.flush() }
            guard accepting else {
                for completion in pendingReleases { completion() }
                return
            }
            if !preparing { state = .streaming }
            observeInterruption()
            if buttonPressed { buttonGeneration = generation }
            if !pendingReleases.isEmpty {
                drainCompletions.append(contentsOf: pendingReleases)
                scheduleReleaseTimeout()
            }
        } catch {
            fail(error.localizedDescription)
            AudioDiagnostics.log("[RcHarness] Xiaomi voice output: \(error.localizedDescription)")
            for completion in pendingReleases { completion() }
        }
    }

    func append(_ pcm: [Int16]) {
        guard accepting, playback != nil || recoveryWork != nil, !pcm.isEmpty else { return }
        // Keep a cold graph's first sentence until it catches up. Applying the
        // live half-second limit here used to discard almost all initial speech.
        let scheduledSamples = queuedSamples - bufferedPCM.count
        let startupBacklog = preparing || startupWork != nil || recoveryWork != nil
            || queuedSamples > Self.maximumQueuedSamples
        if startupBacklog, queuedSamples + pcm.count > PCMBacklog.startupVoiceLimit {
            fail("遥控器音频设备准备过慢，请松开语音键后重试。")
            return
        }
        let limit = startupBacklog ? PCMBacklog.startupVoiceLimit : Self.maximumQueuedSamples
        let wasTrimming = droppedSamples > 0
        droppedSamples += bufferedPCM.append(pcm, limit: limit - scheduledSamples)
        queuedSamples = scheduledSamples + bufferedPCM.count
        if !wasTrimming, droppedSamples > 0 {
            AudioDiagnostics.log("[RcHarness] Xiaomi voice output backlog trimming started pending=\(queuedSamples)")
        }
        guard !bufferedPCM.isEmpty else { return }
        scheduleBufferedAudio()
    }

    private func scheduleBufferedAudio() {
        guard !preparing, startupWork == nil, recoveryWork == nil, let playback else { return }
        if playback.isInterrupted {
            recoverPlayback()
            return
        }
        while scheduledPCM.count < Self.maximumScheduledBuffers, let pcm = bufferedPCM.popFirst() {
            let current = generation
            let currentPlayback = playbackGeneration
            let id = UUID()
            scheduledPCM.append((id, pcm))
            let completion = { [weak self] in
                DispatchQueue.main.async {
                    guard let self, self.generation == current,
                          self.playbackGeneration == currentPlayback else { return }
                    // Stop/configuration changes may complete unplayed buffers.
                    guard self.playback?.isInterrupted != true else {
                        self.recoverPlayback()
                        return
                    }
                    guard let index = self.scheduledPCM.firstIndex(where: { $0.id == id }) else { return }
                    self.scheduledPCM.remove(at: index)
                    self.queuedSamples -= pcm.count
                    self.deliveredSamples += pcm.count
                    self.scheduleBufferedAudio()
                    self.completeDrainIfReady()
                }
            }
            let scheduled = playback.schedule(pcm, completion: completion)
            guard !scheduled else { continue }
            if playback.isInterrupted { recoverPlayback() }
            else { fail("无法写入遥控器音频") }
            return
        }
    }

    private func createPlayback() throws {
        playback = try makePlayback()
        observeInterruption()
        guard let playback else { return }
        preparing = true
        let preparationStartedAt = ProcessInfo.processInfo.systemUptime
        if accepting && !draining { state = .preparing }
        let current = playbackGeneration
        preparationTimeout = schedule(5) { [weak self] in
            guard let self, self.playbackGeneration == current, self.preparing else { return }
            self.fail("遥控器音频设备准备超时，请松开语音键后重试。")
        }
        let prepare = { [weak self] in
            guard let self, self.playbackGeneration == current else { return }
            self.playback?.prepare { [weak self] result in
                guard let self, self.playbackGeneration == current else { return }
                self.preparationTimeout?.cancel()
                self.preparationTimeout = nil
                self.preparing = false
                switch result {
                case .success:
                    guard self.playback?.isReady == true else {
                        self.fail("遥控器音频设备尚未就绪")
                        return
                    }
                    do { try self.playback?.flush() }
                    catch { self.fail(error.localizedDescription); return }
                    let elapsedMS = Int((ProcessInfo.processInfo.systemUptime - preparationStartedAt) * 1000)
                    AudioDiagnostics.log("[RcHarness] Xiaomi voice output ready generation=\(self.generation) prepare_ms=\(elapsedMS) pending=\(self.queuedSamples)")
                    if self.accepting { self.state = .streaming }
                    self.scheduleBufferedAudio()
                    self.completeDrainIfReady()
                case .failure(let error):
                    self.fail(error.localizedDescription)
                }
            }
        }
        if playback.startupDelay == 0 {
            prepare()
            return
        }
        startupWork = schedule(playback.startupDelay) { [weak self] in
            guard let self, self.playbackGeneration == current else { return }
            self.startupWork = nil
            prepare()
        }
    }

    private func observeInterruption() {
        let current = generation
        let currentPlayback = playbackGeneration
        playback?.onInterruption = { [weak self] in
            guard let self, self.generation == current,
                  self.playbackGeneration == currentPlayback,
                  self.startupWork == nil, self.playback?.isInterrupted == true else { return }
            self.recoverPlayback()
        }
    }

    func audioDevicesChanged() {
        guard !preparing else { return }
        guard let playback else { return }
        guard accepting || draining else { stop(); return }
        let current = playbackGeneration
        playback.checkHealth { [weak self] healthy in
            guard let self, self.playbackGeneration == current, !healthy else { return }
            self.recoverPlayback()
        }
    }

    private func recoverPlayback() {
        guard accepting || draining, recoveryWork == nil else { return }
        guard recoveryAttempts < Self.maximumRecoveryAttempts else {
            fail("音频设备配置持续变化，无法恢复遥控器音频；请刷新音频设备后重试。")
            return
        }
        recoveryAttempts += 1
        // Never restart the old player: play() on an invalidated graph can
        // throw an Objective-C exception. Retire its callbacks
        // before stop() and replay only buffers not confirmed as played.
        discardPlayback()
        bufferedPCM.prepend(scheduledPCM.map(\.pcm))
        scheduledPCM.removeAll()
        drainCompletion?.cancel()
        drainCompletion = nil
        let current = generation
        recoveryWork = schedule(0.05) { [weak self] in
            guard let self, self.generation == current else { return }
            self.recoveryWork = nil
            do {
                try self.createPlayback()
                self.scheduleBufferedAudio()
                self.completeDrainIfReady()
            } catch {
                self.fail(error.localizedDescription)
            }
        }
        AudioDiagnostics.log("[RcHarness] Xiaomi voice output rebuilding after configuration change attempt=\(recoveryAttempts) pending=\(queuedSamples)")
    }

    private func discardPlayback() {
        playbackGeneration += 1
        startupWork?.cancel()
        startupWork = nil
        preparationTimeout?.cancel()
        preparationTimeout = nil
        playback?.onInterruption = nil
        playback?.stop()
        playback = nil
        preparing = false
    }

    private func fail(_ message: String) {
        AudioDiagnostics.log("[RcHarness] Xiaomi voice output failure=\(message) generation=\(generation) played=\(deliveredSamples) pending=\(queuedSamples) dropped=\(droppedSamples) recoveries=\(recoveryAttempts)")
        failure = message
        stop()
    }

    /// HID release and BLE AUDIO_STOP travel independently. Keep accepting the
    /// current stream until AUDIO_STOP, then release the key after playback.
    func releaseWhenFinished(completion: @escaping () -> Void) {
        let releasedGeneration = buttonGeneration
        let wasPressed = buttonPressed
        buttonPressed = false
        buttonGeneration = nil
        guard wasPressed else {
            completion()
            return
        }
        if failure != nil {
            completion()
            return
        }
        if releasedGeneration == generation, accepting || draining {
            drainCompletions.append(completion)
            scheduleReleaseTimeout()
            return
        }
        // HID release can arrive before the BLE AUDIO_START notification. Keep
        // the mapped Fn key held until that late stream either starts and ends,
        // or the timeout expires. Releasing immediately makes speech apps see a
        // tap with no audio and is the main source of intermittent wake failures.
        drainCompletions.append(completion)
        guard startReleaseTimeout == nil else { return }
        let current = generation
        startReleaseTimeout = schedule(streamEndTimeout) { [weak self] in
            guard let self, self.generation == current else { return }
            self.startReleaseTimeout = nil
            let completions = self.drainCompletions
            self.drainCompletions.removeAll()
            for completion in completions { completion() }
        }
    }

    private func scheduleReleaseTimeout() {
        guard accepting, releaseTimeout == nil else { return }
        let current = generation
        releaseTimeout = schedule(streamEndTimeout) { [weak self] in
            guard let self, self.generation == current else { return }
            self.end() // A missing BLE stop must not leave the mapped key held.
        }
    }

    func handle(_ event: RemoteVoiceStreamEvent) {
        switch event {
        case .started: begin()
        case .ended: end()
        case .cancelled:
            buttonPressed = false
            buttonGeneration = nil
            stop()
        }
    }

    func end() {
        guard accepting, !draining else { return }
        releaseTimeout?.cancel()
        releaseTimeout = nil
        draining = true
        accepting = false
        state = .draining
        let current = generation
        // Startup audio is played at its original rate. Give the retained
        // sentence time to drain instead of cutting it off after one second.
        let drainBudget = 1 + Double(queuedSamples) / 16_000 + (preparing ? 5 : 0)
        drainTimeout = schedule(drainBudget) { [weak self] in
            guard let self, self.generation == current else { return }
            self.failure = "遥控器音频输出超时"
            self.stop()
        }
        completeDrainIfReady()
    }

    private func completeDrainIfReady() {
        guard draining, !preparing, queuedSamples == 0, recoveryWork == nil, startupWork == nil,
              drainCompletion == nil else { return }
        let current = generation
        // Allow the virtual input to consume the final output buffers.
        drainCompletion = schedule(0.05) { [weak self] in
            guard let self, self.generation == current else { return }
            AudioDiagnostics.log("[RcHarness] Xiaomi voice output played_samples=\(self.deliveredSamples) dropped_samples=\(self.droppedSamples) pending=0")
            self.finishSession()
        }
    }

    func prepareForPress() {
        if draining || !drainCompletions.isEmpty { stop() }
        buttonPressed = true
        buttonGeneration = accepting || draining ? generation : nil
    }

    func stop() {
        generation += 1
        buttonGeneration = nil
        startReleaseTimeout?.cancel()
        startReleaseTimeout = nil
        // Invalidate callbacks before stop() can complete discarded buffers.
        playbackGeneration += 1
        recoveryWork?.cancel()
        recoveryWork = nil
        startupWork?.cancel()
        startupWork = nil
        preparationTimeout?.cancel()
        preparationTimeout = nil
        playback?.onInterruption = nil
        playback?.stop()
        do { try playback?.flush() }
        catch { failure = error.localizedDescription }
        playback = nil
        preparing = false
        finishSession()
    }

    private func finishSession() {
        accepting = false
        releaseTimeout?.cancel()
        releaseTimeout = nil
        drainTimeout?.cancel()
        drainTimeout = nil
        drainCompletion?.cancel()
        drainCompletion = nil
        bufferedPCM.removeAll()
        scheduledPCM.removeAll()
        queuedSamples = 0
        draining = false
        state = failure.map(RemoteAudioOutputState.failed) ?? .idle
        let completions = drainCompletions
        drainCompletions.removeAll()
        for completion in completions { completion() }
    }

    nonisolated static func outputError(_ message: String) -> NSError {
        NSError(domain: "RemoteMicrophoneOutput", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
