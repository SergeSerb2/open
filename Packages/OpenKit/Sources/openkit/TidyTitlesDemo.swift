import Foundation
import OpenModel
import OpenStore

@MainActor
func runTidyTitlesDemo(check: (Bool, String) -> Void) {
    let fixtures: [(String, String, String)] = [
        ("https://mail.google.com/mail/#inbox", "Inbox (3) - person@example.invalid - Gmail", "Inbox"),
        ("https://mail.google.com/mail/#starred", "Raw Gmail", "Starred"),
        ("https://mail.google.com/mail/#sent", "Raw Gmail", "Sent"),
        ("https://mail.google.com/mail/#drafts", "Raw Gmail", "Drafts"),
        ("https://mail.google.com/mail/#inbox/message", "Inbox (3) - person@example.invalid - Gmail", "Inbox (3)"),
        ("https://docs.google.com/document/d/synthetic", "Plan - Google Docs", "Plan"),
        ("https://docs.google.com/spreadsheets/d/synthetic", "Budget - Google Sheets", "Budget"),
        ("https://docs.google.com/presentation/d/synthetic", "Slides - Google Slides", "Slides"),
        ("https://docs.google.com/forms/d/synthetic", "Survey - Google Forms", "Survey"),
        ("https://drive.google.com/drive/my-drive", "My Drive - Google Drive", "My Drive"),
        ("https://calendar.google.com/calendar/", "Google Calendar - Week", "Week"),
        ("https://www.youtube.com/watch?v=synthetic", "(12) A video - YouTube", "A video"),
        ("https://youtube.com/", "Home - YouTube", "Home"),
        ("https://github.com/example/project", "Project · GitHub", "Project"),
        ("https://x.com/home", "(3) Home / X", "Home"),
        ("https://twitter.com/home", "(8) Home / X", "Home"),
        ("https://www.linkedin.com/feed/", "(42) Feed | LinkedIn", "Feed"),
        ("https://en.wikipedia.org/wiki/Swift", "Swift - Wikipedia", "Swift"),
        ("https://stackoverflow.com/questions/1", "A question - Stack Overflow", "A question"),
        ("https://www.figma.com/design/synthetic", "Design – Figma", "Design"),
        ("https://app.slack.com/client/synthetic", "General - Slack", "General"),
        ("https://outlook.live.com/mail/", "Inbox - Outlook", "Inbox"),
        ("https://outlook.office.com/mail/", "Inbox - Outlook", "Inbox"),
        ("https://www.amazon.com/dp/synthetic", "Amazon.com: A book", "A book"),
        ("https://amazon.com/", "Amazon.com : Search", "Search"),
        ("https://www.github.com/example", "Example · GitHub", "Example"),
        ("https://github.com/", "README 🦊 · GitHub", "README 🦊"),
        ("https://x.com/", "(2) News 🗞 / X", "News 🗞"),
        ("https://mail.google.com/mail/#search/example", "Search - person@example.invalid - Gmail", "Search"),
        ("https://github.com/", " · GitHub", " · GitHub"),
        ("https://example.invalid/", "Title - YouTube", "Title - YouTube"),
        ("https://gist.github.com/", "Snippet · GitHub", "Snippet · GitHub"),
        ("https://evilgithub.com/", "Project · GitHub", "Project · GitHub"),
        ("https://mail.google.com.example.invalid/#inbox", "Untouched", "Untouched"),
        ("https://de.wikipedia.org/wiki/Swift", "Swift - Wikipedia", "Swift - Wikipedia"),
        ("https://docs.google.com/", "A Docs title", "A Docs title"),
        ("https://github.com/", "GitHub · Project", "GitHub · Project"),
        ("https://www.amazon.com/", "An ordinary title", "An ordinary title"),
        ("https://mail.google.com/#Inbox", "Case-sensitive fragment", "Case-sensitive fragment"),
        ("file:///tmp/synthetic", "Local file", "Local file"),
        ("https://en.wikipedia.org/wiki/Example", "مرحبا بالعالم - Wikipedia", "مرحبا بالعالم"),
        ("https://youtube.com/watch?v=example", "(١٢) مثال - YouTube", "مثال")
    ]
    let profile = Profile(name: "Tidy Titles")
    let space = Space(title: "Tidy Titles", profileID: profile.id)
    let model = BrowserModel(profiles: [profile], spaces: [space])
    var matches = 0
    for (url, title, expected) in fixtures {
        let tab = model.newTab(in: space.id, url: URL(string: url)!, title: title)
        if tab.displayTitle == expected && tab.title == title { matches += 1 }
    }
    check(fixtures.count == 42 && matches == 42, "T1 42 Open-written title/URL fixtures through Tab.displayTitle (\(matches)/42)")
    let custom = model.newTab(in: space.id, url: URL(string: "https://mail.google.com/#inbox")!, title: "Raw")
    model.renameNode(id: custom.id, title: "My custom title")
    check(custom.displayTitle == "My custom title" && TidyTitles.tidy(title: "", url: URL(string: "https://github.com")!) == "",
          "T2 custom titles win; empty-result and no-match fixtures preserve raw titles")
    let restored = SnapshotMapper.model(from: SnapshotMapper.dto(from: model))
    check(SnapshotMapper.structurallyEqual(model, restored) && restored.tab(id: custom.id)?.displayTitle == "My custom title",
          "T2 snapshot roundtrip stores raw title and customization")
    func p95(_ samples: [UInt64]) -> Double { Double(samples.sorted()[Int(Double(samples.count - 1) * 0.95)]) / 1000 }
    let cachedURL = URL(string: "https://github.com/example/cached")!
    _ = TidyTitles.tidy(title: "Cached · GitHub", url: cachedURL)
    var hits: [UInt64] = [], misses: [UInt64] = [], length = 0
    hits.reserveCapacity(10_000); misses.reserveCapacity(1_000)
    for _ in 0..<10_000 {
        let start = DispatchTime.now().uptimeNanoseconds
        let result = TidyTitles.tidy(title: "Cached · GitHub", url: cachedURL)
        hits.append(DispatchTime.now().uptimeNanoseconds - start); length += result.utf8.count
    }
    for index in 0..<1_000 {
        let title = "Miss \(index) · GitHub"
        let start = DispatchTime.now().uptimeNanoseconds
        let result = TidyTitles.tidy(title: title, url: cachedURL)
        misses.append(DispatchTime.now().uptimeNanoseconds - start); length += result.utf8.count
    }
    let hitP95 = p95(hits), missP95 = p95(misses)
    check(hitP95 <= 5 && missP95 <= 50 && length > 0,
          String(format: "T3 tidy title p95 cached %.3f µs (≤5), miss %.3f µs (≤50)", hitP95, missP95))
}
