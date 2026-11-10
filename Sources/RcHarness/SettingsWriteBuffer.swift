import Foundation

/// Main-queue write combining for editable collections. Deferred producers read
/// the current model only at commit time, so typing neither encodes nor retains
/// a copy of each intermediate collection. Runtime state stays synchronous.
@MainActor
final class SettingsWriteBuffer {
    private let defaults: UserDefaults
    private let schedule: RemoteVoiceSessionController.Scheduler
    private var pending: [String: () throws -> Data] = [:]
    private var scheduledWrite: DispatchWorkItem?
    private var generation = 0
    private var batchDepth = 0

    init(defaults: UserDefaults, schedule: @escaping RemoteVoiceSessionController.Scheduler) {
        self.defaults = defaults
        self.schedule = schedule
    }

    func save<T: Encodable>(_ value: T, _ key: String) {
        let encode = { try JSONEncoder().encode(value) }
        if batchDepth > 0 {
            pending[key] = encode
        } else {
            commit([key: encode])
        }
    }

    func debounce<T: Encodable>(_ key: String, value: @escaping () -> T) {
        pending[key] = { try JSONEncoder().encode(value()) }
        cancelTimer()
        guard batchDepth == 0 else { return }
        let token = generation
        scheduledWrite = schedule(0.4) { [weak self] in
            guard let self, self.generation == token else { return }
            self.flush()
        }
    }

    func batch(_ operation: () -> Void) {
        batchDepth += 1
        defer {
            batchDepth -= 1
            if batchDepth == 0 { flush() }
        }
        operation()
    }

    func flush() {
        guard batchDepth == 0 else { return }
        cancelTimer()
        guard !pending.isEmpty else { return }
        let values = pending
        pending.removeAll()
        commit(values)
    }

    /// A successful import/deletion has already committed a complete snapshot.
    /// Drop producers from the superseded state before notifying runtime clients.
    func discard() {
        cancelTimer()
        pending.removeAll()
    }

    private func cancelTimer() {
        generation += 1
        scheduledWrite?.cancel()
        scheduledWrite = nil
    }

    private func commit(_ values: [String: () throws -> Data]) {
        do { try SettingsStorage.saveValues(values, defaults: defaults) }
        catch { Log.settings.error("Settings could not be encoded; previous values retained") }
    }
}
