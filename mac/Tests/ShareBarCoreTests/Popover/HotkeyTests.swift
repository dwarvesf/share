import Carbon.HIToolbox
import XCTest
@testable import ShareBarCore

/// SPEC-009 TASK-4b13: Control-Option-S.
final class HotkeyTests: XCTestCase {
    /// Answers like the OS: one owner per key.
    private final class FakeRegistrar: HotkeyRegistrar {
        var held: [Hotkey: Int] = [:]
        var handlers: [Int: () -> Void] = [:]
        var next = 1
        func register(_ key: Hotkey, handler: @escaping () -> Void) -> Int? {
            guard held[key] == nil else { return nil }
            let token = next
            next += 1
            held[key] = token
            handlers[token] = handler
            return token
        }
        func unregister(_ token: Int) {
            held = held.filter { $0.value != token }
            handlers[token] = nil
        }
    }

    func testControlOptionSIsKeyCodeSWithControlAndOption() {
        XCTAssertEqual(Hotkey.controlOptionS.keyCode, UInt32(kVK_ANSI_S))
        XCTAssertEqual(Hotkey.controlOptionS.modifiers, UInt32(controlKey | optionKey))
    }

    func testTheFirstRegistrationTakesAndThePressRunsTheHandler() {
        let registrar = FakeRegistrar()
        let center = HotkeyCenter(registrar: registrar)
        var presses = 0
        XCTAssertEqual(center.register { presses += 1 }, .registered)
        registrar.handlers.values.forEach { $0() }
        XCTAssertEqual(presses, 1)
        XCTAssertNil(center.status.message)
    }

    func testASecondRegistrationOfTheSameKeyReportsInUse() {
        let registrar = FakeRegistrar()
        let first = HotkeyCenter(registrar: registrar)
        let second = HotkeyCenter(registrar: registrar)
        XCTAssertEqual(first.register {}, .registered)
        XCTAssertEqual(second.register {}, .inUse, "the key is held: it reports in use")
        XCTAssertEqual(second.status.message, "Control-Option-S is in use by another app")
        first.unregister()
        XCTAssertEqual(second.register {}, .registered, "once the holder lets go the key is free")
    }

    /// The real call: Carbon refuses a key a second time, with no Accessibility permission involved.
    func testCarbonRefusesASecondRegistrationOfTheSameKey() {
        let key = Hotkey(keyCode: UInt32(kVK_F19), modifiers: UInt32(controlKey | optionKey | cmdKey | shiftKey))
        let registrar = CarbonHotkeyRegistrar()
        let token = registrar.register(key) {}
        XCTAssertNotNil(token, "a free key registers")
        XCTAssertNil(registrar.register(key) {}, "the same key twice is refused")
        if let token { registrar.unregister(token) }
        let again = registrar.register(key) {}
        XCTAssertNotNil(again, "released, the key registers again")
        if let again { registrar.unregister(again) }
    }
}
