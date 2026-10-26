import CoreGraphics

/// Session 1 and session 2 capture calibration. Own drawing, no Arc assets.
public enum ThemeEditorColors {
    public static let padFill = DesignColor(light: .black(0.055), dark: .white(0.04))
    public static let dot = DesignColor(light: .black(0.14), dark: .white(0.20))
    public static let knobRing = DesignColor(.white(1))
    public static let glyph = DesignColor(light: .black(0.50), dark: .white(0.50))
    // F0137 Automatic core #C6C5C5 over the selected plate: white 0.50.
    public static let glyphSelected = DesignColor(light: .black(0.50), dark: .white(0.50))
    public static let disabledGlyphAlpha: CGFloat = 0.32
    public static let selectedPlate = DesignColor(light: .black(0.10), dark: .white(0.10))
    public static let hoverPlate = DesignColor(light: .black(0.11), dark: .white(0.11))
    public static let secondaryText = DesignColor(light: .black(0.74), dark: .white(0.90))
    public static let trackFill = DesignColor(light: .black(0.085), dark: .white(0.08))
    public static let waveActive = DesignColor(light: .black(0.40), dark: .white(0.53))
    public static let waveInactive = DesignColor(light: .black(0.15), dark: .white(0.15))
    public static let thumb = DesignColor(.white(1))
    public static let dotUnlit = DesignColor(light: .black(0.15), dark: .white(0.15))
    public static let dotLit = DesignColor(light: .black(0.40), dark: .white(0.50))
    /// Neutral fallback when a preview tile cannot be made.
    public static let noisePreviewBase = RGBA(0.46, 0.46, 0.46)

}

public enum ThemeEditorMetrics {
    public static let panelSize = CGSize(width: 382, height: 534)
    public static let contentInset: CGFloat = 13
    public static let contentSize = CGSize(width: 356, height: 508)
    public static let pad = CGRect(x: 8, y: 8, width: 340, height: 340)
    public static let padRadius: CGFloat = 170
    public static let modeBar = CGRect(x: 122, y: 32, width: 112, height: 32)
    public static let remove = CGRect(x: 142, y: 300, width: 32, height: 32)
    public static let add = CGRect(x: 182, y: 300, width: 32, height: 32)
    public static let previous = CGRect(x: 9, y: 364, width: 32, height: 32)
    public static let next = CGRect(x: 315, y: 364, width: 32, height: 32)
    public static let swatches = CGRect(x: 48, y: 364, width: 260, height: 32)
    public static let intensity = CGRect(x: 18, y: 424, width: 224, height: 56)
    public static let noise = CGRect(x: 258, y: 412, width: 84, height: 80)
    /// F0137/F0138 calibrated art positions; hit frames above stay AX-sized.
    public static let intensityThumbStart: CGFloat = 7.8 // panel x = 13 + 18 + 7.8 = 38.8
    public static let intensityTravel: CGFloat = 208.4
    public static let noiseCenter = CGPoint(x: 40, y: 40) // content (298, 452)
    public static let noiseRadius: CGFloat = 32.0
    public static let noiseTickSize = CGSize(width: 8, height: 16)
}
