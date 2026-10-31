import AgentWatcherCore
import AppKit

/// The menu bar glyph: a sparkle inside a ring gauge filled to the tightest
/// limit across every harness. While there is room it is a template image
/// and follows the menu bar's own color; once a harness drops to the warning
/// threshold it is drawn orange, reddening on the way to the critical one.
/// Past the critical threshold the gauge gives way to a red warning sign.
enum StatusIcon {
  static let size = NSSize(width: 18, height: 18)

  static func image(used: Double?, alert: RGB?, critical: Bool = false) -> NSImage {
    if critical, let warning = warningSign() { return warning }
    let color: NSColor = alert.map(nsColor) ?? .black
    let image = NSImage(size: size, flipped: false) { rect in
      let lineWidth: CGFloat = 1.8
      let center = NSPoint(x: rect.midX, y: rect.midY)
      let radius: CGFloat = 7.6

      let track = NSBezierPath()
      track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
      track.lineWidth = lineWidth
      color.withAlphaComponent(0.3).setStroke()
      track.stroke()

      if let used, used > 0 {
        // Clockwise from 12 o'clock.
        let arc = NSBezierPath()
        arc.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - 360 * CGFloat(min(used, 0.9999)), clockwise: true)
        arc.lineWidth = lineWidth
        arc.lineCapStyle = .round
        color.setStroke()
        arc.stroke()
      }

      color.setFill()
      sparkle(center: center, radius: 4.4).fill()
      return true
    }
    image.isTemplate = alert == nil
    return image
  }

  /// A filled red triangle with a white exclamation mark.
  static func warningSign() -> NSImage? {
    let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .bold)
      .applying(.init(paletteColors: [.white, nsColor(Alert.red)]))
    guard let symbol = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Usage almost exhausted")?
      .withSymbolConfiguration(config) else { return nil }
    let image = NSImage(size: size, flipped: false) { rect in
      let s = symbol.size
      symbol.draw(in: NSRect(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2, width: s.width, height: s.height))
      return true
    }
    image.isTemplate = false
    return image
  }

  /// A four-point star with concave sides, the same shape as the app icon's.
  static func sparkle(center c: NSPoint, radius s: CGFloat) -> NSBezierPath {
    let k = s * 0.22
    let path = NSBezierPath()
    path.move(to: NSPoint(x: c.x, y: c.y + s))
    path.curve(to: NSPoint(x: c.x + s, y: c.y), controlPoint1: NSPoint(x: c.x + k * 0.6, y: c.y + k), controlPoint2: NSPoint(x: c.x + k, y: c.y + k * 0.6))
    path.curve(to: NSPoint(x: c.x, y: c.y - s), controlPoint1: NSPoint(x: c.x + k, y: c.y - k * 0.6), controlPoint2: NSPoint(x: c.x + k * 0.6, y: c.y - k))
    path.curve(to: NSPoint(x: c.x - s, y: c.y), controlPoint1: NSPoint(x: c.x - k * 0.6, y: c.y - k), controlPoint2: NSPoint(x: c.x - k, y: c.y - k * 0.6))
    path.curve(to: NSPoint(x: c.x, y: c.y + s), controlPoint1: NSPoint(x: c.x - k, y: c.y + k * 0.6), controlPoint2: NSPoint(x: c.x - k * 0.6, y: c.y + k))
    path.close()
    return path
  }

  static func nsColor(_ rgb: RGB) -> NSColor {
    NSColor(srgbRed: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1)
  }
}
