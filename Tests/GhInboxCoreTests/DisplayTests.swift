import Foundation
import Testing

@testable import GhInboxCore

private let identity = Identity(login: "me", host: "github.com")

private func loaded(_ answers: [SectionFetch]) -> Inbox {
  var inbox = Inbox()
  inbox.refresh()
  while let ticket = inbox.nextJob() {
    switch ticket.job {
    case .section(let index, _):
      inbox.finish(ticket, .section(answers.indices.contains(index) ? answers[index] : ok([])), now: .now)
    case .checks(let ids):
      inbox.finish(
        ticket, .checks(ChecksFetch(identity: identity, results: ids.map { ($0, .failure(.server("502"))) })),
        now: .now)
    case .membership:
      inbox.finish(ticket, .membership(MembershipFetch(identity: identity, membership: .member)), now: .now)
    }
  }
  return inbox
}

private let noon = ISO8601DateFormatter().date(from: "2026-11-08T12:00:00Z")!

/// A fixed moment in a fixed place, so wording never depends on the machine.
private func at(_ instant: Instant = .now, _ date: Date = noon) -> Now {
  Now(
    instant: instant, date: date, timeZone: TimeZone(identifier: "UTC")!, locale: Locale(identifier: "en_US"))
}

extension SectionFetch {
  /// The same fetch, failed.
  var failing: SectionFetch {
    var fetch = self
    fetch.page = .failure(.server("502"))
    return fetch
  }
}

private func notices(_ rows: [RowModel]) -> [Notice] {
  rows.compactMap { if case .notice(let notice) = $0.content { notice } else { nil } }
}

struct DisplayTests {
  @Test func rowsListHeadingsItemsAndOneRowForACutOffSection() {
    let inbox = loaded([truncated([pr("a", "h")], 60), ok([]), ok([issue("b")]), ok([]), ok([])])
    let shown = rows(inbox, now: at())
    #expect(
      shown.map(\.id).prefix(3) == [.heading(section: 0), .item(section: 0, url: "a"), .cutOff(section: 0)])
    #expect(
      shown.first?.content
        == .heading(HeadingRow(name: "Back to me", mark: .count(1, dim: false), ruled: false)))
    #expect(
      shown[2].content
        == .cutOff(
          CutOffRow(
            section: 0, more: .button("Load 25 more"), note: "Showing the newest 1 of 60 matches",
            url: searchURL(0, host: "github.com"))))
    #expect(
      shown[3].content == .heading(HeadingRow(name: "Asked of me", mark: .count(0, dim: true), ruled: true)))
    #expect(shown.compactMap { if case .item(let item) = $0.content { item.owner } else { nil } }.isEmpty)
  }

  /// GitHub may also match a PR asked by name in the team search; it shows
  /// once, in Asked of me, and the team queue says where it went.
  @Test func aPrAskedBothWaysShowsOnlyInAskedOfMe() {
    let both = pr("both", "h")
    let inbox = loaded([ok([]), ok([both]), ok([both, pr("team", "h")]), ok([]), ok([]), ok([])])
    #expect(rows(inbox, queue: 1, now: at()).map(\.id) == [.item(section: 1, url: "both")])
    let team = rows(inbox, queue: teamSection, now: at())
    #expect(team.prefix(1).map(\.id) == [.item(section: teamSection, url: "team")])
    guard case .cutOff(let cut) = team.last?.content else {
      Issue.record("no closing row")
      return
    }
    #expect(cut.note == "1 shown of 2 matches; 1 in other queues")
    #expect(cut.more == .none)
    #expect(queues(inbox).map(\.count) == [0, 1, 2, 0, 0, 0], "the sidebar counts GitHub's totals")
  }

  @Test func myOpenPrsShowTheirGroupsWithoutRepeatingThemOnRows() {
    func mine(_ url: String, _ review: Review?, draft: Bool = false) -> Item {
      var item = pr(url, "h")
      item.review = review
      item.isDraft = draft
      return item
    }
    let prs = [
      mine("a", .approved), mine("c", .changesRequested), mine("w", .required), mine("w2", nil),
      mine("d", nil, draft: true),
    ]
    let inbox = loaded([ok([]), ok([]), ok([]), ok(prs), ok([]), ok([])])
    let shown = rows(inbox, queue: 3, now: at())
    let headings = shown.compactMap { row -> String? in
      if case .heading(let h) = row.content, case .count(let n, _) = h.mark { "\(h.name) \(n)" } else { nil }
    }
    #expect(headings == ["Approved 1", "Changes requested 1", "Awaiting review 2", "Drafts 1"])
    #expect(shown.allSatisfy { if case .item(let item) = $0.content { !item.showsBadge } else { true } })
    let elsewhere = rows(loaded([ok(prs)]), queue: 0, now: at())
    #expect(elsewhere.allSatisfy { if case .item(let item) = $0.content { item.showsBadge } else { true } })
  }

  @Test func theSidebarSaysWhatEachQueueIsDoing() {
    var inbox = Inbox()
    inbox.refresh()
    var tickets: [Ticket] = []
    while let ticket = inbox.nextJob() { tickets.append(ticket) }
    #expect(queues(inbox).prefix(4).map(\.status) == [.loading, .loading, .loading, .loading])
    inbox.finish(tickets[0], .section(ok([issue("x")])), now: .now)
    inbox.finish(tickets[1], .section(ok([]).failing), now: .now)
    #expect(queues(inbox).prefix(2).map(\.status) == [.ready, .failed])
    #expect(emptyText(inbox, queue: 1) == nil, "a failure isn't emptiness")
    inbox.refresh()
    while let ticket = inbox.nextJob() {
      guard case .section(let index, _) = ticket.job else { continue }
      inbox.finish(ticket, .section(index == 0 ? ok([]).failing : ok([])), now: .now)
    }
    #expect(queues(inbox)[0].status == .stale, "the earlier rows stay")
    #expect(queues(inbox)[0].count == 1)
  }

  @Test func aQueuesFailureIsABannerNotARow() {
    var inbox = loaded([ok([issue("x")]), ok([]), ok([]), ok([]), ok([])])
    inbox.refresh()
    while let ticket = inbox.nextJob() {
      let fetch = ticket.job == .section(index: 0, size: pageStep) ? ok([]).failing : ok([])
      inbox.finish(ticket, .section(fetch), now: .now)
    }
    #expect(rows(inbox, queue: 0, now: at()).map(\.id) == [.item(section: 0, url: "x")])
    #expect(banners(inbox, queue: 0, now: at()).map(\.tone) == [.error])
    #expect(banners(inbox, queue: 2, now: at()).isEmpty, "only the queue shown")
  }

  /// Back to me counts only what came back; what waits on its author is
  /// neither a row nor a gap to explain.
  @Test func backToMeCountsOnlyWhatCameBack() {
    func back(_ items: [Item], waiting: Int, total: Int, truncated: Bool = false) -> SectionFetch {
      var fetch = ok(items)
      fetch.page = .success(
        Page(items: items, total: total, truncated: truncated, returned: min(total, 25), waiting: waiting))
      return fetch
    }
    let some = loaded([back([pr("a", "h")], waiting: 2, total: 3)])
    #expect(queues(some)[0].count == 1)
    #expect(rows(some, queue: 0, now: at()).map(\.id) == [.item(section: 0, url: "a")], "no closing row")
    #expect(emptyText(some, queue: 0) == nil)

    let none = loaded([back([], waiting: 2, total: 2)])
    #expect(queues(none)[0].count == 0)
    #expect(rows(none, queue: 0, now: at()).isEmpty)
    #expect(emptyText(none, queue: 0) == sections[0].empty)

    let long = loaded([back([pr("a", "h")], waiting: 24, total: 40, truncated: true)])
    guard case .cutOff(let cut) = rows(long, queue: 0, now: at()).last?.content else {
      Issue.record("no closing row")
      return
    }
    #expect(cut.note == "1 shown of the newest 25 of 40 matches; 24 not pushed since your review")
  }

  @Test func anEmptyQueueSaysSoAndALoadedEmptyOneIsZero() {
    let inbox = loaded([ok([]), ok([]), ok([]), ok([]), ok([]), ok([])])
    #expect(emptyText(inbox, queue: 1) == "No one has asked you by name.")
    #expect(queues(inbox)[0].count == 0)
  }

  @Test func anItemRowCarriesEverythingItShows() {
    var item = pr("a", "h")
    item.review = .approved
    item.reviewRoute = .team("platform")
    item.author = "ravi"
    item.updatedAt = "2026-11-08T09:00:00Z"
    let row = itemRow(
      item, check: .known(checks: .passing, stale: false), multiOwner: true, viewer: "me", now: at())
    #expect(row.owner == "o")
    #expect(row.repo == "r")
    #expect(row.kind == .approved)
    #expect(row.route == "via platform")
    #expect(row.author == "ravi")
    #expect(row.age == "3h")
    // The date reads in the reader's own format, which varies by platform.
    let updated = "updated " + localTime(date("2026-11-08T09:00:00Z")!, now: at())
    #expect(row.toolTip == "t\no/r #1 · \(updated)\nReview request: via platform")
    #expect(
      row.accessibilityLabel
        == "Pull request, t, o/r #1, Approved, checks passing, via platform, by ravi, \(updated)"
    )
    #expect(itemRow(item, check: nil, multiOwner: false, viewer: "ravi", now: at()).author == "")
  }

  @Test func aTickRewordsOnlyTheRowsWhoseTextMoved() {
    var failing = loaded([ok([pr("a", "h")]), ok([]), ok([]), ok([]), ok([])])
    let then = ContinuousClock.now
    failing.sections[0].error = .server("502")
    failing.sections[0].fetchedAt = then
    let before = rows(failing, now: at(then, noon))
    let after = rows(failing, now: at(then + .seconds(180), noon))
    let error = GhError.server("502").described
    #expect(notices(before).first?.text == "\(error) Showing results from just now.")
    #expect(notices(after).first?.text.hasSuffix("from 3m ago.") == true)
    #expect(changes(from: before, to: after) == RowChanges(removed: [], inserted: [], updated: [1]))
    #expect(changes(from: after, to: after).isEmpty)
  }

  @Test func rowChangesKeepRowsWhoseIdentityStays() {
    let first = loaded([ok([pr("a", "h"), pr("b", "h")]), ok([]), ok([]), ok([]), ok([])])
    let second = loaded([ok([pr("b", "h"), pr("c", "h")]), ok([]), ok([]), ok([]), ok([])])
    let old = rows(first, now: at())
    let new = rows(second, now: at())
    let diff = changes(from: old, to: new)
    // "a" left and "c" arrived; "b" moved up but is the same row.
    #expect(diff.removed.map { old[$0].id } == [.item(section: 0, url: "a")])
    #expect(diff.inserted.map { new[$0].id } == [.item(section: 0, url: "c")])
    #expect(diff.updated.isEmpty)
  }

  @Test func arrowKeysSkipRowsThatDoNothing() {
    let inbox = loaded([truncated([pr("a", "h")], 60), ok([]), ok([issue("b")]), ok([]), ok([])])
    let shown = rows(inbox, now: at())
    let items = shown.indices.filter { shown[$0].action != nil }
    #expect(items.count == 2)
    #expect(nextSelectable(shown, from: nil, step: 1) == items[0])
    #expect(nextSelectable(shown, from: nil, step: -1) == items[1])
    // Past the cut-off row and the empty section's heading.
    #expect(nextSelectable(shown, from: items[0], step: 1) == items[1])
    #expect(nextSelectable(shown, from: items[1], step: -1) == items[0])
    #expect(nextSelectable(shown, from: items[1], step: 1) == nil)
    #expect(nextSelectable(shown, from: items[0], step: -1) == nil)
  }

  @Test func copyTakesAnItemsLinkAndNothingFromRowsThatDoNothing() {
    let inbox = loaded([truncated([pr("a", "h")], 60), ok([]), ok([]), ok([]), ok([])])
    let copied = rows(inbox, now: at()).map(\.copyText)
    #expect(copied.compactMap { $0 } == ["a"])
  }

  @Test func rightClickOffersAnItemsLinkAndReferenceAndNothingOnRowsThatDoNothing() {
    let inbox = loaded([truncated([pr("https://x/1", "h")], 60), ok([]), ok([]), ok([]), ok([])])
    let menus = rows(inbox, now: at()).map(\.menu).filter { !$0.isEmpty }
    #expect(
      menus == [
        [
          MenuEntry(title: "Open in Browser", action: .open("https://x/1")),
          MenuEntry(title: "Copy Link", action: .copy("https://x/1")),
          MenuEntry(title: "Copy o/r#1", action: .copy("o/r#1")),
        ]
      ])
  }

  @Test func aCutOffNoteNamesTheShownCountOnlyWhenItDiffers() {
    var inbox = loaded([truncated([pr("a", "h")], 60), ok([]), ok([]), ok([]), ok([])])
    // The fixture's repository has no owner type, so the Personal tab drops it.
    inbox.ownerFilter = .personal
    let notes = rows(inbox, now: at()).compactMap { row -> String? in
      if case .cutOff(let cut) = row.content { cut.note } else { nil }
    }
    #expect(notes == ["0 shown of the newest 1 of 60 matches; 1 hidden by the Personal/Org filter"])
  }

  @Test func nothingOpenNeedsEverySectionEmptyAndWhole() {
    #expect(nothingOpen(loaded([ok([]), ok([]), ok([]), ok([]), ok([])])))
    var withheld = ok([])
    withheld.warnings = [.withheld(3)]
    #expect(!nothingOpen(loaded([ok([]), ok([]), withheld, ok([])])))
    #expect(!nothingOpen(loaded([ok([]), ok([]), ok([]), truncated([], 300)])))
    // Items count before the owner tabs filter them out.
    var inbox = loaded([ok([pr("a", "h")]), ok([]), ok([]), ok([]), ok([])])
    inbox.ownerFilter = .personal
    #expect(!nothingOpen(inbox))
  }

  @Test func aHeadingShowsARetryAsLoadingNotFailed() {
    var section = SectionView(name: "s")
    #expect(headingMark(section, shown: 0) == .unknown)
    section.busy = true
    #expect(headingMark(section, shown: 0) == .loading)
    section.busy = false
    section.error = .server("502")
    #expect(headingMark(section, shown: 0) == .failed)
    section.busy = true
    #expect(headingMark(section, shown: 0) == .loading)
    section.loaded = true
    #expect(headingMark(section, shown: 0) == .count(0, dim: true))
    #expect(headingMark(section, shown: 3) == .count(3, dim: false))
  }

  @Test func thePinnedHeadingIsTheNearestAboveTheFirstVisibleRow() {
    let inbox = loaded([ok([pr("a", "h"), pr("b", "h")]), ok([pr("c", "h")]), ok([]), ok([]), ok([])])
    let shown = rows(inbox, now: at())
    #expect(pinnedHeading(shown, firstVisible: 0) == 0)
    #expect(pinnedHeading(shown, firstVisible: 2) == 0)
    #expect(pinnedHeading(shown, firstVisible: 3) == 3)
    #expect(pinnedHeading(shown, firstVisible: 4) == 3)
    #expect(pinnedHeading(shown, firstVisible: shown.count) == nil)
  }

  @Test func onlySectionFetchesCountAsRetrying() {
    var inbox = Inbox()
    #expect(!retrying(inbox))
    inbox.refresh()
    #expect(retrying(inbox))
    var answered = loaded([ok([pr("a", "h")]), ok([]), ok([]), ok([]), ok([])])
    #expect(!retrying(answered))
    answered.sections[1].busy = true
    #expect(retrying(answered))
  }

  @Test func headerCountsWhatIsDisplayed() {
    var draft = pr("d", "h")
    draft.isDraft = true
    let inbox = loaded([ok([pr("a", "h"), draft]), ok([]), ok([issue("b")]), ok([]), ok([])])
    let head = header(inbox, now: at())
    #expect(head.title == "Open for me")
    #expect(head.summary == "2 PRs (1 draft) · 1 issue · updated just now")
    #expect(!head.busy)
  }

  @Test func bannersNameTheSharedFailureAndFailedChecks() {
    let inbox = loaded([ok([pr("a", "h")]), ok([]), ok([]), ok([]), ok([])])
    let shown = banners(inbox, now: at())
    #expect(shown.count == 1)
    #expect(
      shown.first?.text.hasPrefix("Couldn't load checks for 1 PR: GitHub had a server error: 502.") == true
    )
  }

  @Test func kindsDotsAndRoutesReadAsBefore() {
    var approved = pr("a", "h")
    approved.review = .approved
    #expect(Kind(approved).badge == "Approved")
    #expect(Kind(issue("i")).badge == nil)
    #expect(Dot(.known(checks: .failing, stale: true)) == .filled(.failing, dim: true))
    #expect(Dot(.known(checks: nil, stale: false)) == Dot.none)
    #expect(Dot(.failed(.otherCommit)) == .failed)
    #expect(routeLabel(.team("platform")) == "via platform")
    #expect(routeLabel(.direct) == nil)
    #expect(routeLabel(.unknown) == "request source unknown")
  }

  @Test func agesAreCompactAndTurnIntoDates() {
    #expect(age("2026-11-08T11:59:30Z", now: at()) == "now")
    #expect(age("2026-11-08T11:15:00Z", now: at()) == "45m")
    #expect(age("2026-11-07T13:00:00Z", now: at()) == "23h")
    #expect(age("2026-11-02T12:00:00Z", now: at()) == "6d")
    #expect(age("2026-10-12T12:00:00Z", now: at()) == "3w")
    #expect(age("2026-09-30T12:00:00Z", now: at()) == "Sep 30")
    #expect(age("2025-12-01T00:00:00Z", now: at()) == "Dec 1, 2025")
    #expect(age("not a date", now: at()) == nil)
    #expect(age("2026-11-08T11:14:59.500Z", now: at()) == "45m")
    #expect(age("2026-11-08T12:05:00Z", now: at()) == "now")
    // Old enough to show a date: the reader's zone decides which day it was,
    // and their locale how it reads.
    var west = at()
    west.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    #expect(age("2026-10-01T03:00:00Z", now: west) == "Sep 30")
    var german = at()
    german.locale = Locale(identifier: "de_DE")
    #expect(age("2026-09-30T12:00:00Z", now: german) == "30. Sept.")
  }

}
