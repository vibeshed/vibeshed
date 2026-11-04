import AppKit
import Foundation

/// Web links that belong to a desktop app, and the app's own link for each, so a link can
/// open in the app instead of a browser tab: a Slack channel in Slack, a meeting in Zoom.
/// `urlRouting.openInApps` picks the apps clicked links go to; meeting links from the
/// calendar go to any of them that's installed.
///
/// Each rewrite keeps to the formats the app documents, or that are in wide use where it
/// doesn't (Notion, Discord, Apple's media apps). One that can't place a link returns nil
/// and the link opens in the browser as before.
enum DeepLinkCatalog {
    struct App: Sendable {
        /// The name config uses for it (`urlRouting.openInApps`).
        let id: String
        let name: String
        /// The hosts it claims: a host as is, or with a leading dot that host and every
        /// subdomain of it.
        let hosts: [String]
        let rewrite: @Sendable (URL) -> URL?

        func claims(host: String) -> Bool {
            hosts.contains { claimed in
                guard claimed.hasPrefix(".") else { return host == claimed }
                return host.hasSuffix(claimed) || host == claimed.dropFirst()
            }
        }
    }

    struct Link: Equatable, Sendable {
        let appID: String
        let appName: String
        let url: URL
    }

    /// The app's link for `url` from the catalog app that claims its host, whether or not
    /// the app is installed. `among` limits the apps to those names.
    static func link(for url: URL, among appIDs: Set<String>? = nil) -> Link? {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host?.lowercased()
        else { return nil }
        for app in apps where appIDs?.contains(app.id) ?? true && app.claims(host: host) {
            if let rewritten = app.rewrite(url) {
                return Link(appID: app.id, appName: app.name, url: rewritten)
            }
        }
        return nil
    }

    /// The same, only when an app on this Mac opens the rewritten link.
    static func installedLink(
        for url: URL,
        among appIDs: Set<String>? = nil,
        canOpen: (URL) -> Bool = hasHandler
    ) -> Link? {
        link(for: url, among: appIDs).flatMap { canOpen($0.url) ? $0 : nil }
    }

    static func hasHandler(_ url: URL) -> Bool {
        NSWorkspace.shared.urlForApplication(toOpen: url) != nil
    }

    static var appIDs: [String] {
        apps.map(\.id)
    }

    static let apps: [App] = [
        App(id: "zoom", name: "Zoom", hosts: [".zoom.us"], rewrite: zoom),
        App(id: "slack", name: "Slack", hosts: ["app.slack.com"], rewrite: slack),
        App(id: "teams", name: "Microsoft Teams", hosts: ["teams.microsoft.com"], rewrite: teams),
        App(id: "linear", name: "Linear", hosts: ["linear.app"], rewrite: linear),
        App(id: "notion", name: "Notion", hosts: ["www.notion.so", "notion.so"], rewrite: notion),
        App(
            id: "discord", name: "Discord",
            hosts: ["discord.com", "ptb.discord.com", "canary.discord.com"], rewrite: discord
        ),
        App(id: "telegram", name: "Telegram", hosts: ["t.me", "telegram.me"], rewrite: telegram),
        App(id: "whatsapp", name: "WhatsApp", hosts: ["wa.me", "api.whatsapp.com"], rewrite: whatsapp),
        App(id: "spotify", name: "Spotify", hosts: ["open.spotify.com"], rewrite: spotify),
        App(id: "music", name: "Music", hosts: ["music.apple.com"]) { mirror($0, scheme: "music") },
        App(id: "podcasts", name: "Podcasts", hosts: ["podcasts.apple.com"]) { mirror($0, scheme: "podcasts") },
        App(id: "appStore", name: "App Store", hosts: ["apps.apple.com"]) { mirror($0, scheme: "macappstore") },
        App(id: "maps", name: "Maps", hosts: ["maps.apple.com"], rewrite: maps),
        App(id: "steam", name: "Steam", hosts: ["store.steampowered.com", "steamcommunity.com"], rewrite: steam),
    ]
}

// MARK: - Rewrites

private extension DeepLinkCatalog {
    /// The path's parts without the leading `/`.
    static func parts(_ url: URL) -> [String] {
        url.pathComponents.filter { $0 != "/" }
    }

    static func make(_ string: String, query: [URLQueryItem]) -> URL? {
        guard var components = URLComponents(string: string) else { return nil }
        let items = query.filter { $0.value?.isEmpty == false }
        components.queryItems = items.isEmpty ? nil : items
        return components.url
    }

    /// The same link under another scheme: `https://music.apple.com/…` → `music://music.apple.com/…`.
    static func mirror(_ url: URL, scheme: String) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = scheme
        return components.url
    }

    /// `prefix` followed by the link's path and query as they are, still percent-encoded.
    static func path(of url: URL, after prefix: String) -> URL? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let query = components.percentEncodedQuery.map { "?\($0)" } ?? ""
        return URL(string: prefix + components.percentEncodedPath + query)
    }

    static func queryValue(_ name: String, in url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }

    /// `https://us06web.zoom.us/j/123?pwd=x` → `zoommtg://zoom.us/join?confno=123&pwd=x`.
    static func zoom(_ url: URL) -> URL? {
        guard parts(url).contains("j"), let meeting = ZoomManager.parseMeetingInput(url.absoluteString) else {
            return nil
        }
        return ZoomManager.joinURL(meetingId: meeting.meetingId, password: meeting.password)
    }

    /// `https://app.slack.com/client/T123/C456` → `slack://channel?team=T123&id=C456`, and the
    /// workspace alone → `slack://open?team=T123`. Slack's documented links have no form for
    /// a thread or a view (Unreads, Activity), so those stay in the browser.
    static func slack(_ url: URL) -> URL? {
        let parts = parts(url)
        guard parts.count == 2 || parts.count == 3, parts[0] == "client", isSlackID(parts[1], kinds: "TE")
        else { return nil }
        let team = URLQueryItem(name: "team", value: parts[1])
        guard parts.count == 3 else { return make("slack://open", query: [team]) }
        // A channel, a direct message or a private group.
        guard isSlackID(parts[2], kinds: "CDG") else { return nil }
        return make("slack://channel", query: [team, URLQueryItem(name: "id", value: parts[2])])
    }

    /// Slack IDs are a kind letter and uppercase letters and digits: T0123, C0456.
    static func isSlackID(_ part: String, kinds: String) -> Bool {
        guard let kind = part.first, kinds.contains(kind), part.count > 1 else { return false }
        return part.allSatisfy { ($0.isUppercase && $0.isASCII) || $0.isNumber }
    }

    /// `https://teams.microsoft.com/l/…` → `msteams:/l/…`, the desktop form of Teams' deep links.
    static func teams(_ url: URL) -> URL? {
        guard parts(url).first == "l" else { return nil }
        return path(of: url, after: "msteams:")
    }

    /// Workspace pages only (`https://linear.app/acme/issue/ENG-1/…` → `linear://acme/issue/ENG-1/…`),
    /// not the marketing site under the same host.
    static func linear(_ url: URL) -> URL? {
        let parts = parts(url)
        guard parts.count >= 2, linearSections.contains(parts[1]) else { return nil }
        return path(of: url, after: "linear:/")
    }

    static let linearSections: Set = [
        "issue", "project", "projects", "view", "views", "team", "initiative", "initiatives",
        "document", "cycle", "inbox", "my-issues", "settings", "customers", "roadmap",
    ]

    /// `https://www.notion.so/acme/Page-1a2b…` → `notion://www.notion.so/acme/Page-1a2b…`, leaving
    /// out Notion's own pages on the same host.
    static func notion(_ url: URL) -> URL? {
        guard let first = parts(url).first, !notionSitePages.contains(first.lowercased()) else { return nil }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.scheme = "notion"
        components?.host = "www.notion.so"
        return components?.url
    }

    static let notionSitePages: Set = [
        "login", "signup", "pricing", "product", "help", "guides", "templates", "desktop", "mobile",
        "about", "careers", "blog", "enterprise", "security", "terms", "privacy",
    ]

    /// `https://discord.com/channels/<server or @me>/<channel>[/<message>]` →
    /// `discord://discord.com/channels/…`.
    static func discord(_ url: URL) -> URL? {
        let parts = parts(url)
        guard parts.count >= 2, parts[0] == "channels" else { return nil }
        return path(of: url, after: "discord://discord.com")
    }

    /// t.me links in Telegram's documented `tg://` forms (core.telegram.org/api/links): a
    /// username, with a bot's start options or a post in it; a private channel's post; an
    /// invite. Each form carries over the options its `tg://` form takes, under the same
    /// names. Anything else, such as a sticker set (`t.me/addstickers/…`), a named mini app or
    /// an option the form doesn't take, stays in the browser.
    static func telegram(_ url: URL) -> URL? {
        var parts = parts(url)
        // t.me/s/<channel> is the channel's web preview.
        if parts.first == "s" {
            parts.removeFirst()
        }
        let options = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let first = parts.first else { return nil }
        switch (first, parts.count) {
        case ("c", 3) where parts.dropFirst().allSatisfy(isNumber):
            let post = [("channel", parts[1]), ("post", parts[2])]
            return telegramLink("privatepost", post, options, telegramPostOptions)
        case ("joinchat", 2):
            return telegramLink("join", [("invite", parts[1])], options, [])
        case (_, 1) where first.hasPrefix("+") && first.count > 1:
            return telegramLink("join", [("invite", String(first.dropFirst()))], options, [])
        case (_, 1) where isTelegramUsername(first):
            return telegramLink("resolve", [("domain", first)], options, telegramChatOptions)
        case (_, 2) where isTelegramUsername(first) && isNumber(parts[1]):
            return telegramLink("resolve", [("domain", first), ("post", parts[1])], options, telegramPostOptions)
        default:
            return nil
        }
    }

    /// `tg://<action>?…` with `fixed` first, then the link's own `options` as they are,
    /// valueless ones included (`single`); nil if one isn't in `allowed`.
    static func telegramLink(
        _ action: String, _ fixed: [(String, String)], _ options: [URLQueryItem], _ allowed: Set<String>
    ) -> URL? {
        guard options.allSatisfy({ allowed.contains($0.name) }) else { return nil }
        var components = URLComponents()
        components.scheme = "tg"
        components.host = action
        components.queryItems = fixed.map { URLQueryItem(name: $0.0, value: $0.1) } + options
        return components.url
    }

    static func isNumber(_ part: String) -> Bool {
        !part.isEmpty && part.allSatisfy(\.isNumber)
    }

    /// 4–32 letters, digits and underscores, starting with a letter, and not one of the t.me
    /// paths Telegram keeps for other links.
    static func isTelegramUsername(_ part: String) -> Bool {
        guard (4 ... 32).contains(part.count), let head = part.first, head.isLetter, head.isASCII,
              part.allSatisfy({ ($0.isLetter || $0.isNumber) && $0.isASCII || $0 == "_" })
        else { return false }
        return !telegramReservedPaths.contains(part.lowercased())
    }

    static let telegramReservedPaths: Set = [
        "addstickers", "addemoji", "addtheme", "addlist", "setlanguage", "share", "msg", "proxy", "socks",
        "login", "invoice", "boost", "contact", "confirmphone", "giftcode", "joinchat", "iv", "nft",
    ]

    /// What `tg://resolve` takes for a user, group, channel or bot.
    static let telegramChatOptions: Set = [
        "start", "startgroup", "startchannel", "admin", "game", "startapp", "voicechat", "videochat", "livestream",
    ]

    /// What `tg://resolve` and `tg://privatepost` take with a post.
    static let telegramPostOptions: Set = ["single", "thread", "comment", "t"]

    /// `https://wa.me/15551234567?text=hi` (or api.whatsapp.com/send?phone=…) →
    /// `whatsapp://send?phone=15551234567&text=hi`.
    static func whatsapp(_ url: URL) -> URL? {
        let parts = parts(url)
        let phone = url.host?.lowercased() == "wa.me" ? parts.first : queryValue("phone", in: url)
        guard let phone, !phone.isEmpty, phone.allSatisfy({ $0.isNumber || $0 == "+" }) else { return nil }
        return make("whatsapp://send", query: [
            URLQueryItem(name: "phone", value: phone), URLQueryItem(name: "text", value: queryValue("text", in: url)),
        ])
    }

    /// `https://open.spotify.com/[intl-xx/]album/<id>` → `spotify:album:<id>`.
    static func spotify(_ url: URL) -> URL? {
        var parts = parts(url)
        if parts.first?.hasPrefix("intl-") == true {
            parts.removeFirst()
        }
        guard parts.count >= 2, spotifyTypes.contains(parts[0]) else { return nil }
        return URL(string: "spotify:\(parts[0]):\(parts[1])")
    }

    static let spotifyTypes: Set = ["track", "album", "artist", "playlist", "show", "episode"]

    /// `https://maps.apple.com/?q=…` → `maps://?q=…`, the same parameters (Apple's Map Links).
    static func maps(_ url: URL) -> URL? {
        guard parts(url).isEmpty, let query = url.query else { return nil }
        return URL(string: "maps://?\(query)")
    }

    /// A store page → `steam://store/<id>`; any other page opens in Steam's own browser
    /// through `steam://openurl/`.
    static func steam(_ url: URL) -> URL? {
        let parts = parts(url)
        if url.host?.lowercased() == "store.steampowered.com", parts.count >= 2, parts[0] == "app",
           parts[1].allSatisfy(\.isNumber)
        {
            return URL(string: "steam://store/\(parts[1])")
        }
        return URL(string: "steam://openurl/\(url.absoluteString)")
    }
}
