import os

/// Unified logging. GUI processes have no useful stdout, so everything goes
/// through os.Logger (visible in Console.app / `log stream --predicate
/// 'subsystem == "vip.tokenzz.rcharness"'`). Voice metadata additionally goes
/// to the bounded file in AudioDiagnostics.
enum Log {
    private static let subsystem = "vip.tokenzz.rcharness"
    static let app = Logger(subsystem: subsystem, category: "app")
    static let hid = Logger(subsystem: subsystem, category: "hid")
    static let suppression = Logger(subsystem: subsystem, category: "suppression")
    static let settings = Logger(subsystem: subsystem, category: "settings")
    static let switcher = Logger(subsystem: subsystem, category: "switcher")
    static let audio = Logger(subsystem: subsystem, category: "audio")
}
