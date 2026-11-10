import Foundation

/// Each occurrence owns its lifetime; equal text never shares a dismissal timer.
struct ActionNotice: Identifiable, Equatable {
    enum Level: Equatable {
        case success, information, warning, error

        var dismissalDelay: TimeInterval? {
            switch self {
            case .success: 3
            case .information: 5
            case .warning, .error: nil
            }
        }

        var title: String {
            switch self {
            case .success: "操作完成"
            case .information: "提示"
            case .warning: "需要处理"
            case .error: "操作失败"
            }
        }

        var symbol: String {
            switch self {
            case .success: "checkmark.circle.fill"
            case .information: "info.circle.fill"
            case .warning: "exclamationmark.triangle.fill"
            case .error: "exclamationmark.circle.fill"
            }
        }
    }

    enum RecoveryAction: Equatable {
        case permissions, connection, configuration, macros, loginItems

        var title: String {
            switch self {
            case .permissions: "打开设置 → 权限"
            case .connection: "检查接收设备与麦克风组件"
            case .configuration: "打开配置导入与导出"
            case .macros: "检查组合动作"
            case .loginItems: "打开系统登录项设置"
            }
        }
    }

    enum Source: Equatable {
        case configurationImport, configurationExport, configurationRecovery, configurationDeletion
        case audioOutput, testTone, voiceConnection, voicePermissions, microphoneUpdate
    }

    struct NavigationRequest {
        let id = UUID()
        let action: RecoveryAction
    }

    let id = UUID()
    let level: Level
    let message: String
    let recoveryAction: RecoveryAction?
    let source: Source?
}
