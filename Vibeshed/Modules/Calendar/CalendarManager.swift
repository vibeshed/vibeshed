import AppKit
import EventKit
import Foundation

/// Isolates the shared `EKEventStore`. It is not `Sendable` and is reached from
/// two module actors (`CalendarModule`, `MeetingPrepModule`), so every member
/// that touches it is pinned to this actor rather than to either caller.
@globalActor
actor CalendarStoreActor {
    static let shared = CalendarStoreActor()
}

enum CalendarManager {
    // MARK: - Permission

    static var hasAccess: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    @CalendarStoreActor
    static func requestAccess() async -> Bool {
        do {
            return try await store.requestFullAccessToEvents()
        } catch {
            return false
        }
    }

    static func openCalendarPrivacySettings() {
        if let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"
        ) {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Event Store

    @CalendarStoreActor
    private static let store = EKEventStore()

    // MARK: - Data Types

    struct CalendarEvent: Sendable {
        let eventIdentifier: String
        let title: String
        let startDate: Date
        let endDate: Date
        let isAllDay: Bool
        let calendarTitle: String
        let calendarColorHex: String
        let location: String?
        let url: URL?
        let notes: String?
        let attendeeNames: [String]
        let status: EventStatus
    }

    enum EventStatus: Sendable {
        case confirmed
        case tentative
        case declined
        case none
    }

    struct EventQuery: Sendable {
        var lookaheadHours: Int
        var lookbehindMinutes: Int
        var excludedCalendars: [String]?
        var includedCalendars: [String]?
        var showAllDay = false
        var showDeclined = false
    }

    // MARK: - Fetch Events

    @CalendarStoreActor
    static func fetchEvents(_ query: EventQuery) -> [CalendarEvent] {
        let now = Date()
        let startDate = now.addingTimeInterval(
            -Double(query.lookbehindMinutes) * 60
        )
        let endDate = now.addingTimeInterval(
            Double(query.lookaheadHours) * 3600
        )

        let calendars = resolveCalendars(
            excluded: query.excludedCalendars,
            included: query.includedCalendars
        )

        let predicate = store.predicateForEvents(
            withStart: startDate,
            end: endDate,
            calendars: calendars
        )

        let ekEvents = store.events(matching: predicate)

        return ekEvents.compactMap { event in
            if event.isAllDay, !query.showAllDay { return nil }

            let status = mapStatus(event)
            if status == .declined, !query.showDeclined { return nil }

            let attendees = (event.attendees ?? [])
                .filter { !$0.isCurrentUser }
                .compactMap(\.name)

            return CalendarEvent(
                eventIdentifier: event.eventIdentifier,
                title: event.title ?? "Untitled Event",
                startDate: event.startDate,
                endDate: event.endDate,
                isAllDay: event.isAllDay,
                calendarTitle: event.calendar.title,
                calendarColorHex: hexColor(from: event.calendar.cgColor),
                location: event.location,
                url: event.url,
                notes: truncateNotes(event.notes),
                attendeeNames: attendees,
                status: status
            )
        }
        .sorted { $0.startDate < $1.startDate }
    }

    // MARK: - Video Link Detection

    static func detectVideoLink(
        url: URL?,
        location: String?,
        notes: String?
    ) -> (type: VideoLinkType, url: URL)? {
        let fields = [
            url?.absoluteString,
            location,
            notes,
        ].compactMap { $0 }

        for field in fields {
            if let match = matchURL(pattern: zoomPattern, in: field) {
                return (.zoom, match)
            }
            if let match = matchURL(pattern: meetPattern, in: field) {
                return (.googleMeet, match)
            }
            if let match = matchURL(pattern: teamsPattern, in: field) {
                return (.teams, match)
            }
        }
        return nil
    }

    // swiftlint:disable force_try
    private static let zoomPattern = try! NSRegularExpression(
        pattern: #"https?://[^\s]*zoom\.us/j/\d+[^\s]*"#
    )
    private static let meetPattern = try! NSRegularExpression(
        pattern: #"https?://meet\.google\.com/[a-z]+-[a-z]+-[a-z]+"#
    )
    private static let teamsPattern = try! NSRegularExpression(
        pattern: #"https?://teams\.microsoft\.com/l/meetup-join/[^\s]+"#
    )
    // swiftlint:enable force_try

    private static func matchURL(
        pattern: NSRegularExpression,
        in text: String
    ) -> URL? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = pattern.firstMatch(in: text, range: range),
              let matchRange = Range(match.range, in: text)
        else {
            return nil
        }
        return URL(string: String(text[matchRange]))
    }

    // MARK: - Open Helpers

    static func openEvent(_ eventIdentifier: String) {
        let calendarBundleID = "com.apple.iCal"
        if let app = NSRunningApplication
            .runningApplications(withBundleIdentifier: calendarBundleID)
            .first
        {
            app.activate()
        } else if let url = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: calendarBundleID
        ) {
            NSWorkspace.shared.openApplication(
                at: url,
                configuration: .init()
            )
        }
    }

    /// Joins in the meeting's app (Zoom, Teams, …) when it's installed, rather than
    /// through a browser tab; otherwise opens the link as is.
    static func openVideoLink(_ url: URL) {
        NSWorkspace.shared.open(DeepLinkCatalog.installedLink(for: url)?.url ?? url)
    }

    static func openCalendarApp() {
        let calendarBundleID = "com.apple.iCal"
        if let app = NSRunningApplication
            .runningApplications(withBundleIdentifier: calendarBundleID)
            .first
        {
            app.activate()
        } else if let url = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: calendarBundleID
        ) {
            NSWorkspace.shared.openApplication(
                at: url,
                configuration: .init()
            )
        }
    }

    // MARK: - Stable ID

    static func stableID(_ input: String) -> String {
        StableID.hash(input)
    }

    // MARK: - Private Helpers

    @CalendarStoreActor
    private static func resolveCalendars(
        excluded: [String]?,
        included: [String]?
    ) -> [EKCalendar]? {
        let allCalendars = store.calendars(for: .event)

        if let included, !included.isEmpty {
            let lowered = Set(included.map { $0.lowercased() })
            let filtered = allCalendars.filter {
                lowered.contains($0.title.lowercased())
            }
            return filtered.isEmpty ? nil : filtered
        }

        if let excluded, !excluded.isEmpty {
            let lowered = Set(excluded.map { $0.lowercased() })
            let filtered = allCalendars.filter {
                !lowered.contains($0.title.lowercased())
            }
            return filtered.isEmpty ? nil : filtered
        }

        return nil
    }

    private static func mapStatus(_ event: EKEvent) -> EventStatus {
        guard let attendees = event.attendees else { return .none }
        guard let me = attendees.first(where: { $0.isCurrentUser }) else {
            return .none
        }
        switch me.participantStatus {
        case .accepted: return .confirmed
        case .tentative: return .tentative
        case .declined: return .declined
        default: return .none
        }
    }

    private static func hexColor(from cgColor: CGColor) -> String {
        guard let rgb = cgColor.converted(
            to: CGColorSpaceCreateDeviceRGB(),
            intent: .defaultIntent,
            options: nil
        ),
            let components = rgb.components,
            components.count >= 3
        else {
            return "#808080"
        }
        let red = Int(components[0] * 255)
        let green = Int(components[1] * 255)
        let blue = Int(components[2] * 255)
        return String(format: "#%02X%02X%02X", red, green, blue)
    }

    private static func truncateNotes(_ notes: String?) -> String? {
        guard let notes, !notes.isEmpty else { return nil }
        if notes.count > 2000 {
            return String(notes.prefix(2000))
        }
        return notes
    }
}
