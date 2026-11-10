import Foundation
import XCTest
@testable import RcHarness

final class AudioBufferBoundaryTests: XCTestCase {
    func testRecoveryReplayPrecedesNewSpeechAndSharesTheSampleBudget() {
        var backlog = PCMBacklog()
        backlog.append([3, 4, 5], limit: 8)
        backlog.append([6, 7, 8], limit: 8)
        backlog.prepend([[1], [2]])
        XCTAssertEqual(backlog.count, 8)
        XCTAssertEqual(backlog.packets.flatMap { $0 }, Array(1...8).map(Int16.init))
        XCTAssertEqual(backlog.append([9, 10], limit: 5), 5)
        XCTAssertEqual(backlog.count, 5)
        XCTAssertEqual(backlog.drain().flatMap { $0 }, [6, 7, 8, 9, 10])
        XCTAssertTrue(backlog.isEmpty)
        XCTAssertEqual(backlog.count, 0)
        backlog.append([11, 12], limit: 5)
        XCTAssertEqual(backlog.popFirst(), [11, 12])
        XCTAssertNil(backlog.popFirst())
        XCTAssertEqual(backlog.count, 0)
    }

    func testOversizedPacketAndNonpositiveBudgetsNeverRetainOldAudio() {
        var backlog = PCMBacklog()
        XCTAssertEqual(backlog.append(Array(1...9).map(Int16.init), limit: 4), 5)
        XCTAssertEqual(backlog.packets, [[6, 7, 8, 9]])
        XCTAssertEqual(backlog.append([10], limit: 0), 5)
        XCTAssertTrue(backlog.isEmpty)
        XCTAssertEqual(backlog.count, 0)
        XCTAssertEqual(backlog.append([11, 12], limit: -1), 2)
        XCTAssertTrue(backlog.isEmpty)
        XCTAssertEqual(backlog.count, 0)
    }

    func testPacketBoundariesCannotChangeTheRetainedAudio() {
        let samples = (0..<10_000).map(Int16.init)
        let limit = PCMBacklog.voiceLimit
        for packetSize in [1, 7, 120, 160, 512, 10_000] {
            var backlog = PCMBacklog()
            var dropped = 0
            for start in stride(from: 0, to: samples.count, by: packetSize) {
                dropped += backlog.append(Array(samples[start..<min(samples.count, start + packetSize)]), limit: limit)
                XCTAssertLessThanOrEqual(backlog.count, limit)
            }
            XCTAssertEqual(backlog.drain().flatMap { $0 }, Array(samples.suffix(limit)), "packetSize=\(packetSize)")
            XCTAssertEqual(dropped, samples.count - limit)
            XCTAssertEqual(backlog.count, 0)
        }
    }

    func testADPCMSaturationAndInvalidStepIndicesStayWithinInt16() {
        var decoder = RemoteADPCMDecoder()
        decoder.reset(sample: .max, index: 1_000)
        XCTAssertEqual(decoder.decode(Data([0x77])), [.max, .max])
        decoder.reset(sample: .min, index: 1_000)
        XCTAssertEqual(decoder.decode(Data([0xFF])), [.min, .min])
        decoder.reset(index: -1)
        XCTAssertEqual(decoder.decode(Data([0x7F])), [11, -19])
    }

    func testEveryNotificationSplitPreservesFramesAndStreamAccounting() {
        let bytes = Data((0..<360).map { UInt8(truncatingIfNeeded: $0 * 17) })
        var decoder = RemoteADPCMDecoder()
        let expected = decoder.decode(bytes)
        for split in 1..<bytes.count {
            var stream = RemoteVoiceStream()
            stream.start(session: 1)
            let first = stream.append(Data(bytes.prefix(split)), frameBytes: 120)
            let second = stream.append(Data(bytes.dropFirst(split)), frameBytes: 120)
            XCTAssertEqual(first + second, expected, "split=\(split)")
            XCTAssertEqual(stream.pendingBytes, 0)
            XCTAssertEqual(stream.sampleCount, 720)
            XCTAssertEqual(stream.decodedFrames, 3)
            XCTAssertEqual(stream.receivedPackets, 2)
            XCTAssertEqual(stream.receivedBytes, 360)
            XCTAssertEqual(stream.peak, expected.map { abs(Int($0)) }.max())
        }
    }

    func testSynchronizationDropsPartialFrameAndUsesTheNewPredictor() {
        var stream = RemoteVoiceStream()
        stream.start(session: 1)
        XCTAssertTrue(stream.append(Data([0xFF]), frameBytes: 2).isEmpty)
        stream.synchronize(sample: 100, index: 0)
        XCTAssertEqual(stream.pendingBytes, 0)
        XCTAssertEqual(stream.synchronizationDiscardedBytes, 1)
        // At IMA step 7, nibble 7 adds 11; nibble F then subtracts 30.
        XCTAssertEqual(stream.append(Data([0x7F, 0x00]), frameBytes: 2), [111, 81, 85, 88])
        XCTAssertEqual(stream.sampleCount, 4)
        XCTAssertEqual(stream.decodedFrames, 1)
        XCTAssertEqual(stream.receivedBytes, 3)
    }

    func testRestartCannotCarryPartialFramesPredictorOrStatisticsIntoTheNextStream() {
        var stream = RemoteVoiceStream()
        stream.start(session: 1, implicit: true)
        _ = stream.append(Data([0xFF, 0xFF]), frameBytes: 2)
        _ = stream.append(Data([0xFF]), frameBytes: 2)
        stream.stop()
        XCTAssertTrue(stream.append(Data([0xFF]), frameBytes: 2).isEmpty)
        stream.start(session: 2)
        XCTAssertFalse(stream.isImplicit)
        XCTAssertEqual(stream.pendingBytes, 0)
        XCTAssertEqual(stream.sampleCount, 0)
        XCTAssertEqual(stream.peak, 0)
        XCTAssertEqual(stream.receivedBytes, 0)
        XCTAssertEqual(stream.receivedPackets, 0)
        XCTAssertEqual(stream.decodedFrames, 0)
        XCTAssertEqual(stream.synchronizationDiscardedBytes, 0)
        XCTAssertEqual(stream.append(Data([0x7F]), frameBytes: 1), [11, -19])
    }
}
