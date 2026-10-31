import AgentWatcherCore
import SwiftUI

struct PanelView: View {
  @ObservedObject var store: UsageStore
  @ObservedObject var updater: Updater
  var onOpenSettings: () -> Void
  var onOpenAbout: () -> Void = {}
  var onQuit: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      header

      if store.usages.isEmpty {
        Text(store.isRefreshing ? "Loading…" : "No harness to show.\nClaude Code, Codex and Cursor show up here when installed and enabled in Settings.")
          .font(.callout)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .center)
          .multilineTextAlignment(.center)
          .padding(.vertical, 24)
      } else {
        ForEach(store.usages) { usage in
          ProviderCard(usage: usage, warning: store.warningThreshold, critical: store.criticalThreshold)
        }
      }

      updateBanner

      Divider()
      footer
    }
    .padding(14)
    .frame(width: 340)
    .environment(\.locale, Locale(identifier: "en_US"))
  }

  private var header: some View {
    HStack {
      Text("Agent Watcher").font(.headline)
      Spacer()
      if let last = store.lastRefresh {
        TimelineView(.periodic(from: .now, by: 30)) { _ in
          Text(last, format: .relative(presentation: .named))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      // A fixed frame, and no repeating animation: a repeatForever rotation
      // also animated the button's position while the popover laid out.
      ZStack {
        if store.isRefreshing {
          ProgressView().controlSize(.small).scaleEffect(0.75)
        } else {
          Button {
            store.refresh()
          } label: {
            Image(systemName: "arrow.clockwise")
          }
          .buttonStyle(.borderless)
          .help("Refresh now")
        }
      }
      .frame(width: 18, height: 18)
    }
  }

  @ViewBuilder private var updateBanner: some View {
    switch updater.state {
    case .available(let release):
      HStack(spacing: 8) {
        Image(systemName: "arrow.down.circle.fill").foregroundStyle(Color.accentColor)
        Text("Version \(release.version.description) is available").font(.callout)
        Spacer()
        if updater.notInstallableReason == nil {
          Button("Install") { updater.install(release) }.controlSize(.small)
        } else {
          Button("Download") { NSWorkspace.shared.open(release.pageURL) }.controlSize(.small)
        }
      }
    case .installing(let release):
      HStack(spacing: 8) {
        ProgressView().controlSize(.small).scaleEffect(0.75).frame(width: 16, height: 16)
        Text("Installing \(release.version.description)…").font(.callout).foregroundStyle(.secondary)
      }
    default:
      EmptyView()
    }
  }

  private var footer: some View {
    HStack {
      Button {
        onOpenSettings()
      } label: {
        Label("Settings", systemImage: "gearshape")
      }
      .buttonStyle(.borderless)
      .keyboardShortcut(",")
      Button {
        onOpenAbout()
      } label: {
        Label("About", systemImage: "info.circle")
      }
      .buttonStyle(.borderless)
      Spacer()
      Button("Quit", action: onQuit)
        .buttonStyle(.borderless)
        .keyboardShortcut("q")
    }
    .font(.callout)
  }
}

struct ProviderCard: View {
  let usage: ProviderUsage
  let warning: Double
  let critical: Double

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        ProviderLogo(id: usage.id, size: 18)
        Text(usage.name).font(.system(size: 13, weight: .semibold))
        if let plan = usage.plan {
          Text(plan)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(.quaternary, in: Capsule())
        }
        Spacer()
      }

      // A rate limit is routine: keep showing the last numbers, no warning.
      if usage.rateLimited {
        if usage.limits.isEmpty {
          Text("Waiting for data…").font(.caption).foregroundStyle(.secondary)
        }
      } else if let message = usage.message {
        Label {
          Text(Self.styled(message))
        } icon: {
          Image(systemName: usage.needsLogin ? "person.crop.circle.badge.xmark" : "exclamationmark.triangle")
        }
          .font(.caption)
          .foregroundStyle(usage.needsLogin ? Color.red : Color.orange)
          .fixedSize(horizontal: false, vertical: true)
      }
      if usage.message != nil, !usage.rateLimited, !usage.limits.isEmpty, let fetchedAt = usage.fetchedAt {
        TimelineView(.periodic(from: .now, by: 30)) { _ in
          Text("Last known values, from \(fetchedAt, format: .relative(presentation: .named))")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      ForEach(usage.visibleLimits) { limit in
        LimitRow(limit: limit, warning: warning, critical: critical)
      }
    }
    .padding(10)
    .background(.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
  }

}

extension ProviderCard {
  /// `code` spans in monospace, everything else verbatim. Not Markdown: the
  /// message can carry server text, which must not turn into links.
  static func styled(_ message: String) -> AttributedString {
    var result = AttributedString()
    for (index, part) in message.split(separator: "`", omittingEmptySubsequences: false).enumerated() {
      var piece = AttributedString(String(part))
      if index % 2 == 1 { piece.font = .caption.monospaced() }
      result += piece
    }
    return result
  }
}

struct ProviderLogo: View {
  let id: String
  let size: CGFloat

  var body: some View {
    if let image = Logos.image(for: id) {
      Image(nsImage: image)
        .resizable()
        .renderingMode(image.isTemplate ? .template : .original)
        .scaledToFit()
        .frame(width: size, height: size)
    } else {
      Image(systemName: "cpu").frame(width: size, height: size)
    }
  }
}

struct LimitRow: View {
  let limit: UsageLimit
  let warning: Double
  let critical: Double

  var body: some View {
    TimelineView(.periodic(from: .now, by: 60)) { context in
      let used = limit.effectiveUsed(now: context.date)
      let level = Alert.level(remaining: 1 - used, warning: warning, critical: critical)
      let tint = Alert.color(remaining: 1 - used, warning: warning, critical: critical)
        .map { Color(StatusIcon.nsColor($0)) } ?? Color.accentColor

      VStack(alignment: .leading, spacing: 4) {
        HStack {
          Text(limit.title).font(.callout)
          Spacer()
          Text("\(Alert.percentLeft(1 - used))% left")
            .font(.callout.monospacedDigit().weight(level == nil ? .regular : .semibold))
            .foregroundStyle(level == nil ? Color.primary : tint)
        }
        Meter(value: used, tint: tint)
        HStack {
          Text("\(100 - Alert.percentLeft(1 - used))% used")
          Spacer()
          if let resetsAt = limit.resetsAt, resetsAt > context.date {
            Text("Resets in \(Self.duration(resetsAt.timeIntervalSince(context.date)))")
          }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    }
  }

  static func duration(_ seconds: TimeInterval) -> String {
    let minutes = Int(seconds / 60)
    let days = minutes / 1440, hours = (minutes % 1440) / 60, mins = minutes % 60
    if days > 0 { return "\(days)d \(hours)h" }
    if hours > 0 { return "\(hours)h \(mins)m" }
    return "\(max(mins, 1))m"
  }
}

struct Meter: View {
  let value: Double
  let tint: Color

  var body: some View {
    GeometryReader { geo in
      ZStack(alignment: .leading) {
        Capsule().fill(.quaternary)
        Capsule().fill(tint).frame(width: max(0, geo.size.width * min(value, 1)))
      }
    }
    .frame(height: 6)
  }
}
