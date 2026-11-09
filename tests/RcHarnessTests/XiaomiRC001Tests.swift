import XCTest
@testable import RcHarness

@MainActor
private final class RecordingRemoteVolumeGuard: RemoteVolumeGuarding {
    var onFailure: ((String) -> Void)?
    var mappingUpdates: [Bool] = []
    var stopped = false

    func update(mapping: Bool) { mappingUpdates.append(mapping) }
    func stop() { stopped = true }
}

final class XiaomiRC001Tests: XCTestCase {
    func testTwoConnectedModelsUseTheirOwnHIDIdentity() {
        for profile in [RemoteProfiles.xiaomiRC001, RemoteProfiles.xiaomiRC003] {
            for deviceModel in ["RC001", "RC003", "unknown"] {
                XCTAssertEqual(profile.matchesHIDDevice(vendorID: profile.vendorID, productID: profile.productID,
                    name: "小米蓝牙语音遥控器", confirmedModelNumber: profile.model,
                    deviceModelNumber: " \(deviceModel)\u{0}\n", isOnlyCandidate: false),
                    profile.acceptsVoiceModel(deviceModel))
            }
            XCTAssertFalse(profile.matchesHIDDevice(vendorID: profile.vendorID, productID: profile.productID,
                name: nil, confirmedModelNumber: profile.model, deviceModelNumber: nil, isOnlyCandidate: false))
            XCTAssertTrue(profile.matchesHIDDevice(vendorID: profile.vendorID, productID: profile.productID,
                name: nil, confirmedModelNumber: profile.model, deviceModelNumber: nil, isOnlyCandidate: true))
            XCTAssertFalse(profile.matchesHIDDevice(vendorID: profile.vendorID, productID: profile.productID,
                name: nil, confirmedModelNumber: nil, deviceModelNumber: profile.model, isOnlyCandidate: true))
        }
    }

    func testSharedHIDIdentityDoesNotConnectEitherModelBeforeModelConfirmation() {
        let profiles = [RemoteProfiles.xiaomiRC001, RemoteProfiles.xiaomiRC003]
        let connected = profiles.filter {
            $0.matchesHID(vendorID: 0x2717, productID: 0x32B8, name: "小米蓝牙语音遥控器")
        }
        XCTAssertTrue(connected.isEmpty, "Shared HID identity must not mark both Xiaomi models connected")
    }

    @MainActor
    func testBLEModelReadSelectsOnlyThePhysicalModelAndDisconnectRevokesHIDIdentity() {
        for modelNumber in ["RC001", "RC001-MS", "RC003", "RC003-MS"] {
            for profile in [RemoteProfiles.xiaomiRC001, RemoteProfiles.xiaomiRC003] {
                let voice = XiaomiRemoteVoice(profile: profile)
                var connected = false
                voice.onStatus = {
                    connected = profile.matchesHID(vendorID: 0x2717, productID: 0x32B8,
                                                   name: "小米蓝牙语音遥控器",
                                                   modelNumber: voice.detectedModelNumber)
                }
                voice.receiveModelNumber(" \(modelNumber)\u{0}\n")
                XCTAssertEqual(connected, profile.acceptsVoiceModel(modelNumber))
                XCTAssertEqual(voice.identityRejected, !connected)
                XCTAssertFalse(voice.isReady, "Model confirmation must not bypass voice capability negotiation")
                if !connected { XCTAssertTrue(voice.status.contains("不符")) }
                voice.stop()
                XCTAssertNil(voice.detectedModelNumber)
                XCTAssertFalse(connected, "Disconnect must revoke HID model confirmation")
                voice.onStatus = nil
            }
        }
    }

    @MainActor
    func testNativeKeySuppressionStaysActiveBeforeSharedModelConfirmation() {
        let guardProbe = RecordingRemoteVolumeGuard()
        let manager = XiaomiRemoteHIDManager(profiles: [RemoteProfiles.xiaomiRC001], volumeGuard: guardProbe)

        manager.setOperationMode(.native)
        manager.setOperationMode(.mapping)

        XCTAssertEqual(guardProbe.mappingUpdates, [false, true])
        manager.stop()
        XCTAssertTrue(guardProbe.stopped)
    }

    func testModelConfirmationCannotOverrideHIDIdentityOrAffectDistinctRemotes() {
        let pro = RemoteProfiles.xiaomiRC003
        XCTAssertFalse(pro.matchesHID(vendorID: 0, productID: pro.productID, name: "Mi RC", modelNumber: pro.model))
        XCTAssertFalse(pro.matchesHID(vendorID: pro.vendorID, productID: 0, name: "Mi RC", modelNumber: pro.model))
        XCTAssertFalse(pro.matchesHID(vendorID: pro.vendorID, productID: pro.productID, name: "Mi RC", modelNumber: "unknown"))
        let chromecast = RemoteProfiles.googleG9N9N
        XCTAssertTrue(chromecast.matchesHID(vendorID: chromecast.vendorID, productID: chromecast.productID, name: nil))
    }

    func testRemote2ProfileUsesTheVerifiedRC001Identity() {
        let profile = RemoteProfiles.xiaomiRC001

        XCTAssertTrue(RemoteProfiles.all.contains(profile))
        XCTAssertEqual(profile.model, "RC001-MS")
        XCTAssertEqual(profile.vendorID, 0x2717)
        XCTAssertEqual(profile.productID, 0x32B8)
        XCTAssertEqual(profile.inputs.count, 13)
        XCTAssertTrue(profile.acceptsVoiceModel("RC001"))
        XCTAssertTrue(profile.acceptsVoiceModel("RC001-MS"))
        XCTAssertFalse(profile.acceptsVoiceModel("RC003"))
        XCTAssertFalse(profile.acceptsVoiceModel("RC003-MS"))
        XCTAssertTrue(profile.matchesBluetoothName(" Xiaomi Bluetooth Remote 2 "))
        XCTAssertTrue(profile.matchesBluetoothName("小米蓝牙遥控器2"))
        XCTAssertFalse(profile.matchesBluetoothName("Chromecast Remote"))
    }

    func testRemote2SharesTheRC003HIDAndATVVMappings() {
        let rc001 = RemoteProfiles.xiaomiRC001
        let rc003 = RemoteProfiles.xiaomiRC003
        XCTAssertEqual(rc001.hidMatching.count, rc003.hidMatching.count)
        XCTAssertEqual(rc001.hidMatching.first?["VendorID"] as? Int, rc003.hidMatching.first?["VendorID"] as? Int)
        XCTAssertEqual(rc001.hidMatching.first?["ProductID"] as? Int, rc003.hidMatching.first?["ProductID"] as? Int)
        XCTAssertEqual(rc001.inputs, rc003.inputs)
        XCTAssertEqual(rc001.voiceCapabilitiesRequest, rc003.voiceCapabilitiesRequest)

        let parser = XiaomiRemoteHIDParser(profile: rc001)
        let usages: [(UInt32, ControllerInput)] = [
            (0x66, .power), (0x52, .dpadUp), (0x51, .dpadDown),
            (0x50, .dpadLeft), (0x4F, .dpadRight), (0x28, .buttonA),
            (0xF1, .buttonB), (0x65, .menu), (0x80, .rightShoulder),
            (0x81, .leftShoulder), (0x35, .buttonY), (0x4A, .home),
            (0x3E, .options),
        ]
        for (usage, input) in usages {
            XCTAssertEqual(parser.parse(usagePage: 0x07, usage: usage, value: 1),
                           [.init(input: input, isPressed: true)])
            XCTAssertEqual(parser.parse(usagePage: 0x07, usage: usage, value: 0),
                           [.init(input: input, isPressed: false)])
        }
    }

    @MainActor
    func testSwitchingBetweenXiaomiModelsRestoresIndependentSettings() throws {
        let suite = "RcHarness.XiaomiRC001Tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        model.update(ButtonMapping(action: .copy), for: .buttonA, trigger: .double)
        model.setGlobalInput(.menu)
        let proProfiles = model.profiles

        model.selectRemoteProfile(RemoteProfiles.xiaomiRC001.id)
        XCTAssertEqual(model.mapping[.buttonA, .double].action, .disabled)
        XCTAssertEqual(model.globalButtons.input, .power)
        model.update(ButtonMapping(action: .paste), for: .buttonA, trigger: .double)
        model.setGlobalInput(.home)
        let rc001ProfileID = try XCTUnwrap(model.selectedProfileID)
        XCTAssertTrue(model.bindProfile(rc001ProfileID, to: "codex"))
        model.voiceMode = .tap
        XCTAssertEqual(model.voiceMode, .hold)

        let restored = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        XCTAssertEqual(restored.remoteProfile, RemoteProfiles.xiaomiRC001)
        XCTAssertEqual(restored.mapping[.buttonA, .double].action, .paste)
        XCTAssertEqual(restored.globalButtons.input, .home)
        XCTAssertEqual(restored.harnesses.first { $0.id == "codex" }?.profileID, rc001ProfileID)
        restored.selectRemoteProfile(RemoteProfiles.xiaomiRC003.id)
        XCTAssertEqual(restored.profiles, proProfiles)
        XCTAssertEqual(restored.mapping[.buttonA, .double].action, .copy)
        XCTAssertEqual(restored.globalButtons.input, .menu)
        XCTAssertFalse(RemoteProfiles.xiaomiRC003.acceptsVoiceModel("RC001"))
    }

    func testSharedHIDIdentityDoesNotPreventNativeKeySuppressionAndRestore() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pipe = Pipe()
        try pipe.fileHandleForWriting.write(contentsOf: Data("mapping\n".utf8))
        try pipe.fileHandleForWriting.close()
        let profile = RemoteProfiles.xiaomiRC001
        let service: [String: Any] = [
            "type": "service", "IORegistryEntryID": 7,
            "VendorID": profile.vendorID!, "ProductID": profile.productID!,
            "LocationID": 42, "PrimaryUsagePage": 7, "PrimaryUsage": 6,
        ]
        let original = [RemoteKeyMapping(source: 0x70000003E, destination: 0x700000004)]
        var current = original
        var writes: [[RemoteKeyMapping]] = []
        let worker = RemoteVolumeGuardWorker(directory: directory, input: pipe.fileHandleForReading,
                                            profiles: [profile, RemoteProfiles.xiaomiRC003]) { arguments in
            switch arguments.first {
            case "list": return try JSONSerialization.data(withJSONObject: service)
            case "dump":
                let entries = current.map { ["Src": $0.source, "Dst": $0.destination] }
                let record: [String: Any] = ["IORegistryEntryID": 7, "ServiceFilterDebug": [
                    ["name": "com.apple.iokit.hid.IOHIDKeyboardFilter", "plugin": ["UserKeyMapping": entries]],
                ]]
                return try PropertyListSerialization.data(fromPropertyList: ["ServiceRecords": [record]], format: .xml, options: 0)
            case "property":
                let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(arguments.last!.utf8)) as? [String: Any])
                let entries = try XCTUnwrap(payload["UserKeyMapping"] as? [[String: NSNumber]])
                current = try entries.map {
                    .init(source: try XCTUnwrap($0["HIDKeyboardModifierMappingSrc"]).uint64Value,
                          destination: try XCTUnwrap($0["HIDKeyboardModifierMappingDst"]).uint64Value)
                }
                writes.append(current)
                return Data()
            default: XCTFail("Unexpected hidutil command"); return Data()
            }
        }
        worker.run()
        XCTAssertEqual(writes.count, 2)
        XCTAssertEqual(Set(writes.first ?? []), Set(RemoteVolumeSuppression.suppress(original)))
        XCTAssertEqual(current, original)
    }
}
