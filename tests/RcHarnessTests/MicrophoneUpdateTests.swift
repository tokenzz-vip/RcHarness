import XCTest
@testable import RcHarness

final class MicrophoneUpdateTests: XCTestCase {
    func testOnlyInstalledOlderOrUnreadableDriversNeedUpdating() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundled = root.appendingPathComponent("bundled.driver")
        let installed = root.appendingPathComponent("installed.driver")
        try writeVersion("10", to: bundled)
        XCTAssertFalse(RemoteMicrophoneInstallation.updateRequired(bundledDriver: bundled, installedDriver: installed),
                       "Updating the app must not install a component the user has not installed")
        try writeVersion("9", to: installed)
        XCTAssertTrue(RemoteMicrophoneInstallation.updateRequired(bundledDriver: bundled, installedDriver: installed))
        try writeVersion("10", to: installed)
        XCTAssertFalse(RemoteMicrophoneInstallation.updateRequired(bundledDriver: bundled, installedDriver: installed))
        try writeVersion("11", to: installed)
        XCTAssertFalse(RemoteMicrophoneInstallation.updateRequired(bundledDriver: bundled, installedDriver: installed),
                       "Launching an older app must not downgrade the installed driver")
        try Data("invalid".utf8).write(to: installed.appendingPathComponent("Contents/Info.plist"))
        XCTAssertTrue(RemoteMicrophoneInstallation.updateRequired(bundledDriver: bundled, installedDriver: installed))
        try FileManager.default.removeItem(at: bundled)
        XCTAssertFalse(RemoteMicrophoneInstallation.updateRequired(bundledDriver: bundled, installedDriver: installed))
    }

    private func writeVersion(_ version: String, to driver: URL) throws {
        let contents = driver.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: ["CFBundleVersion": version], format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
    }
}
