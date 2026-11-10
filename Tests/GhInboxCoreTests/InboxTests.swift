import Testing

@testable import GhInboxCore

private func me() -> Identity { Identity(login: "me", host: "github.com") }
private func someoneElse() -> Identity { Identity(login: "work-me", host: "github.com") }

func issue(_ url: String) -> Item {
  Item(
    id: url, number: 1, title: "t", repository: Repository(name: "r", nameWithOwner: "o/r", owner: nil),
    isPullRequest: false, isDraft: false, head: nil, review: nil, reviewRoute: nil, url: url,
    updatedAt: "2026-11-01T00:00:00Z", author: "a")
}

func pr(_ id: String, _ head: String) -> Item {
  var item = issue(id)
  item.isPullRequest = true
  item.head = head
  return item
}

private func titled(_ title: String, _ item: Item = issue("x")) -> Item {
  var item = item
  item.title = title
  return item
}

func ok(_ items: [Item]) -> SectionFetch {
  SectionFetch(
    identity: me(),
    page: .success(Page(items: items, total: items.count, truncated: false, returned: items.count)),
    warnings: [])
}

func truncated(_ items: [Item], _ total: Int) -> SectionFetch {
  var fetch = ok(items)
  if case .success(var page) = fetch.page {
    page.truncated = true
    page.total = total
    fetch.page = .success(page)
  }
  return fetch
}

private func failed(_ error: GhError) -> SectionFetch {
  SectionFetch(identity: me(), page: .failure(error), warnings: [])
}

private func ghFailed() -> SectionFetch { failed(.gh("x")) }

private func noChecks(_ ids: [String]) -> Outcome {
  .checks(
    ChecksFetch(
      identity: me(), results: ids.map { ($0, .success(CheckState(head: "\($0)-head", checks: nil))) }))
}

private func member(_ membership: Membership) -> Outcome {
  .membership(MembershipFetch(identity: me(), membership: membership))
}

private func passing(_ head: String) -> Result<CheckState, GhError> {
  .success(CheckState(head: head, checks: .passing))
}

private let now = ContinuousClock.now

/// Starts every startable job, answering until none is left. Section `i` gets
/// `answers[i]`; a section without an answer, or a nil from `checks`, stays
/// running.
@discardableResult
private func drain(
  _ inbox: inout Inbox, _ answers: [SectionFetch?], at time: Instant = now,
  checks: ([String]) -> Outcome? = { _ in nil }
) -> [Ticket] {
  var answers = answers
  var unanswered: [Ticket] = []
  while let ticket = inbox.nextJob() {
    let outcome: Outcome?
    switch ticket.job {
    case .section(let index, _):
      outcome = answers.indices.contains(index) ? answers[index].map { .section($0) } : nil
      if answers.indices.contains(index) { answers[index] = nil }
    case .checks(let ids): outcome = checks(ids)
    case .membership: outcome = member(.member)
    }
    if let outcome {
      inbox.finish(ticket, outcome, now: time)
    } else {
      unanswered.append(ticket)
    }
  }
  return unanswered
}

/// A full refresh where every section answers and every PR has no checks.
private func refreshWith(_ inbox: inout Inbox, _ answers: [SectionFetch], at time: Instant = now) {
  inbox.refresh()
  let left = drain(&inbox, answers, at: time, checks: noChecks)
  #expect(left.isEmpty, "every job answered")
}

private func four(_ a: SectionFetch, _ b: SectionFetch) -> [SectionFetch] {
  [a, b, ok([]), ok([]), ok([])]
}

/// Answers the queued review fetch, and any check lookups it starts.
private func answerReview(_ inbox: inout Inbox, _ fetch: SectionFetch) {
  let left = drain(&inbox, [fetch], checks: noChecks)
  #expect(left.isEmpty, "every job answered")
}

private func jobs(_ inbox: inout Inbox) -> [Ticket] {
  var tickets: [Ticket] = []
  while let ticket = inbox.nextJob() { tickets.append(ticket) }
  return tickets
}

private func urls(_ section: SectionView) -> [String] { section.items.map(\.url) }

private func owned(_ item: Item, _ typename: String) -> Item {
  var item = item
  item.repository.owner = Owner(typename: typename)
  return item
}

private func firstTwo(_ inbox: Inbox) -> [[Int]] { Array(inbox.visible().prefix(2)) }

/// Check lookups that find every PR at `head`.
private func checksAt(_ head: String) -> ([String]) -> Outcome? {
  { ids in
    .checks(
      ChecksFetch(
        identity: me(), results: ids.map { ($0, .success(CheckState(head: head, checks: .passing))) }))
  }
}

/// Everything a refresh could visibly change in the list.
private func screen(_ inbox: Inbox) -> String {
  let rows = zip(inbox.sections, inbox.visible()).map { section, shown in
    let items = shown.map { i in
      let item = section.items[i]
      return "\(item.url)@\(String(describing: item.head)):\(String(describing: inbox.check(item)))"
    }
    return
      "\(section.name) [\(items.joined(separator: ", "))] error=\(String(describing: section.error)) more=\(section.canLoadMore)/\(section.expanding)"
  }
  return rows.joined(separator: "\n") + "\nbanner=\(String(describing: inbox.checkFailures()))"
}

/// `screen` without each section's error.
private func rowsAndDots(_ inbox: Inbox) -> String { withoutErrors(screen(inbox)) }

private func withoutErrors(_ screen: String) -> String {
  screen.split(separator: "\n").map { line in
    line.range(of: " error=").map { String(line[..<$0.lowerBound]) } ?? String(line)
  }.joined(separator: "\n")
}

/// Checks answer for every PR except `bad`, which fails.
private func checksWithOneFailure(_ ids: [String]) -> Outcome? {
  .checks(
    ChecksFetch(
      identity: me(),
      results: ids.map { id in (id, id == "bad" ? .failure(.server("502")) : passing("\(id)-head")) }))
}

private func sample() -> [SectionFetch] {
  let shared = pr("shared", "shared-head")
  return four(truncated([shared, pr("bad", "bad-head")], 40), ok([shared, pr("mine", "mine-head")]))
}

/// Starts a refresh, then answers its sections one at a time in `order`,
/// returning the screen after each answer; check lookups stay running.
private func refreshOneByOne(_ inbox: inout Inbox, _ answers: [SectionFetch], _ order: [Int]) -> [String] {
  inbox.refresh()
  var tickets = jobs(&inbox).filter { if case .section = $0.job { true } else { false } }
  var screens = [screen(inbox)]
  for index in order {
    let at = tickets.firstIndex { if case .section(index, _) = $0.job { true } else { false } }!
    let ticket = tickets.remove(at: at)
    inbox.finish(ticket, .section(answers[index]), now: now)
    screens.append(screen(inbox))
  }
  return screens
}

/// One PR shown under review, with its check lookups answered by `answer`.
private func withCheck(_ answer: Result<CheckState, GhError>) -> (Inbox, Item) {
  let item = pr("PR_a", "h1")
  var inbox = Inbox()
  inbox.refresh()
  drain(&inbox, [ok([item]), ok([]), ok([]), ok([]), ok([])]) { ids in
    .checks(ChecksFetch(identity: me(), results: ids.map { ($0, answer) }))
  }
  return (inbox, item)
}

/// A full refresh answering every section; check lookups are left queued.
private func refreshWithPending(_ inbox: inout Inbox, _ answers: [SectionFetch]) {
  inbox.refresh()
  while let ticket = inbox.nextJob() {
    guard case .section(let index, _) = ticket.job else {
      Issue.record("only sections expected")
      return
    }
    inbox.finish(ticket, .section(answers.indices.contains(index) ? answers[index] : ok([])), now: now)
  }
}

/// Starts jobs until the membership check, answering every section empty.
private func answerMembership(_ inbox: inout Inbox, _ membership: Membership) {
  while let ticket = inbox.nextJob() {
    switch ticket.job {
    case .membership:
      inbox.finish(ticket, member(membership), now: now)
      return
    case .section: inbox.finish(ticket, .section(ok([])), now: now)
    case .checks(let ids): inbox.finish(ticket, noChecks(ids), now: now)
    }
  }
  Issue.record("the membership check is queued")
}

/// x shown in review, whose fetch failed after its copy at commit A, while
/// authored has a newer copy at B.
private func splitRounds() -> Inbox {
  var inbox = Inbox()
  inbox.refresh()
  drain(&inbox, four(ok([pr("x", "A")]), ok([])), checks: checksAt("A"))
  inbox.refresh()
  drain(&inbox, four(ghFailed(), ok([pr("x", "B")])), checks: checksAt("B"))
  #expect(firstTwo(inbox) == [[0], []])
  #expect(inbox.sections[0].items[0].head == "B")
  return inbox
}

struct SectionStateTests {
  @Test func aFailedSectionKeepsItsItemsSizeAndSaysWhy() {
    let t0 = ContinuousClock.now
    let t1 = t0 + .seconds(120)
    var inbox = Inbox()
    refreshWith(&inbox, four(ok([issue("x")]), ok([])), at: t0)
    refreshWith(&inbox, four(failed(.server("502")), ok([])), at: t1)
    let a = inbox.sections[0]
    #expect(a.items.count == 1)
    #expect(a.error == .server("502"))
    #expect(a.fetchedAt == t0)
    #expect(inbox.updated == t1, "other sections did arrive")
  }

  @Test func aNewerCopyReranksMyPrsByMyOrder() {
    let waiting = pr("waiting", "h")
    var later = pr("later", "h")
    var inbox = Inbox()
    refreshWith(&inbox, [ok([]), ok([]), ok([waiting, later]), ok([]), ok([later])])
    // My open PRs fails; Also in my repos brings the newer, approved copy.
    later.review = .approved
    refreshWith(&inbox, [ok([]), ok([]), ghFailed(), ok([]), ok([later])])
    #expect(urls(inbox.sections[2]) == ["later", "waiting"])
  }

  @Test func recoveryClearsErrorsAndNeverLoadedIsNotEmpty() {
    var inbox = Inbox()
    refreshWith(&inbox, four(ghFailed(), ok([])))
    #expect(!inbox.sections[0].loaded)
    #expect(inbox.sections[1].loaded)
    refreshWith(&inbox, four(ok([issue("y")]), ok([])))
    #expect(inbox.sections[0].error == nil)
    #expect(inbox.sections[0].loaded)
  }

  @Test func oneSharedFailureIsReportedOnce() {
    var inbox = Inbox()
    let down = { failed(.network("dial tcp")) }
    refreshWith(&inbox, [down(), down(), down(), down(), down()])
    #expect(inbox.commonError == .network("dial tcp"))
    #expect(!inbox.anyLoaded)
    refreshWith(&inbox, [down(), ghFailed(), down(), down(), down()])
    #expect(inbox.commonError == nil, "different failures are shown apart")
  }

  @Test func sectionsRenderAsEachArrives() {
    var inbox = Inbox()
    inbox.refresh()
    let left = drain(&inbox, [nil, ok([issue("x")])])
    #expect(left.count == 4, "the other sections still running")
    #expect(inbox.sections[1].loaded && !inbox.sections[0].loaded)
    #expect(inbox.visible()[1] == [0])
    #expect(inbox.anyBusy)
  }

  @Test func noMoreThanTheConcurrencyLimitRunsAndSectionsGoFirst() {
    var inbox = Inbox()
    inbox.checksQueued.append(contentsOf: ["PR_a", "PR_b"])
    inbox.refresh()
    let started = jobs(&inbox)
    #expect(started.count == concurrency)
    #expect(started.allSatisfy { if case .section(_, pageStep) = $0.job { true } else { false } })
    let v1 = inbox.refresh()
    #expect(v1 == 0, "busy sections are not queued twice")
  }

  @Test func scheduleFollowsPresence() {
    func s(_ n: Int64) -> Duration { .seconds(n) }
    #expect(due(.tick, presence: .focused, sinceAttempt: nil), "first load")
    #expect(!due(.tick, presence: .focused, sinceAttempt: s(119)))
    #expect(due(.tick, presence: .focused, sinceAttempt: s(120)))
    #expect(!due(.tick, presence: .background, sinceAttempt: s(599)))
    #expect(due(.tick, presence: .background, sinceAttempt: s(600)))
    #expect(!due(.focus, presence: .focused, sinceAttempt: s(29)))
    #expect(due(.focus, presence: .focused, sinceAttempt: s(30)))
    #expect(!due(.focus, presence: .background, sinceAttempt: s(3600)))
    #expect(!due(.tick, presence: .closed, sinceAttempt: nil), "closed fetches nothing")
    #expect(!due(.tick, presence: .closed, sinceAttempt: s(86400)))
  }

  @Test func agesReadNaturally() {
    let t = ContinuousClock.now
    #expect(ago(t, t + .seconds(59)) == "just now")
    #expect(ago(t, t + .seconds(250)) == "4m ago")
    #expect(ago(t, t + .seconds(7300)) == "2h ago")
  }
}

struct AccountTests {
  @Test func aNewAccountClearsEverythingAndDropsLateResults() {
    var inbox = Inbox()
    refreshWith(&inbox, four(ok([issue("x")]), ok([issue("y")])))
    inbox.refresh()
    var tickets = jobs(&inbox)

    var theirs = ok([issue("z")])
    theirs.identity = someoneElse()
    let v2 = inbox.finish(tickets.removeFirst(), .section(theirs), now: now)
    #expect(v2)
    #expect(inbox.identity == someoneElse())
    #expect(inbox.sections[0].items[0].url == "z")
    #expect(inbox.sections[1].items.isEmpty, "nothing of the old account survives")

    // The old account's response, issued before the switch, arrives late.
    let v3 = inbox.finish(tickets.removeFirst(), .section(ok([issue("y")])), now: now)
    #expect(!v3)
    #expect(inbox.sections[1].items.isEmpty)
    #expect(inbox.identity == someoneElse())
  }

  @Test func aCheckLookupFromAnotherAccountAlsoResets() {
    var inbox = Inbox()
    inbox.refresh()
    // The last section frees a slot, so the check lookup starts.
    let left = drain(&inbox, [ok([pr("PR_a", "h1")]), nil, nil, nil, ok([])])
    let check = left.first { if case .checks = $0.job { true } else { false } }!
    let theirs = Outcome.checks(ChecksFetch(identity: someoneElse(), results: [("PR_a", passing("h1"))]))
    let v4 = inbox.finish(check, theirs, now: now)
    #expect(v4)
    #expect(!inbox.anyLoaded)
    #expect(inbox.check(pr("PR_a", "h1")) == .loading)
  }

  @Test func theTeamQueueShowsUnlessMembershipRulesTeamsOut() {
    for (membership, shown) in [(Membership.none, false), (.member, true), (.unknown, true)] {
      var inbox = Inbox()
      #expect(inbox.showTeamQueue, "shown until ruled out, so it never appears late")
      inbox.refresh()
      answerMembership(&inbox, membership)
      #expect(inbox.showTeamQueue == shown, "\(membership)")
      inbox.refresh()
      let v5 = jobs(&inbox)
      #expect(!v5.contains { $0.job == .membership }, "once per account")
    }
  }

  @Test func noTeamsHidesTheTeamQueue() {
    var inbox = Inbox()
    inbox.refresh()
    answerMembership(&inbox, .none)
    #expect(!queues(inbox).contains { $0.section == teamSection })
    #expect(queues(inbox).count == sections.count - 1)
  }

  @Test func aMembershipAnswerForTheOldAccountIsDropped() {
    var inbox = Inbox()
    inbox.refresh()
    var tickets = jobs(&inbox)
    inbox.finish(tickets.removeFirst(), .section(ok([])), now: now)
    // The fifth section takes the freed slot; the next one goes to membership.
    tickets.append(inbox.nextJob()!)
    inbox.finish(tickets.removeFirst(), .section(ok([])), now: now)
    let membership = inbox.nextJob()!
    #expect(membership.job == .membership)

    var theirs = ok([])
    theirs.identity = someoneElse()
    let v6 = inbox.finish(tickets.removeFirst(), .section(theirs), now: now)
    #expect(v6)
    inbox.finish(membership, member(.none), now: now)
    #expect(inbox.showTeamQueue)
    #expect(inbox.membership == .due, "asked again")
  }

  @Test func aNewAccountStartsWithDefaultFilters() {
    var inbox = Inbox()
    refreshWith(&inbox, four(ok([]), ok([])))
    inbox.ownerFilter = .personal
    inbox.mixedOwners = true
    inbox.refresh()
    let ticket = inbox.nextJob()!
    var theirs = ok([])
    theirs.identity = someoneElse()
    let v8 = inbox.finish(ticket, .section(theirs), now: now)
    #expect(v8)
    #expect(inbox.ownerFilter == .all)
    #expect(!inbox.showOwnerTabs && inbox.showTeamQueue)
  }
}

struct PlacementTests {
  @Test func aFailedSectionKeepsItsRowAndShowsTheNewerCopy() {
    var inbox = Inbox()
    refreshWith(&inbox, four(ok([titled("old")]), ok([])))
    // Review fails and keeps x; authored now returns x freshly.
    refreshWith(&inbox, four(ghFailed(), ok([titled("new"), issue("y")])))
    #expect(firstTwo(inbox) == [[0], [1]])
    #expect(inbox.sections[0].items[0].title == "new")
  }

  @Test func aRowStaysPutWhileEverySectionFails() {
    var inbox = Inbox()
    refreshWith(&inbox, four(ok([issue("x")]), ok([])))
    refreshWith(&inbox, four(ghFailed(), ok([issue("x")])))
    #expect(firstTwo(inbox) == [[0], []])
    refreshWith(&inbox, four(ghFailed(), ghFailed()))
    #expect(firstTwo(inbox) == [[0], []])
  }

  @Test func oneRoundFallsBackToSectionOrderWhateverArrivesFirst() {
    var inbox = Inbox()
    inbox.refresh()
    // Authored answers first, then review, both with x.
    drain(&inbox, [nil, ok([issue("x")])])
    let review = Ticket(
      job: .section(index: 0, size: pageStep), epoch: inbox.epoch, round: inbox.round)
    inbox.finish(review, .section(ok([issue("x")])), now: now)
    #expect(firstTwo(inbox) == [[0], []])
  }

  @Test func staleItemsNotRefetchedElsewhereStayVisible() {
    var inbox = Inbox()
    refreshWith(&inbox, four(ok([issue("x")]), ok([])))
    refreshWith(&inbox, four(ghFailed(), ok([])))
    #expect(inbox.visible()[0] == [0])
  }

  @Test func anIdenticalRefreshChangesNothingOnScreenAtAnyPoint() {
    var inbox = Inbox()
    inbox.refresh()
    drain(&inbox, sample(), checks: checksWithOneFailure)
    let before = screen(inbox)
    #expect(before.contains("server"), "a failed check is part of the test")

    // Authored answers first: its fresh copy of `shared` must not pull the
    // row out of review while review is still loading.
    for shown in refreshOneByOne(&inbox, sample(), [1, 2, 3, 0]) {
      #expect(shown == before)
    }
  }

  @Test func aFailedRefreshChangesOnlyThatSectionsStatus() {
    var inbox = Inbox()
    inbox.refresh()
    drain(&inbox, sample(), checks: checksWithOneFailure)
    let before = rowsAndDots(inbox)

    var answers = sample()
    answers[1] = ghFailed()
    _ = refreshOneByOne(&inbox, answers, [0, 1, 2, 3])
    #expect(rowsAndDots(inbox) == before)
    #expect(inbox.sections.map { $0.error != nil } == [false, true, false, false, false])
  }

  @Test func aChangedRefreshTouchesOnlyTheChangedRows() {
    var inbox = Inbox()
    inbox.refresh()
    drain(&inbox, sample(), checks: checksWithOneFailure)

    var answers = sample()
    answers[1] = ok([pr("shared", "shared-head"), pr("new", "new-head")])
    _ = refreshOneByOne(&inbox, answers, [0, 1, 2, 3])
    let visible = inbox.visible()
    let shown = { (s: Int) in visible[s].map { inbox.sections[s].items[$0].url } }
    #expect(shown(0) == ["shared", "bad"], "untouched")
    #expect(shown(1) == ["new"], "mine left, new arrived")
    #expect(inbox.check(pr("shared", "shared-head")) == .known(checks: .passing, stale: false))
  }

  @Test func startingOrFailingARefreshChangesNothingShown() {
    var inbox = splitRounds()
    let before = screen(inbox)
    for shown in refreshOneByOne(&inbox, four(ghFailed(), ok([pr("x", "B")])), [0, 1, 2, 3]) {
      #expect(shown == before)
    }
  }

  @Test func aRowMovesOnlyWhenASuccessfulFetchDropsIt() {
    var inbox = splitRounds()
    let before = rowsAndDots(inbox)
    let screens = refreshOneByOne(&inbox, four(ok([]), ok([pr("x", "B")])), [1, 2, 3, 0])
    #expect(screens.count == 5)
    for shown in screens.prefix(4) {
      #expect(withoutErrors(shown) == before, "nothing moves before review answers")
    }
    #expect(firstTwo(inbox) == [[], [0]], "review no longer has x")
  }

  @Test func aFailedSectionKeepsItsRowReviewRouteAndTakesNewerData() {
    var requested = titled("old", pr("x", "A"))
    requested.reviewRoute = .team("platform")
    var inbox = Inbox()
    inbox.refresh()
    drain(&inbox, four(ok([requested]), ok([pr("x", "A")])), checks: checksAt("A"))

    inbox.refresh()
    drain(&inbox, four(ghFailed(), ok([titled("new", pr("x", "B"))])), checks: checksAt("B"))
    #expect(firstTwo(inbox) == [[0], []], "still in review")
    let shown = inbox.sections[0].items[0]
    #expect(shown.title == "new" && shown.head == "B")
    #expect(shown.reviewRoute == .team("platform"), "authored's copy has no route to give")
    #expect(inbox.check(shown) == .known(checks: .passing, stale: false))
    #expect(inbox.sections[0].error != nil)
  }

  @Test func copiedDataKeepsItsOwnFreshness() {
    func shownHeads(_ inbox: Inbox) -> [String] {
      let visible = inbox.visible()
      return (0..<3).flatMap { s in visible[s].map { "\(s):\(inbox.sections[s].items[$0].head ?? "")" } }
    }
    var inbox = Inbox()
    // Round 1: review has A. Round 2: review fails, assigned has A.
    refreshWith(&inbox, [ok([pr("x", "A")]), ok([]), ok([]), ok([]), ok([])])
    refreshWith(&inbox, [ghFailed(), ok([]), ok([pr("x", "A")]), ok([]), ok([])])
    // Round 3: authored brings B; review shows it in place.
    refreshWith(&inbox, [ghFailed(), ok([pr("x", "B")]), ghFailed(), ok([]), ok([])])
    #expect(shownHeads(inbox) == ["0:B"])
    // Round 4: authored drops x while review and assigned fail.
    refreshWith(&inbox, [ghFailed(), ok([]), ghFailed(), ok([]), ok([])])
    #expect(shownHeads(inbox) == ["0:B"], "assigned's round-2 copy is older than B")
  }
}

struct LoadMoreTests {
  @Test func loadMoreGrowsOneSectionAndRefreshesKeepTheSize() {
    var inbox = Inbox()
    let v9 = inbox.loadMore(1)
    #expect(!v9, "nothing to load yet")
    refreshWith(&inbox, four(ok([]), truncated([issue("x")], 60)))
    let v10 = inbox.loadMore(1)
    #expect(v10)
    let v11 = inbox.loadMore(1)
    #expect(!v11, "already loading")
    var ticket = inbox.nextJob()!
    #expect(ticket.job == .section(index: 1, size: 50))
    let v12 = inbox.nextJob()
    #expect(v12 == nil, "only that section")

    // A failed expansion keeps the rows and the last size that worked.
    inbox.finish(ticket, .section(ghFailed()), now: now)
    #expect(inbox.sections[1].size == pageStep)
    #expect(inbox.sections[1].items.count == 1)

    let v13 = inbox.loadMore(1)
    #expect(v13)
    ticket = inbox.nextJob()!
    inbox.finish(ticket, .section(truncated([issue("x"), issue("y")], 60)), now: now)
    #expect(inbox.sections[1].size == 50)

    inbox.refresh()
    let sizes = jobs(&inbox).map(\.job)
    #expect(sizes.contains(.section(index: 1, size: 50)))
    #expect(sizes.contains(.section(index: 0, size: pageStep)))
  }

  @Test func anExpandedSectionRefreshesADuplicateShownEarlier() {
    var inbox = Inbox()
    refreshWith(&inbox, four(ok([titled("old")]), truncated([titled("old")], 60)))
    #expect(firstTwo(inbox) == [[0], []])
    let v14 = inbox.loadMore(1)
    #expect(v14)
    let ticket = inbox.nextJob()!
    inbox.finish(ticket, .section(truncated([titled("new"), issue("y")], 60)), now: now)
    #expect(firstTwo(inbox) == [[0], [1]], "first match wins")
    #expect(inbox.sections[0].items[0].title == "new", "the newer copy")
  }

  @Test func loadMoreStopsAtGitHubsPageLimit() {
    var section = SectionView(name: "s")
    section.truncated = true
    section.size = pageMax
    #expect(!section.canLoadMore, "past this, the search link")
    section.size = pageMax - pageStep
    #expect(section.canLoadMore)
  }

  @Test func loadMoreDuringARefreshWaitsForItThenRuns() {
    var inbox = Inbox()
    refreshWith(&inbox, four(truncated([issue("a")], 60), ok([])))
    inbox.refresh()
    #expect(!inbox.sections[0].expanding, "a refresh alone isn't loading more")
    let v15 = inbox.loadMore(0)
    #expect(v15)
    let v16 = inbox.loadMore(0)
    #expect(!v16, "asked once")
    let refresh = inbox.nextJob()!
    #expect(refresh.job == .section(index: 0, size: pageStep))
    inbox.finish(refresh, .section(truncated([issue("a")], 60)), now: now)
    #expect(inbox.sections[0].expanding)
    // The other sections' refreshes free the slots the expansion waits for.
    var sizes: [Int] = []
    while let ticket = inbox.nextJob() {
      if case .section(0, let size) = ticket.job { sizes.append(size) }
      inbox.finish(ticket, .section(ok([])), now: now)
    }
    #expect(sizes == [2 * pageStep])
  }
}

struct ReviewModeTests {

  @Test func ownerTabsAppearOnceBothOwnerTypesLoadAndStay() {
    let org = { owned(issue("org"), "Organization") }
    let mine = { owned(issue("mine"), "User") }
    var inbox = Inbox()
    refreshWith(&inbox, four(ghFailed(), ok([])))
    #expect(!inbox.showOwnerTabs, "nothing loaded")
    refreshWith(&inbox, four(truncated([org()], 30), ok([])))
    #expect(!inbox.showOwnerTabs, "one owner type")

    inbox.ownerFilter = .personal
    let v31 = inbox.loadMore(0)
    #expect(v31)
    let v32 = drain(&inbox, [ok([org(), mine()])], checks: noChecks)
    #expect(v32.isEmpty)
    #expect(inbox.showOwnerTabs, "revealed by a later page")

    refreshWith(&inbox, four(ok([org()]), ok([])))
    #expect(inbox.showOwnerTabs, "kept for the account")
  }
}

struct CheckStateTests {
  @Test func theCheckBannerCountsOnlyRowsTheOwnerTabShows() {
    let orgError = GhError.server("502")
    let mineError = GhError.rateLimited("slow down")
    var inbox = Inbox()
    inbox.refresh()
    let answers = four(
      ok([owned(pr("org_a", "org_a-head"), "Organization"), owned(pr("mine_bad", "mine_bad-head"), "User")]),
      ok([owned(pr("org_b", "org_b-head"), "Organization"), owned(pr("mine_ok", "mine_ok-head"), "User")]))
    drain(&inbox, answers) { ids in
      .checks(
        ChecksFetch(
          identity: me(),
          results: ids.map { id in
            let result: Result<CheckState, GhError> =
              id == "mine_bad"
              ? .failure(mineError)
              : id.hasPrefix("org")
                ? .failure(orgError) : .success(CheckState(head: "\(id)-head", checks: nil))
            return (id, result)
          }))
    }
    func banner() -> String { String(describing: inbox.checkFailures()) }
    #expect(inbox.checkFailures()?.count == 3 && inbox.checkFailures()?.first == orgError)
    inbox.ownerFilter = .personal
    #expect(
      inbox.checkFailures()?.count == 1 && inbox.checkFailures()?.first == mineError,
      "the example comes from a shown row")
    inbox.ownerFilter = .organization
    #expect(inbox.checkFailures()?.count == 2 && inbox.checkFailures()?.first == orgError)
    inbox.ownerFilter = .all
    #expect(inbox.checkFailures()?.count == 3 && inbox.checkFailures()?.first == orgError)
  }

  @Test func failuresOnlyOnHiddenRowsRaiseNoBanner() {
    var (inbox, item) = withCheck(.failure(.server("502")))
    #expect(item.repository.owner == nil)
    inbox.ownerFilter = .personal
    #expect(inbox.checkFailures() == nil)
    inbox.ownerFilter = .all
    #expect(inbox.checkFailures() != nil)
  }

  @Test func checksLoadAfterRowsInBatches() {
    var inbox = Inbox()
    let prs = (0..<30).map { pr("PR_\($0)", "h") }
    inbox.refresh()
    var batches: [Int] = []
    drain(&inbox, [ok(prs), ok([issue("i")]), ok([]), ok([]), ok([])]) { ids in
      batches.append(ids.count)
      return nil
    }
    #expect(batches == [checkBatch, 30 - checkBatch])
    #expect(inbox.check(prs[0]) == .loading)
    #expect(inbox.check(issue("i")) == nil, "issues have no checks")
  }

  @Test func aKnownCheckIsShownForItsHeadCommitOnly() {
    let (inbox, item) = withCheck(passing("h1"))
    #expect(inbox.check(item) == .known(checks: .passing, stale: false))
    #expect(
      inbox.check(pr("PR_a", "h2")) == .loading, "a new commit's checks are unknown, not the old commit's")
  }

  @Test func aPendingRecheckKeepsTheDotAsItWas() {
    var (inbox, item) = withCheck(passing("h1"))
    inbox.refresh()
    let left = drain(&inbox, [ok([item]), ok([]), ok([]), ok([]), ok([])])
    #expect(!left.isEmpty, "the recheck is still running")
    #expect(inbox.check(item) == .known(checks: .passing, stale: false))
  }

  @Test func aFailedLookupStaysShownWhileRecheckedUntilANewHead() {
    let error = GhError.server("502")
    let item = pr("PR_a", "h1")
    var inbox = Inbox()
    inbox.refresh()
    drain(&inbox, four(ok([item]), ok([]))) { ids in
      .checks(ChecksFetch(identity: me(), results: ids.map { ($0, .failure(error)) }))
    }

    inbox.refresh()
    let left = drain(&inbox, four(ok([item]), ok([])))
    #expect(left.count == 1, "the recheck is still running")
    #expect(inbox.check(item) == .failed(error))
    #expect(inbox.checkFailures()?.count == 1 && inbox.checkFailures()?.first == error, "no banner flash")

    let moved = pr("PR_a", "h2")
    inbox.refresh()
    drain(&inbox, four(ok([moved]), ok([])))
    #expect(inbox.check(moved) == .loading, "a new commit")
    #expect(inbox.checkFailures() == nil)
  }

  @Test func aFailedLookupIsShownAndCounted() {
    let error = GhError.server("502")
    let (inbox, item) = withCheck(.failure(error))
    #expect(inbox.check(item) == .failed(error))
    #expect(inbox.checkFailures()?.count == 1 && inbox.checkFailures()?.first == error)
  }

  @Test func aFailedRecheckKeepsTheOldStateMarkedStale() {
    var (inbox, item) = withCheck(passing("h1"))
    inbox.refresh()
    drain(&inbox, [ok([item]), ok([]), ok([]), ok([]), ok([])]) { ids in
      .checks(ChecksFetch(identity: nil, results: ids.map { ($0, .failure(.network("down"))) }))
    }
    #expect(inbox.check(item) == .known(checks: .passing, stale: true))
  }

  @Test func aHeadChangeDuringALookupIsFollowedUp() {
    var inbox = Inbox()
    inbox.refresh()
    let left = drain(&inbox, four(ok([pr("PR_a", "h1")]), ok([])))
    #expect(left.count == 1)
    let lookup = left[0]

    // A push lands; the next refresh shows h2 while the h1 lookup still runs.
    refreshWithPending(&inbox, four(ok([pr("PR_a", "h2")]), ok([])))
    inbox.finish(lookup, .checks(ChecksFetch(identity: me(), results: [("PR_a", passing("h1"))])), now: now)
    let shown = pr("PR_a", "h2")
    #expect(inbox.check(shown) == .loading)
    let followUp = inbox.nextJob()
    #expect(followUp?.job == .checks(ids: ["PR_a"]), "loading means a lookup is queued")
    if let followUp {
      inbox.finish(
        followUp, .checks(ChecksFetch(identity: me(), results: [("PR_a", passing("h2"))])), now: now)
    }
    #expect(inbox.check(shown) == .known(checks: .passing, stale: false))
  }

  @Test func checksForAnUnexpectedCommitFailRatherThanLoadForever() {
    let (inbox, item) = withCheck(passing("h9"))
    #expect(inbox.check(item) == .failed(.otherCommit))
    #expect(inbox.checksPending.isEmpty, "nothing left to load")
  }
}
