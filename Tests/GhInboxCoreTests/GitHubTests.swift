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

/// The recorded response, for any request.
private func recordedGitHub() -> FakeGitHub {
  let body = FileManager.default.contents(atPath: recorded)!
  return FakeGitHub { _ in .reply(status: 200, headers: [:], body: body) }
}

/// Runs `call` against the recorded response, returning the query sent.
private func sentQuery(_ call: (FakeGitHub) async -> Void) async throws -> String {
  let server = recordedGitHub()
  await call(server)
  let sent = try #require(server.received.last)
  #expect(sent.method == "POST" && sent.url == "https://api.github.com/graphql")
  #expect(sent.authorization == "bearer \(server.token)")
  #expect(sent.query.hasPrefix("query {"))
  #expect(sent.query.contains("viewer { login url }"), "every request names its account")
  return sent.query
}

struct SectionRequestTests {
  @Test func eachSectionSendsOneSearchOfTheSizeAsked() async throws {
    for (index, spec) in sections.enumerated() {
      let sent = try await sentQuery { _ = await $0.section(index, size: 50) }
      let query = search(index, directOnly: false)
      #expect(sent.contains("\(spec.alias): search(query: \"\(query)\", type: ISSUE, first: 50)"))
      #expect(sent.components(separatedBy: "search(").count == 2)
      #expect(query.hasSuffix(" sort:updated-desc"), "\(spec.alias)")
      #expect(sent.contains("fragment items on SearchResultItemConnection"))
      #expect(sent.contains("reviewRequests") == (index == review), "only the review section reads requests")
      #expect(!sent.contains("statusCheckRollup"), "checks load separately")
    }
  }

  @Test func checkLookupsSendTheIds() async throws {
    let sent = try await sentQuery { _ = await $0.checks(["PR_a", "PR_b"]) }
    #expect(sent.contains(#"nodes(ids: ["PR_a","PR_b"])"#))
    #expect(sent.contains("fragment checks on PullRequest"))
  }

  @Test func parsesRecordedResponsePerSection() async throws {
    let server = recordedGitHub()
    let fetch = await server.section(authored)
    #expect(fetch.identity == Identity(login: "example-user", host: "github.com"))
    let (mine, warnings) = try page(fetch)
    #expect(warnings.isEmpty && !mine.truncated)
    #expect(mine.items.count == 3)
    #expect(mine.items.dropFirst().allSatisfy { $0.isDraft }, "drafts last")
    #expect(mine.items.allSatisfy { $0.head != nil })
    for index in sections.indices {
      let (section, warnings) = try await page(server.section(index))
      #expect(!section.truncated && warnings.isEmpty, "\(index)")
    }
  }

  @Test func directOnlySwapsOneQualifierAndTheLinkFollows() async throws {
    let any = search(review, directOnly: false)
    let direct = search(review, directOnly: true)
    #expect(any.replacingOccurrences(of: "review-requested", with: "user-review-requested") == direct)
    for (directOnly, expected) in [(false, any), (true, direct)] {
      let sent = try await sentQuery { _ = await $0.section(review, directOnly: directOnly) }
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

  @Test func eachHostGetsGhsEndpoint() {
    #expect(endpoint(host: "github.com")?.absoluteString == "https://api.github.com/graphql")
    #expect(endpoint(host: "GitHub.com")?.absoluteString == "https://api.github.com/graphql")
    #expect(endpoint(host: "acme.ghe.com")?.absoluteString == "https://api.acme.ghe.com/graphql")
    #expect(endpoint(host: "ghe.example.com")?.absoluteString == "https://ghe.example.com/api/graphql")
  }

  @Test func requestsGoToTheCredentialsHost() async throws {
    let server = FakeGitHub(host: "acme.ghe.com") { _ in .json(response(conn([]), conn([]))) }
    _ = await server.section(review)
    #expect(try #require(server.received.first).url == "https://api.acme.ghe.com/graphql")
  }
}

/// The error from a section whose request got `answer`.
private func failing(_ answer: Answer, timeout: Duration = .seconds(10)) async -> GhError? {
  let server = answering(answer)
  let fetch = await server.github(timeout: timeout).section(
    review, size: 25, directOnly: false, as: server.credential)
  let error = unavailable(fetch)
  if let error { #expect(!error.described.contains(server.token), "the token never shows") }
  return error
}

struct TokenSafetyTests {
  @Test func aCredentialNeverPrintsItsToken() {
    let credential = Credential(host: "github.com", token: "gho_secret")
    var dumped = ""
    dump(credential, to: &dumped)
    for text in ["\(credential)", String(reflecting: credential), dumped] {
      #expect(!text.contains("gho_secret") && text.contains("github.com"), "\(text)")
    }
  }

  @Test func redirectsStayOnTheSameSchemeAndHost() {
    let api = URL(string: "https://api.github.com/graphql")
    #expect(follows(from: api, to: URL(string: "https://API.github.com/moved")))
    #expect(!follows(from: api, to: URL(string: "https://elsewhere.example/graphql")))
    #expect(!follows(from: api, to: URL(string: "http://api.github.com/graphql")))
    #expect(!follows(from: api, to: URL(string: "https://api.github.com:8443/graphql")))
    #expect(follows(from: api, to: URL(string: "https://api.github.com:443/moved")))
    #expect(!follows(from: api, to: nil))
  }

  // Linux's URLSession traps on a URLProtocol redirect, and only macOS runs
  // the app.
  #if !canImport(FoundationNetworking)
    @Test func aRedirectToAnotherHostIsNotFollowed() async throws {
      let server = FakeGitHub { request in
        request.url.contains("elsewhere.example")
          ? .json(response(conn([]), conn([]))) : .redirect("https://elsewhere.example/graphql")
      }
      // A fake can't finish a refused redirect, so it ends at the timeout;
      // over the network the 307 itself is the reply.
      let fetch = await server.github(timeout: .seconds(1)).section(
        review, size: 25, directOnly: false, as: server.credential)
      #expect(fetch.page.failure != nil)
      #expect(
        server.received.allSatisfy { !$0.url.contains("elsewhere.example") }, "the token stays on GitHub")
    }

    @Test func aRedirectOnTheSameHostIsFollowed() async throws {
      let server = FakeGitHub { request in
        request.url.hasSuffix("/moved")
          ? .json(response(conn([]), conn([]))) : .redirect("https://api.github.com/moved")
      }
      #expect(await server.section(review).page.success != nil)
      #expect(server.received.map(\.url).last == "https://api.github.com/moved")
    }
  #endif
}

struct FailureTests {
  @Test func rejectedTokenIsBadCredentials() async {
    let body: JSON = ["message": "Bad credentials", "documentation_url": "https://docs.github.com/graphql"]
    let error = await failing(.json(body, status: 401))
    #expect(error == .badCredentials("HTTP 401: Bad credentials (https://api.github.com/graphql)"))
    #expect(error?.hint?.contains("gh auth login") == true)
  }

  @Test func networkFailureIsNetwork() async {
    #expect(await failing(.fail(.cannotFindHost)) == .network("No server was found at api.github.com"))
    #expect(
      await failing(.fail(.notConnectedToInternet))
        == .network("The Internet connection appears to be offline"))
    #expect(kind(await failing(.fail(.badServerResponse))) == "network")
  }

  @Test func aSilentServerTimesOut() async {
    let started = ContinuousClock.now
    #expect(await failing(.hang, timeout: .milliseconds(300)) == .timeout(.milliseconds(300)))
    #expect(ContinuousClock.now - started < .seconds(5))
  }

  @Test func garbageOutputIsAParseError() async {
    #expect(kind(await failing(.text("not json", status: 200))) == "parse")
  }

  @Test func aBodyWithNeitherDataNorErrorsIsAParseError() async {
    #expect(kind(await failing(.json(["unexpected": true]))) == "parse")
  }

  @Test func wholeQueryRateLimitIsUnavailable() async {
    let json: JSON = ["errors": [["type": "RATE_LIMITED", "message": "API rate limit exceeded"]]]
    #expect(kind(await failing(.json(json))) == "rateLimited")
  }

  @Test func rateLimitStatusesAreRateLimits() async {
    let primary: JSON = ["message": "API rate limit exceeded for user ID 1."]
    #expect(kind(await failing(.json(primary, status: 403))) == "rateLimited")
    #expect(kind(await failing(.text("", status: 429))) == "rateLimited")
  }

  @Test func aForbiddenStatusIsForbidden() async {
    let body: JSON = ["message": "Resource protected by organization SAML enforcement."]
    #expect(kind(await failing(.json(body, status: 403))) == "forbidden")
  }

  @Test func anIpAllowListStatusPointsAtTheNetwork() async {
    let body: JSON = ["message": "The `o` organization has an IP allow list enabled."]
    let error = await failing(.json(body, status: 403))
    #expect(kind(error) == "ipRestricted")
    #expect(error?.hint?.contains("VPN") == true)
  }

  @Test func aFailedSearchStillNamesTheAccount() async {
    var json = response(nil, conn([]))
    json["errors"] = [["type": "FORBIDDEN", "path": ["review"], "message": "Resource not accessible"]]
    let fetch = await responding(json).section(review, size: 25, directOnly: false)
    #expect(fetch.identity != nil)
    #expect(kind(fetch.page.failure) == "forbidden")
  }

  @Test func aMalformedSectionIsAParseError() async {
    let json = response(["nodes": "not a list"], conn([]))
    let fetch = await responding(json).section(review, size: 25, directOnly: false)
    #expect(kind(fetch.page.failure) == "parse")
  }

  @Test func aBare502IsAServerError() async {
    let error = await failing(.text("<html>Bad Gateway</html>", status: 502))
    #expect(
      error == .server("HTTP 502: Bad Gateway (https://api.github.com/graphql)"), "worded as gh words it")
  }

  @Test func a504IsAServerError() async {
    #expect(kind(await failing(.text("", status: 504))) == "server")
  }

  @Test func aQueryTimeoutBodyIsAServerError() async {
    let json: JSON = [
      "data": nil,
      "errors": [
        [
          "message":
            "Something went wrong while executing your query. This may be the result of a timeout, or it could be a GitHub bug."
        ]
      ],
    ]
    let error = await failing(.json(json))
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

  @Test func anIpAllowListPointsAtTheNetwork() async throws {
    var json = response(conn([nil, pr(2, "2026-11-01T00:00:00Z")]), conn([]))
    json["errors"] = [
      [
        "type": "FORBIDDEN", "path": ["review", "nodes", 0],
        "message":
          "Although you appear to have the correct authorization credentials, the `o` organization has an IP allow list enabled, and your IP address is not permitted to access this resource.",
      ]
    ]
    let (_, warnings) = try await page(responding(json).section(review, size: 25, directOnly: false))
    #expect(warnings.count == 1 && kind(warnings.first) == "ipRestricted")
    #expect(warnings.first?.hint?.contains("VPN") == true)
  }
}

struct PartialResultTests {
  @Test func aMalformedItemCostsOnlyItselfAndIsReported() async throws {
    var broken = pr(2, "2026-11-01T00:00:00Z")
    broken["title"] = nil
    let json = response(conn([broken, pr(3, "2026-11-01T00:00:00Z")]), conn([]))
    let (found, warnings) = try await page(
      responding(json).section(review, size: 25, directOnly: false))
    #expect(found.items.count == 1)
    #expect(warnings == [.unreadable(1)])
  }

  @Test func ssoWithheldItemsKeepTheRestAndSaySo() async throws {
    var json = response(conn([nil, pr(2, "2026-11-01T00:00:00Z")]), conn([]))
    json["errors"] = [
      [
        "type": "FORBIDDEN", "path": ["review", "nodes", 0],
        "message": "Resource protected by organization SAML enforcement.",
      ]
    ]
    let (found, warnings) = try await page(responding(json).section(review, size: 25, directOnly: false))
    #expect(found.items.count == 1)
    #expect(warnings.count == 1 && kind(warnings.first) == "forbidden")
  }

  @Test func unexplainedMissingItemsStillWarn() async throws {
    let json = response(conn([nil]), conn([]))
    let (_, warnings) = try await page(
      responding(json).section(review, size: 25, directOnly: false))
    #expect(warnings == [.withheld(1)])
  }

  @Test func anErrorInsideAPresentItemIsNotLost() async throws {
    var json = response(conn([pr(4, "2026-11-01T00:00:00Z")]), conn([]))
    json["errors"] = [
      [
        "type": "FORBIDDEN", "path": ["review", "nodes", 0, "commits"],
        "message": "Resource not accessible by integration",
      ]
    ]
    let (found, warnings) = try await page(
      responding(json).section(review, size: 25, directOnly: false))
    #expect(found.items.count == 1)
    #expect(warnings.count == 1 && kind(warnings.first) == "forbidden")
  }

  @Test func errorsWithoutAPathWarnTheSectionThatAsked() async throws {
    var json = response(conn([]), conn([]))
    json["errors"] = [["type": "INTERNAL", "message": "Something went wrong"]]
    let (_, warnings) = try await page(responding(json).section(review, size: 25, directOnly: false))
    #expect(warnings == [.github("Something went wrong")])
  }

  @Test func truncatedSectionsSaySoAndLinkTheFullSearch() async throws {
    var json = response(conn([pr(1, "2026-11-01T00:00:00Z")]), conn([]))
    json["data"]["review"]["issueCount"] = 342
    json["data"]["review"]["pageInfo"]["hasNextPage"] = true
    let (found, _) = try await page(responding(json).section(review, size: 25, directOnly: false))
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

  @Test func searchLinksFollowTheViewersHost() async throws {
    var json = response(conn([]), conn([]))
    json["data"]["viewer"]["url"] = "https://ghe.example.com/me"
    let host = try #require(await responding(json).section(review, size: 25, directOnly: false).identity)
      .host
    #expect(host == "ghe.example.com")
    #expect(searchURL(review, host: host, directOnly: false).hasPrefix("https://ghe.example.com/search?"))
  }

  @Test func pageCountsWhatGitHubReturnedNotWhatSurvived() async throws {
    var broken = pr(8, "2026-11-01T00:00:00Z")
    broken["title"] = nil
    let json = response(conn([broken, nil, pr(9, "2026-11-01T00:00:00Z")]), conn([]))
    let (found, _) = try await page(responding(json).section(review, size: 25, directOnly: false))
    #expect(found.returned == 3 && found.items.count == 1)
  }
}

struct ItemTests {
  @Test func approvedAndDraftPrsSinkInThatOrder() async throws {
    let json = response(
      conn([
        pr(1, "2026-11-04T00:00:00Z", draft: true),
        pr(2, "2026-11-03T00:00:00Z", decision: "APPROVED"),
        pr(3, "2026-10-01T00:00:00Z", decision: "REVIEW_REQUIRED"),
        pr(4, "2026-11-02T00:00:00Z"),
      ]), conn([]))
    let numbers = try await items(responding(json).section(review, size: 25, directOnly: false)).map(
      \.number)
    #expect(numbers == [4, 3, 2, 1])
  }

  @Test func reviewsDecideOnlyFromCompleteOpinions() async {
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

  @Test func checkStatesMapToThreeColors() async {
    #expect(checks("SUCCESS") == .passing)
    #expect(checks("ERROR") == .failing)
    #expect(checks("EXPECTED") == .pending)
  }

  @Test func deletedAuthorsShowAsGhost() async throws {
    var item = pr(6, "2026-11-01T00:00:00Z")
    item["author"] = nil
    let found = try await items(
      responding(response(conn([item]), conn([]))).section(review, size: 25, directOnly: false))
    #expect(found[0].author == ghost)
  }

  @Test func aWithheldReviewerOpinionBlocksInferredApproval() async throws {
    var item = pr(7, "2026-11-01T00:00:00Z")
    item["latestOpinionatedReviews"]["nodes"] = [["state": "APPROVED"], nil]
    let found = try await items(
      responding(response(conn([item]), conn([]))).section(
        review, size: 25, directOnly: false))
    #expect(found[0].review == nil)
  }

  @Test func repositoryOwnerTypenameTellsPersonalFromOrganization() async throws {
    var org = pr(11, "2026-11-01T00:00:00Z")
    org["repository"]["owner"] = ["__typename": "Organization"]
    var personal = pr(12, "2026-10-31T00:00:00Z")
    personal["repository"]["owner"] = ["__typename": "User"]
    let found = try await items(
      responding(response(conn([org, personal]), conn([])))
        .section(review, size: 25, directOnly: false))
    #expect(found.first { $0.number == 11 }?.repository.ownerKind == .organization)
    #expect(found.first { $0.number == 12 }?.repository.ownerKind == .personal)
  }

  @Test func aRepositoryWithNoOwnerTypeIsUnknownNotPersonal() async throws {
    let found = try await items(
      responding(response(conn([pr(13, "2026-11-01T00:00:00Z")]), conn([])))
        .section(review, size: 25, directOnly: false))
    #expect(found[0].repository.ownerKind == .unknown)
  }
}

/// The review section's route for a PR whose request list is `nodes`.
private func route(_ name: String, _ nodes: JSON, hasNextPage: Bool) async throws -> ReviewRoute? {
  var item = pr(8, "2026-11-01T00:00:00Z")
  item["reviewRequests"] = ["pageInfo": ["hasNextPage": .bool(hasNextPage)], "nodes": nodes]
  return try await items(
    responding(response(conn([item]), conn([]))).section(review, size: 25, directOnly: false))[
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
  @Test func aDirectRequestWinsOverTeamsEvenOnAPartialList() async throws {
    let nodes: JSON = [team("platform"), user("other"), user("me")]
    #expect(try await route("mixed", nodes, hasNextPage: false) == .direct)
    #expect(try await route("mixed-cut", nodes, hasNextPage: true) == .direct)
    let behindNull: JSON = [nil, ["requestedReviewer": nil], user("me")]
    #expect(try await route("null-then-me", behindNull, hasNextPage: false) == .direct)
  }

  @Test func onlyACompleteListWithOneTeamNamesIt() async throws {
    #expect(
      try await route("one-team", [user("other"), team("platform")], hasNextPage: false) == .team("platform"))
    #expect(
      try await route("two-teams", [team("platform"), team("security")], hasNextPage: false) == .someTeam,
      "not the first one listed")
  }

  @Test func aCutOffOrWithheldRequestListIsUnknown() async throws {
    #expect(
      try await route("cut-off", [team("platform")], hasNextPage: true) == .unknown,
      "the viewer may be past the page")
    #expect(try await route("null-node", [team("platform"), nil], hasNextPage: false) == .unknown)
    #expect(
      try await route("null-reviewer", [team("platform"), ["requestedReviewer": nil]], hasNextPage: false)
        == .unknown,
      "a hidden team may be the viewer's")
    #expect(
      try await route("unsupported", [["requestedReviewer": ["__typename": "Robot"]]], hasNextPage: false)
        == .unknown)
    #expect(try await route("empty", [], hasNextPage: false) == .unknown)
    let missing = try await items(
      responding(response(conn([pr(9, "2026-11-01T00:00:00Z")]), conn([])))
        .section(review, size: 25, directOnly: false))
    #expect(missing[0].reviewRoute == .unknown)
  }

  @Test func theDirectOnlySearchNeedsNoRequestList() async throws {
    let direct = try await items(
      responding(response(conn([pr(10, "2026-11-01T00:00:00Z")]), conn([])))
        .section(review, size: 25, directOnly: true))
    #expect(direct[0].reviewRoute == .direct)
  }

  @Test func otherSectionsHaveNoReviewRoute() async throws {
    var item = pr(11, "2026-11-01T00:00:00Z")
    item["reviewRequests"] = ["pageInfo": ["hasNextPage": false], "nodes": [team("platform")]]
    let mine = try await items(
      responding(response(conn([]), conn([item])))
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

private func gatedState(_ name: String, _ node: JSON) async throws -> Checks? {
  let json: JSON = ["data": ["viewer": ["login": "me", "url": "https://github.com/me"], "nodes": [node]]]
  let fetch = await responding(json).checks(["PR_a"])
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
  @Test func everyRequestedCheckGetsAnAnswer() async {
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
    let fetch = await responding(json).checks(["PR_a", "PR_b", "PR_c", "PR_d", "PR_e"])
    #expect(fetch.identity != nil)
    let results = fetch.results.map(\.result)
    #expect(results[0] == .success(CheckState(head: "a1", checks: .failing)))
    #expect(results[1] == .failure(.withheld(1)))
    #expect(results[2] == .success(CheckState(head: "c1", checks: nil)))
    #expect(kind(results[3].failure) == "forbidden")
    #expect(results[4] == .failure(.unreadable(1)), "answer for another id")
  }

  @Test func aRequiredCheckThatNeverReportedIsPendingNotPassing() async throws {
    // Seen for real: the ruleset gained a required check after the PR's
    // checks ran, so GitHub's rollup says SUCCESS without it.
    let node = gatedNode("SUCCESS", ran, total: ran.count, required: ["Gate / Validate"])
    #expect(try await gatedState("gated-missing", node) == .pending)
  }

  @Test func aRequiredCheckThatReportedLeavesTheRollupAlone() async throws {
    let all = ran + ["Gate / Validate"]
    let node = gatedNode("SUCCESS", all, total: all.count, required: ["Gate / Validate"])
    #expect(try await gatedState("gated-reported", node) == .passing)
  }

  @Test func aMissingRequiredCheckDoesNotHideAFailure() async throws {
    let node = gatedNode("FAILURE", ran, total: ran.count, required: ["Gate / Validate"])
    #expect(try await gatedState("gated-failing", node) == .failing)
  }

  @Test func aRequiredCheckOnACommitWithNoChecksIsPending() async throws {
    var node = gatedNode("SUCCESS", [], total: 0, required: ["Gate / Validate"])
    node["commits"]["nodes"][0]["commit"]["statusCheckRollup"] = nil
    #expect(try await gatedState("gated-no-rollup", node) == .pending)
  }

  @Test func aRequiredCommitStatusCountsByItsContext() async throws {
    #expect(try await gatedState("gated-status", withStatus(["ci/legacy"])) == .passing)
  }

  @Test func commitStatusesCompleteTheListThatProvesACheckMissing() async throws {
    #expect(
      try await gatedState("gated-status-missing", withStatus(["ci/legacy", "Gate / Validate"])) == .pending)
  }

  @Test func branchProtectionRequirementsCountToo() async throws {
    var node = gatedNode("SUCCESS", ran, total: ran.count, required: [])
    node["baseRef"]["branchProtectionRule"] = ["requiredStatusCheckContexts": ["Gate / Validate"]]
    #expect(try await gatedState("gated-classic", node) == .pending)
  }

  @Test func aRequiredCheckPassingOnTheTestMergeCommitIsNotMissing() async throws {
    let head = gatedNode("SUCCESS", ran, total: ran.count, required: ["Gate / Validate"])
    #expect(
      try await gatedState("gated-merge-pass", withMergeCommit(head, "SUCCESS", ["Gate / Validate"]))
        == .passing)
  }

  @Test func theTestMergeCommitStatusWinsOverTheHead() async throws {
    let head = gatedNode("SUCCESS", ran, total: ran.count, required: [])
    #expect(
      try await gatedState("gated-merge-fail", withMergeCommit(head, "FAILURE", ["external"])) == .failing)
  }

  @Test func aTestMergeCommitWithoutAStatusLeavesTheHeadToDecide() async throws {
    var node = gatedNode("SUCCESS", ran, total: ran.count, required: ["Gate / Validate"])
    node["potentialMergeCommit"] = ["statusCheckRollup": nil]
    #expect(try await gatedState("gated-merge-none", node) == .pending)
  }

  @Test func aCutOffCheckListCannotProveACheckMissing() async throws {
    let node = gatedNode("SUCCESS", ran, total: 150, required: ["Gate / Validate"])
    #expect(try await gatedState("gated-cut-off", node) == .passing)
  }

  @Test func aFailedCheckLookupFailsEveryId() async {
    let fetch = await answering(.fail(.timedOut)).checks(["PR_a", "PR_b"])
    #expect(fetch.identity == nil)
    #expect(fetch.results.count == 2)
    #expect(fetch.results.allSatisfy { kind($0.result.failure) == "timeout" })
  }
}

private func memberships(_ count: Int) -> JSON {
  [
    "data": [
      "viewer": ["login": "me", "url": "https://github.com/me"],
      "memberships": ["organizations": ["totalCount": .int(count)]],
    ]
  ]
}

private func membershipOf(_ scopes: String?, _ body: JSON) async -> Membership {
  let headers = scopes.map { ["X-OAuth-Scopes": $0] } ?? [:]
  return await responding(body, headers: headers).membership().membership
}

struct MembershipTests {
  @Test func anEmptyMembershipListCountsOnlyWithAnOrgScope() async {
    for scope in ["read:org", "write:org", "admin:org"] {
      #expect(await membershipOf("gist, \(scope), repo", memberships(0)) == .none)
    }
    #expect(await membershipOf("repo, user, read:packages", memberships(0)) == .unknown)
    #expect(await membershipOf(nil, memberships(0)) == .unknown, "fine-grained tokens send no scopes")
  }

  @Test func anyMembershipIsConclusive() async {
    #expect(await membershipOf(nil, memberships(2)) == .member)
  }

  @Test func aPartialOrFailedMembershipCheckIsUnknown() async {
    var partial = memberships(0)
    partial["errors"] = [["message": "Resource not accessible by integration"]]
    #expect(await membershipOf("read:org", partial) == .unknown)
    var missing = memberships(0)
    missing["data"]["memberships"] = nil
    #expect(await membershipOf("read:org", missing) == .unknown)
    let failed = await answering(.text("", status: 502)).membership()
    #expect(failed.identity == nil && failed.membership == .unknown)
  }

  @Test func theScopesHeaderIsReadInAnyCase() async {
    let fetch = await responding(memberships(0), headers: ["x-oauth-scopes": "read:org"]).membership()
    #expect(fetch.membership == .none)
    #expect(fetch.identity?.login == "me", "names its account")
  }

  @Test func theMembershipCheckAsksForOrganizations() async throws {
    let server = responding(memberships(1))
    _ = await server.membership()
    #expect(try #require(server.received.first).query.contains("organizations(first: 1) { totalCount }"))
  }
}
