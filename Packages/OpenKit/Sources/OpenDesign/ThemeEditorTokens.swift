import CoreGraphics

/// Dark tokens measured in F0137. Light tokens are the plan's v1 guesses.
public enum ThemeEditorColors {
    public static let padFill = DesignColor(light: .black(0.03), dark: .white(0.04))
    public static let dot = DesignColor(light: .black(0.14), dark: .white(0.20))
    public static let knobRing = DesignColor(.white(1))
    public static let glyph = DesignColor(light: .black(0.45), dark: .white(0.50))
    // F0137 Automatic core #C6C5C5 over the selected plate: white 0.50.
    public static let glyphSelected = DesignColor(light: .black(0.85), dark: .white(0.50))
    // F0137 Add core #C1C1C4; the fixed offscreen material needs this slight cool tint.
    public static let addGlyph = DesignColor(light: .black(0.45), dark: RGBA(0.98, 0.98, 1, 0.54))
    public static let selectedPlate = DesignColor(light: .black(0.07), dark: .white(0.10))
    public static let hoverPlate = DesignColor(light: .black(0.04), dark: .white(0.06))
    public static let secondaryText = glyph
    public static let trackFill = DesignColor(light: .black(0.06), dark: .white(0.08))
    public static let waveActive = DesignColor(light: .black(0.45), dark: .white(0.53))
    public static let waveInactive = DesignColor(light: .black(0.12), dark: .white(0.15))
    public static let thumb = DesignColor(.white(1))
    public static let dotUnlit = DesignColor(light: .black(0.12), dark: .white(0.15))
    public static let dotLit = DesignColor(light: .black(0.45), dark: .white(0.50))
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
}
