import AppKit
import Testing

@testable import GhInboxCore
@testable import GhInboxUI

@MainActor
struct SidebarTests {
  let sidebar = Sidebar()
  let listed = queues(Inbox())
  var mine: Int { listed.first { $0.name == "My open PRs" }!.section }
  var asked: Int { listed.first { $0.name == "Asked of me" }!.section }

  private func selected() -> Int? {
    guard case .queue(let queue) = sidebar.entries[sidebar.table.selectedRow] else { return nil }
    return queue.section
  }

  /// A render landing between a click's mouse-down and mouse-up, as a
  /// refresh's arriving sections do, must not undo the click.
  @Test func aRenderMidClickKeepsTheClickedQueue() {
    sidebar.show(listed, selected: mine)
    sidebar.table.tracking = true
    sidebar.table.selectRowIndexes([sidebar.row(of: asked)!], byExtendingSelection: false)
    sidebar.show(listed, selected: mine)
    #expect(selected() == asked)
  }

  /// Outside a click, the queue shown wins, as for cmd-1 to cmd-5.
  @Test func aRenderOtherwiseSelectsTheQueueShown() {
    sidebar.show(listed, selected: mine)
    sidebar.table.selectRowIndexes([sidebar.row(of: asked)!], byExtendingSelection: false)
    sidebar.show(listed, selected: mine)
    #expect(selected() == mine)
  }
}
