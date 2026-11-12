import Foundation

/// Popular sites with display names (Arc parity FA TD-1/TD-2: Arc ships `TopDomains.json` and
/// `popularDomains.json`). Open's own curated list in rough popularity order, written for Open; Arc's
/// files are not used. Typed prefixes complete inline to the domain and list the site first (capture PB1-i).
public enum TopDomains {
    public struct Site: Sendable, Hashable {
        public let domain: String
        public let name: String
    }

    public static let sites: [Site] = list.map { Site(domain: $0.0, name: $0.1) }

    /// The display name for a host ("www.youtube.com" → "YouTube"), or nil.
    public static func name(forHost host: String) -> String? {
        var h = host.lowercased()
        if h.hasPrefix("www.") { h.removeFirst(4) }
        return byDomain[h]
    }

    private static let byDomain: [String: String] = Dictionary(list.map { ($0.0, $0.1) }, uniquingKeysWith: { a, _ in a })

    private static let list: [(String, String)] = [
        ("google.com", "Google"), ("youtube.com", "YouTube"), ("facebook.com", "Facebook"), ("instagram.com", "Instagram"),
        ("wikipedia.org", "Wikipedia"), ("x.com", "X"), ("twitter.com", "Twitter"), ("reddit.com", "Reddit"),
        ("amazon.com", "Amazon"), ("amazon.co.uk", "Amazon.co.uk"), ("amazon.es", "Amazon.es"),
        ("amazonaws.com", "Amazon Web Services (AWS)"), ("amazon.ca", "Amazon.ca"), ("whatsapp.com", "WhatsApp"), ("linkedin.com", "LinkedIn"), ("chatgpt.com", "ChatGPT"),
        ("netflix.com", "Netflix"), ("bing.com", "Bing"), ("yahoo.com", "Yahoo"), ("tiktok.com", "TikTok"),
        ("microsoft.com", "Microsoft"), ("live.com", "Outlook"), ("office.com", "Microsoft 365"), ("apple.com", "Apple"),
        ("icloud.com", "iCloud"), ("github.com", "GitHub"), ("gmail.com", "Gmail"), ("mail.google.com", "Gmail"),
        ("drive.google.com", "Google Drive"), ("docs.google.com", "Google Docs"), ("calendar.google.com", "Google Calendar"),
        ("maps.google.com", "Google Maps"), ("meet.google.com", "Google Meet"), ("translate.google.com", "Google Translate"),
        ("pinterest.com", "Pinterest"), ("twitch.tv", "Twitch"), ("discord.com", "Discord"), ("spotify.com", "Spotify"),
        ("open.spotify.com", "Spotify"), ("ebay.com", "eBay"), ("paypal.com", "PayPal"), ("dropbox.com", "Dropbox"),
        ("zoom.us", "Zoom"), ("slack.com", "Slack"), ("notion.so", "Notion"), ("notion.com", "Notion"),
        ("figma.com", "Figma"), ("canva.com", "Canva"), ("medium.com", "Medium"), ("quora.com", "Quora"),
        ("stackoverflow.com", "Stack Overflow"), ("imdb.com", "IMDb"), ("nytimes.com", "The New York Times"),
        ("cnn.com", "CNN"), ("bbc.com", "BBC"), ("bbc.co.uk", "BBC"), ("theguardian.com", "The Guardian"),
        ("washingtonpost.com", "The Washington Post"), ("wsj.com", "The Wall Street Journal"), ("bloomberg.com", "Bloomberg"),
        ("reuters.com", "Reuters"), ("espn.com", "ESPN"), ("weather.com", "The Weather Channel"), ("craigslist.org", "Craigslist"),
        ("etsy.com", "Etsy"), ("walmart.com", "Walmart"), ("target.com", "Target"), ("bestbuy.com", "Best Buy"),
        ("airbnb.com", "Airbnb"), ("booking.com", "Booking.com"), ("tripadvisor.com", "Tripadvisor"), ("expedia.com", "Expedia"),
        ("uber.com", "Uber"), ("doordash.com", "DoorDash"), ("yelp.com", "Yelp"), ("zillow.com", "Zillow"),
        ("hulu.com", "Hulu"), ("disneyplus.com", "Disney+"), ("max.com", "Max"), ("primevideo.com", "Prime Video"),
        ("vimeo.com", "Vimeo"), ("soundcloud.com", "SoundCloud"), ("tumblr.com", "Tumblr"), ("wordpress.com", "WordPress.com"),
        ("wordpress.org", "WordPress"), ("blogger.com", "Blogger"), ("substack.com", "Substack"), ("producthunt.com", "Product Hunt"),
        ("news.ycombinator.com", "Hacker News"), ("gitlab.com", "GitLab"), ("bitbucket.org", "Bitbucket"), ("npmjs.com", "npm"),
        ("developer.apple.com", "Apple Developer"), ("developer.mozilla.org", "MDN Web Docs"), ("vercel.com", "Vercel"),
        ("netlify.com", "Netlify"), ("cloudflare.com", "Cloudflare"), ("aws.amazon.com", "AWS"), ("azure.microsoft.com", "Azure"),
        ("linear.app", "Linear"), ("atlassian.com", "Atlassian"), ("trello.com", "Trello"), ("asana.com", "Asana"),
        ("monday.com", "monday.com"), ("airtable.com", "Airtable"), ("miro.com", "Miro"), ("loom.com", "Loom"),
        ("calendly.com", "Calendly"), ("mailchimp.com", "Mailchimp"), ("hubspot.com", "HubSpot"), ("salesforce.com", "Salesforce"),
        ("shopify.com", "Shopify"), ("stripe.com", "Stripe"), ("squarespace.com", "Squarespace"), ("wix.com", "Wix"),
        ("duckduckgo.com", "DuckDuckGo"), ("ecosia.org", "Ecosia"), ("perplexity.ai", "Perplexity"), ("claude.ai", "Claude"),
        ("gemini.google.com", "Gemini"), ("openai.com", "OpenAI"), ("anthropic.com", "Anthropic"), ("huggingface.co", "Hugging Face"),
        ("coursera.org", "Coursera"), ("udemy.com", "Udemy"), ("khanacademy.org", "Khan Academy"), ("duolingo.com", "Duolingo"),
        ("archive.org", "Internet Archive"), ("goodreads.com", "Goodreads"), ("letterboxd.com", "Letterboxd"),
        ("steampowered.com", "Steam"), ("epicgames.com", "Epic Games"), ("roblox.com", "Roblox"), ("chess.com", "Chess.com"),
        ("lichess.org", "Lichess"), ("nba.com", "NBA"), ("nfl.com", "NFL"), ("fifa.com", "FIFA"),
        ("telegram.org", "Telegram"), ("web.telegram.org", "Telegram"), ("signal.org", "Signal"), ("messenger.com", "Messenger"),
        ("threads.net", "Threads"), ("bsky.app", "Bluesky"), ("mastodon.social", "Mastodon"), ("snapchat.com", "Snapchat"),
        ("proton.me", "Proton"), ("fastmail.com", "Fastmail"), ("outlook.com", "Outlook"), ("1password.com", "1Password"),
        ("bitwarden.com", "Bitwarden"), ("wise.com", "Wise"), ("chase.com", "Chase"), ("bankofamerica.com", "Bank of America"),
        ("wellsfargo.com", "Wells Fargo"), ("capitalone.com", "Capital One"), ("coinbase.com", "Coinbase"), ("robinhood.com", "Robinhood"),
        ("fidelity.com", "Fidelity"), ("vanguard.com", "Vanguard"), ("costco.com", "Costco"), ("homedepot.com", "The Home Depot"),
        ("ikea.com", "IKEA"), ("nike.com", "Nike"), ("aliexpress.com", "AliExpress"), ("temu.com", "Temu"),
    ]
}

/// Popular sites whose domain starts with the typed text ("netfl" → Netflix — netflix.com). Capture
/// PB1-i (C-report-s6 §8, also on a Profile with no history): Arc completes the field inline to the
/// domain and lists "Name — domain" first, then further matching domains. The first row may be the top
/// hit and complete inline (`InlineCompletion.canComplete`); history and tabs still rank above it.
public struct TopDomainsProvider: SuggestProvider {
    public let id = "topDomains"
    public var maxRows = 5
    public init() {}

    public func localSuggestions(for input: SuggestInput) -> [Suggestion] {
        guard !input.context.mode.isScoped, input.siteSearch == nil, case .text = input.typed else { return [] }
        var typed = input.rawText.lowercased()
        for lead in ["https://", "http://", "www."] where typed.hasPrefix(lead) { typed.removeFirst(lead.count) }
        guard typed.count >= 2, !typed.contains(where: { $0.isWhitespace || $0 == "/" }) else { return [] }
        var rows: [Suggestion] = []
        for site in TopDomains.sites where site.domain.hasPrefix(typed) && site.domain != typed {
            guard let url = URL(string: "https://" + site.domain) else { continue }
            var row = Suggestion(id: "topDomain:" + site.domain, kind: .navigate, title: site.name, subtitle: site.domain,
                                 url: url, provider: id,
                                 scoreDetail: ScoreDetail(quality: MatchQuality.prefix, weight: 0.85))
            // List order: a falling boost keeps the list's popularity order through ranking.
            row.scoreDetail.boost = Double(maxRows - rows.count) * 0.01
            row.score = row.scoreDetail.total
            row.canBeTopHit = rows.isEmpty
            rows.append(row)
            if rows.count == maxRows { break }
        }
        return rows
    }
}
