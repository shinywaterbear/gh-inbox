import Foundation

/// gh supplies only the host and token; every request then goes through
/// `GitHub`.
public struct Gh: Sendable {
  var program = "gh"
  /// Variables set over the inherited environment; nil reads the login
  /// shell's when the inherited PATH cannot find gh (`LoginEnvironment`).
  var env: [EnvVar]?
  var timeout = Duration.seconds(10)

  /// gh as a terminal would start it, including from a Finder or Dock launch.
  public static func resolved() -> Gh { Gh() }

  /// Asked every round, never cached: gh refreshes an expiring token before
  /// printing it, and a `gh auth switch` shows up on the next round.
  func credential() async -> Result<Credential, GhError> {
    await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: token()) }
    }
  }

  /// `gh auth token` follows `GH_HOST`, and prints `GH_TOKEN`,
  /// `GITHUB_TOKEN` or `GH_ENTERPRISE_TOKEN` when one applies.
  func token() -> Result<Credential, GhError> {
    let env = self.env ?? LoginEnvironment.environment()
    let host = ghHost(merged(env))
    let output: Output
    do {
      output = try capture(program, ["auth", "token", "--hostname", host], overlay: env, timeout: timeout)
    } catch {
      if case .timeout(let d) = error {
        return .failure(.gh("`gh auth token` did not finish within \(d.components.seconds)s"))
      }
      return .failure(error)
    }
    let token = String(decoding: output.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    if output.success && !token.isEmpty { return .success(Credential(host: host, token: token)) }
    let stderr = String(decoding: output.stderr, as: UTF8.self).trimmingCharacters(
      in: .whitespacesAndNewlines)
    let lower = stderr.lowercased()
    if output.success || output.status == exitAuthRequired || lower.contains("no oauth token")
      || lower.contains("not logged in")
    {
      return .failure(.notLoggedIn)
    }
    return .failure(.gh(stderr.isEmpty ? "`gh auth token` failed" : stderr))
  }
}

/// gh's host: `GH_HOST` when set, else github.com.
func ghHost(_ env: [EnvVar]) -> String {
  let value = env.last { $0.name == Array("GH_HOST".utf8) }.map { String(decoding: $0.value, as: UTF8.self) }
  let host = value?.trimmingCharacters(in: .whitespaces) ?? ""
  return host.isEmpty ? "github.com" : host
}
