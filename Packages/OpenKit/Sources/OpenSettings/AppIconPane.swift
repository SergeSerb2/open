import Foundation
import Observation
import SwiftUI
import AppKit
import OpenDesign

@MainActor @Observable public final class AppIconViewModel {
    unowned let root: SettingsViewModel
    public init(root: SettingsViewModel) { self.root = root }
    public var errorText = ""
    public var selected: String { root.string("open.appIcon.selectedID") }
    public func select(_ option: AppIconOption) { root.set(option.rawValue, for: "open.appIcon.selectedID"); root.actions.setApplicationIcon(id: option.rawValue) }
}
public struct AppIconPane:View {
    let model:AppIconViewModel
    public init(model:AppIconViewModel) {self.model=model}
    public var body:some View {VStack(alignment:.leading) {SettingsGroup {
        ForEach(Array(AppIconOption.allCases.enumerated()),id:\.element) {index,option in
            SettingsRow(height:80,divider:index != AppIconOption.allCases.count-1) {Button {model.select(option)} label:{HStack(spacing:0) {
                ZStack {Circle().stroke(Color.secondary,lineWidth:1).frame(width:20,height:20);if model.selected == option.rawValue {Circle().fill(Color(nsColor:SettingsTokens.link.nsColor)).frame(width:12,height:12)}}.frame(width:22).padding(.leading,6).padding(.trailing,25)
                AppIconPreview(option:option).frame(width:52,height:52).padding(.trailing,15)
                VStack(alignment:.leading,spacing:4) {Text(option.title).font(.system(size:13,weight:.semibold));if model.selected == option.rawValue {Text("CURRENT ICON").font(.system(size:10,weight:.bold)).foregroundStyle(Color(nsColor:SettingsTokens.link.nsColor))}};Spacer()
            }}.buttonStyle(.plain).accessibilityLabel(option.title).accessibilityAddTraits(model.selected == option.rawValue ? .isSelected:[]) }
        }
    };SettingsError(text:model.errorText)}}
}
/// Open's App Icon images. Each one is the system's own render of an Icon Composer document, so it has the
/// macOS squircle, rim, glass and shadow, and the transparent margin of a bundle icon (body 824 of 1024 px,
/// 100 px in). The default is the bundle icon (App/Resources/AppIcon.icon, compiled into Assets.car). Each
/// alternate is assets/app-icons/<option>.icon, rendered by tools/generate-app-icons.sh into
/// Contents/Resources/AppIcons/<option>.png. The Dock, Cmd-Tab and the Dock tile plug-in show a runtime icon as is.
@MainActor public enum AppIconArtwork {
    /// The Dock draws a runtime image about 1.5 % smaller and lower than a bundle icon, so each alternate's body is
    /// scaled 1.015 and lifted 5 px (of 1024) to match (tools/generate-app-icons.sh). The bundle icon's body is 824 px.
    public static let alternateScale: CGFloat = 1.015, alternateLift: CGFloat = 5
    /// The committed render of an alternate; nil for the bundle icon.
    public static func url(for option: AppIconOption) -> URL? {
        option == .openDefault ? nil : Bundle.main.url(forResource: option.rawValue, withExtension: "png", subdirectory: "AppIcons")
    }
    /// The six images stay cached once the picker or a selection asks for them (each alternate is 1024 px, 4 MiB decoded).
    private static var images: [AppIconOption: NSImage] = [:]
    public static func image(for option: AppIconOption) -> NSImage? {
        if let cached = images[option] { return cached }
        // The bundle icon as the system draws it now (it follows the system's icon style).
        let image = option == .openDefault ? NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
            : url(for: option).flatMap(NSImage.init(contentsOf:))
        if let image { images[option] = image }
        return image
    }
}
/// One App Icon at the given body (plate) size. The image's transparent margin and shadow extend past the frame.
struct AppIconPreview: View {
    let option: AppIconOption
    var body: some View {
        GeometryReader { g in
            let alternate = option != .openDefault
            let side = g.size.width * 1024 / (824 * (alternate ? AppIconArtwork.alternateScale : 1))
            let lift = alternate ? side * AppIconArtwork.alternateLift / 1024 : 0
            Group { if let image = AppIconArtwork.image(for: option) { Image(nsImage: image).resizable().interpolation(.high) } }
                .frame(width: side, height: side).position(x: g.size.width / 2, y: g.size.height / 2 + lift)
        }.accessibilityHidden(true)
    }
}
