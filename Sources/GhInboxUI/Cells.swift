import AppKit
import GhInboxCore

/// A list cell drawn from one `RowModel`, laid out by hand: each row kind
/// has a fixed height, so each cell places its parts in `layout()`.
/// Cells are reused; `configure` changes only what the model changed.
@MainActor
class RowCell: NSTableCellView {
  /// The age column's width, which fits the widest age in the list.
  var ageColumn = Metrics.ageWidth {
    didSet { if ageColumn != oldValue { needsLayout = true } }
  }

  override init(frame: NSRect) {
    super.init(frame: frame)
    setAccessibilityElement(true)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }

  func configure(_ row: RowModel, onLoadMore: @escaping (Int) -> Void) {}

  static func make(for row: RowModel) -> RowCell {
    switch row.content {
    case .heading: HeadingCell()
    case .notice: NoticeCell()
    case .item: ItemCell()
    case .cutOff: CutOffCell()
    }
  }

  static func identifier(for row: RowModel) -> NSUserInterfaceItemIdentifier {
    switch row.content {
    case .heading: .init("heading")
    case .notice: .init("notice")
    case .item: .init("item")
    case .cutOff: .init("cutOff")
    }
  }
}

extension NSTextField {
  /// Assigns only on change, so an unchanged field isn't redrawn.
  func show(_ text: String) {
    if stringValue != text { stringValue = text }
  }
}

final class HeadingCell: RowCell {
  private let name = label(size: 13, weight: .semibold)
  private let badge = CountBadge()
  private let spinner = NSProgressIndicator()
  private let failed = symbol("exclamationmark.circle.fill", size: 12, color: .systemRed)
  private let unknown = label(size: 12, color: .tertiaryLabelColor)
  private var mark: HeadingMark?

  override init(frame: NSRect) {
    super.init(frame: frame)
    spinner.style = .spinning
    spinner.controlSize = .small
    spinner.isDisplayedWhenStopped = false
    failed.toolTip = "This section couldn't load"
    unknown.stringValue = "—"
    for view in [name, badge, spinner, failed, unknown] { addSubview(view) }
    setAccessibilityRole(.staticText)
  }

  override func configure(_ row: RowModel, onLoadMore: @escaping (Int) -> Void) {
    guard case .heading(let heading) = row.content else { return }
    name.show(heading.name)
    // An empty section stays as a dimmed heading: "nothing waiting" is
    // worth seeing, a row saying so is not.
    name.textColor = heading.mark == .count(0, dim: true) ? .secondaryLabelColor : .labelColor
    let spoken =
      switch heading.mark {
      case .count(let count, _): "\(heading.name), \(count)"
      case .loading: "\(heading.name), loading"
      case .failed: "\(heading.name), couldn't load"
      case .unknown: heading.name
      }
    setAccessibilityLabel(spoken)
    // A reused cell may get another section's name, so the mark moves.
    needsLayout = true
    guard heading.mark != mark else { return }
    mark = heading.mark
    badge.isHidden = true
    failed.isHidden = true
    unknown.isHidden = true
    spinner.stopAnimation(nil)
    switch heading.mark {
    case .count(let count, let dim):
      badge.show(count, dim: dim)
      badge.isHidden = false
    case .loading: spinner.startAnimation(nil)
    case .failed: failed.isHidden = false
    case .unknown: unknown.isHidden = false
    }
  }

  override func layout() {
    super.layout()
    let text = place(name, x: Metrics.inset)
    let x = text.maxX + Metrics.iconGap
    // A stopped spinner draws nothing, so it needs no hiding.
    for view in [badge, spinner, failed, unknown] where !view.isHidden {
      place(view, x: x)
    }
  }
}

final class NoticeCell: RowCell {
  private let icon = NSImageView()
  private let field = label(size: 12, color: .secondaryLabelColor)
  private var tone: Tone?

  override init(frame: NSRect) {
    super.init(frame: frame)
    addSubview(icon)
    addSubview(field)
  }

  override func configure(_ row: RowModel, onLoadMore: @escaping (Int) -> Void) {
    guard case .notice(let notice) = row.content else { return }
    field.show(notice.text)
    setAccessibilityLabel(notice.text)
    if notice.tone != tone {
      tone = notice.tone
      // Quieter than titles: the icon carries the alarm.
      icon.image = symbolImage(notice.tone.symbol, size: 12)
      icon.contentTintColor = notice.tone.color
      needsLayout = true
    }
  }

  override func layout() {
    super.layout()
    place(icon, x: Metrics.inset + Metrics.leadIconOffset)
    let x = Metrics.inset + Metrics.leadWidth + Metrics.columnGap
    place(field, x: x, width: bounds.width - Metrics.inset - x)
  }
}

/// "Load more" while the section can grow, what the page holds, and the
/// full search for everything it can't.
final class CutOffCell: RowCell {
  private let icon = symbol("ellipsis.circle", size: 12, color: .tertiaryLabelColor)
  private let more = LinkButton("")
  private let loading = label(size: 12, color: .secondaryLabelColor)
  private let note = label(size: 12, color: .secondaryLabelColor)
  private let open = LinkButton("Open on GitHub", symbol: "arrow.up.right")
  private var url = ""

  override init(frame: NSRect) {
    super.init(frame: frame)
    loading.stringValue = "Loading…"
    for view in [icon, more, loading, note, open] { addSubview(view) }
    open.run = { [weak self] in
      if let link = self.flatMap({ URL(string: $0.url) }) { NSWorkspace.shared.open(link) }
    }
    setAccessibilityElement(false)
  }

  override func configure(_ row: RowModel, onLoadMore: @escaping (Int) -> Void) {
    guard case .cutOff(let cut) = row.content else { return }
    url = cut.url
    note.show(cut.note)
    more.run = { onLoadMore(cut.section) }
    switch cut.more {
    case .button(let title):
      more.setLinkTitle(title)
      more.isHidden = false
      loading.isHidden = true
    case .loading:
      more.isHidden = true
      loading.isHidden = false
    case .none:
      more.isHidden = true
      loading.isHidden = true
    }
    needsLayout = true
  }

  override func layout() {
    super.layout()
    place(icon, x: Metrics.inset + Metrics.leadIconOffset)
    var x = Metrics.inset + Metrics.leadWidth + Metrics.columnGap
    for view in [more, loading] where !view.isHidden {
      x = place(view, x: x).maxX + Metrics.columnGap
    }
    let openWidth = open.naturalSize.width
    let room = bounds.width - Metrics.inset - openWidth - Metrics.columnGap - x
    x = place(note, x: x, width: min(note.naturalSize.width, room)).maxX + Metrics.columnGap
    place(open, x: x)
  }
}

/// One item, on two lines: the check symbol, kind icon, title with its
/// state and age; under the title, the repository and number, the author
/// and the review route.
final class ItemCell: RowCell {
  private let check = CheckMark()
  private let kindIcon = NSImageView()
  private let title = label(size: 13)
  private let pill = Pill()
  private let age = label(size: 12, color: .secondaryLabelColor)
  private let repo = NSTextField(labelWithString: "")
  private let author = label(size: 12, color: .secondaryLabelColor)
  private let route = label(size: 12, color: .secondaryLabelColor)
  private var shown: ItemRow?

  override init(frame: NSRect) {
    super.init(frame: frame)
    repo.usesSingleLineMode = true
    repo.lineBreakMode = .byTruncatingMiddle
    repo.cell?.wraps = false
    age.font = Metrics.ageFont
    age.alignment = .right
    for view in [check, kindIcon, title, pill, age, repo, author, route] { addSubview(view) }
  }

  override func configure(_ row: RowModel, onLoadMore: @escaping (Int) -> Void) {
    guard case .item(let item) = row.content, item != shown else { return }
    let old = shown
    shown = item
    setAccessibilityLabel(item.accessibilityLabel)
    check.show(item.dot)
    if old?.kind != item.kind || old?.showsBadge != item.showsBadge {
      kindIcon.image = symbolImage(
        item.kind == .issue ? "smallcircle.filled.circle" : "arrow.triangle.pull", size: 13)
      // Everything listed is open; the check and the pill carry the color.
      kindIcon.contentTintColor = item.kind == .draft ? .tertiaryLabelColor : .secondaryLabelColor
      title.textColor = item.kind == .draft ? .secondaryLabelColor : .labelColor
      pill.show(item.showsBadge ? item.kind.badge : nil, color: item.kind.badgeColor)
    }
    if old?.owner != item.owner || old?.repo != item.repo || old?.number != item.number {
      repo.attributedStringValue = repoText(item)
    }
    title.show(item.title)
    age.show(item.age)
    author.show(item.author.isEmpty ? "" : "· \(item.author)")
    route.show(item.route.map { "· \($0)" } ?? "")
    needsLayout = true
  }

  /// "owner/" (only when several owners show), the name, then the number;
  /// the middle goes first, so the number survives.
  private func repoText(_ item: ItemRow) -> NSAttributedString {
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byTruncatingMiddle
    let text = NSMutableAttributedString()
    func add(_ part: String, _ color: NSColor) {
      text.append(
        NSAttributedString(
          string: part,
          attributes: [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: color, .paragraphStyle: paragraph,
          ]))
    }
    if let owner = item.owner { add("\(owner)/", .tertiaryLabelColor) }
    add(item.repo, .secondaryLabelColor)
    add(" #\(item.number)", .tertiaryLabelColor)
    return text
  }

  override func layout() {
    super.layout()
    let top = bounds.height / 2 - Metrics.itemLineOffset
    let bottom = bounds.height / 2 + Metrics.itemLineOffset
    place(check, x: Metrics.inset, width: Metrics.checkWidth, centerY: top)
    place(
      kindIcon, x: Metrics.inset + Metrics.checkWidth + Metrics.iconGap, width: Metrics.kindWidth,
      centerY: top)
    let textX = Metrics.inset + Metrics.leadWidth + Metrics.columnGap
    let ageX = bounds.width - Metrics.inset - ageColumn
    place(age, x: ageX, width: ageColumn, centerY: top)

    // The title gives way; the pill always shows.
    let titleRoom = ageX - Metrics.columnGap - textX
    let pillWidth = pill.isHidden ? 0 : Metrics.titleGap + pill.naturalSize.width
    let titleEnd = place(
      title, x: textX, width: min(title.naturalSize.width, titleRoom - pillWidth), centerY: top
    ).maxX
    if !pill.isHidden { place(pill, x: titleEnd + Metrics.titleGap, centerY: top) }

    // The repository and number always show, shortened in the middle; the
    // route, then the author, drop out whole rather than squeeze it.
    let metaRoom = bounds.width - Metrics.inset - textX
    func width(_ field: NSTextField) -> CGFloat {
      field.stringValue.isEmpty ? 0 : Metrics.metaGap + field.naturalSize.width
    }
    let repoWidth = repo.naturalSize.width
    var (authorWidth, routeWidth) = (width(author), width(route))
    if repoWidth + authorWidth + routeWidth > metaRoom { routeWidth = 0 }
    if repoWidth + authorWidth > metaRoom { authorWidth = 0 }
    author.isHidden = authorWidth == 0
    route.isHidden = routeWidth == 0
    var x = place(
      repo, x: textX, width: min(repoWidth, metaRoom - authorWidth - routeWidth), centerY: bottom
    ).maxX
    if !author.isHidden { x = place(author, x: x + Metrics.metaGap, centerY: bottom).maxX }
    if !route.isHidden { place(route, x: x + Metrics.metaGap, centerY: bottom) }
  }
}

/// A borderless, link-colored button for an action inside a row.
final class LinkButton: NSButton {
  var run: () -> Void = {}

  init(_ title: String, symbol name: String? = nil) {
    super.init(frame: .zero)
    isBordered = false
    setLinkTitle(title)
    if let name {
      image = symbolImage(name, size: 10, weight: .semibold)
      imagePosition = .imageTrailing
      contentTintColor = .linkColor
    }
    target = self
    action = #selector(clicked)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  func setLinkTitle(_ text: String) {
    guard text != attributedTitle.string else { return }
    attributedTitle = NSAttributedString(
      string: text, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.linkColor])
  }

  override func resetCursorRects() {
    addCursorRect(bounds, cursor: .pointingHand)
  }

  @objc private func clicked() { run() }
}

/// A rounded, tinted label for an item's state.
final class Pill: NSView {
  private let field = label(size: 10.5, weight: .medium)
  private var color: NSColor = .clear
  private static let padding = NSSize(width: 6, height: 1.5)

  override init(frame: NSRect) {
    super.init(frame: frame)
    addSubview(field)
    wantsLayer = true
    layer?.cornerRadius = 4
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  func show(_ text: String?, color: NSColor) {
    isHidden = text == nil
    field.show(text ?? "")
    field.textColor = readable(color)
    self.color = color
    needsDisplay = true
  }

  override var intrinsicContentSize: NSSize {
    let text = field.naturalSize
    return NSSize(width: text.width + 2 * Self.padding.width, height: text.height + 2 * Self.padding.height)
  }

  override func layout() {
    super.layout()
    // Not `insetBy`, which turns a rect too small to inset into `.null`,
    // whose infinite origin AppKit rejects.
    let text = NSRect(
      x: Self.padding.width, y: Self.padding.height, width: max(0, bounds.width - 2 * Self.padding.width),
      height: max(0, bounds.height - 2 * Self.padding.height))
    field.frame = field.frame(forAlignmentRect: text)
  }

  override var wantsUpdateLayer: Bool { true }

  override func updateLayer() {
    // Resolved here so the tint follows light and dark mode.
    layer?.backgroundColor = color.withAlphaComponent(0.14).cgColor
  }
}

/// A section's item count, as a small capsule.
final class CountBadge: NSView {
  private let field = label(size: 11, weight: .medium)
  private var dim = false
  private static let padding = NSSize(width: 7, height: 1)

  override init(frame: NSRect) {
    super.init(frame: frame)
    field.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
    addSubview(field)
    wantsLayer = true
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  func show(_ count: Int, dim: Bool) {
    field.show(String(count))
    field.textColor = dim ? .tertiaryLabelColor : .secondaryLabelColor
    self.dim = dim
    needsDisplay = true
  }

  override var intrinsicContentSize: NSSize {
    let text = field.naturalSize
    let height = text.height + 2 * Self.padding.height
    return NSSize(width: max(height, text.width + 2 * Self.padding.width), height: height)
  }

  override func layout() {
    super.layout()
    let text = field.naturalSize
    field.frame = field.frame(
      forAlignmentRect: NSRect(
        x: ((bounds.width - text.width) / 2).rounded(), y: Self.padding.height, width: text.width,
        height: text.height))
  }

  override var wantsUpdateLayer: Bool { true }

  override func updateLayer() {
    layer?.cornerRadius = bounds.height / 2
    layer?.backgroundColor = (dim ? NSColor.quinaryLabel : NSColor.quaternaryLabelColor).cgColor
  }
}

/// A PR's check state as a symbol, so it never rests on color alone.
final class CheckMark: NSImageView {
  private var dot: Dot?

  func show(_ dot: Dot) {
    guard dot != self.dot else { return }
    self.dot = dot
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
    image = name.flatMap { symbolImage($0, size: 11, weight: .semibold) }
    contentTintColor = color
    toolTip = tip
  }
}
