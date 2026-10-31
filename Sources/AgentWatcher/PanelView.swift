import AgentWatcherCore
import SwiftUI

struct PanelView: View {
  @ObservedObject var store: UsageStore
  var onOpenSettings: () -> Void
  var onQuit: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      header

      if store.usages.isEmpty {
        Text(store.isRefreshing ? "Carregando…" : "Nenhum harness para mostrar.\nClaude Code, Codex e Cursor aparecem aqui quando instalados e ativos nas configurações.")
          .font(.callout)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .center)
          .multilineTextAlignment(.center)
          .padding(.vertical, 24)
      } else {
        ForEach(store.usages) { usage in
          ProviderCard(usage: usage, threshold: store.alertThreshold)
        }
      }

      Divider()
      footer
    }
    .padding(14)
    .frame(width: 340)
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
          .help("Atualizar agora")
        }
      }
      .frame(width: 18, height: 18)
    }
  }

  private var footer: some View {
    HStack {
      Button {
        onOpenSettings()
      } label: {
        Label("Configurações", systemImage: "gearshape")
      }
      .buttonStyle(.borderless)
      .keyboardShortcut(",")
      Spacer()
      Button("Sair", action: onQuit)
        .buttonStyle(.borderless)
        .keyboardShortcut("q")
    }
    .font(.callout)
  }
}

struct ProviderCard: View {
  let usage: ProviderUsage
  let threshold: Double

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

      if let message = usage.message {
        Label(message, systemImage: "exclamationmark.triangle")
          .font(.caption)
          .foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
      }

      ForEach(usage.limits) { limit in
        LimitRow(limit: limit, threshold: threshold)
      }
    }
    .padding(10)
    .background(.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
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
  let threshold: Double

  var body: some View {
    TimelineView(.periodic(from: .now, by: 60)) { context in
      let used = limit.effectiveUsed(now: context.date)
      let severity = Alert.severity(remaining: 1 - used, threshold: threshold)
      let tint = severity.map { Color(StatusIcon.nsColor(Alert.color(severity: $0))) } ?? Color.accentColor

      VStack(alignment: .leading, spacing: 4) {
        HStack {
          Text(limit.title).font(.callout)
          Spacer()
          Text("\(Int((used * 100).rounded()))% usado")
            .font(.callout.monospacedDigit().weight(severity == nil ? .regular : .semibold))
            .foregroundStyle(severity == nil ? Color.primary : tint)
        }
        Meter(value: used, tint: tint)
        HStack {
          Text("Restam \(Int(((1 - used) * 100).rounded()))%")
          Spacer()
          if let resetsAt = limit.resetsAt, resetsAt > context.date {
            Text("Renova em \(Self.duration(resetsAt.timeIntervalSince(context.date)))")
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
    if hours > 0 { return "\(hours)h \(mins)min" }
    return "\(max(mins, 1))min"
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
