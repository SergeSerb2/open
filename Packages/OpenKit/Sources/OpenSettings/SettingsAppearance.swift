import AppKit
import SwiftUI
import OpenDesign

struct SettingsAppearance: View {
    let root: SettingsViewModel
    @State private var iconHovered = false
    @FocusState private var iconFocused: Bool
    @Environment(\.colorScheme) private var scheme
    private var accent: Color { Color(nsColor: SettingsStyle.accessibleAccent(root.settingsAccentSource, dark: scheme == .dark)) }
    var body: some View {
        // One seam for the onboarding miniature kit, absent on this base.
        SettingsAppearancePreview().frame(height: 214)
        OpenSettingsGroup("Window") {
            OpenSettingsRow(root: root, id: "appearance/website-appearance", title: "Website appearance", changed: root.string("open.web.colorScheme") != "automatic", reset: { setWebsiteAppearance("automatic") }) {
                OpenSettingsSegments(title: "Website appearance", selection: Binding(get: { root.string("open.web.colorScheme") }, set: setWebsiteAppearance), options: [("Light", "light"), ("Dark", "dark"), ("Match System", "automatic")])
            }
            OpenSettingsRow(root: root, id: "appearance/toolbar", title: "Show the toolbar", help: "The address and page controls above each page.", changed: root.appearanceToolbar, reset: { root.appearanceToolbar = false }) {
                Toggle("Show the toolbar", isOn: Binding(get: { root.appearanceToolbar }, set: { root.appearanceToolbar = $0 })).toggleStyle(OpenSettingsSwitchStyle(accent: accent, label: "Show the toolbar"))
            }
            OpenPreferenceRow(root: root, id: "appearance/full-url", title: "Show the full URL", key: "open.advanced.showFullURLWithToolbar", help: root.appearanceToolbar ? "Show the full address in the toolbar." : "Turn on the toolbar to show the full address.", last: true).disabled(!root.appearanceToolbar)
        }
        OpenSettingsGroup("App icon") {
            HStack(spacing: 12) {
                ForEach(Array(AppIconOption.allCases.enumerated()), id: \.element) { index, option in
                    Button { root.appIcon.select(option) } label: {
                        OriginalOpenIcon(index: index).frame(width: 44, height: 44)
                            .padding(3).overlay(RoundedRectangle(cornerRadius: 13).stroke(root.appIcon.selected == option.rawValue ? accent : Color.clear, lineWidth: 2))
                    }.buttonStyle(.plain).help(option.title).accessibilityLabel(option.title)
                        .accessibilityAddTraits(root.appIcon.selected == option.rawValue ? [.isSelected] : [])
                }
                Spacer(minLength: 0)
                if root.appIcon.selected != "openDefault", iconHovered || iconFocused {
                    Button("↺ Reset") { root.appIcon.select(.openDefault) }.buttonStyle(.plain).font(.system(size: 11.5)).accessibilityLabel("Reset App icon")
                }
            }.padding(.horizontal, 14).padding(.vertical, 10)
                .overlay(alignment: .leading) { if root.appIcon.selected != "openDefault" { Circle().fill(accent).frame(width: 4, height: 4).padding(.leading, 5) } }
                .background(SettingsHoverRegion(hovered: $iconHovered).allowsHitTesting(false)).focusable(root.appIcon.selected != "openDefault").focused($iconFocused).focusEffectDisabled()
                .id("appearance/app-icon").accessibilityIdentifier("appearance/app-icon")
        }
        SettingsInlineMessage(text: root.appIcon.errorText)
    }
    private func setWebsiteAppearance(_ value: String) {
        root.set(value, for: "open.web.colorScheme"); root.actions.setWebsiteAppearance(value)
    }
}

/// G1 placeholder. Plan B supplies the production miniature through this seam.
private struct SettingsAppearancePreview: View {
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RadialGradient(colors: SettingsStyle.preview.map { Color(nsColor: $0.nsColor) }, center: .topTrailing, startRadius: 0, endRadius: 650)
            GeometryReader { geometry in
                HStack(spacing: 6) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 4) { ForEach(0..<3) { _ in Circle().fill(Color(nsColor: SettingsStyle.white.nsColor).opacity(0.35)).frame(width: 6, height: 6) } }.padding(.bottom, 4)
                        RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: SettingsStyle.white.nsColor).opacity(0.12)).frame(height: 16)
                        HStack(spacing: 4) { ForEach(0..<3) { _ in RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: SettingsStyle.white.nsColor).opacity(0.14)).frame(height: 22) } }
                        ForEach(["Design notes", "Inbox", "Release plan", "Weather"], id: \.self) { title in
                            HStack(spacing: 5) { RoundedRectangle(cornerRadius: 2).fill(Color(nsColor: SettingsStyle.white.nsColor).opacity(0.4)).frame(width: 8, height: 8); Text(title).font(.system(size: 7.5)); Spacer() }.padding(.horizontal, 5).frame(height: 15)
                                .background(title == "Design notes" ? Color(nsColor: SettingsStyle.white.nsColor).opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                        }
                        Spacer()
                    }.padding(6).frame(width: 120).foregroundStyle(Color(nsColor: SettingsStyle.white.nsColor).opacity(0.75))
                    VStack(alignment: .leading, spacing: 10) {
                        RoundedRectangle(cornerRadius: 3).fill(Color(nsColor: SettingsStyle.text.light.nsColor)).frame(width: 120, height: 10)
                        ForEach(0..<5) { index in RoundedRectangle(cornerRadius: 2).fill(Color(nsColor: SettingsStyle.secondary.light.nsColor).opacity(0.25)).frame(width: index == 4 ? 140 : 200, height: 5) }
                        Spacer()
                    }.padding(18).frame(maxWidth: .infinity).background(Color(nsColor: SettingsStyle.background.light.nsColor), in: RoundedRectangle(cornerRadius: 7))
                }.padding(6).frame(width: 420, height: 230).background(Color(nsColor: SettingsStyle.hero[1].nsColor), in: RoundedRectangle(cornerRadius: 10))
                    .shadow(color: Color(nsColor: SettingsStyle.shadow.nsColor), radius: 24, y: 16)
                    .position(x: geometry.size.width / 2, y: 141)
            }
            Text("Appearance preview").font(.system(size: 11)).foregroundStyle(Color(nsColor: SettingsStyle.white.nsColor).opacity(0.75)).padding(.leading, 12).padding(.bottom, 10)
        }.clipShape(RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).stroke(Color(nsColor: SettingsStyle.hairline.nsColor), lineWidth: 1)).accessibilityLabel("Appearance preview placeholder")
    }
}
