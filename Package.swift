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
// The window lives in a library so other executables can host and render it.
#if os(macOS)
  package.products.append(.executable(name: "gh-inbox", targets: ["GhInbox"]))
  package.products.append(.library(name: "GhInboxUI", targets: ["GhInboxUI"]))
  package.targets.append(.target(name: "GhInboxUI", dependencies: ["GhInboxCore"]))
  package.targets.append(.executableTarget(name: "GhInbox", dependencies: ["GhInboxUI"]))
#endif
