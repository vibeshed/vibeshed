import Foundation
import SQLite3
import SystemConfiguration

/// A device signed in to the same iCloud account with Safari's tabs syncing.
struct SafariDevice: Sendable, Equatable, Hashable {
    enum Kind: Sendable {
        case phone, pad, laptop, desktop, vision, other
    }

    let id: String
    let name: String
    /// Such as "com.apple.iphone-13-mini-2" or "com.apple.macbookpro-14-2021-silver".
    let typeIdentifier: String?

    var kind: Kind {
        let type = typeIdentifier?.lowercased() ?? ""
        if type.hasPrefix("com.apple.iphone") { return .phone }
        if type.hasPrefix("com.apple.ipad") { return .pad }
        if type.hasPrefix("com.apple.macbook") { return .laptop }
        if type.hasPrefix("com.apple.mac") || type.hasPrefix("com.apple.imac") { return .desktop }
        if type.contains("vision") || type.contains("reality") { return .vision }
        return .other
    }

    var symbolName: String {
        switch kind {
        case .phone: "iphone"
        case .pad: "ipad"
        case .laptop: "laptopcomputer"
        case .desktop: "desktopcomputer"
        case .vision: "visionpro"
        case .other: "macbook.and.iphone"
        }
    }
}

/// A tab open in Safari on another device.
struct SafariCloudTab: Sendable, Equatable {
    let title: String
    let url: String
    let device: SafariDevice
    let lastViewed: Date?
    let isPinned: Bool

    var displayTitle: String {
        title.isEmpty ? SafariURL.display(url) : title
    }
}

enum SafariCloudTabsReader {
    static let sql = """
    SELECT d.device_uuid, d.device_name, d.device_type_identifier, t.title, t.url, t.is_pinned, t.last_viewed_time
    FROM cloud_tabs t JOIN cloud_tab_devices d ON d.device_uuid = t.device_uuid
    ORDER BY t.last_viewed_time DESC
    """

    /// For a CloudTabs.db from before `last_viewed_time`, in the order the tabs synced.
    static let sqlWithoutViewTimes = """
    SELECT d.device_uuid, d.device_name, d.device_type_identifier, t.title, t.url, t.is_pinned, NULL
    FROM cloud_tabs t JOIN cloud_tab_devices d ON d.device_uuid = t.device_uuid
    ORDER BY t.rowid
    """

    /// Tabs open on other devices, most recently viewed first. CloudTabs.db lists this
    /// Mac's own tabs too, under its computer name; those are left out, as Safari's
    /// iCloud Tabs do. No CloudTabs.db (iCloud Tabs off) is no tabs.
    static func read(at path: String, thisMac: String? = currentComputerName()) throws -> [SafariCloudTab] {
        guard FileManager.default.fileExists(atPath: path) else { return [] }
        let tabs: [SafariCloudTab]
        do {
            tabs = try SafariDatabase.rows(path, sql: sql, map: tab)
        } catch {
            guard let legacy = try? SafariDatabase.rows(path, sql: sqlWithoutViewTimes, map: tab) else { throw error }
            tabs = legacy
        }
        // A page open on two devices is one row, on the one that viewed it last.
        var seen: Set<String> = []
        return tabs.filter { $0.device.name != thisMac && seen.insert($0.url).inserted }
    }

    private static func tab(_ stmt: OpaquePointer) -> SafariCloudTab? {
        guard let deviceID = SafariDatabase.text(stmt, 0), let url = SafariDatabase.text(stmt, 4),
              SafariURL.isListable(url)
        else { return nil }
        let device = SafariDevice(
            id: deviceID,
            name: SafariDatabase.text(stmt, 1) ?? "Another device",
            typeIdentifier: SafariDatabase.text(stmt, 2)
        )
        return SafariCloudTab(
            title: (SafariDatabase.text(stmt, 3) ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            url: url,
            device: device,
            lastViewed: SafariDatabase.date(stmt, 6),
            isPinned: sqlite3_column_int(stmt, 5) != 0
        )
    }

    /// The name in Sharing settings, which is what Safari syncs as this Mac's device name.
    static func currentComputerName() -> String? {
        SCDynamicStoreCopyComputerName(nil, nil) as String?
    }
}
