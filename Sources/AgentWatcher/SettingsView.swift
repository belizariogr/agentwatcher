import AgentWatcherCore
import AppKit
import ServiceManagement
import SwiftUI

/// A threshold row: the colored dot in the label, a slider snapped to whole
/// percents, and the value it lands on.
private struct ThresholdSlider: View {
  let label: String
  let color: AlertLevel
  @Binding var value: Double
  let range: ClosedRange<Double>

  var body: some View {
    LabeledContent {
      HStack(spacing: 10) {
        // No `step:`, which would draw a tick per step; snap to whole percents here instead.
        Slider(value: Binding(
          get: { value },
          set: { new in
            let snapped = (new / Alert.step).rounded() * Alert.step
            if snapped != value { value = snapped }
          }
        ), in: range)
        .labelsHidden()
        .frame(width: 190)
        Text("\(Int((value * 100).rounded()))% left")
          .monospacedDigit()
          .frame(width: 64, alignment: .leading)
      }
    } label: {
      HStack(spacing: 6) {
        Circle()
          .fill(Color(StatusIcon.nsColor(Alert.color(color))))
          .frame(width: 8, height: 8)
        Text(label)
      }
    }
  }
}

/// Settings are split into toolbar tabs, like the system's own: what to
/// watch and how often, how the limits are drawn, and updates.
enum SettingsTab: String, CaseIterable {
  case general, limits, updates

  var title: String {
    switch self {
    case .general: "General"
    case .limits: "Limits"
    case .updates: "Updates"
    }
  }

  var symbol: String {
    switch self {
    case .general: "gearshape"
    case .limits: "gauge.with.dots.needle.50percent"
    case .updates: "arrow.down.circle"
    }
  }
}

/// A note under a row's controls, in the right-hand column.
private struct Note: View {
  let text: Text
  init(_ text: Text) { self.text = text }
  init(_ string: String) { self.text = Text(string) }

  var body: some View {
    text
      .font(.callout)
      .foregroundStyle(.secondary)
      .multilineTextAlignment(.leading)
      .frame(maxWidth: 300, alignment: .leading)
      .fixedSize(horizontal: false, vertical: true)
  }
}

/// Laid out like Safari's settings: labels ending in a colon, right-aligned
/// in a column of their own, with the controls and checkboxes beside them.
private struct SettingsPage<Content: View>: View {
  @ViewBuilder var content: Content

  var body: some View {
    Form { content }
      .formStyle(.columns)
      .toggleStyle(.checkbox)
      .padding(.horizontal, 32)
      .padding(.vertical, 24)
      .frame(width: SettingsWindowController.width)
      .fixedSize(horizontal: false, vertical: true)
      .environment(\.locale, Locale(identifier: "en_US"))
  }
}

struct GeneralSettings: View {
  @ObservedObject var store: UsageStore

  var body: some View {
    SettingsPage {
      Section {
        LabeledContent("Refresh every:") {
          // Only the menu is sized here, not the label beside it.
          Picker("Refresh every", selection: $store.refreshInterval) {
            ForEach(UsageStore.refreshIntervalChoices, id: \.self) { seconds in
              Text(Self.intervalLabel(seconds)).tag(seconds)
            }
          }
          .labelsHidden()
          .frame(width: 130)
        }
        LabeledContent("Startup:") {
          LaunchAtLoginToggle()
        }
      }

      Section {
        LabeledContent("Harnesses:") {
          VStack(alignment: .leading, spacing: 7) {
            ForEach(store.providers, id: \.id) { provider in
              let installed = provider.isInstalled()
              Toggle(isOn: Binding(
                get: { !store.isHidden(provider.id) },
                set: { store.setHidden(provider.id, !$0) }
              )) {
                HStack(spacing: 6) {
                  ProviderLogo(id: provider.id, size: 15)
                  Text(provider.name)
                  if !installed {
                    Text("Not installed").foregroundStyle(.secondary)
                  }
                }
              }
            }
            Note("Hidden harnesses are not checked and never color the menu bar icon.")
          }
        }
        .padding(.top, 14)
      }
    }
  }

  static func intervalLabel(_ seconds: TimeInterval) -> String {
    let minutes = Int(seconds / 60)
    if minutes >= 60 { return minutes == 60 ? "1 hour" : "\(minutes / 60) hours" }
    return minutes == 1 ? "1 minute" : "\(minutes) minutes"
  }
}

struct LimitsSettings: View {
  @ObservedObject var store: UsageStore

  var body: some View {
    SettingsPage {
      Section {
        ThresholdSlider(label: "Orange at:", color: .warning, value: $store.warningThreshold, range: 0.01...0.5)
        ThresholdSlider(label: "Red at:", color: .critical, value: $store.criticalThreshold, range: 0...0.49)
        LabeledContent("") {
          Note("The menu bar icon and the bars turn orange, then red, when a harness has this much or less left.")
        }
      }

      Section {
        LabeledContent("Pace:") {
          Toggle("Show pace marker", isOn: $store.showPace)
        }
        .padding(.top, 14)
        LabeledContent("Leave out:") {
          VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 16) {
              Toggle("Saturdays", isOn: $store.paceSkipSaturday)
              Toggle("Sundays", isOn: $store.paceSkipSunday)
            }
            .disabled(!store.showPace)
            Note("The marker is how much would be left by now if the allowance were spread evenly until the reset. Days left out apply to weekly and monthly windows.")
          }
        }
      }
    }
  }
}

struct UpdatesSettings: View {
  @ObservedObject var updater: Updater

  private var footer: Text {
    if let reason = updater.notInstallableReason { return Text(reason) }
    if !updater.isReleaseBuild { return Text("This is a local build: it reports new releases but doesn't replace itself.") }
    if let last = updater.lastCheck { return Text("From GitHub Releases. Last checked \(last, format: .relative(presentation: .named)).") }
    return Text("From GitHub Releases, every 6 hours.")
  }

  var body: some View {
    SettingsPage {
      Section {
        LabeledContent("Updates:") {
          VStack(alignment: .leading, spacing: 7) {
            Toggle("Check for updates automatically", isOn: $updater.checkAutomatically)
            Toggle("Install updates automatically", isOn: $updater.installAutomatically)
              .disabled(!updater.checkAutomatically)
          }
        }
      }

      Section {
        LabeledContent("Version:") {
          VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 12) {
              Text(updater.versionString).monospacedDigit()
              Button("Check Now") { updater.check() }
                .disabled(updater.state == .checking)
            }
            Note(footer)
          }
        }
        .padding(.top, 14)
      }
    }
  }
}

/// Only meaningful when running from the .app bundle. The status is read
/// from the system each time, so changes made in System Settings show up and a
/// failed change snaps back without another register/unregister round.
struct LaunchAtLoginToggle: View {
  @State private var status = SMAppService.mainApp.status

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Toggle("Launch at login", isOn: Binding(
        get: { status == .enabled || status == .requiresApproval },
        set: { wanted in
          try? wanted ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
          status = SMAppService.mainApp.status
        }
      ))
      if status == .requiresApproval {
        Text("Allow Agent Watcher in System Settings › General › Login Items.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .onAppear { status = SMAppService.mainApp.status }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      status = SMAppService.mainApp.status
    }
  }
}

/// The system's own toolbar tabs, as in Safari's settings: the selected tab
/// in the accent color, Liquid Glass on macOS 26, and the window resized to
/// each page.
final class SettingsTabController: NSTabViewController {
  override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
    super.tabView(tabView, didSelect: tabViewItem)
    fitWindow(animated: view.window?.isVisible == true)
  }

  /// A page that grows (a footer that changes, a login note) resizes the window too.
  override func preferredContentSizeDidChange(for viewController: NSViewController) {
    super.preferredContentSizeDidChange(for: viewController)
    if tabViewItems[selectedTabViewItemIndex].viewController === viewController { fitWindow(animated: false) }
  }

  func fitWindow(animated: Bool) {
    guard let window = view.window, let page = tabViewItems[selectedTabViewItemIndex].viewController else { return }
    page.view.layoutSubtreeIfNeeded()
    let size = page.view.fittingSize
    guard size.width > 0, size.height > 0 else { return }
    var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
    // Keep the title bar where it is.
    frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
    window.setFrame(frame, display: true, animate: animated)
  }
}

@MainActor
final class SettingsWindowController {
  static let width: CGFloat = 560

  private var window: NSWindow?
  private var tabs: SettingsTabController?
  private let store: UsageStore
  private let updater: Updater

  init(store: UsageStore, updater: Updater) {
    self.store = store
    self.updater = updater
  }

  func show() {
    makeWindow()
    NSApp.activate()
    window?.makeKeyAndOrderFront(nil)
  }

  /// Built once; reopening keeps the last tab.
  @discardableResult
  func makeWindow() -> NSWindow {
    if let window { return window }
    let tabs = SettingsTabController()
    tabs.tabStyle = .toolbar
    for tab in SettingsTab.allCases {
      let page: NSViewController
      switch tab {
      case .general: page = Self.page(GeneralSettings(store: store))
      case .limits: page = Self.page(LimitsSettings(store: store))
      case .updates: page = Self.page(UpdatesSettings(updater: updater))
      }
      page.title = tab.title
      let item = NSTabViewItem(viewController: page)
      item.label = tab.title
      item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
      tabs.addTabViewItem(item)
    }
    let window = NSWindow(contentViewController: tabs)
    window.styleMask = [.titled, .closable]
    window.toolbarStyle = .preference
    window.isReleasedWhenClosed = false
    self.tabs = tabs
    self.window = window
    tabs.fitWindow(animated: false)
    window.center()
    return window
  }

  /// A page that reports its SwiftUI size, so the tabs can fit the window to it.
  private static func page<Page: View>(_ view: Page) -> NSViewController {
    let controller = NSHostingController(rootView: view)
    controller.sizingOptions = [.preferredContentSize]
    return controller
  }

  /// Selects a tab, for the debug render.
  func select(_ tab: SettingsTab) {
    makeWindow()
    tabs?.selectedTabViewItemIndex = SettingsTab.allCases.firstIndex(of: tab) ?? 0
  }
}
