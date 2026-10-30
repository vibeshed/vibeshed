<p align="center">
  <img src="docs/icon.png" alt="Vibeshed icon" width="160" height="160">
</p>

# Vibeshed

A keyboard-driven macOS launcher built with SwiftUI. Control your Mac with keystrokes — manage windows, switch apps, search browser tabs, control Spotify, and more from a single floating picker.

<p align="center">
  <img src="docs/img/readme-hero.gif" alt="Vibeshed's picker finds the Spotify track that's playing and a Claude Code session, previews four themes that repaint Zed, btop and the wallpaper live, then maximizes and restores a window from the keyboard" width="960">
</p>

## Goals

- **Keyboard-first.** Every action reachable in a few keystrokes; mouse optional.
- **Native and unobtrusive.** Pure SwiftUI, menu-bar only, no Dock icon, no Electron.
- **Modular by default.** Each integration is a separate module; load only what you configure.
- **Hackable config.** One YAML file at `~/.config/vibeshed/config.yaml` with hot-reload.
- **Composable actions.** Anything triggerable from the picker is also reachable via `vibeshed://` URLs and key combos.
- **Local-first.** No telemetry. State and history stay on disk.

## Non-goals

- **Not a cross-platform tool.** macOS only. No plans for Linux/Windows.
- **Not a Raycast/Alfred replacement.** No store, no plugin marketplace, no paid tier — modules ship in-tree.
- **Not a scripting platform.** Workflows belong in shell/AppleScript; Vibeshed dispatches, it does not orchestrate.
- **No mobile companion, no cloud sync, no AI chat surface inside the picker.**
- **No GUI configuration.** Config is YAML; if that's a dealbreaker, this is the wrong tool.

## Features

**Launcher**
- Fuzzy-matched searchable picker with keyboard navigation and preview pane
- Hold Shift (⇧Return, ⇧double-click, ⌘⇧1–9) to run an action and keep the picker open, with only the search text cleared — for firing several similar actions in a row, like a batch of cask installs
- Esc steps back one level (from a parameter step or pushed list to where you picked it) and ⌘Esc closes from anywhere; hidden with the toggle hotkey, the picker keeps your place for 10 seconds (`picker.resetAfter`), then opens on a fresh search
- Usage-aware sorting that adapts to how you work
- Context-sensitive action boosting based on focused app, time of day, audio state
- Picker colors follow the applied palette theme, live while you browse themes
- Optional backdrop behind the picker — blur, tint, vignette, grain — with fade, focus-pull and iris animations

**Window Management**
- Cycle window sizes anchored to screen edges, tile halves, maximize/restore
- Enlarge/shrink while keeping split position
- Focus windows by title or app name

**Applications & Browser**
- Launch, focus, or quit any app
- Search and switch browser tabs across Safari and Chromium browsers
- Browser bookmarks and most-visited sites
- Default browser with per-URL routing to specific browsers/profiles

**Productivity**
- Clipboard history with search and paste
- Timers and reminders
- Math expressions, unit conversions, currency conversion
- Calendar events with one-click join for Zoom/Meet
- Meeting prep: hide distractions and surface relevant docs

**Developer Tools**
- VSCode, JetBrains, and Zed project/workspace search
- iTerm session management and command execution
- GitHub repo/issue/PR search and notifications
- AI session search and resume across Claude Code, Claude Desktop, Codex, and OpenCode
- Homebrew package search, install, upgrade, and cleanup

**Media & Communication**
- Wallpaper search across Wallhaven, Unsplash and public-domain museum collections, with previews and credits
- Spotify search that plays songs, albums, artists and playlists, plus playback control (no API setup)
- System audio volume, mute, device selection, media keys
- Telegram chat quick-open
- Zoom meeting join, start, and configured meeting shortcuts

**System**
- Lock, sleep, restart, shutdown, toggle dark mode
- Empty trash, flush DNS, purge memory, screenshots
- App-scoped key remapping (remap keys per-application)
- Global and per-app key combo bindings
- Custom action aliases with keyword search

## Requirements

- **Apple silicon only** (M1 or later). Releases are arm64 builds and won't open on Intel Macs.
- macOS 14 (Sonoma) or later
- Swift 5.9+ (for building from source)

## Installation

Download the latest signed and notarized build from [vibeshed.dev](https://vibeshed.dev) or [Releases](https://github.com/vibeshed/vibeshed/releases/latest), unzip it and drag `Vibeshed.app` to Applications. Or use Homebrew:

```bash
brew install --cask idmitriev/tap/vibeshed
```

To build from source:

```bash
git clone https://github.com/vibeshed/vibeshed.git
cd vibeshed
make build
make run
```

The app runs as a menu bar item (no Dock icon). Use `make run-debug` to see logs in the terminal, or `make log` in a separate terminal for live OSLog streaming.

## Configuration

Configuration lives at `~/.config/vibeshed/config.yaml`. On first launch Vibeshed writes a config there. Caps Lock works as a modifier in it:

| Shortcut | Does |
|----------|------|
| Caps Lock + Space | Toggle the picker |
| Caps Lock + ← → ↑ ↓ | Focus the window on that side |
| Caps Lock + W A S D | Cycle the window's height or width against the top, left, bottom or right edge |
| Caps Lock + M | Maximize / restore the window |
| Caps Lock + P | Pick a window to focus |

Windows and the tiling grid (two side-by-side splits) get 4pt of padding and gaps. The default browser is left alone, and these modules are enabled:

- the ones backed by macOS itself: apps, system actions, settings panes, audio, processes, performance, windows, tiling, clipboard history, themes, math, timers, emoji and web search;
- one for each app it finds on the Mac: browser tabs, Homebrew, Claude, ChatGPT/Codex, OpenCode, VS Code (and Cursor, Windsurf), JetBrains IDEs, Zed, iTerm, Ghostty, Spotify, Telegram, Zoom and GitHub (via the `gh` CLI or GitHub Desktop).

Without Homebrew, it also adds an **Install Homebrew** alias that runs the [brew.sh](https://brew.sh) install script in a new Terminal window, and enables the Terminal module that alias runs in.

Every other module is listed in the file, commented out. A welcome window then walks through the permissions those modules need, one macOS prompt at a time, so each module works the first time you use it. It's under **Set Up Permissions…** in the menu bar afterwards.

See [config.example.yaml](config.example.yaml) for all available options including keybindings, module settings, URL routing rules, and action aliases.

The app watches the config file for changes and hot-reloads automatically.

## Modules

| Module | Description |
|--------|-------------|
| **Window** | Resize, move, tile, cycle, maximize/restore, focus windows, focus border |
| **Tiling** | Per-display grid tiling, auto-tile, directional moves |
| **Application** | Launch, focus, quit applications |
| **Menu** | Search and click the frontmost app's menu bar items |
| **Processes** | List and kill running processes |
| **Performance** | CPU, memory, disk and network activity with history charts; opens Activity Monitor on the matching tab |
| **Browser** | Search/focus/close tabs in Safari and Chromium browsers |
| **Bookmark** | Browser bookmarks and most-visited URLs |
| **Clipboard** | Clipboard history with search, paste, and persistence |
| **Audio** | Volume, mute, device selection, media key control |
| **System** | Lock, sleep, restart, shutdown, appearance, screenshots |
| **Settings** | Open macOS System Settings panes |
| **Spotify** | Search and play songs, albums, artists, playlists; playback control |
| **GitHub** | Search repos, issues, PRs; view notifications |
| **VSCode** | Search and open recent projects |
| **JetBrains** | Search and open IDE projects |
| **ITerm** | Session listing, command execution, new tabs |
| **Ghostty** | Focus open terminals, new windows/tabs, quick commands, config reload (Ghostty 1.3+) |
| **Terminal** | New Terminal.app windows, Run Command, quick commands |
| **Claude** | Resume Claude Code/Desktop sessions, start new ones, jump to sessions awaiting input |
| **Codex** | Resume Codex threads with project/branch/model context, start new sessions |
| **OpenCode** | Resume OpenCode sessions in a terminal with project/model context, start new sessions |
| **Zed** | Search and open recent workspaces |
| **Homebrew** | Search, install, uninstall, upgrade packages and casks |
| **Zoom** | Join meetings, start personal meeting, configured shortcuts |
| **Telegram** | Quick-open configured chats and groups |
| **Calendar** | Upcoming events, join Zoom/Meet links |
| **Notes** | Search Apple Notes by title or text, open them, start new ones |
| **MeetingPrep** | Prepare workspace for meetings |
| **Timer** | Set timers and reminders |
| **Math** | Arithmetic, unit/currency conversion |
| **Web Search** | Search the web when nothing else matches |
| **Emoji** | Search and copy/paste emoji |
| **Theme** | Palette themes and coding fonts applied across macOS and apps, with live preview |
| **Wallpaper** | Search Wallhaven, Unsplash and the Rijksmuseum, Met and Art Institute of Chicago collections, or pick at random; set the result as the wallpaper |
| **Self** | Open config, reload modules, view logs, quit |

Modules load only when their config section is present. A section added while Vibeshed is running loads its module right away; a removed one takes effect at the next launch. Installing an app with the Homebrew module (for example the `spotify` cask or the `gh` formula) adds the section for the module that works with it. Each module declares the permissions it needs (accessibility, automation, etc.) and the apps it scripts; **Set Up Permissions…** in the menu bar walks through granting them.

## Theming

One palette, applied everywhere at once. `theme/switch` lists the themes; moving the highlight applies each one live, Return keeps it, Esc puts everything back. Every theme is also a direct action (`theme/apply.tokyo-night`) you can bind or alias, plus `theme/next`, `theme/previous`, `theme/reapply` and `theme/fromWallpaper`, which derives a full palette from your current wallpaper.

| Target | What changes | Live? |
|--------|--------------|-------|
| `appearance` | Light/dark mode | ✓ |
| `accent` | Accent (nearest preset) + text highlight (exact color) | ✓ |
| `folders` | "Icon, widget & folder color" (macOS 26+), tinted icons for listed folders | ✓ |
| `pointer` | Pointer fill/outline (needs Full Disk Access) | best-effort |
| `wallpaper` | Theme image, or one generated from the palette in one of 45 styles | ✓ |
| `iterm` | Every open session, plus a "Vibeshed" profile (your default profile's settings, theme colours) made the default, so new windows and restarts keep the theme | ✓ |
| `ghostty` | Generated `themes/Vibeshed`, selected with `theme =` in your config; open terminals reload on SIGUSR2 (Ghostty 1.2+) | ✓ |
| `terminal` | Terminal.app: a "Vibeshed" profile (your default profile's settings, theme colours) made the default and startup profile; open tabs get background, text and cursor colours live, ANSI colours when Terminal next launches | partly |
| `vscode` | VS Code, Insiders, Cursor, Windsurf, VSCodium via a generated theme extension | ✓* |
| `zed` | Generated `themes/vibeshed.json`, selected in settings | ✓* |
| `jetbrains` | Generated editor scheme; follows "Sync with OS" | on restart |
| `neovim` | Generated `colors/vibeshed.lua` (UI, syntax, Tree-sitter, LSP, diagnostics, `:terminal`); running Neovims using it reload over their RPC sockets | ✓ |
| `claude` | Claude Code custom theme (`~/.claude/themes`) | ✓ |
| `bat` / `lsd` / `micro` | Generated `Vibeshed.tmTheme` (+ cache rebuild), `colors.yaml`, `vibeshed.micro` | next run |
| `btop` | Generated `vibeshed.theme`, selected in `btop.conf`; running btops reload via SIGUSR2 | ✓ |
| `github` | github.com appearance via an open tab (opt-in) | ✓ |
| `templates` / `hooks` | Your own `{{ key }}` templates and shell commands | ✓ |

\* The very first time the generated theme is installed, the editor may need one reload to discover it; after that, switches apply live.

The picker and the window focus border follow the theme's accent too. Terminal tools that use the 16 ANSI colours (e.g. fzf with `--color=hl:4,…`) need no target at all: they follow the terminal palette (iTerm, Ghostty) live. For bat, select the generated theme once with `--theme=Vibeshed`; for Neovim, with `vim.cmd.colorscheme("vibeshed")` (or LazyVim's `opts = { colorscheme = "vibeshed" }`).

Themes use [Omarchy](https://omarchy.org)'s `colors.toml` key names (`background`, `accent`, `bright_blue`, `color0`…`color15`, …); only background, foreground and the six base hues are required. 73 built-ins: Catppuccin, Tokyo Night, Rosé Pine, Kanagawa, Gruvbox, Everforest, Nord, Solarized, GitHub, Ayu, Nightfox, Flexoki, Melange, One Dark/Light, Dracula, Monokai Pro, Night Owl, Poimandres, Vesper, Moonfly, Sonokai, Iceberg, Vague, plus Omarchy's own (Osaka Jade, Ristretto, Matte Black, Retro 82, Lumon, …) and classic desktops — BeOS, OS/2 Warp, OS/2 Text Mode and NeXTSTEP, with colors taken from the systems themselves, plus System 7, Mac OS 8, Mac OS 9 and the Hi-Tech appearance from Mac OS 8.5's betas (Platinum greys and the Macintosh 16-color palette; the highlight and desktop colors are inspired rather than measured), and Windows 95, Windows XP (Luna), Amiga Workbench 1.3 and 3.1 (every color in the Amiga's 12-bit palette) and QNX Photon (its window manager's default title colors and the QNX 6.2 demo CD's desktop). The community and Omarchy palettes are regenerated from their sources by `scripts/generate-builtin-themes.py`. Define your own in config (optionally `base:` another theme), or drop Omarchy theme folders into `~/.config/vibeshed/themes/`:

```yaml
modules:
  theme:
    themes:
      - name: "Midnight"
        base: "Tokyo Night"
        colors: { background: "#0b0b12", accent: "#ff9e64" }
    templates:   # Omarchy placeholder syntax: {{ accent }}, {{ red_rgb }}, {{ mix background green 15% }}
      - source: "~/.config/vibeshed/templates/kitty.conf.tpl"
        target: "~/.config/kitty/current-theme.conf"
        reload: "pkill -USR1 -x kitty"
```

Generated wallpapers come in 45 styles: glow, mesh gradient, waves, ridges, bokeh, low poly, topographic, retro sunset, retro arcs, halftone and solid; eleven from the generative-art canon — Pulsar (after the Unknown Pleasures cover), Guilloché, Sashiko (hitomezashi stitching), a Clifford attractor, Bauhaus, De Stijl, Truchet tiles, Terrazzo, circle packing, isometric terraces and Penrose tiling; and fifteen from classic systems — Leaves (Haiku's screen saver, the BeOS theme's default), Polyhedra (NeXTSTEP BackSpace's module, which could run as the workspace background), Warp Speed (OS/2 Warp), ASCII Art (a shaded `donut.c` torus, the Mandelbrot set or `aafire` flames, in terminal characters), 10 PRINT (the Commodore 64 one-line maze), Dither (a Bayer-dithered planet), Pipes (the Windows NT screen saver), Pebbles (the classic Mac desktop tile, recolored from the theme's desktop color), Desktop Pattern (one-bit 8×8 tiles), Platinum Pinstripes, Clouds (Windows 95's sky in dithered 15-bit color), Azul (XP's ribbons of light), Windows Pattern (the one-bit patterns of Windows 3.0 and 95), Boing Ball (the Amiga demo, in 12-bit color) and Digital Rain (QNX Photon's screen saver). These last eight are made for their own themes, so they stay out of `auto`, and all but Azul are pixel bitmaps that skip film grain. Eight more are simulations and fields, opt-in by name rather than picked by `auto` (so no theme's automatic wallpaper changed when they arrived): Flow (evenly spaced streamlines around a disc), Lens (stripes and a sun bent around a black hole), Paper Cut (layered paper sheets with soft shadows), Automata (panels of Wolfram's elementary cellular automata), Cyclic (Griffeath's cyclic automaton, noise turning into square spirals), Chladni (sand on a vibrating plate), Complex (a complex function's phase portrait) and Growth (differential growth, folding like brain coral). Any style works with any theme; the classic themes default to their own. `theme/wallpaperStyle` browses them on the current theme with live preview, and `theme/shuffleWallpaper` re-rolls the variation. They're painted at full display resolution in 16-bit colour and dithered, so soft gradients don't band.

The resolved palette is also exported to `~/Library/Application Support/Vibeshed/Theme/current/` (`colors.toml`, `colors.json`) for scripts.

### Fonts

`theme/switchFont` does the same for coding fonts: it lists the installed ones among ~50 popular picks (JetBrains Mono, Fira Code, Cascadia Code, Iosevka, Monaspace, Geist Mono, Berkeley Mono, SF Mono, …), previews each live in your terminals and editors as you move, and opens on the font your apps already use. Every font is also a direct action (`theme/font.jetbrains-mono`). Editors get the font as published; terminals get its Nerd Font single-width variant ("JetBrainsMono Nerd Font Mono") when that's installed, so prompt and `ls` icons keep working, and families cut for terminals where a font has one (Iosevka Term). Fonts you add under `fonts:` are offered too.

| Target | What changes | Live? |
|--------|--------------|-------|
| `iterm` | Font of the "Vibeshed" profile, keeping the weight and size of your default profile's font | ✓ |
| `ghostty` | The first `font-family` in your config (later ones stay as fallbacks) | ✓ |
| `terminal` | Font of every open tab and of the "Vibeshed" profile, keeping your size and weight | ✓ |
| `vscode` | `editor.fontFamily`, and `terminal.integrated.fontFamily` if you set one; fallback fonts are kept | ✓ |
| `zed` | `buffer_font_family`, `ui_font_family` when it matched the buffer font, `terminal.font_family` if set | ✓ |
| `jetbrains` | Editor font, terminal and console fonts if set apart, and fonts your color scheme overrides | on restart |

The `targets:` list limits fonts as well as themes, and a theme switch keeps the font.

## Key Bindings

Define bindings in the `keybindings:` config section. Each entry maps a key combo to an action or a key remap:

```yaml
keybindings:
  - combo: "capslock+space"
    action: "app/togglePicker"
  - combo: "capslock+1"
    action: "alias/Safari"
  - combo: "ctrl+h"
    remap: "left"
    app: "com.apple.Terminal"
```

Modifiers: `cmd`, `ctrl`, `option`/`alt`, `shift`, `capslock` (hyper), `space`. Mouse buttons: `mouse1`-`mouse5`.

To hand the keyboard back entirely in certain apps — remote-desktop and VM clients, where the combos belong to the machine on the other end — list their bundle IDs (matched case-insensitively) under `keybindingExclusions:`:

```yaml
keybindingExclusions:
  - "com.realvnc.vncviewer"
```

While one of those apps is focused, every key and mouse event passes straight through: no bindings (including the picker toggle), no remaps, and no capslock/space/tab modifier interception.

The one exception is a bound capslock. VM consoles such as UTM's macOS VMs only mirror the host's CapsLock toggle into the guest, never a press and release, so a Vibeshed running inside the VM could never see capslock held. Instead, while an excluded app is focused, holding capslock is sent as holding F18, and Vibeshed treats a held F18 as capslock. Capslock combos then work inside the VM as long as the guest runs Vibeshed too.

## Architecture

- **Swift Package Manager** with `Package.swift` — no Xcode project required
- **Actor-based modules** for thread-safe concurrent action queries
- **SwiftUI** for picker UI, status bar, and module preview views
- **Combine** for debounced search input
- **NSPanel** subclass for the floating picker window
- **YAML config** with typed per-module schemas, validation, and hot-reload

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for the dev setup and house style.

## Releases

Built, signed, and notarized by GitHub Actions on tag push. See [RELEASING.md](RELEASING.md) for the workflow.

## Wallpapers

Desktop wallpapers in Vibeshed's colors, in 5K and MacBook sizes, are in [docs/wallpapers](docs/wallpapers): [Sunset](docs/wallpapers/vibeshed-sunset-5k.jpg), [Midnight](docs/wallpapers/vibeshed-midnight-5k.jpg) and [Pattern](docs/wallpapers/vibeshed-pattern-5k.jpg).

## Support

Vibeshed is free. If it saves you keystrokes, [tip the project](https://vibeshed.dev/#support) in USDC:

- Base, Polygon, Arbitrum or Ethereum (one address): `0x9Ee642a541b96B85D4D4e5f17333b3121fD1E55A`
- Solana: `FFW7o79fpujjarCn87gorHcZzUzjzBpF6h4zfJDGpGEH`

Only these addresses, only these networks; check the whole address, not just its ends. They're signed in [DONATE.md](DONATE.md). We never post addresses in issues or messages, and we don't issue or endorse any token.

## License

[MIT](LICENSE)
