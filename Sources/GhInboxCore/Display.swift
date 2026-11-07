// What the window draws from an `Inbox`, kept here so it is tested; the
// AppKit shell only lays it out.

public enum Tone: Sendable, Equatable {
  case error, warning
}

/// A list row, pointing into `Inbox` rather than copying items.
public enum Row: Sendable, Equatable {
  case heading(section: Int, first: Bool, shown: Int)
  /// Truncated to one row; the full text is a hover away, and a click opens
  /// `url` or copies the text.
  case notice(text: String, tone: Tone, url: String?)
  case item(section: Int, index: Int)
  case loadMore(section: Int)
}

public struct Rows: Sendable {
  public var rows: [Row] = []
  /// Items from more than one owner are shown, so repos need their owner.
  public var multiOwner = false

  public init() {}
}

public func rows(_ inbox: Inbox, now: Instant) -> Rows {
  var result = Rows()
  var owners = Set<Substring>()
  let common = inbox.commonError != nil
  for (s, (section, shown)) in zip(inbox.sections, inbox.visible()).enumerated() {
    result.rows.append(.heading(section: s, first: result.rows.isEmpty, shown: shown.count))
    if let error = section.error, !common {
      let text =
        section.fetchedAt.map { "\(error.described) Showing results from \(ago($0, now))." }
        ?? error.described
      result.rows.append(.notice(text: text, tone: .error, url: nil))
    }
    for warning in section.warnings {
      result.rows.append(.notice(text: warning.described, tone: .warning, url: nil))
    }
    for index in shown {
      owners.insert(section.items[index].owner)
      result.rows.append(.item(section: s, index: index))
    }
    if section.canLoadMore { result.rows.append(.loadMore(section: s)) }
    if section.truncated {
      // The owner tabs filter only what's already fetched.
      let beforeFilter = inbox.ownerFilter == .all ? "" : " before the Personal/Org filter"
      let text =
        "Fetched the newest \(section.returned) of \(section.total) matches\(beforeFilter); "
        + "\(shown.count) shown here. Open the full search on GitHub."
      let url = searchURL(s, host: inbox.identity?.host ?? "github.com", directOnly: inbox.reviewDirectOnly)
      result.rows.append(.notice(text: text, tone: .warning, url: url))
    }
  }
  result.multiOwner = owners.count > 1
  return result
}

public struct Header: Sendable, Equatable {
  public var title: String
  public var summary: String
  public var busy: Bool
}

public func header(_ inbox: Inbox, rows: [Row], now: Instant) -> Header {
  var (prs, drafts, issues) = (0, 0, 0)
  for case .item(let section, let index) in rows {
    let item = inbox.sections[section].items[index]
    if item.isDraft {
      drafts += 1
    } else if item.isPullRequest {
      prs += 1
    } else {
      issues += 1
    }
  }
  let busy = inbox.anyBusy
  var summary: [String] = []
  if !inbox.anyLoaded {
    summary.append(busy ? "Loading…" : "Unavailable")
  } else {
    summary.append("\(prs) PRs")
    if drafts > 0 { summary.append("\(drafts) drafts") }
    summary.append("\(issues) issues")
    if busy {
      summary.append("refreshing…")
    } else if let updated = inbox.updated {
      summary.append("updated \(ago(updated, now))")
    }
  }
  let title =
    switch inbox.identity {
    case .some(let id) where id.host == "github.com": "Open for \(id.login)"
    case .some(let id): "Open for \(id.login) on \(id.host)"
    case nil: "Open work"
    }
  return Header(title: title, summary: summary.joined(separator: " · "), busy: busy)
}

/// Problems that aren't tied to a section, shown in full above the list.
public func banners(_ inbox: Inbox, now: Instant) -> [(text: String, tone: Tone)] {
  var result: [(String, Tone)] = []
  if let error = inbox.commonError {
    let when = inbox.updated.map { " Showing results from \(ago($0, now))." } ?? ""
    result.append(("Couldn't refresh: \(error.described)\(when)", .error))
  }
  if let (count, error) = inbox.checkFailures() {
    result.append(("Couldn't load checks for \(count) PR(s): \(error.described)", .warning))
  }
  return result
}

public enum Kind: Sendable, Equatable {
  case issue, draft, approved, changes, pullRequest

  public init(_ item: Item) {
    switch (item.isPullRequest, item.isDraft, item.review) {
    case (false, _, _): self = .issue
    case (true, true, _): self = .draft
    case (true, false, .approved): self = .approved
    case (true, false, .changesRequested): self = .changes
    case (true, false, _): self = .pullRequest
    }
  }

  public var label: String {
    switch self {
    case .issue: "Issue"
    case .draft: "Draft"
    case .approved: "Approved"
    case .changes: "Changes"
    case .pullRequest: "PR"
    }
  }
}

/// Filled: known for the head commit (dimmed while being rechecked). Ring:
/// still loading or the lookup failed.
public enum Dot: Sendable, Equatable {
  case none
  case filled(Checks, dim: Bool)
  case loading
  case failed

  public init(_ check: CheckView?) {
    switch check {
    case nil, .known(checks: nil, _): self = .none
    case .known(.some(let checks), let stale): self = .filled(checks, dim: stale)
    case .loading: self = .loading
    case .failed: self = .failed
    }
  }
}

public func routeLabel(_ route: ReviewRoute?) -> String? {
  switch route {
  case nil, .direct: nil
  case .team(let team): "via \(team)"
  case .someTeam: "via a team"
  case .unknown: "request source unknown"
  }
}
