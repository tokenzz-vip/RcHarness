import XCTest
@testable import RcHarness

final class GuardTests: XCTestCase {
    func testVoiceOnlyRestorePreservesAnotherToolsChangesToOrdinaryKeys() {
        let voiceSources = RemoteVolumeSuppression.inactiveVoiceSources(for: RemoteProfiles.xiaomiRC001)
        let original = [RemoteKeyMapping(source: 0x70000003E, destination: 0x700000004),
                        RemoteKeyMapping(source: 0x700000052, destination: 0x700000005)]
        var current = RemoteVolumeSuppression.suppress(original, sources: voiceSources)
        current.removeAll { $0.source == 0x700000052 }
        current.append(.init(source: 0x700000052, destination: 0))
        let restored = RemoteVolumeSuppression.restore(current, original: original, sources: voiceSources)
        XCTAssertTrue(restored.contains(original[0]))
        XCTAssertTrue(restored.contains(.init(source: 0x700000052, destination: 0)), "We never owned the ordinary key")
    }

    func testInactiveVoiceProtectionEndsWhenNativeModeIsSelected() throws {
        for resolvesModel in [false, true] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let pipe = Pipe()
            try pipe.fileHandleForWriting.write(contentsOf: Data("mapping\n".utf8))
            let xiaomi = RemoteProfiles.xiaomiRC001
            let original = [RemoteKeyMapping(source: 0x70000003E, destination: 0x700000004),
                            RemoteKeyMapping(source: 0x700000052, destination: 0x700000005)]
            var current = original
            var writes = 0
            var detectedModel: String?
            let worker = RemoteVolumeGuardWorker(directory: directory, input: pipe.fileHandleForReading,
                profiles: [resolvesModel ? xiaomi : RemoteProfiles.googleG9N9N],
                identity: .init(modelNumber: { _ in resolvesModel ? detectedModel : "RC001" })) { arguments in
                switch arguments.first {
                case "list":
                    let match = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(arguments[3].utf8)) as? [String: Int])
                    guard match["VendorID"] == xiaomi.vendorID else { return Data() }
                    let service: [String: Any] = ["type": "service", "IORegistryEntryID": 7,
                        "VendorID": xiaomi.vendorID!, "ProductID": xiaomi.productID!, "LocationID": 42,
                        "PrimaryUsagePage": 1, "PrimaryUsage": 6]
                    return try JSONSerialization.data(withJSONObject: service)
                case "dump":
                    let record: [String: Any] = ["IORegistryEntryID": 7, "ServiceFilterDebug": [
                        ["name": "com.apple.iokit.hid.IOHIDKeyboardFilter", "plugin": [
                            "UserKeyMapping": current.map { ["Src": $0.source, "Dst": $0.destination] }]]]]
                    return try PropertyListSerialization.data(fromPropertyList: ["ServiceRecords": [record]], format: .xml, options: 0)
                case "property":
                    writes += 1
                    let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(arguments[4].utf8)) as? [String: [[String: UInt64]]])
                    current = try XCTUnwrap(body["UserKeyMapping"]).map {
                        .init(source: $0["HIDKeyboardModifierMappingSrc"]!, destination: $0["HIDKeyboardModifierMappingDst"]!)
                    }
                    if resolvesModel && writes == 1 {
                        XCTAssertTrue(current.contains(.init(source: 0x700000052, destination: 0)))
                        detectedModel = "RC003"
                        try pipe.fileHandleForWriting.write(contentsOf: Data("mapping\n".utf8))
                    } else if writes == (resolvesModel ? 2 : 1) {
                        XCTAssertTrue(current.contains(.init(source: 0x70000003E, destination: 0)))
                        XCTAssertTrue(current.contains(original[1]), "Model resolution must return ordinary keys to native")
                        try pipe.fileHandleForWriting.write(contentsOf: Data("native\n".utf8))
                    } else {
                        XCTAssertEqual(Set(current), Set(original))
                        try pipe.fileHandleForWriting.close()
                    }
                    return Data()
                default: throw NSError(domain: "unexpectedCommand", code: 1)
                }
            }
            XCTAssertTrue(worker.run())
            XCTAssertEqual(writes, resolvesModel ? 3 : 2)
            XCTAssertEqual(Set(current), Set(original))
        }
    }

    func testInactiveXiaomiVoiceKeysAreSuppressedWithoutChangingOtherNativeKeys() throws {
        for profile in [RemoteProfiles.xiaomiRC001, RemoteProfiles.xiaomiRC003, RemoteProfiles.googleG9N9N] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let pipe = Pipe()
            try pipe.fileHandleForWriting.write(contentsOf: Data("mapping\n".utf8))
            try pipe.fileHandleForWriting.close()
            let original = [RemoteKeyMapping(source: 0x700000052, destination: 0x700000004)]
            var current = [1: original, 2: original]
            var writes: [Int] = []
            let worker = RemoteVolumeGuardWorker(directory: directory, input: pipe.fileHandleForReading,
                profiles: [profile], identity: .init(modelNumber: { $0 == 1 ? "RC001" : "RC003" })) { arguments in
                switch arguments.first {
                case "list":
                    return try [1, 2].reduce(into: Data()) { data, id in
                        let record: [String: Any] = ["type": "service", "IORegistryEntryID": id,
                            "VendorID": RemoteProfiles.xiaomiRC001.vendorID!, "ProductID": RemoteProfiles.xiaomiRC001.productID!, "LocationID": id,
                            "PrimaryUsagePage": 1, "PrimaryUsage": 6]
                        data.append(try JSONSerialization.data(withJSONObject: record))
                        data.append(0x0A)
                    }
                case "dump":
                    let records = current.map { id, mappings in
                        ["IORegistryEntryID": id, "ServiceFilterDebug": [["name": "com.apple.iokit.hid.IOHIDKeyboardFilter",
                            "plugin": ["UserKeyMapping": mappings.map { ["Src": $0.source, "Dst": $0.destination] }]]]]
                    }
                    return try PropertyListSerialization.data(fromPropertyList: ["ServiceRecords": records], format: .xml, options: 0)
                case "property":
                    let match = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(arguments[2].utf8)) as? [String: Int])
                    let id = try XCTUnwrap(match["LocationID"])
                    writes.append(id)
                    let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(arguments[4].utf8)) as? [String: [[String: UInt64]]])
                    current[id] = try XCTUnwrap(body["UserKeyMapping"]).map {
                        .init(source: $0["HIDKeyboardModifierMappingSrc"]!, destination: $0["HIDKeyboardModifierMappingDst"]!)
                    }
                    if writes.filter({ $0 == id }).count == 1 {
                        XCTAssertTrue(current[id]!.contains(.init(source: 0x70000003E, destination: 0)),
                                      "An inactive Xiaomi's F5 voice key must not reach macOS")
                        let selected = (id == 1 && profile == RemoteProfiles.xiaomiRC001)
                            || (id == 2 && profile == RemoteProfiles.xiaomiRC003)
                        if !selected {
                            XCTAssertTrue(current[id]!.contains(original[0]), "Keep inactive direction keys native")
                            XCTAssertFalse(current[id]!.contains(.init(source: 0x700000052, destination: 0)))
                        }
                    }
                    return Data()
                default: throw NSError(domain: "unexpectedCommand", code: 1)
                }
            }
            XCTAssertTrue(worker.run())
            XCTAssertEqual(writes.filter { $0 == 1 }.count, 2, "Protect and restore RC001's voice key")
            XCTAssertEqual(writes.filter { $0 == 2 }.count, 2, "Protect and restore RC003's voice key")
            XCTAssertEqual(current, [1: original, 2: original])
        }
    }

    func testMappingNeverTouchesMouseServiceWithSameRemoteIdentity() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let pipe = Pipe()
        try pipe.fileHandleForWriting.write(contentsOf: Data("mapping\n".utf8))
        try pipe.fileHandleForWriting.close()
        let profile = RemoteProfiles.xiaomiRC003
        let original = [RemoteKeyMapping(source: 0x700000052, destination: 0x700000004)]
        var current: [Int: [RemoteKeyMapping]] = [1: original, 2: original]
        var writes: [Int] = []
        let worker = RemoteVolumeGuardWorker(directory: directory, input: pipe.fileHandleForReading,
                                             profiles: [profile]) { arguments in
            switch arguments.first {
            case "list":
                let records: [[String: Any]] = [
                    ["type": "service", "IORegistryEntryID": 1, "VendorID": profile.vendorID!,
                     "ProductID": profile.productID!, "LocationID": 11, "PrimaryUsagePage": 1, "PrimaryUsage": 6],
                    ["type": "service", "IORegistryEntryID": 2, "VendorID": profile.vendorID!,
                     "ProductID": profile.productID!, "LocationID": 12, "PrimaryUsagePage": 1, "PrimaryUsage": 2],
                ]
                return try records.reduce(into: Data()) { data, record in
                    data.append(try JSONSerialization.data(withJSONObject: record))
                    data.append(0x0A)
                }
            case "dump":
                let records = current.map { id, mappings in
                    ["IORegistryEntryID": id, "ServiceFilterDebug": [["name": "com.apple.iokit.hid.IOHIDKeyboardFilter",
                        "plugin": ["UserKeyMapping": mappings.map { ["Src": $0.source, "Dst": $0.destination] }]]]]
                }
                return try PropertyListSerialization.data(fromPropertyList: ["ServiceRecords": records], format: .xml, options: 0)
            case "property":
                let match = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(arguments[2].utf8)) as? [String: Int])
                let id = try XCTUnwrap(match["LocationID"]) - 10
                writes.append(id)
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(arguments[4].utf8)) as? [String: [[String: UInt64]]])
                current[id] = try XCTUnwrap(body["UserKeyMapping"]).map {
                    RemoteKeyMapping(source: $0["HIDKeyboardModifierMappingSrc"]!, destination: $0["HIDKeyboardModifierMappingDst"]!)
                }
                return Data()
            default:
                throw NSError(domain: "unexpectedCommand", code: 1)
            }
        }

        XCTAssertTrue(worker.run())
        XCTAssertEqual(writes, [1, 1], "Only the keyboard service may receive temporary mappings")
        XCTAssertEqual(current[2], original)
    }

    func testUnmatchedServiceRetriesBackOffInsteadOfPollingForever() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pipe = Pipe()
        let lock = NSLock()
        var listCalls = 0
        // LocationID is missing, so the guard can never write a safe mapping.
        let service = Data(#"{"type":"service","IORegistryEntryID":7,"VendorID":10007,"ProductID":12984}"#.utf8)
        let dump = try PropertyListSerialization.data(fromPropertyList: ["ServiceRecords": []], format: .xml, options: 0)
        let worker = RemoteVolumeGuardWorker(
            directory: directory, input: pipe.fileHandleForReading,
            retryMilliseconds: 5, maximumRetryMilliseconds: 40,
            profiles: [RemoteProfiles.xiaomiRC003]
        ) { arguments in
            if arguments.first == "list" {
                lock.lock(); listCalls += 1; lock.unlock()
                return service
            }
            return dump
        }
        let finished = expectation(description: "guard exits on EOF")
        // The worker is confined to this background thread until it returns.
        nonisolated(unsafe) let backgroundWorker = worker
        Thread.detachNewThread {
            backgroundWorker.run()
            finished.fulfill()
        }
        try pipe.fileHandleForWriting.write(contentsOf: Data("mapping\n".utf8))
        Thread.sleep(forTimeInterval: 0.4)
        try pipe.fileHandleForWriting.close()
        wait(for: [finished], timeout: 5)
        lock.lock(); defer { lock.unlock() }
        // Without backoff a 5 ms retry would list services about 80 times.
        XCTAssertGreaterThan(listCalls, 2)
        XCTAssertLessThan(listCalls, 20)
    }

    func testUninstallCommandOnlyTouchesTheFixedDriverPath() {
        let command = RemoteMicrophoneInstallation.uninstallationCommand()
        XCTAssertTrue(command.contains("'/Library/Audio/Plug-Ins/HAL/RcHarnessMicrophone.driver'"))
        XCTAssertEqual(command.components(separatedBy: "/bin/rm -rf").count, 2)
        XCTAssertTrue(command.contains("killall -TERM coreaudiod"))
    }

    func testEOFRestoreRetriesATransientHidutilFailure() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pipe = Pipe()
        try pipe.fileHandleForWriting.write(contentsOf: Data("mapping\n".utf8))
        try pipe.fileHandleForWriting.close()
        let service: [String: Any] = ["type": "service", "IORegistryEntryID": 7,
            "VendorID": 10007, "ProductID": 12984, "LocationID": 42,
            "PrimaryUsagePage": 1, "PrimaryUsage": 6]
        let original = [RemoteKeyMapping(source: 0x700000052, destination: 0x700000004)]
        var current = original
        var writes = 0
        let worker = RemoteVolumeGuardWorker(directory: directory, input: pipe.fileHandleForReading,
            retryMilliseconds: 1, maximumRetryMilliseconds: 2,
            profiles: [RemoteProfiles.xiaomiRC003], retryTiming: .init(pause: { _ in })) { arguments in
            switch arguments.first {
            case "list":
                return try JSONSerialization.data(withJSONObject: service)
            case "dump":
                let entries = current.map { ["Src": $0.source, "Dst": $0.destination] }
                let record: [String: Any] = ["IORegistryEntryID": 7, "ServiceFilterDebug": [
                    ["name": "com.apple.iokit.hid.IOHIDKeyboardFilter", "plugin": ["UserKeyMapping": entries]]]]
                return try PropertyListSerialization.data(fromPropertyList: ["ServiceRecords": [record]], format: .xml, options: 0)
            case "property":
                writes += 1
                if writes == 2 { throw NSError(domain: "transient", code: 1) }
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(arguments[4].utf8)) as? [String: [[String: UInt64]]])
                current = try XCTUnwrap(body["UserKeyMapping"]).map {
                    RemoteKeyMapping(source: $0["HIDKeyboardModifierMappingSrc"]!, destination: $0["HIDKeyboardModifierMappingDst"]!)
                }
                return Data()
            default: throw NSError(domain: "unexpected", code: 1)
            }
        }
        worker.run()
        XCTAssertGreaterThanOrEqual(writes, 3)
        XCTAssertEqual(current, original)
    }
}
