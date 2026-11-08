import Foundation
import Testing

@testable import GhInboxCore

private let identity = Identity(login: "me", host: "github.com")

private func loaded(_ answers: [SectionFetch]) -> Inbox {
  var inbox = Inbox()
  inbox.refresh()
  while let ticket = inbox.nextJob() {
    switch ticket.job {
    case .section(let index, _, _): inbox.finish(ticket, .section(answers[index]), now: .now)
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

struct DisplayTests {
  @Test func rowsListHeadingsItemsAndOneRowForACutOffSection() {
    let inbox = loaded([truncated([pr("a", "h")], 60), ok([]), ok([issue("b")]), ok([])])
    let shown = rows(inbox, now: .now)
    #expect(shown.rows.first == .heading(section: 0, first: true, shown: 1))
    #expect(shown.rows.contains(.item(section: 0, index: 0)))
    #expect(inbox.sections[0].canLoadMore)
    #expect(
      shown.rows.contains(
        .cutOff(
          section: 0, note: "Showing the newest 1 of 60 matches",
          url: searchURL(0, host: "github.com", directOnly: false))))
    #expect(shown.rows.contains(.heading(section: 1, first: false, shown: 0)))
    #expect(!shown.multiOwner)
  }

  @Test func aCutOffNoteNamesTheShownCountOnlyWhenItDiffers() {
    var inbox = loaded([truncated([pr("a", "h")], 60), ok([]), ok([]), ok([])])
    // The fixture's repository has no owner type, so the Personal tab drops it.
    inbox.ownerFilter = .personal
    let notes = rows(inbox, now: .now).rows.compactMap { row -> String? in
      if case .cutOff(_, let note, _) = row { note } else { nil }
    }
    #expect(notes == ["0 shown of the newest 1 of 60 matches, before the Personal/Org filter"])
  }

  @Test func nothingOpenNeedsEverySectionEmptyAndWhole() {
    #expect(nothingOpen(loaded([ok([]), ok([]), ok([]), ok([])])))
    var withheld = ok([])
    withheld.warnings = [.withheld(3)]
    #expect(!nothingOpen(loaded([ok([]), ok([]), withheld, ok([])])))
    #expect(!nothingOpen(loaded([ok([]), ok([]), ok([]), truncated([], 300)])))
    // Items count before the owner tabs filter them out.
    var inbox = loaded([ok([pr("a", "h")]), ok([]), ok([]), ok([])])
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

  @Test func aNoticeKeepsItsAgeOutOfItsIdentity() {
    let then = ContinuousClock.now
    let notice = Notice(text: "GitHub had a server error: 502.", tone: .error, since: then)
    #expect(notice.text(now: then) == "GitHub had a server error: 502. Showing results from just now.")
    #expect(notice.text(now: then + .seconds(180)).hasSuffix("from 3m ago."))
    #expect(Notice(text: "x", tone: .warning).text(now: then) == "x")
  }

  @Test func thePinnedHeadingIsTheNearestAboveTheFirstVisibleRow() {
    let shown: [Row] = [
      .heading(section: 0, first: true, shown: 2), .item(section: 0, index: 0), .item(section: 0, index: 1),
      .heading(section: 1, first: false, shown: 1), .item(section: 1, index: 0),
    ]
    #expect(pinnedHeading(shown, firstVisible: 0) == 0)
    #expect(pinnedHeading(shown, firstVisible: 2) == 0)
    #expect(pinnedHeading(shown, firstVisible: 3) == 3)
    #expect(pinnedHeading(shown, firstVisible: 4) == 3)
    #expect(pinnedHeading(shown, firstVisible: 5) == nil)
  }

  @Test func onlySectionFetchesCountAsRetrying() {
    var inbox = Inbox()
    #expect(!retrying(inbox))
    inbox.refresh()
    #expect(retrying(inbox))
    var answered = loaded([ok([pr("a", "h")]), ok([]), ok([]), ok([])])
    #expect(!retrying(answered))
    answered.sections[1].busy = true
    #expect(retrying(answered))
  }

  @Test func headerCountsWhatIsDisplayed() {
    var draft = pr("d", "h")
    draft.isDraft = true
    let inbox = loaded([ok([pr("a", "h"), draft]), ok([]), ok([issue("b")]), ok([])])
    let head = header(inbox, rows: rows(inbox, now: .now).rows, now: .now)
    #expect(head.title == "Open for me")
    #expect(head.summary == "2 PRs (1 draft) · 1 issue · updated just now")
    #expect(!head.busy)
  }

  @Test func bannersNameTheSharedFailureAndFailedChecks() {
    let inbox = loaded([ok([pr("a", "h")]), ok([]), ok([]), ok([])])
    let shown = banners(inbox)
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
    let now = ISO8601DateFormatter().date(from: "2026-11-08T12:00:00Z")!
    let utc = TimeZone(identifier: "UTC")!
    #expect(age("2026-11-08T11:59:30Z", now: now, timeZone: utc) == "now")
    #expect(age("2026-11-08T11:15:00Z", now: now, timeZone: utc) == "45m")
    #expect(age("2026-11-07T13:00:00Z", now: now, timeZone: utc) == "23h")
    #expect(age("2026-11-02T12:00:00Z", now: now, timeZone: utc) == "6d")
    #expect(age("2026-10-12T12:00:00Z", now: now, timeZone: utc) == "3w")
    #expect(age("2026-09-30T12:00:00Z", now: now, timeZone: utc) == "Sep 30")
    #expect(age("2025-12-01T00:00:00Z", now: now, timeZone: utc) == "Dec 1, 2025")
    #expect(age("not a date", now: now, timeZone: utc) == nil)
    #expect(age("2026-11-08T11:14:59.500Z", now: now, timeZone: utc) == "45m")
    #expect(age("2026-11-08T12:05:00Z", now: now, timeZone: utc) == "now")
    // Old enough to show a date: the reader's zone decides which day it was.
    #expect(
      age("2026-10-01T03:00:00Z", now: now, timeZone: TimeZone(identifier: "America/Los_Angeles")!)
        == "Sep 30")
  }
}
