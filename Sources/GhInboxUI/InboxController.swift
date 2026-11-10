import AppKit
import GhInboxCore

/// How often the scheduler checks whether a refresh is due, and ages re-render.
private let tick: TimeInterval = 10

private let controlsItem = NSToolbarItem.Identifier("controls")
private let refreshItem = NSToolbarItem.Identifier("refresh")

private let ownerTabs: [(OwnerFilter, String)] = [
  (.all, "All"), (.personal, "Personal"), (.organization, "Org"),
]

public final class InboxController: NSWindowController, NSWindowDelegate, NSToolbarDelegate,
  NSMenuItemValidation
{
  /// How many times the window has redrawn from new state, so a host can
  /// tell when results stop arriving.
  public private(set) var renders = 0
  private let model: InboxModel
  private var inbox: Inbox { model.inbox }
  private let now: @MainActor () -> Date
  private let timeZone: TimeZone
  private let locale: Locale
  private var presence = Presence.background
  private var lastAttempt: Instant?
  private var timer: Timer?

  private let tabs = NSSegmentedControl(
    labels: ownerTabs.map(\.1), trackingMode: .selectOne, target: nil, action: nil)
  private let directOnly = NSButton(checkboxWithTitle: "Direct only", target: nil, action: nil)
  private let spinner = NSProgressIndicator()
  private let banners = BannerList()
  private let list = InboxList()
  private let allClear = NSStackView()
  private lazy var unavailable = UnavailableView { [weak self] in self?.refresh(nil) }

  /// `now` is the wall clock ages are read from, and `timeZone` and
  /// `locale` how dates read; `restoresFrame` false leaves the saved window
  /// frame alone, for windows that are never shown; `github` is where
  /// requests go.
  public init(
    now: @escaping @MainActor () -> Date = Date.init, timeZone: TimeZone = .current,
    locale: Locale = .current,
    restoresFrame: Bool = true, github: GitHub = .live()
  ) {
    model = InboxModel(github: github)
    self.now = now
    self.timeZone = timeZone
    self.locale = locale
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: Metrics.windowSize),
      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    window.title = "gh-inbox"
    window.toolbarStyle = .unified
    window.contentMinSize = Metrics.windowMinSize
    // Closing only orders the window out, so the Dock icon or ⌘0 brings it back.
    window.isReleasedWhenClosed = false
    // Window > Inbox stands in for it, and stays while the window is closed.
    window.isExcludedFromWindowsMenu = true
    super.init(window: window)
    model.changed = { [weak self] in self?.render() }
    window.delegate = self
    layout(in: window)
    if restoresFrame {
      // Centered only the first time; after that the saved frame is restored.
      if !window.setFrameUsingName("inbox") { window.center() }
      window.setFrameAutosaveName("inbox")
    }
    list.onLoadMore = { [weak self] section in self?.loadMore(section) }
    refresh(nil)
    timer = Timer.scheduledTimer(withTimeInterval: tick, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, self.presence != .closed else { return }
        self.refreshIfDue(.tick)
        // Ages move without new data; only the rows they changed update.
        self.render()
      }
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  /// Draws list row `hoveredRow` (headings count) as hovered, selects
  /// `selectedRow` and scrolls the list down `scroll` points, for rendering
  /// states no pointer or keyboard is there to make.
  public func stage(hoveredRow: Int?, selectedRow: Int? = nil, scroll: CGFloat?) {
    list.stage(hoveredRow: hoveredRow, selectedRow: selectedRow, scroll: scroll)
  }

  /// The whole window, title bar included, drawn offscreen.
  public func snapshot() -> NSBitmapImageRep? {
    guard let frame = window?.contentView?.superview else { return nil }
    frame.layoutSubtreeIfNeeded()
    guard let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { return nil }
    frame.cacheDisplay(in: frame.bounds, to: rep)
    return rep
  }

  private func layout(in window: NSWindow) {
    tabs.target = self
    tabs.action = #selector(chooseTab(_:))
    directOnly.target = self
    directOnly.action = #selector(toggleDirectOnly(_:))
    spinner.style = .spinning
    spinner.controlSize = .small
    spinner.isDisplayedWhenStopped = false

    let toolbar = NSToolbar(identifier: "inbox")
    toolbar.delegate = self
    toolbar.displayMode = .iconOnly
    toolbar.allowsUserCustomization = false
    window.toolbar = toolbar

    let check = symbol("checkmark.circle", size: 28, color: .tertiaryLabelColor)
    check.symbolConfiguration = .init(pointSize: 28, weight: .light)
    let message = label(size: 13, color: .secondaryLabelColor)
    message.stringValue = "Nothing open for you"
    allClear.setViews([check, message], in: .center)
    allClear.orientation = .vertical
    allClear.spacing = 8
    allClear.isHidden = true
    window.initialFirstResponder = list.keyView
    window.contentView = RootView(
      banners: banners, list: list.scrollView, allClear: allClear, unavailable: unavailable)
  }

  // MARK: Refreshing

  private func refreshIfDue(_ trigger: Trigger) {
    let since = lastAttempt.map { ContinuousClock.now - $0 }
    if due(trigger, presence: presence, sinceAttempt: since) { refresh(nil) }
  }

  /// Keeps the current rows on screen until the new ones arrive.
  @objc public func refresh(_ sender: Any?) {
    if model.refresh() > 0 { lastAttempt = .now }
  }

  private func loadMore(_ section: Int) {
    model.loadMore(section)
  }

  // MARK: Controls

  @objc private func chooseTab(_ sender: NSSegmentedControl) {
    model.setOwnerFilter(ownerTabs[sender.selectedSegment].0)
  }

  @objc private func toggleDirectOnly(_ sender: NSButton) {
    model.setReviewDirectOnly(sender.state == .on)
  }

  // MARK: Menu

  /// The owner tabs, in order, as menu titles; a menu item's tag picks one
  /// for `showOwnerTab(_:)`.
  public static let ownerTabTitles = ownerTabs.map(\.1)

  @objc public func showOwnerTab(_ sender: NSMenuItem) {
    guard ownerTabs.indices.contains(sender.tag) else { return }
    model.setOwnerFilter(ownerTabs[sender.tag].0)
  }

  @objc public func toggleReviewDirectOnly(_ sender: Any?) {
    model.setReviewDirectOnly(!inbox.reviewDirectOnly)
  }

  /// Ages kept still while the window was closed, so they catch up first.
  public override func showWindow(_ sender: Any?) {
    if presence == .closed { presence = .background }
    render()
    super.showWindow(sender)
  }

  /// The filters act on what the window shows, so they wait for it, and
  /// for the toolbar control each mirrors.
  public func validateMenuItem(_ item: NSMenuItem) -> Bool {
    switch item.action {
    case #selector(showOwnerTab(_:)):
      guard ownerTabs.indices.contains(item.tag) else { return false }
      item.state = ownerTabs[item.tag].0 == inbox.ownerFilter ? .on : .off
      return presence != .closed && inbox.showOwnerTabs
    case #selector(toggleReviewDirectOnly(_:)):
      item.state = inbox.reviewDirectOnly ? .on : .off
      return presence != .closed && inbox.showDirectOnly
    default:
      return true
    }
  }

  // MARK: Toolbar

  public func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    [.flexibleSpace, controlsItem, refreshItem]
  }

  public func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    toolbarDefaultItemIdentifiers(toolbar)
  }

  public func toolbar(
    _ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
    willBeInsertedIntoToolbar flag: Bool
  ) -> NSToolbarItem? {
    let item = NSToolbarItem(itemIdentifier: identifier)
    switch identifier {
    case controlsItem:
      let controls = NSStackView(views: [tabs, directOnly, spinner])
      controls.spacing = 12
      // Hidden controls keep their slot, so revealing one never moves another.
      controls.detachesHiddenViews = false
      item.view = controls
    case refreshItem:
      item.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh")
      item.label = "Refresh"
      item.toolTip = "Refresh (⌘R)"
      item.isBordered = true
      item.target = self
      item.action = #selector(refresh(_:))
    default: return nil
    }
    return item
  }

  public func windowDidBecomeKey(_ notification: Notification) {
    presence = .focused
    refreshIfDue(.focus)
  }

  public func windowDidResignKey(_ notification: Notification) {
    if presence == .focused { presence = .background }
  }

  public func windowWillClose(_ notification: Notification) {
    presence = .closed
  }

  // MARK: Rendering

  /// Draws the inbox as of now. Unchanged rows and banners are left alone,
  /// so a render with nothing new changes nothing on screen.
  private func render() {
    renders += 1
    window?.contentView?.needsLayout = true
    let now = Now(date: now(), timeZone: timeZone, locale: locale)
    let shown = rows(inbox, now: now)
    let head = header(inbox, rows: shown, now: now)
    window?.title = head.title
    window?.subtitle = head.summary
    if head.busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    tabs.isHidden = !inbox.showOwnerTabs
    tabs.selectedSegment = ownerTabs.firstIndex { $0.0 == inbox.ownerFilter } ?? 0
    directOnly.isHidden = !inbox.showDirectOnly
    directOnly.state = inbox.reviewDirectOnly ? .on : .off

    // One shared failure before any data is shown once, as a panel.
    let failure = inbox.anyLoaded ? nil : inbox.commonError
    unavailable.isHidden = failure == nil
    banners.isHidden = failure != nil
    if let failure {
      unavailable.show(failure, retrying: retrying(inbox))
      list.show([])
      allClear.isHidden = true
      return
    }
    banners.show(GhInboxCore.banners(inbox, now: now))
    list.show(shown)
    allClear.isHidden = !nothingOpen(inbox)
  }
}

/// The window's content, laid out by hand: banners on top, the list under
/// them, and the panels that sit over the list. Laid out in one pass, so
/// banners wrap at the width they're given, never a width from before.
final class RootView: NSView {
  private let banners: BannerList
  private let list: NSScrollView
  private let allClear: NSView
  private let unavailable: NSView

  init(banners: BannerList, list: NSScrollView, allClear: NSView, unavailable: NSView) {
    (self.banners, self.list, self.allClear, self.unavailable) = (banners, list, allClear, unavailable)
    super.init(frame: .zero)
    for view in [banners, list, unavailable, allClear] { addSubview(view) }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }

  override func layout() {
    super.layout()
    let top = banners.isHidden ? 0 : banners.height(for: bounds.width)
    banners.frame = NSRect(x: 0, y: 0, width: bounds.width, height: top)
    list.frame = NSRect(x: 0, y: top, width: bounds.width, height: bounds.height - top)
    // The error panel sits over the emptied list, so it shares its background.
    unavailable.frame = list.frame
    // Just under the rows, which are only headings when it shows.
    let rows = (list.documentView as? NSTableView)?.numberOfRows ?? 0
    let size = allClear.fittingSize
    allClear.frame = NSRect(
      x: ((bounds.width - size.width) / 2).rounded(),
      y: top + CGFloat(rows) * Metrics.rowHeight + Metrics.allClearGap, width: size.width, height: size.height
    )
  }
}

/// The banners above the list, each kept and reworded in place, so an open
/// tooltip stays open as a banner's age moves.
final class BannerList: NSView {
  private var views: [Banner] = []

  override var isFlipped: Bool { true }

  func show(_ notices: [Notice]) {
    var changed = views.count != notices.count
    while views.count > notices.count { views.removeLast().removeFromSuperview() }
    while views.count < notices.count {
      let banner = Banner()
      views.append(banner)
      addSubview(banner)
    }
    for (banner, notice) in zip(views, notices) { changed = banner.show(notice) || changed }
    if changed { superview?.needsLayout = true }
  }

  func height(for width: CGFloat) -> CGFloat {
    views.reduce(0) { $0 + $1.height(for: width) }
  }

  override func layout() {
    super.layout()
    var y: CGFloat = 0
    for banner in views {
      let height = banner.height(for: bounds.width)
      banner.frame = NSRect(x: 0, y: y, width: bounds.width, height: height)
      y += height
    }
  }
}

/// A full-width notice above the list, tinted by its tone: two lines at
/// most, the rest a hover away, and a click copies it. Not selectable
/// text, which would take the list's arrow keys and keep them.
final class Banner: NSView {
  private let icon = NSImageView()
  private let field = NSTextField(wrappingLabelWithString: "")
  /// Held here: AppKit doesn't retain a tooltip's owner.
  private let toolTipOwner = LiveToolTip()
  private var notice: Notice?

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    field.font = .systemFont(ofSize: 12)
    field.textColor = .labelColor
    // Word wrapping, not tail truncation, which keeps a label to one line.
    field.lineBreakMode = .byWordWrapping
    field.maximumNumberOfLines = Metrics.bannerLines
    field.cell?.truncatesLastVisibleLine = true
    addSubview(icon)
    addSubview(field)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }

  /// Returns whether anything changed.
  func show(_ notice: Notice) -> Bool {
    guard notice != self.notice else { return false }
    if notice.tone != self.notice?.tone {
      icon.image = symbolImage(notice.tone.symbol, size: 13)
      icon.contentTintColor = notice.tone.color
      needsDisplay = true
    }
    self.notice = notice
    field.show(notice.text)
    toolTipOwner.text = "\(notice.text)\n\nClick to copy."
    needsLayout = true
    return true
  }

  /// The text's alignment rect for a banner `width` wide; at most
  /// `Metrics.bannerLines` tall.
  private func textRect(for width: CGFloat) -> NSRect {
    let x = Metrics.bannerPadding.left + icon.naturalSize.width + Metrics.bannerIconGap
    var rect = NSRect(
      x: x, y: Metrics.bannerPadding.top, width: max(0, width - x - Metrics.bannerPadding.right), height: 0)
    let frameWidth = field.frame(forAlignmentRect: rect).width
    let size = field.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: frameWidth, height: 10_000))
    rect.size.height = (size?.height ?? 0).rounded(.up)
    return rect
  }

  func height(for width: CGFloat) -> CGFloat {
    textRect(for: width).height + Metrics.bannerPadding.top + Metrics.bannerPadding.bottom
  }

  override func layout() {
    super.layout()
    // Its top on the first line's, as text and icon read together.
    icon.frame = icon.frame(
      forAlignmentRect: NSRect(
        origin: NSPoint(x: Metrics.bannerPadding.left, y: Metrics.bannerPadding.top), size: icon.naturalSize))
    field.frame = field.frame(forAlignmentRect: textRect(for: bounds.width))
    toolTipOwner.attach(to: self)
  }

  /// The whole banner takes the click, its text included.
  override func hitTest(_ point: NSPoint) -> NSView? {
    frame.contains(point) ? self : nil
  }

  override func mouseDown(with event: NSEvent) {
    guard let notice else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(notice.text, forType: .string)
  }

  override func resetCursorRects() {
    addCursorRect(bounds, cursor: .pointingHand)
  }

  override var wantsUpdateLayer: Bool { true }

  override func updateLayer() {
    layer?.backgroundColor = (notice?.tone.color ?? .clear).withAlphaComponent(0.12).cgColor
  }
}

/// The one error and its hint, centered, when nothing could load.
final class UnavailableView: NSView {
  private let error = label(size: 15, weight: .semibold)
  private let hint = label(size: 13, color: .secondaryLabelColor)
  private let retry: () -> Void
  private let button = NSButton(title: "Try Again", target: nil, action: nil)
  private let stack = NSStackView()

  init(retry: @escaping () -> Void) {
    self.retry = retry
    super.init(frame: .zero)
    let icon = symbol("exclamationmark.icloud", size: 40, color: .tertiaryLabelColor)
    icon.symbolConfiguration = .init(pointSize: 40, weight: .light)
    for field in [error, hint] {
      field.isSelectable = true
      field.alignment = .center
      field.lineBreakMode = .byWordWrapping
      field.maximumNumberOfLines = 0
      field.preferredMaxLayoutWidth = Metrics.panelWidth - 20
    }
    button.target = self
    button.action = #selector(tryAgain)
    stack.setViews([icon, error, hint, button], in: .center)
    stack.setCustomSpacing(18, after: hint)
    stack.orientation = .vertical
    stack.alignment = .centerX
    stack.spacing = 10
    stack.setCustomSpacing(16, after: icon)
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    NSLayoutConstraint.activate([
      stack.centerXAnchor.constraint(equalTo: centerXAnchor),
      stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -Metrics.panelLift),
      stack.widthAnchor.constraint(lessThanOrEqualToConstant: Metrics.panelWidth),
      stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: Metrics.panelMargin),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  @objc private func tryAgain() { retry() }

  /// `retrying` while the sections are fetched again: the old error stays
  /// up until the new answer, so the button says the retry is underway.
  func show(_ failure: GhError, retrying: Bool) {
    button.isEnabled = !retrying
    button.title = retrying ? "Trying Again…" : "Try Again"
    error.stringValue = failure.description
    hint.stringValue = failure.hint ?? ""
    hint.isHidden = failure.hint == nil
    // A hidden hint leaves the stack, and its spacing with it.
    stack.setCustomSpacing(failure.hint == nil ? 18 : 10, after: error)
  }
}
