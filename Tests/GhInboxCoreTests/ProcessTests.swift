import Foundation
import Testing

@testable import GhInboxCore

/// A stand-in login shell: `body`, then the command it was given (`-l -i -c COMMAND`).
private func fakeShell(_ name: String, _ body: String) -> String {
  let path = scratch(name).appendingPathComponent("shell")
  executable(path, "#!/usr/bin/env bash\n\(body)\nexec /bin/sh -c \"$4\"\n")
  return path.path
}

private func variable(_ vars: [EnvVar], _ key: String) -> String? {
  vars.first { $0.name == Array(key.utf8) }.map { String(decoding: $0.value, as: UTF8.self) }
}

struct LoginEnvironmentTests {
  @Test func loginEnvironmentIsReadPastRcOutput() throws {
    let shell = fakeShell(
      "login-shell", "printf 'welcome, no newline'\nexport GH_HOST=example.test\nexport MULTI=$'two\\nlines'")
    let vars = try #require(LoginEnvironment.read(shell: shell, timeout: .seconds(10)))
    #expect(variable(vars, "GH_HOST") == "example.test")
    #expect(variable(vars, "MULTI") == "two\nlines")
    #expect(variable(vars, "PATH") != nil)
  }

  @Test func loginEnvironmentDropsOutputAfterEnv() {
    let parsed = LoginEnvironment.parse(Array("rc\ngh-inbox-environment\nA=1\0B=x=y\0junk".utf8))
    #expect(parsed == [EnvVar(Array("A".utf8), Array("1".utf8)), EnvVar(Array("B".utf8), Array("x=y".utf8))])
    #expect(LoginEnvironment.parse(Array("A=1\0".utf8)) == nil)
  }

  @Test func aHungOrFailingLoginShellGivesNothing() {
    #expect(
      LoginEnvironment.read(shell: fakeShell("hung-shell", "sleep 30"), timeout: .milliseconds(300)) == nil)
    #expect(LoginEnvironment.read(shell: fakeShell("failing-shell", "exit 1"), timeout: .seconds(10)) == nil)
  }

  @Test func findsGhOnlyAsAnExecutableFile() throws {
    let dir = scratch("path-lookup")
    let path = Array(dir.path.utf8)
    let gh = dir.appendingPathComponent("gh")
    #expect(!LoginEnvironment.findsGh(path))
    try "".write(to: gh, atomically: true, encoding: .utf8)
    #expect(!LoginEnvironment.findsGh(path))
    chmod(gh.path, 0o755)
    #expect(LoginEnvironment.findsGh(path))
  }
}

struct CaptureTests {
  @Test func largeOutputOnBothPipesDoesNotDeadlock() throws {
    let gh = fakeGh("large", "head -c 2000000 /dev/zero; head -c 2000000 /dev/zero >&2")
    let output = try capture(gh.program, [], timeout: .seconds(10))
    #expect(output.stdout.count == 2_000_000 && output.stderr.count == 2_000_000)
  }

  @Test func aTimeoutKillsTheWholeProcessGroup() throws {
    let marker = scratch("group").appendingPathComponent("survived").path
    let gh = fakeGh("group-kill", "(sleep 2; touch '\(marker)') &\nexit 0")
    #expect(throws: GhError.self) { try capture(gh.program, [], timeout: .milliseconds(300)) }
    Thread.sleep(forTimeInterval: 2.5)
    #expect(!FileManager.default.fileExists(atPath: marker), "the background child was killed")
  }

  @Test func environmentBytesPassThroughUnchanged() throws {
    let gh = fakeGh("bytes", "printf '%s' \"$WEIRD\"")
    let weird: [UInt8] = [0xff, 0xfe, 0x41]
    let output = try capture(
      gh.program, [], overlay: [EnvVar(Array("WEIRD".utf8), weird)], timeout: .seconds(5))
    #expect(output.stdout == weird)
  }

  @Test func ghIsFoundOnTheChildsPath() throws {
    let dir = scratch("child-path")
    _ = fakeGh("child-path", "echo found", in: dir)
    let path = EnvVar(Array("PATH".utf8), Array("\(dir.path):/usr/bin:/bin".utf8))
    let output = try capture("gh", [], overlay: [path], timeout: .seconds(5))
    #expect(output.stdout == Array("found\n".utf8))
  }

  @Test func ghMissingFromThePathIsNotInstalled() {
    let path = EnvVar(Array("PATH".utf8), Array("/nonexistent".utf8))
    #expect(throws: GhError.notInstalled) { try capture("gh", [], overlay: [path], timeout: .seconds(1)) }
  }
}
