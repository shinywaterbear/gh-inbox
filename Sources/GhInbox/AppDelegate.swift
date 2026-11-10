import AppKit
import GhInboxUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private var controller: InboxController?

  func applicationDidFinishLaunching(_ notification: Notification) {
    setDockIconOutsideBundle()
    let controller = InboxController()
    NSApp.mainMenu = appMenu(for: controller, about: (#selector(showAbout(_:)), self))
    self.controller = controller
    controller.showWindow(nil)
    NSApp.activate()
  }

  /// Closing the window leaves the app running in the Dock; clicking the
  /// icon brings the window back.
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
    if !hasVisibleWindows { controller?.showWindow(nil) }
    return true
  }

  /// The standard About panel, its version naming the commit it was built
  /// from when the bundle records one.
  @objc private func showAbout(_ sender: Any?) {
    var options: [NSApplication.AboutPanelOptionKey: Any] = [:]
    let info = Bundle.main.infoDictionary ?? [:]
    if let version = info["CFBundleShortVersionString"] as? String,
      let revision = info["SourceRevision"] as? String
    {
      let commit = revision.prefix { $0 != "-" }
      let short = commit.prefix(7) + revision.dropFirst(commit.count)
      options[.applicationVersion] = "\(version) (\(short))"
      options[.version] = ""
    }
    NSApp.orderFrontStandardAboutPanel(options: options)
  }

  /// `swift run` has no bundle, so the Dock would show the generic icon.
  private func setDockIconOutsideBundle() {
    guard Bundle.main.bundleIdentifier == nil else { return }
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    if let icon = NSImage(contentsOf: repository.appendingPathComponent("assets/icon.png")) {
      NSApp.applicationIconImage = icon
    }
  }
}
