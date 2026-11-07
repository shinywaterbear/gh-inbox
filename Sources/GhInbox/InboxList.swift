import AppKit
import GhInboxCore

/// Every row kind is this tall, so the list never reflows as rows change kind.
private let rowHeight: CGFloat = 36

/// The sectioned list: headings, notices, items and "Load more" rows.
@MainActor
final class InboxList: NSObject, NSTableViewDataSource, NSTableViewDelegate {
  let scrollView = NSScrollView()
  private let table = HoverTable()
  private var shown = Rows()
  private var inbox = Inbox()
  var onLoadMore: (Int) -> Void = { _ in }

  override init() {
    super.init()
    let column = NSTableColumn(identifier: .init("row"))
    column.resizingMask = .autoresizingMask
    table.addTableColumn(column)
    table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
    table.headerView = nil
    table.rowHeight = rowHeight
    table.intercellSpacing = .zero
    table.style = .plain
    table.selectionHighlightStyle = .none
    table.backgroundColor = .clear
    table.dataSource = self
    table.delegate = self
    table.target = self
    table.action = #selector(clicked(_:))
    scrollView.documentView = table
    scrollView.hasVerticalScroller = true
    scrollView.drawsBackground = false
    scrollView.contentView.postsBoundsChangedNotifications = true
    NotificationCenter.default.addObserver(
      table, selector: #selector(HoverTable.updateHover), name: NSView.boundsDidChangeNotification,
      object: scrollView.contentView)
  }

  func show(_ rows: Rows, of inbox: Inbox) {
    shown = rows
    self.inbox = inbox
    table.reloadData()
    table.updateHover()
  }

  func numberOfRows(in tableView: NSTableView) -> Int { shown.rows.count }

  func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

  func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
    let view = HoverRow()
    view.hovering = row == table.hoveredRow
    switch shown.rows[row] {
    case .heading(_, let first, _):
      // A rule above every section but the first, which sits under the header's.
      view.ruled = !first
    case .notice(let text, _, let url):
      view.clickable = true
      view.toolTip = url == nil ? "\(text)\n\nClick to copy." : text
    case .item(let section, let index):
      view.clickable = true
      view.toolTip = inbox.sections[section].items[index].title
    case .loadMore(let section):
      view.clickable = !inbox.sections[section].expanding
    }
    return view
  }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    switch shown.rows[row] {
    case .heading(let index, _, let count):
      let section = inbox.sections[index]
      // An empty section stays as a dimmed heading: "nothing waiting" is
      // worth seeing, a row saying so is not.
      let empty = section.loaded && count == 0
      let name = label(size: 13, weight: .semibold, color: empty ? .secondaryLabelColor : .labelColor)
      name.stringValue = section.name
      // Never loaded is unknown, not zero.
      let number = label(size: 11, color: .secondaryLabelColor)
      number.stringValue = section.loaded ? String(count) : "—"
      let spacer = NSView()
      spacer.setContentHuggingPriority(.init(1), for: .horizontal)
      return cells([name, number, spacer])
    case .notice(let text, let tone, _):
      let field = label(size: 12, color: tone.color)
      field.stringValue = text
      field.lineBreakMode = .byTruncatingTail
      field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
      field.setContentHuggingPriority(.init(1), for: .horizontal)
      return cells([field])
    case .item(let section, let index):
      let item = inbox.sections[section].items[index]
      return itemCells(item, check: inbox.check(item))
    case .loadMore(let section):
      let busy = inbox.sections[section].expanding
      let field = label(size: 12, color: busy ? .secondaryLabelColor : .linkColor)
      field.stringValue = busy ? "Loading…" : "Load \(pageStep) more"
      return cells([field])
    }
  }

  private func itemCells(_ item: Item, check: CheckView?) -> NSView {
    let kind = Kind(item)
    let kindLabel = fixed(label(size: 11, color: kind.color), width: 60)
    kindLabel.stringValue = kind.label
    let repo = fixed(label(size: 12, color: .secondaryLabelColor), width: shown.multiOwner ? 240 : 170)
    repo.stringValue =
      "\(shown.multiOwner ? item.repository.nameWithOwner : item.repository.name)#\(item.number)"
    let title = label(size: 13, color: item.isDraft ? .secondaryLabelColor : .labelColor)
    title.stringValue = item.title
    title.lineBreakMode = .byTruncatingTail
    title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    var titleViews: [NSView] = [title]
    if let route = routeLabel(item.reviewRoute) {
      let routeField = label(size: 11, color: .secondaryLabelColor)
      routeField.stringValue = route
      routeField.setContentCompressionResistancePriority(.required, for: .horizontal)
      titleViews.append(routeField)
    }
    let titles = NSStackView(views: titleViews)
    titles.alignment = .firstBaseline
    titles.spacing = 8
    // The title takes whatever width the fixed columns leave.
    titles.setContentHuggingPriority(.init(1), for: .horizontal)
    titles.setContentCompressionResistancePriority(.init(1), for: .horizontal)
    let author = fixed(label(size: 11, color: .secondaryLabelColor), width: 110)
    author.stringValue = item.author
    let date = fixed(label(size: 11, color: .secondaryLabelColor), width: 72)
    date.stringValue = String(item.updatedAt.prefix(10))
    return cells([DotView(Dot(check)), kindLabel, repo, titles, author, date])
  }

  @objc private func clicked(_ sender: Any?) {
    let row = table.clickedRow
    guard shown.rows.indices.contains(row) else { return }
    switch shown.rows[row] {
    case .heading: break
    case .notice(let text, _, let url):
      if let url, let link = URL(string: url) {
        NSWorkspace.shared.open(link)
      } else {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
      }
    case .item(let section, let index):
      if let link = URL(string: inbox.sections[section].items[index].url) { NSWorkspace.shared.open(link) }
    case .loadMore(let section):
      onLoadMore(section)
    }
  }
}

@MainActor
private func cells(_ views: [NSView]) -> NSView {
  let stack = NSStackView(views: views)
  stack.spacing = 12
  stack.distribution = .fill
  stack.alignment = .centerY
  stack.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
  for view in views { view.setContentHuggingPriority(.required, for: .vertical) }
  return stack
}

@MainActor
private func fixed(_ field: NSTextField, width: CGFloat) -> NSTextField {
  field.lineBreakMode = .byTruncatingTail
  field.widthAnchor.constraint(equalToConstant: width).isActive = true
  return field
}

extension Kind {
  var color: NSColor {
    switch self {
    case .issue: .systemBlue
    case .draft: .tertiaryLabelColor
    case .approved, .pullRequest: .systemGreen
    case .changes: .systemOrange
    }
  }
}

extension Checks {
  var color: NSColor {
    switch self {
    case .passing: .systemGreen
    case .failing: .systemRed
    case .pending: .systemYellow
    }
  }
}

/// A PR's check state as an 8-point dot.
final class DotView: NSView {
  private let dot: Dot

  init(_ dot: Dot) {
    self.dot = dot
    super.init(frame: NSRect(x: 0, y: 0, width: 8, height: 8))
    widthAnchor.constraint(equalToConstant: 8).isActive = true
    heightAnchor.constraint(equalToConstant: 8).isActive = true
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  override func draw(_ dirtyRect: NSRect) {
    let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5))
    switch dot {
    case .none: break
    case .filled(let checks, let dim):
      checks.color.withAlphaComponent(dim ? 0.45 : 1).setFill()
      circle.fill()
    case .loading:
      NSColor.secondaryLabelColor.setStroke()
      circle.stroke()
    case .failed:
      NSColor.systemYellow.setStroke()
      circle.stroke()
    }
  }
}

/// Tracks the one row under the pointer. Per-row tracking areas miss exits
/// when rows scroll out from under a still pointer, leaving several lit.
final class HoverTable: NSTableView {
  private(set) var hoveredRow = -1 {
    didSet {
      guard hoveredRow != oldValue else { return }
      for row in [oldValue, hoveredRow] where row >= 0 && row < numberOfRows {
        (rowView(atRow: row, makeIfNecessary: false) as? HoverRow)?.hovering = row == hoveredRow
      }
    }
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    trackingAreas.filter { $0.owner === self }.forEach(removeTrackingArea)
    addTrackingArea(
      NSTrackingArea(
        rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
        owner: self))
  }

  override func mouseEntered(with event: NSEvent) { updateHover() }
  override func mouseMoved(with event: NSEvent) { updateHover() }
  override func mouseExited(with event: NSEvent) { hoveredRow = -1 }

  /// Recomputes the hovered row from the pointer's current position.
  @objc func updateHover() {
    guard let window, window.isKeyWindow else {
      hoveredRow = -1
      return
    }
    let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
    hoveredRow = visibleRect.contains(point) ? row(at: point) : -1
  }
}

/// Highlights a clickable hovered row and draws a section's rule.
final class HoverRow: NSTableRowView {
  var clickable = false
  var ruled = false
  var hovering = false {
    didSet { if hovering != oldValue { needsDisplay = true } }
  }

  override func resetCursorRects() {
    if clickable { addCursorRect(bounds, cursor: .pointingHand) }
  }

  override func drawBackground(in dirtyRect: NSRect) {
    if hovering && clickable {
      NSColor.quaternaryLabelColor.setFill()
      bounds.fill()
    }
    if ruled {
      NSColor.separatorColor.setFill()
      NSRect(x: 0, y: isFlipped ? bounds.minY : bounds.maxY - 1, width: bounds.width, height: 1).fill()
    }
  }
}
