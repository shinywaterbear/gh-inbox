import AppKit

/// Every size and gap the window lays out with.
enum Metrics {
  /// Headings, notices and cut-off rows.
  static let rowHeight: CGFloat = 30
  /// An item: its title, and under it where it is and who asked.
  static let itemRowHeight: CGFloat = 46
  /// How far each of an item's two lines sits from the row's middle.
  static let itemLineOffset: CGFloat = 9
  /// Between the parts of an item's second line.
  static let metaGap: CGFloat = 6
  /// The sidebar's width, and the narrowest it may be dragged.
  static let sidebarWidth: CGFloat = 200
  static let sidebarMinWidth: CGFloat = 160
  static let sidebarRowHeight: CGFloat = 26
  /// The list's left and right margin.
  static let inset: CGFloat = 20
  static let checkWidth: CGFloat = 14
  static let kindWidth: CGFloat = 16
  /// Between the check and kind icons, and between a heading and its mark.
  static let iconGap: CGFloat = 8
  /// Where an item's text starts, after the check and kind icons; notices
  /// and cut-off rows start their text there too.
  static let leadWidth = checkWidth + iconGap + kindWidth
  /// A notice's or cut-off row's icon sits under the kind icons.
  static let leadIconOffset: CGFloat = 18
  static let columnGap: CGFloat = 12
  /// Between a title, its pill and its review route.
  static let titleGap: CGFloat = 8
  /// The age column's least width; a date with a year widens it.
  static let ageWidth: CGFloat = 52
  static var ageFont: NSFont { .monospacedDigitSystemFont(ofSize: 12, weight: .regular) }
  /// The hover wash's inset from the row's edges, and its corner radius.
  static let hoverInset = NSSize(width: 8, height: 1)
  static let hoverRadius: CGFloat = 6
  /// "Nothing open for you" sits this far below the last heading.
  static let allClearGap: CGFloat = 48
  static let bannerPadding = NSEdgeInsets(top: 10, left: 20, bottom: 10, right: 20)
  static let bannerIconGap: CGFloat = 8
  static let bannerLines = 2
  /// The nothing-could-load panel: its width, how far above center it
  /// sits, and its margin in a narrow window.
  static let panelWidth: CGFloat = 480
  static let panelLift: CGFloat = 40
  static let panelMargin: CGFloat = 24
  static let windowSize = NSSize(width: 1000, height: 680)
  /// Below this the sidebar leaves titles too little room.
  static let windowMinSize = NSSize(width: 760, height: 320)

  /// The age column, wide enough for every age shown in the reader's
  /// date format, so none is cut off whatever room the titles have.
  @MainActor static func ageColumn(_ ages: [String]) -> CGFloat {
    let probe = label(size: 12)
    probe.font = ageFont
    let widest =
      ages.map { age -> CGFloat in
        probe.stringValue = age
        return probe.naturalSize.width
      }.max() ?? 0
    return max(ageWidth, widest.rounded(.up))
  }
}
