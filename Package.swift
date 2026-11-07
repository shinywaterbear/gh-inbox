// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "gh-inbox",
  platforms: [.macOS(.v14)],
  targets: [
    .target(name: "GhInboxCore"),
    .testTarget(name: "GhInboxCoreTests", dependencies: ["GhInboxCore"]),
  ]
)

// The AppKit shell is macOS-only; Linux CI builds and tests the core alone.
#if os(macOS)
  package.products.append(.executable(name: "gh-inbox", targets: ["GhInbox"]))
  package.targets.append(.executableTarget(name: "GhInbox", dependencies: ["GhInboxCore"]))
#endif
