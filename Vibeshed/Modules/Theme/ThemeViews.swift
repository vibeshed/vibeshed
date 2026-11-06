import SwiftUI

/// Preview-panel content for a theme: a miniature editor + terminal drawn in the
/// theme's own colors on its wallpaper, and the terminal palette.
struct ThemePreviewView: View {
    let theme: ResolvedTheme
    var wallpaper: ThemeWallpaperPreview?

    private var palette: ThemePalette { theme.palette }

    var body: some View {
        PreviewLayout(moduleName: "theme") {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: theme.icon)
                        .foregroundStyle(palette.accent.color)
                    Text(theme.name)
                        .font(.title3)
                        .fontWeight(.medium)
                }
                Text(ThemeModule.describe(theme))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let style = theme.macStyle.summary {
                    Label(style, systemImage: "macbook")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            DesktopPreview(palette: palette, wallpaper: wallpaper)

            VStack(alignment: .leading, spacing: 6) {
                sectionLabel("Terminal")
                ANSIGrid(colors: palette.ansi)
            }
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }
}

/// The code-window mockup sitting on the wallpaper the theme would set, like a desktop.
struct DesktopPreview: View {
    let palette: ThemePalette
    let wallpaper: ThemeWallpaperPreview?

    var body: some View {
        if let wallpaper {
            ThemeMockup(palette: palette)
                .shadow(color: .black.opacity(0.35), radius: 6, y: 3)
                .padding(16)
                .background { WallpaperThumbnail(palette: palette, wallpaper: wallpaper) }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else {
            ThemeMockup(palette: palette)
        }
    }
}

/// A wallpaper rendered small, off the main thread.
struct WallpaperThumbnail: View {
    let palette: ThemePalette
    let wallpaper: ThemeWallpaperPreview
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            palette.darkerBackground.color
            if let image {
                Image(decorative: image, scale: 2)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            }
        }
        .task(id: wallpaper) {
            let palette = palette
            let wallpaper = wallpaper
            let rendered = await Task.detached(priority: .userInitiated) {
                Self.render(palette, wallpaper)
            }.value
            withAnimation(.easeOut(duration: 0.2)) { image = rendered }
        }
    }

    private nonisolated static func render(_ palette: ThemePalette, _ wallpaper: ThemeWallpaperPreview) -> CGImage? {
        switch wallpaper {
        case let .generated(choice):
            return WallpaperRenderer.draw(palette, size: CGSize(width: 720, height: 450), choice: choice)
        case let .image(path):
            // A dynamic desktop shows the picture for the appearance the theme sets.
            let url = URL(fileURLWithPath: path)
            return DynamicDesktop.thumbnail(of: url, dark: palette.mode == .dark, maxPixelSize: 720)?.image
        }
    }
}

/// Preview-panel content for a wallpaper style, drawn with the current theme.
struct WallpaperStylePreview: View {
    let theme: ResolvedTheme
    let style: WallpaperStyle
    let choice: WallpaperChoice

    var body: some View {
        PreviewLayout(moduleName: "theme") {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: style.icon)
                        .foregroundStyle(theme.palette.accent.color)
                    Text(style.displayName)
                        .font(.title3)
                        .fontWeight(.medium)
                }
                Text(style.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            WallpaperThumbnail(palette: theme.palette, wallpaper: .generated(choice))
                .aspectRatio(16 / 10, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text("Generated from \(theme.name). Shuffle Wallpaper gives a new variation.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// A tiny code window: title bar, gutter, a few syntax-colored lines and a terminal prompt.
private struct ThemeMockup: View {
    let palette: ThemePalette

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                ForEach([palette.red, palette.yellow, palette.green], id: \.self) { color in
                    Circle().fill(color.color).frame(width: 7, height: 7)
                }
                Spacer()
                Capsule()
                    .fill(palette.accent.color)
                    .frame(width: 34, height: 6)
            }
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(palette.darkBackground.color)

            VStack(alignment: .leading, spacing: 3) {
                codeLine(1, [("func ", palette.magenta), ("greet", palette.blue), ("(name: ", palette.foreground),
                             ("String", palette.yellow), (") {", palette.foreground)])
                codeLine(2, [("    // say hello", palette.muted)], highlighted: true)
                codeLine(3, [("    print(", palette.foreground), ("\"Hi, \\(name)\"", palette.green),
                             (", ", palette.foreground), ("42", palette.orange), (")", palette.foreground)])
                codeLine(4, [("}", palette.foreground)])
            }
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.background.color)

            HStack(spacing: 0) {
                Text("~/vibeshed ").foregroundStyle(palette.cyan.color)
                Text("main ").foregroundStyle(palette.magenta.color)
                Text("❯ ").foregroundStyle(palette.green.color)
                Rectangle().fill(palette.cursor.color).frame(width: 6, height: 11)
            }
            .font(.system(size: 10, design: .monospaced))
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
            .background(palette.darkBackground.color)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(palette.accent.color.opacity(0.5), lineWidth: 1)
        )
    }

    private func codeLine(_ number: Int, _ segments: [(String, ThemeColor)], highlighted: Bool = false) -> some View {
        HStack(spacing: 8) {
            Text("\(number)")
                .foregroundStyle((highlighted ? palette.foreground : palette.muted).color)
                .frame(width: 12, alignment: .trailing)
            segments.reduce(Text("")) { text, segment in
                text + Text(segment.0).foregroundColor(segment.1.color)
            }
        }
        .font(.system(size: 10, design: .monospaced))
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(highlighted ? palette.selectionBackground.color.opacity(0.6) : .clear)
    }
}

/// The 16 terminal colors as two rows (normal / bright).
private struct ANSIGrid: View {
    let colors: [ThemeColor]

    var body: some View {
        VStack(spacing: 3) {
            ForEach(0 ..< 2, id: \.self) { row in
                HStack(spacing: 3) {
                    ForEach(0 ..< 8, id: \.self) { column in
                        let index = row * 8 + column
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(index < colors.count ? colors[index].color : .clear)
                            .frame(height: 14)
                            .overlay(
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
                            )
                    }
                }
            }
        }
    }
}
