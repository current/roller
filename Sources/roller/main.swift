import Foundation
import RollerCore

let usage = """
usage: roller <command>

Commands:
  status            Show whether Roller is running and managing windows
  list              Print every strip as JSON
  <action>          Run an action, e.g. `roller focus_left`

Actions:
\(Action.allCases.map { "  \($0.rawValue.padding(toLength: 22, withPad: " ", startingAt: 0))\($0.title)" }.joined(separator: "\n"))

Every action is also available as a URL: open -g roller://focus_left
"""

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else {
    print(usage)
    exit(1)
}
if command == "-h" || command == "--help" || command == "help" {
    print(usage)
    exit(0)
}
if command != "status" && command != "list" && Action(name: command) == nil {
    FileHandle.standardError.write("roller: unknown command '\(command)'\n".data(using: .utf8)!)
    exit(2)
}

do {
    let reply = try IPC.send(args.joined(separator: " "))
    let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("error:") {
        FileHandle.standardError.write((trimmed + "\n").data(using: .utf8)!)
        exit(1)
    }
    if !trimmed.isEmpty { print(trimmed) }
} catch {
    FileHandle.standardError.write("roller: \(error)\n".data(using: .utf8)!)
    exit(1)
}
