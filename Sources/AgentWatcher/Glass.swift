import AppKit
import SwiftUI

/// Liquid Glass for the few custom views that need it (system controls get
/// it on their own), and the flat look it replaces before macOS 26. The
/// compiler check keeps older toolchains (an SDK without the glass API)
/// building the fallback.
extension View {
  /// A chip of glass in `shape`; `fallback` fills it before macOS 26.
  @ViewBuilder
  func glassSurface<S: Shape>(in shape: S, fallback: some ShapeStyle) -> some View {
    #if compiler(>=6.2)
    if #available(macOS 26, *) {
      self.glassEffect(.regular, in: shape)
    } else {
      self.background(fallback, in: shape)
    }
    #else
    self.background(fallback, in: shape)
    #endif
  }
}

/// Whether this Mac draws Liquid Glass, for the few places that change shape with it.
var hasLiquidGlass: Bool {
  #if compiler(>=6.2)
  if #available(macOS 26, *) { return true }
  #endif
  return false
}

