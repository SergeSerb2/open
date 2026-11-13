import AppKit

/// Live web cards (findings §3.5: a web card can flip from its screenshot to the live page;
/// `EaselWebContentPool.liveWebViews`). At most `maxLive` pages exist per canvas: the live
/// cards that are on screen, top-most first. Others draw their screenshot. A hidden canvas
/// (another tab selected, window closed) releases every page, so idle CPU returns to zero.
extension EaselCanvasView {
    public static let maxLive = 3
    static let liveEduKey = "open.easel.liveWebCardEduSeen"

    public var liveObjectIDs: [UUID] { objectViews.filter { $0.value.liveView != nil }.map(\.key) }

    func updateLiveViews() {
        let visible = window != nil && !isHiddenOrHasHiddenAncestor
        let clip = scrollView.contentView.bounds
        var wanted: [UUID: URL] = [:]
        if visible {
            for object in document.paintOrder.reversed() {
                guard wanted.count < Self.maxLive, case .webCard(let card) = object.content, card.isLive,
                      let url = URL(string: card.url), ["http", "https", "file"].contains(url.scheme?.lowercased() ?? ""),
                      viewRect(object.frame).intersects(clip) else { continue }
                wanted[object.id] = url
            }
        }
        for (id, view) in objectViews where view.liveView != nil && wanted[id] == nil {
            view.liveView = nil
            liveViewRelease?(id)
        }
        for (id, url) in wanted where objectViews[id]?.liveView == nil {
            objectViews[id]?.liveView = liveViewProvider?(id, url)
        }
    }

    func releaseAllLiveViews() {
        for (id, view) in objectViews where view.liveView != nil { view.liveView = nil; liveViewRelease?(id) }
    }

    /// Show Live Website / Show Screenshot. The first switch to live asks once (sheet).
    public func setLive(_ live: Bool, for id: UUID, confirmed: Bool = false) {
        guard let object = document.object(id), case .webCard(var card) = object.content, card.isLive != live else { return }
        if live, !confirmed, !UserDefaults.standard.bool(forKey: Self.liveEduKey), let window {
            let alert = NSAlert()
            // Arc's text (docs/re/easels-notes.md §3.5). Arc's body ends "…by pressing <shortcut>"; the
            // shortcut and the button titles are not captured (C3-EZ-1), so Open ends with its own
            // menu wording and keeps its own buttons.
            alert.messageText = "Replace this screenshot with the live website?"
            alert.informativeText = "See an up-to-date, interactive view of whatever you've captured. This does not work on all sites. You can always flip back to the screenshot with Show Screenshot in the card's menu."
            alert.addButton(withTitle: "Show Live Website")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { [weak self] response in
                guard response == .alertFirstButtonReturn else { return }
                UserDefaults.standard.set(true, forKey: Self.liveEduKey)
                self?.setLive(true, for: id, confirmed: true)
            }
            return
        }
        card.live = live ? true : nil
        mutate(live ? "Show Live Website" : "Show Screenshot") { doc in
            if let i = doc.index(of: id) { doc.objects[i].content = .webCard(card) }
        }
    }
}
