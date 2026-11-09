import Foundation

@MainActor
protocol RemoteVoiceAudioOutput: AnyObject {
    func prepareForPress()
    func begin()
    func append(_ pcm: [Int16])
    func end()
    func stop()
    func releaseWhenFinished(completion: @escaping () -> Void)
}

extension RemoteMicrophoneOutput: RemoteVoiceAudioOutput {}

/// All entry points and scheduled operations run on the main queue. A session
/// captures one mapping and owns its key edges, buffered audio and drain reply.
@MainActor
final class RemoteVoiceSessionController {
    typealias Scheduler = (TimeInterval, @escaping () -> Void) -> DispatchWorkItem
    nonisolated static func mainQueue(after delay: TimeInterval, operation: @escaping () -> Void) -> DispatchWorkItem {
        let work = DispatchWorkItem(block: operation)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        return work
    }

    private final class Session {
        let id: Int
        var mapping: ButtonMapping?
        var tap = false
        var toggle = false
        var physicalDown = false
        var released = false
        var streamStarted = false
        var streamEnded = false
        var outputActive = false
        var releaseRegistered = false
        var endSent = false
        var keyDown = false
        var startTapStarted = false
        var startTapFinished = false
        var stopTapStarted = false
        var gateOpen = false
        var finishRequested = false
        var cancelled = false
        var closed = false
        var pcm = PCMBacklog()
        var droppedSamples = 0
        var tasks: [DispatchWorkItem] = []
        init(id: Int) { self.id = id }
    }

    private let output: RemoteVoiceAudioOutput
    private let sendKey: (ButtonMapping, Bool) -> Void
    private let schedule: Scheduler
    private let logger: (String) -> Void
    private let tapDuration: TimeInterval = 0.12
    private let targetStartDelay: TimeInterval = 0.15
    private var nextID = 0
    // One active session and up to two waiting presses; rapid presses cannot
    // retain unlimited audio or overwrite a key which still needs releasing.
    private var sessions: [Session] = []
    private var idleCompletions: [() -> Void] = []
    private var physicalSession: Session?
    private var bluetoothSession: Session?
    private var current: Session? { sessions.first }

    init(output: RemoteVoiceAudioOutput, schedule: @escaping Scheduler = mainQueue,
         logger: @escaping (String) -> Void = AudioDiagnostics.log,
         sendKey: @escaping (ButtonMapping, Bool) -> Void) {
        self.output = output
        self.schedule = schedule
        self.logger = logger
        self.sendKey = sendKey
    }

    func press(mapping: ButtonMapping, fnTap: Bool, toggle: Bool = false) {
        if let physicalSession, physicalSession.physicalDown, !physicalSession.closed { return }
        guard let session = sessions.first(where: { $0.mapping == nil && !$0.closed }) ?? makeSession() else { return }
        session.mapping = mapping
        session.toggle = toggle
        session.tap = toggle || (fnTap && mapping.action == .fn)
        session.physicalDown = true
        physicalSession = session
        log(session, "press action=\(mapping.action.rawValue) tap=\(session.tap)")
        activateIfPossible()
    }

    func release() {
        guard let session = physicalSession, !session.released else { return }
        session.physicalDown = false
        physicalSession = nil
        if session.toggle { return }
        session.released = true
        log(session, "release")
        if current === session, session.outputActive { registerDrain(session) }
    }

    /// A stop press is consumed by the input router, including its release.
    /// BLE STOP and the original voice-key release never end latch-to-talk.
    @discardableResult
    func finishToggle() -> Bool {
        guard let session = current, session.toggle, !session.released, !session.closed,
              !session.cancelled else { return false }
        session.released = true
        session.finishRequested = true
        if session.outputActive {
            session.streamEnded = true
            pump(session)
        } else {
            closeTarget(session)
        }
        return true
    }

    func handle(_ event: RemoteVoiceStreamEvent) {
        switch event {
        case .started:
            if let bluetoothSession, !bluetoothSession.streamEnded, !bluetoothSession.closed { return }
            guard let session = sessions.first(where: { !$0.streamStarted && !$0.closed }) ?? makeSession() else { return }
            session.streamStarted = true
            bluetoothSession = session
            log(session, "ble_start")
            if session.mapping == nil {
                // BLE can beat HID, but BLE alone must never open the target or
                // leak audio if Input Monitoring is unavailable.
                session.tasks.append(schedule(1) { [weak self, weak session] in
                    guard let self, let session, session.mapping == nil, !session.closed else { return }
                    self.log(session, "unmatched_ble_start discarded")
                    self.complete(session)
                })
            }
            activateIfPossible()
        case .ended:
            guard let session = bluetoothSession else { return }
            bluetoothSession = nil
            session.streamEnded = true
            log(session, "ble_stop")
            pump(session)
        case .cancelled:
            cancel()
        }
    }

    func append(_ samples: [Int16]) {
        guard let session = bluetoothSession, !session.closed, !session.cancelled, !samples.isEmpty else { return }
        session.droppedSamples += session.pcm.append(samples, limit: PCMBacklog.voiceLimit)
        pump(session)
    }

    func cancel(completion: (() -> Void)? = nil) {
        if let completion { idleCompletions.append(completion) }
        physicalSession = nil
        bluetoothSession = nil
        guard let session = current else { output.stop(); notifyIdle(); return }
        for waiting in sessions.dropFirst() {
            waiting.closed = true
            waiting.tasks.forEach { $0.cancel() }
        }
        sessions = [session]
        session.cancelled = true
        session.finishRequested = true
        session.pcm.removeAll()
        // Invalidate the drain reply before stop can synchronously complete it.
        session.outputActive = false
        output.stop()
        log(session, "cancel")
        closeTarget(session)
    }

    private func makeSession() -> Session? {
        guard sessions.count < 3 else {
            logger("[RcHarness] voice trigger backlog full; press discarded")
            return nil
        }
        nextID += 1
        let session = Session(id: nextID)
        sessions.append(session)
        return session
    }

    private func activateIfPossible() {
        guard let session = current, let mapping = session.mapping,
              !session.outputActive, !session.finishRequested, !session.cancelled, !session.closed else { return }
        session.outputActive = true
        output.prepareForPress()
        output.begin()
        // A synchronous preparation failure may cancel this session.
        guard current === session, !session.closed, !session.cancelled else { return }
        if session.tap {
            session.startTapStarted = true
            emit(session, mapping: mapping, down: true, reason: "start_tap")
            session.tasks.append(schedule(tapDuration) { [weak self, weak session] in
                guard let self, let session, self.current === session, !session.closed else { return }
                self.emit(session, mapping: mapping, down: false, reason: "start_tap")
                session.startTapFinished = true
                // This is a startup grace period, not proof that the external
                // application accepted Fn or has begun recording.
                session.tasks.append(self.schedule(self.targetStartDelay) { [weak self, weak session] in
                    guard let self, let session, self.current === session, !session.closed else { return }
                    session.gateOpen = true
                    if session.toggle, session.finishRequested { self.pump(session) }
                    else if session.finishRequested { self.closeTarget(session) }
                    else { self.pump(session) }
                })
            })
        } else {
            session.gateOpen = true
            emit(session, mapping: mapping, down: true, reason: "hold")
            pump(session)
        }
        if session.released { registerDrain(session) }
    }

    private func pump(_ session: Session) {
        guard current === session, session.outputActive, session.gateOpen,
              !session.closed, !session.cancelled else { return }
        for packet in session.pcm.drain() {
            guard !session.cancelled, !session.closed else { return }
            output.append(packet)
        }
        if session.streamEnded, !session.endSent {
            session.endSent = true
            // Register before end: an empty stream may finish immediately.
            registerDrain(session)
            output.end()
        }
    }

    private func registerDrain(_ session: Session) {
        guard session.outputActive, !session.releaseRegistered, !session.closed else { return }
        session.releaseRegistered = true
        output.releaseWhenFinished { [weak self, weak session] in
            guard let self, let session, self.current === session,
                  session.outputActive, !session.closed else { return }
            session.outputActive = false
            if session.toggle, !session.released, !session.cancelled {
                self.log(session, "audio_drained waiting_for_remote_key")
                return
            }
            session.finishRequested = true
            self.log(session, "drain_finished remote_stop=\(session.streamEnded)")
            self.closeTarget(session)
        }
    }

    private func closeTarget(_ session: Session) {
        guard current === session, !session.closed else { return }
        guard let mapping = session.mapping else { complete(session); return }
        if session.tap, session.startTapStarted {
            guard session.startTapFinished, session.gateOpen, !session.stopTapStarted else { return }
            session.stopTapStarted = true
            emit(session, mapping: mapping, down: true, reason: "stop_tap")
            session.tasks.append(schedule(tapDuration) { [weak self, weak session] in
                guard let self, let session, self.current === session, !session.closed else { return }
                self.emit(session, mapping: mapping, down: false, reason: "stop_tap")
                self.complete(session)
            })
        } else {
            if session.keyDown { emit(session, mapping: mapping, down: false, reason: "release") }
            complete(session)
        }
    }

    private func complete(_ session: Session) {
        guard !session.closed else { return }
        session.closed = true
        session.tasks.forEach { $0.cancel() }
        session.tasks.removeAll()
        session.pcm.removeAll()
        log(session, "closed dropped_samples=\(session.droppedSamples)")
        sessions.removeAll { $0 === session }
        if physicalSession === session { physicalSession = nil }
        activateIfPossible()
        notifyIdle()
    }

    private func emit(_ session: Session, mapping: ButtonMapping, down: Bool, reason: String) {
        session.keyDown = down
        log(session, "key action=\(mapping.action.rawValue) down=\(down) reason=\(reason)")
        sendKey(mapping, down)
    }

    private func log(_ session: Session, _ message: String) {
        logger("[RcHarness] voice trigger session=\(session.id) \(message)")
    }

    private func notifyIdle() {
        guard sessions.isEmpty else { return }
        let completions = idleCompletions
        idleCompletions.removeAll()
        completions.forEach { $0() }
    }
}
