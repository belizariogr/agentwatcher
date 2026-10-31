import AgentWatcherCore
import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private let store = UsageStore()
  private var statusItem: NSStatusItem!
  private let popover = NSPopover()
  private var cancellables = Set<AnyCancellable>()
  private lazy var settings = SettingsWindowController(store: store)

  func applicationDidFinishLaunching(_ notification: Notification) {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    if let button = statusItem.button {
      button.target = self
      button.action = #selector(statusItemClicked(_:))
      button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    popover.behavior = .transient
    popover.animates = true
    popover.contentViewController = NSHostingController(
      rootView: PanelView(
        store: store,
        onOpenSettings: { [weak self] in self?.openSettings() },
        onQuit: { NSApp.terminate(nil) }
      )
    )

    // objectWillChange fires before the new values land; read them a turn later.
    store.objectWillChange
      .receive(on: RunLoop.main)
      .sink { [weak self] _ in self?.updateIcon() }
      .store(in: &cancellables)

    // Windows reset on their own schedule; keep the icon honest between refreshes.
    Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.updateIcon() }
    }

    updateIcon()
    store.start()
  }

  private func updateIcon() {
    guard let button = statusItem.button else { return }
    let worst = store.worstRemaining
    button.image = StatusIcon.image(used: worst.map { 1 - $0 }, severity: store.severity)
    button.toolTip = tooltip()
  }

  private func tooltip() -> String {
    guard !store.usages.isEmpty else { return "Agent Watcher" }
    return store.usages.map { usage in
      guard let tight = usage.tightest() else { return "\(usage.name): no data" }
      return "\(usage.name): \(Int((tight.remaining() * 100).rounded()))% left (\(tight.title))"
    }.joined(separator: "\n")
  }

  @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
    if NSApp.currentEvent?.type == .rightMouseUp {
      showMenu()
    } else {
      togglePopover(sender)
    }
  }

  private func togglePopover(_ sender: NSStatusBarButton) {
    if popover.isShown {
      popover.performClose(sender)
    } else {
      store.refreshIfStale()
      popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
      popover.contentViewController?.view.window?.makeKey()
      NSApp.activate()
    }
  }

  private func showMenu() {
    let menu = NSMenu()
    menu.addItem(withTitle: "Refresh", action: #selector(refreshNow), keyEquivalent: "r").target = self
    menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
    menu.addItem(.separator())
    menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    statusItem.menu = menu
    statusItem.button?.performClick(nil)
    statusItem.menu = nil
  }

  @objc private func refreshNow() { store.refresh() }

  @objc private func openSettings() {
    popover.performClose(nil)
    settings.show()
  }
}

// `AgentWatcher --dump` prints what the panel would show and exits.
if CommandLine.arguments.contains("--dump") {
  let done = DispatchSemaphore(value: 0)
  Task.detached {
    for provider in UsageStore.allProviders where provider.isInstalled() {
      let usage = await provider.fetch()
      print("\(usage.name) [\(usage.plan ?? "-")]\(usage.message.map { " ! \($0)" } ?? "")")
      for limit in usage.limits {
        print("  \(limit.title): \(Int(((1 - limit.used) * 100).rounded()))% left, resets \(limit.resetsAt.map { "\($0)" } ?? "-")")
      }
    }
    done.signal()
  }
  done.wait()
  exit(0)
}

// `AgentWatcher --snapshot <dir>` renders the panel and the icon to PNGs.
if let flag = CommandLine.arguments.firstIndex(of: "--snapshot") {
  let dir = URL(fileURLWithPath: CommandLine.arguments.count > flag + 1 ? CommandLine.arguments[flag + 1] : ".")
  try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  MainActor.assumeIsolated {
    let store = UsageStore()
    store.refresh()
    while store.isRefreshing || store.lastRefresh == nil {
      RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }
    func write(_ image: NSImage?, _ name: String) {
      guard let tiff = image?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
            let png = rep.representation(using: .png, properties: [:]) else { return }
      try? png.write(to: dir.appendingPathComponent(name))
    }
    for scheme in [ColorScheme.light, .dark] {
      let renderer = ImageRenderer(content: PanelView(store: store, onOpenSettings: {}, onQuit: {})
        .background(scheme == .dark ? Color(white: 0.16) : Color(white: 0.96))
        .environment(\.colorScheme, scheme))
      renderer.scale = 2
      write(renderer.nsImage, "panel-\(scheme == .dark ? "dark" : "light").png")
    }
    let icon = StatusIcon.image(used: store.worstRemaining.map { 1 - $0 }, severity: store.severity)
    let big = NSImage(size: NSSize(width: 72, height: 72), flipped: false) { rect in
      icon.draw(in: rect); return true
    }
    write(big, "icon.png")
  }
  exit(0)
}

MainActor.assumeIsolated {
  let app = NSApplication.shared
  let delegate = AppDelegate()
  app.delegate = delegate
  app.setActivationPolicy(.accessory)
  app.run()
}
