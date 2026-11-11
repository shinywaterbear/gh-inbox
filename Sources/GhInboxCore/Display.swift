// What the window draws from an `Inbox`, kept here so it is tested; the
// AppKit shell only lays it out.

import Foundation

public enum Tone: Sendable, Equatable {
  case error, warning
}

/// The moment a render describes: ages and "updated" notes are read from it,
/// so a tick is just a render at a later moment.
public struct Now: Sendable {
  public var instant: Instant
  public var date: Date
  public var timeZone: TimeZone
  public var locale: Locale

  public init(
    instant: Instant = .now, date: Date = Date(), timeZone: TimeZone = .current, locale: Locale = .current
  ) {
    self.instant = instant
    self.date = date
    self.timeZone = timeZone
    self.locale = locale
  }
}

/// A problem to show, as a row or a banner, worded as of a `Now`.
public struct Notice: Sendable, Equatable {
  public var text: String
  public var tone: Tone

  public init(text: String, tone: Tone) {
    self.text = text
    self.tone = tone
  }
}

/// A row's identity across renders, so a list can update rows in place.
public enum RowID: Sendable, Hashable {
  case heading(section: Int)
  /// A group of the queue's items, by `Item.tier`.
  case group(section: Int, tier: Int)
  /// The section's error first, then its warnings.
  case notice(section: Int, ordinal: Int)
  case item(section: Int, url: String)
  case cutOff(section: Int)
}

public struct HeadingRow: Sendable, Equatable {
  public var name: String
  public var mark: HeadingMark
  /// A rule above it: every section but the first.
  public var ruled: Bool
}

/// Everything an item's row shows.
public struct ItemRow: Sendable, Equatable {
  public var url: String
  /// Only when several owners show; the row then reads "owner/".
  public var owner: String?
  public var repo: String
  public var number: Int
  /// `owner/repo#123`, as GitHub links it in comments and commits.
  public var reference: String
  public var title: String
  public var kind: Kind
  public var dot: Dot
  /// Off where a group heading already names the state.
  public var showsBadge: Bool
  public var route: String?
  /// Blank when it's the viewer.
  public var author: String
  public var age: String
  public var toolTip: String
  public var accessibilityLabel: String
}

/// A section with more matches than fetched: what the page holds and the
/// full search.
public struct CutOffRow: Sendable, Equatable {
  public enum More: Sendable, Equatable {
    case button(String)
    case loading
    /// At GitHub's largest page; only the full search is left.
    case none
  }

  public var section: Int
  public var more: More
  public var note: String
  public var url: String
}

public enum RowContent: Sendable, Equatable {
  case heading(HeadingRow)
  /// Truncated to one row; the full text is a hover away, and a click
  /// copies it.
  case notice(Notice)
  case item(ItemRow)
  /// Only its buttons act: a near-miss on "Load more" shouldn't open the
  /// browser.
  case cutOff(CutOffRow)
}

/// What clicking a row, or pressing Return on it, does.
public enum RowAction: Sendable, Equatable {
  case open(String)
  case copy(String)
}

/// One entry in a row's right-click menu.
public struct MenuEntry: Sendable, Equatable {
  public var title: String
  public var action: RowAction
}

public struct RowModel: Sendable, Equatable, Identifiable {
  public var id: RowID
  public var content: RowContent

  public var isHeading: Bool {
    if case .heading = content { true } else { false }
  }

  public var action: RowAction? {
    switch content {
    case .heading, .cutOff: nil
    case .notice(let notice): .copy(notice.text)
    case .item(let item): .open(item.url)
    }
  }

  /// The right-click menu: an item can be copied without opening it.
  public var menu: [MenuEntry] {
    switch content {
    case .heading, .cutOff: []
    case .notice(let notice): [MenuEntry(title: "Copy", action: .copy(notice.text))]
    case .item(let item):
      [
        MenuEntry(title: "Open in Browser", action: .open(item.url)),
        MenuEntry(title: "Copy Link", action: .copy(item.url)),
        MenuEntry(title: "Copy \(item.reference)", action: .copy(item.reference)),
      ]
    }
  }

  /// What Edit > Copy puts on the pasteboard for the selected row: an
  /// item's link, or a notice's full text.
  public var copyText: String? {
    switch action {
    case .open(let text), .copy(let text): text
    case nil: nil
    }
  }

  public var toolTip: String? {
    switch content {
    case .heading: nil
    case .notice(let notice): "\(notice.text)\n\nClick to copy."
    case .item(let item): item.toolTip
    case .cutOff(let cut): cut.note
    }
  }
}

/// A queue's entry in the sidebar.
public struct QueueModel: Sendable, Equatable {
  public var section: Int
  public var name: String
  /// The sidebar heading it sits under.
  public var group: String
  /// GitHub's total for the queue's search (`SectionView.matched`), before
  /// deduplication and the owner filter; nil until it has loaded.
  public var count: Int?
  public var status: QueueStatus
}

public enum QueueStatus: Sendable, Equatable {
  case ready
  /// Never loaded, and a fetch is running.
  case loading
  /// The latest refresh failed; the rows are from an earlier one.
  case stale
  /// Never loaded, and the last fetch failed.
  case failed
  /// Never loaded, and nothing asked yet.
  case unknown

  init(_ section: SectionView) {
    if section.loaded {
      self = section.error == nil ? .ready : .stale
    } else if section.busy {
      self = .loading
    } else {
      self = section.error == nil ? .unknown : .failed
    }
  }
}

/// The queues to list, in order. The team queue drops out for an account
/// that can't be on a team.
public func queues(_ inbox: Inbox) -> [QueueModel] {
  sections.indices.filter { $0 != teamSection || inbox.showTeamQueue }.map { s in
    let section = inbox.sections[s]
    return QueueModel(
      section: s, name: sections[s].name, group: sections[s].group,
      count: section.loaded ? section.matched : nil, status: QueueStatus(section))
  }
}

/// Every listed queue in one list, each under its heading.
public func rows(_ inbox: Inbox, now: Now) -> [RowModel] {
  var result: [RowModel] = []
  let visible = inbox.visible()
  for queue in queues(inbox) {
    let s = queue.section
    let heading = HeadingRow(
      name: queue.name, mark: headingMark(inbox.sections[s], shown: visible[s].count), ruled: !result.isEmpty)
    result.append(RowModel(id: .heading(section: s), content: .heading(heading)))
    for (ordinal, notice) in notices(inbox, queue: s, now: now).enumerated() {
      result.append(RowModel(id: .notice(section: s, ordinal: ordinal), content: .notice(notice)))
    }
    result += rows(inbox, queue: s, now: now)
  }
  return result
}

/// A queue's latest failure, with the age of the rows it kept, then its
/// warnings. A failure every queue shares is a banner of its own instead.
public func notices(_ inbox: Inbox, queue s: Int, now: Now) -> [Notice] {
  let section = inbox.sections[s]
  var result: [Notice] = []
  if let error = section.error, inbox.commonError == nil {
    let age = section.fetchedAt.map { " Showing results from \(ago($0, now.instant))." } ?? ""
    result.append(Notice(text: error.described + age, tone: .error))
  }
  return result + section.warnings.map { Notice(text: $0.described, tone: .warning) }
}

/// Group names for `Ranking.merge`, by tier.
private let mergeGroups = ["Approved", "Changes requested", "Awaiting review", "Drafts"]

/// One queue's items (grouped where its order has groups), and a closing
/// row when fewer show than GitHub matched. Its notices are banners
/// (`banners(_:queue:now:)`).
public func rows(_ inbox: Inbox, queue s: Int, now: Now) -> [RowModel] {
  var result: [RowModel] = []
  let section = inbox.sections[s]
  let shown = inbox.visible()[s]
  let owners = Set(shown.map { section.items[$0].owner })
  let viewer = inbox.identity?.login
  let ranking = sections[s].ranking
  let grouped = ranking == .merge
  var tier: Int?
  for index in shown {
    let item = section.items[index]
    if grouped, item.tier(ranking) != tier {
      let next = item.tier(ranking)
      tier = next
      let count = shown.filter { section.items[$0].tier(ranking) == next }.count
      let heading = HeadingRow(
        name: mergeGroups[next], mark: .count(count, dim: false), ruled: result.contains(where: \.isHeading))
      result.append(RowModel(id: .group(section: s, tier: next), content: .heading(heading)))
    }
    var row = itemRow(
      item, check: inbox.check(item), multiOwner: owners.count > 1, viewer: viewer, now: now)
    row.showsBadge = !grouped
    result.append(RowModel(id: .item(section: s, url: item.url), content: .item(row)))
  }
  if section.loaded, section.truncated || shown.count < section.matched {
    let url = searchURL(s, host: inbox.identity?.host ?? "github.com")
    let more: CutOffRow.More =
      section.expanding ? .loading : section.canLoadMore ? .button("Load \(pageStep) more") : .none
    let cut = CutOffRow(section: s, more: more, note: shortfall(inbox, queue: s), url: url)
    result.append(RowModel(id: .cutOff(section: s), content: .cutOff(cut)))
  }
  return result
}

/// Why a queue shows fewer rows than GitHub matched.
func shortfall(_ inbox: Inbox, queue s: Int) -> String {
  let section = inbox.sections[s]
  let unique = inbox.deduplicated()[s].count
  let shown = inbox.visible()[s].count
  let fetched =
    section.truncated
    ? "the newest \(section.returned) of \(section.total) matches" : "\(section.total) matches"
  var reasons: [String] = []
  let elsewhere = section.items.count - unique
  if elsewhere > 0 { reasons.append("\(elsewhere) in other queues") }
  if unique > shown { reasons.append("\(unique - shown) hidden by the Personal/Org filter") }
  let lost = section.returned - section.items.count - section.waiting
  if section.waiting > 0 { reasons.append("\(section.waiting) not pushed since your review") }
  if lost > 0 { reasons.append("\(lost) unreadable or withheld") }
  if shown == section.returned && section.truncated { return "Showing \(fetched)" }
  return "\(shown) shown of \(fetched)" + (reasons.isEmpty ? "" : "; " + reasons.joined(separator: ", "))
}

/// What an empty queue says, when nothing it matched is shown elsewhere,
/// filtered out or held back.
public func emptyText(_ inbox: Inbox, queue s: Int) -> String? {
  let section = inbox.sections[s]
  guard section.loaded, section.matched == 0, section.warnings.isEmpty, section.error == nil else {
    return nil
  }
  return sections[s].empty
}

func itemRow(_ item: Item, check: CheckView?, multiOwner: Bool, viewer: String?, now: Now) -> ItemRow {
  let kind = Kind(item)
  let dot = Dot(check)
  let route = routeLabel(item.reviewRoute)
  let author = item.author == viewer ? "" : item.author
  let updated = date(item.updatedAt).map { localTime($0, now: now) } ?? item.updatedAt
  let place = "\(item.repository.nameWithOwner) #\(item.number)"
  // The route too: a narrow row may have no room to show it.
  let toolTip =
    "\(item.title)\n\(place) · updated \(updated)"
    + (route.map { "\n\(item.reviewRoute == .returned ? "Review" : "Review request"): \($0)" } ?? "")
  let spoken = [
    kind.spokenName, item.title, place, kind.badge, dot.spoken, route, author.isEmpty ? nil : "by \(author)",
    "updated \(updated)",
  ]
  return ItemRow(
    url: item.url, owner: multiOwner ? String(item.owner) : nil, repo: item.repository.name,
    number: item.number, reference: "\(item.repository.nameWithOwner)#\(item.number)",
    title: item.title, kind: kind, dot: dot, showsBadge: true, route: route, author: author,
    age: age(item.updatedAt, now: now) ?? "", toolTip: toolTip,
    accessibilityLabel: spoken.compactMap { $0 }.joined(separator: ", "))
}

/// The timestamp in the reader's own zone and format.
func localTime(_ date: Date, now: Now) -> String {
  date.formatted(
    Date.FormatStyle(date: .abbreviated, time: .shortened, locale: now.locale, timeZone: now.timeZone))
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

/// Counts each item shown in any queue once.
public func header(_ inbox: Inbox, now: Now) -> Header {
  var (prs, drafts, issues) = (0, 0, 0)
  for (section, shown) in zip(inbox.sections, inbox.visible()) {
    for index in shown {
      switch Kind(section.items[index]) {
      case .draft: drafts += 1
      case .issue: issues += 1
      case .pullRequest, .approved, .changes: prs += 1
      }
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
      summary.append("updated \(ago(updated, now.instant))")
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

/// Problems above the list: those not tied to a queue, then `queue`'s own
/// (`notices`); long ones show in full on hover.
public func banners(_ inbox: Inbox, queue: Int? = nil, now: Now) -> [Notice] {
  var result: [Notice] = []
  if let error = inbox.commonError {
    let age = inbox.updated.map { " Showing results from \(ago($0, now.instant))." } ?? ""
    result.append(Notice(text: "Couldn't refresh: \(error.described)\(age)", tone: .error))
  }
  if let (count, error) = inbox.checkFailures() {
    result.append(
      Notice(text: "Couldn't load checks for \(counted(count, "PR")): \(error.described)", tone: .warning))
  }
  if let queue { result += notices(inbox, queue: queue, now: now) }
  return result
}

/// The heading pinned over the top of the list when `firstVisible` is the
/// first row in view: the nearest heading at or above it.
public func pinnedHeading(_ rows: [RowModel], firstVisible: Int) -> Int? {
  guard rows.indices.contains(firstVisible) else { return nil }
  return rows[...firstVisible].lastIndex(where: \.isHeading)
}

/// The row an arrow key moves the selection to: the nearest row past
/// `from` in `step`'s direction that acts, skipping headings and cut-off
/// rows. With nothing selected, the first such row from that end.
public func nextSelectable(_ rows: [RowModel], from: Int?, step: Int) -> Int? {
  let start = from.map { $0 + step } ?? (step > 0 ? 0 : rows.count - 1)
  return stride(from: start, to: step > 0 ? rows.count : -1, by: step > 0 ? 1 : -1)
    .first { rows.indices.contains($0) && rows[$0].action != nil }
}

/// How to turn one list of rows into another without rebuilding the rows
/// that stay: rows whose identity left or arrived, and rows kept whose
/// content changed.
public struct RowChanges: Sendable, Equatable {
  /// Indexes into the old rows.
  public var removed: [Int]
  /// Indexes into the new rows.
  public var inserted: [Int]
  /// Indexes into the new rows.
  public var updated: [Int]

  public var isEmpty: Bool { removed.isEmpty && inserted.isEmpty && updated.isEmpty }
}

public func changes(from old: [RowModel], to new: [RowModel]) -> RowChanges {
  let difference = new.map(\.id).difference(from: old.map(\.id))
  var removed: [Int] = []
  var inserted: [Int] = []
  for change in difference {
    switch change {
    case .remove(let offset, _, _): removed.append(offset)
    case .insert(let offset, _, _): inserted.append(offset)
    }
  }
  let arrived = Set(inserted)
  let before = Dictionary(old.map { ($0.id, $0.content) }, uniquingKeysWith: { first, _ in first })
  let updated = new.indices.filter { !arrived.contains($0) && before[new[$0].id] != new[$0].content }
  return RowChanges(removed: removed.sorted(), inserted: inserted.sorted(), updated: updated)
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

  var spokenName: String {
    switch self {
    case .issue: "Issue"
    case .draft, .approved, .changes, .pullRequest: "Pull request"
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
/// "2d", "3w", then the date in `now`'s zone and locale, with the year only
/// when it isn't this year. Nil when the timestamp doesn't parse.
public func age(_ timestamp: String, now: Now) -> String? {
  guard let then = date(timestamp) else { return nil }
  let secs = max(0, Int(now.date.timeIntervalSince(then)))
  switch secs {
  case ..<60: return "now"
  case ..<3600: return "\(secs / 60)m"
  case ..<86400: return "\(secs / 3600)h"
  case ..<(7 * 86400): return "\(secs / 86400)d"
  case ..<(5 * 7 * 86400): return "\(secs / (7 * 86400))w"
  default:
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = now.timeZone
    let day = Date.FormatStyle(locale: now.locale, calendar: calendar, timeZone: now.timeZone)
      .month(.abbreviated).day()
    let sameYear = calendar.component(.year, from: then) == calendar.component(.year, from: now.date)
    return then.formatted(sameYear ? day : day.year())
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

  var spoken: String? {
    switch self {
    case .none: nil
    case .filled(let checks, let dim):
      checks.spoken + (dim ? " (recheck failed)" : "")
    case .loading: "loading checks"
    case .failed: "couldn't load checks"
    }
  }
}

extension Checks {
  var spoken: String {
    switch self {
    case .passing: "checks passing"
    case .failing: "checks failing"
    case .pending: "checks pending"
    }
  }
}

public func routeLabel(_ route: ReviewRoute?) -> String? {
  switch route {
  case nil, .direct: nil
  case .team(let team): "via \(team)"
  case .someTeam: "via a team"
  case .unknown: "request source unknown"
  case .returned: "pushed since your review"
  }
}
