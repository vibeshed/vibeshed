import SwiftUI

struct AIActionListItemView: View {
    let action: AIAction

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: action.iconName ?? "brain")
                .font(.title3)
                .foregroundStyle(accentColor)
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(action.title)
                    .font(.body)
                    .lineLimit(1)

                if !action.subtitle.isEmpty {
                    Text(action.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            HStack(spacing: 4) {
                if action.isAwaitingUser {
                    Text("WAITING")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.orange)
                }
                if let source = action.source {
                    Text(source.shortLabel)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if let timestamp = action.sessionTimestamp {
                    Text(relativeTime(timestamp))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private var accentColor: Color {
        color(for: action.source?.accent)
    }
}

struct AIActionPreviewView: View {
    let action: AIAction

    var body: some View {
        PreviewLayout(moduleName: action.moduleName) {
            PreviewHeader(
                title: action.title,
                subtitle: action.subtitle,
                systemIcon: action.iconName ?? "brain",
                iconColor: accentColor
            )

            if let source = action.source {
                PreviewPill(
                    text: source.fullLabel,
                    icon: source.iconName,
                    color: accentColor
                )
            }

            if let waitingFor = action.waitingFor {
                PreviewPill(
                    text: "Waiting for you: \(waitingFor)",
                    icon: "bell.badge",
                    color: .orange
                )
            }

            if let path = action.projectPath {
                PreviewMetadataRow(
                    icon: "folder",
                    label: "Project",
                    value: abbreviatePath(path)
                )
            }

            if let branch = action.branch {
                PreviewMetadataRow(
                    icon: "arrow.triangle.branch",
                    label: "Branch",
                    value: branch
                )
            }

            if let model = action.modelName {
                PreviewMetadataRow(
                    icon: "cpu",
                    label: "Model",
                    value: model
                )
            }

            if let timestamp = action.sessionTimestamp {
                PreviewMetadataRow(
                    icon: "clock",
                    label: "Session",
                    value: formatDate(timestamp)
                )
            }
        }
    }

    private var accentColor: Color {
        color(for: action.source?.accent)
    }
}

// MARK: - Helpers

private func color(for accent: AIAccent?) -> Color {
    switch accent {
    case .orange: .orange
    case .purple: .purple
    case .green: .green
    case .teal: .teal
    case .neutral, nil: .secondary
    }
}

private func relativeTime(_ date: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter.localizedString(for: date, relativeTo: Date())
}

private func formatDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter.string(from: date)
}
