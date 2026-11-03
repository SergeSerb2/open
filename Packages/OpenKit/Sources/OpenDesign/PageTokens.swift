import CoreGraphics
import Foundation

/// Toasts over the web panel (page-platform plan §4.1.2). Evidence: `docs/re/page-platform.md`
/// PG-1 (F0142 zoom toast, F0155 copy toast) and PG-14 (capture session 2). Values marked
/// "guess" stay in this one place so a capture fixes them in one edit.
public enum ToastMetrics {
    /// Text-only toast: 60 × 42 ("110%", PG-1.2).
    public static let height: CGFloat = 42
    /// Toast with a button: 192 × 46 ("Copied Current URL" + Share, PG-1.2; S2 20/0048 also 46).
    public static let heightWithAccessory: CGFloat = 46
    /// Title plus subtitle (14 pt + 12 pt). guess.
    public static let heightTwoLine: CGFloat = 60
    /// Body top edge 8 pt below the panel top, right edge 10 pt left of the panel's (PG-1.1).
    public static let topInset: CGFloat = 8
    public static let trailingInset: CGFloat = 10
    /// Continuous corner, 10–11 pt (PG-1.4).
    public static let cornerRadius: CGFloat = 11
    /// Text starts 12 pt in (PG-1.3); text-only trailing padding symmetric (guess).
    public static let leadingPadding: CGFloat = 12
    public static let trailingPadding: CGFloat = 12
    /// Text to button 8, button to the trailing edge 10, button 10 below the top (PG-1.3).
    public static let labelToAccessory: CGFloat = 8
    public static let accessoryTrailing: CGFloat = 10
    public static let accessoryTop: CGFloat = 10
    /// Share button 32 × 27 (PG-1.3); radius guess.
    public static let accessorySize = CGSize(width: 32, height: 27)
    public static let accessoryRadius: CGFloat = 6
    /// Button fill over the toast fill: white 0.22 derived (PG-1.3); pressed guess.
    public static let accessoryFillAlpha: Double = 0.22
    public static let accessoryPressedAlpha: Double = 0.32
    /// Button symbol point size. guess.
    public static let accessorySymbolSize: CGFloat = 13
    /// Optional leading SF Symbol: 14 pt at x 12, then 6 pt to the title. guess.
    public static let symbolSize: CGFloat = 14
    public static let symbolToTitle: CGFloat = 6
    /// Gap between title and subtitle lines. guess.
    public static let lineGap: CGFloat = 2
    /// Width limits; the title truncates in the middle past `maxWidth` (min PG-1.2, max guess).
    public static let minWidth: CGFloat = 60
    public static let maxWidth: CGFloat = 380
    /// Toast views that may exist at once (PG-1.8: four windows at one frame on A0487).
    public static let maxVisible = 4
    /// Plain toasts 3.0 s (PG-1.7: `FUN_1018e22f8` holds 3.0; zoom toast gone after ≈ 3 s).
    public static let lifetime: TimeInterval = 3.0
    /// Toasts with a button: 5.0 s. PG-14 (V 69.99–75.11 s) measured the copy toast with Share
    /// staying ≈ 4.95 s before it shrinks; the plan's 6.0 was a guess (≥ 5 s) before that capture.
    public static let accessoryLifetime: TimeInterval = 5.0
    /// The pointer leaving a toast restarts its timer with this much left (Open choice).
    public static let hoverResumeLifetime: TimeInterval = 1.5
    /// Shadow and 1 px inner rim, fitted on the hint toast (sidebar-completion §3.12; PG-1.5
    /// shows the same darker edge rows).
    public static let shadowOpacity: Float = 0.10
    public static let shadowRadius: CGFloat = 8
    public static let shadowOffsetY: CGFloat = 2
    public static let rimAlpha: Double = 0.20
    /// Keycap plates before the title: the hint's measured plate (27 tall, radius 6, ink + 18).
    public static let keycapHeight: CGFloat = 27
    public static let keycapRadius: CGFloat = 6
    public static let keycapInkPadding: CGFloat = 18
    public static let keycapAlpha: Double = 0.10
    public static let keycapGap: CGFloat = 4
    public static let keycapToTitle: CGFloat = 6

    /// The toast height for its content.
    public static func height(hasSubtitle: Bool, hasButton: Bool) -> CGFloat {
        hasSubtitle ? heightTwoLine : (hasButton ? heightWithAccessory : height)
    }
    /// Frame of a toast of `size` in a flipped panel of `bounds` (PG-1.1).
    public static func frame(size: CGSize, in bounds: CGRect) -> CGRect {
        CGRect(x: bounds.maxX - trailingInset - size.width, y: bounds.minY + topInset, width: size.width, height: size.height)
    }
}

/// Toast fill and text: one rule for `ToastView` and the first-hide hint (`HintToastView`),
/// page-platform §4.1.2 and sidebar-completion §3.12.
extension SpaceThemeStyle {
    /// Default theme, dark: vertical gradient `#442B68` → `#332350` (hint, A0440, measured).
    public static let defaultDarkToastFill = (top: RGBA(hex: 0x442B68), bottom: RGBA(hex: 0x332350))
    /// Default theme, macOS Light: lavender `#D0C6F0` → `#C2B4E9` with dark text (S2 20/0048, sRGB
    /// after the display profile; rows 19–21 and 62 of column 1540 inside the copy toast).
    public static let defaultLightToastFill = (top: RGBA(hex: 0xD0C6F0), bottom: RGBA(hex: 0xC2B4E9))
    /// Dark text ink core on S2 20/0048 (`#0D0D10`).
    public static let defaultLightToastText = RGBA(hex: 0x0D0D10)
    /// Themed Spaces (guess): the tooltip fill lightened (top) and darkened (bottom) by this much
    /// OKLab L. PG-1.5's olive Space measures bottom ≈ 0.77 × top, the same ratio as the hint's pair.
    public static let themedToastLightness: Double = 0.06

    /// True for the default theme in macOS Light: the only light toast Arc showed (S2 20/0048).
    public var usesLightToast: Bool { lightPalette == nil && windowColorScheme == .light }

    public var toastFillTop: RGBA { toastFill.top }
    public var toastFillBottom: RGBA { toastFill.bottom }
    /// Gradient stops (top, bottom).
    public var toastFill: (top: RGBA, bottom: RGBA) {
        guard lightPalette != nil else { return usesLightToast ? Self.defaultLightToastFill : Self.defaultDarkToastFill }
        let base = tooltipFill
        func shifted(_ dL: Double) -> RGBA {
            var lab = OKLab.fromSRGB(base.red, base.green, base.blue)
            lab.L = min(1, max(0, lab.L + dL))
            let (r, g, b) = OKLab.toLinear(lab)
            return RGBA(min(1, max(0, OKLab.encode(r))), min(1, max(0, OKLab.encode(g))), min(1, max(0, OKLab.encode(b))))
        }
        return (shifted(Self.themedToastLightness), shifted(-Self.themedToastLightness))
    }
    /// Title text. White, opaque: the hint fit (A0440 ink core `#F1F0F3`, ΔE00 0.05 with 1.0;
    /// 0.95 gave 2.03). Dark in the default theme under macOS Light.
    public var toastText: RGBA { usesLightToast ? Self.defaultLightToastText : RGBA.white(1) }
    /// Subtitle text: the title color at 0.80. guess.
    public var toastSubtitleText: RGBA { toastText.withAlpha(0.80) }
    /// Button and keycap plates: the text color over the fill (white 0.22 / 0.10 on dark fills).
    public var toastAccessoryFill: RGBA { toastText.withAlpha(ToastMetrics.accessoryFillAlpha) }
    public var toastAccessoryPressedFill: RGBA { toastText.withAlpha(ToastMetrics.accessoryPressedAlpha) }
    public var toastKeycapFill: RGBA { toastText.withAlpha(ToastMetrics.keycapAlpha) }
}
