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
          ProviderCard(
            usage: usage,
            warning: store.warningThreshold,
            critical: store.criticalThreshold,
            pace: store.showPace ? store.paceOptions : nil,
            selected: store.pinnedProviderID == usage.id,
            onSelect: { store.togglePinnedProvider(usage.id) }
          )
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
  /// Nil hides the pace.
  var pace: PaceOptions? = PaceOptions()
  var selected: Bool = false
  var onSelect: () -> Void = {}

  var body: some View {
    Button(action: onSelect) {
      card
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(selected ? .isSelected : [])
    .help(selected
      ? "Menu bar icon follows \(usage.name). Click again for automatic."
      : "Show \(usage.name) on the menu bar icon")
  }

  private var card: some View {
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
        LimitRow(limit: limit, warning: warning, critical: critical, pace: pace)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(10)
    .background(.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    .overlay(alignment: .topTrailing) {
      if selected {
        Image(systemName: "checkmark.circle.fill")
          .font(.system(size: 14))
          .foregroundStyle(.white, Color.green)
          .padding(6)
          .accessibilityHidden(true)
      }
    }
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .strokeBorder(selected ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: selected ? 2 : 1)
    )
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
  var pace: PaceOptions? = PaceOptions()

  var body: some View {
    TimelineView(.periodic(from: .now, by: 60)) { context in
      let now = context.date
      let remaining = limit.remaining(now: now)
      let level = Alert.level(remaining: remaining, warning: warning, critical: critical)
      let tint = Alert.color(remaining: remaining, warning: warning, critical: critical)
        .map { Color(StatusIcon.nsColor($0)) } ?? Color.accentColor
      let reading = pace.flatMap { limit.pace(now: now, options: $0) }

      VStack(alignment: .leading, spacing: 4) {
        HStack {
          Text(limit.title).font(.callout)
          Spacer()
          Text("\(limit.percentLeftText(now: now)) left")
            .font(.callout.monospacedDigit().weight(level == nil ? .regular : .semibold))
            .foregroundStyle(level == nil ? Color.primary : tint)
        }
        Meter(value: remaining, tint: tint, marker: reading?.expectedRemaining, dayMarks: reading?.dayMarks ?? [])
        HStack(spacing: 4) {
          if let reading {
            Text(reading.label)
              .foregroundStyle(reading.deltaPercent > 0 && reading.delta > 0 ? Color.orange : Color.secondary)
            if let runsOut = reading.runsOutAt {
              Text("· runs out in \(Self.duration(runsOut.timeIntervalSince(now)))")
            }
          } else {
            Text("\(limit.percentUsedText(now: now)) used")
          }
          Spacer()
          if let resetsAt = limit.resetsAt, resetsAt > now {
            Text("Resets in \(Self.duration(resetsAt.timeIntervalSince(now)))")
          }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
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

/// What is left of an allowance: the fill shrinks toward zero as it is used.
/// `marker` is where an even spread until the reset would be by now; fill
/// short of it means spending faster than the pace. `dayMarks` split the bar
/// into the window's days.
struct Meter: View {
  let value: Double
  let tint: Color
  var marker: Double? = nil
  var dayMarks: [Double] = []

  var body: some View {
    GeometryReader { geo in
      let width = geo.size.width
      ZStack(alignment: .leading) {
        Capsule().fill(.quaternary)
        Capsule().fill(tint).frame(width: max(0, width * min(max(value, 0), 1)))
        ForEach(dayMarks, id: \.self) { mark in
          Rectangle()
            .fill(Color(nsColor: .windowBackgroundColor).opacity(0.7))
            .frame(width: 1)
            .offset(x: width * mark - 0.5)
        }
      }
      .clipShape(Capsule())
      .overlay(alignment: .leading) {
        if let marker {
          // Pulled in at the ends so the line stays visible on the rounded caps.
          RoundedRectangle(cornerRadius: 1)
            .fill(Color.primary)
            .frame(width: 2, height: geo.size.height + 6)
            .offset(x: min(max(width * marker - 1, 1), width - 3))
        }
      }
    }
    .frame(height: 8)
    .padding(.vertical, marker == nil ? 0 : 3)
    .accessibilityElement()
    .accessibilityLabel("\(Int((value * 100).rounded()))% left")
  }
}
