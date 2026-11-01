import CoreGraphics

/// Модификатор, который мы умеем «нажимать» вместо кнопки мыши.
struct ModifierSpec: Hashable {
    let name: String        // каноническое имя: option / control / command / shift
    let keycode: CGKeyCode  // код левой клавиши
    let flags: CGEventFlags

    // CGEventFlags не Hashable — сравниваем по имени и коду (flags выводится из имени)
    static func == (lhs: ModifierSpec, rhs: ModifierSpec) -> Bool {
        lhs.name == rhs.name && lhs.keycode == rhs.keycode
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(name)
        hasher.combine(keycode)
    }

    static let registry: [String: ModifierSpec] = [
        "option":  ModifierSpec(name: "option",  keycode: 58, flags: .maskAlternate),
        "control": ModifierSpec(name: "control", keycode: 59, flags: .maskControl),
        "command": ModifierSpec(name: "command", keycode: 55, flags: .maskCommand),
        "shift":   ModifierSpec(name: "shift",   keycode: 56, flags: .maskShift),
    ]

    /// Разрешает имя модификатора из конфига, включая алиасы (alt, ctrl, cmd…).
    static func resolve(_ raw: String) throws -> ModifierSpec {
        let aliases = [
            "alt": "option", "opt": "option", "⌥": "option",
            "ctrl": "control", "ctl": "control", "⌃": "control",
            "cmd": "command", "meta": "command", "⌘": "command",
            "⇧": "shift",
        ]
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let canonical = aliases[key] ?? key
        guard let spec = registry[canonical] else {
            throw ConfigError.unknownModifier(raw)
        }
        return spec
    }
}
