import XCTest
@testable import RcHarness

final class NativeKeyRecoveryTests: XCTestCase {
    private final class HID {
        let original = [RemoteKeyMapping(source: 0x700000052, destination: 0x700000004)]
        var mappings: [Int: [RemoteKeyMapping]] = [:]
        var failures: Set<Int> = []
        var ignoreWrites = false
        var writes: [Int] = []
        var pauses: [TimeInterval] = []

        func execute(_ arguments: [String]) throws -> Data {
            switch arguments.first {
            case "list":
                let profile = RemoteProfiles.xiaomiRC003
                return try mappings.keys.sorted().reduce(into: Data()) { data, id in
                    let service: [String: Any] = ["type": "service", "IORegistryEntryID": id,
                        "VendorID": profile.vendorID!, "ProductID": profile.productID!, "LocationID": id,
                        "PrimaryUsagePage": 1, "PrimaryUsage": 6]
                    data.append(try JSONSerialization.data(withJSONObject: service))
                    data.append(0x0A)
                }
            case "dump":
                let records: [[String: Any]] = mappings.map { id, entries in
                    ["IORegistryEntryID": id, "ServiceFilterDebug": [
                        ["name": "com.apple.iokit.hid.IOHIDKeyboardFilter", "plugin": [
                            "UserKeyMapping": entries.map { ["Src": $0.source, "Dst": $0.destination] }]]]]
                }
                return try PropertyListSerialization.data(fromPropertyList: ["ServiceRecords": records], format: .xml, options: 0)
            case "property":
                let match = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(arguments[2].utf8)) as? [String: Int])
                let id = try XCTUnwrap(match["LocationID"])
                writes.append(id)
                if failures.contains(id) { throw NSError(domain: "hidUnavailable", code: id) }
                if ignoreWrites { return Data() }
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(arguments[4].utf8)) as? [String: [[String: UInt64]]])
                mappings[id] = try XCTUnwrap(body["UserKeyMapping"]).map {
                    .init(source: $0["HIDKeyboardModifierMappingSrc"]!, destination: $0["HIDKeyboardModifierMappingDst"]!)
                }
                return Data()
            default: throw NSError(domain: "unexpectedCommand", code: 1)
            }
        }

        func writeJournal(to directory: URL, ids: [Int]) throws {
            let profile = RemoteProfiles.xiaomiRC003
            let snapshots: [[String: Any]] = ids.map { id in
                mappings[id] = RemoteVolumeSuppression.suppress(original)
                return ["registryID": id, "matching": ["VendorID": profile.vendorID!, "ProductID": profile.productID!,
                                                      "LocationID": id, "PrimaryUsagePage": 1, "PrimaryUsage": 6],
                        "original": original.map { ["source": $0.source, "destination": $0.destination] }]
            }
            try JSONSerialization.data(withJSONObject: snapshots).write(to: directory.appendingPathComponent("remote-volume-restore.json"))
        }

        func run(at directory: URL) throws -> Bool {
            let pipe = Pipe()
            try pipe.fileHandleForWriting.close()
            return RemoteVolumeGuardWorker(directory: directory, input: pipe.fileHandleForReading,
                profiles: [RemoteProfiles.xiaomiRC003], retryTiming: .init(pause: { self.pauses.append($0) }),
                hidutil: execute).run()
        }
    }

    func testPartialRestorationCommitsSuccessfulServicesAndRetainsOnlyFailures() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let hid = HID()
        try hid.writeJournal(to: directory, ids: [1, 2])
        hid.failures = [1]
        XCTAssertFalse(try hid.run(at: directory))
        XCTAssertEqual(hid.writes.filter { $0 == 1 }.count, 4)
        XCTAssertEqual(hid.writes.filter { $0 == 2 }.count, 1, "A restored service must not be rewritten on retry")
        XCTAssertEqual(hid.mappings[2], hid.original)
        let journal = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("remote-volume-restore.json"))) as? [[String: Any]]
        XCTAssertEqual(journal?.compactMap { $0["registryID"] as? Int }, [1])
        XCTAssertEqual(hid.pauses, [0.5, 1, 2])
        hid.failures = []
        XCTAssertTrue(try hid.run(at: directory), "A new guard must recover the retained snapshot")
        XCTAssertEqual(hid.mappings[1], hid.original)
    }

    func testSuccessfulHidutilExitWithoutRestorationStillFailsAndKeepsJournal() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let hid = HID()
        try hid.writeJournal(to: directory, ids: [1])
        hid.ignoreWrites = true
        XCTAssertFalse(try hid.run(at: directory))
        XCTAssertEqual(hid.writes.count, 4)
        XCTAssertNotEqual(hid.mappings[1], hid.original)
        hid.ignoreWrites = false
        XCTAssertTrue(try hid.run(at: directory))
        XCTAssertEqual(hid.mappings[1], hid.original)
    }
}
