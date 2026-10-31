import AgentWatcherCore
import AppKit
import ServiceManagement
import SwiftUI

private struct ThresholdSlider: View {
  let label: String
  let color: AlertLevel
  @Binding var value: Double
  let range: ClosedRange<Double>

  var body: some View {
    HStack {
      // No `step:`, which would draw a tick per step; snap to whole percents here instead.
      Slider(value: Binding(
        get: { value },
        set: { new in
          let snapped = (new / Alert.step).rounded() * Alert.step
          if snapped != value { value = snapped }
        }
      ), in: range) {
        HStack(spacing: 6) {
          Circle()
            .fill(Color(StatusIcon.nsColor(Alert.color(color))))
            .frame(width: 8, height: 8)
          Text(label)
        }
      }
      Text("\(Int((value * 100).rounded()))% left")
        .monospacedDigit()
        .frame(width: 100, alignment: .trailing)
    }
  }
}

struct SettingsView: View {
  @ObservedObject var store: UsageStore
  @ObservedObject var updater: Updater

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
        ThresholdSlider(label: "Orange at", color: .warning, value: $store.warningThreshold, range: 0.01...0.5)
        ThresholdSlider(label: "Red at", color: .critical, value: $store.criticalThreshold, range: 0...0.49)
      } header: {
        Text("Alert")
      } footer: {
        Text("The menu bar icon and the panel turn orange, then red, when any harness has this much or less left.")
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

      Section {
        Toggle("Check for updates automatically", isOn: $updater.checkAutomatically)
        Toggle("Install updates automatically", isOn: $updater.installAutomatically)
          .disabled(!updater.checkAutomatically)
        HStack {
          Text("Version \(updater.versionString)").foregroundStyle(.secondary)
          Spacer()
          Button("Check Now") { updater.check() }
            .disabled(updater.state == .checking)
        }
      } header: {
        Text("Updates")
      } footer: {
        Group {
          if let reason = updater.notInstallableReason {
            Text(reason)
          } else if !updater.isReleaseBuild {
            Text("This is a local build: it reports new releases but doesn't replace itself.")
          } else if let last = updater.lastCheck {
            Text("From GitHub Releases. Last checked \(last, format: .relative(presentation: .named)).")
          } else {
            Text("From GitHub Releases, every 6 hours.")
          }
        }
        .foregroundStyle(.secondary)
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
  private let updater: Updater

  init(store: UsageStore, updater: Updater) {
    self.store = store
    self.updater = updater
  }

  func show() {
    if window == nil {
      let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(store: store, updater: updater)))
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
