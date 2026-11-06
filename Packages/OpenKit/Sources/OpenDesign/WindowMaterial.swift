import CoreGraphics
import Foundation

/// One model for the window background in every state (interaction-states §13.1).
///
/// Arc's window background is a theme tint over a backdrop:
/// `pixel = (1 − w) × tint + w × backdrop`, with `w` ≈ 0.115. The backdrop is
///
/// - near-white while the window is active (dark appearance: gray 0.91, fitted),
/// - black while it is inactive (dark appearance, fitted),
/// - the blurred page under the hover-reveal card (Gaussian σ ≈ 25 px, fitted).
///
/// Open keeps each theme's active field as the reference (it is what every theme
/// fit measured), so `tint = (active − w × activeBackdrop) / (1 − w)`. An inactive
/// window is the active field plus `w × (inactiveBackdrop − activeBackdrop)`; the
/// card is the tint at `1 − w` over the blurred page.
///
/// Evidence: capture session 2, 03 frames 0003 vs 0016 (sidebar −27.0 / −26.4 /
/// −26.3 levels, margins −26.5 / −26.1 / −25.5: backdrop ≈ 0.89 over black), and
/// 05 frames 0009 vs 0006, 0029 vs 0037 (card fit a = 0.115, σ ≈ 25 px; the card is
/// +1.3 levels over white and −25 over `#101418` against the anchored sidebar:
/// backdrop 0.93–0.96). 0.91 splits the two fits (docs/design.md §16.6).
public enum WindowMaterial {
    /// The backdrop's share of every window background pixel.
    public static let backdropWeight: Double = 0.115
    /// Gaussian σ of the page blur under the card, in points (1x pixels in the fit).
    public static let pageBlurSigma: CGFloat = 25

    /// Backdrop gray behind an active window.
    /// Dark: fitted (0.91). Light: derived (guess): with an inactive backdrop of white,
    /// the light themes' fitted inactive lightening (underlay 0.694 → 0.83 at the
    /// legacy alpha 0.64, ≈ 12.5 levels) needs an active backdrop of ≈ 0.574.
    public static func activeBackdrop(_ t: SpaceThemeStyle.Translucency) -> Double {
        switch t {
        case .dark: 0.91
        case .light: 1 - lightInactiveLift / backdropWeight
        }
    }

    /// Backdrop gray behind an inactive window. Dark: black (fitted). Light: white (guess).
    public static func inactiveBackdrop(_ t: SpaceThemeStyle.Translucency) -> Double {
        switch t {
        case .dark: 0
        case .light: 1
        }
    }

    /// Change of every background channel when the window becomes inactive.
    public static func inactiveShift(_ t: SpaceThemeStyle.Translucency) -> Double {
        backdropWeight * (inactiveBackdrop(t) - activeBackdrop(t))
    }

    /// The light themes' fitted inactive lift at the legacy alpha 0.64 (design.md §3.3).
    static let lightInactiveLift = (1 - 0.64) * (ThemeField.lightUnderlayInactive - ThemeField.lightUnderlayActive)

    /// The tint channel for an active-window channel value.
    static func tint(_ active: Double, _ t: SpaceThemeStyle.Translucency) -> Double {
        let v = (active - backdropWeight * activeBackdrop(t)) / (1 - backdropWeight)
        return active >= 0 ? max(0, v) : v
    }

    /// An active-window channel value moved to the inactive backdrop.
    static func inactive(_ active: Double, _ t: SpaceThemeStyle.Translucency) -> Double {
        let v = active + inactiveShift(t)
        return active >= 0 ? min(max(0, v), max(1, active)) : v
    }
}

extension SpaceThemeStyle {
    /// The window scheme that picks the backdrop: an imported Arc theme's own
    /// `translucencyStyle`; editor and default themes follow the window's color scheme
    /// (the macOS appearance), as their underlay wash does.
    public var backdropScheme: Translucency {
        usesLegacyIntensity ? translucency : (windowColorScheme == .dark ? .dark : .light)
    }
}
