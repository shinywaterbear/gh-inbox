import AppKit
import GhInboxCore

/// The queues, under their group headings: each with its count, a spinner
/// while it first loads, and a mark when its last fetch failed.
@MainActor
final class Sidebar: NSObject, NSTableViewDataSource, NSTableViewDelegate {
  enum Entry: Equatable {
    case group(String)
    case queue(QueueModel)
  }

  let scrollView = NSScrollView()
  let table = SidebarTable()
  private(set) var entries: [Entry] = []
  var keyView: NSView { table }
  /// A queue was chosen, by click or arrow key.
  var onSelect: (Int) -> Void = { _ in }
  /// Right arrow: the keys move to the list.
  var toList: () -> Void {
    get { table.toList }
    set { table.toList = newValue }
  }

  override init() {
    super.init()
    let column = NSTableColumn(identifier: .init("queue"))
    table.addTableColumn(column)
    table.headerView = nil
    table.style = .sourceList
    // As in Finder and Mail: the selection's color shows where keys go.
    table.focusRingType = .none
    // Headings stay with their queues; the list is too short to need them
    // pinned, and pinned they slid over the rows in a bounce.
    table.floatsGroupRows = false
    table.rowHeight = Metrics.sidebarRowHeight
    table.allowsEmptySelection = false
    table.dataSource = self
    table.delegate = self
    table.isQueue = { [weak self] row in
      guard let self, entries.indices.contains(row), case .queue = entries[row] else { return false }
      return true
    }
    table.setAccessibilityLabel("Queues")
    scrollView.documentView = table
    scrollView.contentView.postsBoundsChangedNotifications = true
    NotificationCenter.default.addObserver(
      table, selector: #selector(SidebarTable.updateHover), name: NSView.boundsDidChangeNotification,
      object: scrollView.contentView)
    scrollView.drawsBackground = false
    scrollView.hasVerticalScroller = true
    // With "Show scroll bars: Always", a track only when there is more.
    scrollView.autohidesScrollers = true
    // Too short to scroll, so it doesn't bounce either.
    scrollView.verticalScrollElasticity = .none
  }

  /// Lists `queues` with `selected` chosen. Unchanged entries keep their
  /// views; a changed list reloads.
  func show(_ queues: [QueueModel], selected: Int) {
    var new: [Entry] = []
    var group: String?
    for queue in queues {
      if queue.group != group {
        group = queue.group
        new.append(.group(queue.group))
      }
      new.append(.queue(queue))
    }
    if new.map(identity) != entries.map(identity) {
      entries = new
      table.reloadData()
      table.updateHover()
    } else if new != entries {
      let old = entries
      entries = new
      for row in entries.indices where entries[row] != old[row] {
        (table.view(atColumn: 0, row: row, makeIfNecessary: false) as? QueueCell)?.configure(entries[row])
      }
    }
    // Mid-click the table holds the user's choice, not yet reported.
    if !table.tracking, let row = row(of: selected), table.selectedRow != row {
      table.selectRowIndexes([row], byExtendingSelection: false)
    }
  }

  func stage(hoveredRow: Int?) {
    table.stagedHover = hoveredRow
    table.updateHover()
  }

  private func identity(_ entry: Entry) -> String {
    switch entry {
    case .group(let name): "group:\(name)"
    case .queue(let queue): "queue:\(queue.section)"
    }
  }

  func row(of section: Int) -> Int? {
    entries.firstIndex { if case .queue(let q) = $0 { q.section == section } else { false } }
  }

  func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

  func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
    if case .group = entries[row] { true } else { false }
  }

  func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
    if case .queue = entries[row] { true } else { false }
  }

  func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
    let view = QueueRow()
    view.hoverable = table.isQueue(row)
    view.hovering = row == table.hoveredRow
    return view
  }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    let cell =
      tableView.makeView(withIdentifier: QueueCell.identifier, owner: nil) as? QueueCell ?? QueueCell()
    cell.identifier = QueueCell.identifier
    cell.configure(entries[row])
    return cell
  }

  func tableViewSelectionDidChange(_ notification: Notification) {
    guard entries.indices.contains(table.selectedRow), case .queue(let queue) = entries[table.selectedRow]
    else { return }
    onSelect(queue.section)
  }
}

/// Tracks the queue under the pointer, as the list's `HoverTable` does.
final class SidebarTable: NSTableView {
  var toList: () -> Void = {}
  var tracking = false
  var isQueue: (Int) -> Bool = { _ in false }
  /// Drawn as hovered whatever the pointer does, for rendering offscreen.
  var stagedHover: Int?
  private(set) var hoveredRow = -1

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    trackingAreas.filter { $0.owner === self }.forEach(removeTrackingArea)
    addTrackingArea(
      NSTrackingArea(
        rect: .zero,
        options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
        owner: self))
  }

  override func mouseEntered(with event: NSEvent) { updateHover() }
  override func mouseMoved(with event: NSEvent) { updateHover() }
  override func mouseExited(with event: NSEvent) {
    setHovered(-1)
    NSCursor.arrow.set()
  }
  override func cursorUpdate(with event: NSEvent) { updateHover() }

  private func setHovered(_ row: Int) {
    hoveredRow = row
    enumerateAvailableRowViews { view, index in (view as? QueueRow)?.hovering = index == row }
  }

  @objc func updateHover() {
    if let stagedHover {
      setHovered(stagedHover)
      return
    }
    guard let window, window.isKeyWindow else {
      setHovered(-1)
      return
    }
    let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
    guard visibleRect.contains(point) else {
      setHovered(-1)
      return
    }
    setHovered(row(at: point))
    (isQueue(hoveredRow) ? NSCursor.pointingHand : NSCursor.arrow).set()
  }

  override func mouseDown(with event: NSEvent) {
    tracking = true
    defer { tracking = false }
    super.mouseDown(with: event)
  }

  override func keyDown(with event: NSEvent) {
    if event.specialKey == .rightArrow, event.modifierFlags.intersection([.command, .option, .shift]).isEmpty
    {
      toList()
      return
    }
    super.keyDown(with: event)
  }
}

/// Washes a hovered queue as the list washes a hovered row; the selected
/// queue keeps the source list's own highlight alone.
final class QueueRow: NSTableRowView {
  var hoverable = false
  var hovering = false {
    didSet { if hovering != oldValue { needsDisplay = true } }
  }

  override var isSelected: Bool {
    didSet { if isSelected != oldValue { needsDisplay = true } }
  }

  override func drawBackground(in dirtyRect: NSRect) {
    super.drawBackground(in: dirtyRect)
    guard hovering, hoverable, !isSelected else { return }
    NSColor.labelColor.withAlphaComponent(0.07).setFill()
    NSBezierPath(
      roundedRect: bounds.insetBy(dx: Metrics.hoverInset.width, dy: Metrics.hoverInset.height),
      xRadius: Metrics.hoverRadius, yRadius: Metrics.hoverRadius
    ).fill()
  }
}

/// A group heading, or a queue: its name, then its count or state.
final class QueueCell: NSTableCellView {
  static let identifier = NSUserInterfaceItemIdentifier("queue")
  private let name = label(size: 13)
  private let count = label(size: 12, color: .secondaryLabelColor)
  private let spinner = NSProgressIndicator()
  private let failed = symbol("exclamationmark.circle.fill", size: 12, color: .systemRed)
  private var group = false
  private var loading = false

  override init(frame: NSRect) {
    super.init(frame: frame)
    name.lineBreakMode = .byTruncatingTail
    count.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    count.alignment = .right
    spinner.style = .spinning
    spinner.controlSize = .small
    spinner.isDisplayedWhenStopped = false
    for view in [name, count, spinner, failed] { addSubview(view) }
    setAccessibilityElement(true)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }

  func configure(_ entry: Sidebar.Entry) {
    switch entry {
    case .group(let title):
      group = true
      name.show(title)
      name.font = .systemFont(ofSize: 11, weight: .semibold)
      name.textColor = .secondaryLabelColor
      count.isHidden = true
      failed.isHidden = true
      loading = false
      spinner.stopAnimation(nil)
      setAccessibilityRole(.staticText)
      setAccessibilityLabel(title)
    case .queue(let queue):
      group = false
      name.show(queue.name)
      name.font = .systemFont(ofSize: 13)
      name.textColor = .labelColor
      count.show(queue.count.map(String.init) ?? "")
      count.isHidden = queue.count == nil
      failed.isHidden = queue.status != .stale && queue.status != .failed
      failed.toolTip =
        queue.status == .stale ? "The last refresh failed; showing earlier results" : "Couldn't load"
      loading = queue.status == .loading
      if loading { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
      setAccessibilityRole(.row)
      let state: String? =
        switch queue.status {
        case .ready: queue.count.map { "\($0)" }
        case .loading: "loading"
        case .stale: "\(queue.count ?? 0), last refresh failed"
        case .failed: "couldn't load"
        case .unknown: nil
        }
      setAccessibilityLabel([queue.name, state].compactMap { $0 }.joined(separator: ", "))
    }
    needsLayout = true
  }

  override func layout() {
    super.layout()
    let inset: CGFloat = group ? 4 : 8
    var right = bounds.width - 8
    if !count.isHidden { right = place(count, x: right - count.naturalSize.width).minX - 6 }
    if !failed.isHidden { right = place(failed, x: right - failed.naturalSize.width).minX - 6 }
    if loading { right = place(spinner, x: right - 16, width: 16).minX - 6 }
    place(name, x: inset, width: max(0, right - inset))
  }
}
