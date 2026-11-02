import AgentWatcherCore
import AppKit

/// The menu bar glyph: a four-point sparkle inside a 270° horseshoe gauge
/// (Gemini Tray 1). The open gap sits at 6 o'clock. While there is room it
/// is a template image and follows the menu bar's own color; once a harness
/// drops to the warning threshold it is drawn orange, reddening toward
/// critical. At critical the sparkle is replaced by a bang in the same seat.
/// When the allowance is gone, the bang becomes an X; the horseshoe stays.
enum StatusIcon {
  static let size = NSSize(width: 18, height: 18)
  /// Lower-left of the horseshoe. Clockwise 270° over the top ends at 4:30.
  static let arcStart: CGFloat = 225
  static let arcSpan: CGFloat = 270

  static func image(used: Double?, alert: RGB?, critical: Bool = false, exhausted: Bool = false) -> NSImage {
    let color: NSColor = alert.map(nsColor) ?? .black
    let image = NSImage(size: size, flipped: false) { rect in
      draw(in: rect, used: used, color: color, critical: critical || exhausted, exhausted: exhausted)
      return true
    }
    image.isTemplate = alert == nil && !critical && !exhausted
    return image
  }

  static func draw(in rect: NSRect, used: Double?, color: NSColor, critical: Bool, exhausted: Bool) {
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    let xform = NSAffineTransform()
    xform.translateX(by: rect.minX, yBy: rect.minY)
    xform.scaleX(by: rect.width / size.width, yBy: rect.height / size.height)
    xform.concat()

    let base = NSRect(origin: .zero, size: size)
    let lineWidth: CGFloat = 2.2
    let center = NSPoint(x: base.midX, y: base.midY + 0.55)
    let radius: CGFloat = 6.9
    let arcColor = (critical || exhausted) ? nsColor(Alert.red) : color

    let track = horseshoe(center: center, radius: radius, fraction: 1)
    track.lineWidth = lineWidth
    track.lineCapStyle = .round
    arcColor.withAlphaComponent(0.3).setStroke()
    track.stroke()

    let fillFraction: CGFloat = (critical || exhausted) ? 1 : CGFloat(min(max(used ?? 0, 0), 1))
    if fillFraction > 0 {
      let arc = horseshoe(center: center, radius: radius, fraction: fillFraction)
      arc.lineWidth = lineWidth
      arc.lineCapStyle = .round
      arcColor.setStroke()
      arc.stroke()
    }

    if exhausted {
      xMark(center: center, color: arcColor)
    } else if critical {
      bang(center: center, color: arcColor)
    } else {
      arcColor.setFill()
      sparkle(center: center, radius: 3.55).fill()
    }
  }

  /// Clockwise horseshoe from 7:30, spanning `fraction` of 270°.
  static func horseshoe(center: NSPoint, radius: CGFloat, fraction: CGFloat) -> NSBezierPath {
    let sweep = arcSpan * min(max(fraction, 0.0001), 1)
    let path = NSBezierPath()
    path.appendArc(
      withCenter: center,
      radius: radius,
      startAngle: arcStart,
      endAngle: arcStart - sweep,
      clockwise: true
    )
    return path
  }

  /// X in the sparkle's seat when the allowance is gone.
  static func xMark(center c: NSPoint, color: NSColor) {
    let d: CGFloat = 2.65
    let width: CGFloat = 1.85
    color.setStroke()
    for (a, b) in [
      (NSPoint(x: c.x - d, y: c.y + d), NSPoint(x: c.x + d, y: c.y - d)),
      (NSPoint(x: c.x - d, y: c.y - d), NSPoint(x: c.x + d, y: c.y + d)),
    ] {
      let path = NSBezierPath()
      path.move(to: a)
      path.line(to: b)
      path.lineWidth = width
      path.lineCapStyle = .round
      path.stroke()
    }
  }

  /// Exclamation occupying the sparkle's seat in the middle of the horseshoe.
  static func bang(center c: NSPoint, color: NSColor) {
    color.setFill()
    let stemW: CGFloat = 1.85
    let stemH: CGFloat = 4.5
    let gap: CGFloat = 0.9
    let dotR: CGFloat = 1.0
    let totalH = stemH + gap + dotR * 2
    let top = c.y + totalH / 2
    let stem = NSRect(x: c.x - stemW / 2, y: top - stemH, width: stemW, height: stemH)
    NSBezierPath(roundedRect: stem, xRadius: stemW / 2, yRadius: stemW / 2).fill()
    NSBezierPath(ovalIn: NSRect(
      x: c.x - dotR,
      y: top - stemH - gap - dotR * 2,
      width: dotR * 2,
      height: dotR * 2
    )).fill()
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
