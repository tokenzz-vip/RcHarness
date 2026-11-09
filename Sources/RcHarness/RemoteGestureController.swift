import Foundation

/// Captures each gesture's mappings at the first press so an edit cannot leave a key held.
@MainActor
final class RemoteGestureController {
    private final class Session {
        let single: ButtonMapping
        let double: ButtonMapping
        let long: ButtonMapping
        let immediate: Bool
        var held = true
        var second = false
        var longFired = false
        var work: DispatchWorkItem?
        var opensSwitcher: Bool {
            [single, double, long].contains { $0.action == .openHarnessSwitcher }
        }
        init(_ input: ControllerInput, _ mapping: RemoteMapping) {
            single = mapping[input, .single]
            double = mapping[input, .double]
            long = mapping[input, .long]
            immediate = double.action == .disabled && long.action == .disabled
        }
    }
    static let doubleTapWindow: TimeInterval = 0.3
    static let longPressDelay: TimeInterval = 0.55
    private let schedule: RemoteVoiceSessionController.Scheduler
    private var sessions: [ControllerInput: Session] = [:]
    private var operationMode: ControllerOperationMode = .mapping
    var onOutput: ((ButtonMapping, Bool) -> Void)?

    init(schedule: @escaping RemoteVoiceSessionController.Scheduler = RemoteVoiceSessionController.mainQueue) {
        self.schedule = schedule
    }

    func setOperationMode(_ mode: ControllerOperationMode) {
        cancel()
        operationMode = mode
    }

    func handle(_ input: ControllerInput, pressed: Bool, mapping: RemoteMapping) {
        guard operationMode == .mapping else { return }
        if pressed {
            if let old = sessions[input] {
                guard !old.held else {
                    if old.opensSwitcher {
                        Log.switcher.notice("Gesture ignored repeated-down input=\(input.rawValue, privacy: .public)")
                    }
                    return
                }
                old.work?.cancel()
                old.held = true
                old.second = true
                scheduleLongPress(old, input: input)
                return
            }
            let session = Session(input, mapping)
            sessions[input] = session
            if session.immediate {
                logResolution(session.single, input: input, trigger: .single, session: session)
                onOutput?(session.single, true)
            } else { scheduleLongPress(session, input: input) }
        } else {
            guard let session = sessions[input], session.held else { return }
            session.held = false
            session.work?.cancel()
            if session.immediate { onOutput?(session.single, false); sessions[input] = nil }
            else if session.longFired { sessions[input] = nil }
            else if session.second { tap(session.double, input: input, trigger: .double, session: session); sessions[input] = nil }
            else if session.double.action != .disabled {
                session.work = schedule(Self.doubleTapWindow) { [weak self, weak session] in
                    guard let self, let session, self.sessions[input] === session, !session.held else { return }
                    self.sessions[input] = nil
                    self.tap(session.single, input: input, trigger: .single, session: session)
                }
            } else { tap(session.single, input: input, trigger: .single, session: session); sessions[input] = nil }
        }
    }
    private func scheduleLongPress(_ session: Session, input: ControllerInput) {
        guard session.long.action != .disabled else { return }
        session.work = schedule(Self.longPressDelay) { [weak self, weak session] in
            guard let self, let session, self.sessions[input] === session, session.held else { return }
            session.longFired = true
            self.tap(session.long, input: input, trigger: .long, session: session)
        }
    }
    func cancel() {
        let old = sessions
        sessions.removeAll()
        for (input, session) in old {
            if session.opensSwitcher {
                Log.switcher.notice("Gesture cancelled input=\(input.rawValue, privacy: .public) held=\(session.held) second=\(session.second) long_fired=\(session.longFired)")
            }
            session.work?.cancel()
            if session.immediate && session.held { onOutput?(session.single, false) }
        }
    }
    func cancel(_ input: ControllerInput) {
        guard let session = sessions.removeValue(forKey: input) else { return }
        session.work?.cancel()
        if session.immediate && session.held { onOutput?(session.single, false) }
    }
    private func tap(_ mapping: ButtonMapping, input: ControllerInput, trigger: ButtonTrigger, session: Session) {
        logResolution(mapping, input: input, trigger: trigger, session: session)
        onOutput?(mapping, true)
        onOutput?(mapping, false)
    }

    private func logResolution(_ mapping: ButtonMapping, input: ControllerInput, trigger: ButtonTrigger, session: Session) {
        guard session.opensSwitcher else { return }
        Log.switcher.notice("Gesture resolved input=\(input.rawValue, privacy: .public) trigger=\(trigger.rawValue, privacy: .public) action=\(mapping.action.rawValue, privacy: .public)")
    }
}
