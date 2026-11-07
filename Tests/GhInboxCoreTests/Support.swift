import Foundation

@testable import GhInboxCore

let recorded = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
  .deletingLastPathComponent().appendingPathComponent("mocks/graphql.json").path

func scratch(_ name: String) -> URL {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
    "gh-inbox-\(ProcessInfo.processInfo.processIdentifier)-\(name)-\(UUID().uuidString)")
  try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  return dir
}

func executable(_ path: URL, _ text: String) {
  try! text.write(to: path, atomically: true, encoding: .utf8)
  chmod(path.path, 0o755)
}

/// A fake gh running `body` as a bash script.
func fakeGh(_ name: String, _ body: String, in dir: URL? = nil) -> Gh {
  let path = (dir ?? scratch(name)).appendingPathComponent("gh")
  executable(path, "#!/usr/bin/env bash\n\(body)\n")
  return Gh(program: path.path, timeout: .seconds(10))
}

/// A fake gh that prints `json` and exits with `code`, as gh does for GraphQL errors.
func responding(_ name: String, _ json: JSON, _ code: Int) -> Gh {
  let dir = scratch(name)
  let file = dir.appendingPathComponent("response.json")
  try! json.text.write(to: file, atomically: true, encoding: .utf8)
  return fakeGh(name, "cat '\(file.path)'\nexit \(code)", in: dir)
}

/// The case name of an error with a payload, for matching any payload.
func kind(_ error: GhError?) -> String? {
  error.flatMap { Mirror(reflecting: $0).children.first?.label }
}

extension Result {
  var failure: Failure? {
    if case .failure(let error) = self { return error }
    return nil
  }

  var success: Success? {
    if case .success(let value) = self { return value }
    return nil
  }
}
