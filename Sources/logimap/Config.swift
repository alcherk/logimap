import Foundation

enum ConfigError: Error, LocalizedError {
    case unknownModifier(String)
    case duplicateButton(Int)
    case invalidJSON(String)

    var errorDescription: String? {
        switch self {
        case .unknownModifier(let raw):
            return "Неизвестный модификатор «\(raw)». Доступны: option, control, command, shift (алиасы: alt, ctrl, cmd)."
        case .duplicateButton(let button):
            return "Кнопка CG#\(button) указана в конфиге дважды."
        case .invalidJSON(let detail):
            return "Ошибка в config.json: \(detail)"
        }
    }
}

struct MappingRule: Equatable {
    let button: Int      // CG-номер с нуля: 3 = «Button 4» (ближняя на G603), 4 = «Button 5»
    let modifier: String // option / control / command / shift или алиас
}

struct AppConfig {
    /// Дефолт заточен под Logitech G603:
    /// ближняя к ладони кнопка («назад») = ⌥ Option, передняя («вперёд») = ⌃ Control.
    var mappings: [MappingRule] = [
        MappingRule(button: 3, modifier: "option"),
        MappingRule(button: 4, modifier: "control"),
    ]

    /// Подмешивать флаг модификатора в события мыши/клавиатуры, пока кнопка зажата.
    /// Именно это делает ⌥+клик и ⌃+скролл рабочими в приложениях.
    var injectFlags: Bool = true

    static let defaultPath = NSHomeDirectory() + "/.config/logimap/config.json"

    static func load(path: String? = nil) throws -> AppConfig {
        let url = URL(fileURLWithPath: path ?? defaultPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return AppConfig() // конфига нет — работаем на дефолтах
        }
        let data = try Data(contentsOf: url)
        return try parse(data)
    }

    static func parse(_ data: Data) throws -> AppConfig {
        guard let raw = try? JSONDecoder().decode(RawConfig.self, from: data) else {
            throw ConfigError.invalidJSON(
                "ожидался JSON вида {\"mappings\":[{\"button\":3,\"modifier\":\"option\"}],\"injectFlags\":true}"
            )
        }
        var config = AppConfig()
        if let m = raw.mappings {
            config.mappings = m.map { MappingRule(button: $0.button, modifier: $0.modifier) }
        }
        if let inject = raw.injectFlags {
            config.injectFlags = inject
        }
        return config
    }

    func engine() throws -> BindEngine {
        var map: [Int: ModifierSpec] = [:]
        for rule in mappings {
            guard map[rule.button] == nil else {
                throw ConfigError.duplicateButton(rule.button)
            }
            map[rule.button] = try ModifierSpec.resolve(rule.modifier)
        }
        return BindEngine(mappings: map)
    }

    func writeSample(to path: String) throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let json = """
        {
          "mappings": [
            { "button": 3, "modifier": "option"  },
            { "button": 4, "modifier": "control" }
          ],
          "injectFlags": true
        }
        """
        try json.data(using: .utf8)?.write(to: URL(fileURLWithPath: path))
    }
}

private struct RawConfig: Codable {
    var mappings: [MappingRuleDecodable]?
    var injectFlags: Bool?
}

private struct MappingRuleDecodable: Codable {
    let button: Int
    let modifier: String
}
