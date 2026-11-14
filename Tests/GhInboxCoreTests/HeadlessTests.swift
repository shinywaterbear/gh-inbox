import Foundation
import Testing

@testable import GhInboxCore

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

struct HeadlessTests {
  @Test func onlyItsOwnFlagsSkipTheWindow() {
    #expect(command([]) == .window)
    #expect(command(["-NSDocumentRevisionsDebugMode", "YES"]) == .window)
    #expect(command(["--help"]) == .help)
    #expect(command(["--json"]) == .json(queue: nil, limit: pageStep))
    #expect(command(["--json", "--queue", "back-to-me", "--limit=50"]) == .json(queue: 0, limit: 50))
    #expect(command(["--queue=my-open-prs", "--json"]) == .json(queue: 3, limit: pageStep))
  }

  @Test func aMistakeIsAUsageErrorNotTheWindow() {
    for arguments in [
      ["--json", "--queue", "inbox"], ["--json", "--queue"], ["--json", "--limit", "0"],
      ["--json", "--limit", "101"], ["--json", "--verbose"], ["--queue", "back-to-me"],
      ["--json", ""], ["--json", "="], ["--json", "--queue="], ["--json=yes"],
    ] {
      guard case .invalid = command(arguments) else {
        Issue.record("\(arguments)")
        continue
      }
    }
  }

  @Test func everyQueueHasItsOwnKey() {
    #expect(Set(sections.map(\.key)).count == sections.count)
    for spec in sections { #expect(usage.contains(spec.key)) }
  }

  @Test func reportsEachQueueOnceWithChecksAndCompleteness() async throws {
    let body = FileManager.default.contents(atPath: recorded)!
    let server = FakeGitHub { _ in .reply(status: 200, headers: [:], body: body) }
    let inbox = await loadOnce(server.github(), limit: 25)
    let (json, complete) = report(inbox, queue: nil)
    #expect(complete)
    #expect(json["login"] == "example-user" && json["host"] == "github.com")
    guard case .array(let queues) = json["queues"] else { throw Failure("no queues") }
    #expect(queues.map { $0["key"].string } == sections.map(\.key))
    let mine = queues[3]
    #expect(mine["loaded"] == true && mine["matched"] == 3 && mine["error"] == .null)
    guard case .array(let items) = mine["items"] else { throw Failure("no items") }
    #expect(items.count == 3)
    #expect(items.allSatisfy { $0["type"] == "pull_request" && $0["checks"] != .null })
    #expect(items.dropFirst().allSatisfy { $0["draft"] == true }, "the window's order")
    let urls = queues.flatMap { queue -> [String] in
      guard case .array(let items) = queue["items"] else { return [] }
      return items.compactMap { $0["url"].string }
    }
    #expect(Set(urls).count == urls.count, "an item shows in one queue")
    #expect(server.received.count > sections.count, "checks are looked up too")
  }

  @Test func oneQueueStillDeduplicatesAgainstTheOthers() async {
    let body = FileManager.default.contents(atPath: recorded)!
    let server = FakeGitHub { _ in .reply(status: 200, headers: [:], body: body) }
    let inbox = await loadOnce(server.github(), limit: 25)
    let all = report(inbox, queue: nil).json["queues"][5]
    let one = report(inbox, queue: 5).json["queues"]
    #expect(one == [all])
  }

  @Test func aFailureStillReportsAndSaysWhy() async {
    let server = answering(.fail(.notConnectedToInternet))
    let inbox = await loadOnce(server.github(), limit: 25)
    let (json, complete) = report(inbox, queue: 0)
    #expect(!complete)
    #expect(json["login"] == .null)
    #expect(json["queues"][0]["loaded"] == false)
    #expect(json["queues"][0]["error"].string?.hasPrefix("could not reach GitHub") == true)
    #expect(!json.text.contains(server.token))
  }

  /// An earlier queue that failed can't claim its items, so a later one
  /// may list them: the run is incomplete and the queue says why.
  @Test func oneQueueReportsAFailureEarlierInTheOrder() async {
    let body = FileManager.default.contents(atPath: recorded)!
    let server = FakeGitHub { request in
      request.query.contains("back: search")
        ? .fail(.notConnectedToInternet) : .reply(status: 200, headers: [:], body: body)
    }
    let inbox = await loadOnce(server.github(), limit: 25)
    let (later, complete) = report(inbox, queue: 4)
    #expect(!complete)
    #expect(later["queues"][0]["loaded"] == true && later["queues"][0]["error"] == .null)
    #expect(later["queues"][0]["warnings"][0].string?.hasPrefix("Back to me didn't load") == true)
    #expect(report(inbox, queue: 0).complete == false)
    let (all, _) = report(inbox, queue: nil)
    #expect(all["queues"][4]["warnings"] == [], "listing every queue shows the failure where it happened")
  }

  @Test func anItemNamesEveryQueueItMatched() async throws {
    let body = FileManager.default.contents(atPath: recorded)!
    let server = FakeGitHub { _ in .reply(status: 200, headers: [:], body: body) }
    let inbox = await loadOnce(server.github(), limit: 25)
    guard case .array(let queues) = report(inbox, queue: nil).json["queues"] else {
      throw Failure("no queues")
    }
    var listed = 0
    for queue in queues {
      guard case .array(let items) = queue["items"] else { continue }
      for item in items {
        guard case .array(let keys) = item["in_queues"] else { throw Failure("no in_queues") }
        let names = keys.compactMap(\.string)
        #expect(names.first == queue["key"].string, "the queue it shows in is the first it matched")
        #expect(names == sections.map(\.key).filter(names.contains), "in the window's order")
        listed += 1
      }
    }
    #expect(listed > 0)
    let held = sections.indices.flatMap { s in inbox.sections[s].items.map(\.url) }
    #expect(Set(held).count < held.count, "the recording has items in more than one queue")
  }

  @Test func theSnapshotIsEveryQueueWhicheverTabShows() async throws {
    let body = FileManager.default.contents(atPath: recorded)!
    let server = FakeGitHub { _ in .reply(status: 200, headers: [:], body: body) }
    var inbox = await loadOnce(server.github(), limit: 25)
    let all = report(inbox, queue: nil).json
    inbox.ownerFilter = .personal
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    var json = snapshot(inbox, at: date)
    #expect(json["generated_at"] == "2027-01-15T08:00:00Z")
    json["generated_at"] = nil
    #expect(json == all)
  }

  @Test func theSnapshotReplacesTheLastOneOnceAQueueLoaded() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("gh-inbox/inbox.json")
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    try writeSnapshot(Inbox(), at: date, to: url)
    #expect(!FileManager.default.fileExists(atPath: url.path), "nothing before any queue loads")
    let body = FileManager.default.contents(atPath: recorded)!
    let server = FakeGitHub { _ in .reply(status: 200, headers: [:], body: body) }
    let inbox = await loadOnce(server.github(), limit: 25)
    try writeSnapshot(inbox, at: date, to: url)
    try writeSnapshot(inbox, at: date.addingTimeInterval(60), to: url)
    let written = try JSONDecoder().decode(JSON.self, from: Data(contentsOf: url))
    #expect(written["generated_at"] == "2027-01-15T08:01:00Z")
    #expect(written["queues"] == report(inbox, queue: nil).json["queues"])
  }

  @Test func aMissingTokenFailsEveryQueue() async {
    let github = GitHub(session: .shared) { .failure(.notLoggedIn) }
    let (json, complete) = report(await loadOnce(github, limit: 25), queue: nil)
    #expect(!complete)
    #expect(json["queues"][2]["error"].string?.contains("gh auth login") == true)
  }
}

private struct Failure: Error {
  var message: String
  init(_ message: String) { self.message = message }
}
