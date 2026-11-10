/// Shared guidance for the receiver path, independent of the system default input.
enum VoiceSetupGuidance {
    static let selectReceiver = "在目标语音应用的麦克风设置中，选择上方接收设备。"
    static let checkInputLevel = "发送测试音时，在目标语音应用的麦克风设置中查看输入电平；无需从扬声器听到声音。"
    static let systemDefault = "仅当目标应用使用系统默认输入时，才需要在系统声音设置中选择同一设备。"
    static let permissions = "语音按键需要输入监控和辅助功能权限，请在「设置 → 权限」中开启。"

    static func installationComplete(receiverName: String?) -> String {
        let receiver = receiverName.map { "当前接收设备：\($0)。\n\n" } ?? ""
        return receiver + "在「连接与语音」确认接收设备，再到目标语音应用的麦克风设置中选择同一设备。\n\n" + checkInputLevel
    }
}
