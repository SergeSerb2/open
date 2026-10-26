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
public struct AppIconPane:View {
    let model:AppIconViewModel
    public init(model:AppIconViewModel) {self.model=model}
    public var body:some View {SettingsGroup {
        ForEach(Array(AppIconOption.allCases.enumerated()),id:\.element) {index,option in
            SettingsRow(height:80,divider:index != AppIconOption.allCases.count-1) {Button {model.select(option)} label:{HStack(spacing:0) {
                ZStack {Circle().stroke(Color.secondary,lineWidth:1).frame(width:20,height:20);if model.selected == option.rawValue {Circle().fill(Color(nsColor:SettingsTokens.link.nsColor)).frame(width:12,height:12)}}.frame(width:22).padding(.leading,6).padding(.trailing,25)
                OriginalOpenIcon(index:index).frame(width:52,height:52).padding(.trailing,15)
                VStack(alignment:.leading,spacing:4) {Text(option.title).font(.system(size:13,weight:.semibold));if model.selected == option.rawValue {Text("CURRENT ICON").font(.system(size:10,weight:.bold)).foregroundStyle(Color(nsColor:SettingsTokens.link.nsColor))}};Spacer()
            }}.buttonStyle(.plain).accessibilityLabel(option.title).accessibilityAddTraits(model.selected == option.rawValue ? .isSelected:[]) }
        }
    }}
}
/// Original doorway and sun artwork, drawn in normalized coordinates. No reference art.
struct OriginalOpenIcon:View {
    let index:Int
    private var colors:[Color] {switch index {
    case 1:[Color(red:0.02,green:0.03,blue:0.10),Color(red:0.07,green:0.10,blue:0.19)]
    case 2:[.white,Color(white:0.94)]
    case 3:[Color(white:0.42),Color(white:0.24)]
    case 4:[.pink,.orange,.yellow,.green,.blue,.purple]
    case 5:[Color(red:1,green:0.98,blue:0.88),Color(red:0.96,green:0.94,blue:0.81)]
    default:[Color(red:0.12,green:0.4,blue:0.95),Color(red:0.08,green:0.18,blue:0.6)]
    }}
    var body:some View {GeometryReader {g in ZStack {
        RoundedRectangle(cornerRadius:11).fill(LinearGradient(colors:colors,startPoint:.topLeading,endPoint:.bottomTrailing))
        if index == 5 {ForEach(0..<5) {line in Path {p in p.move(to:.init(x:0,y:CGFloat(line)*9+8));p.addLine(to:.init(x:52,y:CGFloat(line)*9+8))}.stroke(.blue.opacity(0.25),lineWidth:0.6)};Rectangle().fill(.red.opacity(0.4)).frame(width:1).offset(x:-17)}
        RoundedRectangle(cornerRadius:12).trim(from:0.08,to:0.88).stroke(index == 2 || index == 5 ? Color.blue:Color.white,style:StrokeStyle(lineWidth:4,lineCap:.round)).frame(width:25,height:34)
        Circle().fill(index == 1 ? Color.yellow:Color.orange).frame(width:8,height:8).offset(x:6,y:-7)
    }.frame(width:52,height:52).clipShape(RoundedRectangle(cornerRadius:11)).overlay(RoundedRectangle(cornerRadius:11).stroke(.black.opacity(0.12))).scaleEffect(g.size.width/52,anchor:.topLeading)}}
}
