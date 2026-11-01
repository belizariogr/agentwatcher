import AgentWatcherCore
import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
  private let store = UsageStore()
  private var statusItem: NSStatusItem!
  private let popover = NSPopover()
  private var panel: NSHostingController<PanelView>!
  private var cancellables = Set<AnyCancellable>()
  private let updater = Updater()
  private lazy var settings = SettingsWindowController(store: store, updater: updater)
  private lazy var about = AboutWindowController(updater: updater)
  private weak var popoverAnchor: NSStatusBarButton?
  private var pinningPopover = false
  private var popoverFrameObservers: [NSObjectProtocol] = []
  /// Generation token so delayed pins from a previous open/close do not fire.
  private var pinGeneration = 0
  private var pendingPins: [DispatchWorkItem] = []
  /// While this is in the future, NSPopover's late `didMove` is forced back
  /// below the menu bar. The usual open is already correct; the miss is a
  /// flip a beat later, after SwiftUI publishes its real size.
  private var holdBelowUntil: Date?
  /// Same-click reopen: a transient popover dismisses on mouseDown, then the
  /// button action runs with `isShown == false`. Only that follow-up is
  /// swallowed — not the next click ~500 ms later.
  private var ignoreToggleUntil: Date?
  private var closingFromToggle = false
  private var statusItemMouseDownMonitor: Any?

  func applicationDidFinishLaunching(_ notification: Notification) {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    if let button = statusItem.button {
      button.target = self
      button.action = #selector(statusItemClicked(_:))
      // mouseDown: same phase as NSPopover's click-outside dismiss.
      button.sendAction(on: [.leftMouseDown, .rightMouseDown])
    }
    statusItemMouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
      self?.armIgnoreIfClickInSlot()
      return event
    }

    popover.behavior = .transient
    popover.animates = false
    popover.delegate = self
    panel = NSHostingController(
      rootView: PanelView(
        store: store,
        updater: updater,
        onOpenSettings: { [weak self] in self?.openSettings() },
        onOpenAbout: { [weak self] in self?.openAbout() },
        onQuit: { NSApp.terminate(nil) }
      )
    )
    // The popover follows the SwiftUI content's size as it changes.
    panel.sizingOptions = [.preferredContentSize]
    popover.contentViewController = panel

    // objectWillChange fires before the new values land; read them a turn
    // later. The main queue (unlike RunLoop.main's default mode) also runs
    // while a menu is tracking, so the icon never lags behind.
    store.objectWillChange
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in self?.updateIcon() }
      .store(in: &cancellables)

    // Windows reset on their own schedule; keep the icon honest between refreshes.
    Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.updateIcon() }
    }

    updateIcon()
    store.start()

    // Don't swap the app out from under an open panel or a menu.
    updater.isBusy = { [weak self] in self?.popover.isShown ?? false }
    updater.onWillRelaunch = { NSApp.terminate(nil) }
    updater.start()
  }

  private func updateIcon() {
    guard let button = statusItem.button else { return }
    let remaining = store.iconRemaining
    button.image = StatusIcon.image(used: remaining.map { 1 - $0 }, alert: store.alertColor, critical: store.alertLevel == .critical)
    button.toolTip = tooltip()
  }

  private func tooltip() -> String {
    guard !store.usages.isEmpty else { return "Agent Watcher" }
    return store.usages.map { usage in
      let line = usage.tooltipLine()
      return store.pinnedProviderID == usage.id ? "\(line) (menu bar)" : line
    }.joined(separator: "\n")
  }

  @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
    if NSApp.currentEvent?.type == .rightMouseDown {
      showMenu()
    } else {
      togglePopover(sender)
    }
  }

  private func togglePopover(_ sender: NSStatusBarButton) {
    if popover.isShown {
      // This click is the close. Do not keep the swallow armed for the next one.
      closingFromToggle = true
      ignoreToggleUntil = nil
      popover.performClose(sender)
      return
    }
    if let until = ignoreToggleUntil, Date() < until {
      ignoreToggleUntil = nil
      return
    }
    store.refreshIfStale()
    showPopover(below: sender)
  }

  /// Opens the panel under the icon. NSPopover still sometimes picks the
  /// wrong edge (above the menu bar) a beat after show — SwiftUI's size is
  /// late, then AppKit re-anchors and flips. Measure, show against a 1-pt
  /// strip at the button's bottom, then hold the window below the menu bar
  /// until those layout passes finish.
  private func showPopover(below button: NSStatusBarButton) {
    NSApp.activate()
    panel.view.layoutSubtreeIfNeeded()
    let size = panel.view.fittingSize
    if size.width > 0, size.height > 0 { popover.contentSize = size }
    popoverAnchor = button
    // Whole button, not a 1-pt strip: transient popover treats clicks on the
    // positioning view as inside. The horseshoe does not fill the slot.
    popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    popover.contentViewController?.view.window?.makeKey()
    holdPopoverBelow()
  }

  func popoverDidShow(_ notification: Notification) {
    observePopoverFrame()
    holdPopoverBelow()
  }

  func popoverDidClose(_ notification: Notification) {
    stopHoldingPopover()
    popoverFrameObservers.forEach { NotificationCenter.default.removeObserver($0) }
    popoverFrameObservers = []
    pinningPopover = false
    if closingFromToggle {
      closingFromToggle = false
      ignoreToggleUntil = nil
      return
    }
    // Click-outside dismissed the panel; the button action may still fire.
    if statusItemSlotContainsMouse() {
      ignoreToggleUntil = Date().addingTimeInterval(0.12)
    }
  }

  private func armIgnoreIfClickInSlot() {
    guard popover.isShown, !closingFromToggle, statusItemSlotContainsMouse() else { return }
    ignoreToggleUntil = Date().addingTimeInterval(0.12)
  }

  /// The whole status-item window, in screen coordinates — not the painted
  /// glyph and not a convert through the button, which misses the padding.
  private func statusItemSlotContainsMouse() -> Bool {
    guard let window = statusItem.button?.window else { return false }
    return window.frame.insetBy(dx: -4, dy: -4).contains(NSEvent.mouseLocation)
  }

  private func observePopoverFrame() {
    popoverFrameObservers.forEach { NotificationCenter.default.removeObserver($0) }
    popoverFrameObservers = []
    guard let window = popover.contentViewController?.view.window else { return }
    let onResize: @Sendable (Notification) -> Void = { [weak self] _ in
      Task { @MainActor in self?.holdPopoverBelow() }
    }
    // didMove is only honored while `holdBelowUntil` is in the future, so
    // NSPopover's late flip is undone without a permanent tug-of-war.
    let onMove: @Sendable (Notification) -> Void = { [weak self] _ in
      Task { @MainActor in
        guard let self, let until = self.holdBelowUntil, Date() < until else { return }
        self.pinPopoverBelowMenuBar()
      }
    }
    popoverFrameObservers = [
      NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main, using: onResize),
      NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: window, queue: .main, using: onMove),
    ]
  }

  private func stopHoldingPopover() {
    pinGeneration += 1
    pendingPins.forEach { $0.cancel() }
    pendingPins = []
    holdBelowUntil = nil
  }

  private func holdPopoverBelow() {
    pinGeneration += 1
    let generation = pinGeneration
    pendingPins.forEach { $0.cancel() }
    pendingPins = []
    holdBelowUntil = Date().addingTimeInterval(0.45)
    pinPopoverBelowMenuBar()
    for delay in [0.0, 1.0 / 30.0, 0.08, 0.16, 0.3, 0.45] {
      let work = DispatchWorkItem { [weak self] in
        guard let self, self.pinGeneration == generation, self.popover.isShown else { return }
        self.pinPopoverBelowMenuBar()
      }
      pendingPins.append(work)
      DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
  }

  private func pinPopoverBelowMenuBar() {
    guard !pinningPopover, popover.isShown,
          let button = popoverAnchor ?? statusItem.button,
          let window = popover.contentViewController?.view.window,
          let buttonWindow = button.window else { return }
    let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
    let probe = NSPoint(x: buttonFrame.midX, y: buttonFrame.minY - 1)
    let screen = NSScreen.screens.first { $0.frame.contains(probe) }
      ?? buttonWindow.screen ?? window.screen ?? NSScreen.main
    let visible = screen?.visibleFrame ?? window.frame
    let current = window.frame
    let ceiling = min(buttonFrame.minY, visible.maxY)
    let misplaced = current.maxY > ceiling + 1 || current.minY >= buttonFrame.minY - 1
    let holding = holdBelowUntil.map { Date() < $0 } ?? false
    guard misplaced || holding else { return }

    var frame = current
    // Keep NSPopover's X so the arrow still points at the icon.
    frame.origin.y = ceiling - frame.height
    if frame.maxX > visible.maxX { frame.origin.x = visible.maxX - frame.width }
    if frame.minX < visible.minX { frame.origin.x = visible.minX }
    if frame.minY < visible.minY { frame.origin.y = visible.minY }
    if frame.maxY > ceiling { frame.origin.y = ceiling - frame.height }
    guard abs(current.origin.x - frame.origin.x) > 0.5
            || abs(current.origin.y - frame.origin.y) > 0.5 else { return }
    pinningPopover = true
    window.setFrameOrigin(frame.origin)
    DispatchQueue.main.async { [weak self] in self?.pinningPopover = false }
  }

  private func showMenu() {
    let menu = NSMenu()
    menu.addItem(withTitle: "Refresh", action: #selector(refreshNow), keyEquivalent: "r").target = self
    menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
    menu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "").target = self
    menu.addItem(withTitle: "About Agent Watcher", action: #selector(openAbout), keyEquivalent: "").target = self
    menu.addItem(.separator())
    menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    statusItem.menu = menu
    statusItem.button?.performClick(nil)
    statusItem.menu = nil
  }

  @objc private func refreshNow() { store.refresh() }

  @objc private func checkForUpdates() {
    updater.check()
    openAbout()
  }

  @objc private func openAbout() {
    popover.performClose(nil)
    about.show()
  }

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
        print("  \(limit.title): \(Alert.percentLeft(1 - limit.used))% left, resets \(limit.resetsAt.map { "\($0)" } ?? "-")")
      }
    }
    done.signal()
  }
  done.wait()
  exit(0)
}

// `AgentWatcher --icons <dir>` renders the tray / warning / critical glyphs.
if let flag = CommandLine.arguments.firstIndex(of: "--icons") {
  let dir = URL(fileURLWithPath: CommandLine.arguments.count > flag + 1 ? CommandLine.arguments[flag + 1] : ".")
  try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  MainActor.assumeIsolated {
    func write(_ image: NSImage, _ name: String) {
      let big = NSImage(size: NSSize(width: 72, height: 72), flipped: false) { rect in
        image.draw(in: rect); return true
      }
      guard let tiff = big.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
            let png = rep.representation(using: .png, properties: [:]) else { return }
      try? png.write(to: dir.appendingPathComponent(name))
    }
    write(StatusIcon.image(used: 0.45, alert: nil), "icon-tray.png")
    write(StatusIcon.image(used: 0.82, alert: Alert.orange), "icon-warning.png")
    write(StatusIcon.image(used: 0.94, alert: Alert.red, critical: true), "icon-critical.png")
  }
  exit(0)
}

// `AgentWatcher --snapshot <dir>` renders the panel and the icon to PNGs.
if let flag = CommandLine.arguments.firstIndex(of: "--snapshot") {
  let dir = URL(fileURLWithPath: CommandLine.arguments.count > flag + 1 ? CommandLine.arguments[flag + 1] : ".")
  try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  MainActor.assumeIsolated {
    // A debug render must not overwrite the app's cache of last known values.
    let store = UsageStore(cacheURL: nil)
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
      let renderer = ImageRenderer(content: PanelView(store: store, updater: Updater(), onOpenSettings: {}, onQuit: {})
        .background(scheme == .dark ? Color(white: 0.16) : Color(white: 0.96))
        .environment(\.colorScheme, scheme))
      renderer.scale = 2
      write(renderer.nsImage, "panel-\(scheme == .dark ? "dark" : "light").png")
    }
    let about = ImageRenderer(content: AboutView(updater: Updater()).background(Color(white: 0.96)))
    about.scale = 2
    write(about.nsImage, "about.png")
    let icon = StatusIcon.image(used: store.iconRemaining.map { 1 - $0 }, alert: store.alertColor, critical: store.alertLevel == .critical)
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
