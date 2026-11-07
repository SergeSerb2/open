import AppKit
import ImageIO
import OpenModel
import OpenBoosts
import OpenAdBlock
import OpenDesign

public struct BoostScopeChoice: Sendable, Equatable {
    public let title: String
    public let match: SiteMatch
    public init(title: String, match: SiteMatch) { self.title = title; self.match = match }
}

/// Each control owns its repeat/drag group. A stale timer cannot commit another control.
public struct BoostEditorInteractionOwner: Hashable, Sendable {
    private let id = UUID()
    public init() {}
}

@MainActor
public final class BoostEditorSession {
    public let context: SiteControlContext
    public let isNew: Bool
    public let undoManager = UndoManager()
    public private(set) var boost: Boost
    public private(set) var colorsReady: Bool
    public private(set) var isClosed = false
    public var onChange: (() -> Void)?
    public var onDelete: (() -> Void)?
    public let defaults: UserDefaults
    private let host: BoostEditorHost
    private let store: BoostStore
    private var interactiveBefore: Boost?
    private var interactiveOwner: BoostEditorInteractionOwner?
    public var isInteracting: Bool { interactiveBefore != nil }
    private var interactiveName = "Change Boost"
    private var previewWork: DispatchWorkItem?
    private var lastPreview: TimeInterval = -.infinity
    private var sampledHue: Double?
    private var sampleTask: Task<Double?, Never>?
    private var sampleGeneration = 0
    private var deleted = false
    /// The exact configured delays of pending native edits; cleared when flushed.
    public private(set) var pendingCodeSaveDelays: [BoostCodeLanguage: TimeInterval] = [:]
    private var codeWork: [BoostCodeLanguage: DispatchWorkItem] = [:]
    private var codeBefore: [BoostCodeLanguage: Boost] = [:]
    private var codeDrafts: [BoostCodeLanguage: String] = [:]
    public private(set) var devToolsVisible = false
    public var showsJSNotice: Bool { !(codeDrafts[.js] ?? boost.js).isEmpty && !defaults.bool(forKey: "open.boosts.hasDismissedJSNotice") }
    public var needsJSReload: Bool { boost.js != (host.loadedJS(boostID: boost.id,tabID: context.tabID) ?? "") }
    public func code(_ language: BoostCodeLanguage) -> String { codeDrafts[language] ?? (language == .css ? boost.css : boost.js) }
    public func editCode(_ text: String,language: BoostCodeLanguage) {
        guard isEditable else { return }
        if codeBefore[language] == nil { codeBefore[language] = boost }
        let noticeBefore = showsJSNotice
        codeDrafts[language] = text;codeWork[language]?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.flushCode(language) } }
        codeWork[language] = work
        let delay = language == .css ? BoostEditorMetrics.cssSaveDelay : BoostEditorMetrics.jsSaveDelay
        pendingCodeSaveDelays[language] = delay
        DispatchQueue.main.asyncAfter(deadline: .now()+delay,execute: work)
        if noticeBefore != showsJSNotice { onChange?() }
    }
    public func flushCode(_ language: BoostCodeLanguage? = nil) {
        for kind in language.map({ [$0] }) ?? [.css,.js] {
            codeWork.removeValue(forKey: kind)?.cancel();pendingCodeSaveDelays.removeValue(forKey: kind)
            guard let text = codeDrafts.removeValue(forKey: kind),isEditable else { continue }
            if kind == .css { boost.css = text } else { boost.js = text }
            boost = store.upsert(boost)
            host.refresh(profile: context.profileID)
        }
        onChange?()
    }
    /// Text undo stays native while focused. Leaving the field records one
    /// whole-Boost checkpoint, as the simple editor's Undo button expects.
    public func endCodeEditing(_ language: BoostCodeLanguage? = nil) {
        flushCode(language)
        for kind in language.map({ [$0] }) ?? [.css,.js] {
            guard let before = codeBefore.removeValue(forKey: kind),isEditable else { continue }
            let changed = kind == .css ? before.css != boost.css : before.js != boost.js
            if changed { registerRestore(before,name: kind == .css ? "Edit CSS" : "Edit JavaScript", restoresName: false) }
        }
        onChange?()
    }
    public func boundPageDidCommit() { guard !isClosed else { return };onChange?() }
    public func refreshToRun() {
        guard isEditable else { return }
        flushCode();host.reload(tabID: context.tabID)
    }
    public func toggleDevTools() { guard isEditable else { return };devToolsVisible.toggle();host.setDevToolsVisible(devToolsVisible,tabID: context.tabID);onChange?() }
    public func dismissJSNotice() { defaults.set(true,forKey: "open.boosts.hasDismissedJSNotice");onChange?() }

    public private(set) var isZapActive = false
    public private(set) var isSelecting = false
    public var zapAvailable: Bool { host.zapAvailability(tabID: context.tabID) }
    /// Code-mode owner inserts through its NSTextView at the current CSS caret.
    public var insertSelectorAtCaret: ((String) -> Void)?
    private var pickerObservation: SiteControlObservationToken?
    private var currentPageURL: URL?

    public init(context: SiteControlContext, boost: Boost, isNew: Bool = false,
                host: BoostEditorHost, defaults: UserDefaults = .standard) {
        self.context = context; self.boost = boost; self.isNew = isNew
        self.host = host; self.defaults = defaults; store = host.store(for: context.profileID)
        currentPageURL = host.currentURL(tabID: context.tabID) ?? context.url
        colorsReady = boost.colorWheel != nil
        sampledHue = boost.colorWheel?.baseHue
        undoManager.groupsByEvent = false
        pickerObservation = host.observePickerEvents { [weak self] tab, event in
            guard let self, tab == self.context.tabID, !self.isClosed else { return }
            self.handlePickerEvent(event)
        }
    }
    isolated deinit { previewWork?.cancel(); sampleTask?.cancel();codeWork.values.forEach { $0.cancel() } }
    public var isEditable: Bool { !context.isIncognito && !isClosed }
    public var globallyEnabled: Bool { defaults.object(forKey: "open.advanced.enableBoosts") as? Bool ?? true }
    public var showsInterstitial: Bool { !defaults.bool(forKey: "open.boosts.hasDismissedInterstitial") }
    public var showsLegacyColors: Bool { boost.colorWheel == nil && boost.colorAdjustment?.isIdentity == false }
    public var pageURL: URL { currentPageURL ?? context.url }
    public var isActiveOnPage: Bool {
        guard ["http", "https"].contains(pageURL.scheme?.lowercased() ?? "") else { return false }
        var candidate = boost; candidate.isEnabled = true
        return !BoostMatcher(boosts: [candidate]).matching(url: pageURL).isEmpty
    }
    public var displayWheel: BoostColorWheel {
        if let wheel = boost.colorWheel { return wheel.clamped() }
        guard let legacy = boost.colorAdjustment, !legacy.isIdentity else { return BoostColorWheel(baseHue: sampledHue) }
        let c = legacy.clamped(), invert = c.invert >= 0.5
        let turn = ((c.hueRotateDegrees - (invert ? 180 : 0)) + 540).truncatingRemainder(dividingBy: 360) - 180
        // At intensity one, the full hue/saturation ranges remain representable.
        // Zero rotation uses the least intensity needed to represent saturation.
        let intensity = abs(turn) > 1e-9 ? 1 : max(0, c.saturation - 2)
        return BoostColorWheel(hue: (sampledHue ?? 0) + (intensity > 0 ? turn/intensity : 0), intensity: intensity,
            baseHue: sampledHue, invertLightness: invert, brightness: c.brightness, contrast: c.contrast,
            originalSaturation: c.saturation/(1 + 0.5*intensity)).clamped()
    }
    public func updatePageURL(_ url: URL?) {
        let changed = currentPageURL != url
        currentPageURL = url
        endPickerSession()
        if changed && boost.colorWheel == nil { restartColorSampling() }
        onChange?()
    }
    public func dismissInterstitial() {
        guard isEditable else { return }
        defaults.set(true, forKey: "open.boosts.hasDismissedInterstitial"); onChange?()
    }
    public func prepareColors() async {
        guard !colorsReady, !isClosed else { return }
        let generation = sampleGeneration
        if sampleTask == nil {
            let tab = context.tabID, host = self.host
            sampleTask = Task {
                guard let png = await host.pageSnapshot(tabID: tab), !Task.isCancelled else { return nil }
                return await Task.detached(priority: .userInitiated) { Self.dominantHue(png) }.value
            }
        }
        let hue = await sampleTask?.value
        guard generation == sampleGeneration, !isClosed else { return }
        sampledHue = hue ?? nil; colorsReady = true; sampleTask = nil
        onChange?()
    }
    public func beginInteractive(_ name: String = "Change colors", owner: BoostEditorInteractionOwner) {
        guard isEditable else { return }
        if interactiveBefore != nil && interactiveOwner != owner { endInteractive() }
        guard interactiveBefore == nil else { return }
        interactiveBefore = boost; interactiveName = name; interactiveOwner = owner
    }
    public func endInteractive(owner: BoostEditorInteractionOwner? = nil) {
        if let owner, owner != interactiveOwner { return }
        guard let before = interactiveBefore else { return }
        interactiveBefore = nil; interactiveOwner = nil; previewWork?.cancel(); previewWork = nil
        commit(before: before, name: interactiveName)
    }
    @discardableResult public func editWheel(owner: BoostEditorInteractionOwner? = nil, _ edit: (inout BoostColorWheel) -> Void, name: String = "Change colors") -> Bool {
        guard isEditable, colorsReady else { return false }
        let standalone = owner == nil
        beginInteractive(name, owner: owner ?? BoostEditorInteractionOwner())
        var wheel = displayWheel; edit(&wheel)
        boost.colorWheel = wheel.clamped()
        boost = BoostStore.normalizedForPreview(boost)
        schedulePreview(); onChange?()
        if standalone { endInteractive() }
        return true
    }
    public func resetColors() {
        change("Reset colors") { $0.colorWheel = nil; $0.colorAdjustment = nil }
        restartColorSampling()
    }
    public func rename(_ name: String) { change("Rename Boost", restoresName: true) { $0.name = name } }
    /// Library metadata changes do not add an editor undo step or end a gesture.
    /// Content edits remain local; the store owns the current name/enabled flag.
    public func reconcileStoreMetadata() {
        guard !isClosed, let stored = store.boost(id: boost.id),
              boost.name != stored.name || boost.isEnabled != stored.isEnabled else { return }
        boost.name = stored.name; boost.isEnabled = stored.isEnabled
        onChange?()
    }
    public func setScope(_ match: SiteMatch) { change("Change scope") { $0.siteMatch = match } }
    public func setFont(_ family: String?) { change("Change font") { $0.fontFamily = family } }
    public static let textSizes: [Double?] = [0.9, nil, 1.1, 1.25, 1.5]
    public static let textSizeNames = ["Small", "Normal", "Medium", "Large", "Larger"]
    public static let textCases: [String?] = [nil, "capitalize", "uppercase", "lowercase"]
    public static let textCaseNames = ["Original", "Capitalize", "Uppercase", "Lowercase"]
    public var textSizeIndex: Int { Self.textSizes.firstIndex(of: boost.textZoom) ?? 1 }
    public var textCaseIndex: Int { Self.textCases.firstIndex(of: boost.textTransform) ?? 0 }
    public func setTextSize(index: Int) { guard Self.textSizes.indices.contains(index) else { return }; change("Change text size") { $0.textZoom = Self.textSizes[index] } }
    public func setTextCase(index: Int) { guard Self.textCases.indices.contains(index) else { return }; change("Change text case") { $0.textTransform = Self.textCases[index] } }
    public func cycleTextSize(backwards: Bool = false) { setTextSize(index: (textSizeIndex + (backwards ? 4 : 1)) % 5) }
    public func cycleTextCase(backwards: Bool = false) { setTextCase(index: (textCaseIndex + (backwards ? 3 : 1)) % 4) }
    public func shuffle(font: String, hue: Double = Double.random(in: 0..<360), intensity: Double = Double.random(in: 0.6...1)) {
        guard colorsReady else { return }
        change("Shuffle") { b in
            var wheel = displayWheel; wheel.hue = hue; wheel.intensity = intensity
            b.colorWheel = wheel; b.fontFamily = font
        }
    }
    public func resetAll() {
        flushCode()
        change("Reset all edits") { b in
            b.colorWheel = nil; b.colorAdjustment = nil; b.fontFamily = nil
            b.textZoom = nil; b.textTransform = nil; b.zaps = []; b.css = ""; b.js = ""
        }
        restartColorSampling()
    }
    public func toggleZap() {
        guard isEditable, globallyEnabled, isActiveOnPage, zapAvailable else { return }
        if isZapActive { endPickerSession(); return }
        if isSelecting { endPickerSession() }
        endInteractive()
        isZapActive = host.enterZap(boostID: boost.id, tabID: context.tabID)
        if isZapActive { host.requestZapCounts(tabID: context.tabID) }
        onChange?()
    }
    public func pickSelector() {
        guard isEditable, globallyEnabled, isActiveOnPage else { return }
        if isSelecting { endPickerSession(); return }
        if isZapActive { endPickerSession() }
        endInteractive()
        isSelecting = host.enterSelectorPicker(boostID: boost.id, tabID: context.tabID)
        onChange?()
    }
    /// App calls this on tab switch, navigation (including same-URL reload),
    /// frame destruction, and transport loss. Close sends its own unconditional exit.
    public func endPickerSession() {
        guard isZapActive || isSelecting else { return }
        host.exitZap(tabID: context.tabID)
        isZapActive = false; isSelecting = false; onChange?()
    }
    private func handlePickerEvent(_ event: BoostPickerEvent) {
        switch event {
        case let .committed(value), let .removed(value):
            guard value.id == boost.id, let saved = store.boost(id: boost.id) else { return }
            let before = boost
            boost = saved
            if boost != before { registerRestore(before, name: "Change Zap", restoresName: false) }
        case .exited: isZapActive = false; isSelecting = false
        case let .selected(selector, _):
            guard isSelecting else { return }
            insertSelectorAtCaret?(selector)
            endPickerSession()
        case .listResult: break
        }
        onChange?()
    }
    public func showAllBoosts() { host.showBoostsLibrary(profileID: context.profileID) }
    public func delete() {
        guard isEditable else { return }
        codeWork.values.forEach { $0.cancel() };codeWork.removeAll();pendingCodeSaveDelays.removeAll();codeDrafts.removeAll();codeBefore.removeAll()
        previewWork?.cancel(); sampleTask?.cancel(); deleted = true
        previewWork = nil; interactiveBefore = nil; interactiveOwner = nil
        _ = store.delete(id: boost.id); store.saveNow(); host.refresh(profile: context.profileID)
        onDelete?()
    }
    public func finish() {
        guard !isClosed else { return }
        if interactiveBefore != nil { endInteractive() }
        flushCode()
        previewWork?.cancel(); previewWork = nil; sampleTask?.cancel()
        host.exitZap(tabID: context.tabID)
        isZapActive = false; isSelecting = false
        if let pickerObservation { host.removePickerObserver(pickerObservation); self.pickerObservation = nil }
        if isNew && boost.isEmpty && !deleted {
            _ = store.delete(id: boost.id); host.refresh(profile: context.profileID)
        }
        store.saveNow()
        undoManager.removeAllActions()
        isClosed = true
    }
    public func scopeChoices() -> [BoostScopeChoice] {
        var hostName = SiteMatch(domain: pageURL.host ?? boost.siteMatch.domain).domain
        if hostName.hasPrefix("www.") { hostName.removeFirst(4) }
        let hostMatch = SiteMatch(domain: hostName)
        var choices: [BoostScopeChoice] = []
        if hostMatch.targetsIPAddress {
            choices.append(BoostScopeChoice(title: hostName, match: hostMatch))
        } else {
            let registrable = (try? AdBlockSites.shared.registrableDomain(hostName)) ?? hostName
            choices.append(BoostScopeChoice(title: "All of " + registrable, match: SiteMatch(domain: registrable)))
            var current = hostName
            while current != registrable && current.hasSuffix("." + registrable) {
                choices.append(BoostScopeChoice(title: current + " and subdomains", match: SiteMatch(domain: current)))
                guard let dot = current.firstIndex(of: ".") else { break }
                current = String(current[current.index(after: dot)...])
            }
        }
        if let segment = pageURL.path(percentEncoded: true).split(separator: "/").first {
            choices.append(BoostScopeChoice(title: "Only pages under /" + segment,
                match: SiteMatch(domain: boost.siteMatch.domain, pathPrefix: "/" + segment)))
        }
        if let prefix = boost.siteMatch.pathPrefix,
           !choices.contains(where: { $0.match == boost.siteMatch }) {
            choices.append(BoostScopeChoice(title: "Only pages under " + prefix, match: boost.siteMatch))
        }
        return choices
    }
    private func change(_ name: String, restoresName: Bool = false, edit: (inout Boost) -> Void) {
        guard isEditable else { return }
        if interactiveBefore != nil { endInteractive() }
        reconcileStoreMetadata()
        endCodeEditing()
        let before = boost; var candidate = boost; edit(&candidate); boost = BoostStore.normalizedForPreview(candidate)
        commit(before: before, name: name, restoresName: restoresName)
    }
    private func commit(before: Boost, name: String, restoresName: Bool = false) {
        guard boost != before, isEditable else { return }
        registerRestore(before, name: name, restoresName: restoresName)
        boost = store.upsert(boost)
        host.refresh(profile: context.profileID); onChange?()
    }
    private func registerRestore(_ value: Boost, name: String, restoresName: Bool) {
        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.restore(value, name: name, restoresName: restoresName) }
        }
        undoManager.setActionName(name); undoManager.endUndoGrouping()
    }
    private func restore(_ value: Boost, name: String, restoresName: Bool) {
        guard isEditable else { return }
        previewWork?.cancel(); previewWork = nil; interactiveBefore = nil; interactiveOwner = nil
        reconcileStoreMetadata()
        let inverse = boost
        undoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.restore(inverse, name: name, restoresName: restoresName) }
        }
        undoManager.setActionName(name)
        for zap in boost.zaps where !value.zaps.contains(where: { $0.selector == zap.selector }) {
            host.removeZapFromSession(zap.selector, tabID: context.tabID)
        }
        var restored = value
        // Undo/Redo always retain the current enabled flag. Only the editor's
        // own Rename step may restore a name from its history snapshot.
        if let stored = store.boost(id: boost.id) {
            restored.isEnabled = stored.isEnabled
            if !restoresName { restored.name = stored.name }
        }
        boost = store.upsert(restored)
        if isZapActive { host.requestZapCounts(tabID: context.tabID) }
        host.refresh(profile: context.profileID); onChange?()
    }
    private func schedulePreview() {
        guard globallyEnabled, isEditable else { return }
        if previewWork != nil { return }
        let wait = max(0, 1.0/60 - (ProcessInfo.processInfo.systemUptime-lastPreview))
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isEditable else { return }
                self.previewWork = nil; self.lastPreview = ProcessInfo.processInfo.systemUptime
                if self.globallyEnabled { self.host.preview(self.boost, tabID: self.context.tabID) }
            }
        }
        previewWork = work; DispatchQueue.main.asyncAfter(deadline: .now()+wait, execute: work)
    }
    private func restartColorSampling() {
        sampleGeneration += 1; sampleTask?.cancel(); sampleTask = nil; sampledHue = nil; colorsReady = false
        Task { [weak self] in await self?.prepareColors() }
    }
    nonisolated public static func dominantHue(_ png: Data) -> Double? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 64,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary),
              let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 64*4,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let bytes = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 64, height: 64))
        var bins = [Double](repeating: 0, count: 36), sinBins = bins, cosBins = bins
        for i in 0..<(64*64) {
            let r = Double(bytes[i*4])/255, g = Double(bytes[i*4+1])/255, b = Double(bytes[i*4+2])/255
            let high = max(r,g,b), low = min(r,g,b), d = high-low
            let saturation = high == 0 ? 0 : d/high
            guard saturation >= 0.25, high >= 0.25, d > 0 else { continue }
            var hue = high == r ? (g-b)/d : high == g ? (b-r)/d+2 : (r-g)/d+4
            hue *= 60; if hue < 0 { hue += 360 }
            let weight = saturation*high, bin = min(35, Int(hue/10)), radians = hue*Double.pi/180
            bins[bin] += weight; sinBins[bin] += sin(radians)*weight; cosBins[bin] += cos(radians)*weight
        }
        guard bins.reduce(0,+) >= Double(64*64)*0.02, let peak = bins.indices.max(by: { bins[$0] < bins[$1] }) else { return nil }
        let indices = [(peak+35)%36, peak, (peak+1)%36]
        let x = indices.reduce(0) { $0+cosBins[$1] }, y = indices.reduce(0) { $0+sinBins[$1] }
        var hue = atan2(y,x)*180/Double.pi; if hue < 0 { hue += 360 }; return hue
    }
}
