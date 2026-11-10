import XCTest
@testable import RcHarness

@MainActor
final class RemoteArtworkTests: XCTestCase {
    func testXiaomiModelsSelectDistinctPackagedArtwork() throws {
        let standard = RemoteProfiles.xiaomiRC001
        let pro = RemoteProfiles.xiaomiRC003
        XCTAssertEqual(standard.adapter, pro.adapter)
        XCTAssertNotEqual(standard.artwork, pro.artwork)
        XCTAssertNotEqual(standard.artwork.assetName, pro.artwork.assetName)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let buildScript = try String(contentsOf: root.appendingPathComponent("scripts/build_app.sh"))
        let standardData = try Data(contentsOf: root.appendingPathComponent("assets/app/" + standard.artwork.assetName))
        let proData = try Data(contentsOf: root.appendingPathComponent("assets/app/" + pro.artwork.assetName))
        XCTAssertNotEqual(standardData, proData)
        for profile in [standard, pro] {
            XCTAssertTrue(buildScript.contains(profile.artwork.assetName))
        }
    }

    func testGoogleConnectorsFollowPhysicalOrderWithoutOverlappingLeaders() throws {
        for profile in [RemoteProfiles.googleG9N9N] {
            for size in [CGSize(width: 700, height: 468), CGSize(width: 1120, height: 620)] {
                let layout = MappingLayout(size: size, profile: profile)
                let positions = RemoteArtworkView.connectorPositions(for: profile.artwork)
                XCTAssertEqual(Set(layout.leftInputs + layout.rightInputs), Set(profile.inputs))
                XCTAssertEqual(layout.leftInputs.count + layout.rightInputs.count, profile.inputs.count)
                for inputs in [layout.leftInputs, layout.rightInputs] {
                    for (upper, lower) in zip(inputs, inputs.dropFirst()) {
                        let upperPoint = try XCTUnwrap(positions[upper])
                        let lowerPoint = try XCTUnwrap(positions[lower])
                        XCTAssertGreaterThan((lowerPoint.y - upperPoint.y) * layout.remoteHeight, 6,
                                             "Leaders for \(upper) and \(lower) must remain separated")
                    }
                }
                XCTAssertTrue(layout.rightInputs.contains(.inputSource), "Input source must connect from its own side")
                XCTAssertEqual(layout.leftInputs.last, .power)
                for input in profile.inputs {
                    let point = try XCTUnwrap(positions[input])
                    let bounds = CGRect(origin: .zero, size: CGSize(width: layout.remoteWidth, height: layout.remoteHeight))
                    XCTAssertEqual(RemoteArtworkView.input(at: CGPoint(x: point.x * bounds.width, y: point.y * bounds.height),
                                                          in: bounds, artwork: profile.artwork), input)
                }
            }
        }
    }

    func testPhysicalPressesOverridePreviewWithoutChangingTheOpenEditor() {
        let suite = "RcHarness.ArtworkTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        model.openButtonEditor(.buttonA)

        func highlights() -> Set<ControllerInput> {
            RemoteArtworkView.highlightedInputs(pressed: model.pressedInputs, preview: .home)
        }

        XCTAssertEqual(highlights(), [.home])
        model.setInput(.dpadLeft, pressed: true)
        XCTAssertEqual(highlights(), [.dpadLeft])
        model.setInput(.rightShoulder, pressed: true)
        XCTAssertEqual(highlights(), [.dpadLeft, .rightShoulder])
        XCTAssertEqual(model.selectedInput, .buttonA, "Feedback must not retarget the editor")
        model.setInput(.dpadLeft, pressed: false)
        XCTAssertEqual(highlights(), [.rightShoulder])
        model.setInput(.rightShoulder, pressed: false)
        XCTAssertEqual(highlights(), [.home])
        model.setInput(.menu, pressed: true)
        model.setConnected(false)
        XCTAssertEqual(highlights(), [.home], "Disconnect must not leave a pressed highlight behind")
        XCTAssertTrue(RemoteArtworkView.highlightedInputs(pressed: [], preview: nil).isEmpty)
    }

    func testButtonCentresAndArrowTipsHitTheSameControlsAtEverySize() throws {
        for profile in [RemoteProfiles.xiaomiRC001, RemoteProfiles.xiaomiRC003] {
            for size in [CGSize(width: 80, height: 316), CGSize(width: 180, height: 520),
                         CGSize(width: 260, height: 1100)] {
                let bounds = RemoteArtworkView.artworkBounds(in: size, artwork: profile.artwork)
                for input in profile.inputs {
                    for positions in [RemoteArtworkView.markerPositions(for: profile.artwork),
                                      RemoteArtworkView.connectorPositions(for: profile.artwork)] {
                        let point = try XCTUnwrap(positions[input])
                        let location = CGPoint(x: bounds.minX + point.x * bounds.width,
                                               y: bounds.minY + point.y * bounds.height)
                        XCTAssertEqual(RemoteArtworkView.input(at: location, in: bounds, artwork: profile.artwork), input,
                                       "Wrong target for \(input) at \(size)")
                    }
                }
            }
        }
    }

    func testBlankBodyLetterboxingAndNavigationGapsDoNotOpenAnotherButton() {
        let bounds = RemoteArtworkView.artworkBounds(in: CGSize(width: 180, height: 520))
        let body = CGPoint(x: bounds.midX, y: bounds.minY + bounds.height * 0.8)
        XCTAssertNil(RemoteArtworkView.input(at: body, in: bounds))
        XCTAssertNil(RemoteArtworkView.input(at: CGPoint(x: 0, y: bounds.midY), in: bounds))
        XCTAssertNil(RemoteArtworkView.input(at: .zero, in: .zero))

        let centre = RemoteArtworkView.markerPositions[.buttonA]!
        let origin = CGPoint(x: bounds.minX + centre.x * bounds.width,
                             y: bounds.minY + centre.y * bounds.height)
        XCTAssertEqual(RemoteArtworkView.input(at: origin, in: bounds), .buttonA)
        // A diagonal between cardinal sectors must not select confirmation
        // or an adjacent direction just because their bounding boxes overlap.
        let diagonal = bounds.width * 0.32 / sqrt(2)
        XCTAssertNil(RemoteArtworkView.input(at: CGPoint(x: origin.x + diagonal,
                                                        y: origin.y + diagonal), in: bounds))
    }

    func testGoogleNavigationOutlineFollowsThePhotographedRimAtEverySize() {
        // Measured on the packaged 392 × 1333 photo. The outer ring is
        // narrower and centred farther right than the confirmation button.
        for scale: CGFloat in [0.25, 0.5, 1, 2] {
            let bounds = CGRect(x: 17, y: 29, width: 392 * scale, height: 1333 * scale)
            func location(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: bounds.minX + x * scale, y: bounds.minY + y * scale)
            }
            for (input, rim): (ControllerInput, CGPoint) in [
                (.dpadUp, CGPoint(x: 176, y: 25)),
                (.dpadLeft, CGPoint(x: 36, y: 205)),
                (.dpadDown, CGPoint(x: 176, y: 385)),
                (.dpadRight, CGPoint(x: 315, y: 205)),
            ] {
                let outline = RemoteArtworkView.controlOutline(for: input, in: bounds, artwork: .chromecast)
                let edge: CGFloat
                let expected: CGFloat
                switch input {
                case .dpadUp: edge = outline.boundingRect.minY; expected = rim.y
                case .dpadDown: edge = outline.boundingRect.maxY; expected = rim.y
                case .dpadLeft: edge = outline.boundingRect.minX; expected = rim.x
                default: edge = outline.boundingRect.maxX; expected = rim.x
                }
                let offset = input == .dpadUp || input == .dpadDown ? bounds.minY : bounds.minX
                XCTAssertEqual((edge - offset) / scale, expected, accuracy: 2)
            }
            XCTAssertNil(RemoteArtworkView.input(at: location(26, 205), in: bounds, artwork: .chromecast),
                         "The body to the left of the navigation ring must not highlight a direction")
            XCTAssertEqual(RemoteArtworkView.input(at: location(40, 205), in: bounds, artwork: .chromecast), .dpadLeft)
            XCTAssertNil(RemoteArtworkView.input(at: location(113, 205), in: bounds, artwork: .chromecast),
                         "The gap around confirmation must remain outside the directional highlight")
        }
    }
}
