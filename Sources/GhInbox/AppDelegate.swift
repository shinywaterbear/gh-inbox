import AppKit
import GhInboxUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private var controller: InboxController?

  func applicationDidFinishLaunching(_ notification: Notification) {
    setDockIconOutsideBundle()
    let controller = InboxController()
    NSApp.mainMenu = menu(refresh: controller)
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

  private func menu(refresh target: InboxController) -> NSMenu {
    let main = NSMenu()
    @discardableResult func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
      let menu = NSMenu(title: title)
      items.forEach(menu.addItem)
      let item = NSMenuItem()
      item.submenu = menu
      main.addItem(item)
      return menu
    }

    submenu(
      "gh-inbox",
      [
        item("About gh-inbox", #selector(showAbout(_:)), target: self),
        .separator(),
        item("Hide gh-inbox", #selector(NSApplication.hide(_:)), "h"),
        item(
          "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h",
          [.command, .option]),
        item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
        .separator(),
        item("Quit gh-inbox", #selector(NSApplication.terminate(_:)), "q"),
      ])
    submenu("File", [item("Close", #selector(NSWindow.performClose(_:)), "w")])
    // Copy takes the selected row's link, or a notice's text.
    submenu("Edit", [item("Copy", #selector(NSText.copy(_:)), "c")])

    var view = [
      item("Refresh", #selector(InboxController.refresh(_:)), "r", target: target),
      .separator(),
      .sectionHeader(title: "Repository Owner"),
    ]
    for (index, title) in InboxController.ownerTabTitles.enumerated() {
      let tab = item(
        title, #selector(InboxController.showOwnerTab(_:)), "\(index + 1)", target: target)
      tab.tag = index
      view.append(tab)
    }
    view += [
      .separator(),
      item(
        "Direct Only", #selector(InboxController.toggleReviewDirectOnly(_:)), "d",
        [.command, .shift], target: target),
    ]
    submenu("View", view)

    // AppKit lists open windows below these; the inbox opts out, since
    // "Inbox" stays even while it is closed.
    NSApp.windowsMenu = submenu(
      "Window",
      [
        item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
        item("Zoom", #selector(NSWindow.performZoom(_:))),
        .separator(),
        item("Inbox", #selector(NSWindowController.showWindow(_:)), "0", target: target),
      ])
    return main
  }

  private func item(
    _ title: String, _ action: Selector, _ key: String = "",
    _ modifiers: NSEvent.ModifierFlags = .command, target: AnyObject? = nil
  ) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
    item.keyEquivalentModifierMask = modifiers
    item.target = target
    return item
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
