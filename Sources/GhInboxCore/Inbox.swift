// What the window shows, independent of AppKit: the last good results per
// section, which requests to run next, their outcomes, and when to refresh.

public typealias Instant = ContinuousClock.Instant

/// Automatic refresh cadence; a manual refresh ignores all of these.
public let focusedInterval = Duration.seconds(2 * 60)
public let blurredInterval = Duration.seconds(10 * 60)
/// Focusing the window refreshes only when the last attempt is at least this old.
public let focusMinAge = Duration.seconds(30)
/// Requests running at once, sections and checks together.
public let concurrency = 4
/// A section's first page, and how much each "load more" adds.
public let pageStep = 25
/// GitHub's largest page; past it a section links to the full search.
public let pageMax = 100
/// PRs per check lookup.
public let checkBatch = 25

public enum Trigger: Sendable {
  case tick, focus
}

/// Where the window stands. Minimized or hidden is `background`; a closed
/// window shows nothing, so nothing is fetched until it opens again.
public enum Presence: Sendable {
  case focused, background, closed
}

/// Whether an automatic refresh is due. `sinceAttempt` counts failures too,
/// so a failing refresh is retried at the normal cadence, not in a loop.
public func due(_ trigger: Trigger, presence: Presence, sinceAttempt: Duration?) -> Bool {
  if presence == .closed { return false }
  guard let age = sinceAttempt else { return true }
  switch (trigger, presence) {
  case (.focus, .focused): return age >= focusMinAge
  case (.focus, _): return false
  case (.tick, _): return age >= (presence == .focused ? focusedInterval : blurredInterval)
  }
}

/// A client-side split by repository owner type.
public enum OwnerFilter: Sendable, CaseIterable {
  case all, personal, organization

  /// An unclassified repository matches neither Personal nor Organization.
  public func matches(_ item: Item) -> Bool {
    switch self {
    case .all: true
    case .personal: item.repository.ownerKind == .personal
    case .organization: item.repository.ownerKind == .organization
    }
  }
}

/// One request to make.
public enum Job: Sendable, Equatable {
  case section(index: Int, size: Int)
  case checks(ids: [String])
  case membership
}

/// A started job, handed back with its outcome.
public struct Ticket: Sendable {
  public var job: Job
  /// Results from before an account change are discarded.
  var epoch: UInt64
  var round: UInt64
}

public enum Outcome: Sendable {
  case section(SectionFetch)
  case checks(ChecksFetch)
  case membership(MembershipFetch)

  var identity: Identity? {
    switch self {
    case .section(let f): f.identity
    case .checks(let f): f.identity
    case .membership(let f): f.identity
    }
  }
}

extension GitHub {
  /// Runs one job with the round's credential.
  func perform(_ job: Job, as credential: Credential) async -> Outcome {
    switch job {
    case .section(let index, let size):
      .section(await section(index, size: size, as: credential))
    case .checks(let ids): .checks(await checks(ids, as: credential))
    case .membership: .membership(await membership(as: credential))
    }
  }
}

extension Outcome {
  /// What a job reports when it could not be sent at all.
  static func failed(_ job: Job, _ error: GhError) -> Outcome {
    switch job {
    case .section: .section(SectionFetch(identity: nil, page: .failure(error), warnings: []))
    case .checks(let ids): .checks(ChecksFetch(identity: nil, results: ids.map { ($0, .failure(error)) }))
    case .membership: .membership(MembershipFetch(identity: nil, membership: .unknown))
    }
  }
}

/// The organization membership check, asked once per account.
enum MembershipCheck: Equatable {
  case due, asked
  case answered(Membership)
}

public struct SectionView: Sendable {
  public var name: String
  public var items: [Item] = []
  /// The section has loaded at least once, so empty `items` means "none".
  public var loaded = false
  /// The latest request failed; `items` are from `fetchedAt`.
  public var error: GhError?
  public var warnings: [GhError] = []
  public var total = 0
  public var truncated = false
  /// Results GitHub returned, before decoding losses and deduplication.
  public var returned = 0
  /// The page size last fetched successfully, which refreshes keep.
  public var size = pageStep
  public var fetchedAt: Instant?
  public var busy = false
  /// "Load more" was asked for and hasn't finished; a refresh in flight
  /// runs first.
  public var expanding = false
  /// The round each item's data came from, by URL: its section's fetch, or
  /// the newer copy `Inbox.placeRows` put in its place.
  var rounds: [String: UInt64] = [:]

  init(name: String) {
    self.name = name
  }

  public var canLoadMore: Bool { truncated && size < pageMax }

  /// Records the outcome; returns whether new items arrived.
  mutating func apply(size: Int, round: UInt64, fetch: SectionFetch, now: Instant) -> Bool {
    busy = false
    warnings = fetch.warnings
    switch fetch.page {
    case .failure(let error):
      self.error = error
      return false
    case .success(let page):
      items = page.items
      total = page.total
      truncated = page.truncated
      returned = page.returned
      self.size = size
      loaded = true
      error = nil
      fetchedAt = now
      rounds = Dictionary(items.map { ($0.url, round) }, uniquingKeysWith: { a, _ in a })
      return true
    }
  }
}

/// A section fetch waiting for a free slot.
struct Queued {
  var index: Int
  var size: Int
  /// The round its result will count as.
  var round: UInt64
}

/// How a PR's check dot should read.
public enum CheckView: Sendable, Equatable {
  /// Nothing known for the current head commit yet.
  case loading
  /// `stale` when the latest lookup for this head failed. A pending recheck
  /// changes nothing, so a refresh doesn't flash every dot.
  case known(checks: Checks?, stale: Bool)
  case failed(GhError)
}

public struct Inbox: Sendable {
  public var identity: Identity?
  public internal(set) var sections: [SectionView] = GhInboxCore.sections.map { SectionView(name: $0.name) }
  public var ownerFilter = OwnerFilter.all
  /// The section each item's row is in, by URL (`placeRows`).
  var placed: [String: Int] = [:]
  var membership = MembershipCheck.due
  /// Rows from both personal and organization repos have loaded.
  var mixedOwners = false
  var epoch: UInt64 = 0
  var round: UInt64 = 0
  var running = 0
  var sectionsQueued: [Queued] = []
  var checksQueued: [String] = []
  /// PR ids queued or running, with the head commit each was asked for.
  var checksPending: [String: String] = [:]
  /// Each displayed PR's latest head commit from any section.
  var heads: [String: String] = [:]
  var checks: [String: CheckState] = [:]
  var checkErrors: [String: GhError] = [:]

  public init() {}

  /// Queues every idle section at its current size. Returns how many.
  @discardableResult
  public mutating func refresh() -> Int {
    round += 1
    var queued = 0
    for index in sections.indices where !sections[index].busy {
      queueSection(index, size: sections[index].size)
      queued += 1
    }
    return queued
  }

  /// Queues a selected section at the current round.
  mutating func queueSection(_ index: Int, size: Int) {
    sections[index].busy = true
    sectionsQueued.append(Queued(index: index, size: size, round: round))
  }

  /// Queues the section again, one step larger. Its rows and size stay until
  /// the larger page arrives. It gets a round of its own, so its copies beat
  /// older duplicates in earlier sections.
  @discardableResult
  public mutating func loadMore(_ index: Int) -> Bool {
    if sections[index].expanding || !sections[index].canLoadMore { return false }
    sections[index].expanding = true
    if !sections[index].busy { expand(index) }
    return true
  }

  mutating func expand(_ index: Int) {
    let size = min(sections[index].size + pageStep, pageMax)
    round += 1
    queueSection(index, size: size)
  }

  /// Teams exist only in organizations, so without a membership nothing
  /// can reach the viewer through one.
  public var showTeamQueue: Bool {
    membership != .answered(.none)
  }

  public var showOwnerTabs: Bool { mixedOwners }

  /// The next job to start, if a slot is free. Sections go first, so rows
  /// never wait behind check lookups.
  public mutating func nextJob() -> Ticket? {
    if running >= concurrency { return nil }
    let job: Job
    let jobRound: UInt64
    if !sectionsQueued.isEmpty {
      let q = sectionsQueued.removeFirst()
      job = .section(index: q.index, size: q.size)
      jobRound = q.round
    } else if membership == .due {
      membership = .asked
      (job, jobRound) = (.membership, round)
    } else if !checksQueued.isEmpty {
      let n = min(checksQueued.count, checkBatch)
      job = .checks(ids: Array(checksQueued.prefix(n)))
      checksQueued.removeFirst(n)
      jobRound = round
    } else {
      return nil
    }
    running += 1
    return Ticket(job: job, epoch: epoch, round: jobRound)
  }

  public var anyBusy: Bool {
    running > 0 || !sectionsQueued.isEmpty || !checksQueued.isEmpty || membership == .due
  }

  /// Applies a finished job. Returns true when it revealed a different
  /// account: everything was cleared and a refresh should follow.
  @discardableResult
  public mutating func finish(_ ticket: Ticket, _ outcome: Outcome, now: Instant) -> Bool {
    running = max(running - 1, 0)
    if ticket.epoch != epoch { return false }
    let answered = outcome.identity
    let switched = answered != nil && identity != nil && answered != identity
    if switched { reset() }
    if let answered { identity = answered }
    switch (ticket.job, outcome) {
    case (.section(let index, let size), .section(let fetch)):
      // After a switch the section was reset to idle; this result still
      // belongs to the new account.
      let expansion = size > sections[index].size
      let loaded = sections[index].apply(size: size, round: ticket.round, fetch: fetch, now: now)
      if sections[index].expanding && (expansion || !sections[index].canLoadMore) {
        sections[index].expanding = false
      }
      placeRows(answered: loaded ? index : nil)
      if loaded {
        trackChecks(index)
        noteOwners()
      }
      // A "Load more" that arrived during a refresh.
      if sections[index].expanding && !sections[index].busy { expand(index) }
    case (.membership, .membership(let fetch)):
      membership = .answered(fetch.membership)
    case (.checks, .checks(let fetch)):
      applyChecks(fetch)
    default:
      break
    }
    return switched
  }

  mutating func reset() {
    // Filters start over too: the new account's controls may be hidden.
    var fresh = Inbox()
    fresh.epoch = epoch + 1
    fresh.round = round
    fresh.running = running
    self = fresh
  }

  /// Unfiltered, so choosing a tab can never hide the tabs.
  mutating func noteOwners() {
    if mixedOwners { return }
    let kinds = Set(sections.flatMap(\.items).map(\.repository.ownerKind))
    mixedOwners = kinds.contains(.personal) && kinds.contains(.organization)
  }

  /// Expects each PR's head from the copy that is displayed, looks up checks
  /// for a section's PRs, and forgets PRs no longer displayed.
  mutating func trackChecks(_ index: Int) {
    var shownHeads: [String: String] = [:]
    for (section, shown) in zip(sections, deduplicated()) {
      for i in shown {
        if let head = section.items[i].head { shownHeads[section.items[i].id] = head }
      }
    }
    // An error describes the head it was asked for.
    let oldHeads = heads
    checkErrors = checkErrors.filter { shownHeads[$0.key] == oldHeads[$0.key] }
    let wanted = sections[index].items.compactMap { item in shownHeads[item.id].map { (item.id, $0) } }
    checks = checks.filter { shownHeads[$0.key] != nil }
    heads = shownHeads
    // A lookup already running for another head is followed up when it
    // finishes.
    for (id, head) in wanted where checksPending[id] == nil {
      queueCheck(id, head: head)
    }
  }

  /// Shown state and errors stay until the answer replaces them.
  mutating func queueCheck(_ id: String, head: String) {
    checksPending[id] = head
    checksQueued.append(id)
  }

  mutating func applyChecks(_ fetch: ChecksFetch) {
    for (id, result) in fetch.results {
      // Not pending: the PR left every section, or the account changed.
      guard let asked = checksPending.removeValue(forKey: id), let wanted = heads[id] else { continue }
      if asked != wanted {
        // A section showed a newer head while this lookup ran.
        if case .success(let state) = result { checks[id] = state }
        checkErrors[id] = nil
        queueCheck(id, head: wanted)
        continue
      }
      switch result {
      case .success(let state) where state.head != wanted:
        checkErrors[id] = .otherCommit
        checks[id] = state
      case .success(let state):
        checkErrors[id] = nil
        checks[id] = state
      case .failure(let error):
        checkErrors[id] = error
      }
    }
  }

  /// nil for issues.
  public func check(_ item: Item) -> CheckView? {
    guard let head = item.head else { return nil }
    let error = checkErrors[item.id]
    if let state = checks[item.id], state.head == head {
      return .known(checks: state.checks, stale: error != nil)
    }
    return error.map { .failed($0) } ?? .loading
  }

  /// Lookups that failed for the rows on screen: how many, and the first error.
  public func checkFailures() -> (count: Int, first: GhError)? {
    let failed = zip(sections, visible()).flatMap { section, shown in
      shown.compactMap { checkErrors[section.items[$0].id] }
    }
    return failed.first.map { (failed.count, $0) }
  }

  /// The error every section's latest attempt failed with, when they all
  /// share one: it is shown once instead of under each section.
  public var commonError: GhError? {
    guard let first = sections.first?.error else { return nil }
    return sections.allSatisfy { $0.error == first } ? first : nil
  }

  public var anyLoaded: Bool { sections.contains(where: \.loaded) }

  /// When data last arrived for any section.
  public var updated: Instant? { sections.compactMap(\.fetchedAt).max() }

  /// The indexes of each section's items to show: `deduplicated`, less what
  /// the owner tab hides.
  public func visible() -> [[Int]] {
    zip(sections, deduplicated()).map { section, shown in
      shown.filter { ownerFilter.matches(section.items[$0]) }
    }
  }

  /// Keeps each row in its section until a successful fetch drops it there,
  /// or an earlier section's successful fetch (`answered`) claims it; a new
  /// item goes to the first section with it. Failed and pending fetches
  /// never move a row. A row shows the newest copy of its item, but keeps
  /// its own section's review route.
  mutating func placeRows(answered: Int?) {
    var holders: [String: [Int]] = [:]
    for (s, section) in sections.enumerated() {
      for item in section.items where holders[item.url, default: []].last != s {
        holders[item.url, default: []].append(s)
      }
    }
    var newPlaced: [String: Int] = [:]
    var reranked = Set<Int>()
    for (url, holding) in holders {
      let held = placed[url].flatMap { holding.contains($0) ? $0 : nil }
      let place: Int
      if let held, let answered, answered < held, holding.contains(answered) {
        place = answered
      } else {
        place = held ?? holding[0]
      }
      func roundOf(_ s: Int) -> UInt64 { sections[s].rounds[url] ?? 0 }
      let newest = holding.reduce(place) { best, s in roundOf(s) > roundOf(best) ? s : best }
      if newest != place,
        let fresh = sections[newest].items.first(where: { $0.url == url }),
        let slot = sections[place].items.firstIndex(where: { $0.url == url })
      {
        let freshRound = roundOf(newest)
        var copy = fresh
        copy.reviewRoute = sections[place].items[slot].reviewRoute
        sections[place].items[slot] = copy
        sections[place].rounds[url] = freshRound
        reranked.insert(place)
      }
      newPlaced[url] = place
    }
    for s in reranked { rank(&sections[s].items, by: GhInboxCore.sections[s].ranking) }
    placed = newPlaced
  }

  /// Each item once, in the section `placeRows` chose.
  func deduplicated() -> [[Int]] {
    var shown = Set<String>()
    return sections.enumerated().map { s, section in
      section.items.indices.filter { i in
        let url = section.items[i].url
        return placed[url] == s && shown.insert(url).inserted
      }
    }
  }
}

/// "just now", "4m ago", "2h ago".
public func ago(_ then: Instant, _ now: Instant) -> String {
  let secs = max(0, (now - then).components.seconds)
  switch secs {
  case ..<60: return "just now"
  case ..<3600: return "\(secs / 60)m ago"
  default: return "\(secs / 3600)h ago"
  }
}
