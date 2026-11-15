import XCTest
@testable import ShareBarCore

/// TASK-4b5: the three token tiers and the state words.
final class TokensAndStateWordTests: XCTestCase {
    func testEveryLinkStateHasASymbolAndAWord() {
        XCTAssertEqual(LinkState.allCases.count, 7)
        var words = Set<String>()
        for state in LinkState.allCases {
            let word = state.stateWord
            XCTAssertFalse(word.symbol.isEmpty, "\(state) symbol")
            XCTAssertFalse(word.word.isEmpty, "\(state) word")
            words.insert(word.word)
        }
        XCTAssertEqual(words.count, LinkState.allCases.count, "no two link states share a word")
        XCTAssertEqual(LinkState(raw: nil), .live)
        XCTAssertEqual(LinkState(raw: "never_heard_of_it"), .live)
        XCTAssertEqual(LinkState(raw: "gate_missing"), .gateMissing)
    }

    func testLinkStateRulesMatchTheSpecTable() {
        // `### Components & states`: click or Return copies, drag out, by link_state.
        let table: [(LinkState, copies: Bool, drags: Bool)] = [
            (.live, true, true), (.offline, true, true), (.paused, true, true),
            (.expired, false, false), (.revoked, false, false),
        ]
        for (state, copies, drags) in table {
            XCTAssertEqual(state.canCopy, copies, "\(state) copy")
            XCTAssertEqual(state.canDrag, drags, "\(state) drag")
        }
        XCTAssertNil(LinkState.live.copyWarning)
        XCTAssertNil(LinkState.offline.copyWarning, "the offline copy names the machine, so the row builds it")
        XCTAssertEqual(LinkState.paused.copyWarning, "This member is paused: visitors get a 503.")
        XCTAssertEqual(LinkState.expired.copyWarning, "This link expired, so it no longer answers. Share the file again for a new link.")
        XCTAssertEqual(LinkState.revoked.stateWord.word, "removed by admin")
    }

    func testEveryMemberStatusHasASymbolAndAWord() {
        let stored = ["adding", "invited", "joining", "active", "pausing", "paused", "resuming", "inviting",
                      "rotating", "renewing", "removing", "removed", "left"]
        for raw in stored + ["expired", "invalid"] {
            let status = MemberStatus(raw: raw)
            XCTAssertNotNil(status, raw)
            XCTAssertFalse(status?.stateWord.symbol.isEmpty ?? true, raw)
            XCTAssertFalse(status?.stateWord.word.isEmpty ?? true, raw)
        }
        XCTAssertEqual(MemberStatus.allCases.count, stored.count + 2, "a new status needs a word here")
        XCTAssertNil(MemberStatus(raw: "teleporting"))
        XCTAssertNil(MemberStatus(raw: nil))
        XCTAssertEqual(MemberStatus.invited.stateWord.word, "Invited")
        XCTAssertEqual(MemberStatus.removed.stateWord.word, "Removed")
    }

    func testDarkOverridesOnlySemanticTokens() {
        let light = Tokens.palette(.light)
        let dark = Tokens.palette(.dark)
        XCTAssertEqual(light.primitive, dark.primitive, "the primitive tier is the system's: one value for both appearances")
        XCTAssertNotEqual(light.semantic, dark.semantic)
        for tone in StateTone.allCases {
            XCTAssertNotEqual(light.semantic.fill(tone), dark.semantic.fill(tone), "\(tone) fill differs in dark")
        }
        XCTAssertEqual(light.semantic.chipOpacity, 0.14)
        XCTAssertEqual(dark.semantic.chipOpacity, 0.24)
        XCTAssertEqual(light.semantic.focus, light.semantic.info, "focus is the info hue")
        XCTAssertNotEqual(dark.semantic.focus, dark.semantic.info, "brightened in dark so it clears 3:1")
        // The component tier holds no value of its own: it is a function of the other two.
        XCTAssertEqual(light.component.chipBackground(.info), light.semantic.info.composited(alpha: 0.14, over: light.primitive.window.light))
        XCTAssertEqual(dark.component.chipForeground(.attention), dark.semantic.attentionInk)
        XCTAssertEqual(dark.component.toastBackground, dark.semantic.toastBackground)
    }

    func testPrototypeValuesAreTheTokenValues() {
        let light = Tokens.palette(.light)
        XCTAssertEqual(light.primitive.label.light, RGB(hex: "#1d1d1f"))
        XCTAssertEqual(light.primitive.label.dark, RGB(hex: "#f5f5f7"))
        XCTAssertEqual(light.semantic.attention, RGB(hex: "#ff9500"))
        XCTAssertEqual(light.semantic.attentionInk, RGB(hex: "#8a4b00"))
        XCTAssertEqual(light.semantic.errorInk, RGB(hex: "#a3190f"))
        XCTAssertEqual(light.semantic.quiet, RGB(hex: "#8e8e93"))
        XCTAssertEqual(light.semantic.info, RGB(hex: "#0060df"))
        XCTAssertEqual(light.semantic.ok, RGB(hex: "#28a745"))
        XCTAssertEqual(Tokens.palette(.dark).semantic.focus, RGB(hex: "#4c9bff"))
        let primitive = Tokens.primitive
        XCTAssertEqual([primitive.titleSize, primitive.bodySize, primitive.monoSize, primitive.metaSize], [15, 13, 12, 11])
        XCTAssertEqual([primitive.buttonRadius, primitive.rowRadius, primitive.chipRadius], [6, 7, 4])
        XCTAssertEqual(primitive.minRowHeight, 40)
        XCTAssertEqual(primitive.iconButtonSize, 26)
        XCTAssertEqual(light.semantic.hoverOpacity, 0.06)
        XCTAssertEqual(light.semantic.pressedOpacity, 0.10)
        XCTAssertEqual(light.semantic.selectionOpacity, 0.08)
    }

    func testEveryTextPairMeets45AndEveryGlyphChipAndFocusPair3InBothAppearances() {
        for appearance in Appearance.allCases {
            let pairs = Tokens.palette(appearance).contrastPairs
            XCTAssertGreaterThan(pairs.count, 20)
            for pair in pairs {
                XCTAssertGreaterThanOrEqual(
                    pair.ratio, pair.role.minimum,
                    "\(appearance) \(pair.name): \(String(format: "%.2f", pair.ratio)) needs \(pair.role.minimum)"
                )
            }
        }
    }

    func testContrastMath() {
        XCTAssertEqual(RGB(hex: "#000000").contrast(with: RGB(hex: "#ffffff")), 21, accuracy: 0.001)
        XCTAssertEqual(RGB(hex: "#777777").contrast(with: RGB(hex: "#777777")), 1, accuracy: 0.001)
        XCTAssertEqual(
            RGB(hex: "#ff0000").composited(alpha: 0.5, over: RGB(hex: "#000000")),
            RGB(red: 127.5, green: 0, blue: 0)
        )
    }
}
