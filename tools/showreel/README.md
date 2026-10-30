# Showreel

Scripted screenshots and videos of Vibeshed for the website and social media,
recorded in a UTM macOS VM so every take starts from the same clean desktop.

A **scene** (`scenes/*.yaml`) describes the starting state, the actions played
while recording, and the files to cut from the recording:

```yaml
title: Launch an app from the picker
setup:                        # the state the VM starts in
  appearance: dark
  wallpaper: ../../docs/wallpapers/vibeshed-sunset-macbook.jpg
  vibeshed: { config: ../configs/demo.yaml, keystrokes: true }
actions:                      # played while recording
  - press: capslock+space
  - waitFor: picker
  - marker: opened
  - type: calc
  - screenshot: { name: results, region: picker, padding: 80 }
  - press: return
outputs:                      # cut on the host with ffmpeg
  - { name: website, width: 1920 }
  - { name: square, crop: picker, padding: 160, size: 1080x1080, background: blur, from: opened-0.5 }
```

```bash
scripts/showreel record picker-launch
```

The take lands in `tools/showreel/out/picker-launch/`: `recording.mov` (the full
display at native resolution), each `screenshot` as a PNG, each output, the
agent's log and `manifest.json` (markers, window frames, timings). Re-cut the
outputs after editing them, without recording again:

```bash
scripts/showreel post picker-launch
```

## How it works

One Swift binary plays both roles. On the host it starts the VM with `utmctl`,
copies the scene (and the files it references) over SSH, and cuts outputs with
ffmpeg. In the VM it runs as `ShowreelAgent.app`, launched with `open` so it
lives in the logged-in GUI session with its own Accessibility and Screen
Recording grants: it applies the setup, records the display with
ScreenCaptureKit and synthesizes input at the HID level, ahead of Vibeshed's
event tap, so keybindings and the keystroke visualizer see it like real typing.

A held CapsLock is sent as F18 — the same way a host Vibeshed forwards CapsLock
into a VM — because a synthesized CapsLock never reaches Vibeshed's IOKit
monitor. `capslock+…` chords therefore need a config with a capslock binding
(`configs/demo.yaml` has them).

## One-time setup

You need UTM with a macOS VM ("macOS" by default; set `SHOWREEL_VM` otherwise)
that logs in automatically, with Homebrew installed, plus `ffmpeg` on the host.

1. **SSH key.** `scripts/showreel vm setup` creates `~/.ssh/vibeshed_showreel`.
2. **Remote Login.** In the VM, turn on System Settings › General › Sharing ›
   Remote Login, then authorize the key and record the guest's details:
   ```bash
   ssh-copy-id -i ~/.ssh/vibeshed_showreel.pub <vm-user>@<vm-ip>
   ```
   ```bash
   scripts/showreel vm setup --host <vm-ip>
   ```
   (Or run `sh "/Volumes/My Shared Files/<share>/tools/showreel/guest/bootstrap.sh"`
   in the VM's Terminal when the repo is shared into it; it also turns off
   sleep and the screen saver.) Later runs find the VM's address from its MAC
   address in `/var/db/dhcpd_leases`.
3. **Vibeshed.** `scripts/showreel vm install-vibeshed` installs the release
   from the Homebrew tap; `--dev` copies this checkout's build instead. Open it
   once in the VM and grant Accessibility and Input Monitoring.
4. **Permissions.** Either answer prompts by hand — `scripts/showreel vm doctor`
   installs the agent and asks for Accessibility, Screen Recording and
   Automation of System Events; answer them in the VM and rerun until all ✓ —
   or pre-grant everything without dialogs:
   ```bash
   security add-generic-password -s vibeshed-showreel-vm -a <vm-user> -w
   ```
   ```bash
   scripts/showreel vm grant
   ```
   `vm grant` reads the VM password from that Keychain item (or
   `SHOWREEL_VM_PASSWORD`), postpones macOS's recurring "bypass the private
   window picker" confirmation for the agent, keeps the VM awake, and writes
   the TCC grants for ShowreelAgent and Vibeshed with sudo. That last part
   needs System Integrity Protection off in the VM, once: `utmctl stop macOS
   && utmctl start --recovery macOS`, then Utilities › Terminal →
   `csrutil disable` and restart. `--dry-run` shows the changes without a
   password. Rerun it after `install-vibeshed --dev` (a new binary needs new
   grants).

   The grants belong to `ShowreelAgent.app`, a tiny launcher that starts the
   real agent (`~/Showreel/bin/showreel`) as its child; it only changes when
   its own source does, so rebuilding the agent keeps them.

`scripts/showreel vm inspect` saves a screenshot of the VM and lists every
window's frame — handy for picking coordinates and window frames.

## Scene reference

Coordinates are points from the top-left of the VM's display, `[x, y]` or
`[x, y, width, height]`. Paths are relative to the scene file and must be
inside the repo. Every field has a default.

### `setup`

| key | default | |
| --- | --- | --- |
| `quitApps` | `true` | quit every regular app (Finder stays) first |
| `display` | — | `{ width: 1440, height: 900 }`: switch display mode (only modes UTM offers) |
| `appearance` | — | `dark` / `light` |
| `wallpaper` | — | image file, or a solid color like `"#120d16"` |
| `dock` | — | `hidden` (autohide) / `shown` |
| `menuBar` | — | `hidden` (autohide) / `shown` |
| `desktopIcons` | — | `hidden` / `shown` |
| `desktopWidgets` | — | `hidden` / `shown` (calendar, weather… on the desktop) |
| `locale` | — | region format, e.g. `en_US` (how apps write numbers), set before apps launch |
| `vibeshed.config` | — | written to `~/.config/vibeshed/config.yaml` (the VM's own config is kept once as `config.yaml.before-showreel`) |
| `vibeshed.files` | — | more files for `~/.config/vibeshed`, e.g. `usage.json: ../fixtures/usage.json` |
| `vibeshed.reset` | `true` | delete usage, clipboard and timer history, so ranking starts the same |
| `vibeshed.launch` | `true` | relaunch Vibeshed after writing the files |
| `vibeshed.warmUp` | `true` | open and close the picker once before recording, so it doesn't appear on camera with a cold catalog |
| `vibeshed.keystrokes` | `false` | turn on the keystroke visualizer (needs `self` in the config) |
| `vibeshed.app` | `/Applications/Vibeshed.app` | |
| `prepare` | — | zsh script run after quitting the other apps, before opening `apps` (e.g. clear an app's saved session) |
| `apps` | — | `- { app: Safari, open: https://…, frame: [x, y, w, h], args: [--flag] }` (`args` apply at launch: apps are quit first) |
| `clipboard` | — | text on the clipboard |
| `events` | — | `- { title: Standup, in: 10, minutes: 15, url: https://zoom.us/j/… }`: events starting `in` minutes from setup, in a local "Showreel" calendar emptied first; `[]` only empties it, and leaving `events` out keeps an earlier scene's |
| `shell` | — | zsh script run in the VM after the apps open |
| `focus` | — | app to bring to the front last |
| `cursor` | — | pointer position |
| `actions` | — | actions played before recording, off camera (move a caret, clear an app) |
| `settle` | `1` | seconds to wait before recording |

### `record`

`video` (`true`; `false` for screenshot-only scenes), `fps` (`60`), `cursor`
(`false`), `codec` (`hevc` / `h264`), `leadIn` (`0.5`) and `leadOut` (`1`)
seconds around the actions.

### `actions`

| action | example |
| --- | --- |
| `wait` | `wait: 1.5` |
| `press` | `press: cmd+shift+4`, `press: { keys: down, times: 3, interval: 0.2 }` |
| `type` | `type: safari`, `type: { text: "Hello", cps: 14, jitter: 0.4 }` (seeded rhythm, same every take) |
| `open` | `open: vibeshed://picker?q=theme`, a web URL, or an app |
| `click` | `click: [400, 300]`, `click: { at: [400, 300], button: right, count: 2, glide: 0.4 }` |
| `move` | `move: [400, 300]`, `move: { to: [400, 300], duration: 0.8 }` |
| `drag` | `drag: { from: [100, 100], to: [600, 400], duration: 0.6 }` |
| `scroll` | `scroll: { at: [700, 500], dy: 10 }` (lines; positive scrolls down) |
| `screenshot` | `screenshot: name` (display), `{ name, window: picker }` (window + shadow, transparent), `{ name, region: picker, padding: 80 }` or `region: [x, y, w, h]` |
| `waitFor` | `waitFor: picker`, `waitFor: Safari`, `{ window: picker, gone: true, timeout: 3 }`, `{ result: Calculator }` (the picker's top result starts with it — check it before every Return: a stale list could run Sleep; with `fresh: true` it also waits for the top row to change from the one before the last `type`, and only warns if the same row stays on top), `{ window: Google Chrome, title: Hacker News, timeout: 15 }` (a page that loaded) |
| `select` | `select: "Tile Right: Ghostty"` — press ↓ to the picker row whose title starts with it, once the list is still, and check the preview shows it |
| `marker` | `marker: opened` — a named moment for outputs |
| `waitForUser` | `waitForUser: 120` — wait while someone answers system dialogs in the VM (the only step that runs while one is up) |
| `focus` | `focus: Safari` |
| `window` | `window: { app: Safari, frame: [80, 60, 1200, 760] }` |
| `shell` | `shell: "defaults write …"` |

Modifiers: `cmd`, `shift`, `opt`/`alt`, `ctrl`, `fn`, `capslock`. Keys: letters,
digits, symbols, `return`, `tab`, `space`, `delete`, `escape`, arrows,
`home`/`end`/`pageup`/`pagedown`, `f1`–`f20`.

### `outputs`

| key | default | |
| --- | --- | --- |
| `name` | required | file name without extension |
| `format` | `mp4` | `mp4`, `webm`, `gif`, `mov` (ProRes), `png` (one frame, needs `at`) |
| `crop` | `display` | `picker`, an app's window, or `[x, y, w, h]` — windows use every frame they were seen at |
| `padding` | `0` | points around the crop |
| `size` | — | exact size like `1080x1920`, fitted with `fit` |
| `width` | — | width keeping the crop's aspect (gif default 960) |
| `fit` | `pad` | `pad` (with `background`) or `cover` |
| `background` | `black` | ffmpeg color (`'#101018'`) or `blur` |
| `from` / `to` / `at` | — | seconds, a marker, `marker±seconds`, `start`, `end` |
| `skip` | — | stretches to cut, e.g. `[[searching+0.5, results]]` to jump past a spinner or a page load |
| `loop` | — | seconds of crossfade from the end back into the start, for `<video loop>`; the output is that much shorter. Start the clip with that long of a still moment |
| `fps` | `60` (gif `15`) | |
| `speed` | `1` | |
| `quality` | 18 (mp4) / 32 (webm) | CRF |

## Website clips

`scenes/clip-*.yaml` are short loops for the site — launcher (Spotify,
Ghostty, VS Code), math, clipboard history, palette themes, Homebrew, URL
routing and window tiling (four apps snapped into a 2×2 grid) — on the
site's `--bg` (`#120d16`) with `configs/clips.yaml`. They switch the VM to a
1280×800 display so the UI fills a small crop, and fade their last half
second into the first (`loop: 0.5`).

Each clip applies the "Vibeshed" palette theme (the site's pink on its card
color) in setup: with no palette applied, Vibeshed 0.6.1 colors the picker
from whatever is on screen, which on a near-black background comes out
near-black. The config also makes Vibeshed the default browser (URL routing
clip) and turns off the overlay backdrop, so the background never changes.

The VM needs the apps the clips use (`brew install --cask spotify
visual-studio-code ghostty google-chrome`, `brew install fastfetch`); `vm
grant` clears their first-launch "downloaded from the Internet" check.

```bash
scripts/showreel record clip-launcher clip-math clip-clipboard clip-themes clip-homebrew clip-urls clip-windows
```

Content clips — `clip-tabs`, `clip-projects`, `clip-github`, `clip-terminal`,
`clip-ai`, `clip-calendar` — layer `configs/clips-content.yaml` over
`clips.yaml` and run `fixtures/demo-data.py` first (sample projects, Claude
Code sessions, VS Code recents). They need Automation and Calendar grants that
macOS 27 keeps out of `vm grant`'s reach; `scripts/showreel record
permissions` brings up every prompt in one sitting for you to Allow. `clip-ai`
needs Claude Code signed in in the VM; `clip-calendar` needs a Vibeshed newer
than 0.6.1. Secrets such as `SPOTIFY_CLIENT_ID` go in the git-ignored
`tools/showreel/.vm/secrets.env` and fill `${NAME}` placeholders in configs.

Theme clips — `clip-theming` (⇪N steps through four themes while VS Code,
Neovim, htop and lsd in Ghostty splits, the wallpaper and the accent all
follow) and `clip-wallpapers` (generated wallpaper styles previewing live) —
layer `configs/clips-theming.yaml`, which turns on those targets and leaves
the wallpaper to the theme, so they fill the whole screen instead of sitting
on `--bg`. `fixtures/terminal-tools.sh` points Neovim at the terminal's ANSI
colors and lsd at the colors Vibeshed writes (`brew install neovim htop lsd`).
VS Code only picks up Vibeshed's theme extension after it restarts, so the
first `clip-theming` take after a fresh VM shows a reload prompt; record it
twice.

Each output prints the background color as a browser decodes it (outputs are
tagged sRGB so it matches CSS); give the element around a clip that color and
the clip has no visible edge:

```html
<video src="launcher.mp4" autoplay muted loop playsinline poster="launcher-poster.png"></video>
```

## Website lap

`scenes/site-lap.yaml` is the redesigned site's video: search, themes and
windows in one continuous take that starts and ends on the same empty desktop
(Vibeshed Glow, every window minimized, no Dock or menu bar), so it loops with
no seam. It uses `configs/site-videos.yaml` with `configs/site-search.yaml`
over it, on a base VM with Vibeshed 0.12.0, Spotify, Zed, Ghostty and btop,
Spotify and Claude Code signed in, and a Claude Code session in
`~/code/vibeshed`. Prepare it once:

```bash
scripts/showreel record site-permissions site-search-permissions
```

```bash
scripts/showreel record site-lap-warmup
```

```bash
scripts/showreel record site-lap
```

```bash
scripts/site-videos.sh
```

The permission scenes bring up the Automation and Calendar prompts for you to
Allow. The warm-up teaches the picker the lap's results (Vibeshed ranks by
usage) and renders each theme's wallpaper once, off camera. `site-videos.sh`
zooms search in on the picker, paces each part, and writes the lap, an 800 px
cut, a poster and each part on its own to `out/site-videos/`, then prints an
SSIM check of the last frame against the first.

The site's stills come from the same base, with VS Code added
(`configs/site-stills.yaml` puts it among the theme targets). Open VS Code once
in the VM by hand first: trust `~/code/vibeshed` and close its Welcome tab.

```bash
scripts/showreel record site-stills-warmup
```

```bash
scripts/showreel record site-picker-themes site-theme-montage
```

```bash
scripts/site-stills.sh
```

`site-picker-themes` shoots the picker in four themes with two demo queries,
alone on transparency and on each theme's wallpaper; `site-theme-montage`
shoots VS Code, Ghostty and the picker's theme list in six themes.
`site-stills.sh` converts them to sRGB, writes WebP beside each PNG or JPEG,
and lays the six screens out as a 3×2 montage in `out/site-stills/`.

## README GIF

`scenes/readme-hero.yaml` is the GIF at the top of the repo's README: search,
four themes and a maximized window in one ~30 s loop on the same base VM, at
1280×800 so the picker stays readable at 960 px, with the keystroke visualizer
on. Copy `out/readme-hero/readme.gif` to `docs/img/readme-hero.gif`.

```bash
scripts/showreel record readme-hero
```

## Gotchas

- The VM must be logged in to its desktop: the agent needs the GUI session.
- While a macOS security or consent dialog is on screen in the VM, a take
  stops instead of sending input (a synthesized Return would answer it).
  Each take captures once before setup, so the screen-recording confirmation
  shows up then rather than mid-take. `vm grant` postpones it for good.
- ScreenCaptureKit writes frames only when the screen changes; outputs hold
  the last frame so still endings keep their length.
- `type` uses the VM's current keyboard layout; characters it lacks are sent
  as text.
- Emoji are options of "Find Emoji", not top-level results: type `emoji`,
  press Return, then search (see `scenes/website-stills.yaml`).
- Tests: `make showreel-test`.
