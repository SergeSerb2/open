import AppKit
import OpenCommandBar
import OpenDesign
import OpenModel
import OpenSuggest

/// Flows 87–90 (docs/plans/commandbar-completion.md §5.1): no open or close animation (CC-44)
/// and the (i) privacy footer (CC-42). Real key and mouse events, real engine, real views.
@MainActor
enum FooterFlows {
    static func run(_ env: Scenes.Env) -> [Flows.Check] {
        var checks: [Flows.Check] = []
        func check(_ name: String, _ pass: Bool, _ detail: @autoclosure () -> String) {
            let d = detail()
            checks.append(.init(name: name, pass: pass, detail: d))
            print("\(pass ? "PASS" : "FAIL")  \(name)  —  \(d)")
        }
        func fresh(_ mode: CommandBarMode = .newTab, engine: SuggestEngine? = nil, remote: Bool = false) -> Stage {
            let s = Stage(size: CGSize(width: 1440, height: 900), scale: 1, engine: engine ?? env.engine, backdrop: .darkPage)
            s.controller.favicons = env.favicons
            s.controller.theme = Scenes.theme(env)
            var r = Scenes.request(env, mode: mode)
            r.allowsRemoteSuggestions = remote
            s.controller.present(r)
            s.settle()
            return s
        }
        func pixel(_ image: CGImage, _ p: CGPoint) -> [Int] { CLI.pixel(image, p) }

        // 87. Present and dismiss change the panel in one frame: no scale, no fade, no animation key.
        do {
            let s = Stage(size: CGSize(width: 1440, height: 900), scale: 1, engine: env.engine, backdrop: .darkPage)
            s.controller.theme = Scenes.theme(env)
            s.controller.present(Scenes.request(env, mode: .newTab))
            OffscreenRenderer.settle(s.root) // layout and display, no time passes
            let keysAfterPresent = s.controller.view.debugAnimationKeys
            let first = OffscreenRenderer().snapshot(s.root, scale: 1, presentation: true)
            s.settle()
            let later = s.render(scale: 1)
            let panel = s.controller.view.panelFrame
            let probes = [CGPoint(x: panel.minX + 300, y: panel.minY + 8), CGPoint(x: panel.minX + 30, y: panel.minY + 30),
                          CGPoint(x: panel.midX, y: panel.minY + CommandBarMetrics.listTop + 25)]
            let diff = probes.map { p in zip(pixel(first, p), pixel(later, p)).map { abs($0 - $1) }.max() ?? 255 }.max() ?? 255
            check("Present: the panel is fully drawn in the first frame, no animation key (CC-44)",
                  !s.controller.view.isHidden && keysAfterPresent.isEmpty && diff <= 2,
                  "animation keys \(keysAfterPresent), first-vs-later max channel difference \(diff)")
            s.controller.dismiss(reason: .escape)
            let hiddenAtOnce = s.controller.view.isHidden
            let keysAfterDismiss = s.controller.view.debugAnimationKeys
            OffscreenRenderer.settle(s.root)
            let gone = OffscreenRenderer().snapshot(s.root, scale: 1, presentation: true)
            let page = CommandBarBackdrop.darkPage.color
            let expected = [Int((page.red * 255).rounded()), Int((page.green * 255).rounded()), Int((page.blue * 255).rounded())]
            let leftover = probes.map { p in zip(pixel(gone, p), expected).map { abs($0 - $1) }.max() ?? 255 }.max() ?? 255
            check("Dismiss: the panel and its shadow are gone in the next frame, no animation key (CC-44)",
                  hiddenAtOnce && keysAfterDismiss.isEmpty && leftover <= 2,
                  "hidden \(hiddenAtOnce), animation keys \(keysAfterDismiss), page difference \(leftover)")
        }

        // 88. (i) shows the footer: (i) hides, the field grows 42 pt, the list's visible part ends at the band.
        // Empty Cmd+T, as in S2 18/0044 (typed hosts show a Site Search hint instead of (i)).
        do {
            let s = fresh()
            let panelBefore = s.controller.view.panelFrame
            let fieldBefore = s.controller.view.debugFieldFrame
            let rows = s.controller.rows.count
            let info = CGPoint(x: panelBefore.maxX - CommandBarMetrics.infoButtonTrailing - 13, y: panelBefore.minY + CommandBarMetrics.infoButtonY + 13)
            s.mouse(.leftMouseDown, at: info); s.mouse(.leftMouseUp, at: info); s.settle()
            let panel = s.controller.view.panelFrame
            let field = s.controller.view.debugFieldFrame
            let image = s.render(scale: 1)
            let band = pixel(image, CGPoint(x: panel.minX + 300, y: panel.maxY - 4))
            let aboveBand = pixel(image, CGPoint(x: panel.minX + 300, y: panel.maxY - CommandBarMetrics.footerHeight - 6))
            let bandTopInList = panel.height - CommandBarMetrics.footerHeight - CommandBarMetrics.listTop
            check("Click (i): footer shows, (i) hides, field +42 pt, panel frame unchanged (CC-42)",
                  rows >= 5 && s.controller.showsPrivacyFooter && !s.controller.view.debugPress("info") && field.width - fieldBefore.width == 42 && panel == panelBefore,
                  "rows \(rows), footer \(s.controller.showsPrivacyFooter), field \(fieldBefore.width) → \(field.width), panel \(panelBefore.height) → \(panel.height)")
            check("Footer band is black and the list's visible part ends at the band (5 rows → 4)",
                  band == [0, 0, 0] && aboveBand != [0, 0, 0] && s.controller.view.debugVisibleListHeight == bandTopInList,
                  "band \(band), above \(aboveBand), visible list \(s.controller.view.debugVisibleListHeight) (band top \(bandTopInList))")
            let selectedBefore = s.controller.selectedIndex
            let behindBand = CGPoint(x: panel.midX - 200, y: panel.maxY - 20)
            s.mouse(.mouseMoved, at: behindBand)
            check("The pointer over the band never selects the row behind it", s.controller.selectedIndex == selectedBefore && !s.controller.userMovedSelection,
                  "selected \(String(describing: selectedBefore)) → \(String(describing: s.controller.selectedIndex))")
            for _ in 0..<4 { s.key(.down) }
            let row5Top = CGFloat(4) * CommandBarMetrics.rowHeight - s.controller.view.debugListScrollOffset
            check("Down to row 5 scrolls it out from behind the band", s.controller.selectedIndex == 4 && row5Top + CommandBarMetrics.rowHeight <= bandTopInList + 1,
                  "row 5 top in the list \(row5Top), band top \(bandTopInList)")
            s.key(.info, flags: .command)
            check("Cmd+I hides the footer again; no intent, the bar stays open", !s.controller.showsPrivacyFooter && s.controller.isPresented && s.recorder.intents.isEmpty
                  && s.controller.view.debugFieldFrame.width == fieldBefore.width,
                  "footer \(s.controller.showsPrivacyFooter), intents \(s.recorder.intents)")
            // A Site Search chip with no query has no rows: the input row only (S2 18/0016).
            let e = fresh()
            e.type("youtube"); e.settle()
            e.key(.tab); e.settle()
            let shortBefore = e.controller.view.panelFrame.height
            e.key(.info, flags: .command)
            let shortAfter = e.controller.view.panelFrame.height
            let shortImage = e.render(scale: 1)
            let p = e.controller.view.panelFrame
            let inputRowFill = pixel(shortImage, CGPoint(x: p.minX + 300, y: p.minY + 8)), bandFill = pixel(shortImage, CGPoint(x: p.minX + 300, y: p.maxY - 4))
            check("A panel without rows grows by the band, which never covers the input row (guess)",
                  e.controller.rows.isEmpty && e.controller.showsPrivacyFooter && shortBefore == CommandBarMetrics.emptyListHeight
                  && shortAfter == shortBefore + CommandBarMetrics.footerHeight && inputRowFill != [0, 0, 0] && bandFill == [0, 0, 0],
                  "rows \(e.controller.rows.count), panel \(shortBefore) → \(shortAfter), input row \(inputRowFill), band \(bandFill)")
        }

        // 89. "Dismiss": the footer hides, the App hears it, the query re-runs and remote rows arrive.
        do {
            let remoteEngine = SuggestEngine(model: env.world.model, history: env.history, fetcher: SlowFetcher())
            let s = fresh(engine: remoteEngine, remote: false)
            s.recorder.allowsRemoteAfterDismissal = true
            var queries: [String] = []
            s.controller.onQueryStarted = { queries.append($0) }
            s.type("git"); s.settle()
            let remoteBefore = s.controller.suggestions.contains { $0.kind == .searchSuggestion }
            s.key(.info, flags: .command)
            let queriesBefore = queries.count
            let pressed = s.controller.view.debugPress("dismiss")
            spin(until: { queries.count == queriesBefore + 1 && s.controller.isSnapshotFinal && s.controller.appliedQuery == "git" })
            s.settle()
            let remoteAfter = s.controller.suggestions.contains { $0.kind == .searchSuggestion }
            check("Footer \"Dismiss\": footer hides, the delegate hears it, the current query re-runs with remote rows",
                  pressed && !s.controller.showsPrivacyFooter && s.recorder.noticeDismissals == 1 && queries.count == queriesBefore + 1 && queries.last == "git"
                  && !remoteBefore && remoteAfter && s.controller.isPresented && s.recorder.intents.isEmpty,
                  "dismissals \(s.recorder.noticeDismissals), queries \(queries), remote rows before \(remoteBefore) after \(remoteAfter)")
            var unasked: [String] = []
            for mode in CommandBarMode.allCases {
                let m = fresh(mode)
                let atOpen = m.controller.showsPrivacyFooter
                m.key(.info, flags: .command)
                let opened = m.controller.showsPrivacyFooter
                // Present while open (Cmd+L during Cmd+T), then close and reopen.
                m.controller.present(Scenes.request(env, mode: mode)); m.settle()
                let whileOpen = m.controller.showsPrivacyFooter
                m.key(.info, flags: .command)
                m.controller.dismiss(reason: .programmatic)
                m.controller.present(Scenes.request(env, mode: mode)); m.settle()
                if atOpen || !opened || whileOpen || m.controller.showsPrivacyFooter { unasked.append(mode.rawValue) }
            }
            check("Present in every mode shows no footer: fresh, while open, and after a close (D14)", unasked.isEmpty, "modes with a wrong footer state: \(unasked)")
        }

        // 90. "Search Settings…" and "here".
        do {
            let s = fresh()
            s.key(.info, flags: .command)
            let panel = s.controller.view.panelFrame
            let m = CommandBarMetrics.self
            let settings = CGPoint(x: panel.maxX - m.footerDismissTrailing - m.footerDismissButtonWidth - m.footerButtonGap - m.footerSettingsButtonWidth / 2,
                                   y: panel.maxY - m.footerHeight + m.footerButtonTop + m.footerButtonHeight / 2)
            s.mouse(.leftMouseDown, at: settings); s.mouse(.leftMouseUp, at: settings); s.settle()
            let profile = env.world.profile.id
            check("Click \"Search Settings…\" → .openSearchSettings(Profile), the bar closes",
                  s.recorder.intents == [.openSearchSettings(profileID: profile)] && !s.controller.isPresented,
                  "intents \(s.recorder.intents)")
            let h = fresh()
            h.key(.info, flags: .command)
            let hiddenLink = !h.controller.view.debugPress("privacyLink")
            let url = URL(string: "https://open.example/privacy")!
            h.controller.privacyURL = url
            let pressed = h.controller.view.debugPress("privacyLink")
            check("\"here\" is hidden without a privacy page; with one it opens it in a new tab",
                  hiddenLink && pressed && h.recorder.intents == [.open(url, .newTab, [])] && !h.controller.isPresented,
                  "hidden without URL \(hiddenLink), intents \(h.recorder.intents)")
        }
        return checks
    }
}
