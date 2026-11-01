import CoreGraphics
import Foundation

/// Событие «нажать/отпустить модификатор», которое нужно отправить в систему.
enum ModifierEvent: Equatable, Hashable {
    case press(ModifierSpec)
    case release(ModifierSpec)
}

/// Чистая логика биндов: CG-номер кнопки → модификатор.
///
/// Инварианты, защищающие от «залипших» модификаторов:
/// - дубликаты down/up по одной кнопке игнорируются;
/// - счётчик ссылок: две кнопки на один модификатор — release только когда отпущены обе;
/// - `releaseAll()` гарантированно отпускает всё, что зажато.
final class BindEngine {
    private let mappings: [Int: ModifierSpec]
    private var active: [Int: ModifierSpec] = [:]

    init(mappings: [Int: ModifierSpec]) {
        self.mappings = mappings
    }

    var mappingsDescription: String {
        mappings.keys.sorted().map { "\(mappings[$0]!.name) → кнопка CG#\($0)" }.joined(separator: ", ")
    }

    func isMapped(_ button: Int) -> Bool {
        mappings[button] != nil
    }

    var activeSpecs: [ModifierSpec] {
        Array(Set(active.values))
    }

    var activeFlags: CGEventFlags {
        activeSpecs.reduce(CGEventFlags()) { $0.union($1.flags) }
    }

    @discardableResult
    func buttonDown(_ button: Int) -> ModifierEvent? {
        guard let spec = mappings[button], active[button] == nil else { return nil }
        let alreadyHeld = active.values.contains(spec)
        active[button] = spec
        return alreadyHeld ? nil : .press(spec)
    }

    @discardableResult
    func buttonUp(_ button: Int) -> ModifierEvent? {
        guard let spec = active[button] else { return nil }
        active[button] = nil
        let stillHeld = active.values.contains(spec)
        return stillHeld ? nil : .release(spec)
    }

    func releaseAll() -> [ModifierEvent] {
        let specs = activeSpecs
        active.removeAll()
        return specs.map { .release($0) }
    }

    /// Флаги для synthetic flagsChanged: физически зажатое объединяем с нашим активным.
    /// previousActive — наши флаги ДО перехода, currentActive — ПОСЛЕ.
    static func composeFlags(sourceFlags: CGEventFlags,
                             previousActive: CGEventFlags,
                             currentActive: CGEventFlags) -> CGEventFlags {
        let physical = sourceFlags.subtracting(previousActive)
        return physical.union(currentActive)
    }
}

/// Предохранитель от петли событий: если через inject-тап за окно проходит
/// аномально много событий — это шторм, надо аварийно отключиться,
/// пока не заблокировали ввод (урок из версии на Hammerspoon).
struct StormDetector {
    let maxHits: Int
    let window: TimeInterval

    private var count = 0
    private var windowStart: Date?

    init(maxHits: Int = 2000, window: TimeInterval = 0.5) {
        self.maxHits = maxHits
        self.window = window
    }

    /// Добавляет одно событие; true — детектор сработал (шторм).
    mutating func hit(now: Date = Date()) -> Bool {
        if let start = windowStart, now.timeIntervalSince(start) < window {
            count += 1
            return count > maxHits
        }
        windowStart = now
        count = 1
        return count > maxHits
    }

    mutating func reset() {
        count = 0
        windowStart = nil
    }
}
