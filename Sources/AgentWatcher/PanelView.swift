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
        VStack(spacing: 12) {
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
          .buttonStyle(.bordered)
          .buttonBorderShape(.circle)
          .help("Refresh now")
        }
      }
      .frame(width: hasLiquidGlass ? 30 : 18, height: hasLiquidGlass ? 30 : 18)
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
          Button("Install") { updater.install(release) }.controlSize(.small).buttonStyle(.borderedProminent)
        } else {
          Button("Download") { NSWorkspace.shared.open(release.pageURL) }.controlSize(.small).buttonStyle(.bordered)
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
      .buttonStyle(.bordered)
      .keyboardShortcut(",")
      Button {
        onOpenAbout()
      } label: {
        Label("About", systemImage: "info.circle")
      }
      .buttonStyle(.bordered)
      Spacer()
      Button("Quit", action: onQuit)
        .buttonStyle(.bordered)
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
        LimitRow(limit: limit, warning: warning, critical: critical, pace: pace, brand: Logos.brandColor(for: usage.id))
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(10)
    .background(.background.opacity(0.5), in: Self.shape)
    // The whole card takes the click, not only what is drawn in it.
    .contentShape(Self.shape)
    .overlay(alignment: .topTrailing) {
      if selected {
        Image(systemName: "checkmark.circle.fill")
          .font(.system(size: 14))
          .foregroundStyle(.white, Color.green)
          .padding(6)
          .accessibilityHidden(true)
      }
    }
    .overlay {
      Self.shape.strokeBorder(selected ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: selected ? 2 : 1)
    }
  }

  static let shape = RoundedRectangle(cornerRadius: 8)

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
  /// The harness' own color, toned down for the fill. Orange and red take
  /// over near the end.
  var brand: NSColor = .controlAccentColor

  var body: some View {
    TimelineView(.periodic(from: .now, by: 60)) { context in
      let now = context.date
      let remaining = limit.remaining(now: now)
      let level = Alert.level(remaining: remaining, warning: warning, critical: critical)
      let alert = Alert.color(remaining: remaining, warning: warning, critical: critical).map { Color(StatusIcon.nsColor($0)) }
      let reading = pace.flatMap { limit.pace(now: now, options: $0) }
      let resetsIn = limit.resetsAt.flatMap { $0 > now ? Self.duration($0.timeIntervalSince(now)) : nil }

      VStack(alignment: .leading, spacing: 5) {
        HStack {
          Text(limit.title).font(.callout)
          Spacer()
          Text("\(limit.percentLeftText(now: now)) left")
            .font(.callout.monospacedDigit().weight(level == nil ? .regular : .semibold))
            .foregroundStyle(alert ?? Color.primary)
        }
        Meter(
          value: remaining,
          tint: alert ?? Color(nsColor: Self.muted(brand)),
          marker: reading?.expectedRemaining,
          dayMarks: reading?.dayMarks ?? [],
          badge: resetsIn
        )
        HStack(spacing: 4) {
          if let reading {
            Text(reading.label)
              .foregroundStyle(reading.deltaPercent > 0 && reading.delta > 0 ? (alert ?? Color.orange) : Color.secondary)
            if let runsOut = reading.runsOutAt {
              Text("· runs out in \(Self.duration(runsOut.timeIntervalSince(now)))")
            }
          } else {
            Text("\(limit.percentUsedText(now: now)) used")
          }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
      }
    }
  }

  /// The brand color pulled toward the window background, so a full bar
  /// reads as calm and the alert colors stand out.
  static func muted(_ color: NSColor) -> NSColor {
    NSColor(name: nil) { appearance in
      let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
      let base = dark ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 1, alpha: 1)
      return color.usingColorSpace(.sRGB)?.blended(withFraction: dark ? 0.42 : 0.25, of: base) ?? color
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

/// What is left of an allowance: the fill shrinks toward zero as it is used,
/// over a hatched track for the part already spent. `marker` is where an
/// even spread until the reset would be by now; fill short of it means
/// spending faster than the pace. `dayMarks` split weekly bars into days, and
/// `badge` (time to the reset) sits inside the right end.
struct Meter: View {
  let value: Double
  let tint: Color
  var marker: Double? = nil
  var dayMarks: [Double] = []
  var badge: String? = nil

  private let height: CGFloat = 16
  private let corner: CGFloat = 5

  var body: some View {
    GeometryReader { geo in
      let width = geo.size.width
      let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
      ZStack(alignment: .leading) {
        shape.fill(.quaternary.opacity(0.6))
        Hatch().stroke(Color.primary.opacity(0.13), lineWidth: 1.5)
        shape.fill(tint).frame(width: max(0, width * min(max(value, 0), 1)))
        ForEach(dayMarks, id: \.self) { mark in
          Rectangle()
            .fill(Color(nsColor: .windowBackgroundColor).opacity(0.35))
            .frame(width: 1)
            .offset(x: width * mark - 0.5)
        }
      }
      .clipShape(shape)
      .overlay(alignment: .leading) {
        if let marker {
          // Pulled in at the ends so the line stays visible on the rounded caps.
          // Under the badge: only its ends above and below the bar show there.
          RoundedRectangle(cornerRadius: 1)
            .fill(Color.primary)
            .frame(width: 2, height: height + 6)
            .offset(x: min(max(width * marker - 1, 1), width - 3))
            .accessibilityHidden(true)
        }
      }
      .overlay(alignment: .trailing) {
        if let badge {
          HStack(spacing: 3) {
            Image(systemName: "arrow.clockwise").font(.system(size: 8, weight: .semibold))
            Text(badge).monospacedDigit()
          }
          .font(.system(size: 10, weight: .medium))
          .foregroundStyle(.primary)
          .padding(.horizontal, 5)
          .frame(height: height - 4)
          .glassSurface(in: RoundedRectangle(cornerRadius: corner - 2, style: .continuous), fallback: .background)
          .padding(.trailing, 2)
          .accessibilityLabel("Resets in \(badge)")
        }
      }
    }
    .frame(height: height)
    .padding(.vertical, marker == nil ? 0 : 3)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(Int((value * 100).rounded()))% left")
  }
}

/// Diagonal stripes across the whole rect, for the spent part of a bar.
struct Hatch: Shape {
  var spacing: CGFloat = 5

  func path(in rect: CGRect) -> Path {
    var path = Path()
    var x = rect.minX - rect.height
    while x < rect.maxX {
      path.move(to: CGPoint(x: x, y: rect.maxY))
      path.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
      x += spacing
    }
    return path
  }
}

