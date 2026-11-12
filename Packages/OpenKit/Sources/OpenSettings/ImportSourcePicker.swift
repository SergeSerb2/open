import SwiftUI
import AppKit
import OpenImport

/// First step of the import sheet: pick the browser to move from.
/// Capture session 5 (C-measurements-s5.md, `u1/01-import/i1-source-picker`): two columns. Left: app icon 62 pt,
/// "Import from your old browser", body 250 pt wide. Right: one pill per detected browser, 175 × 48, with an empty
/// radio circle, the upper-case name, and the browser icon on a tinted right segment. Browsers that are not
/// installed are absent. Next stays disabled until a pill is selected.
struct ImportSourcePicker: View {
    let model: ImportWizardViewModel

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 62, height: 62)
                    .padding(.bottom, 4)
                Text("Import from your old browser").font(.system(size: 17, weight: .semibold))
                Text("Import everything you need from your old browser to hit the ground running with Open.")
                    .font(.system(size: 14)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 250, alignment: .leading)
            Spacer(minLength: 0)
            ScrollView {
                VStack(spacing: 12) {
                    if !model.sourcesLoaded {
                        ProgressView().controlSize(.small)
                    } else if model.visibleSources.isEmpty {
                        Text("No other browsers were found on this Mac.").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(model.visibleSources) { source in
                        pill(source)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .frame(width: 258, height: 264)
            .padding(.top, 60)
        }
    }

    private func pill(_ source: BrowserSource) -> some View {
        let selected = model.selectedSourceID == source.id
        let enabled = model.canSelect(source)
        return Button { model.selectedSourceID = source.id } label: {
            HStack(spacing: 0) {
                ZStack {
                    Circle().strokeBorder(Color.primary.opacity(selected ? 0 : 0.45), lineWidth: 1).frame(width: 18, height: 18)
                    if selected { Circle().fill(Color.accentColor).frame(width: 18, height: 18); Circle().fill(.white).frame(width: 7, height: 7) }
                }
                .padding(.leading, 16)
                VStack(spacing: 1) {
                    Text(source.name.uppercased()).font(.system(size: 13, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                    if let status = model.sourceStatus(source) { Text(status).font(.system(size: 10)).foregroundStyle(.secondary) }
                }
                .frame(maxWidth: .infinity)
                ZStack {
                    // Capture s5: a tinted right segment (Safari's is #CDDDF4). One neutral accent tint for every browser.
                    Color.accentColor.opacity(0.15)
                    BrowserIcon(appURL: model.appURLs[source.id]).frame(width: 28, height: 28)
                }
                .frame(width: 48)
            }
            .frame(width: 175, height: 48)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: selected ? 2 : 1))
            .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled || model.busy)
        .opacity(enabled ? 1 : 0.45)
        .accessibilityLabel(source.name)
        .accessibilityIdentifier("import-source-" + source.id)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The browser's own installed app icon, read at run time from its bundle (nothing is stored in the repo).
/// Without an installed app: a neutral globe in a rounded tile (lead ruling 01:55).
struct BrowserIcon: View {
    let appURL: URL?

    var body: some View {
        if let appURL {
            Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path)).resizable().interpolation(.high)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.08))
                Image(systemName: "globe").font(.system(size: 15, weight: .medium)).foregroundStyle(.secondary)
            }
        }
    }
}
