import XCTest
@testable import RcHarness

final class GoogleRemoteTests: XCTestCase {
    func testConsumerReportsCoverEveryNonVoiceButtonAndRelease() {
        let parser = XiaomiRemoteHIDParser(profile: RemoteProfiles.googleG9N9N)
        let usages: [(UInt32, ControllerInput)] = [
            (0x41, .buttonA), (0x42, .dpadUp), (0x43, .dpadDown), (0x44, .dpadLeft), (0x45, .dpadRight),
            (0x224, .buttonB), (0x223, .home), (0xE9, .rightShoulder), (0xEA, .leftShoulder),
            (0xE2, .mute), (0x19E, .power), (0x89, .inputSource), (0x189, .inputSource), (0x77, .youtube), (0x78, .netflix),
        ]
        XCTAssertEqual(Set(usages.map(\.1)), Set(RemoteProfiles.googleG9N9N.inputs).subtracting([.options]))
        for (usage, input) in usages {
            for value in [1, 2, 0] {
                XCTAssertEqual(parser.parse(usagePage: 0x0C, usage: usage, value: value),
                               [XiaomiRemoteParsedEvent(input: input, isPressed: value != 0)])
            }
        }
        XCTAssertEqual(XiaomiRemoteHIDParser().parse(usagePage: 0x0C, usage: 0x42, value: 1).first?.input, .buttonB)
        for (page, usage): (UInt32, UInt32) in [(0x07, 0x3E), (0x0C, 0xCF), (0x09, 3), (0x0C, 0xFFFF)] {
            XCTAssertTrue(parser.parse(usagePage: page, usage: usage, value: 1).isEmpty)
        }
    }

    func testIdentityRejectsOtherRemoteModelsAndPnPDevices() {
        let profile = RemoteProfiles.googleG9N9N
        XCTAssertTrue(RemoteProfiles.all.contains(profile))
        XCTAssertEqual(profile.inputs.count, 15)
        XCTAssertEqual(RemoteProfiles.xiaomiRC003.inputs.count, 13)
        XCTAssertTrue(profile.matchesBluetoothName(" Chromecast Remote \n"))
        XCTAssertTrue(profile.acceptsVoiceModel("G9N9N"))
        XCTAssertFalse(profile.matchesBluetoothName("Other Chromecast Remote"))
        XCTAssertFalse(profile.matchesBluetoothName("MI RC"))
        XCTAssertFalse(profile.acceptsVoiceModel("RC003-MS"))
        let identity = Data([2, 0xD1, 0x18, 0x50, 0x94, 0x1B, 1])
        XCTAssertTrue(profile.acceptsVoicePnPID(identity))
        XCTAssertFalse(profile.acceptsVoicePnPID(identity.dropLast()))
        // Firmware 26.2 reports model A0 and VendorIDSource 1 with this VID/PID.
        XCTAssertTrue(profile.acceptsVoicePnPID(Data([1, 0xD1, 0x18, 0x50, 0x94, 0x10, 1])))
        XCTAssertFalse(profile.acceptsVoicePnPID(Data([0, 0xD1, 0x18, 0x50, 0x94, 0, 1])))
        XCTAssertFalse(profile.acceptsVoicePnPID(Data([3, 0xD1, 0x18, 0x50, 0x94, 0, 1])))
        XCTAssertFalse(profile.acceptsVoicePnPID(Data([1, 0xD1, 0x18, 0x51, 0x94, 0, 1])))
        XCTAssertFalse(profile.acceptsVoicePnPID(Data([2, 0xD1, 0x18, 0x51, 0x94, 0, 1])))
        XCTAssertFalse(profile.acceptsVoicePnPID(Data([2, 0xD2, 0x18, 0x50, 0x94, 0, 1])))
        XCTAssertFalse(RemoteProfiles.xiaomiRC003.acceptsVoicePnPID(identity))
    }

    func testNegotiatedHeaderlessFramesPreserveADPCMStateAcrossNotifications() throws {
        XCTAssertEqual(RemoteProfiles.googleG9N9N.voiceCapabilitiesRequest, [0x0A, 1, 0, 0, 2, 2])
        XCTAssertEqual(RemoteProfiles.xiaomiRC003.voiceCapabilitiesRequest, [0x0A, 1, 0, 0, 3, 3])
        for frameBytes in [120, 128, 160] {
            let capabilities = try XCTUnwrap(RemoteVoiceCapabilities(Data([0x0B, 1, 0, 2, 3, 0, UInt8(frameBytes)])))
            var stream = RemoteVoiceStream()
            stream.start(session: 7)
            let data = Data(repeating: 0x17, count: frameBytes * 2)
            var decoder = RemoteADPCMDecoder()
            let expected = decoder.decode(data)
            let first = stream.append(data.prefix(37), frameBytes: capabilities.frameBytes)
            let rest = stream.append(data.dropFirst(37), frameBytes: capabilities.frameBytes)
            XCTAssertEqual(first + rest, expected)
            XCTAssertEqual(stream.decodedFrames, 2)
            XCTAssertEqual(stream.pendingBytes, 0)
        }
        for data: [UInt8] in [[0x0B, 1, 0, 1, 3, 0, 128], [0x0B, 1, 0, 2, 3, 0, 0], [0x0B, 1, 0, 2, 3, 0xFF, 0xFF]] {
            XCTAssertNil(RemoteVoiceCapabilities(Data(data)))
        }
    }

    func testBLEVoiceEdgesAreDeduplicatedAndCanBeResetOnDisconnect() {
        var button = RemoteVoiceButtonState()
        XCTAssertNil(button.update(pressed: false))
        XCTAssertEqual(button.update(pressed: true), true)
        XCTAssertNil(button.update(pressed: true))
        XCTAssertEqual(button.update(pressed: false), false)
        XCTAssertNil(button.update(pressed: false))
        XCTAssertEqual(button.update(pressed: true), true)
        XCTAssertEqual(button.update(pressed: false), false)
        XCTAssertFalse(button.isPressed)
    }

    func testConsumerMappingsAreSuppressedAndRestoredWithoutLosingOtherMappings() {
        let usages: [UInt64] = [0x41, 0x42, 0x43, 0x44, 0x45, 0x224, 0x223, 0xE9, 0xEA, 0xE2, 0x19E, 0x89, 0x189, 0x77, 0x78]
        let original = usages.map { RemoteKeyMapping(source: 0xC00000000 | $0, destination: 0x700000004) }
        let suppressed = RemoteVolumeSuppression.suppress(original)
        for usage in usages {
            XCTAssertEqual(suppressed.filter { $0.source == 0xC00000000 | usage },
                           [RemoteKeyMapping(source: 0xC00000000 | usage, destination: 0)])
        }
        XCTAssertEqual(Set(RemoteVolumeSuppression.restore(suppressed, original: original)), Set(original))
    }

    func testGuardMapsGoogleAndOnlyProtectsInactiveXiaomiVoiceKeys() throws {
        try assertGuardOnlyChangesSelectedModel(RemoteProfiles.googleG9N9N)
    }

    private func assertGuardOnlyChangesSelectedModel(_ google: RemoteProfile) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pipe = Pipe()
        try pipe.fileHandleForWriting.write(contentsOf: Data("mapping\n".utf8))
        try pipe.fileHandleForWriting.close()
        let xiaomi = RemoteProfiles.xiaomiRC003
        let selectedProduct = try XCTUnwrap(google.productID)
        let services: [[String: Any]] = [google, xiaomi, RemoteProfiles.xiaomiRC001].enumerated().map { index, profile in
            ["type": "service", "IORegistryEntryID": index + 1, "VendorID": profile.vendorID ?? 0x5678,
             "ProductID": profile.productID ?? selectedProduct, "Product": profile.hidProductNames.first ?? profile.model,
             "LocationID": index + 10, "PrimaryUsagePage": 0x0C, "PrimaryUsage": 1]
        }
        let original = [RemoteKeyMapping(source: 0xC000000E9, destination: 0x700000004)]
        var current: [Int: [RemoteKeyMapping]] = [1: original, 2: original, 3: original]
        var writtenProducts: [Int] = []
        let worker = RemoteVolumeGuardWorker(directory: directory, input: pipe.fileHandleForReading,
                                            profiles: [google]) { arguments in
            switch arguments.first {
            case "list":
                let match = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(arguments[3].utf8)) as? [String: Any])
                return try services.filter { service in
                    match.allSatisfy { key, value in
                        (service[key] as? NSObject)?.isEqual(value) == true
                    }
                }
                    .reduce(into: Data()) { data, service in
                        data.append(try JSONSerialization.data(withJSONObject: service))
                        data.append(0x0A)
                    }
            case "dump":
                let records: [[String: Any]] = current.map { id, mappings in
                    ["IORegistryEntryID": id, "ServiceFilterDebug": [
                        ["name": "com.apple.iokit.hid.IOHIDKeyboardFilter", "plugin": [
                            "UserKeyMapping": mappings.map { ["Src": $0.source, "Dst": $0.destination] }
                        ]]
                    ]]
                }
                return try PropertyListSerialization.data(fromPropertyList: ["ServiceRecords": records], format: .xml, options: 0)
            case "property":
                let match = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(arguments[2].utf8)) as? [String: Int])
                let product = try XCTUnwrap(match["ProductID"])
                writtenProducts.append(product)
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(arguments[4].utf8)) as? [String: [[String: UInt64]]])
                let registry = try XCTUnwrap(services.first { ($0["LocationID"] as? Int) == match["LocationID"] }?["IORegistryEntryID"] as? Int)
                current[registry] = try XCTUnwrap(body["UserKeyMapping"]).map {
                    RemoteKeyMapping(source: $0["HIDKeyboardModifierMappingSrc"]!, destination: $0["HIDKeyboardModifierMappingDst"]!)
                }
                if writtenProducts.count <= 3 {
                    XCTAssertTrue(current[registry]!.contains(.init(source: 0x70000003E, destination: 0)))
                    if registry != 1 {
                        XCTAssertTrue(current[registry]!.contains(original[0]), "Inactive Xiaomi volume keys stay native")
                    }
                }
                return Data()
            default:
                XCTFail("Unexpected hidutil invocation")
                return Data()
            }
        }
        worker.run()
        XCTAssertEqual(writtenProducts.filter { $0 == selectedProduct }.count, 2)
        XCTAssertEqual(writtenProducts.filter { $0 == xiaomi.productID }.count, 4)
        XCTAssertEqual(Set(current[1] ?? []), Set(original))
        XCTAssertEqual(current[2], original)
        XCTAssertEqual(current[3], original)
    }

    @MainActor
    func testSwitchingRealAdaptersRestoresTheirOwnMappingsAndGlobalKeys() {
        let suite = "RcHarness.GoogleRemoteTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        model.setGlobalInput(.menu)
        let profiles = model.profiles
        model.openButtonEditor(.menu)
        model.selectRemoteProfile(RemoteProfiles.googleG9N9N.id)
        XCTAssertNotEqual(model.profiles, profiles)
        XCTAssertEqual(model.selectedInput, .buttonA)
        XCTAssertEqual(model.globalButtons.input, .power)
        XCTAssertEqual(model.effectiveMapping[.power].action, model.globalButtons.single.action)
        model.setGlobalInput(.youtube)
        XCTAssertEqual(model.globalButtons.input, .youtube)
        model.voiceMode = .tap
        XCTAssertEqual(model.voiceMode, .tap)
        model.update(ButtonMapping(action: .copy), for: .netflix, trigger: .double)
        let restored = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        XCTAssertEqual(restored.remoteProfile, RemoteProfiles.googleG9N9N)
        XCTAssertEqual(restored.voiceMode, .tap)
        XCTAssertEqual(restored.effectiveMapping[.netflix, .double].action, .copy)
        model.selectRemoteProfile(RemoteProfiles.xiaomiRC003.id)
        XCTAssertEqual(model.voiceMode, .hold)
        XCTAssertEqual(model.globalButtons.input, .menu)
        XCTAssertEqual(model.effectiveMapping[.netflix, .double].action, .disabled)
        XCTAssertEqual(model.profiles, profiles)
        model.selectRemoteProfile(RemoteProfiles.googleG9N9N.id)
        XCTAssertEqual(model.voiceMode, .tap)
        XCTAssertEqual(model.globalButtons.input, .youtube)
        XCTAssertEqual(model.effectiveMapping[.netflix, .double].action, .copy)
    }

    @MainActor
    func testEveryGoogleArtworkButtonHasItsOwnHitTarget() throws {
        for size in [CGSize(width: 80, height: 316), CGSize(width: 180, height: 520)] {
            let bounds = RemoteArtworkView.artworkBounds(in: size, artwork: .chromecast)
            for input in RemoteProfiles.googleG9N9N.inputs {
                for positions in [RemoteArtworkView.markerPositions(for: .chromecast),
                                  RemoteArtworkView.connectorPositions(for: .chromecast)] {
                    let position = try XCTUnwrap(positions[input])
                    let location = CGPoint(x: bounds.minX + position.x * bounds.width, y: bounds.minY + position.y * bounds.height)
                    XCTAssertEqual(RemoteArtworkView.input(at: location, in: bounds, artwork: .chromecast), input,
                                   "Wrong target for \(input) at \(size)")
                }
            }
            XCTAssertTrue(RemoteArtworkView.controlOutline(for: .menu, in: bounds, artwork: .chromecast).isEmpty)
        }
    }
}
