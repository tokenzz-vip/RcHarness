import CoreGraphics
import XCTest
@testable import RcHarness

final class VoiceShortcutChoiceTests: XCTestCase {
    func testPopoverChoosesTheRoomierDirectionAndCapsOnlyContentHeight() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let low = VoiceShortcutPopoverLayout(anchor: CGRect(x: 400, y: 80, width: 300, height: 36), visibleFrame: screen)
        XCTAssertEqual(low.preferredEdge, .maxY)
        XCTAssertEqual(low.contentHeight, VoiceShortcutPopoverLayout.height)
        let high = VoiceShortcutPopoverLayout(anchor: CGRect(x: 400, y: 780, width: 300, height: 36), visibleFrame: screen)
        XCTAssertEqual(high.preferredEdge, .minY)
        XCTAssertEqual(high.contentHeight, VoiceShortcutPopoverLayout.height)
        let center = VoiceShortcutPopoverLayout(anchor: CGRect(x: 400, y: 400, width: 300, height: 36), visibleFrame: screen)
        XCTAssertEqual(center.contentHeight, VoiceShortcutPopoverLayout.height)
        let constrained = VoiceShortcutPopoverLayout(anchor: CGRect(x: 80, y: 200, width: 300, height: 36),
            visibleFrame: CGRect(x: 0, y: 0, width: 800, height: 450))
        XCTAssertEqual(constrained.preferredEdge, .maxY)
        XCTAssertEqual(constrained.contentHeight, 194)
        let secondScreen = VoiceShortcutPopoverLayout(anchor: CGRect(x: -1000, y: -900, width: 300, height: 36),
            visibleFrame: CGRect(x: -1440, y: -1000, width: 1440, height: 900))
        XCTAssertEqual(secondScreen.preferredEdge, .maxY)
        XCTAssertEqual(secondScreen.contentHeight, VoiceShortcutPopoverLayout.height)
    }

    func testHoldOffersExactlySevenSinglesAndTapAllTwentyOneDistinctPairs() {
        XCTAssertEqual(VoiceShortcutChoice.singles.map { $0.shortcut.keyCode }, [63, 55, 54, 58, 61, 59, 62])
        XCTAssertEqual(VoiceShortcutChoice.options(for: .hold).count, 7)
        XCTAssertEqual(VoiceShortcutChoice.options(for: .tap).count, 28)
        XCTAssertEqual(VoiceShortcutChoice.pairs.count, 21)
        XCTAssertEqual(Set(VoiceShortcutChoice.options(for: .tap).map(\.id)).count, 28)
        for pair in VoiceShortcutChoice.pairs {
            XCTAssertEqual(Set(pair.keys).count, 2)
            XCTAssertNil(VoiceShortcutChoice.matching(pair.shortcut, mode: .hold))
            XCTAssertEqual(VoiceShortcutChoice.matching(pair.shortcut, mode: .tap), pair)
        }
        for codes: Set<UInt16> in [[55, 54], [58, 61], [59, 62]] {
            XCTAssertTrue(VoiceShortcutChoice.pairs.contains { Set($0.keys.map(\.keyCode)) == codes })
        }
    }

    func testOldThreeFieldJSONAndSideLessSingleModifiersMigrateToSelections() throws {
        for choice in VoiceShortcutChoice.singles {
            let key = choice.keys[0]
            let generic: CGEventFlags = [.maskSecondaryFn, .maskCommand, .maskAlternate, .maskControl]
            let json: [String: Any] = ["keyCode": key.keyCode, "modifiers": key.flags.intersection(generic).rawValue, "label": "旧标签"]
            let decoded = try JSONDecoder().decode(RecordedShortcut.self, from: JSONSerialization.data(withJSONObject: json))
            XCTAssertNil(decoded.modifierKeyCodes)
            XCTAssertEqual(VoiceShortcutChoice.normalized(decoded, mode: .hold), choice.shortcut)
            XCTAssertEqual(VoiceShortcutChoice.normalized(decoded, mode: .tap), choice.shortcut)
        }
    }

    func testSelectedPairsRoundTripJSONIncludingBothSidesOfSameModifier() throws {
        for pair in VoiceShortcutChoice.pairs {
            let decoded = try JSONDecoder().decode(RecordedShortcut.self, from: JSONEncoder().encode(pair.shortcut))
            XCTAssertEqual(decoded, pair.shortcut)
            XCTAssertEqual(VoiceShortcutChoice.matching(decoded, mode: .tap), pair)
        }
    }

    func testInvalidOldOrImportedBindingsFallBackToFn() {
        let invalid: [RecordedShortcut] = [
            .init(keyCode: 49, modifiers: CGEventFlags.maskSecondaryFn.rawValue, label: "Fn + Space"),
            .init(keyCode: 40, modifiers: CGEventFlags.maskCommand.rawValue, label: "⌘K"),
            .init(keyCode: 56, modifiers: CGEventFlags.maskShift.rawValue, label: "Shift"),
            .init(keyCode: 55, modifiers: CGEventFlags.maskCommand.union(.maskShift).rawValue, label: "⇧⌘"),
            .init(keyCode: 55, modifiers: 0, label: "missing modifier"),
            .init(keyCode: 55, modifiers: 0, label: "duplicate", modifierKeyCodes: [55, 55]),
            .init(keyCode: 55, modifiers: 0, label: "three", modifierKeyCodes: [63, 55, 58]),
            .init(keyCode: 55, modifiers: 0, label: "unsupported", modifierKeyCodes: [55, 56])
        ]
        for shortcut in invalid {
            for mode in [VoiceTriggerMode.hold, .tap] {
                XCTAssertNil(VoiceShortcutChoice.matching(shortcut, mode: mode), shortcut.label)
                XCTAssertEqual(VoiceShortcutChoice.normalized(shortcut, mode: mode), .voiceHoldDefault)
            }
        }
        XCTAssertEqual(VoiceShortcutChoice.normalized(nil, mode: .tap), .voiceHoldDefault)
    }

    func testEverySelectedPairEmitsBothPhysicalKeysInOrderAndReleasesWithoutResidualFlags() {
        for choice in VoiceShortcutChoice.pairs {
            var events: [CGEvent] = []
            let sender = SystemEventSender(postEvent: { events.append($0) })
            sender.sendShortcut(choice.shortcut, pressed: true)
            sender.sendShortcut(choice.shortcut, pressed: false)
            let codes = choice.keys.map { Int64($0.keyCode) }
            XCTAssertEqual(events.map { $0.getIntegerValueField(.keyboardEventKeycode) }, codes + codes.reversed(), choice.label)
            XCTAssertEqual(events.map(\.type), [.flagsChanged, .flagsChanged, .flagsChanged, .flagsChanged], choice.label)
            XCTAssertEqual(events.map(\.flags), [choice.keys[0].flags,
                choice.keys[0].flags.union(choice.keys[1].flags), choice.keys[0].flags, []], choice.label)
            if choice.keys.contains(.function) {
                XCTAssertEqual(events.map { $0.getIntegerValueField(.eventSourceStateID) }, [1, 1, 1, 1])
            }
        }
    }

    func testPairAndSingleSharePhysicalModifierUntilLastOwnerReleasesIt() throws {
        let pair = try XCTUnwrap(VoiceShortcutChoice.pairs.first { $0.keys == [.leftCommand, .rightCommand] })
        let single = try XCTUnwrap(VoiceShortcutChoice.singles.first { $0.keys == [.leftCommand] })
        for releasePairFirst in [true, false] {
            var events: [CGEvent] = []
            let sender = SystemEventSender(postEvent: { events.append($0) })
            sender.sendShortcut(pair.shortcut, pressed: true)
            sender.sendShortcut(single.shortcut, pressed: true)
            XCTAssertEqual(events.count, 2)
            sender.sendShortcut(releasePairFirst ? pair.shortcut : single.shortcut, pressed: false)
            if releasePairFirst { XCTAssertEqual(events.last?.flags, single.keys[0].flags) }
            sender.sendShortcut(releasePairFirst ? single.shortcut : pair.shortcut, pressed: false)
            XCTAssertEqual(events.count, 4)
            XCTAssertEqual(events.last?.flags, [])
            XCTAssertEqual(events.filter { $0.getIntegerValueField(.keyboardEventKeycode) == 55 }.count, 2)
        }
    }
}
