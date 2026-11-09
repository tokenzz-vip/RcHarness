import XCTest
@testable import RcHarness

@MainActor
final class RemoteVoiceConnectionTests: XCTestCase {
    private final class Radio {
        var candidates: [RemoteVoiceConnectionController.Candidate] = []
        var remembered: Set<UUID> = []
        var connections: [UUID] = []
        var disconnections: [UUID] = []
        var scans = 0
        var transport: RemoteVoiceConnectionController.Transport {
            .init(retrieve: { self.remembered.contains($0) }, connected: { self.candidates },
                  scan: { self.scans += 1 }, stopScan: {},
                  connect: { self.connections.append($0) }, disconnect: { self.disconnections.append($0) })
        }
    }

    func testConnectedGoogleRemoteBypassesStaleScopedAndLegacyCache() {
        for key in [SettingsKeys.voicePeripheralUUID(profileID: RemoteProfiles.googleG9N9N.id),
                    SettingsKeys.voicePeripheralUUID] {
            let clock = TestClock(), radio = Radio()
            let suite = "RcHarness.VoiceConnection." + UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let stale = UUID(), current = UUID()
            defaults.set(stale.uuidString, forKey: key)
            radio.remembered = [stale]
            radio.candidates = [.init(id: current, name: "Chromecast Remote")]
            let connection = RemoteVoiceConnectionController(profile: RemoteProfiles.googleG9N9N, defaults: defaults,
                                                            transport: radio.transport, schedule: clock.schedule, now: { clock.time })
            connection.start()
            connection.setPoweredOn(true)
            XCTAssertEqual(radio.connections, [current], "The connected remote must be tried without waiting for cache timeouts")
            connection.handshakeSucceeded(current)
            clock.advance(60)
            XCTAssertEqual(radio.connections, [current])
            XCTAssertEqual(defaults.string(forKey: SettingsKeys.voicePeripheralUUID(profileID: RemoteProfiles.googleG9N9N.id)),
                           current.uuidString)
            XCTAssertNil(defaults.string(forKey: SettingsKeys.voicePeripheralUUID))
            connection.stop()
        }
    }

    func testConnectedGoogleRemoteAppearingAfterTimeoutBypassesSecondCacheAttempt() {
        let clock = TestClock(), radio = Radio()
        let suite = "RcHarness.VoiceConnection." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let stale = UUID(), current = UUID()
        defaults.set(stale.uuidString, forKey: SettingsKeys.voicePeripheralUUID(profileID: RemoteProfiles.googleG9N9N.id))
        radio.remembered = [stale]
        let connection = RemoteVoiceConnectionController(profile: RemoteProfiles.googleG9N9N, defaults: defaults,
                                                        transport: radio.transport, schedule: clock.schedule, now: { clock.time })
        connection.start()
        connection.setPoweredOn(true)
        XCTAssertEqual(radio.connections, [stale], "The cache still works when no connected candidate exists")
        radio.candidates = [.init(id: current, name: "Chromecast Remote")]
        clock.advance(21)
        XCTAssertEqual(radio.connections, [stale, current])
        connection.stop()
    }

    func testMultipleGoogleCandidatesOnlyUseCacheWhenItIsAmongConnectedCandidates() {
        let clock = TestClock(), radio = Radio()
        let suite = "RcHarness.VoiceConnection." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let stale = UUID(), first = UUID(), second = UUID()
        let key = SettingsKeys.voicePeripheralUUID(profileID: RemoteProfiles.googleG9N9N.id)
        defaults.set(stale.uuidString, forKey: key)
        radio.remembered = [stale, second]
        radio.candidates = [.init(id: first, name: "Chromecast Remote"), .init(id: second, name: "Chromecast Remote")]
        let connection = RemoteVoiceConnectionController(profile: RemoteProfiles.googleG9N9N, defaults: defaults,
                                                        transport: radio.transport, schedule: clock.schedule, now: { clock.time })
        connection.start()
        connection.setPoweredOn(true)
        XCTAssertTrue(radio.connections.isEmpty, "A stale cache must not bypass ambiguity between connected remotes")
        defaults.set(second.uuidString, forKey: key)
        clock.advance(10)
        XCTAssertEqual(radio.connections, [second], "A connected remembered remote can resolve multiple candidates")
        connection.stop()
    }

    func testUnresponsiveRememberedXiaomiRotatesToOtherConnectedCandidates() {
        let clock = TestClock(), radio = Radio()
        let suite = "RcHarness.VoiceConnection." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let remembered = UUID(), other = UUID()
        defaults.set(remembered.uuidString, forKey: SettingsKeys.voicePeripheralUUID(profileID: RemoteProfiles.xiaomiRC001.id))
        radio.remembered = [remembered]
        radio.candidates = [.init(id: other, name: "MI RC"), .init(id: remembered, name: "MI RC")]
        let connection = RemoteVoiceConnectionController(profile: RemoteProfiles.xiaomiRC001, defaults: defaults,
                                                        transport: radio.transport, schedule: clock.schedule, now: { clock.time })
        connection.start()
        connection.setPoweredOn(true)
        XCTAssertEqual(radio.connections, [remembered])
        clock.advance(21)
        XCTAssertEqual(radio.connections, [remembered, other], "A remembered candidate must not delay probing the remaining model")
        connection.stop()
    }

    func testWrongRememberedModelIsReleasedAndCorrectCandidateConnects() {
        let clock = TestClock()
        let radio = Radio()
        let suite = "RcHarness.VoiceConnection." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let wrong = UUID(), correct = UUID()
        let profile = RemoteProfiles.xiaomiRC003
        defaults.set(wrong.uuidString, forKey: SettingsKeys.voicePeripheralUUID(profileID: profile.id))
        radio.remembered = [wrong]
        radio.candidates = [.init(id: wrong, name: "MI RC"), .init(id: correct, name: "MI RC")]
        let connection = RemoteVoiceConnectionController(profile: profile, defaults: defaults, transport: radio.transport,
                                                        schedule: clock.schedule, now: { clock.time })
        connection.start()
        connection.setPoweredOn(true)
        XCTAssertEqual(radio.connections, [wrong])
        var resets = 0
        connection.onReset = { resets += 1 }
        connection.rejected(wrong, message: "型号不符")
        XCTAssertNil(connection.remoteID)
        XCTAssertEqual(radio.disconnections, [wrong])
        XCTAssertEqual(resets, 1)
        clock.advance(1)
        XCTAssertEqual(radio.connections, [wrong, correct])
        // A late disconnect from the rejected peripheral cannot reset the new one.
        connection.failed(wrong)
        XCTAssertEqual(connection.remoteID, correct)
        connection.handshakeSucceeded(correct)
        clock.advance(60)
        XCTAssertEqual(connection.remoteID, correct, "The stale deadline must be cancelled")
        XCTAssertEqual(defaults.string(forKey: SettingsKeys.voicePeripheralUUID(profileID: profile.id)), correct.uuidString)
        connection.stop()
    }

    func testMultipleCandidatesAutomaticallyRecoverWhenOnlyOneRemains() {
        let clock = TestClock(), radio = Radio()
        let suite = "RcHarness.VoiceConnection." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = UUID(), second = UUID()
        radio.candidates = [.init(id: first, name: "Chromecast Remote"), .init(id: second, name: "Chromecast Remote")]
        let connection = RemoteVoiceConnectionController(profile: RemoteProfiles.googleG9N9N, defaults: defaults,
                                                        transport: radio.transport, schedule: clock.schedule, now: { clock.time })
        connection.start()
        connection.setPoweredOn(true)
        XCTAssertTrue(radio.connections.isEmpty)
        radio.candidates.removeLast()
        clock.advance(10)
        XCTAssertEqual(radio.connections, [first])
        connection.stop()
        clock.advance(100)
        XCTAssertEqual(radio.connections, [first], "Stopping cancels both fallback and connection deadlines")
    }

    func testTwoConnectedXiaomiModelsAreProbedUntilSelectedModelIsFound() {
        let clock = TestClock(), radio = Radio()
        let suite = "RcHarness.VoiceConnection." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let pro = UUID(), standard = UUID()
        radio.candidates = [.init(id: pro, name: "小米蓝牙语音遥控器"),
                            .init(id: standard, name: "小米蓝牙语音遥控器")]
        let connection = RemoteVoiceConnectionController(profile: RemoteProfiles.xiaomiRC001, defaults: defaults,
                                                        transport: radio.transport, schedule: clock.schedule, now: { clock.time })
        connection.start()
        connection.setPoweredOn(true)
        XCTAssertEqual(radio.connections, [pro], "Read the candidate's model instead of waiting for one remote to disconnect")
        connection.rejected(pro, message: "检测到 RC003，与 RC001 不符")
        clock.advance(1)
        XCTAssertEqual(radio.connections, [pro, standard])
        connection.handshakeSucceeded(standard)
        clock.advance(60)
        XCTAssertEqual(connection.remoteID, standard)
        XCTAssertEqual(defaults.string(forKey: SettingsKeys.voicePeripheralUUID(profileID: RemoteProfiles.xiaomiRC001.id)), standard.uuidString)
        connection.stop()
    }

    func testUnresponsiveXiaomiCandidatesDoNotStarveTheRemainingRemote() {
        let clock = TestClock(), radio = Radio()
        let suite = "RcHarness.VoiceConnection." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let ids = [UUID(), UUID(), UUID()]
        radio.candidates = ids.map { .init(id: $0, name: "MI RC") }
        let connection = RemoteVoiceConnectionController(profile: RemoteProfiles.xiaomiRC001, defaults: defaults,
                                                        transport: radio.transport, schedule: clock.schedule, now: { clock.time })
        connection.start()
        connection.setPoweredOn(true)
        clock.advance(21)
        XCTAssertEqual(radio.connections, Array(ids.prefix(2)))
        clock.advance(22)
        XCTAssertEqual(radio.connections, ids)
        connection.handshakeSucceeded(ids[2])
        clock.advance(60)
        XCTAssertEqual(connection.remoteID, ids[2])
        connection.stop()
    }

    func testConnectionTimeoutRetriesAndRejectedIdentityExpires() {
        let clock = TestClock(), radio = Radio()
        let suite = "RcHarness.VoiceConnection." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = UUID()
        radio.candidates = [.init(id: id, name: "MI RC")]
        let connection = RemoteVoiceConnectionController(profile: RemoteProfiles.xiaomiRC001, defaults: defaults,
                                                        transport: radio.transport, schedule: clock.schedule, now: { clock.time })
        connection.start()
        connection.setPoweredOn(true)
        clock.advance(20)
        XCTAssertNil(connection.remoteID)
        clock.advance(1)
        XCTAssertEqual(radio.connections, [id, id])
        connection.rejected(id, message: "型号不符")
        clock.advance(2)
        XCTAssertNil(connection.remoteID)
        XCTAssertGreaterThan(radio.scans, 0)
        connection.discovered(.init(id: id, name: "MI RC"), hasVoiceService: true)
        XCTAssertNil(connection.remoteID, "Rejected advertisements must respect the cooldown")
        clock.advance(30)
        XCTAssertEqual(connection.remoteID, id, "A cooldown must not blacklist a device forever")
        connection.stop()
    }

    func testRememberedDevicesAreScopedAndPowerOffCancelsWork() {
        let clock = TestClock(), radio = Radio()
        let suite = "RcHarness.VoiceConnection." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let firstID = UUID(), secondID = UUID()
        let first = RemoteProfiles.xiaomiRC001, second = RemoteProfiles.googleG9N9N
        defaults.set(firstID.uuidString, forKey: SettingsKeys.voicePeripheralUUID(profileID: first.id))
        defaults.set(secondID.uuidString, forKey: SettingsKeys.voicePeripheralUUID(profileID: second.id))
        radio.remembered = [firstID, secondID]
        let connection = RemoteVoiceConnectionController(profile: second, defaults: defaults, transport: radio.transport,
                                                        schedule: clock.schedule, now: { clock.time })
        connection.start()
        connection.setPoweredOn(true)
        XCTAssertEqual(radio.connections, [secondID])
        connection.setPoweredOn(false)
        clock.advance(100)
        XCTAssertEqual(radio.connections, [secondID])
        connection.setPoweredOn(true)
        XCTAssertEqual(radio.connections, [secondID, secondID])
        XCTAssertEqual(defaults.string(forKey: SettingsKeys.voicePeripheralUUID(profileID: first.id)), firstID.uuidString)
        connection.stop()
    }
}

final class RemoteVoiceIdentityTests: XCTestCase {
    func testChromecastPnPAndModelRepliesMayCompleteInEitherOrder() {
        let pnp = Data([2, 0xD1, 0x18, 0x50, 0x94, 0, 1])
        for pnpFirst in [false, true] {
            var identity = RemoteVoiceIdentity(profile: RemoteProfiles.googleG9N9N)
            if pnpFirst { identity.receivePnP(pnp) }
            identity.receiveModel("firmware-specific model")
            XCTAssertFalse(identity.rejected)
            if !pnpFirst { identity.receivePnP(pnp) }
            XCTAssertTrue(identity.confirmed)
            XCTAssertFalse(identity.rejected)
        }
        var unknown = RemoteVoiceIdentity(profile: RemoteProfiles.googleG9N9N)
        unknown.receiveModel("unknown")
        XCTAssertFalse(unknown.rejected)
        unknown.receivePnP(Data())
        XCTAssertTrue(unknown.rejected)
    }

    func testPnPCannotBypassStrictXiaomiModelValidation() {
        for profile in [RemoteProfiles.xiaomiRC001, RemoteProfiles.xiaomiRC003] {
            var identity = RemoteVoiceIdentity(profile: profile)
            identity.receivePnP(Data([2, 0xD1, 0x18, 0x50, 0x94, 0, 1]))
            XCTAssertFalse(identity.confirmed)
            identity.receiveModel("incorrect")
            XCTAssertTrue(identity.rejected)
            identity.receiveModel(" \(profile.model)\u{0}\n")
            XCTAssertTrue(identity.confirmed)
        }
    }

    func testCapturedChromecastA0IdentityAcceptsPnPInEitherReplyOrder() {
        let pnp = Data([1, 0xD1, 0x18, 0x50, 0x94, 0x10, 1])
        for pnpFirst in [false, true] {
            var identity = RemoteVoiceIdentity(profile: RemoteProfiles.googleG9N9N)
            if pnpFirst { identity.receivePnP(pnp) }
            identity.receiveModel("A0")
            XCTAssertFalse(identity.rejected)
            if !pnpFirst { identity.receivePnP(pnp) }
            XCTAssertTrue(identity.confirmed)
            XCTAssertEqual(identity.model, "A0")
        }
        // A0 alone is not a model identity: still require the exact PnP match.
        var unknown = RemoteVoiceIdentity(profile: RemoteProfiles.googleG9N9N)
        unknown.receiveModel("A0")
        unknown.receivePnP(Data([1, 0xD1, 0x18, 0x51, 0x94, 0x10, 1]))
        XCTAssertFalse(unknown.confirmed)
        XCTAssertTrue(unknown.rejected)
    }
}
