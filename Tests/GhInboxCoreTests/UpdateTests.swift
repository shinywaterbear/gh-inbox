import Foundation
import Testing

@testable import GhInboxCore

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// The template as a sync stamps it.
private func plist(_ sync: Int) -> String {
  """
  <?xml version="1.0" encoding="UTF-8"?>
  <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
  <plist version="1.0">
  <dict>
  \t<key>CFBundleShortVersionString</key>
  \t<string>0.1.0</string>
  \t<key>CFBundleVersion</key>
  \t<string>\(sync)</string>
  </dict>
  </plist>

  """
}

private func reply(_ status: Int, _ body: Data = Data(), etag: String? = nil) -> Result<Reply, GhError> {
  .success(Reply(status: status, body: body, scopes: nil, etag: etag, url: "u"))
}

private func synced(_ n: Int, etag: String? = nil) -> Result<Reply, GhError> {
  reply(200, Data(plist(n).utf8), etag: etag)
}

/// Answers checks in order and records each request.
private final class Feed: @unchecked Sendable {
  private let lock = NSLock()
  private var answers: [Result<Reply, GhError>]
  private(set) var requests: [URLRequest] = []

  init(_ answers: [Result<Reply, GhError>]) { self.answers = answers }

  func fetch(_ request: URLRequest) -> Result<Reply, GhError> {
    lock.withLock {
      requests.append(request)
      return answers.isEmpty ? .failure(.cancelled) : answers.removeFirst()
    }
  }
}

/// The plans an updater asked to run.
private final class Plans: @unchecked Sendable {
  private let lock = NSLock()
  private var _seen: [UpdatePlan] = []
  var seen: [UpdatePlan] { lock.withLock { _seen } }
  func add(_ plan: UpdatePlan) { lock.withLock { _seen.append(plan) } }
}

private func info(_ sync: Int?, kind: SourceKind? = .git, directory: String? = nil) -> BuildInfo {
  BuildInfo(sync: sync, kind: kind, directory: directory, repository: "o/r")
}

@MainActor
private func makeUpdater(
  _ feed: Feed = Feed([]), build: BuildInfo = info(10),
  perform: @escaping @Sendable (UpdatePlan) async -> Result<URL, UpdateFailure> = { _ in
    .failure(UpdateFailure("unused"))
  }
) -> Updater {
  Updater(build: build, fetch: { feed.fetch($0) }, perform: perform)
}

/// A directory with an executable `script/build`.
private func source(_ name: String) throws -> URL {
  let dir = scratch(name).appendingPathComponent("gh-inbox-main")
  try FileManager.default.createDirectory(
    at: dir.appendingPathComponent("script"), withIntermediateDirectories: true)
  executable(dir.appendingPathComponent("script/build"), "#!/bin/sh\n")
  return dir
}

private let identity = ["-c", "user.name=t", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false"]

private func git(_ args: [String], in place: URL) throws {
  let out = try capture("git", ["-C", place.path] + identity + args, timeout: .seconds(30))
  if !out.success { throw UpdateFailure(String(decoding: out.stderr, as: UTF8.self)) }
}

/// Stands for the public repository: a local repository on main whose
/// `script/build` makes an app and prints its path, cloned once, then moved
/// on by a commit. github.com's o/r is rewritten to it, so a clone or a fork
/// fetches from it under its public URL.
private func checkout(
  _ name: String, origin remote: String = "https://github.com/o/r.git", build: String? = nil
)
  throws -> URL
{
  let dir = scratch(name)
  let upstream = dir.appendingPathComponent("upstream")
  let clone = dir.appendingPathComponent("clone")
  try FileManager.default.createDirectory(
    at: upstream.appendingPathComponent("script"), withIntermediateDirectories: true)
  try git(["init", "-q", "-b", "main"], in: upstream)
  executable(
    upstream.appendingPathComponent("script/build"),
    build
      ?? "#!/usr/bin/env bash\nset -e\ncd \"$(dirname \"$0\")/..\"\nmkdir -p dist/GhInbox.app\necho building\n"
      + "echo \"$PWD/dist/GhInbox.app\"\n")
  try "one\n".write(to: upstream.appendingPathComponent("file"), atomically: true, encoding: .utf8)
  try git(["add", "."], in: upstream)
  try git(["commit", "-q", "-m", "one"], in: upstream)
  let out = try capture("git", ["clone", "-q", upstream.path, clone.path], timeout: .seconds(30))
  #expect(out.success)
  try git(["remote", "set-url", "origin", remote], in: clone)
  try git(["config", "url.\(upstream.path).insteadOf", "https://github.com/o/r.git"], in: clone)
  try "two\n".write(to: upstream.appendingPathComponent("file"), atomically: true, encoding: .utf8)
  try git(["commit", "-q", "-am", "two"], in: upstream)
  return clone
}

private func contents(_ dir: URL, _ file: String) throws -> String {
  try String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8)
}

private func status(
  _ freshness: Freshness, kind: SourceKind = .git, updating: Bool = false, failure: String? = nil,
  directory: String? = nil
) -> UpdateStatus {
  UpdateStatus(
    freshness: freshness, kind: kind, repository: "o/r", updating: updating, failure: failure,
    directory: directory)
}

@Suite struct UpdateTests {
  @Test func readsTheSyncNumber() {
    #expect(syncNumber("12") == 12)
    // A template that carries 0, and anything that isn't a number.
    for none in ["0", "-3", "", "1.2", "x"] { #expect(syncNumber(none) == nil, "\(none)") }
    #expect(syncNumber(plist: Data(plist(13).utf8)) == 13)
    #expect(syncNumber(plist: Data(plist(0).utf8)) == nil)
    #expect(syncNumber(plist: Data("not a plist".utf8)) == nil)
  }

  @Test func readsWhatTheBuildRecorded() {
    let recorded: [String: Any] = [
      "CFBundleVersion": "7", "SourceKind": "copy", "SourceDirectory": "/src", "UpdateRepository": "o/r",
    ]
    #expect(
      BuildInfo(info: recorded) == BuildInfo(sync: 7, kind: .copy, directory: "/src", repository: "o/r"))
    #expect(BuildInfo(info: recorded).checks)
  }

  @MainActor @Test func onlyACopyOfThePublicRepositoryChecks() {
    func live(_ extra: [String: Any]) -> Updater? {
      Updater.live(
        info: ["CFBundleVersion": "7", "SourceKind": "git", "UpdateRepository": "o/r"].merging(extra) {
          $1
        })
    }
    #expect(live([:]) != nil)
    // A build that carries 0, an older build with no kind, a bad repository.
    #expect(live(["CFBundleVersion": "0"]) == nil)
    #expect(live(["SourceKind": "zip"]) == nil)
    #expect(live(["UpdateRepository": "not a repo"]) == nil)
    #expect(Updater.live(info: nil) == nil)
  }

  @Test func asksOnlyForAPlainRepository() {
    #expect(
      plistURL("o/gh-inbox")?.absoluteString
        == "https://raw.githubusercontent.com/o/gh-inbox/main/Resources/Info.plist")
    #expect(
      zipURL("o/gh-inbox")?.absoluteString == "https://codeload.github.com/o/gh-inbox/zip/refs/heads/main")
    for bad in ["", "someone", "a/b/c", "/b", "a/", "a b/c", "a/b?x=1", "a/b#c"] {
      #expect(plistURL(bad) == nil, "\(bad)")
      #expect(zipURL(bad) == nil, "\(bad)")
    }
  }

  @Test func readsGitHubRemotesOnly() {
    for remote in [
      "git@github.com:o/r.git", "https://github.com/o/r", "https://github.com/o/r.git/",
      "ssh://git@github.com/o/r.git", "https://user:token@github.com/o/r.git", "HTTPS://GitHub.com/o/r\n",
    ] {
      #expect(githubRepository(remote: remote) == "o/r", "\(remote)")
    }
    for remote in [
      "https://gitlab.com/o/r", "/local/path", "http://127.0.0.1/git/o/r", "https://github.com/o", "",
    ] {
      #expect(githubRepository(remote: remote) == nil, "\(remote)")
    }
  }

  @Test func countsTheSyncsSinceTheBuild() {
    #expect(freshness(mine: 10, latest: 10) == .current)
    #expect(freshness(mine: 10, latest: 13) == .behind(3))
    // A fork that numbered itself past the public repository.
    #expect(freshness(mine: 20, latest: 13) == .current)
  }

  @MainActor @Test func findsANewerSyncAndAsksConditionallyAfterward() async {
    let feed = Feed([synced(13, etag: "\"e1\""), reply(304)])
    let updater = makeUpdater(feed)
    var changes = 0
    updater.changed = { changes += 1 }
    let start = Instant.now
    await updater.checkIfDue(now: start)?.value
    #expect(updater.freshness == .behind(3))
    #expect(changes == 1)
    #expect(
      feed.requests.first?.url?.absoluteString
        == "https://raw.githubusercontent.com/o/r/main/Resources/Info.plist")
    #expect(feed.requests.first?.value(forHTTPHeaderField: "If-None-Match") == nil)
    #expect(feed.requests.first?.value(forHTTPHeaderField: "Authorization") == nil)

    // Not again within the hour.
    #expect(updater.checkIfDue(now: start + .seconds(60)) == nil)
    // A 304 keeps what was known.
    await updater.checkIfDue(now: start + Updater.interval)?.value
    #expect(feed.requests.count == 2)
    #expect(feed.requests.last?.value(forHTTPHeaderField: "If-None-Match") == "\"e1\"")
    #expect(updater.freshness == .behind(3))
    #expect(changes == 1)
  }

  @MainActor @Test func aFailedCheckKeepsWhatWasKnown() async {
    let feed = Feed([
      synced(10, etag: "\"e1\""), reply(429, Data("{\"message\":\"slow down\"}".utf8)),
      .failure(.network("offline")), reply(200, Data("<html>".utf8)),
    ])
    let updater = makeUpdater(feed)
    let start = Instant.now
    for hour in 0..<4 {
      await updater.checkIfDue(now: start + Updater.interval * hour)?.value
      #expect(updater.freshness == .current)
    }
    #expect(feed.requests.count == 4)
  }

  @MainActor @Test func bannersSayWhatAClickDoes() {
    #expect(updateBanners(nil).isEmpty)
    #expect(updateBanners(status(.current)).isEmpty)
    #expect(updateBanners(status(.unknown)).isEmpty)
    #expect(
      updateBanners(status(.behind(1), directory: "/src")) == [
        Notice(
          text: "gh-inbox is 1 update behind. Click to pull the latest, rebuild and reopen.", tone: .info,
          click: .update)
      ])
    #expect(
      updateBanners(status(.behind(3), kind: .copy, directory: "/src")).map(\.text) == [
        "gh-inbox is 3 updates behind. Click to download the latest, rebuild and reopen."
      ])
    // No source to rebuild: the steps by hand, and a click copies them.
    #expect(
      updateBanners(status(.behind(2))) == [
        Notice(
          text: "gh-inbox is 2 updates behind: pull main, run script/build, then reopen gh-inbox.",
          tone: .info)
      ])
    #expect(
      updateBanners(status(.behind(2), kind: .copy)).map(\.text) == [
        "gh-inbox is 2 updates behind: download the latest from github.com/o/r, run script/build, then reopen gh-inbox."
      ])
    #expect(
      updateBanners(status(.behind(2), updating: true, directory: "/src")) == [
        Notice(
          text: "Updating gh-inbox: pulling the latest and rebuilding in /src…", tone: .info, click: .inert)
      ])
    #expect(
      updateBanners(status(.behind(2), kind: .copy, updating: true, directory: "/a/src"))
        .map(
          \.text) == ["Updating gh-inbox: downloading the latest and rebuilding beside /a/src…"])
    #expect(
      updateBanners(status(.behind(2), failure: "why", directory: "/src")).map(\.text) == [
        "gh-inbox is 2 updates behind. Click to pull the latest, rebuild and reopen.",
        "Couldn't update gh-inbox: why",
      ])
  }

  @Test func theConfirmationSaysWhatChanges() {
    #expect(updateConfirmation(status(.behind(1))) == nil)
    #expect(
      updateConfirmation(status(.behind(1), directory: "/src"))?.contains("main in /src")
        == true)
    let copy = updateConfirmation(
      status(.behind(1), kind: .copy, directory: "/a/gh-inbox-main"))
    #expect(copy?.contains("a new folder in /a, leaving /a/gh-inbox-main as it is") == true)
  }

  @MainActor @Test func anUpdateRunsThePlanForTheSourceAndTheLatestSync() async throws {
    let dir = try source("plan")
    let built = URL(fileURLWithPath: "/built/GhInbox.app")
    let plans = Plans()
    let updater = makeUpdater(Feed([synced(13)]), build: info(10, kind: .copy, directory: dir.path)) {
      plans.add($0)
      return .success(built)
    }
    #expect(updater.status.directory == dir.path)
    await updater.checkIfDue()?.value
    #expect(await updater.update(replacing: nil) == built)
    #expect(plans.seen == [UpdatePlan(kind: .copy, directory: dir.path, repository: "o/r", latest: 13)])
    // Still updating: the app is about to reopen.
    #expect(updater.status.updating)
  }

  @MainActor @Test func aSourceWithoutABuildScriptUpdatesByHand() async {
    let updater = makeUpdater(build: info(10, directory: "/nowhere"))
    #expect(updater.status.directory == nil)
    #expect(await updater.update(replacing: nil) == nil)
  }

  @MainActor @Test func aFailedUpdateSaysWhyAndCanBeTriedAgain() async throws {
    let dir = try source("fails")
    let updater = makeUpdater(build: info(10, directory: dir.path)) { _ in
      .failure(UpdateFailure("`script/build` failed"))
    }
    #expect(await updater.update(replacing: nil) == nil)
    #expect(updater.status.failure == "`script/build` failed")
    #expect(!updater.status.updating)
  }

  @MainActor @Test func aBuildThatCannotReopenOffersTheUpdateAgain() async throws {
    let dir = try source("reopen")
    let built = URL(fileURLWithPath: "/built/GhInbox.app")
    let updater = makeUpdater(build: info(10, directory: dir.path)) { _ in .success(built) }
    #expect(await updater.update(replacing: nil) == built)
    updater.reopenFailed("no shell")
    #expect(!updater.status.updating)
    #expect(updater.status.failure == "no shell")
  }

  @Test func aCloneMovesForwardFromOrigin() throws {
    let clone = try checkout("clone")
    let app = try pullAndBuild(clone.path, repository: "o/r", env: []).get()
    #expect(app.path.hasSuffix("/dist/GhInbox.app"))
    #expect(FileManager.default.fileExists(atPath: app.path))
    #expect(try contents(clone, "file") == "two\n")
  }

  @Test func aForkMovesForwardFromThePublicRepository() throws {
    let fork = try checkout("fork", origin: "git@github.com:someone/r.git")
    _ = try pullAndBuild(fork.path, repository: "o/r", env: []).get()
    #expect(try contents(fork, "file") == "two\n")
  }

  @Test func aMainWithItsOwnCommitsIsLeftWithTheCommands() throws {
    let fork = try checkout("diverged", origin: "git@github.com:someone/r.git")
    try "mine\n".write(to: fork.appendingPathComponent("other"), atomically: true, encoding: .utf8)
    try git(["add", "other"], in: fork)
    try git(["commit", "-q", "-m", "mine"], in: fork)
    guard case .failure(let failure) = pullAndBuild(fork.path, repository: "o/r", env: []) else {
      Issue.record("moved a diverged main")
      return
    }
    #expect(failure.text.contains("git fetch https://github.com/o/r.git main && git merge FETCH_HEAD"))
    #expect(try contents(fork, "file") == "one\n")
  }

  @Test func neverMovesAnotherBranch() throws {
    let clone = try checkout("branch")
    try git(["switch", "-q", "-c", "feature"], in: clone)
    guard case .failure(let failure) = pullAndBuild(clone.path, repository: "o/r", env: []) else {
      Issue.record("pulled into a branch")
      return
    }
    #expect(failure.text.contains("is on feature, not main"))
    #expect(try contents(clone, "file") == "one\n")
  }

  @Test func aFailedBuildShowsWhatItPrinted() throws {
    let clone = try checkout(
      "build-fails", build: "#!/usr/bin/env bash\necho compiling\necho 'error: no such module' >&2\nexit 1\n")
    guard case .failure(let failure) = pullAndBuild(clone.path, repository: "o/r", env: []) else {
      Issue.record("a failed build succeeded")
      return
    }
    #expect(failure.text.hasPrefix("`script/build` failed in \(clone.path) (exit 1)"))
    #expect(failure.text.contains("error: no such module"))
    #expect(failure.text.contains("compiling"))
  }

  @Test func aBuildThatNamesNoAppFails() throws {
    let clone = try checkout("build-silent", build: "#!/usr/bin/env bash\necho done\n")
    guard case .failure(let failure) = pullAndBuild(clone.path, repository: "o/r", env: []) else {
      Issue.record("succeeded without an app")
      return
    }
    #expect(failure.text.contains("didn't name the app it built"))
  }

  /// Unpacks as GitHub's zip would: one `gh-inbox-main` folder.
  private func fakeUnzip(sync: Int?) -> (String, String) -> Result<Void, UpdateFailure> {
    { archive, directory in
      let top = URL(fileURLWithPath: directory).appendingPathComponent("gh-inbox-main")
      try! FileManager.default.createDirectory(
        at: top.appendingPathComponent("Resources"), withIntermediateDirectories: true)
      try! FileManager.default.createDirectory(
        at: top.appendingPathComponent("script"), withIntermediateDirectories: true)
      if let sync {
        try! plist(sync).write(
          to: top.appendingPathComponent("Resources/Info.plist"), atomically: true, encoding: .utf8)
      }
      executable(
        top.appendingPathComponent("script/build"),
        "#!/bin/sh\nset -e\ncd \"$(dirname \"$0\")/..\"\nmkdir -p dist/GhInbox.app\necho \"$PWD/dist/GhInbox.app\"\n"
      )
      #expect(FileManager.default.fileExists(atPath: archive))
      return .success(())
    }
  }

  @Test func aDownloadBuildsInANewFolderBesideTheOldCopy() throws {
    let old = try source("download")
    let parent = old.deletingLastPathComponent()
    let app = try downloadAndBuild(
      Data("zip".utf8), beside: old.path, atLeast: 13, env: [], unpack: fakeUnzip(sync: 13)
    ).get()
    #expect(app.path == parent.appendingPathComponent("gh-inbox-13/dist/GhInbox.app").path)
    #expect(FileManager.default.fileExists(atPath: app.path))
    // The old copy stays, and nothing staged is left.
    #expect(FileManager.default.fileExists(atPath: old.appendingPathComponent("script/build").path))
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: parent.path).sorted() == [
        "gh-inbox-13", "gh-inbox-main",
      ])

    // A folder already by that name is never touched.
    let again = try downloadAndBuild(
      Data("zip".utf8), beside: old.path, atLeast: 13, env: [], unpack: fakeUnzip(sync: 13)
    ).get()
    #expect(again.path == parent.appendingPathComponent("gh-inbox-13-2/dist/GhInbox.app").path)
  }

  @Test func aDownloadOlderThanTheCheckOrWithoutANumberFails() throws {
    let old = try source("stale")
    guard
      case .failure(let stale) = downloadAndBuild(
        Data(), beside: old.path, atLeast: 13, env: [], unpack: fakeUnzip(sync: 12))
    else {
      Issue.record("built an older download")
      return
    }
    #expect(stale.text.contains("sync 12, older than sync 13"))
    guard
      case .failure(let unnumbered) = downloadAndBuild(
        Data(), beside: old.path, atLeast: 13, env: [], unpack: fakeUnzip(sync: nil))
    else {
      Issue.record("built a download without a number")
      return
    }
    #expect(unnumbered.text.contains("no sync number"))
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: old.deletingLastPathComponent().path) == [
        "gh-inbox-main"
      ])
  }

  @Test func installsOverTheRunningAppUnlessItIsTheBuild() throws {
    let dir = scratch("install")
    let source = dir.appendingPathComponent("gh-inbox-main").path
    let built = dir.appendingPathComponent("gh-inbox-3/dist/GhInbox.app")
    let running = dir.appendingPathComponent("Applications/GhInbox.app")
    let old = dir.appendingPathComponent("gh-inbox-main/dist/GhInbox.app")
    for (app, text) in [(built, "new"), (running, "old"), (old, "old")] {
      try FileManager.default.createDirectory(
        at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
      try text.write(to: app.appendingPathComponent("Contents/marker"), atomically: true, encoding: .utf8)
    }
    #expect(try install(built, over: built, source: source) == built)
    // The old copy's own build is left alone; the new one reopens where it is.
    #expect(try install(built, over: old, source: source) == built)
    #expect(try contents(old, "Contents/marker") == "old")
    #expect(try install(built, over: running, source: source) == running)
    #expect(try contents(running, "Contents/marker") == "new")
    // Nothing staged is left behind, and the build stays where it was.
    let left = try FileManager.default.contentsOfDirectory(atPath: running.deletingLastPathComponent().path)
    #expect(left == ["GhInbox.app"])
    #expect(FileManager.default.fileExists(atPath: built.appendingPathComponent("Contents/marker").path))
  }
}
