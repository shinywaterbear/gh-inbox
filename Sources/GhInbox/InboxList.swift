import AppKit
import GhInboxCore

/// Every row kind is this tall, so the list never reflows as rows change kind.
private let rowHeight: CGFloat = 30
/// The list's left and right margin.
private let inset: CGFloat = 20
/// Where an item's repository column starts: after the check and kind icons.
private let leadWidth: CGFloat = 14 + 8 + 16
private let authorWidth: CGFloat = 104
private let ageWidth: CGFloat = 52
/// The repository column's width, with and without owners shown. Fixed, so
/// titles never shift sideways as rows come and go.
private let repoWidth = (withOwner: CGFloat(200), nameOnly: CGFloat(140))

/// The sectioned list: headings, notices, items and "Load more" rows.
@MainActor
final class InboxList: NSObject, NSTableViewDataSource, NSTableViewDelegate {
  let scrollView = NSScrollView()
  private let table = HoverTable()
  private var shown = Rows()
  private var inbox = Inbox()
  private var repoColumn = repoWidth.nameOnly
  /// Under the headings when every section loaded and none has anything.
  let allClear = NSStackView()
  /// For capturing the window unattended, when nothing can scroll it: the
  /// list opens scrolled down this many points.
  private let forcedScroll = ProcessInfo.processInfo.environment["GH_INBOX_SCROLL"].flatMap { Double($0) }
  /// Places `allClear` just under the rows (only headings when it shows).
  var allClearTop: NSLayoutConstraint?
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
    table.backgroundColor = .controlBackgroundColor
    table.floatsGroupRows = true
    table.dataSource = self
    table.delegate = self
    table.target = self
    table.action = #selector(clicked(_:))
    table.pinnedHeading = { [weak self] row in
      self.flatMap { pinnedHeading($0.shown.rows, firstVisible: row) }
    }
    table.isClickable = { [weak self] row in
      guard let self, shown.rows.indices.contains(row) else { return false }
      switch shown.rows[row] {
      case .heading, .cutOff: return false
      case .notice, .item: return true
      }
    }
    scrollView.documentView = table
    scrollView.hasVerticalScroller = true
    scrollView.backgroundColor = .controlBackgroundColor
    scrollView.contentView.postsBoundsChangedNotifications = true
    scrollView.postsFrameChangedNotifications = true
    NotificationCenter.default.addObserver(
      self, selector: #selector(resized), name: NSView.frameDidChangeNotification, object: scrollView)

    let check = symbol("checkmark.circle", size: 28, color: .tertiaryLabelColor)
    check.symbolConfiguration = .init(pointSize: 28, weight: .light)
    let message = label(size: 13, color: .secondaryLabelColor)
    message.stringValue = "Nothing open for you"
    allClear.setViews([check, message], in: .center)
    allClear.orientation = .vertical
    allClear.spacing = 8
    allClear.isHidden = true
    allClear.translatesAutoresizingMaskIntoConstraints = false
    NotificationCenter.default.addObserver(
      table, selector: #selector(HoverTable.updateHover), name: NSView.boundsDidChangeNotification,
      object: scrollView.contentView)
  }

  func show(_ rows: Rows, of inbox: Inbox) {
    shown = rows
    self.inbox = inbox
    allClear.isHidden = !nothingOpen(inbox)
    allClearTop?.constant = CGFloat(rows.rows.count) * rowHeight + 48
    repoColumn = fittedRepoColumn()
    table.reloadData()
    if let forcedScroll, !rows.rows.isEmpty {
      table.scroll(NSPoint(x: 0, y: forcedScroll))
    }
    table.updateHover()
  }

  /// A narrow window gives titles the room first.
  /// Before the first layout the list has no width yet; the full column
  /// stands in until the first resize corrects it.
  private func fittedRepoColumn() -> CGFloat {
    let full = shown.multiOwner ? repoWidth.withOwner : repoWidth.nameOnly
    let width = scrollView.contentSize.width
    return width > 0 ? min(full, (width * 0.24).rounded()) : full
  }

  /// Resizes the repository column in place: a reload on every live-resize
  /// step would rebuild every row and drop hover and tooltips.
  @objc private func resized() {
    let column = fittedRepoColumn()
    guard column != repoColumn else { return }
    repoColumn = column
    table.enumerateAvailableRowViews { rowView, _ in
      (rowView.view(atColumn: 0) as? ItemCell)?.repoWidth.constant = column
    }
  }

  /// Keeps the list's copy of the inbox current when rows are unchanged
  /// and not rebuilt, so ages and clicks read the latest data. Equal rows
  /// index the same items in either copy.
  func update(_ inbox: Inbox) {
    self.inbox = inbox
  }

  /// Re-reads each visible item's age without rebuilding rows.
  func refreshAges() {
    let now = Date()
    // Every prepared row, not only visible ones: rows kept just out of view
    // come back on scroll without being rebuilt.
    table.enumerateAvailableRowViews { rowView, row in
      guard shown.rows.indices.contains(row) else { return }
      let cell = rowView.view(atColumn: 0)
      switch shown.rows[row] {
      case .item(let section, let index):
        (cell as? ItemCell)?.age.stringValue =
          age(inbox.sections[section].items[index].updatedAt, now: now) ?? ""
      case .notice(let notice) where notice.since != nil:
        (cell as? NoticeCell)?.refresh()
      default: break
      }
    }
  }

  /// "owner/" (only when several owners show), the name, then the number.
  private func repoText(_ item: Item) -> NSAttributedString {
    let font = NSFont.systemFont(ofSize: 12)
    // The middle goes first, so the number survives.
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byTruncatingMiddle
    let text = NSMutableAttributedString()
    func add(_ part: String, _ color: NSColor) {
      text.append(
        NSAttributedString(
          string: part, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]))
    }
    if shown.multiOwner { add("\(item.owner)/", .tertiaryLabelColor) }
    add(item.repository.name, .secondaryLabelColor)
    add(" #\(item.number)", .tertiaryLabelColor)
    return text
  }

  var isEmpty: Bool { shown.rows.isEmpty }

  func numberOfRows(in tableView: NSTableView) -> Int { shown.rows.count }

  func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

  /// A floating heading can ask about its row after the rows shrank.
  func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
    guard shown.rows.indices.contains(row) else { return false }
    if case .heading = shown.rows[row] { return true } else { return false }
  }

  func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
    guard shown.rows.indices.contains(row) else { return nil }
    let view = HoverRow()
    view.hovering = row == table.hoveredRow
    switch shown.rows[row] {
    case .heading(_, let first, _):
      view.heading = true
      view.ruled = !first
    case .notice(let notice):
      view.clickable = true
      view.liveToolTip = LiveToolTip { notice.rowToolTip }
    case .cutOff(_, let note, _):
      // Only its buttons act: a near-miss on "Load more" shouldn't open
      // the browser.
      view.toolTip = note
    case .item(let section, let index):
      let item = inbox.sections[section].items[index]
      view.clickable = true
      // The route too: a narrow row may have no room to show it.
      let route = routeLabel(item.reviewRoute).map { "\nReview request: \($0)" } ?? ""
      view.toolTip =
        "\(item.title)\n\(item.repository.nameWithOwner) #\(item.number) · updated \(localTime(item.updatedAt))"
        + route
    }
    return view
  }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    guard shown.rows.indices.contains(row) else { return nil }
    switch shown.rows[row] {
    case .heading(let index, _, let count):
      return headingCells(inbox.sections[index], count: count)
    case .notice(let notice):
      return NoticeCell(notice)
    case .item(let section, let index):
      let item = inbox.sections[section].items[index]
      return ItemCell(
        item, check: inbox.check(item), repo: repoText(item), repoWidth: repoColumn,
        viewer: inbox.identity?.login)
    case .cutOff(let section, let note, let url):
      return cutOffCells(inbox.sections[section], index: section, note: note, url: url)
    }
  }

  /// "Load more" while the section can grow, what the page holds, and the
  /// full search for everything it can't.
  private func cutOffCells(_ section: SectionView, index: Int, note: String, url: String) -> NSView {
    let icon = symbol("ellipsis.circle", size: 12, color: .tertiaryLabelColor)
    var views: [NSView] = []
    if section.expanding {
      let loading = label(size: 12, color: .secondaryLabelColor)
      loading.stringValue = "Loading…"
      views.append(loading)
    } else if section.canLoadMore {
      views.append(LinkButton("Load \(pageStep) more") { [weak self] in self?.onLoadMore(index) })
    }
    let field = label(size: 12, color: .secondaryLabelColor)
    field.stringValue = note
    field.lineBreakMode = .byTruncatingTail
    field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    views.append(field)
    views.append(
      LinkButton("Open on GitHub", symbol: "arrow.up.right") {
        if let link = URL(string: url) { NSWorkspace.shared.open(link) }
      })
    let spacer = NSView()
    spacer.setContentHuggingPriority(.init(1), for: .horizontal)
    views.append(spacer)
    let stack = lead(icon, views)
    return stack
  }

  private func headingCells(_ section: SectionView, count: Int) -> NSView {
    // An empty section stays as a dimmed heading: "nothing waiting" is
    // worth seeing, a row saying so is not.
    let mark = headingMark(section, shown: count)
    let empty = mark == .count(0, dim: true)
    let name = label(size: 13, weight: .semibold, color: empty ? .secondaryLabelColor : .labelColor)
    name.stringValue = section.name
    var views: [NSView] = [name]
    switch mark {
    case .count(let count, let dim):
      views.append(CountBadge(count, dim: dim))
    case .loading:
      let spinner = NSProgressIndicator()
      spinner.style = .spinning
      spinner.controlSize = .small
      spinner.startAnimation(nil)
      views.append(spinner)
    case .failed:
      let failed = symbol("exclamationmark.circle.fill", size: 12, color: .systemRed)
      failed.toolTip = "This section couldn't load"
      views.append(failed)
    case .unknown:
      let unknown = label(size: 12, color: .tertiaryLabelColor)
      unknown.stringValue = "—"
      views.append(unknown)
    }
    let spacer = NSView()
    spacer.setContentHuggingPriority(.init(1), for: .horizontal)
    views.append(spacer)
    let stack = cells(views, spacing: 8)
    stack.edgeInsets.top = 6
    return stack
  }

  @objc private func clicked(_ sender: Any?) {
    let row = table.clickedRowUnderPins
    guard shown.rows.indices.contains(row) else { return }
    switch shown.rows[row] {
    case .heading: break
    case .notice(let notice):
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(notice.text(now: .now), forType: .string)
    case .item(let section, let index):
      if let link = URL(string: inbox.sections[section].items[index].url) { NSWorkspace.shared.open(link) }
    case .cutOff: break
    }
  }
}

/// A notice row: its icon under the kind icons, its text, with an age that
/// moves in place, starting where repositories do.
final class NoticeCell: NSStackView {
  private let notice: Notice
  private let field = label(size: 12, color: .secondaryLabelColor)

  init(_ notice: Notice) {
    self.notice = notice
    super.init(frame: .zero)
    field.lineBreakMode = .byTruncatingTail
    field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    field.setContentHuggingPriority(.init(1), for: .horizontal)
    refresh()
    // Quieter than titles: the icon carries the alarm.
    let icon = symbol(notice.tone.symbol, size: 12, color: notice.tone.color)
    for view in [leadSlot(icon), field] { addArrangedSubview(view) }
    configure(self, spacing: 12)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  func refresh() {
    field.show(notice)
  }
}

/// A borderless, link-colored button for an action inside a row.
final class LinkButton: NSButton {
  private let run: () -> Void

  init(_ title: String, symbol name: String? = nil, run: @escaping () -> Void) {
    self.run = run
    super.init(frame: .zero)
    isBordered = false
    attributedTitle = NSAttributedString(
      string: title, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.linkColor])
    if let name {
      image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
      imagePosition = .imageTrailing
      contentTintColor = .linkColor
    }
    target = self
    action = #selector(clicked)
    setContentCompressionResistancePriority(.required, for: .horizontal)
    setContentHuggingPriority(.required, for: .horizontal)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  override func resetCursorRects() {
    addCursorRect(bounds, cursor: .pointingHand)
  }

  @objc private func clicked() { run() }
}

/// An RFC 3339 timestamp in the reader's own zone and format.
private func localTime(_ timestamp: String) -> String {
  date(timestamp)?.formatted(date: .abbreviated, time: .shortened) ?? timestamp
}

/// One item: check dot, kind icon, repository, title with its state and
/// review route, author and age.
final class ItemCell: NSStackView {
  let age = label(size: 12, color: .secondaryLabelColor)
  /// The repository column's width, changed in place as the window resizes.
  let repoWidth: NSLayoutConstraint

  init(_ item: Item, check: CheckView?, repo: NSAttributedString, repoWidth: CGFloat, viewer: String?) {
    let repoField = NSTextField(labelWithAttributedString: repo)
    self.repoWidth = repoField.widthAnchor.constraint(equalToConstant: repoWidth)
    super.init(frame: .zero)
    let kind = Kind(item)
    let icon = symbol(
      item.isPullRequest ? "arrow.triangle.pull" : "smallcircle.filled.circle", size: 13,
      // Everything listed is open; the dot and the pill carry the color.
      color: item.isDraft ? .tertiaryLabelColor : .secondaryLabelColor)
    icon.widthAnchor.constraint(equalToConstant: 16).isActive = true

    repoField.usesSingleLineMode = true
    repoField.cell?.wraps = false
    repoField.lineBreakMode = .byTruncatingMiddle
    self.repoWidth.isActive = true

    let title = label(size: 13, color: item.isDraft ? .secondaryLabelColor : .labelColor)
    title.stringValue = item.title
    title.lineBreakMode = .byTruncatingTail
    title.setContentCompressionResistancePriority(.init(250), for: .horizontal)
    // A long title keeps some room before the route gives up its own.
    let titleFloor = title.widthAnchor.constraint(
      greaterThanOrEqualToConstant: min(title.fittingSize.width, 220))
    titleFloor.priority = .init(800)
    titleFloor.isActive = true
    var titleViews: [NSView] = [title]
    if let badge = kind.badge { titleViews.append(Pill(badge, color: kind.badgeColor)) }
    if let route = routeLabel(item.reviewRoute) {
      let routeField = WholeLabel(route)
      // Gives way before the title does.
      routeField.setContentCompressionResistancePriority(.init(249), for: .horizontal)
      titleViews.append(routeField)
    }
    let titles = NSStackView(views: titleViews)
    titles.alignment = .centerY
    titles.spacing = 8
    // The title takes whatever width the fixed columns leave.
    titles.setContentHuggingPriority(.init(1), for: .horizontal)
    titles.setContentCompressionResistancePriority(.init(1), for: .horizontal)
    let spacer = NSView()
    spacer.setContentHuggingPriority(.init(1), for: .horizontal)
    titles.addArrangedSubview(spacer)

    // Your own login says nothing in a list of your own PRs.
    let author = fixed(label(size: 12, color: .secondaryLabelColor), width: authorWidth)
    author.stringValue = item.author == viewer ? "" : item.author
    fixed(age, width: ageWidth).alignment = .right
    age.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    age.stringValue = GhInboxCore.age(item.updatedAt, now: Date()) ?? ""

    let lead = NSStackView(views: [CheckMark(Dot(check)), icon])
    lead.spacing = 8
    for view in [lead, repoField, titles, author, age] { addArrangedSubview(view) }
    configure(self, spacing: 12)
    setCustomSpacing(14, after: repoField)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }
}

/// Secondary text shown whole or not at all: "request s…" says nothing.
final class WholeLabel: NSTextField {
  convenience init(_ text: String) {
    self.init(labelWithString: text)
    font = .systemFont(ofSize: 12)
    textColor = .secondaryLabelColor
    lineBreakMode = .byClipping
  }

  override func setFrameSize(_ size: NSSize) {
    super.setFrameSize(size)
    // Fading, not hiding: a hidden view would leave the stack and relayout.
    alphaValue = size.width + 0.5 < intrinsicContentSize.width ? 0 : 1
  }
}

/// A rounded, tinted label for an item's state.
final class Pill: NSView {
  init(_ text: String, color: NSColor) {
    super.init(frame: .zero)
    let field = label(size: 10.5, weight: .medium, color: readable(color))
    field.stringValue = text
    field.setContentCompressionResistancePriority(.required, for: .horizontal)
    field.translatesAutoresizingMaskIntoConstraints = false
    addSubview(field)
    wantsLayer = true
    layer?.cornerRadius = 4
    self.color = color
    NSLayoutConstraint.activate([
      field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
      field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
      field.topAnchor.constraint(equalTo: topAnchor, constant: 1.5),
      field.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1.5),
    ])
    setContentCompressionResistancePriority(.required, for: .horizontal)
    setContentHuggingPriority(.required, for: .horizontal)
  }

  private var color: NSColor = .clear

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  override func updateLayer() {
    // Resolved here so the tint follows light and dark mode.
    layer?.backgroundColor = color.withAlphaComponent(0.14).cgColor
  }

  override var wantsUpdateLayer: Bool { true }
}

/// A section's item count, as a small capsule.
final class CountBadge: NSView {
  private let dim: Bool

  init(_ count: Int, dim: Bool) {
    self.dim = dim
    super.init(frame: .zero)
    let field = label(size: 11, weight: .medium, color: dim ? .tertiaryLabelColor : .secondaryLabelColor)
    field.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
    field.stringValue = String(count)
    field.translatesAutoresizingMaskIntoConstraints = false
    addSubview(field)
    wantsLayer = true
    NSLayoutConstraint.activate([
      field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
      field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
      field.topAnchor.constraint(equalTo: topAnchor, constant: 1),
      field.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
      widthAnchor.constraint(greaterThanOrEqualTo: heightAnchor),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  override var wantsUpdateLayer: Bool { true }

  override func updateLayer() {
    layer?.cornerRadius = bounds.height / 2
    layer?.backgroundColor = (dim ? NSColor.quinaryLabel : NSColor.quaternaryLabelColor).cgColor
  }

  override func layout() {
    super.layout()
    needsDisplay = true
  }
}

@MainActor
private func configure(_ stack: NSStackView, spacing: CGFloat) {
  stack.spacing = spacing
  stack.distribution = .fill
  stack.alignment = .centerY
  stack.edgeInsets = NSEdgeInsets(top: 0, left: inset, bottom: 0, right: inset)
  for view in stack.arrangedSubviews { view.setContentHuggingPriority(.required, for: .vertical) }
}

@MainActor
private func cells(_ views: [NSView], spacing: CGFloat = 12) -> NSStackView {
  let stack = NSStackView(views: views)
  configure(stack, spacing: spacing)
  return stack
}

/// A notice or "Load more" row: its icon under the kind icons, its text
/// starting where repositories do.
@MainActor
private func lead(_ icon: NSImageView, _ views: [NSView]) -> NSView {
  cells([leadSlot(icon)] + views)
}

/// A row icon under the kind icons, so text after it starts where
/// repositories do.
@MainActor
private func leadSlot(_ icon: NSImageView) -> NSView {
  let slot = NSStackView(views: [icon])
  slot.alignment = .centerY
  slot.edgeInsets = NSEdgeInsets(top: 0, left: 18, bottom: 0, right: 0)
  slot.widthAnchor.constraint(equalToConstant: leadWidth).isActive = true
  return slot
}

/// A tooltip read when it shows, so text that moves with time is never
/// reassigned: reassigning closes a tooltip that is open.
@MainActor
final class LiveToolTip: NSObject, NSViewToolTipOwner {
  private let text: () -> String
  private var covered: NSRect?

  init(_ text: @escaping () -> String) {
    self.text = text
  }

  func view(
    _ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint,
    userData data: UnsafeMutableRawPointer?
  ) -> String {
    text()
  }

  /// Covers `view`'s bounds; called again whenever its size changes.
  func attach(to view: NSView) {
    // Re-adding the same rect would close a tooltip that is open.
    guard view.bounds != covered else { return }
    covered = view.bounds
    view.removeAllToolTips()
    view.addToolTip(view.bounds, owner: self, userData: nil)
  }
}

extension Notice {
  var rowToolTip: String { "\(text(now: .now))\n\nClick to copy." }
}

@MainActor
func symbol(_ name: String, size: CGFloat, color: NSColor) -> NSImageView {
  let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
    .withSymbolConfiguration(.init(pointSize: size, weight: .medium))
  let view = NSImageView(image: image ?? NSImage())
  view.contentTintColor = color
  view.setContentHuggingPriority(.required, for: .horizontal)
  view.setContentCompressionResistancePriority(.required, for: .horizontal)
  return view
}

@MainActor
@discardableResult
private func fixed(_ field: NSTextField, width: CGFloat) -> NSTextField {
  field.lineBreakMode = .byTruncatingTail
  field.widthAnchor.constraint(equalToConstant: width).isActive = true
  return field
}

extension Kind {
  /// Approved and changes-requested pills are colored; the rest are neutral.
  var badgeColor: NSColor {
    switch self {
    case .approved: .systemGreen
    case .changes: .systemOrange
    case .draft, .issue, .pullRequest: .secondaryLabelColor
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
  var symbol: String {
    switch self {
    case .passing: "checkmark.circle.fill"
    case .failing: "xmark.circle.fill"
    case .pending: "clock.fill"
    }
  }

  var tip: String {
    switch self {
    case .passing: "Checks passing"
    case .failing: "Checks failing"
    case .pending: "Checks pending"
    }
  }
}

/// A PR's check state as a symbol, so it never rests on color alone.
final class CheckMark: NSImageView {
  init(_ dot: Dot) {
    super.init(frame: .zero)
    let (name, color, tip): (String?, NSColor, String?) =
      switch dot {
      case .none: (nil, .clear, nil)
      case .filled(let checks, let dim):
        (
          checks.symbol, checks.color.withAlphaComponent(dim ? 0.45 : 1),
          checks.tip + (dim ? " (recheck failed)" : "")
        )
      case .loading: ("circle.dotted", .tertiaryLabelColor, "Loading checks")
      case .failed: ("exclamationmark.circle", .secondaryLabelColor, "Couldn't load checks")
      }
    image = name.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: tip) }?
      .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
    contentTintColor = color
    toolTip = tip
    widthAnchor.constraint(equalToConstant: 14).isActive = true
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }
}

/// Tinted text a pill can carry: darker in light mode, where the system
/// tints are too pale on their own wash.
@MainActor
private func readable(_ color: NSColor) -> NSColor {
  NSColor(name: nil) { appearance in
    var resolved = color
    appearance.performAsCurrentDrawingAppearance { resolved = color.usingColorSpace(.sRGB) ?? color }
    let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    return dark ? resolved : resolved.blended(withFraction: 0.3, of: .black) ?? resolved
  }
}

/// Tracks the one row under the pointer. Per-row tracking areas miss exits
/// when rows scroll out from under a still pointer, leaving several lit.
final class HoverTable: NSTableView {
  /// For capturing the window unattended, when nothing can point at it:
  /// this row draws as hovered.
  private let forcedHover = ProcessInfo.processInfo.environment["GH_INBOX_HOVER_ROW"].flatMap { Int($0) }

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
        rect: .zero,
        options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
        owner: self))
  }

  override func mouseEntered(with event: NSEvent) { updateHover() }
  override func mouseMoved(with event: NSEvent) { updateHover() }
  override func mouseExited(with event: NSEvent) {
    hoveredRow = -1
    NSCursor.arrow.set()
  }
  override func cursorUpdate(with event: NSEvent) { updateHover() }

  /// Recomputes the hovered row from the pointer's current position.
  @objc func updateHover() {
    if let forcedHover {
      hoveredRow = forcedHover
      return
    }
    guard let window, window.isKeyWindow else {
      hoveredRow = -1
      return
    }
    let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
    guard visibleRect.contains(point) else {
      // The pointer is elsewhere, whose cursor isn't the list's to set.
      hoveredRow = -1
      return
    }
    hoveredRow = rowUnderPins(point)
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

  /// The row at `point`, counting a heading pinned over the top of the list
  /// as covering the row scrolled beneath it.
  func rowUnderPins(_ point: NSPoint) -> Int {
    let hit = row(at: point)
    let top = rows(in: visibleRect).location
    guard point.y < visibleRect.minY + rowHeight, let heading = pinnedHeading(top) else { return hit }
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
  var liveToolTip: LiveToolTip? {
    didSet { liveToolTip?.attach(to: self) }
  }
  var clickable = false
  var heading = false
  /// A rule above the heading, for every section but the first.
  var ruled = false
  var hovering = false {
    didSet { if hovering != oldValue { needsDisplay = true } }
  }

  override var isFloating: Bool {
    didSet { needsDisplay = true }
  }

  override func setFrameSize(_ size: NSSize) {
    super.setFrameSize(size)
    liveToolTip?.attach(to: self)
  }

  override func drawBackground(in dirtyRect: NSRect) {
    if heading {
      NSColor.controlBackgroundColor.setFill()
      bounds.fill()
      NSColor.labelColor.withAlphaComponent(0.04).setFill()
      bounds.fill()
    }
    if hovering && clickable {
      // A wash of the text color: dark on light, light on dark, and never
      // so strong it fights the row's own text.
      NSColor.labelColor.withAlphaComponent(0.07).setFill()
      NSBezierPath(roundedRect: bounds.insetBy(dx: 8, dy: 1), xRadius: 6, yRadius: 6).fill()
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
}
