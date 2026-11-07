import Foundation

// Everything is inferred from the account gh is logged in as: no owner, org or
// team names are configured. `review-requested:@me` matches requests made to
// you and to your teams, so no team lookup is needed.

public struct SectionSpec: Sendable {
  let alias: String
  public let name: String
  let scope: String
  /// Who the section is about.
  let qualifier: String
}

/// Display order.
public let sections: [SectionSpec] = [
  SectionSpec(
    alias: "review", name: "Awaiting my review", scope: "is:open is:pr archived:false",
    qualifier: "review-requested:@me"),
  SectionSpec(
    alias: "authored", name: "My open PRs", scope: "is:open is:pr archived:false", qualifier: "author:@me"),
  SectionSpec(
    alias: "assigned", name: "Assigned to me", scope: "is:open archived:false", qualifier: "assignee:@me"),
  SectionSpec(
    alias: "personal", name: "Also in my repos", scope: "is:open archived:false", qualifier: "user:@me"),
]

public let reviewSection = 0

/// Never matches a request that reached the viewer through a team.
let directReviewQualifier = "user-review-requested:@me"

/// Makes the first page the newest activity.
let order = "sort:updated-desc"

/// Token scopes that let `organizations` include private memberships.
let orgScopes = ["read:org", "write:org", "admin:org"]

/// The search a section runs; `directOnly` narrows only the review section.
public func search(_ section: Int, directOnly: Bool) -> String {
  let spec = sections[section]
  let qualifier = section == reviewSection && directOnly ? directReviewQualifier : spec.qualifier
  return "\(spec.scope) \(qualifier) \(order)"
}

/// The same search on GitHub, for everything a section can't show.
public func searchURL(_ section: Int, host: String, directOnly: Bool) -> String {
  "https://\(host)/search?type=issues&q=\(encode(search(section, directOnly: directOnly)))"
}

/// What a section's search says about how each PR's review request reached
/// the viewer.
enum Routing {
  case notAsked, allDirect, fromRequests

  static func of(_ section: Int, directOnly: Bool) -> Routing {
    guard section == reviewSection else { return .notAsked }
    return directOnly ? .allDirect : .fromRequests
  }
}

/// Identity plus one section's newest `size` matches. Every request names
/// the viewer, so results from two accounts are never combined.
func sectionQuery(alias: String, search: String, size: Int, routing: Routing) -> String {
  let (requests, fragment) =
    routing == .fromRequests ? (" nodes { ...requests }", Queries.requests) : ("", "")
  return """
    query {
      viewer { login url }
      \(alias): search(query: "\(search)", type: ISSUE, first: \(size)) { ...items\(requests) }
    }

    \(Queries.items)\(fragment)
    """
}

/// Identity plus the check state of each PR id.
func checksQuery(_ ids: [String]) -> String {
  let encoder = JSONEncoder()
  encoder.outputFormatting = .withoutEscapingSlashes
  let list = String(decoding: (try? encoder.encode(ids)) ?? Data("[]".utf8), as: UTF8.self)
  return """
    query {
      viewer { login url }
      nodes(ids: \(list)) { __typename ...checks }
    }

    \(Queries.checks)
    """
}

/// The gh executable, variables set over the inherited environment, and how
/// long a call may take, output included.
public struct Gh: Sendable {
  var program = "gh"
  var env: [EnvVar] = []
  var timeout = Duration.seconds(30)

  /// gh as a terminal would start it, including from a Finder or Dock launch.
  public static func resolved() -> Gh {
    Gh(env: LoginEnvironment.environment())
  }

  /// The newest `size` (at most 100) matches for `sections[section]`.
  public func section(_ section: Int, size: Int, directOnly: Bool) -> SectionFetch {
    let alias = sections[section].alias
    let routing = Routing.of(section, directOnly: directOnly)
    let query = sectionQuery(
      alias: alias, search: search(section, directOnly: directOnly), size: size, routing: routing)
    switch graphql(query) {
    case .success(let output): return parseSection(alias: alias, routing: routing, output: output)
    case .failure(let error): return SectionFetch(identity: nil, page: .failure(error), warnings: [])
    }
  }

  /// Check states for up to 100 PR node ids.
  public func checks(_ ids: [String]) -> ChecksFetch {
    switch graphql(checksQuery(ids)) {
    case .success(let output): return parseChecks(ids: ids, output: output)
    case .failure(let error): return ChecksFetch(identity: nil, results: ids.map { ($0, .failure(error)) })
    }
  }

  public func membership() -> MembershipFetch {
    let unknown = MembershipFetch(identity: nil, membership: .unknown)
    guard
      case .success(let output) = run(["api", "--include", "graphql", "-f", "query=\(Queries.membership)"])
    else { return unknown }
    return parseMembership(output) ?? unknown
  }

  func graphql(_ query: String) -> Result<Output, GhError> {
    run(["api", "graphql", "-f", "query=\(query)"])
  }

  func run(_ args: [String]) -> Result<Output, GhError> {
    Result { () throws(GhError) in try capture(program, args, overlay: env, timeout: timeout) }
  }
}

/// `https://ghe.example.com/login` -> `ghe.example.com`.
func host(_ profileURL: String) -> String {
  let rest = profileURL.range(of: "://").map { profileURL[$0.upperBound...] } ?? Substring(profileURL)
  return String(rest.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first ?? rest)
}

/// Percent-encodes everything but RFC 3986 unreserved characters.
func encode(_ text: String) -> String {
  text.utf8.map { byte in
    switch byte {
    case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
      UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "-"), UInt8(ascii: "_"), UInt8(ascii: "."),
      UInt8(ascii: "~"):
      String(UnicodeScalar(byte))
    default:
      String(format: "%%%02X", byte)
    }
  }.joined()
}
