import AppKit

/// Extensions plan §3. Values marked guess await the plan's S-2…S-7 captures.
public enum ExtensionsMetrics {
    public static let iconArea = CGSize(width: 28, height: 28)
    public static let actionIconSize: CGFloat = 16
    public static let pitch: CGFloat = 28
    public static let urlFieldHostMinimum: CGFloat = 44 // guess, S-2
    public static let paneSlot = CGSize(width: 28, height: 28)
    public static let paneHostCap: CGFloat = 160 // guess, S-10
    public static let dragThreshold: CGFloat = 3
    public static let popupCornerRadius: CGFloat = 10 // guess, S-3
    public static let popupGap: CGFloat = 6 // guess, S-3
    public static let popupScreenMargin: CGFloat = 8
    public static let popupMinimum = CGSize(width: 25, height: 25)
    public static let popupMaximum = CGSize(width: 800, height: 600)
    public static let itemRowHeight: CGFloat = 32 // guesses, S-5
    public static let itemPinButton: CGFloat = 24
    public static let itemTile: CGFloat = 44
    public static let gridColumns = 5
    public static let gridGap: CGFloat = 4
    public static let promptWidth: CGFloat = 420 // guesses, S-4
    public static let promptPadding: CGFloat = 24
    public static let promptCornerRadius: CGFloat = 12
    public static let promptIcon: CGFloat = 48
    public static let promptBodyMaxHeight: CGFloat = 240
    public static let promptButtonHeight: CGFloat = 28
    public static func littleOpenButton(width: CGFloat) -> CGRect {
        CGRect(x: width - 132, y: 6, width: 30, height: 28)
    }
    public static func littleOpenURLWidth(width: CGFloat, hasExtensions: Bool) -> CGFloat {
        max(0, width - (hasExtensions ? 234 : 202))
    }
}
public enum ExtensionsRole {
    public static let popupStroke = SidebarColors.tabListOverlapBorder
}
