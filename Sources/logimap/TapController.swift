import ApplicationServices
import CoreGraphics
import Foundation

/// Владеет CGEventTap'ами и выполняет решения BindEngine.
///
/// Защита от петли событий (из-за которой зависала версия на Hammerspoon):
/// 1. Все synthetic-события помечены магическим числом в поле eventSourceUserData;
///    inject-тап их игнорирует — замкнутого контура не возникает.
/// 2. Inject-тап только мутирует флаги события «на месте» и возвращает его же —
///    мы ничего не постим из его колбэка, порождать новые события нечем.
/// 3. StormDetector: аномальный поток событий → inject отключается, модификаторы отпускаются.
/// 4. Watch-тап слушает только otherMouse*; synthetic-клавиатура в его маску не входит.
final class TapController {
    /// Магическая метка наших synthetic-событий.
    static let synthTag: Int64 = 0x1A6_1C0_DEA

    let engine: BindEngine
    let injectFlags: Bool
    var log: (String) -> Void = { print($0) }

    private let eventSource: CGEventSource?
    private var watchPort: CFMachPort?
    private var injectPort: CFMachPort?
    private var storm = StormDetector()
    private var selfPointer: UnsafeMutableRawPointer?

    init(engine: BindEngine, injectFlags: Bool) {
        self.engine = engine
        self.injectFlags = injectFlags
        self.eventSource = CGEventSource(stateID: .combinedSessionState)
    }

    // MARK: - Жизненный цикл

    /// Создаёт тапы. false — нет Accessibility-разрешения (или session tap недоступен).
    func start() -> Bool {
        let opaque = Unmanaged.passRetained(self).toOpaque()
        selfPointer = opaque

        let watchMask = Self.mask([.otherMouseDown, .otherMouseUp])
        guard let watch = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: watchMask,
            callback: Self.watchCallback,
            userInfo: opaque
        ) else {
            return false
        }
        watchPort = watch
        addToRunLoop(watch)
        log("watch tap started")

        if injectFlags {
            let injectMask = Self.mask([
                .keyDown, .keyUp, .flagsChanged,
                .leftMouseDown, .leftMouseUp, .leftMouseDragged,
                .rightMouseDown, .rightMouseUp,
                .otherMouseDown, .otherMouseUp, .otherMouseDragged,
                .scrollWheel,
            ])
            if let inject = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: injectMask,
                callback: Self.injectCallback,
                userInfo: opaque
            ) {
                injectPort = inject
                addToRunLoop(inject)
                log("inject tap started (flag injection ON)")
            } else {
                log("WARN: inject tap не создался — работаем без подмешивания флагов")
            }
        } else {
            log("flag injection OFF (конфиг)")
        }
        return true
    }

    /// Отпускает все зажатые модификаторы и глушит тапы. Вызывается по SIGINT/SIGTERM.
    func shutdown(exitCode: Int32) {
        injectPort.map { CGEvent.tapEnable(tap: $0, enable: false) }
        watchPort.map { CGEvent.tapEnable(tap: $0, enable: false) }

        let previous = engine.activeFlags
        let events = engine.releaseAll()
        let physical = baseFlags.subtracting(previous)
        for event in events {
            post(event, physical: physical)
        }
        log("shutdown: modifiers released (\(events.count))")
        exit(exitCode)
    }

    // MARK: - Обработчики колбэков

    func handleWatch(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            watchPort.map { CGEvent.tapEnable(tap: $0, enable: true) }
            log("watch tap re-enabled after \(type == .tapDisabledByTimeout ? "timeout" : "user input")")
            return nil
        case .otherMouseDown, .otherMouseUp:
            break
        default:
            return Unmanaged.passUnretained(event)
        }

        let button = Int(event.getIntegerValueField(.mouseEventButtonNumber))
        let isDown = type == .otherMouseDown

        let previous = engine.activeFlags
        let decision = isDown ? engine.buttonDown(button) : engine.buttonUp(button)
        if let decision = decision {
            let physical = baseFlags.subtracting(previous)
            post(decision, physical: physical)
            if case .press(let spec) = decision {
                log("btn \(button) → \(spec.name) DOWN")
            } else if case .release(let spec) = decision {
                log("btn \(button) → \(spec.name) UP")
            }
        }

        // Замапленную кнопку проглатываем, чтобы не срабатывало «назад/вперёд».
        if engine.isMapped(button) {
            return nil
        }
        return Unmanaged.passUnretained(event)
    }

    func handleInject(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            injectPort.map { CGEvent.tapEnable(tap: $0, enable: true) }
            log("inject tap re-enabled")
            return nil
        default:
            break
        }

        // Свои synthetic-события пропускаем не глядя — иначе петля.
        if event.getIntegerValueField(.eventSourceUserData) == Self.synthTag {
            return Unmanaged.passUnretained(event)
        }

        let active = engine.activeFlags
        if active.isEmpty {
            return Unmanaged.passUnretained(event)
        }

        if storm.hit() {
            injectPort.map { CGEvent.tapEnable(tap: $0, enable: false) }
            let previous = engine.activeFlags
            let events = engine.releaseAll()
            let physical = baseFlags.subtracting(previous)
            for event in events {
                post(event, physical: physical)
            }
            log("‼ STORM: >\(storm.maxHits) events/\(Int(storm.window * 1000))ms — inject отключён, модификаторы отпущены")
            return Unmanaged.passUnretained(event)
        }

        // Мутируем флаги на месте и возвращаем тот же объект. Никаких post() здесь.
        event.flags = event.flags.union(active)
        return Unmanaged.passUnretained(event)
    }

    // MARK: - Приватное

    private var baseFlags: CGEventFlags {
        CGEventSource.flagsState(.combinedSessionState)
    }

    private func post(_ modifierEvent: ModifierEvent, physical: CGEventFlags) {
        guard let source = eventSource else { return }
        let spec: ModifierSpec
        let keyDown: Bool
        switch modifierEvent {
        case .press(let s): spec = s; keyDown = true
        case .release(let s): spec = s; keyDown = false
        }
        guard let event = CGEvent(keyboardEventSource: source,
                                  virtualKey: spec.keycode,
                                  keyDown: keyDown) else { return }
        event.flags = BindEngine.composeFlags(sourceFlags: physical,
                                              previousActive: [],
                                              currentActive: engine.activeFlags)
        event.setIntegerValueField(.eventSourceUserData, value: Self.synthTag)
        event.post(tap: .cgSessionEventTap)
    }

    private func addToRunLoop(_ port: CFMachPort) {
        guard let rlSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else { return }
        CFRunLoopAddSource(CFRunLoopGetCurrent(), rlSource, CFRunLoopMode.commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
    }

    private static func mask(_ types: [CGEventType]) -> CGEventMask {
        types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
    }

    // MARK: - C-колбэки

    static let watchCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let controller = Unmanaged<TapController>.fromOpaque(userInfo).takeUnretainedValue()
        return controller.handleWatch(type: type, event: event)
    }

    static let injectCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let controller = Unmanaged<TapController>.fromOpaque(userInfo).takeUnretainedValue()
        return controller.handleInject(type: type, event: event)
    }
}

// MARK: - Accessibility

enum Accessibility {
    static func isTrusted(prompt: Bool) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}
