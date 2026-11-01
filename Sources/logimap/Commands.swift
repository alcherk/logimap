import CoreGraphics
import Darwin
import Foundation

// MARK: - Утилиты

private let stampFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f
}()

func stamp() -> String {
    stampFormatter.string(from: Date())
}

@discardableResult
func launchctl(_ arguments: [String]) -> (code: Int32, out: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        return (-1, "\(error)")
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

// MARK: - run / stop

enum RunCommand {
    static let agentLabel = "com.lex.logimap"

    static var pidfilePath: String {
        FileManager.default.temporaryDirectory.appendingPathComponent("logimap-\(getuid()).pid").path
    }

    private static var signalSources: [DispatchSourceSignal] = []

    static func run(configPath: String?, injectOverride: Bool?) throws {
        if let pid = existingRunningPID() {
            print("logimap уже запущен (pid \(pid)). Остановите: \(CommandLine.arguments[0]) stop")
            exit(1)
        }

        var config = try AppConfig.load(path: configPath)
        if let injectOverride = injectOverride {
            config.injectFlags = injectOverride
        }
        let engine = try config.engine()

        let usedPath = FileManager.default.fileExists(atPath: configPath ?? AppConfig.defaultPath)
            ? (configPath ?? AppConfig.defaultPath) : "\(AppConfig.defaultPath) (не найден, дефолты)"

        setvbuf(stdout, nil, _IOLBF, 0)
        print("logimap \(version) — G603 button → modifier mapper")
        print("config: \(usedPath)")
        print("mappings: \(engine.mappingsDescription)")
        print("injectFlags: \(config.injectFlags)")

        if !Accessibility.isTrusted(prompt: true) {
            print("Нет Accessibility-разрешения. Открой System Settings → Privacy & Security → Accessibility")
            print("и разреши logimap (или Terminal, если запущено из терминала). Жду…")
            while !Accessibility.isTrusted(prompt: false) {
                Thread.sleep(forTimeInterval: 1.0)
            }
            print("Accessibility есть, продолжаю.")
        }

        let controller = TapController(engine: engine, injectFlags: config.injectFlags)
        controller.log = { line in print("\(stamp()) \(line)") }
        guard controller.start() else {
            print("Не удалось создать event tap — проверь Accessibility-разрешение (logimap doctor).")
            exit(2)
        }

        try? "\(getpid())".write(toFile: pidfilePath, atomically: true, encoding: .utf8)
        installSignalHandlers(controller: controller)
        print("\(stamp()) logimap: работаю. PID \(getpid())")
        CFRunLoopRun()
    }

    static func stop() {
        if let pid = existingRunningPID() {
            kill(pid, SIGTERM)
            print("SIGTERM → pid \(pid)")
            try? FileManager.default.removeItem(atPath: pidfilePath)
            return
        }
        let plistPath = NSHomeDirectory() + "/Library/LaunchAgents/\(agentLabel).plist"
        if FileManager.default.fileExists(atPath: plistPath) {
            _ = launchctl(["bootout", "gui/\(getuid())", agentLabel])
            print("launch agent остановлен")
        } else {
            print("logimap не запущен")
        }
    }

    static func printHelp() {
        print("""
        logimap \(version) — маппер кнопок мыши Logitech G603 в модификаторы

        Команды:
          run            запустить в foreground (Ctrl-C — выход с отпусканием модификаторов)
          buttons        калибровка: показывает номера нажимаемых кнопок
          doctor         диагностика: права, конфиг, состояние
          init-config    записать пример конфига в ~/.config/logimap/config.json
          install-agent  установить LaunchAgent (автозапуск) и стартовать
          uninstall-agent удалить LaunchAgent
          restart        перезапустить агента
          stop           остановить запущенный экземпляр/агента

        Флаги:
          --config PATH  путь к конфигу (по умолчанию ~/.config/logimap/config.json)
          --no-inject    отключить подмешивание флагов модификатора в события мыши/клавиатуры
          --inject       включить (перекрывает конфиг)
        """)
    }

    private static func existingRunningPID() -> Int32? {
        guard let text = try? String(contentsOfFile: pidfilePath, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 1,
              kill(pid, 0) == 0
        else { return nil }
        return pid
    }

    private static func installSignalHandlers(controller: TapController) {
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { controller.shutdown(exitCode: 0) }
            source.resume()
            signalSources.append(source)
        }
    }
}

// MARK: - buttons (калибровка)

enum ButtonsCommand {
    static func run() {
        if !Accessibility.isTrusted(prompt: true) {
            print("Нет Accessibility-разрешения — без него события не видны. Жду…")
            while !Accessibility.isTrusted(prompt: false) {
                Thread.sleep(forTimeInterval: 1.0)
            }
        }
        let probe = ButtonProbe()
        guard probe.start() else {
            print("Не удалось создать event tap (Accessibility?)")
            exit(2)
        }
        print("Калибровка: нажимай кнопки мыши, я покажу их CG-номера. Ctrl-C — выход.")
        print("Нумерация с нуля: 0 = левая, 1 = правая, 2 = средняя, 3 = Button 4, 4 = Button 5")
        CFRunLoopRun()
    }
}

final class ButtonProbe {
    private var port: CFMachPort?

    func start() -> Bool {
        let mask: CGEventMask = (1 << CGEventType.otherMouseDown.rawValue)
            | (1 << CGEventType.otherMouseUp.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.leftMouseUp.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.rightMouseUp.rawValue)
        guard let created = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: Self.callback,
            userInfo: Unmanaged.passRetained(self).toOpaque()
        ) else { return false }
        port = created
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0) else { return false }
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, CFRunLoopMode.commonModes)
        CGEvent.tapEnable(tap: created, enable: true)
        return true
    }

    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let number = event.getIntegerValueField(.mouseEventButtonNumber)
        let isDown: Bool
        switch type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown: isDown = true
        case .leftMouseUp, .rightMouseUp, .otherMouseUp: isDown = false
        default: return Unmanaged.passUnretained(event)
        }
        let name = [0: "левая", 1: "правая", 2: "средняя"][Int(number)] ?? "боковая"
        print("\(stamp()) CG#\(number) (Button \(number + 1), \(name)) \(isDown ? "DOWN" : "UP")")
        return Unmanaged.passUnretained(event)
    }

    private static let callback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let probe = Unmanaged<ButtonProbe>.fromOpaque(userInfo).takeUnretainedValue()
        return probe.handle(type: type, event: event)
    }
}

// MARK: - doctor

enum DoctorCommand {
    static func run() {
        print("logimap \(version) doctor")
        let binary = CommandLine.arguments[0]
        print("binary: \(binary)")
        if binary.contains(".app") {
            print("  → запущен из .app: TCC-запись будет у Logimap.app")
        } else {
            print("  → запущен из терминала: TCC-запись у терминала/родителя, не у Logimap.app")
        }

        let trusted = Accessibility.isTrusted(prompt: false)
        print("accessibility (этого процесса): \(trusted ? "OK" : "НЕТ")")

        let configPath = AppConfig.defaultPath
        if FileManager.default.fileExists(atPath: configPath) {
            print("config: \(configPath)")
            if let config = try? AppConfig.load(path: configPath) {
                print("  mappings: \(config.mappings.map { "CG#\($0.button) → \($0.modifier)" }.joined(separator: ", "))")
                print("  injectFlags: \(config.injectFlags)")
            } else {
                print("  ⚠ конфиг не парсится")
            }
        } else {
            print("config: нет (\(configPath)) — будут дефолты G603: CG#3 → option, CG#4 → control")
        }

        if let pid = runningPID() {
            print("running: да, pid \(pid)")
        } else {
            print("running: нет")
        }

        let probe = ButtonProbe()
        print("event tap probe: \(probe.start() ? "OK (события доступны)" : "FAIL — нет прав у этого процесса")")
        exit(0)
    }

    private static func runningPID() -> Int32? {
        let path = RunCommand.pidfilePath
        guard let text = try? String(contentsOfFile: path, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 1, kill(pid, 0) == 0
        else { return nil }
        return pid
    }
}

// MARK: - init-config

enum InitConfigCommand {
    static func run(path: String?) throws {
        let target = path ?? AppConfig.defaultPath
        try AppConfig().writeSample(to: target)
        print("Пример конфига записан: \(target)")
        print("Правь и перезапускай: logimap restart")
    }
}

// MARK: - LaunchAgent

enum AgentCommand {
    static var plistPath: String {
        NSHomeDirectory() + "/Library/LaunchAgents/\(RunCommand.agentLabel).plist"
    }

    static func install() {
        let binary = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
        let logPath = NSHomeDirectory() + "/Library/Logs/logimap.log"
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(RunCommand.agentLabel)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(binary)</string>
                <string>run</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <false/>
            <key>ProcessType</key>
            <string>Interactive</string>
            <key>StandardOutPath</key>
            <string>\(logPath)</string>
            <key>StandardErrorPath</key>
            <string>\(logPath)</string>
        </dict>
        </plist>
        """
        let dir = (plistPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(atPath: plistPath)
        do {
            try plist.data(using: .utf8)?.write(to: URL(fileURLWithPath: plistPath))
        } catch {
            print("Не удалось записать \(plistPath): \(error)")
            exit(1)
        }
        _ = launchctl(["bootout", "gui/\(getuid())", RunCommand.agentLabel])
        let result = launchctl(["bootstrap", "gui/\(getuid())", plistPath])
        if result.code != 0 {
            print("launchctl bootstrap не удался: \(result.out)")
            exit(1)
        }
        _ = launchctl(["kickstart", "gui/\(getuid())/\(RunCommand.agentLabel)"])
        print("LaunchAgent установлен и запущен. Лог: \(logPath)")
        print("Если Accessibility ещё не разрешён — разреши Logimap в System Settings,")
        print("агент сам начнёт работать в течение секунды после разрешения.")
    }

    static func uninstall() {
        _ = launchctl(["bootout", "gui/\(getuid())", RunCommand.agentLabel])
        try? FileManager.default.removeItem(atPath: plistPath)
        try? FileManager.default.removeItem(atPath: RunCommand.pidfilePath)
        print("LaunchAgent удалён")
    }

    static func restart() {
        if !FileManager.default.fileExists(atPath: plistPath) {
            print("LaunchAgent не установлен (logimap install-agent)")
            exit(1)
        }
        let result = launchctl(["kickstart", "-k", "gui/\(getuid())/\(RunCommand.agentLabel)"])
        if result.code == 0 {
            print("Перезапущен")
        } else {
            print("kickstart не удался: \(result.out)")
            exit(1)
        }
    }
}
