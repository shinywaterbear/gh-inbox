import AppKit
import GhInboxCore

// Colors, symbols and the small view helpers every part of the window uses.

@MainActor
func label(size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
  let field = NSTextField(labelWithString: "")
  field.font = .systemFont(ofSize: size, weight: weight)
  field.textColor = color
  field.lineBreakMode = .byTruncatingTail
  return field
}

@MainActor
func symbolImage(_ name: String, size: CGFloat, weight: NSFont.Weight = .medium) -> NSImage? {
  NSImage(systemSymbolName: name, accessibilityDescription: nil)?
    .withSymbolConfiguration(.init(pointSize: size, weight: weight))
}

@MainActor
func symbol(_ name: String, size: CGFloat, color: NSColor) -> NSImageView {
  let view = NSImageView(image: symbolImage(name, size: size) ?? NSImage())
  view.contentTintColor = color
  return view
}

extension NSView {
  /// The size auto layout would give it: its intrinsic size, measured like
  /// its alignment rect, so text lines up with the other columns' text.
  var naturalSize: NSSize {
    let size = intrinsicContentSize
    if size.width != NSView.noIntrinsicMetric && size.height != NSView.noIntrinsicMetric { return size }
    let fitting = fittingSize
    return NSSize(
      width: size.width == NSView.noIntrinsicMetric ? fitting.width : size.width,
      height: size.height == NSView.noIntrinsicMetric ? fitting.height : size.height)
  }

  /// Places `view`'s alignment rect at `x`, `width` wide (its natural width
  /// when nil), centered on `centerY` (the middle when nil). Returns the
  /// alignment rect.
  @discardableResult
  func place(_ view: NSView, x: CGFloat, width: CGFloat? = nil, centerY: CGFloat? = nil) -> NSRect {
    let size = view.naturalSize
    let rect = NSRect(
      x: x, y: (centerY ?? bounds.height / 2) - size.height / 2, width: max(0, width ?? size.width),
      height: size.height)
    // The frame snaps to device pixels, as auto layout's does.
    var frame = view.frame(forAlignmentRect: rect)
    let scale = window?.backingScaleFactor ?? 2
    frame.origin.y = (frame.origin.y * scale).rounded() / scale
    view.frame = frame
    return rect
  }
}

extension Tone {
  var color: NSColor {
    switch self {
    case .error: .systemRed
    case .warning: .systemOrange
    case .info: .controlAccentColor
    }
  }

  var symbol: String {
    switch self {
    case .error: "xmark.octagon.fill"
    case .warning: "exclamationmark.triangle.fill"
    case .info: "arrow.down.circle.fill"
    }
  }
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

/// Tinted text a pill can carry: darker in light mode, where the system
/// tints are too pale on their own wash.
@MainActor
func readable(_ color: NSColor) -> NSColor {
  NSColor(name: nil) { appearance in
    var resolved = color
    appearance.performAsCurrentDrawingAppearance { resolved = color.usingColorSpace(.sRGB) ?? color }
    let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    return dark ? resolved : resolved.blended(withFraction: 0.3, of: .black) ?? resolved
  }
}

/// A tooltip read when it shows, so text that changes is never reassigned:
/// reassigning closes a tooltip that is open.
@MainActor
final class LiveToolTip: NSObject, NSViewToolTipOwner {
  var text: String?
  private var covered: NSRect?

  func view(
    _ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint,
    userData data: UnsafeMutableRawPointer?
  ) -> String {
    text ?? ""
  }

  /// Covers `view`'s bounds; call again whenever its size changes.
  func attach(to view: NSView) {
    // Re-adding the same rect would close a tooltip that is open.
    guard view.bounds != covered else { return }
    covered = view.bounds
    view.removeAllToolTips()
    view.addToolTip(view.bounds, owner: self, userData: nil)
  }
}
