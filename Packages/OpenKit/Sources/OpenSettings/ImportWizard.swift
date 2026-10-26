import SwiftUI

public struct ImportWizard: View {
    let root: SettingsViewModel
    public init(root: SettingsViewModel) { self.root = root }
    public var body: some View { VStack(alignment: .leading, spacing: 24) {
        Text("Import from Arc").font(.title2)
        Text("Choose → Review → Secrets consent → Report").foregroundStyle(.secondary)
        Text("Import will be available after the Library is ready.")
        Spacer(); Button("Cancel") { root.showsImport = false }
    }.padding(24).frame(width: 592, height: 472) }
}
