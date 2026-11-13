import AppKit
import GhInboxCore

switch command(Array(CommandLine.arguments.dropFirst())) {
case .window:
  let app = NSApplication.shared
  let delegate = AppDelegate()
  app.delegate = delegate
  app.setActivationPolicy(.regular)
  app.run()
case .help:
  print(usage)
case .json(let queue, let limit):
  exit(runJSON(queue: queue, limit: limit))
case .invalid(let message):
  FileHandle.standardError.write(Data("gh-inbox: \(message)\nRun `gh-inbox --help` for usage.\n".utf8))
  exit(2)
}
