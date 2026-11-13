import Foundation

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

/// Finder and the Dock start an app with launchd's minimal environment: a
/// PATH without the user's tools and none of the `GH_*` variables a shell
/// sets. When the inherited PATH cannot find gh, gh gets the login shell's
/// environment.
enum LoginEnvironment {
  static let marker = Array("\ngh-inbox-environment\n".utf8)
  /// The leading newline ends any unterminated line the rc files printed.
  static let command = "printf '\\ngh-inbox-environment\\n'; exec /usr/bin/env -0"
  static let timeout = Duration.seconds(10)

  /// Only a usable answer is kept, so a slow or broken shell is retried on
  /// the next refresh. The lock also keeps concurrent jobs to one shell.
  private static let resolved = Resolved()

  static func environment() -> [EnvVar] {
    resolved.lock.lock()
    defer { resolved.lock.unlock() }
    if let env = resolved.env { return env }
    let env: [EnvVar]
    if findsGh(merged([]).last { $0.name == Array("PATH".utf8) }?.value) {
      env = []
    } else if let vars = read(shell: shell(), timeout: timeout), findsGh(path(of: vars)) {
      env = vars
    } else {
      return []
    }
    resolved.env = env
    return env
  }

  /// For an update's build, always the login shell's, read afresh: a
  /// toolchain is usually first on PATH only once the shell's profile has
  /// run, whether or not the inherited PATH finds gh. Nothing over the
  /// inherited environment when the shell can't be read.
  static func forBuild() -> [EnvVar] {
    read(shell: shell(), timeout: timeout) ?? []
  }

  /// The account's shell, which a Finder launch does not export as `$SHELL`.
  static func shell() -> String {
    if let record = getpwuid(getuid()), let shell = record.pointee.pw_shell {
      let path = String(cString: shell)
      if !path.isEmpty { return path }
    }
    return "/bin/zsh"
  }

  /// Interactive as well as login, since zsh users set PATH in `.zshrc`.
  static func read(shell: String, timeout: Duration) -> [EnvVar]? {
    guard let output = try? capture(shell, ["-l", "-i", "-c", command], timeout: timeout),
      output.success
    else { return nil }
    return parse(output.stdout)
  }

  /// What `env -0` printed after the marker. A segment not ended by NUL is
  /// whatever the shell printed after env, not a variable.
  static func parse(_ stdout: [UInt8]) -> [EnvVar]? {
    guard let start = stdout.firstRange(of: marker)?.upperBound else { return nil }
    var entries = stdout[start...].split(separator: 0, omittingEmptySubsequences: false)
    entries.removeLast()
    return entries.compactMap { entry in
      guard let eq = entry.firstIndex(of: UInt8(ascii: "=")), eq > entry.startIndex else { return nil }
      return EnvVar(Array(entry[..<eq]), Array(entry[(eq + 1)...]))
    }
  }

  static func path(of vars: [EnvVar]) -> [UInt8]? {
    vars.first { $0.name == Array("PATH".utf8) }?.value
  }

  static func findsGh(_ path: [UInt8]?) -> Bool {
    guard let path else { return false }
    return directories(path).contains { isExecutableFile($0 + "/gh") }
  }

  private final class Resolved: @unchecked Sendable {
    let lock = NSLock()
    var env: [EnvVar]?
  }
}
