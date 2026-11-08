import AppKit

/// Every size and gap the window lays out with.
enum Metrics {
  /// Every row kind is this tall, so the list never reflows as rows change kind.
  static let rowHeight: CGFloat = 30
  /// The list's left and right margin.
  static let inset: CGFloat = 20
  static let checkWidth: CGFloat = 14
  static let kindWidth: CGFloat = 16
  /// Between the check and kind icons, and between a heading and its mark.
  static let iconGap: CGFloat = 8
  /// Where an item's repository column starts, after the check and kind
  /// icons; notices and cut-off rows start their text there too.
  static let leadWidth = checkWidth + iconGap + kindWidth
  /// A notice's or cut-off row's icon sits under the kind icons.
  static let leadIconOffset: CGFloat = 18
  static let columnGap: CGFloat = 12
  static let afterRepo: CGFloat = 14
  /// Between a title, its pill and its review route.
  static let titleGap: CGFloat = 8
  static let authorWidth: CGFloat = 104
  static let ageWidth: CGFloat = 52
  /// The repository column, with and without owners shown. Fixed, so titles
  /// never shift sideways as rows come and go.
  static let repoWidth = (withOwner: CGFloat(200), nameOnly: CGFloat(140))
  /// A narrow window gives titles the room: the repository column takes at
  /// most this share of the list's width.
  static let repoShare: CGFloat = 0.24
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
  /// Below this the fixed metadata columns squeeze titles to nothing.
  static let windowMinSize = NSSize(width: 760, height: 320)

  /// The repository column's width for a list `width` wide.
  static func repoColumn(multiOwner: Bool, width: CGFloat) -> CGFloat {
    let full = multiOwner ? repoWidth.withOwner : repoWidth.nameOnly
    return width > 0 ? min(full, (width * repoShare).rounded()) : full
  }
}
