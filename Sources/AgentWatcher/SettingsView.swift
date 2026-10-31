import AgentWatcherCore
import AppKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
  @ObservedObject var store: UsageStore

  var body: some View {
    Form {
      Section("Refresh") {
        Picker("Refresh every", selection: $store.refreshInterval) {
          ForEach(UsageStore.refreshIntervalChoices, id: \.self) { seconds in
            Text(Self.intervalLabel(seconds)).tag(seconds)
          }
        }
        LaunchAtLoginToggle()
      }

      Section {
        HStack {
          Slider(value: $store.alertThreshold, in: 0.05...0.5, step: 0.05) {
            Text("Alert at")
          }
          Text("\(Int((store.alertThreshold * 100).rounded()))% left")
            .monospacedDigit()
            .frame(width: 100, alignment: .trailing)
        }
      } header: {
        Text("Alert")
      } footer: {
        Text("Below this, the menu bar icon goes from yellow to red.")
          .foregroundStyle(.secondary)
      }

      Section("Harnesses") {
        ForEach(store.providers, id: \.id) { provider in
          let installed = provider.isInstalled()
          Toggle(isOn: Binding(
            get: { !store.isHidden(provider.id) },
            set: { store.setHidden(provider.id, !$0) }
          )) {
            HStack(spacing: 8) {
              ProviderLogo(id: provider.id, size: 16)
              VStack(alignment: .leading, spacing: 1) {
                Text(provider.name)
                if !installed {
                  Text("Not installed").font(.caption).foregroundStyle(.secondary)
                }
              }
            }
          }
        }
      }
    }
    .formStyle(.grouped)
    .frame(width: 420)
    .fixedSize(horizontal: false, vertical: true)
    .environment(\.locale, Locale(identifier: "en_US"))
  }

  static func intervalLabel(_ seconds: TimeInterval) -> String {
    let minutes = Int(seconds / 60)
    if minutes >= 60 { return minutes == 60 ? "1 hour" : "\(minutes / 60) hours" }
    return minutes == 1 ? "1 minute" : "\(minutes) minutes"
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

@MainActor
final class SettingsWindowController {
  private var window: NSWindow?
  private let store: UsageStore

  init(store: UsageStore) { self.store = store }

  func show() {
    if window == nil {
      let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(store: store)))
      window.title = "Agent Watcher Settings"
      window.styleMask = [.titled, .closable]
      window.isReleasedWhenClosed = false
      window.center()
      self.window = window
    }
    NSApp.activate()
    window?.makeKeyAndOrderFront(nil)
  }
}
