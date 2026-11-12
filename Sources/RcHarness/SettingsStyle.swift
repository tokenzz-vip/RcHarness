import SwiftUI

/// Shared semantic styles for settings pages and their custom editors.
/// Native control metrics, artwork calibration and scaled diagrams own their geometry;
/// these values describe repeated layout roles, not a mandatory grid for every number.
enum SettingsStyle {
    static let sidebarWidth: CGFloat = 108
    static let pageHeaderHeight: CGFloat = 94
    static let pagePadding: CGFloat = 24
    static let panelPadding: CGFloat = 20
    static let controlPadding: CGFloat = 12
    static let compactControlPadding: CGFloat = 8
    static let panelRadius: CGFloat = 16
    static let controlRadius: CGFloat = 8
    static let panelInsets = EdgeInsets(top: panelPadding, leading: panelPadding,
                                       bottom: panelPadding, trailing: panelPadding)

    /// Gaps between related elements, control groups, panels and page sections.
    enum Spacing {
        static let inline: CGFloat = 8
        static let controls: CGFloat = 12
        static let groups: CGFloat = 16
        static let sections: CGFloat = 24
    }

    enum Typography {
        static let pageTitle = Font.system(size: 24, weight: .semibold)
        static let panelTitle = Font.system(size: 15, weight: .semibold)
        static let dialogTitle = Font.system(size: 18, weight: .semibold)
        static let body = Font.system(size: 12)
        static let caption = Font.system(size: 11)
    }

    static let subtle = Color.primary.opacity(0.035)
    static let switchOn = Color.blue
    static var inactiveSwitchOn: Color {
        Color(nsColor: NSColor.systemBlue.blended(withFraction: 0.45, of: .systemGray) ?? .systemBlue)
    }
    static let switchOff = Color.primary.opacity(0.16)
    // Stronger contrast for the actionable cells inside mapping cards.
    static func mappingTriggerBackground(in colorScheme: ColorScheme, configured: Bool = true) -> Color {
        Color.primary.opacity(configured ? (colorScheme == .dark ? 0.12 : 0.115) : 0.035)
    }
    static func mappingTriggerLabel(in colorScheme: ColorScheme) -> Color {
        Color(white: colorScheme == .dark ? 0.72 : 112.0 / 255)
    }
    /// Shared by the window and the SwiftUI root so the two never disagree.
    static let minimumWindowSize = CGSize(width: 1020, height: 772)
}

