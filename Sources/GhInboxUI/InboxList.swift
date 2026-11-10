import AppKit
import GhInboxCore

/// The sectioned list: headings, notices, items and cut-off rows, updated
/// in place from each render's `RowModel`s. Rows that keep their identity
/// keep their views, so hover, tooltips and the cursor survive updates.
@MainActor
final class InboxList: NSObject, NSTableViewDataSource, NSTableViewDelegate {
  let scrollView = NSScrollView()
  private let table = HoverTable()
  /// Where keys go when the window opens.
  var keyView: NSView { table }
  private(set) var rows: [RowModel] = []
  private var multiOwner = false
  private var repoColumn = Metrics.repoWidth.nameOnly
  private var ageColumn = Metrics.ageWidth
  var onLoadMore: (Int) -> Void = { _ in }

  override init() {
    super.init()
    let column = NSTableColumn(identifier: .init("row"))
    column.resizingMask = .autoresizingMask
    table.addTableColumn(column)
    table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
    table.headerView = nil
    table.rowHeight = Metrics.rowHeight
    table.intercellSpacing = .zero
    table.style = .plain
    table.selectionHighlightStyle = .none
    table.allowsTypeSelect = false
    table.backgroundColor = .controlBackgroundColor
    table.floatsGroupRows = true
    table.dataSource = self
    table.delegate = self
    table.target = self
    table.action = #selector(clicked(_:))
    table.pinnedHeading = { [weak self] row in
      self.flatMap { pinnedHeading($0.rows, firstVisible: row) }
    }
    table.isClickable = { [weak self] row in
      guard let self, rows.indices.contains(row) else { return false }
      return rows[row].action != nil
    }
    table.next = { [weak self] from, step in
      self.flatMap { nextSelectable($0.rows, from: from, step: step) }
    }
    table.copyText = { [weak self] row in
      guard let self, rows.indices.contains(row) else { return nil }
      return rows[row].copyText
    }
    table.contextMenu = { [weak self] row in
      guard let self, rows.indices.contains(row), !rows[row].menu.isEmpty else { return nil }
      let menu = NSMenu()
      for entry in rows[row].menu {
        let item = NSMenuItem(title: entry.title, action: #selector(choose(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = entry.action
        menu.addItem(item)
      }
      return menu
    }
    table.activate = { [weak self] row in
      guard let self, rows.indices.contains(row), let action = rows[row].action else { return }
      perform(action)
    }
    table.setAccessibilityLabel("Open pull requests and issues")
    scrollView.documentView = table
    scrollView.hasVerticalScroller = true
    scrollView.backgroundColor = .controlBackgroundColor
    scrollView.contentView.postsBoundsChangedNotifications = true
    scrollView.postsFrameChangedNotifications = true
    NotificationCenter.default.addObserver(
      self, selector: #selector(resized), name: NSView.frameDidChangeNotification, object: scrollView)
    NotificationCenter.default.addObserver(
      table, selector: #selector(HoverTable.updateHover), name: NSView.boundsDidChangeNotification,
      object: scrollView.contentView)
  }

  /// Applies only what changed since the last rows: rows that left or
  /// arrived are removed or inserted, and kept rows are reconfigured.
  func show(_ new: [RowModel]) {
    let diff = changes(from: rows, to: new)
    rows = new
    multiOwner = new.contains { if case .item(let item) = $0.content { item.owner != nil } else { false } }
    let ages = new.compactMap { if case .item(let item) = $0.content { item.age } else { nil } }
    let age = Metrics.ageColumn(ages)
    if age != ageColumn {
      ageColumn = age
      table.enumerateAvailableRowViews { rowView, _ in
        (rowView.view(atColumn: 0) as? RowCell)?.ageColumn = age
      }
    }
    if !diff.removed.isEmpty || !diff.inserted.isEmpty {
      table.beginUpdates()
      table.removeRows(at: IndexSet(diff.removed), withAnimation: [])
      table.insertRows(at: IndexSet(diff.inserted), withAnimation: [])
      table.endUpdates()
    }
    for row in diff.updated { reconfigure(row) }
    resized()
    table.updateHover()
  }

  private func reconfigure(_ row: Int) {
    (table.rowView(atRow: row, makeIfNecessary: false) as? HoverRow)?.configure(rows[row])
    (table.view(atColumn: 0, row: row, makeIfNecessary: false) as? RowCell)?.configure(
      rows[row], onLoadMore: onLoadMore)
  }

  /// The repository column follows the window's width, in place.
  @objc private func resized() {
    let column = Metrics.repoColumn(multiOwner: multiOwner, width: scrollView.contentSize.width)
    guard column != repoColumn else { return }
    repoColumn = column
    table.enumerateAvailableRowViews { rowView, _ in
      (rowView.view(atColumn: 0) as? RowCell)?.repoColumn = column
    }
  }

  func stage(hoveredRow: Int?, selectedRow: Int?, scroll: CGFloat?) {
    if let scroll { table.scroll(NSPoint(x: 0, y: scroll)) }
    if let selectedRow { table.selectRowIndexes([selectedRow], byExtendingSelection: false) }
    table.stagedHover = hoveredRow
    table.updateHover()
  }

  func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

  /// Rows that act can be selected, by click or arrow key; Return then
  /// does what a click does.
  func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
    rows.indices.contains(row) && rows[row].action != nil
  }

  /// A floating heading can ask about its row after the rows shrank.
  func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
    rows.indices.contains(row) && rows[row].isHeading
  }

  func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
    guard rows.indices.contains(row) else { return nil }
    let view = HoverRow()
    view.configure(rows[row])
    view.hovering = row == table.hoveredRow
    return view
  }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    guard rows.indices.contains(row) else { return nil }
    let model = rows[row]
    let identifier = RowCell.identifier(for: model)
    let cell =
      tableView.makeView(withIdentifier: identifier, owner: nil) as? RowCell ?? RowCell.make(for: model)
    cell.identifier = identifier
    cell.repoColumn = repoColumn
    cell.ageColumn = ageColumn
    cell.configure(model, onLoadMore: onLoadMore)
    return cell
  }

  @objc private func clicked(_ sender: Any?) {
    table.activate(table.clickedRowUnderPins)
  }

  @objc private func choose(_ sender: NSMenuItem) {
    if let action = sender.representedObject as? RowAction { perform(action) }
  }

  private func perform(_ action: RowAction) {
    switch action {
    case .open(let url):
      if let link = URL(string: url) { NSWorkspace.shared.open(link) }
    case .copy(let text): putOnPasteboard(text)
    }
  }
}

/// Tracks the one row under the pointer. Per-row tracking areas miss exits
/// when rows scroll out from under a still pointer, leaving several lit.
final class HoverTable: NSTableView {
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

  /// Every prepared row view is told, not just the old and new rows: rows
  /// inserted or removed above shift which view an index names.
  private func setHovered(_ row: Int) {
    hoveredRow = row
    enumerateAvailableRowViews { view, index in (view as? HoverRow)?.hovering = index == row }
  }

  /// Recomputes the hovered row from the pointer's current position.
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
      // The pointer is elsewhere, whose cursor isn't the list's to set.
      setHovered(-1)
      return
    }
    setHovered(rowUnderPins(point))
    // Set here rather than by per-row cursor rects, which a pinned heading
    // doesn't block for the row hidden beneath it. A button in a row that
    // isn't clickable itself still gets the hand.
    (isClickable(hoveredRow) || isOverButton(point) ? NSCursor.pointingHand : NSCursor.arrow).set()
  }

  private func isOverButton(_ point: NSPoint) -> Bool {
    var view = superview.flatMap { hitTest(convert(point, to: $0)) }
    while let current = view, current !== self {
      if current is NSButton { return true }
      view = current.superview
    }
    return false
  }

  /// The heading for a row index, set by the list.
  var pinnedHeading: (Int) -> Int? = { _ in nil }
  /// Whether a row acts on a click, set by the list.
  var isClickable: (Int) -> Bool = { _ in false }
  /// The row an arrow key selects next, set by the list.
  var next: (_ from: Int?, _ step: Int) -> Int? = { _, _ in nil }
  /// Does what clicking the row does, set by the list.
  var activate: (Int) -> Void = { _ in }
  /// The right-click menu for a row, set by the list.
  var contextMenu: (Int) -> NSMenu? = { _ in nil }
  /// What Edit > Copy takes from a row, set by the list.
  var copyText: (Int) -> String? = { _ in nil }

  @objc func copy(_ sender: Any?) {
    guard selectedRow >= 0, let text = copyText(selectedRow) else { return }
    putOnPasteboard(text)
  }

  override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
    guard item.action == #selector(copy(_:)) else { return super.validateUserInterfaceItem(item) }
    return selectedRow >= 0 && copyText(selectedRow) != nil
  }

  /// A click takes the keys back from wherever they went.
  /// A click on a pinned heading stops there: the table would select the
  /// row scrolled beneath it, which Return would then open unseen.
  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    // The table would treat a control-click as a click and open the row.
    if event.modifierFlags.contains(.control) {
      if let menu = menu(for: event) { NSMenu.popUpContextMenu(menu, with: event, for: self) }
      return
    }
    let point = convert(event.locationInWindow, from: nil)
    if rowUnderPins(point) != row(at: point) { return }
    super.mouseDown(with: event)
  }

  /// Like a click, a right-click on a pinned heading is the heading's.
  override func menu(for event: NSEvent) -> NSMenu? {
    let row = rowUnderPins(convert(event.locationInWindow, from: nil))
    return row >= 0 ? contextMenu(row) : nil
  }

  /// Up and down skip headings and cut-off rows, which do nothing; Return
  /// acts on the selection and Escape clears it.
  override func keyDown(with event: NSEvent) {
    let current = selectedRow >= 0 ? selectedRow : nil
    switch event.specialKey {
    case .downArrow?, .upArrow?:
      guard event.modifierFlags.intersection([.command, .option, .shift]).isEmpty else { break }
      if let row = next(current, event.specialKey == .downArrow ? 1 : -1) {
        selectRowIndexes([row], byExtendingSelection: false)
        scrollRowToVisible(row)
      }
      return
    case .carriageReturn?, .enter?:
      if let current { activate(current) }
      return
    default:
      if event.charactersIgnoringModifiers == "\u{1b}" {
        deselectAll(nil)
        return
      }
    }
    super.keyDown(with: event)
  }

  /// The row at `point`, counting a heading pinned over the top of the list
  /// as covering the row scrolled beneath it.
  func rowUnderPins(_ point: NSPoint) -> Int {
    let hit = row(at: point)
    let top = rows(in: visibleRect).location
    guard point.y < visibleRect.minY + Metrics.rowHeight, let heading = pinnedHeading(top) else { return hit }
    return heading
  }

  /// The clicked row, by the same rule as hovering.
  var clickedRowUnderPins: Int {
    guard let event = NSApp.currentEvent, event.window === window else { return clickedRow }
    return rowUnderPins(convert(event.locationInWindow, from: nil))
  }
}

/// Highlights a clickable hovered row; a heading keeps an opaque background
/// so it can float over the rows beneath it.
final class HoverRow: NSTableRowView {
  /// Held here: AppKit doesn't retain a tooltip's owner.
  private let toolTipOwner = LiveToolTip()
  private var clickable = false
  private var heading = false
  /// A rule above the heading, for every section but the first.
  private var ruled = false
  var hovering = false {
    didSet { if hovering != oldValue { needsDisplay = true } }
  }

  override var isSelected: Bool {
    didSet { if isSelected != oldValue { needsDisplay = true } }
  }

  override var isEmphasized: Bool {
    didSet { if isEmphasized != oldValue { needsDisplay = true } }
  }

  func configure(_ row: RowModel) {
    toolTipOwner.text = row.toolTip
    toolTipOwner.attach(to: self)
    let ruled = if case .heading(let heading) = row.content { heading.ruled } else { false }
    let clickable = row.action != nil
    if (clickable, row.isHeading, ruled) != (self.clickable, heading, self.ruled) {
      (self.clickable, heading, self.ruled) = (clickable, row.isHeading, ruled)
      needsDisplay = true
    }
  }

  override var isFloating: Bool {
    didSet { needsDisplay = true }
  }

  override func setFrameSize(_ size: NSSize) {
    super.setFrameSize(size)
    toolTipOwner.attach(to: self)
  }

  override func drawBackground(in dirtyRect: NSRect) {
    if heading {
      NSColor.controlBackgroundColor.setFill()
      bounds.fill()
      NSColor.labelColor.withAlphaComponent(0.04).setFill()
      bounds.fill()
    }
    let wash = NSBezierPath(
      roundedRect: bounds.insetBy(dx: Metrics.hoverInset.width, dy: Metrics.hoverInset.height),
      xRadius: Metrics.hoverRadius, yRadius: Metrics.hoverRadius)
    if isSelected && clickable {
      // The accent as a tint, so the row's own colors still read; plain
      // when the list isn't where keys go.
      (isEmphasized
        ? NSColor.controlAccentColor.withAlphaComponent(0.22) : NSColor.labelColor.withAlphaComponent(0.1))
        .setFill()
      wash.fill()
    }
    if hovering && clickable {
      // A wash of the text color: dark on light, light on dark, and never
      // so strong it fights the row's own text.
      NSColor.labelColor.withAlphaComponent(0.07).setFill()
      wash.fill()
    }
    NSColor.separatorColor.setFill()
    if heading {
      NSRect(x: 0, y: isFlipped ? bounds.maxY - 1 : bounds.minY, width: bounds.width, height: 1).fill()
      if ruled {
        NSRect(x: 0, y: isFlipped ? bounds.minY : bounds.maxY - 1, width: bounds.width, height: 1).fill()
      }
    }
  }

  override func drawSeparator(in dirtyRect: NSRect) {}

  /// Drawn in `drawBackground`, as a tint rather than a solid fill.
  override func drawSelection(in dirtyRect: NSRect) {}
}

private func putOnPasteboard(_ text: String) {
  NSPasteboard.general.clearContents()
  NSPasteboard.general.setString(text, forType: .string)
}
