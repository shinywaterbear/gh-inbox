import AppKit

/// The app's menus, acting on `target`'s window; `about` shows the About
/// panel. The app and the preview's on-screen window share them.
@MainActor
public func appMenu(for target: InboxController, about: (action: Selector, target: AnyObject?)) -> NSMenu {
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
      item("About gh-inbox", about.action, target: about.target),
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
  ]
  for (index, title) in InboxController.queueTitles.enumerated() {
    let queue = item(title, #selector(InboxController.showQueue(_:)), "\(index + 1)", target: target)
    queue.tag = index
    view.append(queue)
  }
  view += [
    .separator(),
    item(
      InboxController.loadMoreTitle, #selector(InboxController.loadMoreInQueue(_:)), "l", target: target),
    item(
      "Open Queue on GitHub", #selector(InboxController.openQueueOnGitHub(_:)), "o", [.command, .shift],
      target: target),
    .separator(), .sectionHeader(title: "Repository Owner"),
  ]
  for (index, title) in InboxController.ownerTabTitles.enumerated() {
    let tab = item(
      title, #selector(InboxController.showOwnerTab(_:)), "\(index + 1)", [.command, .option],
      target: target)
    tab.tag = index
    view.append(tab)
  }
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

@MainActor
private func item(
  _ title: String, _ action: Selector, _ key: String = "",
  _ modifiers: NSEvent.ModifierFlags = .command, target: AnyObject? = nil
) -> NSMenuItem {
  let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
  item.keyEquivalentModifierMask = modifiers
  item.target = target
  return item
}
