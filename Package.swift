// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "AgentWatcher",
  platforms: [.macOS(.v14)],
  products: [
    .executable(name: "AgentWatcher", targets: ["AgentWatcher"])
  ],
  targets: [
    .target(name: "AgentWatcherCore"),
    .executableTarget(name: "AgentWatcher", dependencies: ["AgentWatcherCore"]),
    .testTarget(name: "AgentWatcherCoreTests", dependencies: ["AgentWatcherCore"]),
  ],
  swiftLanguageModes: [.v5]
)
