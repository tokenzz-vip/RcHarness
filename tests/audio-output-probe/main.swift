import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

enum RemoteVoiceStreamEvent { case started, ended, cancelled }

// Start the probe normally, then attach Instruments during this lead-in.
// Launching it from Instruments can have a different recording authorization.
if CommandLine.arguments.contains("--wait-for-profiler") { pump(10) }

guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
      RemoteMicrophoneOutput.installed else {
    print("SKIP: authorized microphone and installed loopback required")
    exit(2)
}

func pump(_ seconds: TimeInterval) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
}

if CommandLine.arguments.contains("--latency") {
    exit(MainActor.assumeIsolated { runAudioLatencyProbe() })
}

final class OriginalPlayback {
    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
    init() throws {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var bytes: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        AudioObjectGetPropertyDataSize(system, &address, 0, nil, &bytes)
        var devices = [AudioDeviceID](repeating: 0, count: Int(bytes) / 4)
        AudioObjectGetPropertyData(system, &address, 0, nil, &bytes, &devices)
        var target: AudioDeviceID = 0
        for device in devices {
            var uid: Unmanaged<CFString>?
            var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            address.mSelector = kAudioDevicePropertyDeviceUID
            if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid) == noErr,
               uid?.takeRetainedValue() as String? == RemoteMicrophoneOutput.deviceUID { target = device }
        }
        guard target != 0, let unit = engine.outputNode.audioUnit else { throw NSError(domain: "probe", code: 1) }
        let result = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0, &target, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard result == noErr else { throw NSError(domain: "probe", code: Int(result)) }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.prepare()
        try engine.start()
        player.play()
    }
    func stop() { player.stop(); engine.stop() }
}

nonisolated(unsafe) var failures = 0
let attempts = 12
// RemoteMicrophoneOutput is main-actor isolated; top-level code runs on the main thread.
try MainActor.assumeIsolated {
for attempt in 1...attempts {
    if CommandLine.arguments.contains("--original") {
        let playback = try OriginalPlayback()
        pump(0.12)
        if !playback.engine.isRunning {
            failures += 1
            print("FAIL original session=\(attempt): 无法写入遥控器音频 (engine stopped)")
        }
        playback.stop()
    } else {
        let output = RemoteMicrophoneOutput()
        let beganAt = ProcessInfo.processInfo.systemUptime
        output.begin()
        let beginMS = Int((ProcessInfo.processInfo.systemUptime - beganAt) * 1000)
        if CommandLine.arguments.contains("--startup-timing") {
            print("Startup session=\(attempt) main_queue_ms=\(beginMS)")
            if beginMS > 150 {
                failures += 1
                print("FAIL startup session=\(attempt): audio setup blocked the voice trigger")
            }
        }
        // Only synthetic silence, confined to the selected loopback.
        output.append(Array(repeating: 0, count: 1600))
        pump(0.12)
        output.end()
        pump(0.6)
        if output.failure != nil || output.deliveredSamples != 1600 || output.state != .idle {
            failures += 1
            print("FAIL fixed session=\(attempt) delivered=\(output.deliveredSamples) state=\(output.state)")
        }
        output.stop()
    }
    pump(0.05)
}
}
print("\(failures == 0 ? "PASS" : "FAIL"): \(failures)/\(attempts) sessions failed")
exit(failures == 0 ? 0 : 1)
