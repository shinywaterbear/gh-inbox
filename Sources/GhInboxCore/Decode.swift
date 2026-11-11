import Foundation

struct Response: Decodable {
  var data: [String: JSON]?
  var errors: [GraphQLError]?
}

struct Viewer: Decodable {
  var login: String
  var url: String
}

struct GraphQLError: Decodable {
  var kind: String?
  var message: String
  var path: [JSON]?

  enum CodingKeys: String, CodingKey {
    case kind = "type"
    case message, path
  }

  var error: GhError { .classify(kind: kind, message: message) }

  /// Whether the path starts with `key`, then `index` when given.
  func within(_ key: String, _ index: Int? = nil) -> Bool {
    let path = path ?? []
    guard path.first?.string == key else { return false }
    guard let index else { return true }
    return path.count > 1 && path[1].unsigned == index
  }
}

/// A response that names its viewer.
struct Answered {
  var identity: Identity
  var data: [String: JSON]
  var errors: [GraphQLError]
}

/// A response's data and errors, or why there is no usable response. A
/// failing status may still carry GraphQL data, so the body is read either way.
func decodeResponse(_ reply: Reply) -> Result<Answered, GhError> {
  let response: Response
  do {
    response = try JSONDecoder().decode(Response.self, from: reply.body)
  } catch {
    guard reply.success else { return .failure(reply.failure) }
    let reason = (error as? DecodingError).map(describe) ?? String(describing: error)
    return .failure(.parse(reason))
  }
  let errors = response.errors ?? []
  let firstError = {
    errors.first?.error ?? (reply.success ? .parse("no data in the response") : reply.failure)
  }
  guard var data = response.data else { return .failure(firstError()) }
  guard let viewer = try? data.removeValue(forKey: "viewer")?.decode(Viewer.self) else {
    return .failure(firstError())
  }
  return .success(
    Answered(identity: Identity(login: viewer.login, host: host(viewer.url)), data: data, errors: errors))
}

/// Each item is decoded separately so one bad value costs only itself.
/// Errors elsewhere in the response belong to this section too: it is the
/// only thing the request asked for besides the viewer.
func parseSection(alias: String, routing: Routing, reply: Reply) -> SectionFetch {
  let answered: Answered
  switch decodeResponse(reply) {
  case .success(let a): answered = a
  case .failure(let error): return SectionFetch(identity: nil, page: .failure(error), warnings: [])
  }
  var warnings: [GhError] = []
  for error in answered.errors.map(\.error) where !warnings.contains(error) {
    warnings.append(error)
  }
  let page: Result<Page, GhError>
  switch decodeSection(answered.data[alias] ?? .null, viewer: answered.identity.login, routing: routing) {
  case .success(let decoded):
    if decoded.withheld > 0 && warnings.isEmpty { warnings.append(.withheld(decoded.withheld)) }
    if decoded.unreadable > 0 { warnings.append(.unreadable(decoded.unreadable)) }
    var items = decoded.items
    rank(&items, by: sections.first { $0.alias == alias }?.ranking ?? .attention)
    page = .success(
      Page(
        items: items, total: decoded.total, truncated: decoded.truncated, returned: decoded.returned,
        waiting: decoded.waiting))
  case .failure(let problem):
    page = .failure(warnings.isEmpty ? problem : warnings.removeFirst())
  }
  return SectionFetch(identity: answered.identity, page: page, warnings: warnings)
}

/// An empty list is conclusive only from a token whose `X-OAuth-Scopes`
/// let it see private memberships.
func parseMembership(_ reply: Reply) -> MembershipFetch {
  guard case .success(var answered) = decodeResponse(reply) else {
    return MembershipFetch(identity: nil, membership: .unknown)
  }
  let scopes = reply.scopes?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
  let count = answered.data.removeValue(forKey: "memberships")?["organizations"]["totalCount"].unsigned
  let seesPrivate = scopes?.contains { orgScopes.contains($0) } ?? false
  let membership: Membership =
    switch count {
    case .some(let n) where n > 0: .member
    case .some(0) where answered.errors.isEmpty && seesPrivate: .none
    default: .unknown
    }
  return MembershipFetch(identity: answered.identity, membership: membership)
}

/// Every requested id gets an answer: its state, the error GitHub gave for
/// it, or why it is missing.
func parseChecks(ids: [String], reply: Reply) -> ChecksFetch {
  let all = { (error: GhError) in ids.map { (id: $0, result: Result<CheckState, GhError>.failure(error)) } }
  let answered: Answered
  switch decodeResponse(reply) {
  case .success(let a): answered = a
  case .failure(let error): return ChecksFetch(identity: nil, results: all(error))
  }
  guard case .array(let nodes) = answered.data["nodes"] else {
    let error = answered.errors.first?.error ?? .parse("no nodes in the response")
    return ChecksFetch(identity: answered.identity, results: all(error))
  }
  let unscoped = answered.errors.first { !$0.within("nodes") }
  let results = ids.enumerated().map { i, id -> (id: String, result: Result<CheckState, GhError>) in
    if let own = answered.errors.first(where: { $0.within("nodes", i) }) {
      return (id, .failure(own.error))
    }
    guard i < nodes.count, !nodes[i].isNull else {
      return (id, .failure(unscoped?.error ?? .withheld(1)))
    }
    guard let node = try? nodes[i].decode(ChecksNode.self), node.id == id else {
      return (id, .failure(.unreadable(1)))
    }
    return (id, .success(node.state))
  }
  return ChecksFetch(identity: answered.identity, results: results)
}

struct Decoded {
  var items: [Item] = []
  var total: Int
  var truncated: Bool
  var returned: Int
  var withheld = 0
  var unreadable = 0
  var waiting = 0
}

func decodeSection(_ value: JSON, viewer: String, routing: Routing) -> Result<Decoded, GhError> {
  if value.isNull { return .failure(.github("GitHub returned no results for this section")) }
  let connection: Connection
  do { connection = try value.decode(Connection.self) } catch { return .failure(error) }
  var decoded = Decoded(
    total: connection.issueCount, truncated: connection.pageInfo.hasNextPage,
    returned: connection.nodes.count)
  for node in connection.nodes {
    if node.isNull {
      decoded.withheld += 1
    } else if let node = try? node.decode(Node.self) {
      switch node.sentBack(viewer: viewer, routing: routing) {
      case true?: break
      case false?:
        decoded.waiting += 1
        continue
      case nil:
        decoded.unreadable += 1
        continue
      }
      if let item = node.item(viewer: viewer, routing: routing) { decoded.items.append(item) }
    } else {
      decoded.unreadable += 1
    }
  }
  return .success(decoded)
}

struct Connection: Decodable {
  var issueCount: Int
  var pageInfo: PageInfo
  /// `null` entries are items the token may not see, e.g. behind SSO.
  var nodes: [JSON]
}

struct PageInfo: Decodable {
  var hasNextPage: Bool
}

struct Login: Decodable {
  var login: String
}

struct Nodes<T: Decodable>: Decodable {
  var nodes: [T?]
}

/// Deleted accounts come back as a null author.
let ghost = "ghost"

enum Node: Decodable {
  case pullRequest(PullRequestNode)
  case issue(IssueNode)
  case other

  enum CodingKeys: String, CodingKey {
    case typename = "__typename"
  }

  init(from decoder: Decoder) throws {
    switch try decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .typename) {
    case "PullRequest": self = .pullRequest(try PullRequestNode(from: decoder))
    case "Issue": self = .issue(try IssueNode(from: decoder))
    default: self = .other
    }
  }

  /// For `Routing.returned`, whether the viewer's latest opinion requested
  /// changes on an older commit than the head; nil when the opinions came
  /// back incomplete without it. Always true for other routings.
  func sentBack(viewer: String, routing: Routing) -> Bool? {
    guard routing == .returned else { return true }
    guard case .pullRequest(let pr) = self, let opinions = pr.opinions else { return nil }
    let nodes = opinions.nodes.compactMap { $0 }
    guard let mine = nodes.first(where: { $0.author?.login == viewer }) else {
      let complete = !opinions.pageInfo.hasNextPage && nodes.count == opinions.nodes.count
      return complete ? false : nil
    }
    guard mine.state == "CHANGES_REQUESTED" else { return false }
    return mine.commit?.oid != pr.headRefOid
  }

  func item(viewer: String, routing: Routing) -> Item? {
    switch self {
    case .pullRequest(let pr):
      // A null opinion is one GitHub withheld, so as unknown as a further page.
      let latest = pr.latestOpinionatedReviews?.nodes.compactMap { $0?.state } ?? []
      let complete =
        pr.latestOpinionatedReviews.map { !$0.pageInfo.hasNextPage && $0.nodes.allSatisfy { $0 != nil } }
        ?? false
      let route: ReviewRoute? =
        switch routing {
        case .notAsked: nil
        case .allDirect: .direct
        case .fromRequests: reviewRoute(pr.reviewRequests, viewer: viewer)
        case .returned: .returned
        }
      return Item(
        id: pr.id, number: pr.number, title: pr.title, repository: pr.repository, isPullRequest: true,
        isDraft: pr.isDraft, head: pr.headRefOid,
        review: GhInboxCore.review(decision: pr.reviewDecision, latest: latest, complete: complete),
        reviewRoute: route, url: pr.url, updatedAt: pr.updatedAt, author: pr.author?.login ?? ghost)
    case .issue(let issue):
      return Item(
        id: issue.id, number: issue.number, title: issue.title, repository: issue.repository,
        isPullRequest: false, isDraft: false, head: nil, review: nil, reviewRoute: nil, url: issue.url,
        updatedAt: issue.updatedAt, author: issue.author?.login ?? ghost)
    case .other:
      return nil
    }
  }
}

struct PullRequestNode: Decodable {
  var id: String
  var number: Int
  var title: String
  var url: String
  var updatedAt: String
  var isDraft: Bool
  var reviewDecision: String?
  var headRefOid: String
  var author: Login?
  var repository: Repository
  var latestOpinionatedReviews: Reviews?
  var reviewRequests: ReviewRequests?
  var opinions: Opinions?
}

struct IssueNode: Decodable {
  var id: String
  var number: Int
  var title: String
  var url: String
  var updatedAt: String
  var author: Login?
  var repository: Repository
}

struct Reviews: Decodable {
  var pageInfo: PageInfo
  var nodes: [ReviewNode?]
}

struct ReviewNode: Decodable {
  var state: String
}

struct Opinions: Decodable {
  var pageInfo: PageInfo
  var nodes: [Opinion?]
}

struct Opinion: Decodable {
  var state: String
  var author: Login?
  /// Null when the commit is gone, e.g. after a force push: not the head.
  var commit: Oid?
}

struct Oid: Decodable {
  var oid: String
}

struct ReviewRequests: Decodable {
  var pageInfo: PageInfo
  var nodes: [ReviewRequestNode?]
}

struct ReviewRequestNode: Decodable {
  var requestedReviewer: RequestedReviewer?
}

enum RequestedReviewer: Decodable {
  /// A user, bot or mannequin: anything that can be the viewer.
  case actor(login: String)
  case team(name: String)
  case other

  enum CodingKeys: String, CodingKey {
    case typename = "__typename"
    case login, name
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    switch try c.decode(String.self, forKey: .typename) {
    case "User", "Bot", "Mannequin": self = .actor(login: try c.decode(String.self, forKey: .login))
    case "Team": self = .team(name: try c.decode(String.self, forKey: .name))
    default: self = .other
    }
  }
}

/// A direct request settles it even on a partial list; anything else needs
/// the whole list, since a missing entry could be the viewer.
func reviewRoute(_ requests: ReviewRequests?, viewer: String) -> ReviewRoute {
  guard let requests else { return .unknown }
  var complete = !requests.pageInfo.hasNextPage
  var teams: [String] = []
  for reviewer in requests.nodes.map({ $0?.requestedReviewer }) {
    switch reviewer {
    case .actor(let login) where login == viewer: return .direct
    case .actor: break
    case .team(let name): teams.append(name)
    case .other, nil: complete = false
    }
  }
  guard complete else { return .unknown }
  switch teams.count {
  case 0: return .unknown
  case 1: return .team(teams[0])
  default: return .someTeam
  }
}

struct ChecksNode: Decodable {
  var id: String
  var headRefOid: String
  var commits: Nodes<CommitNode>
  var potentialMergeCommit: Commit?
  var baseRef: BaseRef?

  /// The rollup of the commit GitHub requires to pass (the test merge commit
  /// when it has a status, else the head), except that a required check
  /// absent from its complete list keeps it pending; a failure wins.
  var state: CheckState {
    let head = commits.nodes.compactMap { $0 }.first?.commit.statusCheckRollup
    let rollup = potentialMergeCommit?.statusCheckRollup ?? head
    let reported = rollup.flatMap { GhInboxCore.checks($0.state) }
    let ran: [String]? = rollup.map { $0.contexts?.complete } ?? []
    let required = baseRef?.required ?? []
    let awaited = ran.map { ran in required.contains { !ran.contains($0) } } ?? false
    let checks: Checks? = reported == .failing ? reported : awaited ? .pending : reported
    return CheckState(head: headRefOid, checks: checks)
  }
}

struct CommitNode: Decodable {
  var commit: Commit
}

struct Commit: Decodable {
  var statusCheckRollup: Rollup?
}

struct Rollup: Decodable {
  var state: String
  var contexts: Contexts?
}

struct Contexts: Decodable {
  var totalCount: Int
  var nodes: [Context?]

  /// Every reported check's name, or nil when some went unread.
  var complete: [String]? {
    let names = nodes.compactMap { $0 }.compactMap { $0.name ?? $0.context }
    return names.count == totalCount ? names : nil
  }
}

struct Context: Decodable {
  /// A check run's.
  var name: String?
  /// A commit status's.
  var context: String?
}

struct BaseRef: Decodable {
  var branchProtectionRule: ProtectionRule?
  var rules: Nodes<Rule>?

  /// Required check names from branch protection and rulesets alike.
  var required: [String] {
    let classic = branchProtectionRule?.requiredStatusCheckContexts ?? []
    let rulesets = (rules?.nodes ?? []).compactMap { $0?.parameters?.requiredStatusChecks }.joined().map(
      \.context)
    return classic + rulesets
  }
}

struct ProtectionRule: Decodable {
  var requiredStatusCheckContexts: [String]?
}

struct Rule: Decodable {
  var parameters: RuleParameters?
}

struct RuleParameters: Decodable {
  var requiredStatusChecks: [RequiredCheck]?
}

struct RequiredCheck: Decodable {
  var context: String
}

/// GitHub's StatusState values.
func checks(_ state: String) -> Checks? {
  switch state {
  case "SUCCESS": .passing
  case "FAILURE", "ERROR": .failing
  case "PENDING", "EXPECTED": .pending
  default: nil
  }
}

/// The branch rule's decision when there is one, else the reviewers' latest
/// opinions. A change request anywhere is outstanding; approval is claimed
/// only when every reviewer's opinion was fetched (`complete`).
func review(decision: String?, latest: [String], complete: Bool) -> Review? {
  switch decision {
  case "APPROVED": return .approved
  case "CHANGES_REQUESTED": return .changesRequested
  case "REVIEW_REQUIRED": return .required
  default: break
  }
  if latest.contains("CHANGES_REQUESTED") { return .changesRequested }
  if complete && latest.contains("APPROVED") { return .approved }
  return nil
}
