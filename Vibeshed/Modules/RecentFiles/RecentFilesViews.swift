import SwiftUI
import UniformTypeIdentifiers

/// A type's Finder icon. From the type alone: `icon(forFile:)` would read the file,
/// and reading one in Desktop, Documents or Downloads raises a privacy prompt.
struct FileTypeIcon: View {
    let type: UTType

    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(for: type))
            .resizable()
            .aspectRatio(contentMode: .fit)
    }
}

struct RecentFileListItemView: View {
    let file: RecentFile

    var body: some View {
        HStack(spacing: 12) {
            FileTypeIcon(type: file.type)
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(file.name)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(file.folder)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }

            Spacer()
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

/// What a row or option opens: where it is, what it is and when it was last opened.
/// Nothing read from the file itself, not even a thumbnail.
struct RecentFilePreview: View {
    let file: RecentFile
    /// The app that opens it by default.
    let appPath: String?

    var body: some View {
        PreviewLayout(moduleName: "recentFiles") {
            PreviewHeader(title: file.name, subtitle: file.folder) {
                FileTypeIcon(type: file.type)
                    .frame(width: 64, height: 64)
            }

            Divider()

            Text((file.path as NSString).abbreviatingWithTildeInPath)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(3)
                .textSelection(.enabled)

            PreviewMetadataRow(icon: "clock", label: "Last opened", value: Self.relative(file.lastUsed))
            if let kind = file.type.localizedDescription {
                PreviewMetadataRow(icon: "doc", label: "Kind", value: kind)
            }
            if let size = file.size, size > 0 {
                PreviewMetadataRow(
                    icon: "internaldrive",
                    label: "Size",
                    value: ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
                )
            }
            if let appPath {
                PreviewMetadataRow(icon: "arrow.up.forward.app", label: "Opens with", value: Self.appName(appPath))
            }
        }
    }

    /// "Preview", even where Finder shows every extension ("Preview.app").
    nonisolated static func appName(_ path: String) -> String {
        let name = FileManager.default.displayName(atPath: path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    nonisolated static func relative(_ date: Date) -> String {
        min(date, Date()).formatted(Date.RelativeFormatStyle(presentation: .named))
    }
}
