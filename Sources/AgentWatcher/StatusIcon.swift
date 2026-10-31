import AgentWatcherCore
import AppKit

/// The menu bar glyph: a ring gauge filled to the tightest limit across
/// every harness. While there is room it is a template image and follows
/// the menu bar's own color; once a harness drops to the alert threshold it
/// is drawn in the alert color, walking from yellow to red.
enum StatusIcon {
  static let size = NSSize(width: 18, height: 18)

  static func image(used: Double?, severity: Double?) -> NSImage {
    let color: NSColor = severity.map { nsColor(Alert.color(severity: $0)) } ?? .black
    let image = NSImage(size: size, flipped: false) { rect in
      let lineWidth: CGFloat = 2.2
      let ring = rect.insetBy(dx: lineWidth / 2 + 0.5, dy: lineWidth / 2 + 0.5)
      let center = NSPoint(x: ring.midX, y: ring.midY)
      let radius = ring.width / 2

      let track = NSBezierPath(ovalIn: ring)
      track.lineWidth = lineWidth
      color.withAlphaComponent(0.3).setStroke()
      track.stroke()

      if let used, used > 0 {
        // Clockwise from 12 o'clock.
        let arc = NSBezierPath()
        arc.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - 360 * CGFloat(min(used, 1)), clockwise: true)
        arc.lineWidth = lineWidth
        arc.lineCapStyle = .round
        color.setStroke()
        arc.stroke()
      }

      let dot = NSBezierPath(ovalIn: NSRect(x: center.x - 2.5, y: center.y - 2.5, width: 5, height: 5))
      color.setFill()
      dot.fill()
      return true
    }
    image.isTemplate = severity == nil
    return image
  }

  static func nsColor(_ rgb: RGB) -> NSColor {
    NSColor(srgbRed: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1)
  }
}
