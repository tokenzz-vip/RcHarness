import Foundation

/// A read-only presence snapshot, independent of which remote owns input.
enum RemoteHIDPresence {
    struct Device {
        var vendorID: Int?
        var productID: Int?
        var name: String?
        var modelNumber: String?
        var physicalID: String
    }

    static func connectedProfiles(devices: [Device], profiles: [RemoteProfile], confirmedModelNumber: String?) -> Set<String> {
        var connected: Set<String> = []
        for device in devices {
            let candidates = Set(devices.filter {
                $0.vendorID == device.vendorID && $0.productID == device.productID
            }.map(\.physicalID))
            let model = device.modelNumber?.trimmingCharacters(in: .controlCharacters.union(.whitespacesAndNewlines))
            let resolvedModel = model.flatMap { $0.isEmpty ? nil : $0 }
                ?? (candidates.count == 1 ? confirmedModelNumber : nil)
            for profile in profiles where profile.matchesHID(vendorID: device.vendorID, productID: device.productID,
                                                            name: device.name, modelNumber: resolvedModel) {
                connected.insert(profile.id)
            }
        }
        return connected
    }
}
