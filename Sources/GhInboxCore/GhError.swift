/// gh's documented exit status when it has no credentials.
let exitAuthRequired: Int32 = 4

/// GitHub's wording when a request outran its processing deadline, which it
/// may also answer with a bare 502 or 504.
let serverMarkers = [
  "http 502", "http 503", "http 504", "502 bad gateway", "503 service unavailable", "504 gateway timeout",
  "this may be the result of a timeout",
]

public enum GhError: Error, Equatable, Sendable, CustomStringConvertible {
  case notInstalled
  case notLoggedIn
  case badCredentials(String)
  case forbidden(String)
  case ipRestricted(String)
  case server(String)
  case rateLimited(String)
  case network(String)
  case timeout(Duration)
  case spawn(String)
  /// gh could not supply a token.
  case gh(String)
  /// A GitHub error none of the cases above describe.
  case github(String)
  case parse(String)
  case withheld(Int)
  case unreadable(Int)
  case otherCommit
  /// The request was abandoned, as after an account change.
  case cancelled

  public var description: String {
    switch self {
    case .notInstalled: "gh is not installed or not on PATH"
    case .notLoggedIn: "gh is not logged in"
    case .badCredentials(let m): "gh's token was rejected: \(m)"
    case .forbidden(let m): "GitHub denied access: \(m)"
    case .ipRestricted(let m): "GitHub refused this network: \(m)"
    case .server(let m): "GitHub had a server error: \(m)"
    case .rateLimited(let m): "GitHub rate limit reached: \(m)"
    case .network(let m): "could not reach GitHub: \(m)"
    case .timeout(let d): "GitHub did not answer within \(d.components.seconds)s"
    case .spawn(let m): "could not run gh: \(m)"
    case .gh(let m): "gh failed: \(m)"
    case .github(let m): "GitHub reported an error: \(m)"
    case .parse(let m): "unexpected response from GitHub: \(m)"
    case .withheld(let n): "GitHub withheld \(counted(n, "item")), usually because of SSO"
    case .unreadable(let n): "\(counted(n, "item")) could not be read"
    case .otherCommit: "GitHub's checks describe a different commit than the list"
    case .cancelled: "the request was cancelled"
    }
  }

  public var hint: String? {
    switch self {
    case .notInstalled:
      "Install the GitHub CLI and put it on your login shell's PATH, then refresh."
    case .notLoggedIn: "Run `gh auth login`, then refresh."
    case .badCredentials: "Run `gh auth login` to replace the token."
    case .forbidden, .withheld:
      "Check `gh auth status`: classic/OAuth tokens need `repo` for private repositories "
        + "and `read:org` for organization/team access. SSO organizations may require token "
        + "authorization. If using `GH_TOKEN` or `GITHUB_TOKEN`, check that token instead."
    case .ipRestricted:
      "Connect to a network the organization allows, such as its VPN, then refresh."
    case .server: "Usually temporary or a slow query; refresh to retry, or load fewer results."
    case .rateLimited: "Wait a minute, then refresh."
    case .network, .timeout: "Check the network or proxy, then refresh."
    case .otherCommit: "The PR probably changed between requests; refresh."
    case .spawn, .gh, .github, .parse, .unreadable, .cancelled: nil
    }
  }

  /// The error and its hint as sentences. GitHub's messages often end in a
  /// period already.
  public var described: String {
    var text = Substring(description)
    while text.hasSuffix(".") { text = text.dropLast() }
    return hint.map { "\(text). \($0)" } ?? "\(text)."
  }

  /// `kind` is a GraphQL error's `type`, when the error came in a response.
  static func classify(kind: String?, message: String) -> GhError {
    let message = message.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    let lower = String(
      String.UnicodeScalarView(
        message.unicodeScalars.map { ("A"..."Z").contains($0) ? Unicode.Scalar($0.value + 32)! : $0 }))
    if kind == "RATE_LIMITED" || lower.contains("rate limit") || lower.contains("http 429") {
      return .rateLimited(message)
    } else if lower.contains("http 401") || lower.contains("401 unauthorized") {
      return .badCredentials(message)
    } else if lower.contains("ip allow list") {
      return .ipRestricted(message)
    } else if kind == "FORBIDDEN" || lower.contains("http 403") || lower.contains("403 forbidden")
      || lower.contains("saml")
    {
      return .forbidden(message)
    } else if serverMarkers.contains(where: lower.contains) {
      return .server(message)
    }
    return .github(message)
  }
}
