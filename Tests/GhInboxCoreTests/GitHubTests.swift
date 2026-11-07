import Foundation
import Testing

@testable import GhInboxCore

private let review = 0
private let authored = 1

/// A section that loaded, and its warnings.
private func page(_ fetch: SectionFetch) throws -> (Page, [GhError]) {
  #expect(fetch.identity != nil, "no identity")
  switch fetch.page {
  case .success(let page): return (page, fetch.warnings)
  case .failure(let error):
    Issue.record("section failed: \(error)")
    throw error
  }
}

private func items(_ fetch: SectionFetch) throws -> [Item] {
  try page(fetch).0.items
}

/// No usable response at all.
private func unavailable(_ fetch: SectionFetch) -> GhError? {
  #expect(fetch.identity == nil, "expected no identity")
  return fetch.page.failure
}

private func pr(_ number: Int, _ updatedAt: String, draft: Bool = false, decision: String? = nil) -> JSON {
  [
    "__typename": "PullRequest", "number": .int(number), "title": "t",
    "url": .string("https://github.com/o/r/pull/\(number)"), "updatedAt": .string(updatedAt),
    "id": .string("PR_\(number)"), "headRefOid": .string("sha\(number)"),
    "isDraft": .bool(draft), "reviewDecision": decision.map { .string($0) } ?? .null,
    "author": ["login": "a"],
    "repository": ["name": "r", "nameWithOwner": "o/r"],
    "latestOpinionatedReviews": ["pageInfo": ["hasNextPage": false], "nodes": []],
  ]
}

private func conn(_ nodes: JSON) -> JSON {
  var count = 0
  if case .array(let a) = nodes { count = a.count }
  return ["issueCount": .int(count), "pageInfo": ["hasNextPage": false], "nodes": nodes]
}

/// `review` and `authored` as given; the other two sections empty. Each
/// section's request reads only its own alias.
private func response(_ review: JSON, _ authored: JSON) -> JSON {
  [
    "data": [
      "viewer": ["login": "me", "url": "https://github.com/me"],
      "review": review, "authored": authored,
      "assigned": conn([]), "personal": conn([]),
    ]
  ]
}

/// Runs a fake gh that records its arguments, returning the query sent.
private func sentQuery(_ name: String, _ call: (Gh) -> Void) throws -> String {
  let dir = scratch(name)
  let args = dir.appendingPathComponent("args").path
  call(fakeGh(name, "printf '%s\\n' \"$@\" > '\(args)'\ncat '\(recorded)'", in: dir))
  let text = try String(contentsOfFile: args, encoding: .utf8)
  let parts = text.split(separator: "\n", maxSplits: 3, omittingEmptySubsequences: false)
  #expect(parts.prefix(3) == ["api", "graphql", "-f"])
  let sent = String(try #require(parts.dropFirst(3).first))
  #expect(sent.hasPrefix("query=query {"))
  #expect(sent.contains("viewer { login url }"), "every request names its account")
  return sent
}

struct SectionRequestTests {
  @Test func eachSectionSendsOneSearchOfTheSizeAsked() throws {
    for (index, spec) in sections.enumerated() {
      let sent = try sentQuery(spec.alias) { _ = $0.section(index, size: 50, directOnly: false) }
      let query = search(index, directOnly: false)
      #expect(sent.contains("\(spec.alias): search(query: \"\(query)\", type: ISSUE, first: 50)"))
      #expect(sent.components(separatedBy: "search(").count == 2)
      #expect(query.hasSuffix(" sort:updated-desc"), "\(spec.alias)")
      #expect(sent.contains("fragment items on SearchResultItemConnection"))
      #expect(sent.contains("reviewRequests") == (index == review), "only the review section reads requests")
      #expect(!sent.contains("statusCheckRollup"), "checks load separately")
    }
  }

  @Test func checkLookupsSendTheIds() throws {
    let sent = try sentQuery("check-args") { _ = $0.checks(["PR_a", "PR_b"]) }
    #expect(sent.contains(#"nodes(ids: ["PR_a","PR_b"])"#))
    #expect(sent.contains("fragment checks on PullRequest"))
  }

  @Test func parsesRecordedResponsePerSection() throws {
    let gh = fakeGh("recorded", "cat '\(recorded)'")
    let fetch = gh.section(authored, size: 25, directOnly: false)
    #expect(fetch.identity == Identity(login: "example-user", host: "github.com"))
    let (mine, warnings) = try page(fetch)
    #expect(warnings.isEmpty && !mine.truncated)
    #expect(mine.items.count == 3)
    #expect(mine.items.dropFirst().allSatisfy { $0.isDraft }, "drafts last")
    #expect(mine.items.allSatisfy { $0.head != nil })
    for index in sections.indices {
      let (section, warnings) = try page(gh.section(index, size: 25, directOnly: false))
      #expect(!section.truncated && warnings.isEmpty, "\(index)")
    }
  }

  @Test func directOnlySwapsOneQualifierAndTheLinkFollows() throws {
    let any = search(review, directOnly: false)
    let direct = search(review, directOnly: true)
    #expect(any.replacingOccurrences(of: "review-requested", with: "user-review-requested") == direct)
    for (directOnly, expected) in [(false, any), (true, direct)] {
      let sent = try sentQuery("review-search-\(directOnly)") {
        _ = $0.section(review, size: 25, directOnly: directOnly)
      }
      #expect(sent.contains("query: \"\(expected)\""))
      #expect(sent.contains("reviewRequests") == !directOnly)
      #expect(
        searchURL(review, host: "github.com", directOnly: directOnly)
          == "https://github.com/search?type=issues&q=\(encode(expected))")
    }
    for index in 1..<sections.count {
      #expect(search(index, directOnly: true) == search(index, directOnly: false))
    }
  }
}

struct FailureTests {
  @Test func missingBinaryIsNotInstalled() {
    let gh = Gh(program: "/nonexistent/gh")
    #expect(unavailable(gh.section(review, size: 25, directOnly: false)) == .notInstalled)
  }

  @Test func loggedOutIsOneErrorNotOnePerSection() {
    let gh = fakeGh(
      "logged-out", "echo 'To get started with GitHub CLI, please run:  gh auth login' >&2; exit 4")
    #expect(unavailable(gh.section(review, size: 25, directOnly: false)) == .notLoggedIn)
  }

  @Test func rejectedTokenIsBadCredentials() {
    // gh prints the 401 body on stdout and its summary on stderr.
    let gh = fakeGh(
      "bad-token",
      "echo '{\"message\":\"Bad credentials\",\"status\":\"401\"}'\necho 'gh: Bad credentials (HTTP 401)' >&2; exit 1"
    )
    #expect(kind(unavailable(gh.section(review, size: 25, directOnly: false))) == "badCredentials")
  }

  @Test func networkFailureIsNetwork() {
    let gh = fakeGh("network", "echo 'dial tcp: lookup api.github.com: no such host' >&2; exit 1")
    #expect(kind(unavailable(gh.section(review, size: 25, directOnly: false))) == "network")
  }

  @Test func hungGhTimesOut() {
    var gh = fakeGh("hung", "sleep 5")
    gh.timeout = .milliseconds(200)
    let started = ContinuousClock.now
    #expect(kind(unavailable(gh.section(review, size: 25, directOnly: false))) == "timeout")
    #expect(ContinuousClock.now - started < .seconds(3))
  }

  @Test func aDescendantHoldingThePipeCannotOutliveTheTimeout() {
    // gh exits at once, but a background child keeps stdout open.
    var gh = fakeGh("held-pipe", "sleep 5 &\nexit 0")
    gh.timeout = .milliseconds(300)
    let started = ContinuousClock.now
    #expect(kind(unavailable(gh.section(review, size: 25, directOnly: false))) == "timeout")
    #expect(ContinuousClock.now - started < .seconds(3))
  }

  @Test func garbageOutputIsAParseError() {
    let gh = fakeGh("garbage", "echo 'not json'")
    #expect(kind(unavailable(gh.section(review, size: 25, directOnly: false))) == "parse")
  }

  @Test func wholeQueryRateLimitIsUnavailable() {
    let json: JSON = ["errors": [["type": "RATE_LIMITED", "message": "API rate limit exceeded"]]]
    let fetch = responding("rate-limited", json, 1).section(review, size: 25, directOnly: false)
    #expect(kind(unavailable(fetch)) == "rateLimited")
  }

  @Test func aFailedSearchStillNamesTheAccount() {
    var json = response(nil, conn([]))
    json["errors"] = [["type": "FORBIDDEN", "path": ["review"], "message": "Resource not accessible"]]
    let fetch = responding("one-section", json, 1).section(review, size: 25, directOnly: false)
    #expect(fetch.identity != nil)
    #expect(kind(fetch.page.failure) == "forbidden")
  }

  @Test func aMalformedSectionIsAParseError() {
    let json = response(["nodes": "not a list"], conn([]))
    let fetch = responding("malformed-section", json, 0).section(review, size: 25, directOnly: false)
    #expect(kind(fetch.page.failure) == "parse")
  }

  @Test func aBare502IsAServerError() {
    let gh = fakeGh(
      "bare-502",
      "echo '<html>Bad Gateway</html>'\necho 'gh: HTTP 502: 502 Bad Gateway (https://api.github.com/graphql)' >&2; exit 1"
    )
    #expect(kind(unavailable(gh.section(review, size: 25, directOnly: false))) == "server")
  }

  @Test func aQueryTimeoutBodyIsAServerError() {
    let json: JSON = [
      "data": nil,
      "errors": [
        [
          "message":
            "Something went wrong while executing your query. This may be the result of a timeout, or it could be a GitHub bug."
        ]
      ],
    ]
    let error = unavailable(responding("timeout-body", json, 1).section(review, size: 25, directOnly: false))
    #expect(kind(error) == "server")
    #expect(error?.hint != nil)
  }

  @Test func descriptionsEndEachSentenceOnce() {
    let error = GhError.forbidden("Resource protected by organization SAML enforcement.")
    #expect(
      error.described
        == "GitHub denied access: Resource protected by organization SAML enforcement. "
        + "Check `gh auth status`: classic/OAuth tokens need `repo` for private repositories "
        + "and `read:org` for organization/team access. SSO organizations may require token "
        + "authorization. If using `GH_TOKEN` or `GITHUB_TOKEN`, check that token instead.")
    #expect(GhError.gh("boom").described == "gh failed: boom.")
  }

  @Test func anIpAllowListPointsAtTheNetwork() throws {
    var json = response(conn([nil, pr(2, "2026-11-01T00:00:00Z")]), conn([]))
    json["errors"] = [
      [
        "type": "FORBIDDEN", "path": ["review", "nodes", 0],
        "message":
          "Although you appear to have the correct authorization credentials, the `o` organization has an IP allow list enabled, and your IP address is not permitted to access this resource.",
      ]
    ]
    let (_, warnings) = try page(
      responding("ip-allow-list", json, 1).section(review, size: 25, directOnly: false))
    #expect(warnings.count == 1 && kind(warnings.first) == "ipRestricted")
    #expect(warnings.first?.hint?.contains("VPN") == true)
  }
}

struct PartialResultTests {
  @Test func aMalformedItemCostsOnlyItselfAndIsReported() throws {
    var broken = pr(2, "2026-11-01T00:00:00Z")
    broken["title"] = nil
    let json = response(conn([broken, pr(3, "2026-11-01T00:00:00Z")]), conn([]))
    let (found, warnings) = try page(
      responding("malformed-item", json, 0).section(review, size: 25, directOnly: false))
    #expect(found.items.count == 1)
    #expect(warnings == [.unreadable(1)])
  }

  @Test func ssoWithheldItemsKeepTheRestAndSaySo() throws {
    var json = response(conn([nil, pr(2, "2026-11-01T00:00:00Z")]), conn([]))
    json["errors"] = [
      [
        "type": "FORBIDDEN", "path": ["review", "nodes", 0],
        "message": "Resource protected by organization SAML enforcement.",
      ]
    ]
    let (found, warnings) = try page(responding("sso", json, 1).section(review, size: 25, directOnly: false))
    #expect(found.items.count == 1)
    #expect(warnings.count == 1 && kind(warnings.first) == "forbidden")
  }

  @Test func unexplainedMissingItemsStillWarn() throws {
    let json = response(conn([nil]), conn([]))
    let (_, warnings) = try page(
      responding("silent-null", json, 0).section(review, size: 25, directOnly: false))
    #expect(warnings == [.withheld(1)])
  }

  @Test func anErrorInsideAPresentItemIsNotLost() throws {
    var json = response(conn([pr(4, "2026-11-01T00:00:00Z")]), conn([]))
    json["errors"] = [
      [
        "type": "FORBIDDEN", "path": ["review", "nodes", 0, "commits"],
        "message": "Resource not accessible by integration",
      ]
    ]
    let (found, warnings) = try page(
      responding("nested", json, 1).section(review, size: 25, directOnly: false))
    #expect(found.items.count == 1)
    #expect(warnings.count == 1 && kind(warnings.first) == "forbidden")
  }

  @Test func errorsWithoutAPathWarnTheSectionThatAsked() throws {
    var json = response(conn([]), conn([]))
    json["errors"] = [["type": "INTERNAL", "message": "Something went wrong"]]
    let (_, warnings) = try page(responding("unscoped", json, 1).section(review, size: 25, directOnly: false))
    #expect(warnings == [.gh("Something went wrong")])
  }

  @Test func truncatedSectionsSaySoAndLinkTheFullSearch() throws {
    var json = response(conn([pr(1, "2026-11-01T00:00:00Z")]), conn([]))
    json["data"]["review"]["issueCount"] = 342
    json["data"]["review"]["pageInfo"]["hasNextPage"] = true
    let (found, _) = try page(responding("truncated", json, 0).section(review, size: 25, directOnly: false))
    #expect(found.truncated)
    #expect(found.total == 342)
    #expect(
      searchURL(review, host: "github.com", directOnly: false)
        == "https://github.com/search?type=issues&q=is%3Aopen%20is%3Apr%20archived%3Afalse%20review-requested%3A%40me%20sort%3Aupdated-desc"
    )
    #expect(
      searchURL(review, host: "github.com", directOnly: true)
        == "https://github.com/search?type=issues&q=is%3Aopen%20is%3Apr%20archived%3Afalse%20user-review-requested%3A%40me%20sort%3Aupdated-desc"
    )
  }

  @Test func searchLinksFollowTheViewersHost() throws {
    var json = response(conn([]), conn([]))
    json["data"]["viewer"]["url"] = "https://ghe.example.com/me"
    let host = try #require(responding("ghe", json, 0).section(review, size: 25, directOnly: false).identity)
      .host
    #expect(host == "ghe.example.com")
    #expect(searchURL(review, host: host, directOnly: false).hasPrefix("https://ghe.example.com/search?"))
  }

  @Test func pageCountsWhatGitHubReturnedNotWhatSurvived() throws {
    var broken = pr(8, "2026-11-01T00:00:00Z")
    broken["title"] = nil
    let json = response(conn([broken, nil, pr(9, "2026-11-01T00:00:00Z")]), conn([]))
    let (found, _) = try page(responding("page", json, 0).section(review, size: 25, directOnly: false))
    #expect(found.returned == 3 && found.items.count == 1)
  }
}

struct ItemTests {
  @Test func approvedAndDraftPrsSinkInThatOrder() throws {
    let json = response(
      conn([
        pr(1, "2026-11-04T00:00:00Z", draft: true),
        pr(2, "2026-11-03T00:00:00Z", decision: "APPROVED"),
        pr(3, "2026-10-01T00:00:00Z", decision: "REVIEW_REQUIRED"),
        pr(4, "2026-11-02T00:00:00Z"),
      ]), conn([]))
    let numbers = try items(responding("rank", json, 0).section(review, size: 25, directOnly: false)).map(
      \.number)
    #expect(numbers == [4, 3, 2, 1])
  }

  @Test func reviewsDecideOnlyFromCompleteOpinions() {
    let approved = ["APPROVED"]
    #expect(GhInboxCore.review(decision: nil, latest: approved, complete: true) == .approved)
    #expect(
      GhInboxCore.review(decision: nil, latest: approved, complete: false) == nil,
      "an unseen reviewer may object")
    let mixed = ["APPROVED", "CHANGES_REQUESTED"]
    #expect(GhInboxCore.review(decision: nil, latest: mixed, complete: false) == .changesRequested)
    #expect(GhInboxCore.review(decision: "REVIEW_REQUIRED", latest: approved, complete: true) == .required)
    #expect(GhInboxCore.review(decision: nil, latest: [], complete: true) == nil)
  }

  @Test func checkStatesMapToThreeColors() {
    #expect(checks("SUCCESS") == .passing)
    #expect(checks("ERROR") == .failing)
    #expect(checks("EXPECTED") == .pending)
  }

  @Test func deletedAuthorsShowAsGhost() throws {
    var item = pr(6, "2026-11-01T00:00:00Z")
    item["author"] = nil
    let found = try items(
      responding("ghost", response(conn([item]), conn([])), 0).section(review, size: 25, directOnly: false))
    #expect(found[0].author == ghost)
  }

  @Test func aWithheldReviewerOpinionBlocksInferredApproval() throws {
    var item = pr(7, "2026-11-01T00:00:00Z")
    item["latestOpinionatedReviews"]["nodes"] = [["state": "APPROVED"], nil]
    let found = try items(
      responding("null-review", response(conn([item]), conn([])), 0).section(
        review, size: 25, directOnly: false))
    #expect(found[0].review == nil)
  }

  @Test func repositoryOwnerTypenameTellsPersonalFromOrganization() throws {
    var org = pr(11, "2026-11-01T00:00:00Z")
    org["repository"]["owner"] = ["__typename": "Organization"]
    var personal = pr(12, "2026-10-31T00:00:00Z")
    personal["repository"]["owner"] = ["__typename": "User"]
    let found = try items(
      responding("owner-typename", response(conn([org, personal]), conn([])), 0)
        .section(review, size: 25, directOnly: false))
    #expect(found.first { $0.number == 11 }?.repository.ownerKind == .organization)
    #expect(found.first { $0.number == 12 }?.repository.ownerKind == .personal)
  }

  @Test func aRepositoryWithNoOwnerTypeIsUnknownNotPersonal() throws {
    let found = try items(
      responding("owner-missing", response(conn([pr(13, "2026-11-01T00:00:00Z")]), conn([])), 0)
        .section(review, size: 25, directOnly: false))
    #expect(found[0].repository.ownerKind == .unknown)
  }
}

/// The review section's route for a PR whose request list is `nodes`.
private func route(_ name: String, _ nodes: JSON, hasNextPage: Bool) throws -> ReviewRoute? {
  var item = pr(8, "2026-11-01T00:00:00Z")
  item["reviewRequests"] = ["pageInfo": ["hasNextPage": .bool(hasNextPage)], "nodes": nodes]
  return try items(
    responding(name, response(conn([item]), conn([])), 0).section(review, size: 25, directOnly: false))[
      0
    ].reviewRoute
}

private func user(_ login: String) -> JSON {
  ["requestedReviewer": ["__typename": "User", "login": .string(login)]]
}

private func team(_ name: String) -> JSON {
  ["requestedReviewer": ["__typename": "Team", "name": .string(name)]]
}

struct ReviewRouteTests {
  @Test func aDirectRequestWinsOverTeamsEvenOnAPartialList() throws {
    let nodes: JSON = [team("platform"), user("other"), user("me")]
    #expect(try route("mixed", nodes, hasNextPage: false) == .direct)
    #expect(try route("mixed-cut", nodes, hasNextPage: true) == .direct)
    let behindNull: JSON = [nil, ["requestedReviewer": nil], user("me")]
    #expect(try route("null-then-me", behindNull, hasNextPage: false) == .direct)
  }

  @Test func onlyACompleteListWithOneTeamNamesIt() throws {
    #expect(
      try route("one-team", [user("other"), team("platform")], hasNextPage: false) == .team("platform"))
    #expect(
      try route("two-teams", [team("platform"), team("security")], hasNextPage: false) == .someTeam,
      "not the first one listed")
  }

  @Test func aCutOffOrWithheldRequestListIsUnknown() throws {
    #expect(
      try route("cut-off", [team("platform")], hasNextPage: true) == .unknown,
      "the viewer may be past the page")
    #expect(try route("null-node", [team("platform"), nil], hasNextPage: false) == .unknown)
    #expect(
      try route("null-reviewer", [team("platform"), ["requestedReviewer": nil]], hasNextPage: false)
        == .unknown,
      "a hidden team may be the viewer's")
    #expect(
      try route("unsupported", [["requestedReviewer": ["__typename": "Robot"]]], hasNextPage: false)
        == .unknown)
    #expect(try route("empty", [], hasNextPage: false) == .unknown)
    let missing = try items(
      responding("no-requests", response(conn([pr(9, "2026-11-01T00:00:00Z")]), conn([])), 0)
        .section(review, size: 25, directOnly: false))
    #expect(missing[0].reviewRoute == .unknown)
  }

  @Test func theDirectOnlySearchNeedsNoRequestList() throws {
    let direct = try items(
      responding("direct-search-route", response(conn([pr(10, "2026-11-01T00:00:00Z")]), conn([])), 0)
        .section(review, size: 25, directOnly: true))
    #expect(direct[0].reviewRoute == .direct)
  }

  @Test func otherSectionsHaveNoReviewRoute() throws {
    var item = pr(11, "2026-11-01T00:00:00Z")
    item["reviewRequests"] = ["pageInfo": ["hasNextPage": false], "nodes": [team("platform")]]
    let mine = try items(
      responding("authored-review-field", response(conn([]), conn([item])), 0)
        .section(authored, size: 25, directOnly: false))
    #expect(mine[0].reviewRoute == nil)
  }
}

private func checkNode(_ id: String, _ head: String, _ state: String) -> JSON {
  [
    "__typename": "PullRequest", "id": .string(id), "headRefOid": .string(head),
    "commits": ["nodes": [["commit": ["statusCheckRollup": ["state": .string(state)]]]]],
  ]
}

/// A PR whose rollup is `state` over the check runs `ran`, against a base
/// branch whose ruleset requires `required`.
private func gatedNode(_ state: String, _ ran: [String], total: Int, required: [String]) -> JSON {
  var node = checkNode("PR_a", "a1", state)
  node["commits"]["nodes"][0]["commit"]["statusCheckRollup"]["contexts"] = [
    "totalCount": .int(total), "nodes": .array(ran.map { ["__typename": "CheckRun", "name": .string($0)] }),
  ]
  node["baseRef"] = [
    "branchProtectionRule": nil,
    "rules": [
      "nodes": [
        [
          "parameters": [
            "__typename": "RequiredStatusChecksParameters",
            "requiredStatusChecks": .array(required.map { ["context": .string($0)] }),
          ]
        ],
        ["parameters": nil],
      ]
    ],
  ]
  return node
}

private func gatedState(_ name: String, _ node: JSON) throws -> Checks? {
  let json: JSON = ["data": ["viewer": ["login": "me", "url": "https://github.com/me"], "nodes": [node]]]
  let fetch = responding(name, json, 0).checks(["PR_a"])
  return try #require(fetch.results[0].result.success, "check state").checks
}

private let ran = ["check", "Game build", "Game browser tests"]

private func withStatus(_ required: [String]) -> JSON {
  var node = gatedNode("SUCCESS", ran, total: ran.count + 1, required: required)
  var contexts = node["commits"]["nodes"][0]["commit"]["statusCheckRollup"]["contexts"]["nodes"]
  if case .array(var list) = contexts {
    list.append(["__typename": "StatusContext", "context": "ci/legacy"])
    contexts = .array(list)
  }
  node["commits"]["nodes"][0]["commit"]["statusCheckRollup"]["contexts"]["nodes"] = contexts
  return node
}

/// `node` with a test merge commit whose rollup is `state` over `ran`.
private func withMergeCommit(_ node: JSON, _ state: String, _ ran: [String]) -> JSON {
  var node = node
  node["potentialMergeCommit"] = [
    "statusCheckRollup": [
      "state": .string(state),
      "contexts": [
        "totalCount": .int(ran.count),
        "nodes": .array(ran.map { ["__typename": "CheckRun", "name": .string($0)] }),
      ],
    ]
  ]
  return node
}

struct CheckTests {
  @Test func everyRequestedCheckGetsAnAnswer() {
    var noChecks = checkNode("PR_c", "c1", "SUCCESS")
    noChecks["commits"]["nodes"][0]["commit"]["statusCheckRollup"] = nil
    let json: JSON = [
      "data": [
        "viewer": ["login": "me", "url": "https://github.com/me"],
        "nodes": [
          checkNode("PR_a", "a1", "FAILURE"), nil, noChecks, nil, checkNode("PR_other", "x", "SUCCESS"),
        ],
      ],
      "errors": [["type": "FORBIDDEN", "path": ["nodes", 3], "message": "SAML enforcement"]],
    ]
    let fetch = responding("checks", json, 1).checks(["PR_a", "PR_b", "PR_c", "PR_d", "PR_e"])
    #expect(fetch.identity != nil)
    let results = fetch.results.map(\.result)
    #expect(results[0] == .success(CheckState(head: "a1", checks: .failing)))
    #expect(results[1] == .failure(.withheld(1)))
    #expect(results[2] == .success(CheckState(head: "c1", checks: nil)))
    #expect(kind(results[3].failure) == "forbidden")
    #expect(results[4] == .failure(.unreadable(1)), "answer for another id")
  }

  @Test func aRequiredCheckThatNeverReportedIsPendingNotPassing() throws {
    // Seen for real: the ruleset gained a required check after the PR's
    // checks ran, so GitHub's rollup says SUCCESS without it.
    let node = gatedNode("SUCCESS", ran, total: ran.count, required: ["Gate / Validate"])
    #expect(try gatedState("gated-missing", node) == .pending)
  }

  @Test func aRequiredCheckThatReportedLeavesTheRollupAlone() throws {
    let all = ran + ["Gate / Validate"]
    let node = gatedNode("SUCCESS", all, total: all.count, required: ["Gate / Validate"])
    #expect(try gatedState("gated-reported", node) == .passing)
  }

  @Test func aMissingRequiredCheckDoesNotHideAFailure() throws {
    let node = gatedNode("FAILURE", ran, total: ran.count, required: ["Gate / Validate"])
    #expect(try gatedState("gated-failing", node) == .failing)
  }

  @Test func aRequiredCheckOnACommitWithNoChecksIsPending() throws {
    var node = gatedNode("SUCCESS", [], total: 0, required: ["Gate / Validate"])
    node["commits"]["nodes"][0]["commit"]["statusCheckRollup"] = nil
    #expect(try gatedState("gated-no-rollup", node) == .pending)
  }

  @Test func aRequiredCommitStatusCountsByItsContext() throws {
    #expect(try gatedState("gated-status", withStatus(["ci/legacy"])) == .passing)
  }

  @Test func commitStatusesCompleteTheListThatProvesACheckMissing() throws {
    #expect(try gatedState("gated-status-missing", withStatus(["ci/legacy", "Gate / Validate"])) == .pending)
  }

  @Test func branchProtectionRequirementsCountToo() throws {
    var node = gatedNode("SUCCESS", ran, total: ran.count, required: [])
    node["baseRef"]["branchProtectionRule"] = ["requiredStatusCheckContexts": ["Gate / Validate"]]
    #expect(try gatedState("gated-classic", node) == .pending)
  }

  @Test func aRequiredCheckPassingOnTheTestMergeCommitIsNotMissing() throws {
    let head = gatedNode("SUCCESS", ran, total: ran.count, required: ["Gate / Validate"])
    #expect(
      try gatedState("gated-merge-pass", withMergeCommit(head, "SUCCESS", ["Gate / Validate"])) == .passing)
  }

  @Test func theTestMergeCommitStatusWinsOverTheHead() throws {
    let head = gatedNode("SUCCESS", ran, total: ran.count, required: [])
    #expect(try gatedState("gated-merge-fail", withMergeCommit(head, "FAILURE", ["external"])) == .failing)
  }

  @Test func aTestMergeCommitWithoutAStatusLeavesTheHeadToDecide() throws {
    var node = gatedNode("SUCCESS", ran, total: ran.count, required: ["Gate / Validate"])
    node["potentialMergeCommit"] = ["statusCheckRollup": nil]
    #expect(try gatedState("gated-merge-none", node) == .pending)
  }

  @Test func aCutOffCheckListCannotProveACheckMissing() throws {
    let node = gatedNode("SUCCESS", ran, total: 150, required: ["Gate / Validate"])
    #expect(try gatedState("gated-cut-off", node) == .passing)
  }

  @Test func aFailedCheckLookupFailsEveryId() {
    let fetch = fakeGh("checks-down", "echo 'dial tcp: i/o timeout' >&2; exit 1").checks(["PR_a", "PR_b"])
    #expect(fetch.identity == nil)
    #expect(fetch.results.count == 2)
    #expect(fetch.results.allSatisfy { kind($0.result.failure) == "network" })
  }
}

/// A fake `gh api --include` printing `headers`, a blank line and `body`.
private func including(_ name: String, _ headers: String, _ body: JSON, _ code: Int) -> Gh {
  let dir = scratch(name)
  let file = dir.appendingPathComponent("response.txt")
  try! "HTTP/2.0 200 OK\r\n\(headers)\r\n\(body.text)".write(to: file, atomically: true, encoding: .utf8)
  return fakeGh(name, "cat '\(file.path)'\nexit \(code)", in: dir)
}

private func memberships(_ count: Int) -> JSON {
  [
    "data": [
      "viewer": ["login": "me", "url": "https://github.com/me"],
      "memberships": ["organizations": ["totalCount": .int(count)]],
    ]
  ]
}

private func membershipOf(_ name: String, _ headers: String, _ body: JSON) -> Membership {
  including(name, headers, body, 0).membership().membership
}

struct MembershipTests {
  @Test func anEmptyMembershipListCountsOnlyWithAnOrgScope() {
    for scope in ["read:org", "write:org", "admin:org"] {
      #expect(membershipOf(scope, "X-Oauth-Scopes: gist, \(scope), repo\r\n", memberships(0)) == .none)
    }
    let unrelated = "X-Oauth-Scopes: repo, user, read:packages\r\n"
    #expect(membershipOf("no-org-scope", unrelated, memberships(0)) == .unknown)
    #expect(
      membershipOf("no-scope-header", "", memberships(0)) == .unknown, "fine-grained tokens send no scopes")
  }

  @Test func anyMembershipIsConclusive() {
    #expect(membershipOf("member", "", memberships(2)) == .member)
  }

  @Test func aPartialOrFailedMembershipCheckIsUnknown() {
    let scopes = "X-Oauth-Scopes: read:org\r\n"
    var partial = memberships(0)
    partial["errors"] = [["message": "Resource not accessible by integration"]]
    #expect(membershipOf("partial", scopes, partial) == .unknown)
    var missing = memberships(0)
    missing["data"]["memberships"] = nil
    #expect(membershipOf("missing", scopes, missing) == .unknown)
    let failed = fakeGh("membership-failed", "echo 'HTTP 502' >&2\nexit 1").membership()
    #expect(failed.identity == nil && failed.membership == .unknown)
  }

  @Test func membershipHeadersParseWithBareNewlinesToo() throws {
    let dir = scratch("lf")
    let file = dir.appendingPathComponent("response.txt")
    try "HTTP/2.0 200 OK\nX-Oauth-Scopes: read:org\n\n\(memberships(0).text)".write(
      to: file, atomically: true, encoding: .utf8)
    let fetch = fakeGh("lf", "cat '\(file.path)'", in: dir).membership()
    #expect(fetch.membership == .none)
    #expect(fetch.identity?.login == "me", "names its account")
  }

  @Test func theMembershipCheckAsksGhForHeaders() throws {
    let dir = scratch("membership-args")
    let args = dir.appendingPathComponent("args").path
    _ = fakeGh("membership-args", "printf '%s\\n' \"$@\" > '\(args)'", in: dir).membership()
    let text = try String(contentsOfFile: args, encoding: .utf8)
    #expect(text.hasPrefix("api\n--include\ngraphql\n-f\nquery="))
    #expect(text.contains("organizations(first: 1) { totalCount }"))
  }
}
