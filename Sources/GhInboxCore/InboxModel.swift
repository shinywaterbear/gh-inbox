/// Runs the inbox's jobs against GitHub and applies their outcomes, on the
/// main actor. An account change cancels every request still in flight.
@MainActor
public final class InboxModel {
  public private(set) var inbox = Inbox()
  /// Called after every change worth drawing.
  public var changed: @MainActor () -> Void = {}
  private let github: GitHub
  private var tasks: [UInt64: Task<Void, Never>] = [:]
  private var nextTask: UInt64 = 0
  /// The latest round's credential, shared by every job in that round.
  private var credential: (round: UInt64, task: Task<Result<Credential, GhError>, Never>)?

  public init(github: GitHub) {
    self.github = github
  }

  /// Queues every idle section. Returns how many.
  @discardableResult
  public func refresh() -> Int {
    let queued = inbox.refresh()
    pump()
    return queued
  }

  public func loadMore(_ section: Int) {
    if inbox.loadMore(section) { pump() }
  }

  public func setReviewDirectOnly(_ directOnly: Bool) {
    if inbox.setReviewDirectOnly(directOnly) { pump() } else { changed() }
  }

  public func setOwnerFilter(_ filter: OwnerFilter) {
    inbox.ownerFilter = filter
    changed()
  }

  /// Requests in flight, for tests.
  var inFlight: Int { tasks.count }

  /// Starts queued jobs while slots are free; each finished job applies its
  /// outcome, which is drawn at once, and pumps again.
  private func pump() {
    while let ticket = inbox.nextJob() {
      let id = nextTask
      nextTask += 1
      let credential = credential(for: ticket.round)
      tasks[id] = Task { [github] in
        let outcome: Outcome =
          switch await credential.value {
          case .success(let credential) where !Task.isCancelled:
            await github.perform(ticket.job, as: credential)
          case .success: .failed(ticket.job, .cancelled)
          case .failure(let error): .failed(ticket.job, error)
          }
        self.finish(id, ticket, outcome)
      }
    }
    changed()
  }

  private func finish(_ id: UInt64, _ ticket: Ticket, _ outcome: Outcome) {
    tasks[id] = nil
    if inbox.finish(ticket, outcome, now: .now) {
      for task in tasks.values { task.cancel() }
      inbox.refresh()
    }
    pump()
  }

  /// A job from an older round takes the newest credential rather than
  /// asking gh again and evicting it.
  func credential(for round: UInt64) -> Task<Result<Credential, GhError>, Never> {
    if let credential, credential.round >= round { return credential.task }
    let task = Task { [github] in await github.credential() }
    credential = (round, task)
    return task
  }
}
