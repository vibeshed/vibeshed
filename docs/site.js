// Vibeshed's one page: themes (press T), the video lap, the download panel,
// Send to my Mac and the copy buttons. No dependencies; every part works on its own.
(() => {
  'use strict';

  const $ = (sel, root = document) => root.querySelector(sel);
  const $$ = (sel, root = document) => [...root.querySelectorAll(sel)];
  const root = document.documentElement;
  const handheld = root.classList.contains('handheld');
  const calm = matchMedia('(prefers-reduced-motion: reduce)');
  const prefersDark = matchMedia('(prefers-color-scheme: dark)');
  const support = $('#support');
  const panel = $('#dl-panel');

  // Typing in a field, or a modifier held: page shortcuts stay out of the way.
  const typing = (e) => {
    const el = e.target;
    return e.metaKey || e.ctrlKey || e.altKey || (el && (el.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(el.tagName)));
  };

  // --- Colors --------------------------------------------------------------------------

  const rgb = (h) => [1, 3, 5].map((i) => parseInt(h.slice(i, i + 2), 16));
  const hex = (c) => '#' + c.map((v) => Math.round(v).toString(16).padStart(2, '0')).join('');
  const mix = (a, b, t) => hex(rgb(a).map((v, i) => v + (rgb(b)[i] - v) * t));
  const lum = (h) => {
    const [r, g, b] = rgb(h).map((v) => { v /= 255; return v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4; });
    return 0.2126 * r + 0.7152 * g + 0.0722 * b;
  };
  const contrast = (a, b) => { const [x, y] = [lum(a), lum(b)].sort((m, n) => n - m); return (x + 0.05) / (y + 0.05); };
  const readableOn = (bg, prefer) => [prefer, '#ffffff', '#000000'].find((c) => contrast(c, bg) >= 4.5)
    || (contrast('#ffffff', bg) > contrast('#000000', bg) ? '#ffffff' : '#000000');
  // Nudge a color toward `to` until it reads on every background given.
  const legible = (color, to, backgrounds, ratio = 4.5) => {
    for (let t = 0; t <= 1; t += 0.1) {
      const c = mix(color, to, t);
      if (backgrounds.every((bg) => contrast(c, bg) >= ratio)) return c;
    }
    return to;
  };

  // --- Themes: the page wears a built-in palette ----------------------------------------

  // Shown first in the chips and in the order T steps through: the lap's lineup, then the rest.
  const LINEUP = ['Tokyo Night', 'Catppuccin Latte', 'Gruvbox', 'Dracula', 'Mac OS 9', 'Windows 95', 'Amiga Workbench 1.3'];
  const TOKENS = ['--bg', '--surface', '--sunk', '--ink', '--ink-2', '--line', '--accent', '--btn', '--btn-ink', '--sel', '--sel-ink', '--glow'];
  let themes = [];
  let worn = -1; // the theme the page wears; -1 is the site's own palette

  const siteMode = () => root.dataset.scheme || (prefersDark.matches ? 'dark' : 'light');

  function paint(i) {
    const t = themes[i];
    if (!t) {
      TOKENS.forEach((k) => root.style.removeProperty(k));
      root.dataset.mode = siteMode();
      delete root.dataset.theme;
    } else {
      const dark = t.mode === 'dark';
      const surface = dark ? mix(t.bg, t.fg, 0.06) : mix(t.bg, '#ffffff', 0.6);
      const sunk = mix(t.bg, t.fg, dark ? 0.03 : 0.04);
      const sel = t.sel || mix(surface, t.accent, 0.18);
      const set = {
        '--bg': t.bg, '--surface': surface, '--sunk': sunk, '--ink': t.fg,
        '--ink-2': legible(t.muted, t.fg, [t.bg, surface, sunk]),
        '--line': mix(t.bg, t.fg, 0.14),
        '--accent': legible(t.accent, t.fg, [t.bg, surface, sunk]),
        '--btn': t.accent, '--btn-ink': readableOn(t.accent, t.bg),
        '--sel': sel, '--sel-ink': readableOn(sel, t.fg),
        '--glow': t.accent + '40',
      };
      Object.entries(set).forEach(([k, v]) => root.style.setProperty(k, v));
      root.dataset.mode = t.mode;
      root.dataset.theme = t.name;
    }
    root.style.colorScheme = root.dataset.mode;
    shots(t ? t.name : null);
    $$('#chips .chip').forEach((chip) => chip.setAttribute('aria-pressed', String(Number(chip.dataset.index) === i)));
    rove();
  }

  // Real screenshots exist for a few themes (docs/ASSETS.md): the hero picker in four, the
  // VS Code + btop + theme list screen in six. Wearing one of those swaps them in.
  const slug = (name) => name.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/-$/, '');
  const PICKER_SHOTS = ['Tokyo Night', 'Catppuccin Latte', 'Mac OS 9'];
  const THEME_SHOTS = {
    'Tokyo Night': 'Topographic', 'Catppuccin Latte': 'Sashiko', Dracula: '10 PRINT',
    'Mac OS 9': 'Desktop Pattern', 'Amiga Workbench 1.3': 'Boing Ball grid',
  };
  const heroShot = $('#hero-picker');
  const heroNote = $('#hero-picker-note');
  const themeShot = $('#theme-shot');
  const themeNote = $('#theme-shot-note');
  const montage = themeShot && { src: themeShot.getAttribute('src'), alt: themeShot.alt, note: themeNote.innerHTML };

  function shots(name) {
    if (heroShot) {
      const own = PICKER_SHOTS.includes(name);
      const label = own ? name : 'its own Vibeshed Glow palette';
      heroShot.src = `img/picker/launch-${own ? slug(name) : 'vibeshed-glow'}.webp`;
      heroShot.alt = `Vibeshed’s picker in ${label}, just opened: (I Can’t Get No) Satisfaction playing in Spotify with its album art, then a Claude Code session, a project, pull requests, themes and a Safari tab.`;
      heroNote.textContent = own ? `In ${name}, as the app draws it.` : name ? `Shown in Vibeshed Glow; the app has ${name} too.` : '';
      if (!name) heroNote.innerHTML = 'Press <kbd>T</kbd> to see it in other themes.';
    }
    if (themeShot) {
      const wallpaper = THEME_SHOTS[name];
      if (wallpaper) {
        themeShot.src = `img/themes/${slug(name)}.webp`;
        themeShot.width = 1600;
        themeShot.height = 1000;
        themeShot.dataset.single = '';
        themeShot.alt = `${name} on its ${wallpaper} wallpaper, repainting VS Code, Ghostty running btop and the picker’s theme list.`;
        themeNote.textContent = `${name} on its ${wallpaper} wallpaper, as the app applies it.`;
      } else if (themeShot.hasAttribute('data-single')) {
        themeShot.src = montage.src;
        themeShot.width = 2328;
        themeShot.height = 974;
        delete themeShot.dataset.single;
        themeShot.alt = montage.alt;
        themeNote.innerHTML = montage.note;
      }
    }
  }

  // The chips are one Tab stop: the pressed chip (or the first), with arrow keys moving inside.
  function rove(focus) {
    const chips = $$('#chips .chip').filter((c) => !c.hidden);
    if (!chips.length) return;
    const current = focus || chips.find((c) => c.getAttribute('aria-pressed') === 'true') || chips[0];
    chips.forEach((c) => { c.tabIndex = c === current ? 0 : -1; });
    if (focus) focus.focus();
  }

  function wear(i, announce = true) {
    worn = i;
    paint(i);
    const status = $('#wearing');
    if (status && announce) status.textContent = i < 0 ? 'Wearing: Vibeshed, the site’s own palette.' : `Wearing: ${themes[i].name}. Esc takes it off.`;
  }

  function step(by) {
    if (!themes.length) return;
    const order = themes.map((_, i) => i);
    const at = worn < 0 ? -1 : order.indexOf(worn);
    // From the site palette, T starts at the first theme and Shift-T at the last.
    const next = at < 0 ? (by > 0 ? 0 : order.length - 1) : (at + by + order.length) % order.length;
    wear(order[next]);
  }

  function buildChips() {
    const box = $('#chips');
    const more = $('#chips-more');
    if (!box) return;
    themes.forEach((t, i) => {
      const b = document.createElement('button');
      b.type = 'button';
      b.className = 'chip';
      b.dataset.index = String(i);
      b.setAttribute('aria-pressed', 'false');
      b.innerHTML = `<span class="dot" aria-hidden="true"><i style="background:${t.bg}"></i><i style="background:${t.accent}"></i></span>`;
      b.append(t.name);
      if (i >= LINEUP.length + 9) b.hidden = true;
      b.addEventListener('click', () => wear(worn === i ? -1 : i));
      box.append(b);
    });
    box.addEventListener('keydown', (e) => {
      const chips = $$('.chip', box).filter((c) => !c.hidden);
      const at = chips.indexOf(document.activeElement);
      const to = { ArrowRight: at + 1, ArrowDown: at + 1, ArrowLeft: at - 1, ArrowUp: at - 1, Home: 0, End: chips.length - 1 }[e.key];
      if (at < 0 || to === undefined) return;
      e.preventDefault();
      rove(chips[(to + chips.length) % chips.length]);
    });
    if (more && themes.length > LINEUP.length + 9) {
      more.hidden = false;
      more.addEventListener('click', () => {
        const open = more.getAttribute('aria-expanded') !== 'true';
        $$('.chip', box).forEach((c, i) => { if (i >= LINEUP.length + 9) c.hidden = !open; });
        more.setAttribute('aria-expanded', String(open));
        more.textContent = open ? 'Show fewer' : 'Show all';
        rove();
      });
    }
  }

  prefersDark.addEventListener('change', () => { if (worn < 0) paint(-1); });

  // --- Theme data ----------------------------------------------------------------------

  fetch('themes.json').then((r) => r.json()).then((data) => {
    const lineup = LINEUP.map((name) => data.themes.find((t) => t.name === name)).filter(Boolean);
    themes = [...lineup, ...data.themes.filter((t) => !LINEUP.includes(t.name))];
    buildChips();
    rove();
  }).catch(() => {});

  paint(-1);

  // --- Keyboard: D downloads, T tries on a theme, Esc takes it off -----------------------

  document.addEventListener('keydown', (e) => {
    if (e.defaultPrevented || typing(e) || (panel && panel.open)) return;
    if (e.key === 'd' || e.key === 'D') {
      if (handheld) return;
      e.preventDefault();
      getIt();
    } else if (e.key === 't' || e.key === 'T') {
      e.preventDefault();
      step(e.shiftKey ? -1 : 1);
    } else if (e.key === 'Escape' && worn >= 0) {
      wear(-1);
    }
  });

  // --- Download panel ------------------------------------------------------------------

  let ready;
  function openPanel() {
    if (!panel || panel.open) return;
    const spin = $('.spin', panel);
    const title = $('#dl-title');
    spin.classList.remove('done');
    title.textContent = 'Your download is starting';
    clearTimeout(ready);
    ready = setTimeout(() => {
      spin.classList.add('done');
      title.textContent = 'Your download has started';
    }, 2500);
    panel.showModal();
  }

  function getIt() {
    if (handheld) { $('#send').click(); return; }
    const link = $('a.btn[data-download]');
    if (link) link.click();
  }

  // The link downloads the file itself; the panel opens beside it and never blocks it.
  $$('a[data-download]').forEach((a) => a.addEventListener('click', () => {
    if (!a.hasAttribute('data-retry')) openPanel();
  }));

  // The one ask: Send USDC closes the panel and goes to the addresses.
  if (panel) {
    $('#give').addEventListener('click', () => panel.close());
    panel.addEventListener('click', (e) => { if (e.target === panel) panel.close(); }); // a click on the backdrop
  }

  // --- Send to my Mac ------------------------------------------------------------------

  const send = $('#send');
  if (send) {
    send.addEventListener('click', (e) => {
      if (!navigator.share) return; // the mailto link does it
      e.preventDefault();
      navigator.share({
        title: 'Vibeshed',
        text: 'Vibeshed, a free keyboard launcher for macOS (Apple silicon only). Open this on your Mac:',
        url: 'https://vibeshed.dev/',
      }).catch((err) => { if (err.name !== 'AbortError') location.href = send.href; });
    });
  }

  // --- Copy buttons --------------------------------------------------------------------

  function copyText(text) {
    if (navigator.clipboard && window.isSecureContext) return navigator.clipboard.writeText(text);
    const area = document.createElement('textarea');
    area.value = text;
    area.setAttribute('readonly', '');
    area.style.position = 'fixed';
    area.style.opacity = '0';
    document.body.append(area);
    area.select();
    const ok = document.execCommand('copy');
    area.remove();
    return ok ? Promise.resolve() : Promise.reject(new Error('copy failed'));
  }

  $$('button[data-copy]').forEach((b) => {
    const label = b.textContent;
    b.addEventListener('click', () => {
      copyText(b.dataset.copy).then(() => {
        b.textContent = 'Copied';
        b.dataset.done = '';
      }, () => {
        b.textContent = 'Select and copy it';
      }).finally(() => setTimeout(() => { b.textContent = label; delete b.dataset.done; }, 2000));
    });
  });

  // --- The latest release --------------------------------------------------------------

  fetch('latest.json', { cache: 'no-cache' }).then((r) => r.json()).then((latest) => {
    const size = `${(latest.size / 1e6).toFixed(1)} MB`;
    $$('[data-latest="version"]').forEach((el) => { el.textContent = latest.version; });
    $$('[data-latest="size"]').forEach((el) => { el.textContent = size; });
    $$('[data-latest="file"]').forEach((el) => { el.textContent = latest.file; });
    $$('a[data-download]').forEach((a) => { a.href = latest.url; });
  }).catch(() => {});

  // --- The video lap -------------------------------------------------------------------

  const player = $('#player');
  if (player) {
    const video = $('video', player);
    const toggle = $('.player-toggle', player);
    const line = $('.player-line', player);
    const print = $('.player-print', player);
    const keys = $('.player-keys', player);
    const chapter = $('.player-n', player);
    const CLIPS = [
      { at: 0, line: 'Whatever you’re into.', print: 'Apps, tracks, tabs, meetings, pull requests and AI sessions, from one search bar. Each with a preview.', rest: ['⇪', 'Space'] },
      { at: 20.03, line: 'One palette, everywhere.', print: 'A theme repaints macOS, your wallpaper, terminal and editor. Preview live. Esc is the safe word.', rest: ['⇪', 'Space'] },
      { at: 39.45, line: 'Try every position.', print: 'Tile, focus, maximize and grid every window from the keyboard, 4 pt apart.', rest: ['⇪', '←', '→', 'M', 'P'] },
    ];
    // Lap times, checked against the take: each key lights as it's pressed.
    const CUES = [
      [0.9, ['⇪', 'Space']], [1.5, ['spot']], [3.7, ['↓']], [7.0, ['caps']], [9.0, ['pair']], [11.3, ['my mind']],
      [14.0, ['pull', '↩']], [15.1, ['font']], [16.7, ['↩']], [18.8, ['esc']],
      [20.0, ['⇪', 'Space']], [20.6, ['restore', '↩']], [22.7, ['⇪', 'Space']], [23.1, ['switch theme', '↩']],
      [25.0, ['tok']], [26.6, ['latte']], [28.6, ['gruv']], [30.4, ['drac']], [32.0, ['os 9']], [34.4, ['95']], [35.9, ['amiga']], [37.7, ['esc']],
      [39.5, ['⇪', 'Space']], [40.0, ['left', '↩']], [42.2, ['↓']], [44.3, ['↩']], [45.2, ['⇪', '←']], [46.0, ['⇪', '→']],
      [46.9, ['⇪', 'M']], [47.9, ['⇪', 'M']], [48.8, ['⇪', 'P']], [49.4, ['saf']], [50.9, ['↩']],
      [51.9, ['⇪', 'Space']], [52.4, ['grid', '↩']], [54.5, ['⇪', 'Space']], [55.1, ['min all', '↩']],
    ];
    const LIT = 0.9; // seconds a key stays lit
    const KEYS = new Set(['⇪', 'Space', '↓', '↩', 'esc', '←', '→', 'M', 'P']);
    let wants = !calm.matches; // play when in view; the Pause button and reduced motion turn it off
    let inView = false;
    let clip = -1;
    let state = '';

    const render = () => {
      const t = video.currentTime;
      let c = CLIPS.length - 1;
      while (c > 0 && CLIPS[c].at > t) c--;
      if (c !== clip) {
        clip = c;
        line.textContent = CLIPS[c].line;
        print.textContent = CLIPS[c].print;
        chapter.textContent = String(c + 1);
      }
      let q = -1;
      while (q + 1 < CUES.length && CUES[q + 1][0] <= t) q++;
      const lit = q >= 0 && t - CUES[q][0] < LIT && CUES[q][0] >= CLIPS[c].at;
      const next = lit ? `cue${q}` : `rest${c}`;
      if (next !== state) {
        state = next;
        keys.replaceChildren(...(lit ? CUES[q][1] : CLIPS[c].rest).map((k) => {
          const el = document.createElement(KEYS.has(k) ? 'kbd' : 'code');
          el.textContent = k;
          el.className = lit ? 'on' : 'rest';
          return el;
        }));
      }
    };
    const tick = () => { render(); if (!video.paused) requestAnimationFrame(tick); };

    const label = () => {
      const text = wants ? 'Pause' : calm.matches ? 'Play one lap' : 'Play';
      toggle.textContent = text;
      toggle.setAttribute('aria-label', `${text} the demo`);
    };
    const sync = () => {
      if (wants && inView && !document.hidden) video.play().then(label, label);
      else video.pause();
      label();
    };
    const setCalm = () => {
      video.loop = !calm.matches; // with reduced motion, a press plays one lap
      if (calm.matches) wants = false;
      sync();
    };

    video.addEventListener('play', () => requestAnimationFrame(tick));
    video.addEventListener('pause', label);
    video.addEventListener('seeked', render);
    video.addEventListener('ended', () => { wants = false; video.currentTime = 0; sync(); });
    toggle.addEventListener('click', () => {
      wants = !wants;
      if (wants && calm.matches) inView = true; // a press always plays, even half in view
      sync();
    });
    document.addEventListener('visibilitychange', sync);
    calm.addEventListener('change', setCalm);

    if ('IntersectionObserver' in window) {
      // Start fetching as it comes into view; play once half of it is on screen.
      new IntersectionObserver((entries, observer) => {
        if (entries.some((e) => e.isIntersecting)) { video.preload = 'auto'; observer.disconnect(); }
      }).observe(video);
      new IntersectionObserver((entries) => {
        const e = entries[entries.length - 1];
        inView = e.isIntersecting && e.intersectionRatio >= 0.5;
        sync();
      }, { threshold: [0, 0.5, 1] }).observe(video);
    } else {
      inView = true;
    }
    video.loop = !calm.matches;
    render();
    label();
  }
})();
