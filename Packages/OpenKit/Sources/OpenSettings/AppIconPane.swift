import Foundation
import Observation
import SwiftUI
import OpenDesign

@MainActor @Observable public final class AppIconViewModel {
    unowned let root: SettingsViewModel
    public init(root: SettingsViewModel) { self.root = root }
    public var selected: String { root.string("open.appIcon.selectedID") }
    public func select(_ option: AppIconOption) { root.set(option.rawValue, for: "open.appIcon.selectedID"); root.actions.setApplicationIcon(id: option.rawValue) }
}
public struct AppIconPane: View {
    let model: AppIconViewModel
    public init(model: AppIconViewModel) { self.model = model }
    public var body: some View {
        Text("Make Open your own").font(.title2)
        LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: 20) {
            ForEach(Array(AppIconOption.allCases.enumerated()), id: \.element) { index, option in
                Button { model.select(option) } label: {
                    VStack(spacing: 10) {
                        OriginalOpenIcon(index: index).frame(width: 78, height: 78)
                        Text(option.title)
                        Text(model.selected == option.rawValue ? "Current Icon" : " ").font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity).padding(12)
                        .background(model.selected == option.rawValue ? Color(nsColor: Core.focusRing.nsColor).opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: URLFieldMetrics.cornerRadius))
                }.buttonStyle(.plain).accessibilityLabel(option.title).accessibilityAddTraits(model.selected == option.rawValue ? .isSelected : [])
            }
        }
    }
}
/// Original geometric artwork: an open doorway with a rising sun. No reference assets.
struct OriginalOpenIcon: View {
    let index: Int
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18).fill(LinearGradient(colors: [Color(nsColor: Core.brandBlue.nsColor).opacity(index == 2 ? 0.25 : 1), Color(nsColor: Core.foregroundPrimary.nsColor)], startPoint: .topLeading, endPoint: .bottomTrailing))
            if index == 4 { Circle().fill(Color(nsColor: Core.focusRing.nsColor)).offset(x: 18, y: -15) }
            RoundedRectangle(cornerRadius: 22).trim(from: 0.08, to: 0.88).stroke(.white, style: StrokeStyle(lineWidth: 6, lineCap: .round)).frame(width: 36, height: 50).rotationEffect(.degrees(Double(index) * 12))
            if index == 5 { ForEach(0..<3) { i in Rectangle().fill(.white.opacity(0.35)).frame(height: 1).offset(y: CGFloat(i) * 14 - 14) } }
        }.saturation(index == 3 ? 0 : 1)
    }
}
