import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private var controller: InboxController?

  func applicationDidFinishLaunching(_ notification: Notification) {
    setDockIconOutsideBundle()
    let controller = InboxController()
    NSApp.mainMenu = menu(refresh: controller)
    self.controller = controller
    if background {
      controller.window?.orderBack(nil)
    } else {
      controller.showWindow(nil)
      NSApp.activate()
    }
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    true
  }

  private func menu(refresh target: InboxController) -> NSMenu {
    let main = NSMenu()
    let appItem = NSMenuItem()
    let appMenu = NSMenu()
    appMenu.addItem(
      withTitle: "Quit gh-inbox", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    appItem.submenu = appMenu
    main.addItem(appItem)

    let viewItem = NSMenuItem()
    let viewMenu = NSMenu(title: "View")
    let refresh = viewMenu.addItem(
      withTitle: "Refresh", action: #selector(InboxController.refresh(_:)), keyEquivalent: "r")
    refresh.target = target
    viewItem.submenu = viewMenu
    main.addItem(viewItem)
    return main
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
