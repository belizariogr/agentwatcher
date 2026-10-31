import AgentWatcherCore
import AppKit

/// The menu bar glyph: a sparkle inside a ring gauge filled to the tightest
/// limit across every harness. While there is room it is a template image
/// and follows the menu bar's own color; once a harness drops to the alert
/// threshold it is drawn in the alert color, walking from yellow to red.
enum StatusIcon {
  static let size = NSSize(width: 18, height: 18)

  static func image(used: Double?, severity: Double?) -> NSImage {
    let color: NSColor = severity.map { nsColor(Alert.color(severity: $0)) } ?? .black
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
    image.isTemplate = severity == nil
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
