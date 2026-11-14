import AppKit
import GhInboxCore

/// How often the scheduler checks whether a refresh is due, and ages re-render.
private let tick: TimeInterval = 10

private let tabsItem = NSToolbarItem.Identifier("tabs")
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
  private lazy var refreshControl = RefreshControl(target: self, action: #selector(refresh(_:)))
  private let banners = BannerList()
  /// Checks for a newer published source; nil for a build that records none.
  private let updater: Updater?
  private let sidebar = Sidebar()
  private let list = InboxList()
  private let allClear = NSStackView()
  private let allClearText = label(size: 13, color: .secondaryLabelColor)
  private let allClearMark = symbol("checkmark.circle", size: 28, color: .tertiaryLabelColor)
  /// The queue the list shows, by section.
  private var queue = 0
  /// Whether the last queue is kept per account, and the account it was
  /// last restored for.
  private let remembersQueue: Bool
  private var restoredFor: Identity?
  private lazy var unavailable = UnavailableView { [weak self] in self?.refresh(nil) }

  /// `now` is the wall clock ages are read from, and `timeZone` and
  /// `locale` how dates read; `remembersQueue` false neither restores nor
  /// saves the last queue; `restoresFrame` false leaves the saved window
  /// frame alone, for windows that are never shown; `github` is where
  /// requests go; `updater` checks for a newer version, none when nil;
  /// `snapshot` is where each finished round is written for scripts, none
  /// when nil.
  public init(
    now: @escaping @MainActor () -> Date = Date.init, timeZone: TimeZone = .current,
    locale: Locale = .current,
    restoresFrame: Bool = true, remembersQueue: Bool = true, github: GitHub = .live(),
    updater: Updater? = .live(), snapshot: URL? = nil
  ) {
    model = InboxModel(github: github)
    if let snapshot {
      // A failed write only leaves the last one in place; the window is unaffected.
      model.settled = { inbox in try? writeSnapshot(inbox, at: now(), to: snapshot) }
    }
    self.updater = updater
    self.remembersQueue = remembersQueue
    self.now = now
    self.timeZone = timeZone
    self.locale = locale
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: Metrics.windowSize),
      // Full-size content lets the sidebar run the window's height under the
      // title bar, as Finder's does; without it Tahoe floats it as a panel.
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered,
      defer: false)
    window.title = "gh-inbox"
    window.toolbarStyle = .unified
    // The title bar over the list takes the list's color with no rule under
    // it, as Tahoe draws it; older systems paint and rule it otherwise.
    window.titlebarAppearsTransparent = true
    window.titlebarSeparatorStyle = .none
    window.contentMinSize = Metrics.windowMinSize
    // Closing only orders the window out, so the Dock icon or ⌘0 brings it back.
    window.isReleasedWhenClosed = false
    // Window > Inbox stands in for it, and stays while the window is closed.
    window.isExcludedFromWindowsMenu = true
    super.init(window: window)
    model.changed = { [weak self] in self?.render() }
    updater?.changed = { [weak self] in self?.render() }
    banners.onUpdate = { [weak self] in self?.confirmUpdate() }
    window.delegate = self
    layout(in: window)
    window.setContentSize(Metrics.windowSize)
    if restoresFrame {
      // Centered only the first time; after that the saved frame is restored.
      if !window.setFrameUsingName("inbox") { window.center() }
      window.setFrameAutosaveName("inbox")
    }
    list.onLoadMore = { [weak self] section in self?.loadMore(section) }
    refresh(nil)
    updater?.checkIfDue()
    timer = Timer.scheduledTimer(withTimeInterval: tick, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, self.presence != .closed else { return }
        self.refreshIfDue(.tick)
        self.updater?.checkIfDue()
        // Ages move without new data; only the rows they changed update.
        self.render()
      }
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  /// Draws list row `hoveredRow` and sidebar row `hoveredQueue` (headings
  /// count) as hovered, selects `selectedRow` and scrolls the list down
  /// `scroll` points, for rendering states no pointer or keyboard is there
  /// to make.
  public func stage(
    hoveredRow: Int?, hoveredQueue: Int? = nil, selectedRow: Int? = nil, scroll: CGFloat?
  ) {
    list.stage(hoveredRow: hoveredRow, selectedRow: selectedRow, scroll: scroll)
    sidebar.stage(hoveredRow: hoveredQueue)
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

    let toolbar = NSToolbar(identifier: "inbox")
    toolbar.delegate = self
    toolbar.displayMode = .iconOnly
    toolbar.allowsUserCustomization = false
    window.toolbar = toolbar

    allClearMark.symbolConfiguration = .init(pointSize: 28, weight: .light)
    allClear.setViews([allClearMark, allClearText], in: .center)
    allClear.orientation = .vertical
    allClear.spacing = 8
    allClear.isHidden = true

    let side = NSViewController()
    // The split view takes its first width from here; moving the divider
    // afterwards left the title bar's sidebar edge behind it.
    sidebar.scrollView.frame.size.width = Metrics.sidebarWidth
    side.view = sidebar.scrollView
    let sideItem = NSSplitViewItem(sidebarWithViewController: side)
    sideItem.minimumThickness = Metrics.sidebarMinWidth
    sideItem.canCollapse = false
    let content = NSViewController()
    content.view = RootView(
      banners: banners, list: list.scrollView, allClear: allClear, unavailable: unavailable)
    let split = NSSplitViewController()
    let contentItem = NSSplitViewItem(viewController: content)
    // The list's color runs up under the title bar with no rule between.
    sideItem.titlebarSeparatorStyle = .none
    contentItem.titlebarSeparatorStyle = .none
    split.addSplitViewItem(sideItem)
    split.addSplitViewItem(contentItem)
    window.contentViewController = split

    // Tab, and left and right, move the keys between the queues and the list.
    sidebar.onSelect = { [weak self] section in self?.select(queue: section) }
    sidebar.toList = { [weak self] in self?.focusList() }
    list.toSidebar = { [weak self] in self?.focusSidebar() }
    window.autorecalculatesKeyViewLoop = false
    sidebar.keyView.nextKeyView = list.keyView
    list.keyView.nextKeyView = sidebar.keyView
    window.initialFirstResponder = list.keyView
  }

  // MARK: Queues

  /// The queues' names, in order, as menu titles, each with the section a
  /// menu item's tag names for `showQueue(_:)`.
  public static let queueTitles = queueSections.map { (section: $0, name: GhInboxCore.sections[$0].name) }

  /// Shows a queue's rows, and remembers it for the account.
  public func select(queue section: Int) {
    guard GhInboxCore.sections.indices.contains(section), section != queue else { return }
    queue = section
    if remembersQueue, let identity = inbox.identity {
      UserDefaults.standard.set(GhInboxCore.sections[section].name, forKey: queueKey(identity))
    }
    render()
  }

  @objc public func showQueue(_ sender: NSMenuItem) {
    select(queue: sender.tag)
  }

  /// The cut-off row's two buttons, for the keyboard and the menu: arrow
  /// keys skip that row, so a near-miss click can't act.
  public static let loadMoreTitle = "Load \(pageStep) More"

  /// The first of the queue's searches with more to load.
  private var moreInQueue: Int? {
    members(queue).first { inbox.sections[$0].canLoadMore && !inbox.sections[$0].expanding }
  }

  @objc public func loadMoreInQueue(_ sender: Any?) {
    if let section = moreInQueue { loadMore(section) }
  }

  @objc public func openQueueOnGitHub(_ sender: Any?) {
    let host = inbox.identity?.host ?? "github.com"
    if let url = URL(string: searchURL(queue, host: host)) { NSWorkspace.shared.open(url) }
  }

  private func queueKey(_ identity: Identity) -> String {
    "queue.\(identity.host).\(identity.login)"
  }

  /// The account's last queue, once per account. Without one, the first
  /// account keeps the queue already showing; a switched-to account starts
  /// on the first queue, with none of the last account's places.
  private func restoreQueue() {
    guard let identity = inbox.identity, identity != restoredFor else { return }
    let switched = restoredFor != nil
    restoredFor = identity
    if switched {
      queue = 0
      list.forgetPlaces()
    }
    let saved = remembersQueue ? UserDefaults.standard.string(forKey: queueKey(identity)) : nil
    if let saved, let section = GhInboxCore.sections.firstIndex(where: { $0.name == saved }) {
      queue = GhInboxCore.queue(of: section)
    }
  }

  private func focusList() {
    window?.makeFirstResponder(list.keyView)
    list.selectFirstIfNone()
  }

  private func focusSidebar() {
    window?.makeFirstResponder(sidebar.keyView)
  }

  // MARK: Updating

  /// Asks first, naming the source and what happens to it, since the
  /// update changes or adds to it and replaces this app.
  private func confirmUpdate() {
    guard let window, let updater, !updater.updating, let text = updateConfirmation(updater.status) else {
      return
    }
    let alert = NSAlert()
    alert.messageText = "Update gh-inbox?"
    alert.informativeText = text
    alert.addButton(withTitle: "Update")
    alert.addButton(withTitle: "Cancel")
    alert.beginSheetModal(for: window) { [weak self] response in
      MainActor.assumeIsolated {
        guard let self, response == .alertFirstButtonReturn else { return }
        self.update()
      }
    }
  }

  /// Brings the source forward and builds it off the main thread, puts the
  /// new app where this one runs from, and reopens it. A failure shows as a
  /// banner.
  private func update() {
    guard let updater else { return }
    let bundle = Bundle.main.bundleURL
    let running = bundle.pathExtension == "app" ? bundle : nil
    Task {
      guard let app = await updater.update(replacing: running) else { return }
      if let error = relaunch(app) {
        updater.reopenFailed("the new build is at \(app.path), but gh-inbox couldn't reopen it: \(error)")
      }
    }
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

  // MARK: Menu

  /// The owner tabs, in order, as menu titles; a menu item's tag picks one
  /// for `showOwnerTab(_:)`.
  public static let ownerTabTitles = ownerTabs.map(\.1)

  @objc public func showOwnerTab(_ sender: NSMenuItem) {
    guard ownerTabs.indices.contains(sender.tag) else { return }
    model.setOwnerFilter(ownerTabs[sender.tag].0)
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
    case #selector(loadMoreInQueue(_:)):
      return presence != .closed && moreInQueue != nil
    case #selector(openQueueOnGitHub(_:)):
      return presence != .closed && inbox.identity != nil
    case #selector(showQueue(_:)):
      item.state = item.tag == queue ? .on : .off
      return presence != .closed && queues(inbox).contains { $0.section == item.tag }
    case #selector(showOwnerTab(_:)):
      guard ownerTabs.indices.contains(item.tag) else { return false }
      item.state = ownerTabs[item.tag].0 == inbox.ownerFilter ? .on : .off
      return presence != .closed && inbox.showOwnerTabs
    default:
      return true
    }
  }

  // MARK: Toolbar

  public func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    [.sidebarTrackingSeparator, .flexibleSpace, tabsItem, refreshItem]
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
    case tabsItem:
      // Shown only for an account with both kinds of repository; right of
      // a flexible space, appearing never moves the refresh button.
      item.view = tabs
      item.label = "Owner"
    case refreshItem:
      // Turns into a spinner while refreshing, in its own place and size.
      item.view = refreshControl
      item.label = "Refresh"
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

  /// The whole toolbar item goes where it can, so no empty capsule stays.
  private func showTabs(_ shown: Bool) {
    tabs.isHidden = !shown
    if #available(macOS 15, *),
      let item = window?.toolbar?.items.first(where: { $0.itemIdentifier == tabsItem })
    {
      item.isHidden = !shown
    }
  }

  // MARK: Rendering

  /// Draws the inbox as of now. Unchanged rows and banners are left alone,
  /// so a render with nothing new changes nothing on screen.
  private func render() {
    renders += 1
    window?.contentView?.needsLayout = true
    let now = Now(date: now(), timeZone: timeZone, locale: locale)
    restoreQueue()
    let listed = queues(inbox)
    if !listed.contains(where: { $0.section == queue }), let first = listed.first { queue = first.section }
    sidebar.show(listed, selected: queue)
    let shown = rows(inbox, queue: queue, now: now)
    let head = header(inbox, now: now)
    window?.title = head.title
    window?.subtitle = head.summary
    refreshControl.busy = head.busy
    showTabs(inbox.showOwnerTabs)
    tabs.selectedSegment = ownerTabs.firstIndex { $0.0 == inbox.ownerFilter } ?? 0

    // One shared failure before any data is shown once, as a panel, under
    // the update's banners alone.
    let failure = inbox.anyLoaded ? nil : inbox.commonError
    let updates = updateBanners(updater?.status)
    unavailable.isHidden = failure == nil
    banners.isHidden = failure != nil && updates.isEmpty
    if let failure {
      banners.show(updates)
      unavailable.show(failure, retrying: retrying(inbox))
      list.show([], queue: queue)
      allClear.isHidden = true
      return
    }
    banners.show(updates + GhInboxCore.banners(inbox, queue: queue, now: now))
    list.show(shown, queue: queue)
    let loading = listed.first { $0.section == queue }?.status == .loading
    let message =
      nothingOpen(inbox)
      ? "Nothing open for you"
      : !shown.isEmpty
        ? nil : loading ? "Loading \(GhInboxCore.sections[queue].name)…" : emptyText(inbox, queue: queue)
    if allClearText.stringValue != message ?? "" {
      allClearText.stringValue = message ?? ""
      // The message's width sets the panel's.
      allClear.superview?.needsLayout = true
    }
    // Loading isn't all clear.
    allClearMark.isHidden = loading
    allClear.isHidden = message == nil
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

  /// Painted up under the transparent title bar, in the list's color.
  override func draw(_ dirtyRect: NSRect) {
    NSColor.controlBackgroundColor.setFill()
    dirtyRect.fill()
  }

  override func layout() {
    super.layout()
    // Content runs under the title bar; everything starts below it.
    let titleBar = safeAreaInsets.top
    let top = titleBar + (banners.isHidden ? 0 : banners.height(for: bounds.width))
    banners.frame = NSRect(x: 0, y: titleBar, width: bounds.width, height: top - titleBar)
    // Rows stop at the title bar: a transparent one draws no effect over
    // rows scrolled beneath it. `draw` paints it the list's color instead.
    list.frame = NSRect(x: 0, y: top, width: bounds.width, height: bounds.height - top)
    // The error panel sits over the emptied list, so it shares its background.
    unavailable.frame = list.frame
    // Just under the rows, if any.
    let table = list.documentView as? NSTableView
    let rowsEnd = table.map { $0.numberOfRows > 0 ? $0.rect(ofRow: $0.numberOfRows - 1).maxY : 0 } ?? 0
    let size = allClear.fittingSize
    allClear.frame = NSRect(
      x: ((bounds.width - size.width) / 2).rounded(), y: top + rowsEnd + Metrics.allClearGap,
      width: size.width, height: size.height)
  }
}

/// The banners above the list, each kept and reworded in place, so an open
/// tooltip stays open as a banner's age moves.
final class BannerList: NSView {
  private var views: [Banner] = []
  /// A click on a banner that updates the app.
  var onUpdate: () -> Void = {}

  override var isFlipped: Bool { true }

  /// The list starts below the banners, so hiding them moves it too.
  override var isHidden: Bool {
    didSet { if isHidden != oldValue { superview?.needsLayout = true } }
  }

  func show(_ notices: [Notice]) {
    var changed = views.count != notices.count
    while views.count > notices.count { views.removeLast().removeFromSuperview() }
    while views.count < notices.count {
      let banner = Banner()
      banner.onUpdate = { [weak self] in self?.onUpdate() }
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
/// most, the rest a hover away, and a click copies it, or does what the
/// notice says (`Notice.Click`). Not selectable text, which would take the
/// list's arrow keys and keep them.
final class Banner: NSView {
  var onUpdate: () -> Void = {}
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
    let clickChanged = notice.click != self.notice?.click
    self.notice = notice
    field.show(notice.text)
    toolTipOwner.text =
      switch notice.click {
      case .copy: "\(notice.text)\n\nClick to copy."
      case .update: "\(notice.text)\n\nClick to update."
      case .inert: notice.text
      }
    if clickChanged { window?.invalidateCursorRects(for: self) }
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
    // Centered on the first line, however many lines follow.
    let line = field.font.map { NSLayoutManager().defaultLineHeight(for: $0) } ?? icon.naturalSize.height
    let size = icon.naturalSize
    let y = Metrics.bannerPadding.top + (line - size.height) / 2
    let scale = window?.backingScaleFactor ?? 2
    icon.frame = icon.frame(
      forAlignmentRect: NSRect(
        origin: NSPoint(x: Metrics.bannerPadding.left, y: (y * scale).rounded() / scale), size: size))
    field.frame = field.frame(forAlignmentRect: textRect(for: bounds.width))
    toolTipOwner.attach(to: self)
  }

  /// The whole banner takes the click, its text included.
  override func hitTest(_ point: NSPoint) -> NSView? {
    frame.contains(point) ? self : nil
  }

  override func mouseDown(with event: NSEvent) {
    guard let notice else { return }
    switch notice.click {
    case .copy:
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(notice.text, forType: .string)
    case .update: onUpdate()
    case .inert: break
    }
  }

  override func resetCursorRects() {
    if notice?.click != .inert { addCursorRect(bounds, cursor: .pointingHand) }
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

/// The refresh button, which shows a spinner in its place while a refresh
/// runs; the same size either way, so the toolbar never shifts.
final class RefreshControl: NSView {
  private let button: NSButton
  private let spinner = NSProgressIndicator()
  private let icon = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh")

  init(target: AnyObject, action: Selector) {
    button = NSButton(image: icon ?? NSImage(), target: target, action: action)
    super.init(frame: .zero)
    button.bezelStyle = .toolbar
    button.toolTip = "Refresh (⌘R)"
    button.setAccessibilityLabel("Refresh")
    spinner.style = .spinning
    spinner.controlSize = .small
    spinner.isDisplayedWhenStopped = false
    addSubview(button)
    addSubview(spinner)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  var busy = false {
    didSet {
      guard busy != oldValue else { return }
      button.image = busy ? nil : icon
      button.setAccessibilityLabel(busy ? "Refreshing" : "Refresh")
      if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }
  }

  override var intrinsicContentSize: NSSize {
    let image = icon ?? NSImage()
    let probe = NSButton(image: image, target: nil, action: nil)
    probe.bezelStyle = .toolbar
    return probe.fittingSize
  }

  override func layout() {
    super.layout()
    button.frame = bounds
    let size = spinner.fittingSize
    spinner.frame = NSRect(
      x: ((bounds.width - size.width) / 2).rounded(), y: ((bounds.height - size.height) / 2).rounded(),
      width: size.width, height: size.height)
  }
}

/// Quits, and opens `app` once this process has gone, so the new build
/// starts rather than the old one coming forward. Stays put, and says why,
/// if the waiter can't start.
@MainActor
private func relaunch(_ app: URL) -> String? {
  let waiter = Process()
  waiter.executableURL = URL(fileURLWithPath: "/bin/sh")
  waiter.arguments = [
    "-c", "while /bin/kill -0 \"$0\" 2>/dev/null; do /bin/sleep 0.2; done; exec /usr/bin/open \"$1\"",
    "\(ProcessInfo.processInfo.processIdentifier)", app.path,
  ]
  do { try waiter.run() } catch { return error.localizedDescription }
  NSApp.terminate(nil)
  return nil
}
