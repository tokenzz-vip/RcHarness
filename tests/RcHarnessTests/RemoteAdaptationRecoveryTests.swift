import CoreBluetooth
import XCTest
@testable import RcHarness

@MainActor
final class RemoteAdaptationRecoveryTests: XCTestCase {
    private final class Guard: RemoteVolumeGuarding {
        var onFailure: ((String) -> Void)?
        func update(mapping: Bool) {}
        func stop() {}
    }

    func testHIDManagerScopesNativeKeyProtectionBeforeModelConfirmation() {
        for profile in [RemoteProfiles.xiaomiRC003, RemoteProfiles.googleG9N9N] {
            var protectedProfiles: [RemoteProfile] = []
            let manager = XiaomiRemoteHIDManager(profiles: [profile], makeVolumeGuard: {
                protectedProfiles = $0
                return Guard()
            })
            XCTAssertEqual(protectedProfiles.map(\.id), [profile.id], "An unselected remote must retain its native keys")
            XCTAssertFalse(manager.isConnected, "Protection must not wait for BLE model confirmation")
        }
    }

    func testCommandFailureRevokesIdentityAndReconnectsAfterSuccessfulHandshake() {
        for profile in [RemoteProfiles.xiaomiRC003, RemoteProfiles.googleG9N9N] {
            withConnection(profile: profile) { voice, connection, clock, id, connections, disconnections in
                var cancellations = 0
                voice.onStreamEvent = { if case .cancelled = $0 { cancellations += 1 } }
                voice.receiveCommandFailure(NSError(domain: "writeFailed", code: 1), peripheralID: id)
                XCTAssertEqual(connection.phase, "等待重连")
                XCTAssertNil(connection.remoteID)
                XCTAssertNil(voice.detectedModelNumber)
                XCTAssertFalse(voice.isReady)
                XCTAssertEqual(disconnections(), [id])
                XCTAssertEqual(cancellations, 1, "Reset must release the active target without another CLOSE write")
                clock.advance(1)
                XCTAssertEqual(connections(), [id, id])
                XCTAssertEqual(connection.remoteID, id)
            }
        }
    }

    func testOptionalBatteryDiscoveryFailureKeepsIdentityAndConnection() {
        for profile in [RemoteProfiles.xiaomiRC003, RemoteProfiles.googleG9N9N] {
            withConnection(profile: profile) { voice, connection, clock, id, connections, disconnections in
                voice.receiveCharacteristicDiscoveryFailure(NSError(domain: "batteryUnavailable", code: 1),
                    service: CBUUID(string: "180F"), peripheralID: id)
                XCTAssertEqual(connection.phase, "已连接")
                XCTAssertEqual(connection.remoteID, id)
                XCTAssertEqual(voice.detectedModelNumber, profile.model)
                XCTAssertNil(voice.batteryLevel)
                XCTAssertTrue(disconnections().isEmpty)
                clock.advance(30)
                XCTAssertEqual(connections(), [id])
            }
        }
    }

    func testLateWriteFailureFromAnotherPeripheralCannotResetCurrentConnection() {
        withConnection { voice, connection, clock, id, connections, disconnections in
            voice.receiveCommandFailure(NSError(domain: "staleWrite", code: 1), peripheralID: UUID())
            XCTAssertEqual(connection.remoteID, id)
            XCTAssertEqual(voice.detectedModelNumber, RemoteProfiles.xiaomiRC003.model)
            XCTAssertTrue(disconnections().isEmpty)
            clock.advance(30)
            XCTAssertEqual(connections(), [id])
        }
    }

    func testRequiredServiceDiscoveryFailureStillReconnects() {
        withConnection { voice, connection, clock, id, connections, _ in
            voice.receiveCharacteristicDiscoveryFailure(NSError(domain: "identityUnavailable", code: 1),
                service: CBUUID(string: "180A"), peripheralID: id)
            XCTAssertNil(voice.detectedModelNumber)
            XCTAssertNil(connection.remoteID)
            clock.advance(1)
            XCTAssertEqual(connections(), [id, id])
        }
    }

    private func withConnection(profile: RemoteProfile = RemoteProfiles.xiaomiRC003,
        _ body: (XiaomiRemoteVoice, RemoteVoiceConnectionController, TestClock, UUID,
                 () -> [UUID], () -> [UUID]) -> Void) {
        let clock = TestClock(), id = UUID()
        let suite = "RcHarness.AdaptationRecovery." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var connections: [UUID] = [], disconnections: [UUID] = []
        let connection = RemoteVoiceConnectionController(profile: profile, defaults: defaults,
            transport: .init(retrieve: { $0 == id }, connected: { [.init(id: id, name: nil)] },
                             scan: {}, stopScan: {}, connect: { connections.append($0) },
                             disconnect: { disconnections.append($0) }),
            schedule: clock.schedule, now: { clock.time })
        let voice = XiaomiRemoteVoice(profile: profile, defaults: defaults,
            schedule: clock.schedule, now: { clock.time }, connection: connection)
        voice.receiveModelNumber(profile.model)
        connection.start()
        connection.setPoweredOn(true)
        connection.handshakeSucceeded(id)
        body(voice, connection, clock, id, { connections }, { disconnections })
        connection.stop()
    }
}
