import Foundation
import Testing

@testable import GhInboxCore

/// A fake gh that records its arguments in `args` and then runs `body`.
private func recording(_ name: String, _ body: String, env: [EnvVar] = []) -> (Gh, String) {
  let dir = scratch(name)
  let args = dir.appendingPathComponent("args").path
  return (fakeGh(name, "printf '%s\\n' \"$@\" > '\(args)'\n\(body)", in: dir, env: env), args)
}

struct CredentialTests {
  @Test func theTokenComesFromGhAuthTokenForTheDefaultHost() throws {
    let (gh, args) = recording("token", "printf 'gho_secret\\n'")
    let credential = try #require(gh.token().success)
    #expect(credential.host == "github.com" && credential.token == "gho_secret")
    #expect(try String(contentsOfFile: args, encoding: .utf8) == "auth\ntoken\n--hostname\ngithub.com\n")
  }

  @Test func ghHostPicksTheHost() throws {
    let host = EnvVar(Array("GH_HOST".utf8), Array("ghe.example.com".utf8))
    let (gh, args) = recording("gh-host", "echo tok", env: [host])
    #expect(try #require(gh.token().success).host == "ghe.example.com")
    #expect(try String(contentsOfFile: args, encoding: .utf8).hasSuffix("--hostname\nghe.example.com\n"))
  }

  @Test func missingBinaryIsNotInstalled() {
    #expect(Gh(program: "/nonexistent/gh", env: []).token().failure == .notInstalled)
  }

  @Test func noTokenIsNotLoggedIn() {
    let none = fakeGh("no-token", "echo 'no oauth token found for github.com' >&2; exit 1")
    #expect(none.token().failure == .notLoggedIn)
    #expect(fakeGh("exit-4", "exit 4").token().failure == .notLoggedIn)
    #expect(fakeGh("empty", "exit 0").token().failure == .notLoggedIn)
  }

  @Test func anotherFailureKeepsGhsMessage() {
    let gh = fakeGh("broken", "echo 'could not read config' >&2; exit 1")
    #expect(gh.token().failure == .gh("could not read config"))
  }

  @Test func aHungGhIsAbandoned() {
    var gh = fakeGh("hung", "sleep 5")
    gh.timeout = .milliseconds(200)
    let started = ContinuousClock.now
    #expect(kind(gh.token().failure) == "gh")
    #expect(ContinuousClock.now - started < .seconds(3))
  }
}

/// Section answers from `login`, every other request empty.
private func answer(_ query: String, login: String) -> Answer {
  let viewer: JSON = ["login": .string(login), "url": .string("https://github.com/\(login)")]
  if let alias = sections.map(\.alias).first(where: { query.contains("\($0): search(") }) {
    let empty: JSON = ["issueCount": 0, "pageInfo": ["hasNextPage": false], "nodes": []]
    return .json(["data": ["viewer": viewer, .init(stringLiteral: alias): empty]])
  }
  return .json(["data": ["viewer": viewer, "memberships": ["organizations": ["totalCount": 0]]]])
}

@MainActor
private func settle(_ model: InboxModel) async throws {
  let deadline = ContinuousClock.now + .seconds(10)
  while model.inbox.anyBusy || model.inFlight > 0 {
    guard ContinuousClock.now < deadline else { throw CancellationError() }
    try await Task.sleep(for: .milliseconds(10))
  }
}

/// Counts credential requests.
private final class Counter: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0
  func next() { lock.withLock { value += 1 } }
  var count: Int { lock.withLock { value } }
}

@MainActor
struct InboxModelTests {
  @Test func eachRoundAsksForTheTokenOnce() async throws {
    let server = FakeGitHub { answer($0.query, login: "me") }
    let asked = Counter()
    let credential = server.credential
    let github = GitHub(session: server.github().session) {
      asked.next()
      return .success(credential)
    }
    let model = InboxModel(github: github)
    model.refresh()
    try await settle(model)
    #expect(asked.count == 1, "four sections and the membership check share one")
    model.refresh()
    try await settle(model)
    #expect(asked.count == 2)
    #expect(model.inbox.identity?.login == "me")
  }

  @Test func aRoundsRequestsRunTogetherOnceTheTokenArrives() async throws {
    final class Overlap: @unchecked Sendable {
      let lock = NSLock()
      var now = 0
      var most = 0
      func enter() {
        lock.withLock {
          now += 1
          most = max(most, now)
        }
      }
      func leave() { lock.withLock { now -= 1 } }
    }
    let overlap = Overlap()
    let server = FakeGitHub { request in
      overlap.enter()
      return .after(.milliseconds(200)) {
        overlap.leave()
        return answer(request.query, login: "me")
      }
    }
    let credential = server.credential
    let github = GitHub(session: server.github().session) {
      try? await Task.sleep(for: .milliseconds(100))
      return .success(credential)
    }
    let model = InboxModel(github: github)
    model.refresh()
    try await settle(model)
    #expect(overlap.most == concurrency, "every slot's request was in flight at once")
  }

  @Test func anOlderRoundsJobTakesTheNewestCredential() async {
    let asked = Counter()
    let model = InboxModel(
      github: GitHub(session: answering(.hang).github().session) {
        asked.next()
        return .success(Credential(host: "github.com", token: "t"))
      })
    let newest = model.credential(for: 2)
    _ = await newest.value
    _ = await model.credential(for: 1).value
    _ = await model.credential(for: 2).value
    #expect(asked.count == 1, "no gh run for the older round, and the newer token stays")
    _ = await model.credential(for: 3).value
    #expect(asked.count == 2)
  }

  @Test func aRoundSettlesOnceEveryJobIsDone() async throws {
    let server = FakeGitHub { answer($0.query, login: "me") }
    let model = InboxModel(github: server.github())
    var settled: [Bool] = []
    model.settled = { settled.append($0.anyBusy || !$0.sections.allSatisfy(\.loaded)) }
    model.refresh()
    try await settle(model)
    #expect(settled == [false], "once per round, after the last job")
    model.refresh()
    try await settle(model)
    #expect(settled == [false, false])
  }

  @Test func aFailedCredentialFailsTheRound() async throws {
    let github = GitHub(session: answering(.hang).github().session) { .failure(.notLoggedIn) }
    let model = InboxModel(github: github)
    model.refresh()
    try await settle(model)
    #expect(model.inbox.commonError == .notLoggedIn)
  }

  @Test func anAccountChangeCancelsTheRequestsInFlight() async throws {
    // Round one answers as "old". Then the authored section's first request
    // hangs, and the review section answers as "new" once it has.
    final class Script: @unchecked Sendable {
      let lock = NSLock()
      var switched = false
      var hanging = false
      var hung = false
    }
    let script = Script()
    let server = FakeGitHub { request in
      let switched = script.lock.withLock { script.switched }
      guard switched else { return answer(request.query, login: "old") }
      if request.query.contains("authored: search(") {
        let first = script.lock.withLock {
          defer { script.hung = true }
          return !script.hung
        }
        if first {
          script.lock.withLock { script.hanging = true }
          return .hang
        }
      } else if request.query.contains("review: search(") {
        return .later {
          for _ in 0..<500 where !script.lock.withLock({ script.hanging }) { usleep(10_000) }
          return answer(request.query, login: "new")
        }
      }
      return answer(request.query, login: "new")
    }
    let model = InboxModel(github: server.github())
    model.refresh()
    try await settle(model)
    #expect(model.inbox.identity?.login == "old")

    script.lock.withLock { script.switched = true }
    model.refresh()
    try await settle(model)
    #expect(server.cancelled.map(\.query).contains { $0.contains("authored: search(") })
    #expect(model.inbox.identity?.login == "new")
    #expect(model.inbox.sections.allSatisfy { $0.loaded && $0.error == nil })
  }
}
