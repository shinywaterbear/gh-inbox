import Foundation

// The window's queues as JSON on stdout, for scripts: one round,
// checks included, then exit. Only these flags leave the window unopened.

/// What the command line asks for.
public enum Command: Equatable, Sendable {
  case window
  case help
  /// `queue` is a `sections` index; nil prints every queue.
  case json(queue: Int?, limit: Int)
  case invalid(String)
}

private let headlessFlags: Set<String> = ["--json", "--queue", "--limit", "--help", "-h"]

/// Arguments the app doesn't know open the window, as a launch always has.
public func command(_ arguments: [String]) -> Command {
  let flags = arguments.map { flagAndValue($0).flag }
  guard flags.contains(where: headlessFlags.contains) else { return .window }
  if flags.contains("--help") || flags.contains("-h") { return .help }
  var json = false
  var queue: Int?
  var limit = pageStep
  var rest = arguments[...]
  while let argument = rest.popFirst() {
    let (flag, inline) = flagAndValue(argument)
    func value() -> String? { inline ?? rest.popFirst() }
    switch flag {
    case "--json" where inline == nil:
      json = true
    case "--queue":
      guard let name = value(), let index = sections.firstIndex(where: { $0.key == name }) else {
        return .invalid("--queue takes one of: \(sections.map(\.key).joined(separator: ", "))")
      }
      queue = index
    case "--limit":
      guard let text = value(), let n = Int(text), (1...pageMax).contains(n) else {
        return .invalid("--limit takes a number from 1 to \(pageMax)")
      }
      limit = n
    default:
      return .invalid("unknown argument: \"\(argument)\"")
    }
  }
  return json ? .json(queue: queue, limit: limit) : .invalid("--queue and --limit go with --json")
}

/// `--queue=x` as `("--queue", "x")`; an argument without `=` has no value.
private func flagAndValue(_ argument: String) -> (flag: String, value: String?) {
  guard let equals = argument.firstIndex(of: "=") else { return (argument, nil) }
  return (String(argument[..<equals]), String(argument[argument.index(after: equals)...]))
}

public let usage: String = {
  let width = sections.map(\.key.count).max() ?? 0
  let queues = sections.map {
    "  \($0.key.padding(toLength: width, withPad: " ", startingAt: 0))  \($0.about)"
  }
  return """
    usage: gh-inbox [--json [--queue <name>] [--limit <n>]]

    With no arguments, opens the window. With --json, prints the inbox of the
    account gh is logged in as to stdout and exits, opening nothing.

      --json          every queue, in the window's order
      --queue <name>  only this queue
      --limit <n>     each queue's newest n matches, 1 to \(pageMax) (default \(pageStep))

    Queues, in priority order; an item is listed only in the first that has it:
    \(queues.joined(separator: "\n"))

    The window writes the same report of every queue to
    ~/Library/Caches/gh-inbox/inbox.json each time a refresh finishes, with
    generated_at, for scripts that would rather not fetch.

    Exits 0 when every queue loaded, 1 when any failed (the JSON still has
    what did load, and each failure's reason), 2 for a usage error. With
    --queue, a failure in an earlier queue counts too, and the queue's
    warnings name it.
    """
}()

/// Runs one round as the window's first would, every job to the end.
public func loadOnce(_ github: GitHub, limit: Int) async -> Inbox {
  var inbox = Inbox()
  for s in inbox.sections.indices { inbox.sections[s].size = limit }
  inbox.refresh()
  let credential = await github.credential()
  await withTaskGroup(of: (Ticket, Outcome).self) { group in
    while true {
      while let ticket = inbox.nextJob() {
        group.addTask {
          switch credential {
          case .success(let credential): (ticket, await github.perform(ticket.job, as: credential))
          case .failure(let error): (ticket, .failed(ticket.job, error))
          }
        }
      }
      guard let (ticket, outcome) = await group.next() else { break }
      // A different account mid-run resets the inbox; its queues then read
      // as failed rather than mixing two accounts.
      inbox.finish(ticket, outcome, now: .now)
    }
  }
  return inbox
}

/// The inbox as `--json` prints it, and whether every queue it depends on
/// loaded: a listed queue, and with `queue`, each earlier one, since an
/// earlier queue that failed can't claim the items it would have taken.
public func report(_ inbox: Inbox, queue: Int?) -> (json: JSON, complete: Bool) {
  let visible = inbox.visible()
  let host = inbox.identity?.host ?? "github.com"
  let listed = queue.map { [$0] } ?? Array(sections.indices)
  func failure(_ s: Int) -> GhError? {
    inbox.sections[s].error ?? (inbox.sections[s].loaded ? nil : GhError.cancelled)
  }
  let needed = queue.map { Array(0...$0) } ?? Array(sections.indices)
  let complete = needed.allSatisfy { failure($0) == nil }
  let queues: [JSON] = listed.map { s in
    let section = inbox.sections[s]
    let shown = visible[s].map { section.items[$0] }
    let error = failure(s)
    let short = section.loaded && (section.truncated || shown.count < section.matched)
    // Shown only with `--queue`; listing every queue shows each failure.
    let earlier =
      queue == nil
      ? []
      : (0..<s).compactMap { e in
        failure(e).map {
          "\(sections[e].name) didn't load, so items it would list may show here instead: \($0.described)"
        }
      }
    return [
      "key": .string(sections[s].key),
      "name": .string(sections[s].name),
      "loaded": .bool(section.loaded),
      "error": error.map { .string($0.described) } ?? .null,
      "warnings": .array((earlier + section.warnings.map(\.described)).map { .string($0) }),
      "matched": section.loaded ? .int(section.matched) : nil,
      "truncated": .bool(section.truncated),
      "shortfall": short ? .string(shortfall(inbox, queue: s)) : nil,
      "search_url": .string(searchURL(s, host: host)),
      "items": .array(shown.map { item(inbox, $0) }),
    ]
  }
  let json: JSON = [
    "login": inbox.identity.map { .string($0.login) } ?? .null,
    "host": .string(host),
    "queues": .array(queues),
  ]
  return (json, complete)
}

private func item(_ inbox: Inbox, _ item: Item) -> JSON {
  let review: JSON =
    switch item.review {
    case .approved: "approved"
    case .changesRequested: "changes_requested"
    case .required: "review_required"
    case nil: nil
    }
  let checks: JSON =
    switch inbox.check(item) {
    case nil: nil
    case .known(let checks?, _): .string("\(checks)")
    case .known(nil, _): "none"
    case .loading, .failed: "unknown"
    }
  let owner: JSON =
    switch item.repository.ownerKind {
    case .personal: "user"
    case .organization: "organization"
    case .unknown: nil
    }
  // Every queue the item matched, not just the one it shows in: a PR
  // pushed to since your review and also re-requested of you shows in
  // Back to me, and only this says it was asked again.
  let matching = inbox.sections.indices.filter { s in inbox.sections[s].items.contains { $0.url == item.url }
  }
  return [
    "url": .string(item.url),
    "in_queues": .array(matching.map { .string(sections[$0].key) }),
    "repository": .string(item.repository.nameWithOwner),
    "owner_type": owner,
    "number": .int(item.number),
    "title": .string(item.title),
    "author": .string(item.author),
    "type": item.isPullRequest ? "pull_request" : "issue",
    "draft": .bool(item.isDraft),
    "review": review,
    "route": routeLabel(item.reviewRoute).map { .string($0) } ?? .null,
    "checks": checks,
    "updated_at": .string(item.updatedAt),
  ]
}

/// `--json` from start to exit code, blocking the calling thread.
public func runJSON(queue: Int?, limit: Int, github: GitHub = .live()) -> Int32 {
  let done = DispatchSemaphore(value: 0)
  let result = Box()
  Task.detached {
    result.value = report(await loadOnce(github, limit: limit), queue: queue)
    done.signal()
  }
  done.wait()
  guard let (json, complete) = result.value else { return 1 }
  FileHandle.standardOutput.write(encoded(json))
  return complete ? 0 : 1
}

private func encoded(_ json: JSON) -> Data {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
  return ((try? encoder.encode(json)) ?? Data("null".utf8)) + Data("\n".utf8)
}

// The window's latest round, left on disk for scripts that want it without
// a request of their own.

/// Where the window writes its latest round: inside the user's caches
/// folder, `~/Library/Caches` on macOS.
public let cacheURL: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
  .appendingPathComponent("gh-inbox", isDirectory: true).appendingPathComponent("inbox.json")

/// The `--json` report of every queue, whichever owner tab the window
/// shows, with `generated_at`: when the round it holds finished.
public func snapshot(_ inbox: Inbox, at date: Date) -> JSON {
  var all = inbox
  all.ownerFilter = .all
  var json = report(all, queue: nil).json
  json["generated_at"] = .string(date.formatted(.iso8601))
  return json
}

/// Replaces `url` with the inbox's snapshot in one step, so a reader never
/// sees half a file. Nothing is written before any queue has loaded.
public func writeSnapshot(_ inbox: Inbox, at date: Date, to url: URL) throws {
  guard inbox.anyLoaded else { return }
  try FileManager.default.createDirectory(
    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
  try encoded(snapshot(inbox, at: date)).write(to: url, options: .atomic)
}

private final class Box: @unchecked Sendable {
  var value: (JSON, Bool)?
}
