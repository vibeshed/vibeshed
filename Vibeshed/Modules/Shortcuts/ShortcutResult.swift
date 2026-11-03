import Foundation

/// One thing a search shortcut found: a row of its results.
struct ShortcutResult: Sendable, Equatable {
    let title: String
    var subtitle: String?
    /// Opened when the row is picked.
    var url: URL?
    /// Copied when the row is picked and there's no `url`; the title when nil.
    var text: String?
    /// An SF Symbol name for the row.
    var icon: String?
}

/// What a search shortcut outputs, read into rows. It may output:
///
/// - a list of dictionaries with `title` and, each optional, `subtitle`, `url`, `text`
///   and `icon` (`name` and `link` work for `title` and `url`), or a dictionary with
///   such a list under `items`;
/// - a list of text, or text with one result per line. A line that's a link opens it.
///
/// The command-line tool hands over a list item by item, a dictionary as its JSON.
enum ShortcutResultParser {
    static func results(_ items: [Data]) -> [ShortcutResult] {
        items.flatMap(results)
    }

    static func results(_ data: Data) -> [ShortcutResult] {
        let text = (String(bytes: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        if text.first == "[" || text.first == "{",
           let json = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed)
        {
            return results(json)
        }
        // A list of dictionaries can come out as one JSON object per line.
        return text.split(whereSeparator: \.isNewline).flatMap { line -> [ShortcutResult] in
            let line = line.trimmingCharacters(in: .whitespaces)
            if line.first == "{", let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) {
                return results(json)
            }
            return result(line: line).map { [$0] } ?? []
        }
    }

    private static func results(_ json: Any) -> [ShortcutResult] {
        switch json {
        case let list as [Any]:
            list.flatMap(results)
        case let dictionary as [String: Any]:
            if let items = dictionary["items"] as? [Any] {
                items.flatMap(results)
            } else {
                result(dictionary).map { [$0] } ?? []
            }
        case let string as String:
            result(line: string).map { [$0] } ?? []
        case let number as NSNumber:
            [ShortcutResult(title: number.stringValue)]
        default:
            []
        }
    }

    private static func result(_ dictionary: [String: Any]) -> ShortcutResult? {
        func string(_ keys: String...) -> String? {
            keys.lazy.compactMap { (dictionary[$0] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
        }
        let url = string("url", "link").flatMap(link)
        guard let title = string("title", "name") ?? url?.absoluteString else { return nil }
        return ShortcutResult(
            title: title, subtitle: string("subtitle"), url: url, text: string("text"), icon: string("icon")
        )
    }

    private static func result(line: String) -> ShortcutResult? {
        let line = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }
        return ShortcutResult(title: line, url: link(line))
    }

    /// `text` as a link when it's one whole, with no spaces: `https://…`, `notes://…`, or
    /// one of the schemes written without slashes (`message:%3C…%3E`, `mailto:…`). Text
    /// like `Agenda:draft` stays text.
    static func link(_ text: String) -> URL? {
        guard !text.contains(where: \.isWhitespace), let url = URL(string: text),
              let scheme = url.scheme?.lowercased(), scheme.count > 1,
              text.lowercased().hasPrefix(scheme + "://") || slashlessSchemes.contains(scheme)
        else { return nil }
        return url
    }

    private static let slashlessSchemes: Set = [
        "mailto", "message", "tel", "sms", "facetime", "facetime-audio", "spotify", "msteams", "maps",
    ]
}
