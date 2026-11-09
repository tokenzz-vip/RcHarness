/// FIFO of PCM packets bounded by sample count. When the limit is exceeded the
/// oldest audio is discarded first, so latency stays bounded and stale speech
/// never spills into a later recording. Shared by the voice session (while the
/// target app starts) and the microphone output (while the audio graph starts).
struct PCMBacklog {
    private(set) var packets: [[Int16]] = []
    private(set) var count = 0

    var isEmpty: Bool { packets.isEmpty }

    /// Appends `pcm`, then trims the oldest samples until at most `limit`
    /// remain. Returns the number of samples discarded.
    @discardableResult
    mutating func append(_ pcm: [Int16], limit: Int) -> Int {
        guard !pcm.isEmpty else { return 0 }
        packets.append(pcm)
        count += pcm.count
        let limit = max(0, limit)
        var dropped = 0
        while count > limit, !packets.isEmpty {
            let trimmed = min(count - limit, packets[0].count)
            packets[0].removeFirst(trimmed)
            if packets[0].isEmpty { packets.removeFirst() }
            count -= trimmed
            dropped += trimmed
        }
        return dropped
    }

    /// Restores packets ahead of the current backlog (used to replay audio
    /// that was scheduled on a playback graph which had to be rebuilt).
    mutating func prepend(_ replay: [[Int16]]) {
        packets = replay + packets
        count += replay.reduce(0) { $0 + $1.count }
    }

    mutating func popFirst() -> [Int16]? {
        guard !packets.isEmpty else { return nil }
        let first = packets.removeFirst()
        count -= first.count
        return first
    }

    /// Removes and returns every packet in order.
    mutating func drain() -> [[Int16]] {
        defer { removeAll() }
        return packets
    }

    mutating func removeAll() {
        packets.removeAll()
        count = 0
    }
}

extension PCMBacklog {
    /// Half a second of 16 kHz voice for the target-start gate and live playback.
    static let voiceLimit = 8_000
    /// A cold audio graph can take seconds to initialize. Retain the first
    /// sentence separately from the short live-playback latency budget.
    static let startupVoiceLimit = 80_000
}
