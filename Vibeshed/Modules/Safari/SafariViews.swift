import SwiftUI

/// The page a Safari row or option opens: where it's from, its address, and when it
/// was last seen. No favicon, which would mean sending the host somewhere to fetch one.
struct SafariPagePreview: View {
    let page: SafariPage
    let safariPath: String?

    var body: some View {
        PreviewLayout(moduleName: "safari") {
            PreviewHeader(title: page.title, subtitle: page.site) {
                hero
            }

            Divider()

            Text(page.url)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(3)
                .textSelection(.enabled)

            details
        }
    }

    @ViewBuilder
    private var hero: some View {
        if case let .cloudTab(tab) = page {
            Image(systemName: tab.device.symbolName)
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
                .frame(width: 56, height: 56)
        } else if let safariPath {
            Image(nsImage: NSWorkspace.shared.icon(forFile: safariPath))
                .resizable()
                .frame(width: 56, height: 56)
        }
    }

    @ViewBuilder
    private var details: some View {
        switch page {
        case let .history(entry):
            PreviewMetadataRow(icon: "clock", label: "Last visited", value: Self.relative(entry.lastVisited))
            PreviewMetadataRow(icon: "chart.bar", label: "Visits", value: "\(entry.visitCount)")
        case let .favorite(favorite):
            PreviewMetadataRow(
                icon: "star",
                label: "Folder",
                value: (["Favorites"] + favorite.folders).joined(separator: " › ")
            )
        case let .cloudTab(tab):
            PreviewMetadataRow(icon: tab.device.symbolName, label: "Open on", value: tab.device.name)
            if let viewed = tab.lastViewed {
                PreviewMetadataRow(icon: "clock", label: "Last viewed", value: Self.relative(viewed))
            }
            if tab.isPinned {
                PreviewMetadataRow(icon: "pin", label: "Pinned", value: "Yes")
            }
        }
    }

    static func relative(_ date: Date) -> String {
        min(date, Date()).formatted(Date.RelativeFormatStyle(presentation: .named))
    }
}
