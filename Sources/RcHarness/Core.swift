import Foundation
import CoreGraphics

enum RemoteAdapter: Equatable {
    case xiaomi, chromecast

    var usesATVVVoiceButton: Bool { self != .xiaomi }
}

enum RemoteValidation: String {
    case voiceVerified = "语音已实测"
    case awaitingHardware = "待真机验收"
}

/// Hardware-specific identity lives in a profile so additional Bluetooth/HID
/// remotes can be added without changing the common mapping layer. HID
/// discovery, native-key suppression and BLE voice all match through it.
struct RemoteProfile: Identifiable, Equatable {
    let id: String
    let displayName: String
    /// Short name shown in the dashboard.
    let shortName: String
    let model: String
    /// Fixed, visible part of every key scheme name for this remote.
    let keyProfilePrefix: String
    let vendorID: Int?
    let productID: Int?
    /// BLE Device Information model numbers accepted for the voice service.
    /// Empty when the remote has no BLE microphone.
    let voiceModelNumbers: Set<String>
    /// Whether this adapter permits voice sessions that outlive the key release.
    let supportsVoiceTap: Bool
    /// Normalized (trimmed, lowercased) Bluetooth names matched exactly.
    let bluetoothNames: Set<String>
    /// Normalized name fragments matched as substrings.
    let bluetoothNameFragments: [String]
    /// Physical inputs supported by this remote, also used to size usage rankings.
    let inputs: [ControllerInput]
    var adapter: RemoteAdapter = .xiaomi
    /// Exact IOHID Product strings for models whose VID/PID is not yet captured.
    var hidProductNames: [String] = []
    /// Physical appearance is independent of the shared HID/voice adapter.
    var artwork: RemoteArtwork = .xiaomi2Pro
    var validation: RemoteValidation = .awaitingHardware
    /// PnP vendor namespaces observed for this model's exact VID/PID.
    var voicePnPVendorIDSources: Set<UInt8> = [2]

    var selectionName: String {
        validation == .voiceVerified ? shortName : shortName + "（" + validation.rawValue + "）"
    }
    var hidMatching: [[String: Any]] {
        if let vendorID, let productID {
            return [["VendorID": vendorID, "ProductID": productID]]
        }
        return hidProductNames.map { ["Product": $0] }
    }

    /// Shared VID/PIDs identify candidates, not a specific model. Confirm those
    /// through Device Information before enabling HID input; native-key
    /// suppression may begin earlier to prevent a mismatched voice key leak.
    var requiresHIDModelConfirmation: Bool {
        guard let vendorID, let productID else { return false }
        return RemoteProfiles.all.contains {
            $0.id != id && $0.vendorID == vendorID && $0.productID == productID
        }
    }

    func matchesHID(vendorID: Int?, productID: Int?, name: String?, modelNumber: String? = nil) -> Bool {
        if let vendor = self.vendorID, let product = self.productID {
            return vendorID == vendor && productID == product
                && (!requiresHIDModelConfirmation || acceptsVoiceModel(modelNumber))
        }
        return name.map { hidProductNames.contains($0) } ?? false
    }

    /// BLE confirms the selected model; each HID device must also belong to
    /// that model. Older systems without a device model can only fall back to
    /// BLE confirmation when there is a single physical candidate.
    func matchesHIDDevice(vendorID: Int?, productID: Int?, name: String?,
                          confirmedModelNumber: String?, deviceModelNumber: String?, isOnlyCandidate: Bool) -> Bool {
        guard !requiresHIDModelConfirmation || acceptsVoiceModel(confirmedModelNumber) else { return false }
        let deviceModel = deviceModelNumber?.trimmingCharacters(in: .controlCharacters.union(.whitespacesAndNewlines))
        let model = deviceModel.flatMap { $0.isEmpty ? nil : $0 } ?? (isOnlyCandidate ? confirmedModelNumber : nil)
        return matchesHID(vendorID: vendorID, productID: productID, name: name, modelNumber: model)
    }

    var supportsBLEVoice: Bool { !voiceModelNumbers.isEmpty }
    var supportsVoicePnPIdentity: Bool { adapter == .chromecast && vendorID != nil && productID != nil }

    func matchesBluetoothName(_ name: String?) -> Bool {
        guard let name else { return false }
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return bluetoothNames.contains(normalized) || bluetoothNameFragments.contains { normalized.contains($0) }
    }

    func acceptsVoiceModel(_ model: String?) -> Bool {
        guard let model else { return false }
        return voiceModelNumbers.contains(model)
    }

    /// The Chromecast's model string varies by firmware. Its standard BLE PnP
    /// identity uses the same VID/PID as HID. Firmware 26.2 reports these
    /// identifiers with vendor source 1; retain source 2 compatibility as well.
    func acceptsVoicePnPID(_ data: Data) -> Bool {
        let bytes = Array(data)
        guard supportsVoicePnPIdentity, let vendorID, let productID,
              bytes.count == 7, voicePnPVendorIDSources.contains(bytes[0]) else { return false }
        return Int(bytes[1]) | Int(bytes[2]) << 8 == vendorID
            && Int(bytes[3]) | Int(bytes[4]) << 8 == productID
    }
}

enum RemoteProfiles {
    /// Xiaomi Bluetooth Remote 2 (RC001-MS). RC001 and RC003 share the same
    /// HID identity and ATVV v1 transport; the Device Information model keeps
    /// the two products distinct during the BLE handshake.
    static let xiaomiRC001 = RemoteProfile(
        id: "xiaomi-rc001",
        displayName: "Xiaomi Bluetooth Remote 2 (RC001-MS)",
        shortName: "小米蓝牙遥控器 2",
        model: "RC001-MS",
        keyProfilePrefix: "RC1-",
        vendorID: 0x2717,
        productID: 0x32B8,
        voiceModelNumbers: ["RC001", "RC001-MS"],
        supportsVoiceTap: false,
        bluetoothNames: ["mi rc", "xiaomi bluetooth remote 2", "小米蓝牙语音遥控器", "小米蓝牙遥控器2"],
        bluetoothNameFragments: ["xiaomi bluetooth remote 2", "小米蓝牙遥控器"],
        inputs: [.buttonA, .buttonB, .buttonY, .options, .menu, .home, .power,
                 .dpadUp, .dpadDown, .dpadLeft, .dpadRight, .leftShoulder, .rightShoulder],
        artwork: .xiaomi2,
        validation: .voiceVerified
    )

    static let xiaomiRC003 = RemoteProfile(
        id: "xiaomi-rc003-ms",
        displayName: "Xiaomi Bluetooth Remote 2 Pro (RC003-MS)",
        shortName: "小米蓝牙遥控器 2 Pro",
        model: "RC003-MS",
        keyProfilePrefix: "RC3-",
        vendorID: 0x2717,
        productID: 0x32B8,
        voiceModelNumbers: ["RC003", "RC003-MS"],
        supportsVoiceTap: false,
        bluetoothNames: ["mi rc", "小米蓝牙语音遥控器", "xiaomi bluetooth voice remote"],
        bluetoothNameFragments: ["xiaomi bluetooth remote 2", "小米蓝牙遥控器"],
        inputs: [.buttonA, .buttonB, .buttonY, .options, .menu, .home, .power,
                 .dpadUp, .dpadDown, .dpadLeft, .dpadRight, .leftShoulder, .rightShoulder],
        validation: .voiceVerified
    )

    static let googleG9N9N = RemoteProfile(
        id: "google-g9n9n", displayName: "Google Chromecast Voice Remote (G9N9N)",
        shortName: "Chromecast 遥控器", model: "G9N9N",
        keyProfilePrefix: "G9N-",
        vendorID: 0x18D1, productID: 0x9450,
        voiceModelNumbers: ["G9N9N"], supportsVoiceTap: false,
        bluetoothNames: ["chromecast remote", "chromecast voice remote", "g9n9n"],
        bluetoothNameFragments: [],
        inputs: [.buttonA, .buttonB, .options, .home, .power,
                 .dpadUp, .dpadDown, .dpadLeft, .dpadRight, .leftShoulder, .rightShoulder,
                 .mute, .inputSource, .youtube, .netflix],
        adapter: .chromecast,
        artwork: .chromecast,
        validation: .voiceVerified,
        voicePnPVendorIDSources: [1, 2]
    )

    static let all: [RemoteProfile] = [xiaomiRC001, xiaomiRC003, googleG9N9N]
}

enum ControllerInput: String, Hashable, CaseIterable, Codable {
    case buttonA, buttonB, buttonY, options, menu, home, power
    case dpadUp, dpadDown, dpadLeft, dpadRight
    case leftShoulder, rightShoulder
    case mute, inputSource, youtube, netflix

    var label: String {
        switch self {
        case .power: "电源键"
        case .buttonA: "确认 OK"
        case .buttonB: "返回"
        case .buttonY: "自定义键"
        case .options: "语音键"
        case .menu: "菜单"
        case .home: "主页"
        case .dpadUp: "上"
        case .dpadDown: "下"
        case .dpadLeft: "左"
        case .dpadRight: "右"
        case .leftShoulder: "音量 −"
        case .rightShoulder: "音量 +"
        case .mute: "静音"
        case .inputSource: "输入源"
        case .youtube: "YouTube"
        case .netflix: "Netflix"
        }
    }

    /// SF Symbol shown for this input in the dashboard.
    var symbol: String {
        switch self {
        case .power: "power"
        case .buttonA: "circle.inset.filled"
        case .buttonB: "arrow.uturn.backward"
        case .buttonY: "tv"
        case .options: "mic"
        case .menu: "line.3.horizontal"
        case .home: "house"
        case .dpadUp: "chevron.up"
        case .dpadDown: "chevron.down"
        case .dpadLeft: "chevron.left"
        case .dpadRight: "chevron.right"
        case .leftShoulder: "speaker.minus"
        case .rightShoulder: "speaker.plus"
        case .mute: "speaker.slash"
        case .inputSource: "rectangle.on.rectangle"
        case .youtube: "play.rectangle"
        case .netflix: "film"
        }
    }
}

enum ControllerOperationMode: Hashable { case mapping, native }

enum RemoteAction: String, CaseIterable, Codable, Identifiable, Hashable {
    case enter, backspace, escape, arrowUp, arrowDown, arrowLeft, arrowRight
    // Preserve the stored value used by existing mappings and backups.
    case switchToNativeMode = "toggleMode"
    case rightCommand, screenshot, copy, paste, browserBack, browserForward
    case mouseLeft, mouseRight, pointerUp, pointerDown, pointerLeft, pointerRight
    case scrollUp, scrollDown, volumeUp, volumeDown, recordedShortcut, openApplication, disabled
    case leftCommand, fn, leftOption, rightOption, playPause, mute, phrase, macro
    case openHarnessSwitcher

    static let voiceTriggerActions: [Self] = [.fn, .leftCommand, .rightCommand, .leftOption, .rightOption]

    var id: String { rawValue }
    var label: String {
        switch self {
        case .enter: "Enter"
        case .backspace: "Backspace"
        case .escape: "Escape"
        case .arrowUp: "方向键 ↑"
        case .arrowDown: "方向键 ↓"
        case .arrowLeft: "方向键 ←"
        case .arrowRight: "方向键 →"
        case .switchToNativeMode: "切换到原生模式"
        case .rightCommand: "按住右侧 Command"
        case .screenshot: "系统区域截图 (⌘⇧4)"
        case .copy: "复制 (⌘C)"
        case .paste: "粘贴 (⌘V)"
        case .browserBack: "浏览器后退 (⌘[)"
        case .browserForward: "浏览器前进 (⌘])"
        case .mouseLeft: "鼠标左键"
        case .mouseRight: "鼠标右键"
        case .pointerUp: "移动指针 ↑"
        case .pointerDown: "移动指针 ↓"
        case .pointerLeft: "移动指针 ←"
        case .pointerRight: "移动指针 →"
        case .scrollUp: "向上滚动"
        case .scrollDown: "向下滚动"
        case .volumeUp: "系统音量 +"
        case .volumeDown: "系统音量 −"
        case .recordedShortcut: "录制的快捷键"
        case .openApplication: "打开应用"
        case .disabled: "禁用"
        case .leftCommand: "按住左侧 Command"
        case .fn: "按住 Fn / 地球键"
        case .leftOption: "按住左侧 Option"
        case .rightOption: "按住右侧 Option"
        case .playPause: "播放 / 暂停"
        case .mute: "系统静音"
        case .phrase: "输入常用语"
        case .macro: "执行组合动作"
        case .openHarnessSwitcher: "打开运行 Harness 列表"
        }
    }
}

/// A keyboard shortcut recorded in the mapping editor. Named to avoid
/// confusion with SwiftUI.KeyboardShortcut; the JSON shape is unchanged.
struct RecordedShortcut: Codable, Equatable, Hashable {
    let keyCode: UInt16
    let modifiers: UInt64
    let label: String

    static let voiceHoldDefault = RecordedShortcut(keyCode: VirtualKey.function, modifiers: CGEventFlags.maskSecondaryFn.rawValue, label: "Fn / 地球键")
    static let voiceTapDefault = RecordedShortcut(keyCode: 0x31, modifiers: CGEventFlags.maskSecondaryFn.rawValue, label: "Fn + Space")
}

struct ButtonMapping: Codable, Equatable {
    var action: RemoteAction
    var shortcut: RecordedShortcut?
    var applicationPath: String?
    var referenceID: String?

    /// Legacy modifier actions remain readable while new voice bindings store
    /// a recorded shortcut directly.
    var shortcutForVoice: RecordedShortcut? {
        switch action {
        case .recordedShortcut: return shortcut
        case .fn: return .voiceHoldDefault
        case .leftCommand: return RecordedShortcut(keyCode: 0x37, modifiers: 0x00100008, label: "左侧 Command")
        case .rightCommand: return RecordedShortcut(keyCode: 0x36, modifiers: 0x00100010, label: "右侧 Command")
        case .leftOption: return RecordedShortcut(keyCode: 0x3A, modifiers: 0x00080020, label: "左侧 Option")
        case .rightOption: return RecordedShortcut(keyCode: 0x3D, modifiers: 0x00080040, label: "右侧 Option")
        default: return nil
        }
    }
}

struct RemoteMapping: Codable, Equatable {
    var buttons: [String: ButtonMapping]

    subscript(_ input: ControllerInput) -> ButtonMapping {
        get { buttons[input.rawValue] ?? ButtonMapping(action: .disabled) }
        set { buttons[input.rawValue] = newValue }
    }

    static var defaults: RemoteMapping {
        var result = RemoteMapping(buttons: [:])
        let actions: [ControllerInput: RemoteAction] = [
            .buttonA: .enter, .buttonB: .backspace, .menu: .switchToNativeMode,
            .options: .rightCommand, .home: .escape,
            .dpadUp: .arrowUp, .dpadDown: .arrowDown,
            .dpadLeft: .arrowLeft, .dpadRight: .arrowRight,
            .leftShoulder: .volumeDown, .rightShoulder: .volumeUp,
            .buttonY: .screenshot,
            .mute: .mute, .inputSource: .switchToNativeMode,
            .youtube: .copy, .netflix: .paste,
        ]
        for (input, action) in actions { result[input] = ButtonMapping(action: action) }
        return result
    }

    /// Mapping saved by versions that predate key profiles, used only as the
    /// first default profile when no profile has been saved yet.
    static func legacy(profileID: String, defaults: UserDefaults = .standard) -> RemoteMapping? {
        SettingsStorage.load(RemoteMapping.self, SettingsKeys.Stored.legacyMapping(profileID: profileID), defaults: defaults)
    }
}
