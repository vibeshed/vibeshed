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
    /// workspace alone → `slack://open?team=T123`. Slack's documented links.
    static func slack(_ url: URL) -> URL? {
        let parts = parts(url)
        guard parts.count >= 2, parts[0] == "client" else { return nil }
        let team = URLQueryItem(name: "team", value: parts[1])
        guard parts.count >= 3 else { return make("slack://open", query: [team]) }
        return make("slack://channel", query: [team, URLQueryItem(name: "id", value: parts[2])])
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

    /// t.me links in Telegram's documented `tg://` forms: a username (and a post in it), a
    /// private channel's post, an invite.
    static func telegram(_ url: URL) -> URL? {
        var parts = parts(url)
        if parts.first == "s" {
            parts.removeFirst()
        }
        guard let first = parts.first else { return nil }
        if first == "c", parts.count >= 3 {
            return make("tg://privatepost", query: [
                URLQueryItem(name: "channel", value: parts[1]), URLQueryItem(name: "post", value: parts[2]),
            ])
        }
        if first == "joinchat", parts.count >= 2 {
            return make("tg://join", query: [URLQueryItem(name: "invite", value: parts[1])])
        }
        if first.hasPrefix("+"), first.count > 1 {
            return make("tg://join", query: [URLQueryItem(name: "invite", value: String(first.dropFirst()))])
        }
        guard first.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return nil }
        var query = [URLQueryItem(name: "domain", value: first)]
        if parts.count >= 2, parts[1].allSatisfy(\.isNumber) {
            query.append(URLQueryItem(name: "post", value: parts[1]))
        }
        return make("tg://resolve", query: query)
    }

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
