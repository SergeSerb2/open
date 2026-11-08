import AppKit

public enum OnboardingTokens {
    public static let windowSize = NSSize(width: 1280, height: 800)
    public static let buttonSize = NSSize(width: 200, height: 44)
    public static let line = "A browser that's yours, and only yours."
}

public enum IntroColors {
    public static func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(displayP3Red: CGFloat((hex >> 16) & 255) / 255,
                green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: alpha)
    }
    public static let room = color(0x0B1A5C)
    public static let blue = color(0x1A3FD0)
}
