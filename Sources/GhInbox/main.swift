import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
/// For capturing the window unattended: it opens behind others, without a
/// Dock icon, never takes focus and leaves the saved frame alone.
let background = ProcessInfo.processInfo.environment["GH_INBOX_BACKGROUND"] != nil

/// The window's content size when capturing, as `<width>x<height>`.
let backgroundSize: NSSize? = ProcessInfo.processInfo.environment["GH_INBOX_SIZE"].flatMap { size in
  let parts = size.split(separator: "x", omittingEmptySubsequences: false).map { Double($0) }
  guard parts.count == 2, let width = parts[0], let height = parts[1], width > 0, height > 0,
    width.isFinite, height.isFinite
  else {
    return nil
  }
  return NSSize(width: width, height: height)
}

app.setActivationPolicy(background ? .accessory : .regular)
app.run()
