import AgentWatcherCore
import AppKit
import SwiftUI

struct AboutView: View {
  @ObservedObject var updater: Updater

  var body: some View {
    VStack(spacing: 14) {
      Image(nsImage: NSApplication.shared.applicationIconImage)
        .resizable()
        .frame(width: 96, height: 96)

      VStack(spacing: 4) {
        Text("Agent Watcher").font(.title2.weight(.semibold))
        Text("Version \(updater.versionString) (\(updater.buildString))")
          .font(.callout)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      }

      Text("Usage limits of Claude Code, Codex and Cursor in the menu bar.")
        .font(.callout)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)

      UpdateStatusView(updater: updater, showsCheckButton: true)

      HStack(spacing: 16) {
        Link("GitHub", destination: Updater.repositoryURL)
        Link("Releases", destination: Updater.repositoryURL.appendingPathComponent("releases"))
        Link("Report an issue", destination: Updater.repositoryURL.appendingPathComponent("issues"))
      }
      .font(.callout)

      Text(verbatim: "© \(Calendar.current.component(.year, from: Date())) Belizário Ribeiro · MIT License")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(24)
    .frame(width: 360)
    .environment(\.locale, Locale(identifier: "en_US"))
  }
}

/// The updater's state in one line, with the action that fits it.
struct UpdateStatusView: View {
  @ObservedObject var updater: Updater
  var showsCheckButton = false

  var body: some View {
    switch updater.state {
    case .checking:
      HStack(spacing: 6) {
        ProgressView().controlSize(.small)
        Text("Checking for updates…").font(.callout).foregroundStyle(.secondary)
      }
    case .installing(let release):
      HStack(spacing: 6) {
        ProgressView().controlSize(.small)
        Text("Installing \(release.version.description)…").font(.callout).foregroundStyle(.secondary)
      }
    case .available(let release):
      VStack(spacing: 6) {
        Text("Version \(release.version.description) is available.").font(.callout.weight(.medium))
        HStack {
          if updater.notInstallableReason == nil {
            Button("Install and Relaunch") { updater.install(release) }
              .keyboardShortcut(.defaultAction)
          }
          Button("Release Notes") { NSWorkspace.shared.open(release.pageURL) }
        }
        if let reason = updater.notInstallableReason {
          Text(reason).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
      }
    case .failed(let message):
      VStack(spacing: 6) {
        Label(message, systemImage: "exclamationmark.triangle")
          .font(.caption)
          .foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
        if showsCheckButton { checkButton }
      }
    case .upToDate, .idle:
      VStack(spacing: 6) {
        if updater.state == .upToDate {
          Text("Agent Watcher is up to date.").font(.callout).foregroundStyle(.secondary)
        }
        if showsCheckButton { checkButton }
      }
    }
  }

  private var checkButton: some View {
    Button("Check for Updates") { updater.check() }
  }
}

@MainActor
final class AboutWindowController {
  private var window: NSWindow?
  private let updater: Updater

  init(updater: Updater) { self.updater = updater }

  func show() {
    if window == nil {
      let window = NSWindow(contentViewController: NSHostingController(rootView: AboutView(updater: updater)))
      window.title = "About Agent Watcher"
      window.styleMask = [.titled, .closable]
      window.isReleasedWhenClosed = false
      window.center()
      self.window = window
    }
    NSApp.activate()
    window?.makeKeyAndOrderFront(nil)
  }
}
