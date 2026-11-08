import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// The host and token every request of a round is sent with. Printing,
/// dumping or reflecting it never shows the token.
public struct Credential: Sendable, CustomStringConvertible, CustomDebugStringConvertible,
  CustomReflectable
{
  public var host: String
  var token: String

  public init(host: String, token: String) {
    self.host = host
    self.token = token
  }

  public var description: String { "Credential(host: \(host), token: <redacted>)" }
  public var debugDescription: String { description }
  public var customMirror: Mirror { Mirror(self, children: ["host": host, "token": "<redacted>"]) }
}

/// gh's rule: github.com and `*.ghe.com` have an API host, Enterprise Server
/// serves the API under `/api`.
func endpoint(host: String) -> URL? {
  let host = host.lowercased()
  if host == "github.com" { return URL(string: "https://api.github.com/graphql") }
  if host.hasSuffix(".ghe.com") { return URL(string: "https://api.\(host)/graphql") }
  return URL(string: "https://\(host)/api/graphql")
}

/// A finished HTTP exchange.
struct Reply: Sendable {
  var status: Int
  var body: Data
  /// `X-OAuth-Scopes`; absent for fine-grained tokens and apps.
  var scopes: String?
  var url: String

  var success: Bool { (200..<300).contains(status) }

  /// Worded as gh words an HTTP failure, which `GhError.classify` reads.
  var failure: GhError {
    let message =
      (try? JSONDecoder().decode(Message.self, from: body).message)
      ?? HTTPURLResponse.localizedString(forStatusCode: status).capitalized
    return .classify(kind: nil, message: "HTTP \(status): \(message) (\(url))")
  }

  private struct Message: Decodable {
    var message: String
  }
}

/// The URLSession every request shares, plus where each round's credential
/// comes from.
public struct GitHub: Sendable {
  let session: URLSession
  let credential: @Sendable () async -> Result<Credential, GhError>
  let timeout: Duration

  public init(
    session: URLSession, timeout: Duration = .seconds(30),
    credential: @escaping @Sendable () async -> Result<Credential, GhError>
  ) {
    self.session = session
    self.timeout = timeout
    self.credential = credential
  }

  /// gh's credential for the host it would use, over an ephemeral session
  /// that keeps no cookies or cache.
  public static func live() -> GitHub {
    let gh = Gh.resolved()
    return GitHub(session: session(timeout: .seconds(30))) { await gh.credential() }
  }

  /// A session whose requests give up after `timeout`, answer included.
  /// `protocols` replace the network, for fakes.
  public static func session(timeout: Duration, protocols: [AnyClass] = []) -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForResource = seconds(timeout)
    configuration.timeoutIntervalForRequest = seconds(timeout)
    if !protocols.isEmpty { configuration.protocolClasses = protocols }
    return URLSession(configuration: configuration, delegate: SameHostRedirects(), delegateQueue: nil)
  }

  /// One GraphQL query. The token goes only into the Authorization header.
  func graphql(_ query: String, as credential: Credential) async -> Result<Reply, GhError> {
    guard let url = endpoint(host: credential.host) else {
      return .failure(.github("not a GitHub host: \(credential.host)"))
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("bearer \(credential.token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("gh-inbox", forHTTPHeaderField: "User-Agent")
    request.httpBody = try? JSONEncoder().encode(["query": query])
    return await send(request)
  }

  /// Ends at `timeout` or on cancellation even if the session never calls
  /// back, as Linux's doesn't for a protocol that never answers.
  func send(_ request: URLRequest) async -> Result<Reply, GhError> {
    let pending = Pending()
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        let task = session.dataTask(with: request) { data, response, error in
          pending.finish(reply(request, data, response, error))
        }
        pending.start(task, continuation)
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds(timeout)) {
          pending.end(.timeout(timeout))
        }
      }
    } onCancel: {
      pending.end(.cancelled)
    }
  }

  private func reply(_ request: URLRequest, _ data: Data?, _ response: URLResponse?, _ error: Error?)
    -> Result<Reply, GhError>
  {
    if let error = error as? URLError {
      switch error.code {
      case .timedOut: return .failure(.timeout(timeout))
      case .cancelled: return .failure(.cancelled)
      default: return .failure(.network(worded(error, host: request.url?.host ?? "GitHub")))
      }
    }
    if let error { return .failure(.network(error.localizedDescription)) }
    guard let http = response as? HTTPURLResponse else { return .failure(.parse("no HTTP response")) }
    let scopes = http.allHeaderFields.first { ($0.key as? String)?.lowercased() == "x-oauth-scopes" }?.value
    return .success(
      Reply(
        status: http.statusCode, body: data ?? Data(), scopes: scopes as? String,
        url: request.url?.absoluteString ?? ""))
  }
}

/// Follows a redirect only within the same scheme and host, since the
/// Authorization header would go with it. A refused redirect's 3xx is the
/// reply, and fails as an HTTP status.
final class SameHostRedirects: NSObject, URLSessionTaskDelegate, Sendable {
  func urlSession(
    _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    completionHandler(follows(from: task.originalRequest?.url, to: request.url) ? request : nil)
  }
}

func follows(from: URL?, to: URL?) -> Bool {
  guard let from, let to, let host = from.host?.lowercased() else { return false }
  return from.scheme?.lowercased() == to.scheme?.lowercased() && host == to.host?.lowercased()
    && port(from) == port(to)
}

/// The port a URL connects to, its scheme's default when unnamed.
private func port(_ url: URL) -> Int? {
  url.port ?? ["https": 443, "http": 80][url.scheme?.lowercased() ?? ""]
}

/// The same words on every platform; Foundation's vary, and some are only a
/// domain and code.
func worded(_ error: URLError, host: String) -> String {
  switch error.code {
  case .notConnectedToInternet: "The Internet connection appears to be offline"
  case .cannotFindHost, .dnsLookupFailed: "No server was found at \(host)"
  case .cannotConnectToHost: "Could not connect to \(host)"
  case .networkConnectionLost: "The network connection was lost"
  case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
    .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .clientCertificateRejected:
    "A secure connection to \(host) could not be made"
  default: error.localizedDescription
  }
}

/// A data task whose result is delivered once: its own, or the error that
/// ended it first. It may be ended before it has started.
private final class Pending: @unchecked Sendable {
  private let lock = NSLock()
  private var task: URLSessionDataTask?
  private var continuation: CheckedContinuation<Result<Reply, GhError>, Never>?
  private var ended: GhError?
  private var done = false

  func start(_ task: URLSessionDataTask, _ continuation: CheckedContinuation<Result<Reply, GhError>, Never>) {
    let ended = lock.withLock {
      self.task = task
      self.continuation = continuation
      return self.ended
    }
    if let ended {
      finish(.failure(ended))
    } else {
      task.resume()
    }
  }

  func end(_ error: GhError) {
    let task = lock.withLock {
      if ended == nil { ended = error }
      return self.task
    }
    task?.cancel()
    finish(.failure(error))
  }

  func finish(_ result: Result<Reply, GhError>) {
    let continuation: CheckedContinuation<Result<Reply, GhError>, Never>? = lock.withLock {
      guard !done, let continuation = self.continuation else { return nil }
      done = true
      return continuation
    }
    continuation?.resume(returning: result)
  }
}

func seconds(_ d: Duration) -> TimeInterval {
  let (s, atto) = d.components
  return TimeInterval(s) + TimeInterval(atto) / 1e18
}
