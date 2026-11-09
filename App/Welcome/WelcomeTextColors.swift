import AppKit
import OpenDesign

/// Welcome has solid content surfaces. Sidebar accent tokens are only seeds:
/// evaluate their visible sRGB colors on each surface before using them as text.
enum WelcomeTextColors {
  /// One opaque active blue for every illustration. Keep white instructional
  /// text at AA by changing only the Open-blue seed's OKLab lightness.
  @MainActor static let illustrationBlue = readable(
    RGB(r: 61.0 / 255, g: 107.0 / 255, b: 1), on: RGB(r: 1, g: 1, b: 1), minimum: 4.5).color

  struct Pair {
    let primary: NSColor
    let secondary: NSColor
  }

  private struct RGB {
    var r: Double, g: Double, b: Double
    var color: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: 1) }
    var luminance: Double { 0.2126 * OKLab.decode(r) + 0.7152 * OKLab.decode(g) + 0.0722 * OKLab.decode(b) }
    func contrast(_ other: RGB) -> Double {
      (max(luminance, other.luminance) + 0.05) / (min(luminance, other.luminance) + 0.05)
    }
  }

  /// Resolve alpha before measuring. Returning an opaque color also prevents a
  /// parent tint or a second compositing pass from changing the measured ink.
  static func opaque(_ color: NSColor, over surface: NSColor) -> NSColor {
    composite(color, over: composite(surface, over: RGB(r: 1, g: 1, b: 1))).color
  }

  static func pair(primary: NSColor, secondary: NSColor, surface: NSColor) -> Pair {
    let base = composite(surface, over: RGB(r: 1, g: 1, b: 1))
    var detail = readable(composite(secondary, over: base), on: base, minimum: 4.5)
    let strongest = max(base.contrast(RGB(r: 0, g: 0, b: 0)), base.contrast(RGB(r: 1, g: 1, b: 1)))
    let secondaryLimit = max(4.5, strongest - 0.3)
    if detail.contrast(base) > secondaryLimit {
      // A secondary seed at black/white leaves no stronger primary. Move only
      // its L toward the surface just far enough to leave that hierarchy.
      let lab = OKLab.fromSRGB(detail.r, detail.g, detail.b)
      var failing = lab.L, passing = OKLab.fromSRGB(base.r, base.g, base.b).L
      for _ in 0..<24 {
        let middle = (failing + passing) / 2
        let candidate = color(lightness: middle, a: lab.a, b: lab.b)
        if candidate.contrast(base) <= secondaryLimit { passing = middle }
        else { failing = middle }
      }
      detail = color(lightness: passing, a: lab.a, b: lab.b)
    }
    // Keep the secondary hierarchy even when both sidebar tokens need repair.
    // Card titles are 17 pt; use the body target for them as well as headings.
    let title = readable(composite(primary, over: base), on: base,
      minimum: max(4.5, detail.contrast(base) + 0.3))
    return Pair(primary: title.color, secondary: detail.color)
  }

  private static func composite(_ color: NSColor, over surface: RGB) -> RGB {
    guard let rgb = color.usingColorSpace(.sRGB) else { return surface }
    let alpha = Double(rgb.alphaComponent)
    func channel(_ value: CGFloat, _ background: Double) -> Double {
      min(1, max(0, Double(value))) * alpha + background * (1 - alpha)
    }
    return RGB(r: channel(rgb.redComponent, surface.r), g: channel(rgb.greenComponent, surface.g),
      b: channel(rgb.blueComponent, surface.b))
  }

  private static func readable(_ seed: RGB, on surface: RGB, minimum: Double) -> RGB {
    guard seed.contrast(surface) < minimum else { return seed }
    let lab = OKLab.fromSRGB(seed.r, seed.g, seed.b)
    let darkInk = surface.contrast(RGB(r: 0, g: 0, b: 0)) >= surface.contrast(RGB(r: 1, g: 1, b: 1))
    func at(_ lightness: Double) -> RGB { color(lightness: lightness, a: lab.a, b: lab.b) }
    // Only L changes; a/b (hue and chroma) remain the theme's. The extended
    // endpoint lets even saturated seeds reach black/white after sRGB clipping.
    let endpoint = darkInk ? -1.0 : 2.0
    let target = min(minimum + 0.2, at(endpoint).contrast(surface))
    var failing = lab.L, passing = endpoint
    for _ in 0..<24 {
      let middle = (failing + passing) / 2
      if at(middle).contrast(surface) >= target { passing = middle }
      else { failing = middle }
    }
    return at(passing)
  }

  private static func color(lightness: Double, a: Double, b: Double) -> RGB {
    let (r, g, blue) = OKLab.toLinear(OKLab.Lab(lightness, a, b))
    func channel(_ value: Double) -> Double { min(1, max(0, OKLab.encode(value))) }
    return RGB(r: channel(r), g: channel(g), b: channel(blue))
  }
}
