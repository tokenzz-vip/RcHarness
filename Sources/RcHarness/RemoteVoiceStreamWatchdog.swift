import Foundation

/// Bounds streams whose physical release is carried only by BLE AUDIO_STOP.
/// Audio notifications refresh the idle deadline; they never extend the total
/// session deadline. Stopped or replaced streams cannot expire a later one.
@MainActor
final class RemoteVoiceStreamWatchdog {
    enum Expiry { case idle, duration }
    static let idleTimeout: TimeInterval = 2
    static let maximumDuration: TimeInterval = 120

    private let schedule: RemoteVoiceSessionController.Scheduler
    private let onExpiry: (Expiry) -> Void
    private var idleWork: DispatchWorkItem?
    private var durationWork: DispatchWorkItem?
    private var revision = 0
    private var activityRevision = 0
    private var active = false

    init(schedule: @escaping RemoteVoiceSessionController.Scheduler = RemoteVoiceSessionController.mainQueue,
         onExpiry: @escaping (Expiry) -> Void) {
        self.schedule = schedule
        self.onExpiry = onExpiry
    }

    func start() {
        stop()
        active = true
        let current = revision
        durationWork = schedule(Self.maximumDuration) { [weak self] in
            guard let self, self.active, self.revision == current else { return }
            self.expire(.duration)
        }
        receivedAudio()
    }

    func receivedAudio() {
        guard active else { return }
        idleWork?.cancel()
        activityRevision += 1
        let current = revision, activity = activityRevision
        idleWork = schedule(Self.idleTimeout) { [weak self] in
            guard let self, self.active, self.revision == current,
                  self.activityRevision == activity else { return }
            self.expire(.idle)
        }
    }

    func stop() {
        active = false
        revision += 1
        idleWork?.cancel()
        durationWork?.cancel()
        idleWork = nil
        durationWork = nil
    }

    private func expire(_ reason: Expiry) {
        stop()
        onExpiry(reason)
    }
}
