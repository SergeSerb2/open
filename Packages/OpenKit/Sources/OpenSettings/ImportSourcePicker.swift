import SwiftUI
import OpenImport

/// First step of Settings ▸ Import: pick the browser to move from.
/// Arc's screen: "Import from your old browser", browser tiles with logos (docs/re/browser-import.md §2).
/// GUESS — capture pending (F3 §3 item 1): tile size, order and spacing. Values use Open settings tokens.
struct ImportSourcePicker: View {
    let model: ImportWizardViewModel
    private let columns = [GridItem(.adaptive(minimum: 128, maximum: 180), spacing: 12)]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Choose the browser you are moving from. Open copies your data and never changes the other browser.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !model.sourcesLoaded {
                ProgressView().controlSize(.small)
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                    tile(id: "arc", name: "Arc", status: nil, enabled: true)
                    ForEach(model.sources) { source in
                        tile(id: source.id, name: source.name, status: model.sourceStatus(source), enabled: model.canSelect(source))
                    }
                }
                if model.sources.isEmpty {
                    Text("No other browsers were found on this Mac.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func tile(id: String, name: String, status: String?, enabled: Bool) -> some View {
        let selected = model.selectedSourceID == id
        return Button { model.selectedSourceID = id } label: {
            VStack(spacing: 8) {
                BrowserMark(id: id).frame(width: 36, height: 36)
                Text(name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(status ?? " ").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 96)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(selected ? 0.08 : 0.04)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: selected ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled || model.busy)
        .opacity(enabled ? 1 : 0.45)
        .accessibilityLabel(name)
        .accessibilityIdentifier("import-source-" + id)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Open's own simple marks for other browsers. Not their logos: shapes and colors only.
struct BrowserMark: View {
    let id: String

    var body: some View {
        switch id {
        case "chrome", "chrome-canary", "chromium":
            let colors: [Color] = id == "chromium" ? [.init(red: 0.25, green: 0.45, blue: 0.85), .init(red: 0.45, green: 0.62, blue: 0.95), .init(red: 0.33, green: 0.53, blue: 0.9)]
                : id == "chrome-canary" ? [.init(red: 0.95, green: 0.7, blue: 0.2), .init(red: 0.98, green: 0.82, blue: 0.3), .init(red: 0.9, green: 0.6, blue: 0.15)]
                : [.init(red: 0.86, green: 0.27, blue: 0.22), .init(red: 0.98, green: 0.76, blue: 0.2), .init(red: 0.2, green: 0.62, blue: 0.33)]
            ZStack {
                ForEach(0..<3) { index in
                    Circle().trim(from: CGFloat(index) / 3, to: CGFloat(index + 1) / 3)
                        .stroke(colors[index], lineWidth: 12).rotationEffect(.degrees(-30)).padding(6)
                }
                Circle().fill(.white).padding(10)
                Circle().fill(Color(red: 0.26, green: 0.52, blue: 0.96)).padding(13)
            }
        case "brave":
            ShieldShape().fill(LinearGradient(colors: [Color(red: 1, green: 0.42, blue: 0.13), Color(red: 0.95, green: 0.28, blue: 0.12)], startPoint: .top, endPoint: .bottom))
                .padding(.horizontal, 3)
        case "edge":
            ZStack {
                Circle().fill(AngularGradient(colors: [Color(red: 0.05, green: 0.45, blue: 0.8), Color(red: 0.2, green: 0.75, blue: 0.55), Color(red: 0.1, green: 0.6, blue: 0.9), Color(red: 0.05, green: 0.45, blue: 0.8)], center: .center))
                Circle().fill(Color(nsColor: .windowBackgroundColor)).frame(width: 15, height: 15).offset(x: 5, y: 3)
            }
        case "vivaldi":
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color(red: 0.94, green: 0.22, blue: 0.24))
                Path { path in
                    path.move(to: CGPoint(x: 10, y: 11)); path.addLine(to: CGPoint(x: 18, y: 26)); path.addLine(to: CGPoint(x: 26, y: 11))
                }.stroke(.white, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            }
        case "opera", "opera-gx":
            Ellipse().strokeBorder(id == "opera" ? Color(red: 0.9, green: 0.1, blue: 0.2) : Color(red: 0.98, green: 0.15, blue: 0.45), lineWidth: 7)
                .padding(.horizontal, 3)
                .background(id == "opera-gx" ? Circle().fill(Color(white: 0.12)) : nil)
        case "firefox":
            ZStack {
                Circle().fill(AngularGradient(colors: [Color(red: 1, green: 0.6, blue: 0.1), Color(red: 0.95, green: 0.25, blue: 0.3), Color(red: 0.55, green: 0.2, blue: 0.75), Color(red: 1, green: 0.6, blue: 0.1)], center: .center))
                Circle().fill(Color(red: 0.4, green: 0.2, blue: 0.7)).padding(11)
            }
        case "safari":
            ZStack {
                Circle().fill(LinearGradient(colors: [Color(red: 0.3, green: 0.75, blue: 1), Color(red: 0.1, green: 0.45, blue: 0.95)], startPoint: .top, endPoint: .bottom))
                Circle().strokeBorder(.white.opacity(0.9), lineWidth: 2).padding(3)
                NeedleShape().fill(.white).rotationEffect(.degrees(45)).padding(8)
                NeedleShape().fill(Color(red: 0.95, green: 0.25, blue: 0.25)).rotationEffect(.degrees(225)).padding(8)
            }
        default:
            // Arc: a rounded tile with a single bright arc stroke.
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(LinearGradient(colors: [Color(red: 0.98, green: 0.42, blue: 0.42), Color(red: 0.36, green: 0.36, blue: 0.95)], startPoint: .topLeading, endPoint: .bottomTrailing))
                Circle().trim(from: 0.5, to: 1).stroke(.white, style: StrokeStyle(lineWidth: 4.5, lineCap: .round)).frame(width: 20, height: 20).offset(y: 4)
            }
        }
    }
}

private struct ShieldShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.18))
        path.addQuadCurve(to: CGPoint(x: rect.midX, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY * 0.8))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.18), control: CGPoint(x: rect.minX, y: rect.maxY * 0.8))
        path.closeSubpath()
        return path
    }
}

/// Half of a compass needle: a thin diamond from the center to the top.
private struct NeedleShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX + rect.width * 0.1, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.midX - rect.width * 0.1, y: rect.midY))
        path.closeSubpath()
        return path
    }
}
