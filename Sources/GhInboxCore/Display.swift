// What the window draws from an `Inbox`, kept here so it is tested; the
// AppKit shell only lays it out.

import Foundation

public enum Tone: Sendable, Equatable {
  case error, warning
}

/// A problem to show, whose age can move without new data: `since` is when
/// the results it describes arrived. Equal notices stay equal as that age
/// grows, so nothing is rebuilt (closing a tooltip) just because time passed.
public struct Notice: Sendable, Equatable {
  public var text: String
  public var tone: Tone
  public var since: Instant?

  public init(text: String, tone: Tone, since: Instant? = nil) {
    self.text = text
    self.tone = tone
    self.since = since
  }

  /// The full text as of `now`.
  public func text(now: Instant) -> String {
    since.map { "\(text) Showing results from \(ago($0, now))." } ?? text
  }
}

/// A list row, pointing into `Inbox` rather than copying items.
public enum Row: Sendable, Equatable {
  case heading(section: Int, first: Bool, shown: Int)
  /// Truncated to one row; the full text is a hover away, and a click
  /// copies it.
  case notice(Notice)
  case item(section: Int, index: Int)
  /// A section with more matches than fetched: what the page holds, the
  /// full search, and "Load more" while `SectionView.canLoadMore`.
  case cutOff(section: Int, note: String, url: String)
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
      result.rows.append(.notice(Notice(text: error.described, tone: .error, since: section.fetchedAt)))
    }
    for warning in section.warnings {
      result.rows.append(.notice(Notice(text: warning.described, tone: .warning)))
    }
    for index in shown {
      owners.insert(section.items[index].owner)
      result.rows.append(.item(section: s, index: index))
    }
    if section.truncated {
      // The owner tabs filter only what's already fetched.
      let beforeFilter = inbox.ownerFilter == .all ? "" : ", before the Personal/Org filter"
      // The shown count is named apart only when decoding, deduplication or
      // the filter made it differ from what GitHub returned.
      let fetched = "the newest \(section.returned) of \(section.total) matches\(beforeFilter)"
      let note = shown.count == section.returned ? "Showing \(fetched)" : "\(shown.count) shown of \(fetched)"
      let url = searchURL(s, host: inbox.identity?.host ?? "github.com", directOnly: inbox.reviewDirectOnly)
      result.rows.append(.cutOff(section: s, note: note, url: url))
    }
  }
  result.multiOwner = owners.count > 1
  return result
}

/// A section is being fetched: what a retry of a failed load waits on. The
/// membership and check lookups don't count; they run without one.
public func retrying(_ inbox: Inbox) -> Bool {
  inbox.sections.contains(where: \.busy)
}

/// What a section's heading shows beside its name.
public enum HeadingMark: Sendable, Equatable {
  /// How many rows show; `dim` when that is none.
  case count(Int, dim: Bool)
  /// Never loaded and a fetch is running, a retry included.
  case loading
  /// Never loaded and the last fetch failed.
  case failed
  /// Never loaded and nothing asked yet: unknown, not zero.
  case unknown
}

public func headingMark(_ section: SectionView, shown: Int) -> HeadingMark {
  if section.loaded { return .count(shown, dim: shown == 0) }
  if section.busy { return .loading }
  return section.error == nil ? .unknown : .failed
}

/// Every section loaded and found nothing, with nothing withheld, unreadable
/// or cut off. Unfiltered: an owner tab showing nothing doesn't mean nothing
/// is open.
public func nothingOpen(_ inbox: Inbox) -> Bool {
  inbox.sections.allSatisfy {
    $0.loaded && $0.error == nil && $0.warnings.isEmpty && !$0.truncated && $0.items.isEmpty
  }
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
    // Drafts are PRs too; counted apart, "9 PRs · 2 drafts" read as 9 in all.
    let draftNote = drafts > 0 ? " (\(counted(drafts, "draft")))" : ""
    summary.append(counted(prs + drafts, "PR") + draftNote)
    summary.append(counted(issues, "issue"))
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

/// Problems that aren't tied to a section, above the list; long ones show in full on hover.
public func banners(_ inbox: Inbox) -> [Notice] {
  var result: [Notice] = []
  if let error = inbox.commonError {
    result.append(Notice(text: "Couldn't refresh: \(error.described)", tone: .error, since: inbox.updated))
  }
  if let (count, error) = inbox.checkFailures() {
    result.append(
      Notice(text: "Couldn't load checks for \(counted(count, "PR")): \(error.described)", tone: .warning))
  }
  return result
}

/// The heading pinned over the top of the list when `firstVisible` is the
/// first row in view: the nearest heading at or above it.
public func pinnedHeading(_ rows: [Row], firstVisible: Int) -> Int? {
  guard rows.indices.contains(firstVisible) else { return nil }
  return rows[...firstVisible].lastIndex { if case .heading = $0 { true } else { false } }
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

  /// A state worth calling out beside the title; an open PR or issue is
  /// the default and needs none.
  public var badge: String? {
    switch self {
    case .issue, .pullRequest: nil
    case .draft: "Draft"
    case .approved: "Approved"
    case .changes: "Changes requested"
    }
  }
}

func counted(_ n: Int, _ noun: String) -> String {
  "\(n) \(noun)\(n == 1 ? "" : "s")"
}

private let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

/// Formatters are costly to make and every row parses a timestamp; the lock
/// keeps sharing them safe where Foundation doesn't promise it.
private final class Parsers: @unchecked Sendable {
  let lock = NSLock()
  let plain = ISO8601DateFormatter()
  let fractional: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions.insert(.withFractionalSeconds)
    return formatter
  }()
}

private let parsers = Parsers()

/// An RFC 3339 timestamp, with or without fractional seconds.
public func date(_ timestamp: String) -> Date? {
  parsers.lock.lock()
  defer { parsers.lock.unlock() }
  return parsers.plain.date(from: timestamp) ?? parsers.fractional.date(from: timestamp)
}

/// How long ago an RFC 3339 timestamp was, compactly: "now", "5m", "3h",
/// "2d", "3w", then the date in `timeZone`. Nil when the timestamp doesn't
/// parse.
public func age(_ timestamp: String, now: Date, timeZone: TimeZone = .current) -> String? {
  guard let then = date(timestamp) else { return nil }
  let secs = max(0, Int(now.timeIntervalSince(then)))
  switch secs {
  case ..<60: return "now"
  case ..<3600: return "\(secs / 60)m"
  case ..<86400: return "\(secs / 3600)h"
  case ..<(7 * 86400): return "\(secs / 86400)d"
  case ..<(5 * 7 * 86400): return "\(secs / (7 * 86400))w"
  default:
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let date = calendar.dateComponents([.year, .month, .day], from: then)
    let year = calendar.component(.year, from: now)
    let day = "\(months[date.month! - 1]) \(date.day!)"
    return date.year == year ? day : "\(day), \(date.year!)"
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
