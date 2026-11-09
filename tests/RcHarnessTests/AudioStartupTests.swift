import AVFoundation
import XCTest
@testable import RcHarness

@MainActor
final class AudioStartupTests: XCTestCase {
    func testPlaybackConstructionDefersEngineCreationOffTheVoiceTriggerQueue() async throws {
        let attempted = expectation(description: "Engine initialization runs off the main queue")
        let completed = expectation(description: "Preparation error returns to the main queue")
        // Throw before touching real audio, so this test needs no device or
        // recording permission and cannot send sound or synthesize key events.
        let playback = try CoreAudioRemoteMicrophonePlayback(outputUID: RemoteMicrophoneOutput.deviceUID) {
            XCTAssertFalse(Thread.isMainThread, "Cold AVAudioEngine initialization must not block Fn or incoming BLE audio")
            attempted.fulfill()
            throw RemoteMicrophoneOutput.outputError("injected startup failure")
        }
        playback.prepare { result in
            XCTAssertTrue(Thread.isMainThread)
            guard case .failure(let error) = result else { return XCTFail("Expected injected preparation failure") }
            XCTAssertEqual(error.localizedDescription, "injected startup failure")
            completed.fulfill()
        }
        await fulfillment(of: [attempted, completed], timeout: 1)
        playback.stop()
    }

    func testCancellationReturnsWhileEngineConstructionIsStillPending() async throws {
        let entered = expectation(description: "Cold constructor entered")
        let completed = expectation(description: "Cancelled preparation callback completed")
        let unblock = DispatchSemaphore(value: 0)
        let playback = try CoreAudioRemoteMicrophonePlayback(outputUID: RemoteMicrophoneOutput.deviceUID) {
            entered.fulfill()
            unblock.wait()
            throw RemoteMicrophoneOutput.outputError("cancelled cold constructor")
        }
        playback.prepare { _ in completed.fulfill() }
        await fulfillment(of: [entered], timeout: 1)
        // A queue.sync teardown deadlocks here; only release the constructor
        // after cancellation and health queries have returned to the caller.
        playback.stop()
        XCTAssertFalse(playback.isReady)
        XCTAssertFalse(playback.isInterrupted)
        try playback.flush()
        unblock.signal()
        await fulfillment(of: [completed], timeout: 1)
    }
}
