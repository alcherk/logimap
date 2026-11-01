import Foundation

let version = "1.0.0"
let allArgs = Array(CommandLine.arguments.dropFirst())
let command = allArgs.first ?? "help"
var rest = Array(allArgs.dropFirst())

var configPath: String?
var injectOverride: Bool?

func parseRest() {
    var i = 0
    while i < rest.count {
        switch rest[i] {
        case "--config":
            i += 1
            if i < rest.count { configPath = rest[i] }
        case "--no-inject":
            injectOverride = false
        case "--inject":
            injectOverride = true
        default:
            break
        }
        i += 1
    }
}
parseRest()

func logHead() {
    print("logimap \(version) — Logitech G603 button → modifier mapper")
}

do {
    switch command {
    case "run":
        try RunCommand.run(configPath: configPath, injectOverride: injectOverride)
    case "buttons":
        ButtonsCommand.run()
    case "doctor":
        DoctorCommand.run()
    case "init-config":
        try InitConfigCommand.run(path: configPath)
    case "install-agent":
        AgentCommand.install()
    case "uninstall-agent":
        AgentCommand.uninstall()
    case "restart":
        AgentCommand.restart()
    case "stop":
        RunCommand.stop()
    case "help", "--help", "-h", "":
        RunCommand.printHelp()
    default:
        print("Неизвестная команда: \(command)")
        RunCommand.printHelp()
        exit(64)
    }
} catch {
    FileHandle.standardError.write(("Ошибка: \(error.localizedDescription)\n").data(using: .utf8)!)
    exit(1)
}
