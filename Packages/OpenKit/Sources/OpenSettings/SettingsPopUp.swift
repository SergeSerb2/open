import AppKit
import SwiftUI
import OpenDesign

/// A regular native pop-up with a stable 24 pt control height and the standard arrows.
/// A fixed width must size the control itself, rather than only the SwiftUI wrapper.
enum SettingsPopUpEntry<Value: Hashable> {
    case option(String, Value, symbol: String? = nil)
    case imageOption(String,Value,NSImage)
    case separator
    var value:Value? {switch self {case .option(_,let value,_),.imageOption(_,let value,_):.some(value);case .separator:nil}}
}
struct SettingsPopUp<Value: Hashable>: NSViewRepresentable {
    let title: String
    @Binding var selection: Value
    let width: CGFloat
    let entries: [SettingsPopUpEntry<Value>]
    @Environment(\.isEnabled) private var enabled
    init(_ title: String, selection: Binding<Value>, width: CGFloat, entries: [SettingsPopUpEntry<Value>]) {
        self.title=title; _selection=selection; self.width=width; self.entries=entries
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSPopUpButton {
        let control=NSPopUpButton(frame:.init(x:0,y:0,width:width,height:24),pullsDown:false)
        control.controlSize = .regular; control.font=SettingsTokens.label.font
        control.target=context.coordinator; control.action=#selector(Coordinator.select(_:))
        control.setAccessibilityLabel(title)
        control.setContentHuggingPriority(.defaultLow,for:.horizontal)
        control.setContentCompressionResistancePriority(.required,for:.vertical)
        return control
    }
    func updateNSView(_ control:NSPopUpButton,context:Context) {
        context.coordinator.parent=self
        control.removeAllItems(); control.autoenablesItems=false
        var selected=0
        for (index,entry) in entries.enumerated() {
            switch entry {
            case .separator: control.menu?.addItem(.separator())
            case .option(let title,let value,let symbol):
                let item=NSMenuItem(title:title,action:nil,keyEquivalent:"")
                if let symbol {item.image=NSImage(systemSymbolName:symbol,accessibilityDescription:nil)}
                control.menu?.addItem(item)
                if value == selection {selected=index}
            case .imageOption(let title,let value,let image):
                let item=NSMenuItem(title:title,action:nil,keyEquivalent:"")
                let icon=image.copy() as? NSImage;icon?.size = .init(width:16,height:16);item.image=icon;control.menu?.addItem(item)
                if value == selection {selected=index}
            }
        }
        control.selectItem(at:selected);control.isEnabled=enabled
    }
    func sizeThatFits(_ proposal:ProposedViewSize,nsView:NSPopUpButton,context:Context)->CGSize? {.init(width:width,height:24)}
    @MainActor final class Coordinator:NSObject {
        var parent:SettingsPopUp
        init(_ parent:SettingsPopUp){self.parent=parent}
        @objc func select(_ sender:NSPopUpButton) {
            guard parent.entries.indices.contains(sender.indexOfSelectedItem),let value=parent.entries[sender.indexOfSelectedItem].value else {return}
            parent.selection=value
            // A cancelled Other… picker may leave the model value unchanged.
            if let index=parent.entries.firstIndex(where:{$0.value.map{$0 == parent.selection} ?? false}) {sender.selectItem(at:index)}
        }
    }
}
