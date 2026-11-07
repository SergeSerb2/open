import AppKit
import OpenDesign
import OpenModel

/// guess S10-I1. Both native headers use the existing Set Profile menu.
@MainActor
final class ProfileIndicatorButton: PlateButton {
    private let profileGlyph = ProfileIndicatorGlyph()
    init(context: SidebarContext, space: Space) {
        super.init(glyph:nil)
        self.context=context; showsHoverPlate=false
        profileGlyph.context=context; profileGlyph.space=space
        profileGlyph.alphaValue=ProfileIndicatorMetrics.opacity
        addSubview(profileGlyph)
        accessibleTitle = { [unowned context, space] in "Profile: \(context.model.profile(id:space.profileID)?.name ?? "Profile")" }
        tooltip = { [unowned context, space] in Tooltip(title:"Profile: \(context.model.profile(id:space.profileID)?.name ?? "Profile")",style:context.style(for:space)) }
        setAccessibilityIdentifier("space-profile-indicator")
    }
    @available(*, unavailable) required init?(coder:NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        let size=ProfileIndicatorMetrics.glyphSize
        profileGlyph.frame=CGRect(x:(bounds.width-size)/2,y:(bounds.height-size)/2,width:size,height:size)
        toolTip=tracked({ accessibleTitle?() }) { [weak self] in self?.needsLayout=true }
    }
}

@MainActor
private final class ProfileIndicatorGlyph:NSView {
    weak var context:SidebarContext?
    weak var space:Space?
    override var isFlipped:Bool { true }
    override func hitTest(_ point:NSPoint)->NSView? { nil }
    override func draw(_ dirtyRect:NSRect) {
        guard let context, let space else { return }
        let icon=tracked({
            _ = context.appearance(for:space)
            return context.model.profile(id:space.profileID)?.icon
        }) { [weak self] in self?.needsDisplay=true }
        if case .emoji(let emoji)?=icon { EmojiRenderer.draw(emoji,fontSize:ProfileIndicatorMetrics.glyphSize,in:bounds);return }
        let name:String
        switch icon {
        case .symbol(let symbol):name=symbol
        case .named(let named):name=NamedSpaceIcons.symbolName(for:named)
        default:name="person.crop.circle"
        }
        guard let image=NSImage(systemSymbolName:name,accessibilityDescription:nil) else { return }
        let ratio=min(bounds.width/image.size.width,bounds.height/image.size.height)
        let size=CGSize(width:image.size.width*ratio,height:image.size.height*ratio)
        image.drawTinted(in:CGRect(x:(bounds.width-size.width)/2,y:(bounds.height-size.height)/2,width:size.width,height:size.height),color:SidebarRole.spaceTitle.resolved(context.appearance(for:space)).nsColor)
    }
}
