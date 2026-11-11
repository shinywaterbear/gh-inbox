public enum Checks: Sendable, Equatable {
  case passing, failing, pending
}

public enum Review: Sendable, Equatable {
  case approved, changesRequested, required
}

/// A team is named only when it is the one request that can explain the
/// match; anything withheld or cut off leaves the route unknown.
public enum ReviewRoute: Sendable, Equatable {
  case direct
  case team(String)
  /// One of several requested teams, unknown which.
  case someTeam
  case unknown
  /// Not a request: the author pushed since the viewer requested changes.
  case returned
}

public enum OwnerKind: Sendable, Hashable {
  case personal, organization, unknown
}

public struct Owner: Sendable, Equatable, Decodable {
  var typename: String

  enum CodingKeys: String, CodingKey {
    case typename = "__typename"
  }
}

public struct Repository: Sendable, Equatable, Decodable {
  public var name: String
  public var nameWithOwner: String
  public var owner: Owner?

  /// `.unknown` when GitHub didn't return an owner type: left out of both
  /// the personal and organization filters rather than guessed into one.
  public var ownerKind: OwnerKind {
    switch owner?.typename {
    case "User": .personal
    case "Organization": .organization
    default: .unknown
    }
  }
}

public struct Item: Sendable, Equatable {
  /// GitHub's node id, which check lookups use.
  public var id: String
  public var number: Int
  public var title: String
  public var repository: Repository
  public var isPullRequest: Bool
  public var isDraft: Bool
  /// The PR's head commit; nil for issues.
  public var head: String?
  public var review: Review?
  /// How the review request reached the viewer; review section only.
  public var reviewRoute: ReviewRoute?
  public var url: String
  /// Bumped by any activity: creation, comments, pushes, reviews, labels.
  public var updatedAt: String
  public var author: String

  public var owner: Substring {
    guard let slash = repository.nameWithOwner.firstIndex(of: "/") else { return "" }
    return repository.nameWithOwner[..<slash]
  }

  /// Where the item falls in `ranking`'s order; drafts always come last.
  func tier(_ ranking: Ranking) -> Int {
    if isDraft { return 3 }
    switch (ranking, review) {
    case (.attention, .approved): return 1
    case (.attention, _): return 0
    case (.merge, .approved): return 0
    case (.merge, .changesRequested): return 1
    case (.merge, _): return 2
    }
  }
}

public struct Identity: Sendable, Equatable {
  public var login: String
  /// The GitHub host gh is talking to, e.g. `github.com`.
  public var host: String
}

/// What one section's search returned.
public struct Page: Sendable {
  public var items: [Item]
  /// GitHub's match count.
  public var total: Int
  /// GitHub has more matches than the page fetched.
  public var truncated: Bool
  /// Results GitHub returned on the page, before dropping unreadable or
  /// withheld ones.
  public var returned: Int
  /// Results left out as not yet back from their authors (`Routing.returned`).
  public var waiting = 0
}

public struct SectionFetch: Sendable {
  /// Who answered; nil when no usable response arrived.
  public var identity: Identity?
  public var page: Result<Page, GhError>
  /// Why some items are missing or incomplete, even though others loaded.
  public var warnings: [GhError]
}

/// A PR's check state, for the head commit it describes.
public struct CheckState: Sendable, Equatable {
  public var head: String
  /// nil when the commit has no checks.
  public var checks: Checks?
}

/// Whether the viewer belongs to any organization.
public enum Membership: Sendable, Equatable {
  case member
  /// An empty list from a token that can see private memberships.
  case none
  /// Failed, partial, or from a token that may not see every membership.
  case unknown
}

public struct MembershipFetch: Sendable {
  public var identity: Identity?
  public var membership: Membership
}

public struct ChecksFetch: Sendable {
  public var identity: Identity?
  /// One entry per requested id, in request order.
  public var results: [(id: String, result: Result<CheckState, GhError>)]
}

/// How a section orders its items; most recent activity first within each
/// group, drafts last.
public enum Ranking: Sendable {
  /// What needs the viewer's review first, then approved PRs.
  case attention
  /// The viewer's own PRs: approved ones can be merged now, changes
  /// requested are theirs to fix, and the rest wait on reviewers.
  case merge
}

/// Orders items by `ranking`. Stable, so equal items keep their order.
public func rank(_ items: inout [Item], by ranking: Ranking) {
  // RFC 3339 UTC timestamps sort lexically.
  items = items.enumerated().sorted { a, b in
    let (ta, tb) = (a.element.tier(ranking), b.element.tier(ranking))
    if ta != tb { return ta < tb }
    if a.element.updatedAt != b.element.updatedAt { return a.element.updatedAt > b.element.updatedAt }
    return a.offset < b.offset
  }.map(\.element)
}
