import Foundation

/// A fixed catalog of filter labels, independent of configured or active Harnesses.
struct MacroTag: Identifiable, Equatable {
    let id: String
    let name: String

    static let general = Self(id: "general", name: "通用")
    static let all = [general] + HarnessConfiguration.defaults.map { Self(id: $0.id, name: $0.name) }
}
