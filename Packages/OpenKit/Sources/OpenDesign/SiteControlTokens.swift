import AppKit
import QuartzCore

// Layout guesses and measured colors from site-control-boost-editor.md §§3–4.
public enum SiteControlMetrics {          // §3; all guess unless a section cites evidence
    public static let width: CGFloat = 320, maxHeight: CGFloat = 640, cornerRadius: CGFloat = 16
    public static let sidebarPanelGap: CGFloat = 13, panePanelGap: CGFloat = 11
    public static let inset: CGFloat = 14, headerHeight: CGFloat = 48, actionRowHeight: CGFloat = 44
    public static let actionButton = CGSize(width: 44, height: 36), actionGap: CGFloat = 4, actionRadius: CGFloat = 8
    public static let sectionHeaderHeight: CGFloat = 28, sectionBottomPadding: CGFloat = 10
    public static let tile = CGSize(width: 142, height: 48), tileGap: CGFloat = 8, tileRadius: CGFloat = 10, tileIcon: CGFloat = 28
    public static let boostRowHeight: CGFloat = 40   // extension item metrics belong to OpenExtensionsUI (§3.6)
    public static let footerHeight: CGFloat = 44, reloadRowHeight: CGFloat = 32
    public static let shadowOpacity: Float = 0.25, shadowRadius: CGFloat = 16, shadowOffsetY: CGFloat = 6
}
public enum BoostEditorMetrics {          // §4
    public static let width: CGFloat = 268, inset: CGFloat = 14, headerHeight: CGFloat = 52
    public static let wheelArea: CGFloat = 176, ringDiameter: CGFloat = 128, ringWidth: CGFloat = 18, padRadius: CGFloat = 46, puck: CGFloat = 24
    public static let sideButton: CGFloat = 28, sliderRow: CGFloat = 28
    public static let fontChip = CGSize(width: 56, height: 36), toolTile: CGFloat = 54, toolGap: CGFloat = 8
    public static let zapRow: CGFloat = 30, zapVisibleRows = 5
    public static let codeDefault = CGSize(width: 560, height: 640), codeMinimum = CGSize(width: 420, height: 360)
    public static let gutterWidth: CGFloat = 36, codeFontSize: CGFloat = 12, codeLineHeight: CGFloat = 16
    public static let contentInset: CGFloat = 12   // from the web panel's top-right corner
    public static let cornerRadius: CGFloat = 12, shadowPadding: CGFloat = 24
    public static let wheelY: CGFloat = 60, sideButtonsY: CGFloat = 240, bannerHeight: CGFloat = 28
    public static let fontGap: CGFloat = 6, fontStripHeight: CGFloat = 44, blockGap: CGFloat = 12
    public static let colorDuration: CFTimeInterval = 0.22
    public static let interstitialHeight: CGFloat = 326, interstitialFooter: CGFloat = 64, illustration: CGFloat = 70
}
public enum BoostEditorColors {           // BO-22 values (facts); usage per §4 (guess)
    public static let segmentBackground = DesignColor(light: .black(0.07), dark: .white(0.10))
    public static let segmentSelection = DesignColor(light: .white(1), dark: .white(0.30))
    public static let sliderTrack = DesignColor(RGBA(hex: 0x3B3746, alpha: 0.05))
    public static let sliderTint = DesignColor(RGBA(hex: 0x017AFF))
    public static let warning = DesignColor(RGBA(hex: 0xFF5A5F))
    public static let puck = DesignColor(RGBA(hex: 0xFAFBFF))
    public static let puckPad = DesignColor(light: .black(0.04), dark: .white(0.06))
    public static let label = DesignColor(light: .white(1), dark: .black(0.80))
    public static let zapPreview = DesignColor(RGBA(hex: 0xD9D9D9))
    public static let interstitialForeground = DesignColor(RGBA(hex: 0x2E2740))
    public static let interstitialFooter = DesignColor(RGBA(hex: 0xCEDBFC))
    public static let accents: [DesignColor] = [0x300EFF, 0x55B948, 0xDD0EFF, 0xFF560E, 0xFF0E82, 0x860EFF, 0xFF0E0E, 0xF1A23C]
        .enumerated().map { DesignColor(RGBA(hex: UInt32($0.element), [1, 7].contains($0.offset) ? .displayP3 : .sRGB)) }
}
extension Motion { public static let popoverOpen: CFTimeInterval = 0.18, popoverClose: CFTimeInterval = 0.12 }
extension Typography {
    public static let siteControlTitle = FontToken(14, .semibold), sectionTitle = FontToken(12, .semibold)
    public static let tileTitle = FontToken(12, .semibold), tileSubtitle = FontToken(11, .regular)
    public static let boostRowTitle = FontToken(13, .medium), editorTitle = FontToken(14, .semibold)
}

public extension SiteControlMetrics {
    static let windowMargin: CGFloat = 8, contentAnchorInset: CGFloat = 12, anchorAlignmentY: CGFloat = 24
    static let faviconFrame = CGRect(x: 14, y: 16, width: 16, height: 16)
    static let titleX: CGFloat = 36, titleBaseline: CGFloat = 29
    static let actionGlyph: CGFloat = 18, actionButtonInsetY: CGFloat = 0, disabledAlpha: CGFloat = 0.3
    static let separatorInset: CGFloat = 12
    static let footerInset: CGFloat = 10, footerButton: CGFloat = 28, footerY: CGFloat = 8
    static let securityPadding: CGFloat = 6, securityGlyph: CGFloat = 12, securityRadius: CGFloat = 6
    static let moreGlyph: CGFloat = 13, focusWidth: CGFloat = 2
    static let sectionBodyGap: CGFloat = 2, sectionChevron: CGFloat = 9
    static let tileIconInset: CGFloat = 10, tileGlyph: CGFloat = 14
    static let tileTextX: CGFloat = 46, tileTitleBaseline: CGFloat = 21, tileSubtitleBaseline: CGFloat = 36, tileTextTrailing: CGFloat = 8
    static let inUseDot: CGFloat = 6, inUseGap: CGFloat = 4
    static let boostIcon: CGFloat = 18, boostTextX: CGFloat = 42, boostTitleBaseline: CGFloat = 18, boostSubtitleBaseline: CGFloat = 32
    static let switchSize = CGSize(width: 26, height: 16), switchKnob: CGFloat = 12, switchInset: CGFloat = 2
    static let editButton: CGFloat = 24, editGap: CGFloat = 6, editGlyph: CGFloat = 13
    static let globalOffHeight: CGFloat = 28, globalOffAlpha: CGFloat = 0.5
    static let focusOutset: CGFloat = 2, closeScale: CGFloat = 0.96, openScale: CGFloat = 0.66
    static let switchDuration: CFTimeInterval = 0.12
    static let captionSize: CGFloat = 11, bodySize: CGFloat = 12, accessoryGap: CGFloat = 6
}

/// A continuous superellipse corner. Fill, inner edge and shadow share this path.
public enum SiteControlShape {
    public static func path(in rect: CGRect, radius: CGFloat) -> CGPath {
        // Own G2 corner: zero curvature at the straight joins, fitted to the
        // continuous-r16 targets (20 pt blend; 4.7 pt diagonal), all still guesses.
        let r = min(radius, rect.width/2.56, rect.height/2.56), extent = 1.28*r
        let path = CGMutablePath()
        let centers = [CGPoint(x: rect.maxX,y: rect.minY),CGPoint(x: rect.maxX,y: rect.maxY),CGPoint(x: rect.minX,y: rect.maxY),CGPoint(x: rect.minX,y: rect.minY)]
        let controls = [CGPoint(x: -extent,y: 0),CGPoint(x: -0.75*r,y: 0),CGPoint(x: -0.436*r,y: 0),CGPoint(x: 0,y: 0.436*r),CGPoint(x: 0,y: 0.75*r),CGPoint(x: 0,y: extent)]
        let coefficients: [CGFloat] = [1,5,10,10,5,1]
        for (corner,center) in centers.enumerated() {
            for step in 0...40 {
                let t = CGFloat(step)/40
                var p = CGPoint.zero
                for i in 0...5 { let w = coefficients[i]*pow(1-t,CGFloat(5-i))*pow(t,CGFloat(i)); p.x += controls[i].x*w; p.y += controls[i].y*w }
                let local = p
                let angle = CGFloat(corner) * .pi / 2
                let point = CGPoint(x: center.x+local.x*cos(angle)-local.y*sin(angle),y: center.y+local.x*sin(angle)+local.y*cos(angle))
                if corner == 0 && step == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
        }
        path.closeSubpath(); return path
    }
}
