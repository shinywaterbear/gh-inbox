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
  @Test func rowsListHeadingsItemsAndTheFullSearchForACutOffSection() {
    let inbox = loaded([truncated([pr("a", "h")], 60), ok([]), ok([issue("b")]), ok([])])
    let shown = rows(inbox, now: .now)
    #expect(shown.rows.first == .heading(section: 0, first: true, shown: 1))
    #expect(shown.rows.contains(.item(section: 0, index: 0)))
    #expect(shown.rows.contains(.loadMore(section: 0)))
    let notice = shown.rows.first { if case .notice(_, _, .some) = $0 { true } else { false } }
    guard case .notice(let text, .warning, let url?) = notice else {
      Issue.record("no search link")
      return
    }
    #expect(text == "Fetched the newest 1 of 60 matches; 1 shown here. Open the full search on GitHub.")
    #expect(url == searchURL(0, host: "github.com", directOnly: false))
    #expect(shown.rows.contains(.heading(section: 1, first: false, shown: 0)))
    #expect(!shown.multiOwner)
  }

  @Test func headerCountsWhatIsDisplayed() {
    var draft = pr("d", "h")
    draft.isDraft = true
    let inbox = loaded([ok([pr("a", "h"), draft]), ok([]), ok([issue("b")]), ok([])])
    let head = header(inbox, rows: rows(inbox, now: .now).rows, now: .now)
    #expect(head.title == "Open for me")
    #expect(head.summary == "1 PRs · 1 drafts · 1 issues · updated just now")
    #expect(!head.busy)
  }

  @Test func bannersNameTheSharedFailureAndFailedChecks() {
    let inbox = loaded([ok([pr("a", "h")]), ok([]), ok([]), ok([])])
    let shown = banners(inbox, now: .now)
    #expect(shown.count == 1)
    #expect(
      shown.first?.text.hasPrefix("Couldn't load checks for 1 PR(s): GitHub had a server error: 502.") == true
    )
  }

  @Test func kindsDotsAndRoutesReadAsBefore() {
    var approved = pr("a", "h")
    approved.review = .approved
    #expect(Kind(approved).label == "Approved")
    #expect(Kind(issue("i")).label == "Issue")
    #expect(Dot(.known(checks: .failing, stale: true)) == .filled(.failing, dim: true))
    #expect(Dot(.known(checks: nil, stale: false)) == Dot.none)
    #expect(Dot(.failed(.otherCommit)) == .failed)
    #expect(routeLabel(.team("platform")) == "via platform")
    #expect(routeLabel(.direct) == nil)
    #expect(routeLabel(.unknown) == "request source unknown")
  }
}
