import Foundation
@testable import logimap
import XCTest

final class ConfigTests: XCTestCase {
    func testDefaultsMatchG603() throws {
        let config = try AppConfig.parse("{}".data(using: .utf8)!)
        XCTAssertEqual(config.mappings, [
            MappingRule(button: 3, modifier: "option"),
            MappingRule(button: 4, modifier: "control"),
        ])
        XCTAssertTrue(config.injectFlags)
    }

    func testPartialOverride() throws {
        let json = #"{"injectFlags": false}"#
        let config = try AppConfig.parse(json.data(using: .utf8)!)
        XCTAssertFalse(config.injectFlags)
        XCTAssertEqual(config.mappings.count, 2) // mappings не указаны — дефолт
    }

    func testAliases() throws {
        let json = #"{"mappings": [{"button": 3, "modifier": "alt"}, {"button": 4, "modifier": "ctrl"}]}"#
        let engine = try AppConfig.parse(json.data(using: .utf8)!).engine()
        XCTAssertEqual(engine.buttonDown(3), .press(ModifierSpec.registry["option"]!))
        XCTAssertEqual(engine.buttonDown(4), .press(ModifierSpec.registry["control"]!))
    }

    func testUnknownModifierThrows() {
        let json = #"{"mappings": [{"button": 3, "modifier": "hyper"}]}"#
        XCTAssertThrowsError(try AppConfig.parse(json.data(using: .utf8)!).engine())
    }

    func testDuplicateButtonThrows() {
        let json = #"{"mappings": [{"button": 3, "modifier": "option"}, {"button": 3, "modifier": "shift"}]}"#
        XCTAssertThrowsError(try AppConfig.parse(json.data(using: .utf8)!).engine())
    }

    func testInvalidJSONThrows() {
        let json = #"{"mappings": 42}"#
        XCTAssertThrowsError(try AppConfig.parse(json.data(using: .utf8)!))
    }

    func testLoadMissingFileGivesDefaults() throws {
        let path = NSTemporaryDirectory() + "logimap-test-\(UUID().uuidString).json"
        let config = try AppConfig.load(path: path)
        XCTAssertEqual(config.mappings.count, 2)
    }
}
