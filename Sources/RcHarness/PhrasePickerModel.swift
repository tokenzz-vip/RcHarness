import Combine
import Foundation

/// Owns remote input only while the phrase panel is visible, plus outstanding releases.
@MainActor
final class PhrasePickerModel: ObservableObject {
    @Published private(set) var isPresented = false
    @Published private(set) var phrases: [ControllerInput: SavedPhrase] = [:]
    @Published private(set) var message = "单击输入内容1 · 双击输入内容2"
    var onOutput: ((String) -> Void)?
    var onDismiss: (() -> Void)?

    private final class Session {
        let phrase: SavedPhrase
        var second = false
        var work: DispatchWorkItem?
        init(_ phrase: SavedPhrase) { self.phrase = phrase }
    }
    private let schedule: RemoteVoiceSessionController.Scheduler
    private var heldInputs: Set<ControllerInput> = []
    private var consumedInputs: Set<ControllerInput> = []
    private var sessions: [ControllerInput: Session] = [:]

    init(schedule: @escaping RemoteVoiceSessionController.Scheduler = RemoteVoiceSessionController.mainQueue) {
        self.schedule = schedule
    }

    func present(phrases: [SavedPhrase], assignments: PhraseAssignments) {
        dismiss()
        let byID = Dictionary(phrases.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.phrases = Dictionary(uniqueKeysWithValues: PhraseAssignments.inputs.compactMap { input in
            assignments[input].flatMap { byID[$0] }.map { (input, $0) }
        })
        consumedInputs.formUnion(heldInputs)
        message = self.phrases.isEmpty ? "尚未分配常用语，请先在设置中添加并分配。" : "单击输入内容1 · 双击输入内容2"
        isPresented = true
    }

    func dismiss() {
        guard isPresented else { return }
        for session in sessions.values { session.work?.cancel() }
        sessions.removeAll()
        consumedInputs.formUnion(heldInputs)
        isPresented = false
        onDismiss?()
    }

    func reset() {
        dismiss()
        heldInputs.removeAll()
        consumedInputs.removeAll()
    }

    func cancel(_ input: ControllerInput) {
        sessions.removeValue(forKey: input)?.work?.cancel()
        heldInputs.remove(input)
        consumedInputs.remove(input)
    }

    /// Observe every edge even when hidden, so the opening press cannot select a phrase.
    @discardableResult
    func handle(_ input: ControllerInput, pressed: Bool) -> Bool {
        let wasHeld = heldInputs.contains(input)
        if pressed { heldInputs.insert(input) } else { heldInputs.remove(input) }
        if consumedInputs.contains(input) {
            if !pressed { consumedInputs.remove(input) }
            return true
        }
        guard isPresented else { return false }
        guard PhraseAssignments.inputs.contains(input) else {
            if pressed {
                consumedInputs.insert(input)
                if [.buttonB, .home, .menu].contains(input) { dismiss() }
            }
            return true
        }
        if pressed {
            guard !wasHeld else { return true }
            if let session = sessions[input] {
                session.work?.cancel()
                session.second = true
            } else if let phrase = phrases[input] {
                sessions[input] = Session(phrase)
            }
        } else if wasHeld, let session = sessions[input] {
            if session.second {
                output(session.phrase, language: .english)
            } else {
                session.work = schedule(RemoteGestureController.doubleTapWindow) { [weak self, weak session] in
                    guard let self, let session, self.isPresented, self.sessions[input] === session else { return }
                    self.output(session.phrase, language: .chinese)
                }
            }
        }
        return true
    }

    /// Also supports mouse/keyboard selection in the panel without posting real events in tests.
    func output(_ phrase: SavedPhrase, language: PhraseLanguage) {
        guard isPresented else { return }
        let text = language == .english ? phrase.englishText : phrase.text
        guard !text.isEmpty else {
            for session in sessions.values { session.work?.cancel() }
            sessions.removeAll()
            message = language == .english ? "这条常用语的内容2为空。" : "这条常用语的内容1为空。"
            return
        }
        dismiss()
        onOutput?(text)
    }
}
