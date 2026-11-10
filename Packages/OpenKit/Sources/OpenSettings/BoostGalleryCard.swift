import SwiftUI
import OpenDesign

/// A layout over the Library's snapshots and actions, with no page loading.
struct BoostGalleryCard: View {
    let item: BoostItemSnapshot
    @Binding var enabled: Bool
    let edit: () -> Void
    let delete: () -> Void

    private var title: String { item.name.isEmpty ? item.domain : item.name }
    var body: some View {
        VStack(alignment: .leading, spacing: SettingsTokens.groupGap) {
            HStack {
                Image(systemName: BoostGlyph.fill)
                    .foregroundStyle(Color(nsColor: Core.brandBlue.nsColor))
                    .frame(width: 20, height: 20)
                    .accessibilityHidden(true)
                Spacer()
                Toggle("Enable \(title)", isOn: $enabled)
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .accessibilityIdentifier("boosts.\(item.id).enabled")
            }
            Text(title).font(Font(SettingsTokens.title.font)).lineLimit(1).help(title)
            Text("Made for \(item.domain)\(item.pathPrefix ?? "")")
                .font(Font(SettingsTokens.section.font))
                .foregroundStyle(Color(nsColor: SettingsTokens.secondary.nsColor))
                .lineLimit(1).help(item.domain + (item.pathPrefix ?? ""))
            HStack {
                Button("Edit…", action: edit).accessibilityIdentifier("boosts.\(item.id).edit")
                Spacer(minLength: 0)
                Button("Delete…", role: .destructive, action: delete).accessibilityIdentifier("boosts.\(item.id).delete")
            }.buttonStyle(SettingsButtonStyle())
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: SettingsTokens.fill.nsColor), in: RoundedRectangle(cornerRadius: SettingsTokens.radius))
        .overlay(RoundedRectangle(cornerRadius: SettingsTokens.radius).stroke(Color(nsColor: SettingsTokens.border.nsColor), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("boosts.\(item.id).card")
    }
}
