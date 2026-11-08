import Foundation

@testable import GhInboxCore

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

let recorded = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
  .deletingLastPathComponent().appendingPathComponent("mocks/graphql.json").path

func scratch(_ name: String) -> URL {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
    "gh-inbox-\(ProcessInfo.processInfo.processIdentifier)-\(name)-\(UUID().uuidString)")
  try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  return dir
}

func executable(_ path: URL, _ text: String) {
  try! text.write(to: path, atomically: true, encoding: .utf8)
  chmod(path.path, 0o755)
}

/// A fake gh running `body` as a bash script, with nothing set over the
/// inherited environment.
func fakeGh(_ name: String, _ body: String, in dir: URL? = nil, env: [EnvVar] = []) -> Gh {
  let path = (dir ?? scratch(name)).appendingPathComponent("gh")
  executable(path, "#!/usr/bin/env bash\n\(body)\n")
  return Gh(program: path.path, env: env, timeout: .seconds(10))
}

/// What a fake GitHub does with one request.
enum Answer: Sendable {
  case reply(status: Int, headers: [String: String], body: Data)
  case fail(URLError.Code)
  /// A 307 to `url`.
  case redirect(String)
  /// Never answers; the request ends only when it is cancelled or times out.
  case hang
  /// Answers whatever this returns, worked out off the protocol's thread:
  /// Linux starts protocols one at a time, so blocking there stalls the rest.
  case later(@Sendable () -> Answer)
  /// Answers whatever this returns after `delay`, holding no thread while
  /// it waits, so slow answers overlap however few cores there are.
  case after(Duration, @Sendable () -> Answer)

  static func json(_ json: JSON, status: Int = 200, headers: [String: String] = [:]) -> Answer {
    .reply(status: status, headers: headers, body: Data(json.text.utf8))
  }

  static func text(_ text: String, status: Int) -> Answer {
    .reply(status: status, headers: [:], body: Data(text.utf8))
  }
}

/// One request a fake GitHub received.
struct Received: Sendable {
  var url: String
  var method: String
  var authorization: String?
  var query: String
}

/// A fake GitHub behind `FakeProtocol`, found by the token its requests
/// carry, so tests running at once never share one.
final class FakeGitHub: @unchecked Sendable {
  let token = "test-token-\(UUID().uuidString)"
  let host: String
  private let lock = NSLock()
  private let answer: @Sendable (Received) -> Answer
  private var _received: [Received] = []
  private var _cancelled: [Received] = []

  init(host: String = "github.com", _ answer: @escaping @Sendable (Received) -> Answer) {
    self.host = host
    self.answer = answer
    FakeProtocol.register(self)
  }

  var credential: Credential { Credential(host: host, token: token) }
  var received: [Received] { lock.withLock { _received } }
  /// Requests that were stopped before they were answered.
  var cancelled: [Received] { lock.withLock { _cancelled } }

  func github(timeout: Duration = .seconds(10)) -> GitHub {
    let credential = credential
    return GitHub(
      session: GitHub.session(timeout: timeout, protocols: [FakeProtocol.self]), timeout: timeout
    ) { .success(credential) }
  }

  func receive(_ request: Received) -> Answer {
    lock.withLock { _received.append(request) }
    return answer(request)
  }

  func stopped(_ request: Received) {
    lock.withLock { _cancelled.append(request) }
  }

  func section(_ index: Int, size: Int = 25, directOnly: Bool = false) async -> SectionFetch {
    await github().section(index, size: size, directOnly: directOnly, as: credential)
  }

  func checks(_ ids: [String]) async -> ChecksFetch {
    await github().checks(ids, as: credential)
  }

  func membership() async -> MembershipFetch {
    await github().membership(as: credential)
  }
}

/// A fake GitHub answering every request with `json`.
func responding(_ json: JSON, status: Int = 200, headers: [String: String] = [:]) -> FakeGitHub {
  FakeGitHub { _ in .json(json, status: status, headers: headers) }
}

func answering(_ answer: Answer) -> FakeGitHub {
  FakeGitHub { _ in answer }
}

/// Answers requests from the fake GitHub their token names.
final class FakeProtocol: URLProtocol {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var servers: [String: FakeGitHub] = [:]
  private var pending: (FakeGitHub, Received)?
  /// Linux traps on an answer to a stopped request.
  private var stopped = false
  private let state = NSLock()

  static func register(_ server: FakeGitHub) {
    lock.withLock { servers["bearer \(server.token)"] = server }
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let auth = request.value(forHTTPHeaderField: "Authorization")
    guard let server = FakeProtocol.lock.withLock({ auth.flatMap { FakeProtocol.servers[$0] } }) else {
      client?.urlProtocol(self, didFailWithError: URLError(.userAuthenticationRequired))
      return
    }
    let body = request.httpBody ?? request.httpBodyStream.map(read) ?? Data()
    let query = (try? JSONDecoder().decode([String: String].self, from: body))?["query"] ?? ""
    let received = Received(
      url: request.url?.absoluteString ?? "", method: request.httpMethod ?? "", authorization: auth,
      query: query)
    deliver(server.receive(received), server, received)
  }

  private func deliver(_ answer: Answer, _ server: FakeGitHub, _ received: Received) {
    switch answer {
    case .reply(let status, let headers, let data):
      let response = HTTPURLResponse(
        url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    case .fail(let code):
      client?.urlProtocol(self, didFailWithError: URLError(code))
    case .redirect(let url):
      let response = HTTPURLResponse(
        url: request.url!, statusCode: 307, httpVersion: "HTTP/1.1", headerFields: ["Location": url])!
      var next = request
      next.url = URL(string: url)
      client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
    case .hang:
      state.withLock { pending = (server, received) }
    case .later(let answer):
      later(.zero, answer, server, received)
    case .after(let delay, let answer):
      later(delay, answer, server, received)
    }
  }

  private func later(
    _ delay: Duration, _ answer: @escaping @Sendable () -> Answer, _ server: FakeGitHub, _ received: Received
  ) {
    state.withLock { pending = (server, received) }
    let me = Unchecked(self)
    DispatchQueue.global().asyncAfter(deadline: .now() + seconds(delay)) {
      let answer = answer()
      // Answered, so a stop from here on is not a cancellation.
      let live = me.value.state.withLock {
        me.value.pending = nil
        return !me.value.stopped
      }
      if live { me.value.deliver(answer, server, received) }
    }
  }

  override func stopLoading() {
    let pending = state.withLock {
      stopped = true
      return self.pending
    }
    if let (server, received) = pending { server.stopped(received) }
  }

  private func read(_ stream: InputStream) -> Data {
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 16384)
    while true {
      let n = stream.read(&buffer, maxLength: buffer.count)
      if n <= 0 { break }
      data.append(contentsOf: buffer[0..<n])
    }
    return data
  }
}

/// Sends a protocol instance to the queue that answers it; Foundation calls
/// it from one thread at a time.
private struct Unchecked<T>: @unchecked Sendable {
  let value: T
  init(_ value: T) { self.value = value }
}

/// The case name of an error with a payload, for matching any payload.
func kind(_ error: GhError?) -> String? {
  error.flatMap { Mirror(reflecting: $0).children.first?.label }
}

extension Result {
  var failure: Failure? {
    if case .failure(let error) = self { return error }
    return nil
  }

  var success: Success? {
    if case .success(let value) = self { return value }
    return nil
  }
}
