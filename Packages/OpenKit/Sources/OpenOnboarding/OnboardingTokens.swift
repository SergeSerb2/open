import AppKit
import OpenDesign

public enum OnboardingTokens {
    public static let windowSize = NSSize(width: 1280, height: 800)
    public static let buttonSize = NSSize(width: 160, height: 52)
    public static let line = "A browser that's yours, and only yours."

    /// Lead's B-design-mockup.html; artwork uses encoded sRGB, as CSS does.
    public enum Room {
        public static let far = IntroColors.color(0x070818)
        public static let wall = IntroColors.color(0x12133A)
        public static let lit = IntroColors.color(0x23246B)
        public static let welcomeFar = IntroColors.color(0x0A0B1E)
        public static let welcomeWall = IntroColors.color(0x14153D)
        public static let floor = IntroColors.color(0x040510)
        public static let spaceRGBA = RGBA(hex: 0x5B5BD6)
        public static let space = spaceRGBA.nsColor
        public static let demoSpaces: [RGBA] = [spaceRGBA,RGBA(hex: 0x754770),RGBA(hex: 0x39836E),RGBA(hex: 0xB37040)]
        public static let commandBackdrop = RGBA(0.1, 0.1, 0.14)
        public static let wordmarkBottom = IntroColors.color(0xFFE9CF)
        public static let sunTop = IntroColors.color(0xFFF1D6)
        public static let sunMiddle = IntroColors.color(0xFFC56E)
        public static let sunBottom = IntroColors.color(0xFF8F3A)
        public static let bloom = IntroColors.color(0xFFAA5A)
        public static let spill = IntroColors.color(0xFFBE6E)
        public static let ink = IntroColors.color(0x1A1B4B)
        public static let pageInk = IntroColors.color(0x16171D)
        public static let pageSecondary = IntroColors.color(0x6B6F7B)
        public static let page = IntroColors.color(0xFFFFFF)
        public static let pageLine = IntroColors.color(0xE9E9EE)
        public static let imageMiddle = IntroColors.color(0xFF9F6B)
        public static let imageEnd = IntroColors.color(0xC86BD6)
        public static let white = NSColor.white
        public static let shadow = NSColor.black
        public static let horizon: CGFloat = 0.62
        public static let grainOpacity: Float = 0.11
        public static let miniatureRadius: CGFloat = 14
        public static let miniatureSize = CGSize(width: 675, height: 725)
        public static let miniatureScale: CGFloat = 0.8
    }
}

public enum IntroColors {
    public static func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
                green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: alpha)
    }
    public static let room = color(0x070818)
    public static let blue = color(0x5B5BD6)
}
