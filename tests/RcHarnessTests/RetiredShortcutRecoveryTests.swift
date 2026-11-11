import XCTest
@testable import RcHarness

final class RetiredShortcutRecoveryTests: XCTestCase {
    private final class HID {
        let fn = UInt64(0xFF00000003)
        var mappings: [Int: [RemoteKeyMapping]] = [:]
        var writes: [(Int, [RemoteKeyMapping])] = []
        var ignoreWrites = false

        func execute(_ arguments: [String]) throws -> Data {
            switch arguments[0] {
            case "list":
                let records: [[String: Any]] = mappings.keys.sorted().map { id in
                    let remote = RemoteProfiles.xiaomiRC003
                    return ["type": "service", "IORegistryEntryID": id,
                            "VendorID": id == 2 ? remote.vendorID! : 0,
                            "ProductID": id == 2 ? remote.productID! : 0,
                            "LocationID": id, "PrimaryUsagePage": 1, "PrimaryUsage": 6]
                }
                return try records.reduce(into: Data()) { result, record in
                    result.append(try JSONSerialization.data(withJSONObject: record))
                    result.append(0x0A)
                }
            case "dump":
                let records: [[String: Any]] = mappings.map { id, entries in
                    ["IORegistryEntryID": id, "ServiceFilterDebug": [[
                        "name": "com.apple.iokit.hid.IOHIDKeyboardFilter", "plugin": [
                            "UserKeyMapping": entries.map { ["Src": $0.source, "Dst": $0.destination] }]]]]
                }
                return try PropertyListSerialization.data(fromPropertyList: ["ServiceRecords": records], format: .xml, options: 0)
            case "property":
                let match = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(arguments[2].utf8)) as? [String: Int])
                let id = try XCTUnwrap(match["LocationID"])
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(arguments[4].utf8)) as? [String: [[String: UInt64]]])
                let requested = try XCTUnwrap(body["UserKeyMapping"]).map {
                    RemoteKeyMapping(source: $0["HIDKeyboardModifierMappingSrc"]!, destination: $0["HIDKeyboardModifierMappingDst"]!)
                }
                writes.append((id, requested))
                if !ignoreWrites { mappings[id] = requested }
                return Data()
            default: throw NSError(domain: "UnexpectedHIDCommand", code: 1)
            }
        }

        func run(directory: URL) -> Bool {
            // Recovery must ignore even an old capture command and restore only.
            let commands = Pipe()
            try? commands.fileHandleForWriting.write(contentsOf: Data("mapping\n".utf8))
            try? commands.fileHandleForWriting.close()
            return RemoteVolumeGuardWorker(directory: directory, input: commands.fileHandleForReading,
                recoverRetiredShortcuts: true, retryTiming: .init(pause: { _ in }), hidutil: execute).run()
        }

    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func journal(_ sources: [UInt64], original: [RemoteKeyMapping], directory: URL) throws {
        let snapshots: [[String: Any]] = [["registryID": 1,
            "matching": ["VendorID": 0, "ProductID": 0, "LocationID": 1, "PrimaryUsagePage": 1, "PrimaryUsage": 6],
            "sources": sources, "original": original.map { ["source": $0.source, "destination": $0.destination] }]]
        try JSONSerialization.data(withJSONObject: snapshots).write(to: directory.appendingPathComponent("shortcut-function-restore.json"))
    }

    func testNoJournalNeverAcquiresKeyboardMappingsEvenWithCaptureCommand() throws {
        let hid = HID()
        hid.mappings = [1: []]
        XCTAssertTrue(hid.run(directory: try temporaryDirectory()))
        XCTAssertTrue(hid.writes.isEmpty)
    }

    func testRecoversBothFnOnlyAndAllSevenKeyJournalsWithoutTouchingOtherDevices() throws {
        let hid = HID()
        let all: [UInt64] = [hid.fn, 0x7000000E3, 0x7000000E7, 0x7000000E2, 0x7000000E6, 0x7000000E0, 0x7000000E4]
        for sources in [[hid.fn], all] {
            let directory = try temporaryDirectory()
            let original = sources.map { RemoteKeyMapping(source: $0, destination: 0x700000004) }
            hid.mappings = [1: sources.map { .init(source: $0, destination: 0) }, 2: []]
            hid.writes = []
            try journal(sources, original: original, directory: directory)
            XCTAssertTrue(hid.run(directory: directory))
            XCTAssertEqual(Set(hid.mappings[1]!), Set(original))
            XCTAssertEqual(hid.writes.count, 1)
            XCTAssertEqual(hid.writes.first?.0, 1)
            let remaining = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("shortcut-function-restore.json"))) as? [Any]
            XCTAssertEqual(remaining?.count, 0)
        }
    }

    func testRecoveryPreservesOtherToolsEditsAndUnrelatedKeys() throws {
        let hid = HID()
        let directory = try temporaryDirectory()
        let external = RemoteKeyMapping(source: hid.fn, destination: 0x7000000E3)
        let other = RemoteKeyMapping(source: 0x700000039, destination: 0x700000004)
        hid.mappings = [1: [external, other]]
        try journal([hid.fn], original: [], directory: directory)
        XCTAssertTrue(hid.run(directory: directory))
        XCTAssertEqual(Set(hid.mappings[1]!), Set([external, other]))
    }

    func testFailedReadbackRetainsJournalForNextLaunch() throws {
        let hid = HID()
        let directory = try temporaryDirectory()
        hid.mappings = [1: [.init(source: hid.fn, destination: 0)]]
        hid.ignoreWrites = true
        try journal([hid.fn], original: [], directory: directory)
        XCTAssertFalse(hid.run(directory: directory))
        XCTAssertEqual(hid.writes.count, 4)
        let remaining = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("shortcut-function-restore.json"))) as? [Any]
        XCTAssertEqual(remaining?.count, 1)
    }
}
