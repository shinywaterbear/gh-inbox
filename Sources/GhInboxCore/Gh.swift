import Foundation

// Everything is inferred from the account gh is logged in as: no owner, org or
// team names are configured. `review-requested:@me` matches requests made to
// you and to your teams, so no team lookup is needed.

public struct SectionSpec: Sendable {
  let alias: String
  /// The queue's name on the command line (`--queue`), kept stable for scripts.
  public let key: String
  public let name: String
  /// The sidebar heading the queue sits under.
  public let group: String
  /// What the queue holds, for `--help`.
  public let about: String
  /// What an empty queue says.
  public let empty: String
  let scope: String
  /// Who the section is about.
  let qualifier: String
  var ranking = Ranking.attention
  var routing = Routing.notAsked
  /// The queue it shows in, by key, when it isn't a queue of its own.
  var shownIn: String?
  /// Its group's heading in a queue it shares.
  var part: String?
}

/// Display order, which is also priority: an item shows in the first queue
/// that has it.
public let sections: [SectionSpec] = [
  // Any review, even a comment, ends the request it answers, and an author
  // may ask again without re-requesting, so no request remains to find. `Routing.returned`
  // decides; `-review:approved` saves page space by dropping PRs GitHub's
  // review decision approved, which can omit a change request that doesn't
  // count toward that decision.
  SectionSpec(
    alias: "back", key: "back-to-me", name: "Back to me", group: "Review",
    about: "PRs you reviewed, not approved, that the author has pushed to since",
    empty: "Nothing you reviewed has been pushed since.",
    scope: "is:open is:pr", qualifier: "reviewed-by:@me -author:@me -review:approved",
    routing: .returned, shownIn: "asked-of-me", part: "Pushed since your review"),
  // GitHub matches `user-review-requested` only against the viewer by name.
  SectionSpec(
    alias: "direct", key: "asked-of-me", name: "Asked of me", group: "Review",
    about:
      "PRs you reviewed, not approved, that the author has pushed to since, then PRs whose review is requested of you by name",
    empty: "No one has asked you by name, and nothing you reviewed has been pushed since.",
    scope: "is:open is:pr", qualifier: "user-review-requested:@me", routing: .allDirect, part: "Requested"),
  // script/check-review-split found it disjoint from the queue above and,
  // with it, equal to `review-requested:@me` on a busy work account. If it
  // ever misbehaves, plain `review-requested:@me` works too: a PR also
  // asked by name shows only in the queue above.
  SectionSpec(
    alias: "team", key: "via-my-teams", name: "Via my teams", group: "Review",
    about: "PRs whose review is requested of a team you are on", empty: "Nothing waiting on your teams.",
    scope: "is:open is:pr", qualifier: "review-requested:@me -user-review-requested:@me",
    routing: .fromRequests),
  SectionSpec(
    alias: "authored", key: "my-open-prs", name: "My open PRs", group: "Mine", about: "PRs you opened",
    empty: "You have no open PRs.",
    scope: "is:open is:pr", qualifier: "author:@me", ranking: .merge),
  SectionSpec(
    alias: "assigned", key: "assigned-to-me", name: "Assigned to me", group: "Mine",
    about: "Issues and PRs assigned to you", empty: "Nothing is assigned to you.",
    scope: "is:open", qualifier: "assignee:@me"),
  SectionSpec(
    alias: "personal", key: "also-in-my-repos", name: "Also in my repos", group: "Mine",
    about: "Anything else open in repositories you own", empty: "Nothing else is open in your repos.",
    scope: "is:open", qualifier: "user:@me"),
]

/// Requests through teams, hidden when the account can't be on one.
public let teamSection = 2

/// The window's queues, each by its own section: every section not shown
/// in another's queue.
public let queueSections = sections.indices.filter { sections[$0].shownIn == nil }

/// The sections a queue lists, in order: those shown in it, then its own.
public func members(_ queue: Int) -> [Int] {
  sections.indices.filter { $0 == queue || sections[$0].shownIn == sections[queue].key }
}

/// The queue that lists a section.
public func queue(of section: Int) -> Int {
  guard let key = sections[section].shownIn else { return section }
  return sections.firstIndex { $0.key == key } ?? section
}

/// Makes the first page the newest activity.
let order = "sort:updated-desc"

/// Token scopes that let `organizations` include private memberships.
let orgScopes = ["read:org", "write:org", "admin:org"]

/// Leaves out archived repositories. The API takes it; GitHub's web search
/// rejects it, so the web link goes without.
let notArchived = "archived:false"

/// The search a section runs.
public func search(_ section: Int) -> String {
  let spec = sections[section]
  return "\(spec.scope) \(notArchived) \(spec.qualifier) \(order)"
}

/// The same search on GitHub, for everything a section can't show; it may
/// also list items in archived repositories. The web search keeps PRs
/// apart from issues and rejects `is:pr` among issues, so a PR queue opens
/// as a pull-request search.
public func searchURL(_ section: Int, host: String) -> String {
  let spec = sections[section]
  let terms = spec.scope.split(separator: " ")
  let pullRequests = terms.contains("is:pr")
  let scope = terms.filter { $0 != "is:pr" }.joined(separator: " ")
  let type = pullRequests ? "pullrequests" : "issues"
  return "https://\(host)/search?type=\(type)&q=\(encode("\(scope) \(spec.qualifier) \(order)"))"
}

/// What a section's search says about how each PR's review request reached
/// the viewer.
enum Routing: Sendable {
  case notAsked, allDirect, fromRequests
  /// Keeps only PRs whose author pushed since the viewer requested changes.
  case returned
}

/// Identity plus one section's newest `size` matches. Every request names
/// the viewer, so results from two accounts are never combined.
func sectionQuery(alias: String, search: String, size: Int, routing: Routing) -> String {
  let (requests, fragment) =
    switch routing {
    case .fromRequests: (" nodes { ...requests }", Queries.requests)
    case .returned: (" nodes { ...returned }", Queries.returned)
    case .notAsked, .allDirect: ("", "")
    }
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

extension GitHub {
  /// The newest `size` (at most 100) matches for `sections[section]`.
  func section(_ section: Int, size: Int, as credential: Credential) async -> SectionFetch {
    let alias = sections[section].alias
    let routing = sections[section].routing
    let query = sectionQuery(alias: alias, search: search(section), size: size, routing: routing)
    switch await graphql(query, as: credential) {
    case .success(let reply): return parseSection(alias: alias, routing: routing, reply: reply)
    case .failure(let error): return SectionFetch(identity: nil, page: .failure(error), warnings: [])
    }
  }

  /// Check states for up to 100 PR node ids.
  func checks(_ ids: [String], as credential: Credential) async -> ChecksFetch {
    switch await graphql(checksQuery(ids), as: credential) {
    case .success(let reply): return parseChecks(ids: ids, reply: reply)
    case .failure(let error): return ChecksFetch(identity: nil, results: ids.map { ($0, .failure(error)) })
    }
  }

  func membership(as credential: Credential) async -> MembershipFetch {
    guard case .success(let reply) = await graphql(Queries.membership, as: credential) else {
      return MembershipFetch(identity: nil, membership: .unknown)
    }
    return parseMembership(reply)
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
