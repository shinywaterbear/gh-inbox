// Whether the public repository has synced since the source this app was
// built from, and the update a click on its banner runs: bring the source up
// to date (a pull, or a new download), rebuild, reopen.

import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// How the source was got, which decides how an update brings it forward.
public enum SourceKind: String, Sendable, Equatable {
  /// A git checkout: a clone of the public repository or a fork of it.
  case git
  /// A downloaded copy without `.git`, such as GitHub's zip of main.
  case copy
}

/// What `script/build` and the public repository's sync record in the
/// bundle. Only a build whose source carries a sync number checks; a
/// template that carries 0 never does.
public struct BuildInfo: Sendable, Equatable {
  /// The public repository's sync the source contains (`CFBundleVersion`).
  public var sync: Int?
  public var kind: SourceKind?
  /// The checkout or copy it was built in.
  public var directory: String?
  /// `owner/name` on github.com whose main branch publishes the app.
  public var repository: String?

  public init(sync: Int?, kind: SourceKind?, directory: String?, repository: String?) {
    self.sync = sync
    self.kind = kind
    self.directory = directory
    self.repository = repository
  }

  public init(info: [String: Any]) {
    self.init(
      sync: (info["CFBundleVersion"] as? String).flatMap(syncNumber),
      kind: (info["SourceKind"] as? String).flatMap(SourceKind.init(rawValue:)),
      directory: info["SourceDirectory"] as? String, repository: info["UpdateRepository"] as? String)
  }

  /// Whether this build checks at all.
  var checks: Bool {
    sync != nil && kind != nil && repository.map(isRepository) == true
  }
}

/// A positive sync number; 0, or anything else, is none.
func syncNumber(_ text: String) -> Int? {
  Int(text.trimmingCharacters(in: .whitespaces)).flatMap { $0 > 0 ? $0 : nil }
}

/// A plain `owner/name`, safe to put in a URL.
func isRepository(_ repository: String) -> Bool {
  let parts = repository.split(separator: "/", omittingEmptySubsequences: false)
  let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
  return parts.count == 2 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(allowed.contains) }
}

/// The template on the repository's main, whose `CFBundleVersion` is the
/// latest sync. A raw file: about a kilobyte, outside the API's rate limit.
func plistURL(_ repository: String) -> URL? {
  isRepository(repository)
    ? URL(string: "https://raw.githubusercontent.com/\(repository)/main/Resources/Info.plist") : nil
}

/// GitHub's zip of main, served directly rather than through a redirect.
func zipURL(_ repository: String) -> URL? {
  isRepository(repository)
    ? URL(string: "https://codeload.github.com/\(repository)/zip/refs/heads/main") : nil
}

/// The sync number in a plist's `CFBundleVersion`.
func syncNumber(plist data: Data) -> Int? {
  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
  return (plist?["CFBundleVersion"] as? String).flatMap(syncNumber)
}

/// `owner/name` of a github.com remote URL in any of git's spellings, or nil
/// for any other host.
func githubRepository(remote: String) -> String? {
  var rest = remote.trimmingCharacters(in: .whitespacesAndNewlines)
  let prefixes = ["git@github.com:", "ssh://git@github.com/", "https://github.com/", "http://github.com/"]
  if let prefix = prefixes.first(where: { rest.lowercased().hasPrefix($0) }) {
    rest = String(rest.dropFirst(prefix.count))
  } else if rest.lowercased().hasPrefix("https://"), let at = rest.firstIndex(of: "@"),
    rest[rest.index(after: at)...].lowercased().hasPrefix("github.com/")
  {
    // A user or token before the host.
    rest = String(rest[rest.index(at, offsetBy: "@github.com/".count)...])
  } else {
    return nil
  }
  if rest.hasSuffix("/") { rest.removeLast() }
  if rest.hasSuffix(".git") { rest.removeLast(4) }
  return isRepository(rest) ? rest : nil
}

/// Where this build stands against the published source.
public enum Freshness: Sendable, Equatable {
  /// Not checked yet, or the check failed: no banner.
  case unknown
  case current
  /// This many syncs have landed since the build's.
  case behind(Int)
}

/// A build ahead of the latest sync (a fork's own number) is no news.
func freshness(mine: Int, latest: Int) -> Freshness {
  latest > mine ? .behind(latest - mine) : .current
}

/// Why an update stopped, in full: the step and what it printed.
public struct UpdateFailure: Error, Sendable, Equatable {
  public var text: String

  public init(_ text: String) { self.text = text }
}

/// What an update is asked to do.
public struct UpdatePlan: Sendable, Equatable {
  public var kind: SourceKind
  public var directory: String
  public var repository: String
  /// The sync the check found, which a download must reach.
  public var latest: Int
}

/// What the update banner shows, as a value.
public struct UpdateStatus: Sendable, Equatable {
  public var freshness: Freshness
  public var kind: SourceKind
  public var repository: String
  public var updating: Bool
  public var failure: String?
  /// The source it was built from, when it still has `script/build`; nil
  /// leaves the update to be done by hand.
  public var directory: String?

  public init(
    freshness: Freshness, kind: SourceKind, repository: String, updating: Bool = false,
    failure: String? = nil, directory: String? = nil
  ) {
    self.freshness = freshness
    self.kind = kind
    self.repository = repository
    self.updating = updating
    self.failure = failure
    self.directory = directory
  }
}

/// Checks the published source now and then, and runs the update when asked.
@MainActor
public final class Updater {
  /// A check that finds nothing new costs next to nothing: the answer to a
  /// conditional request whose ETag still matches is an empty 304.
  public static let interval = Duration.seconds(60 * 60)

  public let build: BuildInfo
  public private(set) var freshness = Freshness.unknown
  public private(set) var updating = false
  /// Why the last update failed, in full.
  public private(set) var failure: String?
  /// Called after every change worth drawing.
  public var changed: @MainActor () -> Void = {}

  private let fetch: @Sendable (URLRequest) async -> Result<Reply, GhError>
  private let perform: @Sendable (UpdatePlan) async -> Result<URL, UpdateFailure>
  private var latest: Int?
  private var etag: String?
  private var lastCheck: Instant?
  private var checking = false

  /// `session` answers the checks and downloads; `perform` runs an update
  /// and returns the app it built, the real steps unless given.
  public convenience init(
    build: BuildInfo, session: URLSession = GitHub.session(timeout: .seconds(300)),
    perform: (@Sendable (UpdatePlan) async -> Result<URL, UpdateFailure>)? = nil
  ) {
    let check = GitHub(session: session, timeout: .seconds(30)) { .failure(.cancelled) }
    let download = GitHub(session: session, timeout: .seconds(300)) { .failure(.cancelled) }
    self.init(
      build: build, fetch: { await check.send($0) },
      perform: perform ?? { await GhInboxCore.perform($0, download: download) })
  }

  init(
    build: BuildInfo, fetch: @escaping @Sendable (URLRequest) async -> Result<Reply, GhError>,
    perform: @escaping @Sendable (UpdatePlan) async -> Result<URL, UpdateFailure>
  ) {
    self.build = build
    self.fetch = fetch
    self.perform = perform
  }

  /// The running app's updater, or nil when its bundle carries no sync
  /// number to compare.
  public static func live(info: [String: Any]? = Bundle.main.infoDictionary) -> Updater? {
    let build = BuildInfo(info: info ?? [:])
    return build.checks ? Updater(build: build) : nil
  }

  public var status: UpdateStatus {
    let directory = build.directory.flatMap { isExecutableFile($0 + "/script/build") ? $0 : nil }
    return UpdateStatus(
      freshness: freshness, kind: build.kind ?? .git, repository: build.repository ?? "",
      updating: updating, failure: failure, directory: build.checks ? directory : nil)
  }

  /// Checks when none has run for `interval`. One at a time, and none
  /// while an update runs. Returns the check started, if any.
  @discardableResult
  public func checkIfDue(now: Instant = .now) -> Task<Void, Never>? {
    guard !checking, !updating, lastCheck.map({ now - $0 >= Self.interval }) ?? true,
      build.checks, let mine = build.sync, let url = build.repository.flatMap(plistURL)
    else { return nil }
    lastCheck = now
    checking = true
    var request = URLRequest(url: url)
    request.setValue("gh-inbox", forHTTPHeaderField: "User-Agent")
    request.cachePolicy = .reloadIgnoringLocalCacheData
    if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
    return Task {
      let result = await fetch(request)
      self.checked(result, mine: mine)
    }
  }

  /// Anything but a readable number (a 304, a rate limit, no network)
  /// keeps what was last known.
  private func checked(_ result: Result<Reply, GhError>, mine: Int) {
    checking = false
    guard case .success(let reply) = result, reply.success, let number = syncNumber(plist: reply.body) else {
      return
    }
    etag = reply.etag
    latest = number
    let next = GhInboxCore.freshness(mine: mine, latest: number)
    if next != freshness {
      freshness = next
      changed()
    }
  }

  /// Brings the source forward, builds it, and puts the new app where
  /// `running` is. Returns the app to reopen, or nil after a failure, which
  /// `failure` then describes. Stays `updating` on success, since the app
  /// is about to quit.
  public func update(replacing running: URL?) async -> URL? {
    let status = status
    guard !updating, let directory = status.directory, let kind = build.kind,
      let repository = build.repository
    else { return nil }
    updating = true
    failure = nil
    changed()
    let plan = UpdatePlan(
      kind: kind, directory: directory, repository: repository, latest: latest ?? build.sync ?? 0)
    let result = await perform(plan).flatMap { built in
      guard let running else { return .success(built) }
      return Result { try install(built, over: running, source: directory) }.mapError {
        UpdateFailure("couldn't replace \(running.path): \($0.localizedDescription)")
      }
    }
    switch result {
    case .success(let app):
      return app
    case .failure(let error):
      updating = false
      failure = error.text
      changed()
      return nil
    }
  }

  /// The new app is in place but couldn't be opened: says so, and lets the
  /// banner offer the update again.
  public func reopenFailed(_ why: String) {
    updating = false
    failure = why
    changed()
  }
}

/// The real update: a pull for a checkout, a new download beside a copy.
/// The blocking steps run off the caller's thread.
func perform(_ plan: UpdatePlan, download: GitHub) async -> Result<URL, UpdateFailure> {
  switch plan.kind {
  case .git:
    return await offMain {
      pullAndBuild(plan.directory, repository: plan.repository, env: LoginEnvironment.forBuild())
    }
  case .copy:
    guard let url = zipURL(plan.repository) else {
      return .failure(UpdateFailure("no repository to download"))
    }
    var request = URLRequest(url: url)
    request.setValue("gh-inbox", forHTTPHeaderField: "User-Agent")
    let zip: Data
    switch await download.send(request) {
    case .success(let reply) where reply.success: zip = reply.body
    case .success(let reply): return .failure(UpdateFailure("couldn't download \(url): \(reply.failure)"))
    case .failure(let error): return .failure(UpdateFailure("couldn't download \(url): \(error)"))
    }
    return await offMain {
      downloadAndBuild(zip, beside: plan.directory, atLeast: plan.latest, env: LoginEnvironment.forBuild())
    }
  }
}

private func offMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
  await withCheckedContinuation { continuation in
    DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: work()) }
  }
}

/// Copies the app built at `built` over `running` and returns where the new
/// app now is. An app inside `source`, the source it was built from, stays
/// with that source: the new build is reopened where it is, so deleting an
/// old downloaded copy never takes the running app with it. The copy is
/// staged beside it and swapped in, so a failure leaves the old app whole.
func install(_ built: URL, over running: URL, source: String) throws -> URL {
  let files = FileManager.default
  func resolved(_ url: URL) -> String { url.resolvingSymlinksInPath().standardizedFileURL.path }
  if resolved(built) == resolved(running)
    || resolved(running).hasPrefix(resolved(URL(fileURLWithPath: source)) + "/")
  {
    return built
  }
  let staging = running.deletingLastPathComponent().appendingPathComponent(
    ".\(running.lastPathComponent).update")
  try? files.removeItem(at: staging)
  try files.copyItem(at: built, to: staging)
  do {
    _ = try files.replaceItemAt(running, withItemAt: staging)
  } catch {
    try? files.removeItem(at: staging)
    throw error
  }
  return running
}

/// Runs one step of an update in `directory` and returns what it printed,
/// or the step, its status and the tail of its output.
private func step(
  _ program: String, _ args: [String], shown: String, in directory: String, env: [EnvVar], timeout: Duration
) -> Result<String, UpdateFailure> {
  let output: Output
  do {
    output = try capture(program, args, overlay: env, timeout: timeout)
  } catch {
    return .failure(UpdateFailure("`\(shown)` in \(directory): \(error)"))
  }
  let stdout = String(decoding: output.stdout, as: UTF8.self)
  guard output.success else {
    let said = tail(String(decoding: output.stderr, as: UTF8.self) + "\n" + stdout)
    let status = output.status.map { "exit \($0)" } ?? "stopped by a signal"
    return .failure(
      UpdateFailure("`\(shown)` failed in \(directory) (\(status))" + (said.isEmpty ? "" : ": \(said)")))
  }
  return .success(stdout)
}

/// The source's own `script/build`, whose last line names the app it built.
private func build(_ directory: String, env: [EnvVar], timeout: Duration) -> Result<URL, UpdateFailure> {
  step(directory + "/script/build", [], shown: "script/build", in: directory, env: env, timeout: timeout)
    .flatMap { stdout in
      let last = stdout.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
      guard last.hasSuffix(".app"), FileManager.default.fileExists(atPath: last) else {
        return .failure(UpdateFailure("`script/build` in \(directory) didn't name the app it built"))
      }
      return .success(URL(fileURLWithPath: last))
    }
}

/// The update by hand, for a checkout on main: fetch the public
/// repository's main (from `origin` when that is it, else from its URL, as
/// for a fork), move forward to it only by fast-forward, then build. A main
/// with commits of its own is left alone, with the commands to merge.
/// `env` is set over the inherited environment, so a Finder launch finds the
/// toolchain the login shell would.
func pullAndBuild(
  _ directory: String, repository: String, env: [EnvVar], gitTimeout: Duration = .seconds(120),
  buildTimeout: Duration = .seconds(30 * 60)
) -> Result<URL, UpdateFailure> {
  // Never wait on a password prompt nobody can see.
  let env = env + [EnvVar(Array("GIT_TERMINAL_PROMPT".utf8), Array("0".utf8))]
  func git(_ args: [String], _ shown: String) -> Result<String, UpdateFailure> {
    step("git", ["-C", directory] + args, shown: shown, in: directory, env: env, timeout: gitTimeout)
  }

  let branch =
    (try? git(["symbolic-ref", "--quiet", "--short", "HEAD"], "git symbolic-ref HEAD").get())?
    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  guard branch == "main" else {
    // A detached HEAD fails above, and is no branch to move forward.
    let on = branch.isEmpty ? "a detached HEAD" : branch
    return .failure(UpdateFailure("the checkout in \(directory) is on \(on), not main; update it by hand"))
  }
  let url = "https://github.com/\(repository).git"
  let origin = (try? git(["config", "--get", "remote.origin.url"], "git config remote.origin.url").get())
    .flatMap(githubRepository(remote:))
  let remote = origin?.lowercased() == repository.lowercased() ? "origin" : url
  if case .failure(let error) = git(["fetch", "--quiet", remote, "main"], "git fetch \(remote) main") {
    return .failure(error)
  }
  let ahead: Output
  do {
    ahead = try capture(
      "git", ["-C", directory, "merge-base", "--is-ancestor", "HEAD", "FETCH_HEAD"], overlay: env,
      timeout: gitTimeout)
  } catch {
    return .failure(UpdateFailure("`git merge-base` in \(directory): \(error)"))
  }
  guard ahead.success else {
    return .failure(
      UpdateFailure(
        "main in \(directory) has commits of its own, so it can't just move forward. Merge by hand: "
          + "git fetch \(url) main && git merge FETCH_HEAD && script/build"))
  }
  if case .failure(let error) = git(["merge", "--ff-only", "--quiet", "FETCH_HEAD"], "git merge --ff-only") {
    return .failure(error)
  }
  return build(directory, env: env, timeout: buildTimeout)
}

/// Unpacks GitHub's zip of main into a new folder beside the copy at
/// `directory`, named for its sync (`gh-inbox-<n>`), and builds it there.
/// The old copy is left as it is. A download older than `latest` (a cache
/// not yet caught up) fails rather than going back.
func downloadAndBuild(
  _ zip: Data, beside directory: String, atLeast latest: Int, env: [EnvVar],
  unpack: (String, String) -> Result<Void, UpdateFailure> = unzip,
  buildTimeout: Duration = .seconds(30 * 60)
) -> Result<URL, UpdateFailure> {
  let files = FileManager.default
  let parent = URL(fileURLWithPath: directory).deletingLastPathComponent()
  let staging = parent.appendingPathComponent(".gh-inbox-download-\(UUID().uuidString)")
  defer { try? files.removeItem(at: staging) }
  let archive = staging.appendingPathComponent("main.zip")
  let unpacked = staging.appendingPathComponent("unpacked")
  do {
    try files.createDirectory(at: unpacked, withIntermediateDirectories: true)
    try zip.write(to: archive)
  } catch {
    return .failure(
      UpdateFailure("couldn't save the download beside \(directory): \(error.localizedDescription)"))
  }
  if case .failure(let error) = unpack(archive.path, unpacked.path) { return .failure(error) }
  // GitHub's zip holds one folder, `<name>-main`.
  let entries = (try? files.contentsOfDirectory(atPath: unpacked.path)) ?? []
  guard entries.count == 1 else {
    return .failure(UpdateFailure("the download didn't hold a single folder"))
  }
  let top = unpacked.appendingPathComponent(entries[0])
  let plist = files.contents(atPath: top.appendingPathComponent("Resources/Info.plist").path)
  guard let number = plist.flatMap(syncNumber(plist:)) else {
    return .failure(UpdateFailure("the download has no sync number"))
  }
  guard number >= latest else {
    return .failure(
      UpdateFailure("the download is sync \(number), older than sync \(latest); try again shortly"))
  }
  var destination = parent.appendingPathComponent("gh-inbox-\(number)")
  var suffix = 2
  while files.fileExists(atPath: destination.path) {
    destination = parent.appendingPathComponent("gh-inbox-\(number)-\(suffix)")
    suffix += 1
  }
  do {
    try files.moveItem(at: top, to: destination)
  } catch {
    return .failure(UpdateFailure("couldn't make \(destination.path): \(error.localizedDescription)"))
  }
  return build(destination.path, env: env, timeout: buildTimeout)
}

/// macOS's `ditto`, which keeps the scripts' executable bits as Finder
/// does; `unzip` elsewhere.
func unzip(_ archive: String, into directory: String) -> Result<Void, UpdateFailure> {
  let ditto = "/usr/bin/ditto"
  let (program, args) =
    isExecutableFile(ditto)
    ? (ditto, ["-x", "-k", archive, directory]) : ("unzip", ["-q", archive, "-d", directory])
  return step(program, args, shown: "unzip", in: directory, env: [], timeout: .seconds(120)).map { _ in () }
}

/// The last lines a failed step printed: enough to see why.
func tail(_ text: String, lines: Int = 12) -> String {
  text.split(whereSeparator: \.isNewline).suffix(lines).joined(separator: "\n")
}
