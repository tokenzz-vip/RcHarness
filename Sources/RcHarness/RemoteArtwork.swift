import AppKit
import SwiftUI

enum RemoteArtwork: Hashable {
    case xiaomi2, xiaomi2Pro, chromecast

    var assetName: String {
        switch self {
        case .xiaomi2: "controller-dashboard-xiaomi-rc001.png"
        case .xiaomi2Pro: "controller-dashboard-xiaomi-remote.png"
        case .chromecast: "controller-dashboard-google-g9n9n.png"
        }
    }

    var isXiaomi: Bool { self == .xiaomi2 || self == .xiaomi2Pro }
}

struct RemoteArtworkView: View {
    let pressedInputs: Set<ControllerInput>
    let connected: Bool
    var highlightedInput: ControllerInput? = nil
    var onHoverInput: ((ControllerInput?) -> Void)? = nil
    var onSelectInput: ((ControllerInput) -> Void)? = nil
    var profile: RemoteProfile = RemoteProfiles.xiaomiRC003

    /// Positions are expressed in the same unit square used by the artwork.
    /// Live press feedback is centred on the corresponding control.
    static let markerPositions: [ControllerInput: CGPoint] = [
        // Calibrated against controller-dashboard-xiaomi-remote.png (260 ×
        // 1025), so the overlay stays centred when the artwork is resized.
        .power: CGPoint(x: 0.240, y: 0.070),
        .options: CGPoint(x: 0.760, y: 0.070),
        .buttonA: CGPoint(x: 0.498, y: 0.226),
        .dpadUp: CGPoint(x: 0.50, y: 0.15),
        .dpadDown: CGPoint(x: 0.50, y: 0.31),
        .dpadLeft: CGPoint(x: 0.20, y: 0.235),
        .dpadRight: CGPoint(x: 0.80, y: 0.235),
        // These controls sit above the lower half of the source artwork. Keep
        // the markers on the button centres so a pressed key does not appear
        // to float into the blank body of the remote.
        .buttonB: CGPoint(x: 0.291, y: 0.383),
        .rightShoulder: CGPoint(x: 0.705, y: 0.383),
        .home: CGPoint(x: 0.291, y: 0.478),
        .leftShoulder: CGPoint(x: 0.705, y: 0.478),
        .menu: CGPoint(x: 0.291, y: 0.574),
        .buttonY: CGPoint(x: 0.705, y: 0.574),
    ]

    /// Arrow tips sit inside the buttons, beside the symbols. They are
    /// separate from press centres so the artwork remains unobstructed.
    static let connectorPositions: [ControllerInput: CGPoint] = [
        .power: CGPoint(x: 0.175, y: 0.070),
        .options: CGPoint(x: 0.825, y: 0.070),
        .buttonA: CGPoint(x: 0.610, y: 0.200),
        .dpadUp: CGPoint(x: 0.480, y: 0.150),
        .dpadDown: CGPoint(x: 0.520, y: 0.310),
        .dpadLeft: CGPoint(x: 0.210, y: 0.235),
        .dpadRight: CGPoint(x: 0.790, y: 0.235),
        .buttonB: CGPoint(x: 0.205, y: 0.383),
        .rightShoulder: CGPoint(x: 0.800, y: 0.383),
        .home: CGPoint(x: 0.200, y: 0.478),
        .leftShoulder: CGPoint(x: 0.800, y: 0.478),
        .menu: CGPoint(x: 0.200, y: 0.574),
        .buttonY: CGPoint(x: 0.800, y: 0.574),
    ]

    static func markerPositions(for artwork: RemoteArtwork) -> [ControllerInput: CGPoint] {
        if artwork == .xiaomi2 {
            // Xiaomi Youpin RC001 front photo, cropped to 249 × 984.
            return [
                .power: CGPoint(x: 0.261, y: 0.071), .options: CGPoint(x: 0.735, y: 0.071),
                .buttonA: CGPoint(x: 0.502, y: 0.234),
                .dpadUp: CGPoint(x: 0.502, y: 0.153), .dpadDown: CGPoint(x: 0.502, y: 0.315),
                .dpadLeft: CGPoint(x: 0.207, y: 0.234), .dpadRight: CGPoint(x: 0.797, y: 0.234),
                .buttonB: CGPoint(x: 0.293, y: 0.392), .home: CGPoint(x: 0.293, y: 0.486),
                .menu: CGPoint(x: 0.293, y: 0.579), .rightShoulder: CGPoint(x: 0.703, y: 0.392),
                .leftShoulder: CGPoint(x: 0.703, y: 0.486), .buttonY: CGPoint(x: 0.703, y: 0.579),
            ]
        }
        guard artwork == .chromecast else { return markerPositions }
        // Calibrated to the cropped Google Store Snow product photo (392 × 1333).
        return [
            .buttonA: CGPoint(x: 0.423, y: 0.154),
            .dpadUp: CGPoint(x: 0.423, y: 0.060), .dpadDown: CGPoint(x: 0.423, y: 0.248),
            .dpadLeft: CGPoint(x: 0.155, y: 0.154), .dpadRight: CGPoint(x: 0.691, y: 0.154),
            .buttonB: CGPoint(x: 0.242, y: 0.353), .options: CGPoint(x: 0.638, y: 0.355),
            .home: CGPoint(x: 0.242, y: 0.478), .mute: CGPoint(x: 0.638, y: 0.482),
            .youtube: CGPoint(x: 0.242, y: 0.603), .netflix: CGPoint(x: 0.638, y: 0.608),
            .power: CGPoint(x: 0.245, y: 0.726), .inputSource: CGPoint(x: 0.640, y: 0.728),
            .rightShoulder: CGPoint(x: 0.964, y: 0.233), .leftShoulder: CGPoint(x: 0.964, y: 0.314),
        ]
    }

    static func connectorPositions(for artwork: RemoteArtwork) -> [ControllerInput: CGPoint] {
        if artwork == .xiaomi2 {
            var positions = markerPositions(for: artwork)
            for input: ControllerInput in [.power, .dpadLeft, .buttonB, .home, .menu] {
                positions[input]?.x -= 0.075
            }
            for input: ControllerInput in [.options, .dpadRight, .rightShoulder, .leftShoulder, .buttonY] {
                positions[input]?.x += 0.075
            }
            positions[.buttonA] = CGPoint(x: 0.610, y: 0.208)
            positions[.dpadUp]?.x -= 0.02
            positions[.dpadDown]?.x += 0.02
            return positions
        }
        guard artwork == .chromecast else { return connectorPositions }
        var positions = markerPositions(for: artwork)
        // Land beside each printed icon, keeping the product photo readable.
        for input: ControllerInput in [.buttonB, .home, .youtube, .power] {
            positions[input]?.x -= 0.065
        }
        for input: ControllerInput in [.options, .mute, .netflix, .buttonA] {
            positions[input]?.x += 0.065
        }
        positions[.inputSource]?.x += 0.055
        positions[.buttonA]?.y = 0.128
        return positions
    }

    /// Trace the physical button rather than adding a marker around its icon.
    /// Directional inputs highlight only their quarter of the navigation ring.
    static func controlOutline(for input: ControllerInput, in bounds: CGRect, artwork: RemoteArtwork = .xiaomi2Pro) -> Path {
        let positions = markerPositions(for: artwork)
        guard let centre = positions[input] else { return Path() }
        let point = CGPoint(x: bounds.minX + centre.x * bounds.width,
                            y: bounds.minY + centre.y * bounds.height)
        let angle: Double?
        switch input {
        case .dpadUp: angle = -90
        case .dpadRight: angle = 0
        case .dpadDown: angle = 90
        case .dpadLeft: angle = 180
        default: angle = nil
        }
        if let angle {
            let navigation = positions[.buttonA]!
            let origin = CGPoint(x: bounds.minX + navigation.x * bounds.width,
                                 y: bounds.minY + navigation.y * bounds.height)
            if !artwork.isXiaomi {
                // Perspective in the photo makes the navigation ring elliptical.
                var sector = Path()
                sector.addArc(center: .zero, radius: 1,
                              startAngle: .degrees(angle - 42), endAngle: .degrees(angle + 42), clockwise: false)
                sector.addArc(center: .zero, radius: 0.37,
                              startAngle: .degrees(angle + 42), endAngle: .degrees(angle - 42), clockwise: true)
                sector.closeSubpath()
                return sector.applying(CGAffineTransform(a: bounds.width * 0.375, b: 0, c: 0,
                                                        d: bounds.height * 0.135, tx: origin.x, ty: origin.y))
            }
            var sector = Path()
            sector.addArc(center: origin, radius: bounds.width * 0.415,
                          startAngle: .degrees(angle - 42), endAngle: .degrees(angle + 42), clockwise: false)
            sector.addArc(center: origin, radius: bounds.width * 0.225,
                          startAngle: .degrees(angle + 42), endAngle: .degrees(angle - 42), clockwise: true)
            sector.closeSubpath()
            return sector
        }
        if artwork == .chromecast {
            let size: CGSize
            switch input {
            case .leftShoulder, .rightShoulder:
                size = CGSize(width: bounds.width * 0.05, height: bounds.height * 0.078)
            case .power, .inputSource:
                size = CGSize(width: bounds.width * 0.18, height: bounds.height * 0.055)
            case .buttonA:
                size = CGSize(width: bounds.width * 0.26, height: bounds.height * 0.098)
            default:
                size = CGSize(width: bounds.width * 0.27, height: bounds.height * 0.095)
            }
            let rect = CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                              width: size.width, height: size.height)
            if input == .leftShoulder || input == .rightShoulder {
                return Path(roundedRect: rect, cornerRadius: bounds.width * 0.025)
            }
            return Path(ellipseIn: rect)
        }
        let radius: CGFloat
        switch input {
        case .power, .options: radius = bounds.width * (artwork == .xiaomi2 ? 0.125 : 0.110)
        case .buttonA: radius = bounds.width * 0.215
        default: radius = bounds.width * 0.165
        }
        return Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius,
                                     width: radius * 2, height: radius * 2))
    }

    static func highlightedInputs(pressed: Set<ControllerInput>, preview: ControllerInput?) -> Set<ControllerInput> {
        if !pressed.isEmpty { return pressed }
        return preview.map { [$0] } ?? []
    }

    static func artworkAspectRatio(for artwork: RemoteArtwork) -> CGFloat {
        switch artwork {
        case .xiaomi2: 249.0 / 984.0
        case .xiaomi2Pro: 260.0 / 1025.0
        case .chromecast: 392.0 / 1333.0
        }
    }

    static func artworkBounds(in size: CGSize, artwork: RemoteArtwork = .xiaomi2Pro) -> CGRect {
        let aspect = artworkAspectRatio(for: artwork)
        let height = min(size.height, size.width / aspect)
        let width = height * aspect
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2,
                      width: width, height: height)
    }

    static func input(at point: CGPoint, in bounds: CGRect, artwork: RemoteArtwork = .xiaomi2Pro) -> ControllerInput? {
        guard bounds.width > 0, bounds.height > 0, bounds.contains(point) else { return nil }
        return ControllerInput.allCases.first { controlOutline(for: $0, in: bounds, artwork: artwork).contains(point) }
    }

    var body: some View {
        GeometryReader { proxy in
            let bounds = Self.artworkBounds(in: proxy.size, artwork: profile.artwork)
            let highlights = Self.highlightedInputs(
                pressed: pressedInputs, preview: highlightedInput
            )
            ZStack {
                if let image = RemoteDashboardAssets.image(for: profile.artwork) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .opacity(connected ? 1 : 0.45)
                        .frame(width: bounds.width, height: bounds.height)
                } else {
                    Image(systemName: "appletvremote.gen4.fill")
                        .font(.system(size: 100))
                        .foregroundStyle(.secondary)
                }
                ForEach(profile.inputs, id: \.self) { input in
                    let outline = Self.controlOutline(for: input, in: bounds, artwork: profile.artwork)
                    if highlights.contains(input) {
                        let pressed = pressedInputs.contains(input)
                        outline
                            .fill(Color.accentColor.opacity(pressed ? 0.24 : 0.10))
                            .overlay {
                                outline.stroke(Color.accentColor.opacity(pressed ? 1 : 0.9),
                                               lineWidth: pressed ? 2 : 1.25)
                            }
                            .allowsHitTesting(false)
                    }
                    if let onSelectInput {
                        let buttonBounds = outline.boundingRect
                        let shape = outline.offsetBy(dx: -buttonBounds.minX, dy: -buttonBounds.minY)
                        Button { onSelectInput(input) } label: {
                            shape.fill(.clear).contentShape(shape)
                        }
                        .buttonStyle(.plain)
                        .frame(width: buttonBounds.width, height: buttonBounds.height)
                        .position(x: buttonBounds.midX, y: buttonBounds.midY)
                        .help("点击编辑\(input.label)")
                        .accessibilityLabel(input.label)
                        .accessibilityHint("编辑此按键的动作")
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): onHoverInput?(Self.input(at: point, in: bounds, artwork: profile.artwork))
                case .ended: onHoverInput?(nil)
                }
            }
            .onDisappear { onHoverInput?(nil) }
        }
    }
}

private enum RemoteDashboardAssets {
    private static let images: [RemoteArtwork: NSImage] = {
        var images: [RemoteArtwork: NSImage] = [:]
        for artwork: RemoteArtwork in [.xiaomi2, .xiaomi2Pro, .chromecast] {
            images[artwork] = load(artwork.assetName)
        }
        return images
    }()

    static func image(for artwork: RemoteArtwork) -> NSImage? {
        images[artwork]
    }

    private static func load(_ name: String) -> NSImage? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent(name) else { return nil }
        return NSImage(contentsOf: url)
    }
}
