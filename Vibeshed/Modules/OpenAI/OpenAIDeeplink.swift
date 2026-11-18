import Foundation

/// `codex://` deeplinks handled by the Codex desktop app, which ships as `ChatGPT.app`
/// and registers the `codex` scheme under the `com.openai.codex` bundle id.
enum OpenAIDeeplink {
    static let bundleID = "com.openai.codex"

    static var isInstalled: Bool {
        AILaunch.isAppInstalled(bundleID: bundleID)
    }

    /// Opens one thread by id. A thread on another machine (an SSH host) also needs that
    /// host's id, which the app reads from `hostId` as its own links do (26.1111).
    static func thread(_ id: String, hostID: String? = nil) -> String {
        var components = URLComponents()
        components.scheme = "codex"
        components.host = "threads"
        components.path = "/\(id)"
        if let hostID {
            components.queryItems = [URLQueryItem(name: "hostId", value: hostID)]
        }
        return components.string ?? "codex://threads/\(id)"
    }

    /// Opens the app's connections settings, where MCP servers and integrations live.
    static let connectionSettings = "codex://settings/connections"
}
