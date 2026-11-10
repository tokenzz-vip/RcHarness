import AppKit
import XCTest
@testable import RcHarness

@MainActor
final class RemoteProfileMenuTests: XCTestCase {
    func testPresenceDistinguishesBothXiaomiModelsAndInactiveChromecast() {
        let remote2 = RemoteProfiles.xiaomiRC001
        let pro = RemoteProfiles.xiaomiRC003
        let chromecast = RemoteProfiles.googleG9N9N
        func device(_ profile: RemoteProfile, physicalID: String) -> RemoteHIDPresence.Device {
            .init(vendorID: profile.vendorID, productID: profile.productID, modelNumber: profile.model,
                  physicalID: physicalID)
        }
        let devices = [device(remote2, physicalID: "a"), device(pro, physicalID: "b"),
                       device(chromecast, physicalID: "c")]
        XCTAssertEqual(RemoteHIDPresence.connectedProfiles(devices: devices, profiles: RemoteProfiles.all,
                                                         confirmedModelNumber: nil), Set(RemoteProfiles.all.map(\.id)))
        XCTAssertEqual(RemoteHIDPresence.connectedProfiles(devices: [devices[0]], profiles: RemoteProfiles.all,
                                                         confirmedModelNumber: nil), [remote2.id])
        XCTAssertTrue(RemoteHIDPresence.connectedProfiles(devices: [], profiles: RemoteProfiles.all,
                                                        confirmedModelNumber: pro.model).isEmpty)
    }

    func testAmbiguousSharedHardwareNeverMarksBothXiaomiModelsConnected() {
        let pro = RemoteProfiles.xiaomiRC003
        let first = RemoteHIDPresence.Device(vendorID: pro.vendorID, productID: pro.productID, physicalID: "a")
        let second = RemoteHIDPresence.Device(vendorID: pro.vendorID, productID: pro.productID, physicalID: "b")
        XCTAssertTrue(RemoteHIDPresence.connectedProfiles(devices: [first], profiles: RemoteProfiles.all,
                                                        confirmedModelNumber: nil).isEmpty)
        XCTAssertEqual(RemoteHIDPresence.connectedProfiles(devices: [first, first], profiles: RemoteProfiles.all,
                                                         confirmedModelNumber: pro.model), [pro.id])
        XCTAssertTrue(RemoteHIDPresence.connectedProfiles(devices: [first, second], profiles: RemoteProfiles.all,
                                                        confirmedModelNumber: pro.model).isEmpty)
    }

    func testBlankHIDModelUsesBLEConfirmationOnlyForOnePhysicalDevice() {
        let pro = RemoteProfiles.xiaomiRC003
        for model in [nil, "", " \n\t\0"] as [String?] {
            let device = RemoteHIDPresence.Device(vendorID: pro.vendorID, productID: pro.productID,
                                                 modelNumber: model, physicalID: "a")
            XCTAssertEqual(RemoteHIDPresence.connectedProfiles(devices: [device, device], profiles: RemoteProfiles.all,
                                                             confirmedModelNumber: pro.model), [pro.id])
            var another = device
            another.physicalID = "b"
            XCTAssertTrue(RemoteHIDPresence.connectedProfiles(devices: [device, another], profiles: RemoteProfiles.all,
                                                            confirmedModelNumber: pro.model).isEmpty)
        }
    }

    func testUnknownSecondDeviceCannotBorrowAKnownDevicesModel() {
        let pro = RemoteProfiles.xiaomiRC003
        let known = RemoteHIDPresence.Device(vendorID: pro.vendorID, productID: pro.productID,
                                            modelNumber: " \n" + pro.model + "\0", physicalID: "a")
        let unknown = RemoteHIDPresence.Device(vendorID: pro.vendorID, productID: pro.productID, physicalID: "b")
        XCTAssertEqual(RemoteHIDPresence.connectedProfiles(devices: [known, unknown], profiles: RemoteProfiles.all,
                                                         confirmedModelNumber: RemoteProfiles.xiaomiRC001.model), [pro.id])
        XCTAssertTrue(RemoteHIDPresence.connectedProfiles(devices: [unknown], profiles: RemoteProfiles.all,
                                                        confirmedModelNumber: nil).isEmpty)
    }

    func testMenuPreservesSelectionAndColorsEachModelsConnectionStatus() throws {
        let suite = "RcHarness.RemoteMenuTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        model.setConnected(true)
        model.setConnectedRemoteProfiles([RemoteProfiles.googleG9N9N.id])
        let menu = RemoteProfileMenuContent.make(model: model, target: nil, action: nil)
        XCTAssertEqual(menu.items.count, RemoteProfiles.all.count)
        for (item, profile) in zip(menu.items, model.availableRemoteProfiles) {
            let selected = profile.id == model.remoteProfile.id
            let connected = selected || profile.id == RemoteProfiles.googleG9N9N.id
            XCTAssertEqual(item.state, selected ? .on : .off)
            XCTAssertEqual(item.isEnabled, !selected)
            XCTAssertEqual(item.representedObject as? String, profile.id)
            XCTAssertEqual(item.toolTip, connected ? "已连接" : "未连接")
            let title = try XCTUnwrap(item.attributedTitle)
            XCTAssertTrue(title.string.hasSuffix("\t●"))
            XCTAssertEqual(title.attribute(.foregroundColor, at: title.length - 1, effectiveRange: nil) as? NSColor,
                           connected ? .systemGreen : .systemGray)
        }
        model.setConnected(false)
        model.setConnectedRemoteProfiles([])
        XCTAssertFalse(model.availableRemoteProfiles.contains { model.isRemoteConnected($0) })
    }
}
