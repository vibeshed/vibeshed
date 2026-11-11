# Site assets

Videos and screenshots of the real app for the redesigned page, as planned in
the redesign doc (https://claude.ai/artifact/6s5cSP7V1WAu1dncwuRPz5: Videos,
and Build → Assets). All of it is Vibeshed 0.12.0 in a macOS VM at
1600×1000 pt, captured at 2×, in sRGB. Nothing is burned into the
frames: lines, keys and captions belong in the page's HTML.

They're recorded by the showreel tool in `tools/showreel/` (scenes
`site-lap.yaml`, `site-picker-themes.yaml` and `site-theme-montage.yaml`,
finished by `scripts/site-videos.sh` and `scripts/site-stills.sh`; see
`tools/showreel/README.md`, Website lap). Re-record rather than editing these
files.

## `video/`: the lap

One seamless 57.4 s loop: search, themes and windows, starting and ending on
the same empty desktop (seam SSIM 0.998). It belongs in the showcase, right
below the hero.

| File | Size | Use |
| --- | --- | --- |
| `lap.mp4` | 1600×1000, 4.1 MB | H.264, the first `<source>` |
| `lap.webm` | 1600×1000, 4.2 MB | VP9, the second `<source>` |
| `lap-800.mp4` | 800×500, 1.5 MB | phones (`media="(max-width: 700px)"`) |
| `lap-poster.jpg` | 1600×1000 | poster: the search part's last result |

How the doc wants it played:

- One `<video muted playsinline loop preload="none" poster="video/lap-poster.jpg">`
  with the MP4 source first. Start it once half of it is on screen
  (IntersectionObserver), pause when it leaves or the tab is hidden.
- A small Pause button in the corner (WCAG 2.2.2). With
  `prefers-reduced-motion`, no autoplay: the poster and a play button, one lap
  per press.
- `aria-describedby` points at a one-paragraph summary of the lap; the text
  beside it stays `aria-live="off"`.
- The line, small print and keys beside it follow `currentTime`:

| From | Line | Small print | Keys at rest |
| --- | --- | --- | --- |
| 0:00 | Whatever you’re into. | Apps, tracks, tabs, meetings, pull requests and AI sessions, from one search bar. Each with a preview. | ⇪ Space |
| 0:20.03 | One palette, everywhere. | A theme repaints macOS, your wallpaper, terminal and editor. Preview live. Esc is the safe word. | ⇪ Space |
| 0:39.45 | Try every position. | Tile, focus, maximize and grid every window from the keyboard, 4 pt apart. | ⇪ ← → M P |

Key cues (seconds, each lit for about 0.9 s), mapped from the take's event
log onto the lap's timeline (the two ↓ checked against its frames); `site.js`
has them as `CUES`:

```
0.9 ⇪ Space · 1.5 spot · 3.7 ↓ · 7.0 caps · 9.0 pair · 11.3 my mind · 14.0 pull ↩ · 15.1 font · 16.7 ↩ · 18.8 esc
20.0 ⇪ Space · 20.6 restore ↩ · 22.7 ⇪ Space · 23.1 switch theme ↩ · 25.0 tok · 26.6 latte · 28.6 gruv
30.4 drac · 32.0 os 9 · 34.4 95 · 35.9 amiga · 37.7 esc
39.5 ⇪ Space · 40.0 left ↩ · 42.2 ↓ · 44.3 ↩ · 45.2 ⇪ ← · 46.0 ⇪ → · 46.9 ⇪ M · 47.9 ⇪ M · 48.8 ⇪ P
49.4 saf · 50.9 ↩ · 51.9 ⇪ Space · 52.4 grid ↩ · 54.5 ⇪ Space · 55.1 min all ↩
```

Summary for screen readers: “A 57-second loop of Vibeshed on an empty Mac
desktop. Search finds Spotify, a Safari tab, a meeting, a Claude Code session
and a pull request, each with a preview. Then the windows come back and seven
themes repaint the terminal, editor, wallpaper and picker. Finally the windows
are tiled, maximized, put in a grid and minimized, leaving the empty desktop
again.”

## `img/shot-*.webp`: frames of the lap

The feature cards' pictures, cut from the lap's 3200 px master by
`scripts/site-videos.sh` at the scene's `shot-*` markers: the picker alone
(its footer cropped off) for `shot-tab` (the Caps Lock tab), `shot-meeting`
(the Pairing session in 4 min, with its Zoom pill) and `shot-claude` (the
Claude Code session), each 800×506; and the whole screen after Attach All
Windows to Grid for `shot-grid`, 800×500.

## `img/picker/`: the picker in four themes

The picker at 2× in three states, in the site's own palette (`vibeshed-glow`,
the sunset colors) and three built-in themes: `tokyo-night`,
`catppuccin-latte` and `mac-os-9`. Pick one state for the whole page;
`launch` shows the widest range.

- `launch-<theme>`: the picker as it opens, nothing typed. The list is what
  you reach for most: “(I Can’t Get No) Satisfaction” playing in Spotify (album
  art and a Now playing pill in the preview), the Claude Code session, a
  project file in Zed, Search Pull Requests, Switch Theme, a Safari tab and
  Spotify's controls.
- `music-<theme>`: `satis` typed, the same track first, then the site's own
  tab (“Vibeshed: satisfaction in a few keystrokes”), Switch Theme, Search
  Spotify and Switch Font; the lower rows are window commands. It
  answers the headline.
- `session-<theme>`: `my` typed, the Claude Code session “teach the picker to
  read my mind”, with project, branch `feat/mind-reading` and model Opus 5.5 in
  the preview.

The lists come from a seeded usage history
(`tools/showreel/fixtures/site-stills-usage.json`), so window
commands the video rehearsals ran don't crowd them.

| Files | Size | What |
| --- | --- | --- |
| `<query>-<theme>.webp` | 1680×1168 | the picker window alone, its shadow on transparency (40 pt of it around the picker); show at 840 px wide |
| `<query>-<theme>-desktop.webp` | 2064×1552 | the picker on that theme's generated wallpaper, 136 pt around it; show at 1032 px wide |

Alt text, for example: “Vibeshed's picker in Tokyo Night, just opened: (I Can’t
Get No) Satisfaction playing in Spotify with its album art, then a Claude Code
session, a project, pull requests, themes and a Safari tab.”

## `img/themes/`: the theme montage

VS Code (`Vibeshed/Picker/PickerView.swift`), Ghostty running btop, and the
picker's Switch Theme list, each theme on its own generated wallpaper. For the
themes band.

| File | Size | What |
| --- | --- | --- |
| `montage.webp` | 2328×974 | all six, 3 across and 2 down, 24 px gaps, rounded corners on transparency; show at 1164 px wide |
| `<theme>.webp` | 1600×1000 | one screen each, for theme chips or a carousel; show at 800 px wide |

Themes, in montage order, with the wallpaper each brings:

| File | Theme | Wallpaper |
| --- | --- | --- |
| `vibeshed-glow` | Vibeshed Glow (site palette) | Glow |
| `tokyo-night` | Tokyo Night | Topographic |
| `catppuccin-latte` | Catppuccin Latte | Sashiko |
| `dracula` | Dracula | 10 PRINT |
| `mac-os-9` | Mac OS 9 | Desktop Pattern |
| `amiga-workbench-1-3` | Amiga Workbench 1.3 | Boing Ball grid |

## Not here yet

- The 1200×630 social card: drafted in the doc's Voice section, still to render.
- The wallpaper strip: thumbnails of the generated styles from the app's renderer.
- The photo for the support section.
