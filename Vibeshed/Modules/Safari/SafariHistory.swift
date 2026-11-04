import Foundation
import SQLite3

/// A page in Safari's history.
struct SafariHistoryEntry: Sendable, Equatable {
    let url: String
    /// The latest title Safari saw for it; empty when it never had one.
    let title: String
    let lastVisited: Date
    let visitCount: Int
    /// Safari's own `visit_count_score`, which weighs visits by how recent they are.
    let score: Int

    var displayTitle: String {
        title.isEmpty ? SafariURL.display(url) : title
    }
}

enum SafariHistoryReader {
    /// Every visit, newest first within its page, in the order of Safari's own index on
    /// (history_item, visit_time DESC). Picking each page's latest visit and title out
    /// of this in one pass is far cheaper than asking SQLite per page: a correlated
    /// subquery per page ran for minutes on a 15,000-page history.
    static let visitsSQL = """
    SELECT history_item, visit_time, redirect_destination IS NULL AND load_successful,
           title IS NOT NULL AND title != '', title
    FROM history_visits
    ORDER BY history_item, visit_time DESC
    """

    static let pagesSQL = "SELECT id, url, visit_count, visit_count_score FROM history_items"

    /// Per page: its latest visit that landed, and its latest title.
    private struct Visits {
        var landed: [Int64: Date] = [:]
        var titles: [Int64: String] = [:]
    }

    /// The pages in History.db, most recently visited first. A page with no visit that
    /// landed (only ever a redirect: http → https, a link shortener, a sign-in bounce;
    /// or a load that failed) is left out: where it led has its own entry.
    static func read(at path: String) throws -> [SafariHistoryEntry] {
        // Safari never ran: no history rather than a database that can't be opened.
        guard FileManager.default.fileExists(atPath: path) else { return [] }
        let visits = try SafariDatabase.reduce(path, sql: visitsSQL, into: Visits()) { visits, stmt in
            let page = sqlite3_column_int64(stmt, 0)
            if visits.landed[page] == nil, sqlite3_column_int(stmt, 2) != 0,
               let time = SafariDatabase.date(stmt, 1)
            {
                visits.landed[page] = time
            }
            // Rows are newest first, so the first title seen is the latest; later ones
            // aren't decoded at all.
            if sqlite3_column_int(stmt, 3) != 0, visits.titles[page] == nil {
                visits.titles[page] = SafariDatabase.text(stmt, 4)
            }
        }
        let entries = try SafariDatabase.rows(path, sql: pagesSQL) { stmt -> SafariHistoryEntry? in
            let page = sqlite3_column_int64(stmt, 0)
            guard let landed = visits.landed[page], let url = SafariDatabase.text(stmt, 1),
                  SafariURL.isListable(url)
            else { return nil }
            return SafariHistoryEntry(
                url: url,
                title: (visits.titles[page] ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                lastVisited: landed,
                visitCount: Int(sqlite3_column_int(stmt, 2)),
                score: Int(sqlite3_column_int64(stmt, 3))
            )
        }
        // One page per address the way the picker dedupes them (no fragment, case or
        // trailing slash): the most recent visit stands for the rest.
        var seen: Set<String> = []
        return entries.sorted { $0.lastVisited > $1.lastVisited }
            .filter { seen.insert(ActionScorer.normalizeURL($0.url)).inserted }
    }
}

// MARK: - Search

/// Safari's history, held for searching on every keystroke. Every page's title, host
/// and path sit in one buffer as lowercase UTF-8 words, so a query word is one
/// `memmem` pass over the whole history rather than a few calls per page.
struct SafariHistoryIndex: Sendable {
    enum Mode {
        /// Every query word starts a word of the page (the main search, like `WordPrefixMatch`).
        case wordPrefix
        /// Every query word appears anywhere in the page's title or address (Search Safari History).
        case anywhere
    }

    struct Match: Sendable {
        let entry: SafariHistoryEntry
        /// How well the words matched (title above host above path, word starts above
        /// the middle of words), plus how often and how lately the page was visited.
        let rank: Double
        /// How often and how lately, 0–1.
        let frecency: Double
    }

    private enum Field: Int {
        case title, host, path

        /// A word starting a word of the field, then one inside a word.
        var startQuality: Double {
            [3, 2.5, 2][rawValue]
        }

        var insideQuality: Double {
            [1.5, 1, 1][rawValue]
        }
    }

    static let empty = SafariHistoryIndex(entries: [])

    /// Most recently visited first.
    let entries: [SafariHistoryEntry]
    /// Per page: title words, 0x01, host words, 0x02, path words, 0x00. A needle never
    /// holds those bytes, so a match never runs from one field into the next.
    private let text: [UInt8]
    /// Where each page starts in `text`, plus the end; and where its host and path start.
    private let pageStarts: [Int]
    private let hostStarts: [Int]
    private let pathStarts: [Int]
    private let maxScoreLog: Double

    init(entries: [SafariHistoryEntry]) {
        self.entries = entries
        var text: [UInt8] = []
        text.reserveCapacity(entries.count * 160)
        var pageStarts: [Int] = []
        var hostStarts: [Int] = []
        var pathStarts: [Int] = []
        pageStarts.reserveCapacity(entries.count + 1)
        hostStarts.reserveCapacity(entries.count)
        pathStarts.reserveCapacity(entries.count)
        for entry in entries {
            let (host, path) = SafariURL.split(entry.url)
            pageStarts.append(text.count)
            SearchWords.fold(entry.displayTitle, into: &text)
            text.append(1)
            hostStarts.append(text.count)
            SearchWords.fold(host, into: &text)
            text.append(2)
            pathStarts.append(text.count)
            SearchWords.fold(path, into: &text)
            text.append(0)
        }
        pageStarts.append(text.count)
        self.text = text
        self.pageStarts = pageStarts
        self.hostStarts = hostStarts
        self.pathStarts = pathStarts
        maxScoreLog = log1p(Double(entries.map(\.score).max() ?? 0))
    }

    var count: Int {
        entries.count
    }

    var isEmpty: Bool {
        entries.isEmpty
    }

    /// The page with `StableID.hash(url)` == `hash`, for resolving a row's action ID
    /// (keybindings, aliases, URIs), which is rare enough to hash on the spot.
    func entry(hash: String) -> SafariHistoryEntry? {
        entries.first { StableID.hash($0.url) == hash }
    }

    /// The best `limit` pages for `query`, best first. With nothing typed, the most
    /// recently visited.
    func search(_ query: String, mode: Mode, limit: Int, now: Date = Date()) -> [Match] {
        guard limit > 0 else { return [] }
        let words = SearchWords.queryWords(query)
        guard !words.isEmpty else {
            return entries.prefix(limit).map { Match(entry: $0, rank: 0, frecency: frecency(of: $0, now: now)) }
        }
        // How many query words each page matched so far, and how well. A word only
        // counts for pages that matched every word before it.
        var matched = [Int](repeating: 0, count: entries.count)
        var quality = [Double](repeating: 0, count: entries.count)
        for (position, word) in words.enumerated() {
            scan([SearchWords.space] + word) { page, field in
                guard matched[page] == position else { return }
                matched[page] += 1
                quality[page] += field.startQuality
            }
            guard mode == .anywhere else { continue }
            scan(word) { page, field in
                guard matched[page] == position else { return }
                matched[page] += 1
                quality[page] += field.insideQuality
            }
        }
        // Ranked as bare numbers: sorting the entries themselves would copy their strings.
        var ranked: [(rank: Double, frecency: Double, page: Int)] = []
        for page in entries.indices where matched[page] == words.count {
            let frecency = frecency(of: entries[page], now: now)
            ranked.append((quality[page] / Double(words.count) + 1.5 * frecency, frecency, page))
        }
        ranked.sort { $0.rank > $1.rank }
        return ranked.prefix(limit).map { Match(entry: entries[$0.page], rank: $0.rank, frecency: $0.frecency) }
    }

    /// Calls `found` once for each page whose text holds `needle`, with the field it
    /// first appears in: the best one, as fields are laid out best first.
    private func scan(_ needle: [UInt8], found: (Int, Field) -> Void) {
        text.withUnsafeBytes { haystack in
            needle.withUnsafeBytes { pin in
                guard let base = haystack.baseAddress, let pinBase = pin.baseAddress, !pin.isEmpty else { return }
                var from = 0
                while from < haystack.count,
                      let hit = memmem(base + from, haystack.count - from, pinBase, pin.count)
                {
                    let offset = base.distance(to: UnsafeRawPointer(hit))
                    let page = self.page(containing: offset)
                    let field: Field = offset >= pathStarts[page] ? .path : offset >= hostStarts[page] ? .host : .title
                    found(page, field)
                    from = pageStarts[page + 1]
                }
            }
        }
    }

    /// The page whose bytes include `offset`: the last start at or before it.
    private func page(containing offset: Int) -> Int {
        var low = 0
        var high = pageStarts.count - 1
        while low < high - 1 {
            let middle = (low + high) / 2
            if pageStarts[middle] <= offset {
                low = middle
            } else {
                high = middle
            }
        }
        return low
    }

    /// Half how often (Safari's score against the most visited page, on a log scale),
    /// half how lately (1 today, ½ a week ago, ⅓ two weeks ago).
    private func frecency(of entry: SafariHistoryEntry, now: Date) -> Double {
        let often = maxScoreLog > 0 ? log1p(Double(max(0, entry.score))) / maxScoreLog : 0
        let days = max(0, now.timeIntervalSince(entry.lastVisited)) / 86400
        let lately = 1 / (1 + days / 7)
        return (often + lately) / 2
    }
}

/// Text as lowercase words in UTF-8, each preceded by one space (" make the website"),
/// so " web" finds a word starting with "web" and "web" one containing it.
enum SearchWords {
    static let space = UInt8(ascii: " ")

    static func fold(_ text: some StringProtocol) -> [UInt8] {
        var bytes: [UInt8] = []
        fold(text, into: &bytes)
        return bytes
    }

    /// Appends `text`'s words to `bytes`. ASCII, which nearly every address and most
    /// titles are, needs no case mapping; other text is lowercased first, then composed
    /// (NFC), so canonically equivalent text has the same bytes: a title's "e" + U+0301
    /// matches a typed "é". Composing after lowercasing, which can decompose ("İ").
    static func fold(_ text: some StringProtocol, into bytes: inout [UInt8]) {
        let mark = bytes.count
        if text.utf8.withContiguousStorageIfAvailable({ foldUTF8($0, asciiOnly: true, into: &bytes) }) == true {
            return
        }
        bytes.removeSubrange(mark...)
        var folded = text.lowercased().precomposedStringWithCanonicalMapping
        folded.withUTF8 { _ = foldUTF8($0, asciiOnly: false, into: &bytes) }
    }

    /// Letters and digits make words, other ASCII separates them. Beyond ASCII,
    /// punctuation, symbol and emoji blocks separate and everything else counts as a
    /// letter: close to `Character.isLetter`, without a Unicode property lookup per
    /// character. With `asciiOnly`, stops and returns false at the first non-ASCII byte;
    /// otherwise the text must be lowercase already.
    private static func foldUTF8(
        _ utf8: UnsafeBufferPointer<UInt8>,
        asciiOnly: Bool,
        into bytes: inout [UInt8]
    ) -> Bool {
        var inWord = false
        var index = 0
        while index < utf8.count {
            let byte = utf8[index]
            var length = 1
            let isWord: Bool
            switch byte {
            case 0x30 ... 0x39, 0x41 ... 0x5A, 0x61 ... 0x7A:
                isWord = true
            case 0 ..< 0x80:
                isWord = false
            default:
                guard !asciiOnly else { return false }
                length = byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : 2
                isWord = !isSeparator(scalarValue(utf8, at: index, length: length))
            }
            if isWord {
                if !inWord {
                    bytes.append(space)
                    inWord = true
                }
                if length == 1 {
                    bytes.append(byte >= 0x41 && byte <= 0x5A ? byte + 0x20 : byte)
                } else {
                    let end = min(index + length, utf8.count)
                    bytes.append(contentsOf: UnsafeBufferPointer(rebasing: utf8[index ..< end]))
                }
            } else {
                inWord = false
            }
            index += length
        }
        return true
    }

    private static func scalarValue(_ utf8: UnsafeBufferPointer<UInt8>, at index: Int, length: Int) -> UInt32 {
        guard index + length <= utf8.count else { return 0 }
        let lead = UInt32(utf8[index]) & (0xFF >> (length + 1))
        return (1 ..< length).reduce(lead) { value, offset in value << 6 | UInt32(utf8[index + offset]) & 0x3F }
    }

    /// Non-ASCII that separates words: Latin-1 punctuation and signs, general
    /// punctuation through dingbats and arrows, CJK and full-width punctuation,
    /// variation selectors and emoji.
    private static func isSeparator(_ value: UInt32) -> Bool {
        switch value {
        case 0x80 ... 0xBF, 0xD7, 0xF7, 0x2000 ... 0x2BFF, 0x3000 ... 0x303F, 0xFE00 ... 0xFE0F, 0xFE30 ... 0xFE4F,
             0xFF00 ... 0xFF0F, 0xFF1A ... 0xFF20, 0xFF3B ... 0xFF40, 0xFF5B ... 0xFF65, 0x1F000 ... 0x1FAFF,
             0xE0000 ... 0xE007F:
            true
        default:
            false
        }
    }

    /// The query's words, without the separating spaces.
    static func queryWords(_ query: String) -> [[UInt8]] {
        fold(query).split(separator: space).map(Array.init)
    }
}
