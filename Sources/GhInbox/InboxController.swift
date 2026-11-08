import AppKit
import GhInboxCore

/// How often the scheduler checks whether a refresh is due, and ages re-render.
private let tick: TimeInterval = 10

private let controlsItem = NSToolbarItem.Identifier("controls")
private let refreshItem = NSToolbarItem.Identifier("refresh")

private let ownerTabs: [(OwnerFilter, String)] = [
  (.all, "All"), (.personal, "Personal"), (.organization, "Org"),
]

final class InboxController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
  private var inbox = Inbox()
  private var shown = Rows()
  private var shownBanners: [Notice] = []
  private var focused = false
  private var lastAttempt: Instant?
  private var timer: Timer?

  private let tabs = NSSegmentedControl(
    labels: ownerTabs.map(\.1), trackingMode: .selectOne, target: nil, action: nil)
  private let directOnly = NSButton(checkboxWithTitle: "Direct only", target: nil, action: nil)
  private let spinner = NSProgressIndicator()
  private let bannerStack = NSStackView()
  private let list = InboxList()
  private lazy var unavailable = UnavailableView { [weak self] in self?.refresh(nil) }

  init() {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1000, height: 680),
      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    window.title = "gh-inbox"
    window.toolbarStyle = .unified
    // Below this the fixed metadata columns squeeze titles to nothing.
    window.contentMinSize = NSSize(width: 760, height: 320)
    super.init(window: window)
    window.delegate = self
    layout(in: window)
    if background {
      if let backgroundSize { window.setContentSize(backgroundSize) }
      window.center()
    } else {
      // Centered only the first time; after that the saved frame is restored.
      if !window.setFrameUsingName("inbox") { window.center() }
      window.setFrameAutosaveName("inbox")
    }
    list.onLoadMore = { [weak self] section in self?.loadMore(section) }
    refresh(nil)
    timer = Timer.scheduledTimer(withTimeInterval: tick, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.refreshIfDue(.tick)
        // Ages like "updated 3m ago" move without new data.
        self?.render(rowsChangedOnly: true)
        self?.list.refreshAges()
      }
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

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

    bannerStack.orientation = .vertical
    bannerStack.alignment = .leading
    bannerStack.spacing = 0

    let root = NSStackView(views: [bannerStack, list.scrollView])
    root.orientation = .vertical
    root.alignment = .leading
    root.spacing = 0
    for view in root.arrangedSubviews {
      view.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
    }
    list.scrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
    window.contentView = root
    // Over the list, not in it: a scroll view keeps only its own subviews.
    // The error panel sits over the emptied list, so it shares its background.
    unavailable.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(unavailable)
    root.addSubview(list.allClear)
    NSLayoutConstraint.activate([
      unavailable.leadingAnchor.constraint(equalTo: list.scrollView.leadingAnchor),
      unavailable.trailingAnchor.constraint(equalTo: list.scrollView.trailingAnchor),
      unavailable.topAnchor.constraint(equalTo: list.scrollView.topAnchor),
      unavailable.bottomAnchor.constraint(equalTo: list.scrollView.bottomAnchor),
      list.allClear.centerXAnchor.constraint(equalTo: list.scrollView.centerXAnchor),
    ])
    let allClearTop = list.allClear.topAnchor.constraint(equalTo: list.scrollView.topAnchor)
    allClearTop.isActive = true
    list.allClearTop = allClearTop
  }

  // MARK: Refreshing

  private func refreshIfDue(_ trigger: Trigger) {
    let since = lastAttempt.map { ContinuousClock.now - $0 }
    if due(trigger, focused: focused, sinceAttempt: since) { refresh(nil) }
  }

  /// Keeps the current rows on screen until the new ones arrive.
  @objc func refresh(_ sender: Any?) {
    if inbox.refresh() > 0 { lastAttempt = .now }
    pump()
  }

  private func loadMore(_ section: Int) {
    if inbox.loadMore(section) { pump() }
  }

  /// Starts queued jobs while slots are free; each finished job applies its
  /// result, renders it at once and pumps again.
  private func pump() {
    while let ticket = inbox.nextJob() {
      Task {
        let outcome = await withCheckedContinuation { continuation in
          DispatchQueue.global(qos: .userInitiated).async {
            continuation.resume(returning: Gh.resolved().perform(ticket.job))
          }
        }
        if inbox.finish(ticket, outcome, now: .now) { inbox.refresh() }
        pump()
      }
    }
    render()
  }

  // MARK: Controls

  @objc private func chooseTab(_ sender: NSSegmentedControl) {
    inbox.ownerFilter = ownerTabs[sender.selectedSegment].0
    render()
  }

  @objc private func toggleDirectOnly(_ sender: NSButton) {
    if inbox.setReviewDirectOnly(sender.state == .on) { pump() } else { render() }
  }

  // MARK: Toolbar

  func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    [.flexibleSpace, controlsItem, refreshItem]
  }

  func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    toolbarDefaultItemIdentifiers(toolbar)
  }

  func toolbar(
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

  func windowDidBecomeKey(_ notification: Notification) {
    focused = true
    refreshIfDue(.focus)
  }

  func windowDidResignKey(_ notification: Notification) {
    focused = false
  }

  // MARK: Rendering

  /// `rowsChangedOnly` skips rebuilding a list whose rows are unchanged, for
  /// renders that bring no new data.
  private func render(rowsChangedOnly: Bool = false) {
    let now = ContinuousClock.now
    let previous = shown.rows
    shown = rows(inbox, now: now)
    let head = header(inbox, rows: shown.rows, now: now)
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
    bannerStack.isHidden = failure != nil
    if let failure {
      unavailable.show(failure, retrying: retrying(inbox))
      // Once, as the failure starts; ticks after it have nothing to clear.
      if !list.isEmpty { list.show(Rows(), of: inbox) }
      return
    }
    // Rebuilt only on change: a rebuild closes the tooltip holding the full text.
    let current = banners(inbox)
    if current != shownBanners {
      shownBanners = current
      showBanners(current)
    } else {
      for case let banner as Banner in bannerStack.arrangedSubviews { banner.refresh() }
    }
    if !rowsChangedOnly || shown.rows != previous { list.show(shown, of: inbox) } else { list.update(inbox) }
  }

  private func showBanners(_ current: [Notice]) {
    for view in bannerStack.arrangedSubviews { view.removeFromSuperview() }
    for notice in current {
      let banner = Banner(notice)
      bannerStack.addArrangedSubview(banner)
      banner.widthAnchor.constraint(equalTo: bannerStack.widthAnchor).isActive = true
    }
  }
}

extension Tone {
  var color: NSColor {
    switch self {
    case .error: .systemRed
    case .warning: .systemOrange
    }
  }

  var symbol: String {
    switch self {
    case .error: "xmark.octagon.fill"
    case .warning: "exclamationmark.triangle.fill"
    }
  }
}

@MainActor
func label(size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
  let field = NSTextField(labelWithString: "")
  field.font = .systemFont(ofSize: size, weight: weight)
  field.textColor = color
  return field
}

/// A full-width notice above the list, tinted by its tone.
final class Banner: NSView {
  private let notice: Notice
  private var field: NSTextField?

  init(_ notice: Notice) {
    self.notice = notice
    super.init(frame: .zero)
    wantsLayer = true
    let icon = symbol(notice.tone.symbol, size: 13, color: notice.tone.color)
    let text = notice.text(now: .now)
    let field = WrappingLabel(wrappingLabelWithString: text)
    field.font = .systemFont(ofSize: 12)
    field.textColor = .labelColor
    field.isSelectable = true
    // Two lines at most; the rest is a hover away.
    field.maximumNumberOfLines = 2
    field.lineBreakMode = .byTruncatingTail
    field.cell?.truncatesLastVisibleLine = true
    self.field = field
    let notice = notice
    field.liveToolTip = LiveToolTip { notice.text(now: .now) }
    field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    let row = NSStackView(views: [icon, field])
    row.alignment = .top
    row.spacing = 8
    row.edgeInsets = NSEdgeInsets(top: 10, left: 20, bottom: 10, right: 20)
    row.translatesAutoresizingMaskIntoConstraints = false
    addSubview(row)
    NSLayoutConstraint.activate([
      row.leadingAnchor.constraint(equalTo: leadingAnchor),
      row.trailingAnchor.constraint(equalTo: trailingAnchor),
      row.topAnchor.constraint(equalTo: topAnchor),
      row.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  /// Moves the age in place; a rebuild would close an open tooltip.
  func refresh() {
    if let field { field.show(notice) }
  }

  override var wantsUpdateLayer: Bool { true }

  override func updateLayer() {
    layer?.backgroundColor = notice.tone.color.withAlphaComponent(0.12).cgColor
  }
}

/// A wrapping label that wraps at its own current width. Set from its own
/// frame change, not its container's layout pass, which runs before the
/// label is placed and would wrap at its previous width.
final class WrappingLabel: NSTextField {
  /// Held here: AppKit doesn't retain a tooltip's owner.
  var liveToolTip: LiveToolTip?

  override func setFrameSize(_ size: NSSize) {
    super.setFrameSize(size)
    liveToolTip?.attach(to: self)
    if preferredMaxLayoutWidth != size.width {
      preferredMaxLayoutWidth = size.width
      invalidateIntrinsicContentSize()
    }
  }
}

extension NSTextField {
  /// Shows a notice's text as of now, assigning only on change.
  func show(_ notice: Notice) {
    let text = notice.text(now: .now)
    if stringValue != text { stringValue = text }
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
      field.preferredMaxLayoutWidth = 460
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
      stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -40),
      stack.widthAnchor.constraint(lessThanOrEqualToConstant: 480),
      stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
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
