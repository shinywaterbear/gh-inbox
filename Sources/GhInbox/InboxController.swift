import AppKit
import GhInboxCore

/// How often the scheduler checks whether a refresh is due, and ages re-render.
private let tick: TimeInterval = 10

private let ownerTabs: [(OwnerFilter, String)] = [
  (.all, "All"), (.personal, "Personal"), (.organization, "Org"),
]

final class InboxController: NSWindowController, NSWindowDelegate {
  private var inbox = Inbox()
  private var shown = Rows()
  private var focused = false
  private var lastAttempt: Instant?
  private var timer: Timer?

  private let titleLabel = label(size: 17, weight: .semibold)
  private let summaryLabel = label(size: 12, color: .secondaryLabelColor)
  private let tabs = NSSegmentedControl(
    labels: ownerTabs.map(\.1), trackingMode: .selectOne, target: nil, action: nil)
  private let directOnly = NSButton(checkboxWithTitle: "Direct only", target: nil, action: nil)
  private let refreshButton = NSButton(title: "Refreshing…", target: nil, action: nil)
  private let bannerStack = NSStackView()
  private let list = InboxList()
  private let unavailable = UnavailableView()

  init() {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1000, height: 680),
      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    window.title = "gh-inbox"
    // Below this the fixed metadata columns squeeze titles to nothing.
    window.contentMinSize = NSSize(width: 760, height: 320)
    super.init(window: window)
    window.delegate = self
    layout(in: window)
    window.center()
    list.onLoadMore = { [weak self] section in self?.loadMore(section) }
    refresh(nil)
    timer = Timer.scheduledTimer(withTimeInterval: tick, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.refreshIfDue(.tick)
        // Ages like "updated 3m ago" move without new data.
        self?.render(rowsChangedOnly: true)
      }
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  private func layout(in window: NSWindow) {
    summaryLabel.lineBreakMode = .byTruncatingTail
    summaryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    let titles = NSStackView(views: [titleLabel, summaryLabel])
    titles.alignment = .firstBaseline
    titles.spacing = 12

    tabs.target = self
    tabs.action = #selector(chooseTab(_:))
    tabs.controlSize = .small
    directOnly.target = self
    directOnly.action = #selector(toggleDirectOnly(_:))
    refreshButton.target = self
    refreshButton.action = #selector(refresh(_:))
    // As wide as "Refreshing…", so the controls beside it never shift.
    refreshButton.widthAnchor.constraint(equalToConstant: refreshButton.fittingSize.width).isActive = true
    let controls = NSStackView(views: [tabs, directOnly, refreshButton])
    controls.spacing = 8
    // Hidden controls keep their slot, so revealing one never moves another.
    controls.detachesHiddenViews = false
    controls.setContentHuggingPriority(.required, for: .horizontal)

    let header = NSStackView(views: [titles, NSView(), controls])
    header.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)

    bannerStack.orientation = .vertical
    bannerStack.alignment = .leading
    bannerStack.spacing = 0

    let root = NSStackView(views: [header, separator(), bannerStack, list.scrollView, unavailable])
    root.orientation = .vertical
    root.alignment = .leading
    root.spacing = 0
    for view in root.arrangedSubviews {
      view.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
    }
    list.scrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
    unavailable.setContentHuggingPriority(.defaultLow, for: .vertical)
    window.contentView = root
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
    titleLabel.stringValue = head.title
    summaryLabel.stringValue = head.summary
    refreshButton.title = head.busy ? "Refreshing…" : "Refresh"
    tabs.isHidden = !inbox.showOwnerTabs
    tabs.selectedSegment = ownerTabs.firstIndex { $0.0 == inbox.ownerFilter } ?? 0
    directOnly.isHidden = !inbox.showDirectOnly
    directOnly.state = inbox.reviewDirectOnly ? .on : .off

    // One shared failure before any data is shown once, as a panel.
    let failure = inbox.anyLoaded ? nil : inbox.commonError
    unavailable.isHidden = failure == nil
    list.scrollView.isHidden = failure != nil
    bannerStack.isHidden = failure != nil
    if let failure {
      unavailable.show(failure)
      return
    }
    for view in bannerStack.arrangedSubviews { view.removeFromSuperview() }
    for (text, tone) in banners(inbox, now: now) {
      let banner = Banner(text: text, color: tone.color)
      bannerStack.addArrangedSubview(banner)
      banner.widthAnchor.constraint(equalTo: bannerStack.widthAnchor).isActive = true
    }
    if !rowsChangedOnly || shown.rows != previous { list.show(shown, of: inbox) }
  }
}

extension Tone {
  var color: NSColor {
    switch self {
    case .error: .systemRed
    case .warning: .systemYellow
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

@MainActor
func separator() -> NSBox {
  let box = NSBox()
  box.boxType = .separator
  return box
}

/// A full-width notice above the list.
final class Banner: NSStackView {
  init(text: String, color: NSColor) {
    super.init(frame: .zero)
    let field = NSTextField(wrappingLabelWithString: text)
    field.font = .systemFont(ofSize: 12)
    field.textColor = color
    field.isSelectable = true
    let padded = NSStackView(views: [field])
    padded.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
    orientation = .vertical
    alignment = .leading
    spacing = 0
    addArrangedSubview(padded)
    addArrangedSubview(separator())
    for view in arrangedSubviews { view.widthAnchor.constraint(equalTo: widthAnchor).isActive = true }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }
}

/// The one error and its hint, when nothing could load.
final class UnavailableView: NSStackView {
  private let error = label(size: 17, color: .systemRed)
  private let hint = label(size: 12, color: .secondaryLabelColor)

  init() {
    super.init(frame: .zero)
    for field in [error, hint] {
      field.isSelectable = true
      field.lineBreakMode = .byWordWrapping
      field.maximumNumberOfLines = 0
      field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }
    orientation = .vertical
    alignment = .leading
    spacing = 8
    edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
    setViews([error, hint], in: .top)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  func show(_ failure: GhError) {
    error.stringValue = failure.description
    hint.stringValue = failure.hint ?? ""
    hint.isHidden = failure.hint == nil
  }
}
