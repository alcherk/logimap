import CoreGraphics
@testable import logimap
import XCTest

final class EngineTests: XCTestCase {
    private let option = ModifierSpec.registry["option"]!
    private let control = ModifierSpec.registry["control"]!

    private func engine() -> BindEngine {
        BindEngine(mappings: [3: option, 4: control])
    }

    func testPressAndRelease() {
        let e = engine()
        XCTAssertEqual(e.buttonDown(3), .press(option))
        XCTAssertEqual(e.buttonUp(3), .release(option))
    }

    func testDuplicateDownIgnored() {
        let e = engine()
        XCTAssertEqual(e.buttonDown(3), .press(option))
        XCTAssertNil(e.buttonDown(3)) // дубликат down не должен ничего посылать
        XCTAssertEqual(e.buttonUp(3), .release(option))
        XCTAssertNil(e.buttonUp(3)) // повторный up тоже
    }

    func testUnmappedButtonDoesNothing() {
        let e = engine()
        XCTAssertNil(e.buttonDown(7))
        XCTAssertNil(e.buttonUp(7))
    }

    func testActiveFlagsTrackState() {
        let e = engine()
        XCTAssertTrue(e.activeFlags.isEmpty)
        e.buttonDown(3)
        XCTAssertEqual(e.activeFlags, [.maskAlternate] as CGEventFlags)
        e.buttonDown(4)
        XCTAssertEqual(e.activeFlags, [.maskAlternate, .maskControl] as CGEventFlags)
        e.buttonUp(3)
        XCTAssertEqual(e.activeFlags, [.maskControl] as CGEventFlags)
        e.buttonUp(4)
        XCTAssertTrue(e.activeFlags.isEmpty)
    }

    func testRefcountTwoButtonsSameModifier() {
        let e = BindEngine(mappings: [3: option, 4: option])
        XCTAssertEqual(e.buttonDown(3), .press(option))
        XCTAssertNil(e.buttonDown(4)) // option уже зажат — повторно не жмём
        XCTAssertNil(e.buttonUp(3))   // кнопку 4 ещё держат
        XCTAssertEqual(e.buttonUp(4), .release(option))
    }

    func testReleaseAll() {
        let e = engine()
        e.buttonDown(3)
        e.buttonDown(4)
        let released = e.releaseAll()
        XCTAssertEqual(Set(released), [.release(option), .release(control)])
        XCTAssertTrue(e.activeFlags.isEmpty)
        // повторный releaseAll не должен генерировать события
        XCTAssertTrue(e.releaseAll().isEmpty)
    }

    func testIsMapped() {
        let e = engine()
        XCTAssertTrue(e.isMapped(3))
        XCTAssertFalse(e.isMapped(5))
    }

    func testComposeFlagsKeepsPhysicalAndAddsOurs() {
        // физически зажат ⌘, мы до этого держали option, теперь держим option+control
        let result = BindEngine.composeFlags(
            sourceFlags: [.maskCommand, .maskAlternate] as CGEventFlags,
            previousActive: [.maskAlternate] as CGEventFlags,
            currentActive: [.maskAlternate, .maskControl] as CGEventFlags
        )
        XCTAssertTrue(result.contains(.maskCommand)) // физический не потерян
        XCTAssertTrue(result.contains(.maskAlternate))
        XCTAssertTrue(result.contains(.maskControl))
        XCTAssertFalse(result.contains(.maskShift))
    }

    func testComposeFlagsOnRelease() {
        // отпускаем option: остаются только физические флаги
        let result = BindEngine.composeFlags(
            sourceFlags: [.maskCommand, .maskAlternate] as CGEventFlags,
            previousActive: [.maskAlternate] as CGEventFlags,
            currentActive: []
        )
        XCTAssertEqual(result, [.maskCommand] as CGEventFlags)
    }
}

final class StormDetectorTests: XCTestCase {
    func testNoTripUnderLimit() {
        var d = StormDetector(maxHits: 100, window: 1.0)
        let t0 = Date()
        for i in 0..<100 {
            XCTAssertFalse(d.hit(now: t0.addingTimeInterval(Double(i) * 0.001)))
        }
    }

    func testTripsOverLimit() {
        var d = StormDetector(maxHits: 10, window: 1.0)
        let t0 = Date()
        for i in 0..<10 {
            _ = d.hit(now: t0.addingTimeInterval(Double(i) * 0.001))
        }
        XCTAssertTrue(d.hit(now: t0.addingTimeInterval(0.02)))
    }

    func testResetsAfterQuietWindow() {
        var d = StormDetector(maxHits: 5, window: 0.1)
        let t0 = Date()
        for _ in 0..<5 { _ = d.hit(now: t0) }
        XCTAssertTrue(d.hit(now: t0)) // 6-е событие в том же окне — шторм
        XCTAssertFalse(d.hit(now: t0.addingTimeInterval(1.0))) // новое окно — чисто
    }
}
