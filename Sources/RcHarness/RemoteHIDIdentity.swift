import Foundation
import IOKit

/// macOS caches Device Information on the physical HID provider. Event
/// services inherit it through their IOService parents; hidutil list omits it.
enum RemoteHIDIdentity {
    static func modelNumber(registryID: UInt64) -> String? {
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(registryID))
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        return modelNumber(entry: entry)
    }

    static func modelNumber(entry: io_registry_entry_t) -> String? {
        guard entry != 0 else { return nil }
        return IORegistryEntrySearchCFProperty(
            entry, kIOServicePlane, "ModelNumber" as CFString, kCFAllocatorDefault,
            IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
        ) as? String
    }
}
