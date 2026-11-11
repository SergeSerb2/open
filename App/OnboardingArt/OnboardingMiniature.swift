import AppKit
import QuartzCore
import OpenModel
import OpenDesign
import OpenSidebar
import OpenOnboarding
import OpenCommandBar
import OpenSuggest
import OpenFeatures

/// A real sidebar and command bar, in a disposable model. No store, engine,
/// web-content host, fetcher or user window belongs to this miniature.
@MainActor
final class OnboardingMiniature: NSView {
    // Short holds keep the whole Welcome pass at 19 seconds. Travel durations
    // and easing retain the original 8.5-second demonstrations' motion.
    static let demoDurations: [Double] = [4.2, 4.0, 6.8, 4.0]
    override var isFlipped: Bool { true }
    let model: BrowserModel
    let space: Space
    let profile: Profile
    let context: SidebarContext
    let sidebar: SidebarView
    private let stage = MiniatureStage()
    private let viewport = MiniatureViewport()
    private let theme = ThemeBackgroundView()
    private let page = MiniaturePage()
    private var secondPage: MiniaturePage?
    private var splitDivider: SplitDividerView?
    private var lifted: NSView?
    private var movingTab: Tab?
    private var alternateSpace: Space?
    private var importedSignature = ""
    var demoKind = 0
    private let rim = CAGradientLayer()
    private let rimEdge = CAShapeLayer()
    private let contact = CALayer()
    private var lights: [NSButton] = []
    private var iconImages: [ItemID: NSImage] = [:]
    private var favoriteTabs: [String: Tab] = [:]
    private var command: CommandBarController?
    private var demoTab: Tab?
    private var demoTasks: [Task<Void, Never>] = []
    private(set) var demoRunning = false
    var perspective = false { didSet { needsLayout = true } }
    var reduceMotion = false
    private var appliedTheme: SpaceTheme?
    private var appliedDark: Bool?
    private var preferenceSuite: String
    private let preferences: UserDefaults
    private var designSize = CGSize(width: 675,height: 765)
    private var isDemo = false
    var renderedScale: CGFloat { bounds.width/designSize.width }
    var animationCount: Int { (demoRunning ? 1 : 0) + Self.animationKeys(stage.layer) }
    var pendingDisplayUpdates: Int { theme.hasPendingDisplayUpdate ? 1 : 0 }

    init() {
        profile = Profile(name: "Preview")
        space = Space(title: "Your Space", icon: .symbol("circle.lefthalf.filled"), profileID: profile.id)
        space.pinned = [.tab(Tab(url: URL(string: "open://welcome")!,title: "Welcome to Open",pinnedURL: URL(string: "open://welcome")!))]
        space.today = ["Morning reading","Trip to Lisbon"].enumerated().map {
            .tab(Tab(url: URL(string: "https://open.example/page/\($0.offset)")!,title: $0.element))
        }
        let window = BrowserWindowState(focusedSpaceID: space.id,sidebarWidth: 235,frameWidth: 675,frameHeight: 725)
        model = BrowserModel(profiles: [profile],spaces: [space],windows: [window])
        preferenceSuite = "open.art.\(UUID().uuidString)"
        preferences = UserDefaults(suiteName: preferenceSuite)!
        preferences.set(false,forKey: "open.general.previewsEnabled")
        context = SidebarContext(model: model,windowID: window.id,previewPreferences: preferences)
        context.isWindowActive = true
        context.animatesChanges = false; context.favoriteIconFraction = 0.66
        if let tab = space.pinned.first?.id { model.selectNode(windowID: window.id,spaceID: space.id,nodeID: tab) }
        sidebar = SidebarView(context: context)
        super.init(frame: .zero); wantsLayer = true
        context.faviconProvider = { [weak self] tab in self?.iconImages[tab.id] }
        layer?.addSublayer(contact)
        contact.shadowColor = OnboardingTokens.Room.shadow.cgColor; contact.shadowOpacity = 0.45
        contact.shadowRadius = 28; contact.shadowOffset = CGSize(width: 0,height: 18)
        addSubview(viewport); viewport.addSubview(stage); stage.addSubview(theme); stage.addSubview(sidebar); stage.addSubview(page)
        theme.updatesFieldsSynchronously = true
        theme.material = .window; sidebar.themeBackground = theme
        for type in [NSWindow.ButtonType.closeButton,.miniaturizeButton,.zoomButton] {
            if let button = NSWindow.standardWindowButton(type,for: [.titled,.closable,.miniaturizable]) {
                button.isEnabled = true; button.setAccessibilityElement(false)
                stage.addSubview(button); lights.append(button)
            }
        }
        rim.colors = [OnboardingTokens.Room.bloom.withAlphaComponent(0).cgColor,OnboardingTokens.Room.sunMiddle.withAlphaComponent(0.20).cgColor]
        rim.locations = [0.55,1]; rim.startPoint = CGPoint(x: 0,y: 0.5); rim.endPoint = CGPoint(x: 1,y: 0.3)
        rim.cornerRadius = OnboardingTokens.Room.miniatureRadius; stage.layer?.addSublayer(rim)
        rimEdge.fillColor = nil; rimEdge.strokeColor = OnboardingTokens.Room.sunMiddle.withAlphaComponent(0.5).cgColor
        stage.layer?.addSublayer(rimEdge)
        layer?.shadowColor = OnboardingTokens.Room.shadow.cgColor; layer?.shadowOpacity = 0.5
        layer?.shadowRadius = 40; layer?.shadowOffset = CGSize(width: 0,height: 40)
        stage.layer?.borderWidth = 1; stage.layer?.borderColor = OnboardingTokens.Room.white.withAlphaComponent(0.16).cgColor
        setAccessibilityElement(true); setAccessibilityRole(.image)
        setAccessibilityLabel("Open window preview"); setAccessibilityChildren([])
        apply(theme: nil,dark: false)
    }
    required init?(coder: NSCoder) { nil }
    isolated deinit { demoTasks.forEach { $0.cancel() }; preferences.removePersistentDomain(forName: preferenceSuite) }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout(); CATransaction.begin(); CATransaction.setDisableActions(true)
        // A card is a wide native window: keep enough logical height for a
        // complete Today row above the real bottom bar at the shared inset.
        if isDemo, bounds.width > 0 { designSize = CGSize(width: 900,height: max(300,bounds.height*900/bounds.width)) }
        viewport.frame = bounds; viewport.bounds = CGRect(origin: .zero,size: designSize)
        stage.layer?.transform = CATransform3DIdentity
        stage.frame = CGRect(origin: .zero,size: designSize); stage.bounds = CGRect(origin: .zero,size: designSize)
        theme.frame = stage.bounds
        sidebar.frame = CGRect(x: 0,y: 0,width: 235,height: designSize.height)
        let content = CGRect(x: 242,y: 9,width: designSize.width-251,height: designSize.height-18)
        page.frame = content
        if let secondPage, let splitDivider {
            let half = (content.width-8)/2
            page.frame.size.width = half
            secondPage.frame = CGRect(x: content.minX+half+8,y: content.minY,width: half,height: content.height)
            splitDivider.frame = CGRect(x: content.minX+half,y: content.minY,width: 8,height: content.height)
        }
        for (i,button) in lights.enumerated() { button.frame = CGRect(x: 18+i*20,y: 19,width: 14,height: 14) }
        var t = CATransform3DIdentity
        if perspective && !reduceMotion {
            var p = CATransform3DIdentity; p.m34 = -1/2000
            p = CATransform3DRotate(p,4 * .pi/180,0,1,0); p = CATransform3DRotate(p,.pi/180,1,0,0)
            t = CATransform3DConcat(t,p)
        }
        stage.layer?.transform = t
        rim.frame = stage.bounds
        rimEdge.frame = stage.bounds; rimEdge.lineWidth = designSize.width/max(1,bounds.width)
        let edge = CGMutablePath(); let radius = OnboardingTokens.Room.miniatureRadius
        edge.move(to: CGPoint(x: radius,y: 0.7)); edge.addLine(to: CGPoint(x: designSize.width-radius,y: 0.7))
        edge.addQuadCurve(to: CGPoint(x: designSize.width-0.7,y: radius),control: CGPoint(x: designSize.width-0.7,y: 0.7))
        edge.addLine(to: CGPoint(x: designSize.width-0.7,y: designSize.height-radius)); rimEdge.path = edge
        contact.frame = bounds
        contact.shadowPath = CGPath(ellipseIn: CGRect(x: bounds.width*0.075,y: bounds.height-18,width: bounds.width*0.85,height: 24),transform: nil)
        layer?.shadowPath = CGPath(roundedRect: bounds,cornerWidth: 14,cornerHeight: 14,transform: nil)
        if let command { command.view.frame = CGRect(x: 58,y: 88,width: designSize.width-116,height: 60) }
        CATransaction.commit()
    }
    func apply(theme value: SpaceTheme?,dark: Bool) {
        guard value != appliedTheme || dark != appliedDark else { return }
        appliedTheme = value; appliedDark = dark
        let seedTheme = value?.style == nil && value?.importedArcThemeJSON == nil
        let system: ContentAppearance = seedTheme ? .dark:(dark ? .dark:.light)
        context.systemAppearance = system
        let key = OnboardingTokens.Room.spaceRGBA
        let seed = SpaceStyle(keyColor: RGBAColor(red: key.red,green: key.green,blue: key.blue),colorCount: 2,appearance: .dark,intensityFactor: 0.95)
        let selected = value?.style == nil && value?.importedArcThemeJSON == nil ? SpaceTheme(style: seed):(value ?? SpaceTheme(style: seed))
        model.updateSpace(id: space.id,theme: selected)
        let style = SpaceThemeStyle(theme: selected,system: system)
        self.theme.style = style
        page.dark = dark; page.needsDisplay = true
        stage.appearance = NSAppearance(named: style.resolvedAppearance(system: context.systemAppearance) == .dark ? .darkAqua:.aqua)
    }
    func setName(_ name: String) { model.renameSpace(id: space.id,title: name.isEmpty ? "Your Space":"\(name)'s Space") }

    func setFavorites(_ values: [(String,OnboardingFavicons.Tile)],reduceMotion: Bool) {
        self.reduceMotion = reduceMotion
        let wanted = Set(values.map(\.0))
        for (name,tab) in favoriteTabs where !wanted.contains(name) {
            model.closeTab(id: tab.id); favoriteTabs.removeValue(forKey: name); iconImages.removeValue(forKey: tab.id)
        }
        for (index,value) in values.enumerated() {
            let (name,icon) = value
            if let tab = favoriteTabs[name] {
                if let image = icon.image { iconImages[tab.id] = image }
                sidebar.refreshFavicon(tabID: tab.id)
                continue
            }
            let site = OnboardingStepsController.sites.first { $0.name == name }
            let tab = model.newTab(in: space.id,url: site?.url ?? URL(string: "https://open.example/favorite")!,title: name)
            if let image = icon.image { iconImages[tab.id] = image }
            favoriteTabs[name] = tab; _ = model.addFavorite(tabID: tab.id,to: profile.id,at: index)
            sidebar.layoutSubtreeIfNeeded()
            if let tile = sidebar.favoriteTileView(tabID: tab.id) {
                let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 0; fade.toValue = 1
                fade.duration = 0.3; fade.beginTime = CACurrentMediaTime()+min(0.18,Double(index)*0.018)
                fade.fillMode = .backwards; tile.layer?.add(fade,forKey: "favorite-arrival-fade")
                if !reduceMotion {
                    let spring = CASpringAnimation(keyPath: "transform.scale"); spring.fromValue = 0.8; spring.toValue = 1
                    spring.mass = 1; spring.stiffness = 420; spring.damping = 28; spring.duration = 0.42
                    spring.beginTime = fade.beginTime; spring.fillMode = .backwards; tile.layer?.add(spring,forKey: "favorite-arrival-scale")
                }
            }
        }
        needsLayout = true
    }
    var favoriteState: [String:Any] {
        let actual = sidebar.displayedFavorites
        return ["realSidebar":true,"realTiles":true,"engineContents":0,"selectedCount":profile.favorites.count,
                "visibleCount":actual.count,"emptySlots":0,"ghostRows":0,"arrivalDuration":0.3,"arrivalScales":!reduceMotion,
                "size":[bounds.width,bounds.height],"sidebarWidth":235,"iconFraction":context.favoriteIconFraction ?? 0,"items":actual.compactMap { id -> [String:Any]? in
                    guard let tab = model.tab(id: id),let tile = sidebar.favoriteTileView(tabID: id) else { return nil }
                    return ["name":tab.title,"frame":[tile.frame.minX,tile.frame.minY,tile.frame.width,tile.frame.height]]
                }]
    }
    #if OPEN_AUTOMATION
    var demoState: [String:Any] {
        ["realSidebar":true,"realCommandBar":command != nil,"engineContents":0,
         "designSize":[designSize.width,designSize.height],"scale":renderedScale,
         "pageFrame":[page.frame.minX,page.frame.minY,page.frame.width,page.frame.height],
         "pageBounds":[page.bounds.width,page.bounds.height],"stageBounds":[stage.bounds.width,stage.bounds.height],
         "todayCount":space.today.count,"running":demoRunning,
         "spaceTitles":model.spaces.map { $0.title ?? "" },"pinnedTitles":(context.focusedSpace?.pinned ?? []).compactMap { $0.tab?.displayTitle },
         "splitPaneCount":space.today.compactMap(\.split).first?.panes.count ?? 0,"splitDividerCount":splitDivider == nil ? 0:1,
         "liftedRowVisible":lifted?.superview != nil,"themeKey":space.theme.style.map { [$0.keyColor.red,$0.keyColor.green,$0.keyColor.blue] } ?? [],
         "animationLayers":Self.animationDetails(stage.layer),
         "landedTitle":demoTab.flatMap { sidebar.drawnTitle(tabID: $0.id) } as Any? ?? NSNull()]
    }
    private static func animationDetails(_ layer: CALayer?) -> [[String:Any]] {
        guard let layer else { return [] }
        let own: [[String:Any]] = (layer.animationKeys() ?? []).map { key in
            let animation = layer.animation(forKey: key)
            return ["layer":String(describing: type(of: layer)),"name":layer.name ?? "", "key":key,
                    "duration":animation?.duration ?? 0,"repeats":animation?.repeatCount ?? 0]
        }
        return own+(layer.sublayers ?? []).flatMap { animationDetails($0) }
    }
    func demoLabelFrames(in layer: CALayer?) -> [(String,CGRect)] {
        let tab = demoKind == 0 ? demoTab : (demoKind == 2 ? context.focusedSpace?.pinned.compactMap(\.tab).first:movingTab)
        guard let tab, let label = sidebar.drawnTitle(tabID: tab.id),
              let frame = sidebar.drawnTitleFrame(tabID: tab.id),let source = sidebar.layer else { return [] }
        return [(label,source.convert(frame,to: layer))]
    }
    #endif
    private func prepareDemo() {
        guard !isDemo else { return }; isDemo = true
        context.titleColorTransform = { [weak self] seed in self?.readableTitle(seed) ?? seed }
        // At the compact card size these native rows are about one third of
        // their normal size. Keep solid glyph cores on a 1x panel as well.
        context.titleFontOverride = .systemFont(ofSize: 20,weight: demoKind == 2 ? .bold:.semibold)
        // The same views at a compact window size, with a readable Today list.
        for item in space.pinned { model.closeTab(id: item.id) }
        for item in space.today.dropFirst() { model.closeTab(id: item.id) }
    }
    private func readableTitle(_ seed: NSColor) -> NSColor {
        let style = context.focusedSpace.map(context.style(for:)) ?? theme.targetStyle
        let field = ThemeField.Evaluator(style: style,windowSize: designSize,isActive: true)
        let (r,g,b) = field.color(u: 0.16,v: 0.4)
        let background = NSColor(srgbRed: r,green: g,blue: b,alpha: 1)
        let selected = style.selectedFill(style.resolvedAppearance(system: context.systemAppearance)).nsColor
        let surface = WelcomeTextColors.opaque(selected,over: background)
        // Tiny glyphs need headroom after scaling. Change only ink lightness,
        // retaining the actual Space field, row fill, layout and native text.
        return WelcomeTextColors.text(seed,on: surface,minimum: demoKind == 2 ? 6.5:6)
    }
    func playNewTab(duration: Double) {
        freezeDemo(); context.animatesChanges = true; demoRunning = true; prepareDemo()
        if let tab = demoTab { model.closeTab(id: tab.id); demoTab = nil }
        page.title = "A little room to explore"; page.subtitle = "Start with a question. See where it takes you."
        page.needsDisplay = true; context.isNewTabCommandBarOpen = false; command?.view.isHidden = true
        needsLayout = true; layoutSubtreeIfNeeded()
        schedule(at: 0.3) { [weak self] in self?.showQuery("") }
        let query = "lisbon in spring"
        for count in 1...query.count {
            let text = String(query.prefix(count))
            schedule(at: 0.5+Double(count)*0.153) { [weak self] in self?.showQuery(text) }
        }
        schedule(at: 3.3) { [weak self] in self?.landNewTab() }
        schedule(at: duration) { [weak self] in self?.finishDemo() }
    }
    private func showQuery(_ text: String) {
        if command == nil {
            let value = CommandBarController(engine: SuggestEngine(model: nil,fetcher: nil))
            value.acceptsInputFocus = false; value.allowsSearchHelp = false
            value.view.wantsLayer = true; stage.addSubview(value.view); command = value
        }
        guard let command else { return }
        context.isNewTabCommandBarOpen = true
        command.backdrop = CommandBarBackdrop(color: OnboardingTokens.Room.commandBackdrop)
        command.presentPreview(CommandBarPreview(text: text,input: CommandBarInput(placeholder: "Search or Enter URL…",leadingIcon: .symbol("magnifyingglass",plate: false),trailing: .none),rows: []),presentation: .embedded(width: designSize.width-116))
        command.view.frame = CGRect(x: 58,y: 88,width: designSize.width-116,height: 60)
        command.view.layoutSubtreeIfNeeded()
    }
    private func landNewTab() {
        command?.dismiss(reason: .programmatic); context.isNewTabCommandBarOpen = false
        if demoTab == nil {
            let tab = model.newTab(in: space.id,url: URL(string: "https://open.example/lisbon")!,title: "Lisbon in spring")
            demoTab = tab; model.selectNode(windowID: context.windowID,spaceID: space.id,nodeID: tab.id)
        }
        page.title = "Lisbon in spring"; page.subtitle = "A new place. A fresh point of view."; page.needsDisplay = true
    }
    private func schedule(at delay: Double,action: @escaping @MainActor () -> Void) {
        demoTasks.append(Task { try? await Task.sleep(for: .seconds(delay)); guard !Task.isCancelled else { return }; action() })
    }
    func freezeDemo() {
        demoTasks.forEach { $0.cancel() }; demoTasks.removeAll(); demoRunning = false
        context.animatesChanges = false
        command?.dismiss(reason: .programmatic); context.isNewTabCommandBarOpen = false
        Self.removeAnimations(stage.layer)
    }
    func finishDemo() {
        freezeDemo(); prepareDemo()
        switch demoKind {
        case 1: landPin()
        case 2: finishSpaces()
        case 3: landSplit()
        default: landNewTab()
        }
        lifted?.removeFromSuperview(); lifted = nil; needsLayout = true
        layoutSubtreeIfNeeded(); Self.removeAnimations(stage.layer)
    }
    func playDemo(duration: Double) {
        guard demoKind != 0 else { playNewTab(duration: duration); return }
        freezeDemo(); prepareDemo(); resetComposition(); context.animatesChanges = true; demoRunning = true
        switch demoKind {
        case 1:
            let row = ensureMovingTab(title: "Weekend reading")
            _ = model.moveNode(id: row.id,to: .spaceToday(space.id),at: 0)
            page.title = "Keep a good idea close"; page.subtitle = "A place for the pages you return to."
            schedule(at: 0.2) { [weak self] in self?.liftRow(toPin: true,duration: 3.4) }
            schedule(at: 3.65) { [weak self] in self?.landPin() }
        case 2:
            ensureAlternateSpace(); model.focusSpace(windowID: context.windowID,spaceID: space.id)
            page.title = "A little room for everything"; page.subtitle = "Separate sidebars. A clear point of view."
            schedule(at: 1.05) { [weak self] in
                guard let self, let alternateSpace else { return }
                model.focusSpace(windowID: context.windowID,spaceID: alternateSpace.id)
            }
        default:
            _ = ensureMovingTab(title: "Places to stay")
            page.title = "A weekend in Lisbon"; page.subtitle = "The plan and the possibilities, side by side."
            schedule(at: 0.2) { [weak self] in self?.liftRow(toPin: false,duration: 3.23) }
            schedule(at: 3.5) { [weak self] in self?.landSplit() }
        }
        page.needsDisplay = true; needsLayout = true
        schedule(at: duration) { [weak self] in self?.finishDemo() }
    }
    private func resetComposition() {
        lifted?.removeFromSuperview(); lifted = nil
        secondPage?.removeFromSuperview(); secondPage = nil; splitDivider?.removeFromSuperview(); splitDivider = nil
        if let split = space.pinned.first(where: { $0.split != nil })?.split ?? space.today.first(where: { $0.split != nil })?.split { model.unsplit(splitID: split.id) }
        model.focusSpace(windowID: context.windowID,spaceID: space.id)
    }
    private func ensureMovingTab(title: String) -> Tab {
        if let movingTab, model.tab(id: movingTab.id) != nil { return movingTab }
        let row = model.newTab(in: space.id,url: URL(string: "https://open.example/reading")!,title: title)
        movingTab = row; model.selectNode(windowID: context.windowID,spaceID: space.id,nodeID: row.id)
        return row
    }
    private func liftRow(toPin: Bool,duration: Double) {
        let row = ensureMovingTab(title: toPin ? "Weekend reading":"Places to stay")
        layoutSubtreeIfNeeded(); sidebar.layoutSubtreeIfNeeded()
        guard let view = sidebar.liftedRow(tabID: row.id), let source = sidebar.rowFrame(nodeID: row.id) else { return }
        view.frame = sidebar.convert(source,to: stage); stage.addSubview(view); lifted = view
        let start = view.layer?.position ?? .zero
        let destination = toPin ? CGPoint(x: start.x+20,y: max(154,start.y-72)):CGPoint(x: 450,y: designSize.height*0.52)
        view.layer?.position = destination
        let move = CABasicAnimation(keyPath: "position"); move.fromValue = NSValue(point: start); move.toValue = NSValue(point: destination)
        move.duration = duration; move.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut); view.layer?.add(move,forKey: "native-drag-travel")
        let scale = CAKeyframeAnimation(keyPath: "transform.scale"); scale.values = [1,1.04,1.04,1]; scale.keyTimes = [0,0.15,0.85,1]
        scale.duration = duration; view.layer?.add(scale,forKey: "native-drag-lift")
    }
    private func landPin() {
        let tab = ensureMovingTab(title: "Weekend reading")
        _ = model.moveNode(id: tab.id,to: .spacePinned(space.id),at: 0)
        model.selectNode(windowID: context.windowID,spaceID: space.id,nodeID: tab.id)
        lifted?.removeFromSuperview(); lifted = nil
        page.title = "Keep a good idea close"; page.subtitle = "Pinned. Ready when you are."; page.needsDisplay = true
    }
    private func ensureAlternateSpace() {
        guard alternateSpace == nil else { return }
        let other = model.createSpace(title: "Home",profileID: profile.id,icon: .symbol("house.fill"),theme: space.theme)
        let tab = model.newTab(in: other.id,url: URL(string: "https://open.example/home")!,title: "A slower Sunday")
        _ = model.moveNode(id: tab.id,to: .spacePinned(other.id),at: 0)
        _ = model.newTab(in: other.id,url: URL(string: "https://open.example/garden")!,title: "The garden journal")
        alternateSpace = other
    }
    private func finishSpaces() {
        ensureAlternateSpace()
        if let alternateSpace { model.focusSpace(windowID: context.windowID,spaceID: alternateSpace.id) }
        page.title = "Make yourself at home"; page.subtitle = "A different Space. A fresh start."; page.needsDisplay = true
    }
    private func landSplit() {
        let row = ensureMovingTab(title: "Places to stay")
        if !space.today.contains(where: { $0.split != nil }) {
            let first = space.today.compactMap(\.tab).first(where: { $0.id != row.id }) ?? model.newTab(in: space.id,url: URL(string: "https://open.example/lisbon")!,title: "A weekend in Lisbon")
            if let split = model.makeSplit(tabIDs: [first.id,row.id]) { model.selectNode(windowID: context.windowID,spaceID: space.id,nodeID: split.id) }
        }
        if secondPage == nil {
            let other = MiniaturePage(); other.title = "Somewhere to stay"; other.subtitle = "A sunny room. A quiet street."
            let divider = SplitDividerView(frame: .zero); divider.isEnabled = false
            secondPage = other; splitDivider = divider; stage.addSubview(divider); stage.addSubview(other)
            other.layer?.borderWidth = 1.5; other.layer?.borderColor = OnboardingTokens.Room.sunMiddle.cgColor
        }
        lifted?.removeFromSuperview(); lifted = nil
        page.title = "A weekend in Lisbon"; page.subtitle = "Two views. One good plan."; page.needsDisplay = true; needsLayout = true
    }
    static func demoTheme(kind: Int) -> SpaceTheme {
        let keys = OnboardingTokens.Room.demoSpaces
        let key = keys[min(3,max(0,kind))]
        return SpaceTheme(style: SpaceStyle(keyColor: RGBAColor(red: key.red,green: key.green,blue: key.blue,alpha: 1),colorCount: 2,wheel: .analogous,appearance: .dark,noiseFactor: 0,intensityFactor: 0.95))
    }
    func setEditorial(title: String,subtitle: String) {
        page.title = title; page.subtitle = subtitle; page.needsDisplay = true
    }
    func setBlocker(_ enabled: Bool,animated: Bool) { page.setBlocker(enabled,animated: animated && !reduceMotion) }
    func clearBlocker() { page.clearBlocker() }
    func receiveLink() {
        let tab = model.newTab(in: space.id,url: URL(string: "https://open.example/a-good-read")!,title: "A good read from Mail")
        model.selectNode(windowID: context.windowID,spaceID: space.id,nodeID: tab.id)
        setEditorial(title: "A good read, right here",subtitle: "Every link has a place to land.")
    }
    func setImportedSource(_ source: BrowserModel,completed: Bool,count: Int) {
        setEditorial(title: completed ? "Your familiar places":"Bring your world with you",subtitle: completed ? "Your Spaces and pinned tabs, together again.":"Your tabs will feel at home here.")
        guard completed else { return }
        let signature = source.spaces.map { "\($0.id):\($0.pinned.count):\($0.today.count)" }.joined(separator: ";")
        guard signature != importedSignature else { return }; importedSignature = signature
        for item in space.pinned+space.today { model.closeTab(id: item.id) }
        for (index,original) in source.spaces.prefix(4).enumerated() {
            let destination = index == 0 ? space:model.createSpace(title: original.title ?? "Imported Space",profileID: profile.id,icon: original.icon,theme: original.theme)
            model.updateSpace(id: destination.id,title: original.title)
            for item in original.pinned.prefix(6) { copyImported(item,into: .spacePinned(destination.id),spaceID: destination.id,depth: 0) }
            for item in original.today.prefix(4) { copyImported(item,into: .spaceToday(destination.id),spaceID: destination.id,depth: 0) }
        }
        model.focusSpace(windowID: context.windowID,spaceID: space.id)
    }
    private func copyImported(_ node: SidebarNode,into parent: NodeParent,spaceID: SpaceID,depth: Int) {
        guard depth < 4 else { return }
        switch node {
        case .tab(let tab):
            let copy = model.newTab(in: spaceID,url: tab.url,title: tab.displayTitle)
            _ = model.moveNode(id: copy.id,to: parent,at: nil)
        case .folder(let original):
            guard let folder = model.createFolder(in: parent,title: original.title) else { return }
            for child in original.children.prefix(4) { copyImported(child,into: .folder(folder.id),spaceID: spaceID,depth: depth+1) }
            model.setExpanded(folderID: folder.id,expanded: original.isExpanded)
        case .split(let original):
            let copies = original.panes.prefix(2).map { model.newTab(in: spaceID,url: $0.url,title: $0.displayTitle) }
            if let split = model.makeSplit(tabIDs: copies.map(\.id),orientation: original.orientation) { _ = model.moveNode(id: split.id,to: parent,at: nil) }
        }
    }

    private static func animationKeys(_ layer: CALayer?) -> Int { guard let layer else { return 0 }; return (layer.animationKeys()?.count ?? 0)+(layer.sublayers ?? []).reduce(0) { $0+animationKeys($1) } }
    private static func removeAnimations(_ layer: CALayer?) { layer?.removeAllAnimations(); layer?.sublayers?.forEach { removeAnimations($0) } }
}

@MainActor private final class MiniatureViewport: NSView {
    override var isFlipped: Bool { true }
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true }
    required init?(coder: NSCoder) { nil }
}

@MainActor private final class MiniatureStage: NSView {
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true
        layer?.cornerRadius = OnboardingTokens.Room.miniatureRadius; layer?.cornerCurve = .continuous; layer?.masksToBounds = true
    }
    required init?(coder: NSCoder) { nil }
}

/// Deliberately small editorial content; actual type and imagery replace the
/// old empty rectangles. One drawing, no retained bitmap or web contents.
@MainActor private final class MiniaturePage: NSView {
    override var isFlipped: Bool { true }
    var title = "Welcome to Open"
    var subtitle = "Make yourself at home."
    var dark = false
    private let ad = MiniatureAdvertisement(frame: .zero)
    private let sweep = CAGradientLayer()
    private var blockerEnabled: Bool?
    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true; layer?.cornerRadius = 11; layer?.masksToBounds = true
        addSubview(ad); ad.isHidden = true
        sweep.colors = [OnboardingTokens.Room.sunMiddle.withAlphaComponent(0).cgColor,OnboardingTokens.Room.sunTop.withAlphaComponent(0.55).cgColor,OnboardingTokens.Room.sunMiddle.withAlphaComponent(0).cgColor]
        sweep.startPoint = CGPoint(x: 0,y: 0.5); sweep.endPoint = CGPoint(x: 1,y: 0.5); sweep.opacity = 0
        layer?.addSublayer(sweep)
    }
    required init?(coder: NSCoder) { nil }
    override func layout() {
        super.layout(); ad.frame = CGRect(x: 22,y: max(240,bounds.height-152),width: max(1,bounds.width-44),height: 120)
        CATransaction.begin(); CATransaction.setDisableActions(true); sweep.frame = bounds; CATransaction.commit()
    }
    func clearBlocker() { guard blockerEnabled != nil else { return }; blockerEnabled = nil; ad.isHidden = true; needsDisplay = true }
    func setBlocker(_ enabled: Bool,animated: Bool) {
        guard blockerEnabled != enabled else { return }; blockerEnabled = enabled
        ad.isHidden = enabled; needsDisplay = true
        if animated {
            let light = CABasicAnimation(keyPath: "transform.translation.x"); light.fromValue = -bounds.width; light.toValue = bounds.width; light.duration = 0.5
            let opacity = CAKeyframeAnimation(keyPath: "opacity"); opacity.values = [0,1,1,0]; opacity.keyTimes = [0,0.12,0.8,1]; opacity.duration = 0.5
            sweep.add(light,forKey: "blocker-sweep"); sweep.add(opacity,forKey: "blocker-light")
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds
        OnboardingTokens.Room.page.setFill(); r.fill()
        let left: CGFloat = 30, width = r.width-60
        (title as NSString).draw(in: CGRect(x: left,y: 32,width: width,height: 68),withAttributes: [.font:NSFont.systemFont(ofSize: 23,weight: .semibold),.kern:-0.46,.foregroundColor:OnboardingTokens.Room.pageInk])
        let imageRect = CGRect(x: left,y: 104,width: width,height: min(150,r.height*0.32))
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: imageRect,xRadius: 10,yRadius: 10).addClip()
        NSGradient(colors: [OnboardingTokens.Room.sunTop,OnboardingTokens.Room.imageMiddle,OnboardingTokens.Room.imageEnd])?.draw(in: imageRect,angle: -35)
        // An original sun and landscape give the image block a focal point.
        OnboardingTokens.Room.sunTop.withAlphaComponent(0.7).setFill()
        NSBezierPath(ovalIn: CGRect(x: imageRect.maxX-92,y: imageRect.minY+22,width: 48,height: 48)).fill()
        let hill = NSBezierPath(); hill.move(to: CGPoint(x: imageRect.minX,y: imageRect.maxY)); hill.curve(to: CGPoint(x: imageRect.maxX,y: imageRect.maxY-40),controlPoint1: CGPoint(x: imageRect.midX-55,y: imageRect.minY+50),controlPoint2: CGPoint(x: imageRect.midX+45,y: imageRect.maxY+30)); hill.line(to: CGPoint(x: imageRect.maxX,y: imageRect.maxY)); hill.close()
        OnboardingTokens.Room.imageEnd.withAlphaComponent(0.45).setFill(); hill.fill(); NSGraphicsContext.restoreGraphicsState()
        (subtitle as NSString).draw(in: CGRect(x: left,y: imageRect.maxY+24,width: width,height: 42),withAttributes: [.font:NSFont.systemFont(ofSize: 15,weight: .medium),.foregroundColor:OnboardingTokens.Room.pageInk])
        let body = "Keep your everyday places close.\nLeave room for something new."
        (body as NSString).draw(in: CGRect(x: left,y: imageRect.maxY+68,width: width,height: 96),withAttributes: [.font:NSFont.systemFont(ofSize: 13),.foregroundColor:OnboardingTokens.Room.pageInk.withAlphaComponent(0.68)])
        if let blockerEnabled {
            ((blockerEnabled ? "12 blocked":"Ads are visible") as NSString).draw(in: CGRect(x: left,y: r.height-28,width: width,height: 20),withAttributes: [.font:NSFont.systemFont(ofSize: 12,weight: .semibold),.foregroundColor:OnboardingTokens.Room.pageInk.withAlphaComponent(0.68)])
        }
        if r.height > 600 {
            let headings = ["Make space for the good stuff.","Your next chapter starts here."]
            for (section,heading) in headings.enumerated() {
                let y = imageRect.maxY+196+CGFloat(section)*158
                (heading as NSString).draw(in: CGRect(x: left,y: y,width: width,height: 26),withAttributes: [.font:NSFont.systemFont(ofSize: 17,weight: .semibold),.foregroundColor:OnboardingTokens.Room.pageInk])
                let copy = section == 0 ? "Keep your favourites in easy reach.":"Follow a link. Find a new perspective."
                (copy as NSString).draw(in: CGRect(x: left,y: y+38,width: width,height: 88),withAttributes: [.font:NSFont.systemFont(ofSize: 13),.foregroundColor:OnboardingTokens.Room.pageInk.withAlphaComponent(0.68)])
            }
        }
    }
}

@MainActor private final class MiniatureAdvertisement: NSView {
    override var isFlipped: Bool { true }
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true; layer?.cornerRadius = 8; layer?.masksToBounds = true }
    required init?(coder: NSCoder) { nil }
    override func draw(_ dirtyRect: NSRect) {
        OnboardingTokens.Room.sunTop.setFill(); bounds.fill()
        ("ADVERTISEMENT" as NSString).draw(at: CGPoint(x: 14,y: 12),withAttributes: [.font:NSFont.systemFont(ofSize: 9,weight: .medium),.kern:1.1,.foregroundColor:OnboardingTokens.Room.pageInk.withAlphaComponent(0.6)])
        ("A louder corner of the internet." as NSString).draw(in: bounds.insetBy(dx: 14,dy: 37),withAttributes: [.font:NSFont.systemFont(ofSize: 16,weight: .semibold),.foregroundColor:OnboardingTokens.Room.pageInk])
    }
}
