# Linux Phase 1 — Brand and look: plan

Roadmap: `2026-11-21-linux-elis-migration.md`, Phase 1 and D2. The Mac code is the reference.

## What the audit changed in the roadmap's list

- The shots' four right-hand title-bar buttons are scratch (`rectangle`), split, then dashboard and the quick
  terminal (`terminal`) (`WindowContentView+Titlebar.swift:154`, `AppSettings.swift:207`).
  Linux dropped scratch and the quick terminal, so its cluster is split, dashboard and custom commands.
  The Mac's overlay toggle is `hiddenByDefault` and not in the shots; the owner declined it on Linux.
- The line under a session's name is the Mac's `session.info` info line (`SidebarInfoCell.swift`), not its
  `context`, which the title pill shows. Linux's `session.info` read becomes `session.get` (task 8).
- The pill is the Mac's `recentSessions` element ("Session switcher"): it replaces the clock, and the plain title
  labels are its fallback when hidden. No new Interface preference.
- The selection pill takes the workspace tint, else the session tint, else the accent (`WorkspaceSidebar+Bands.swift:93`).
- On the Mac a tint always colours icon and name, a workspace tint draws the band and a session tint a 9% wash,
  and `--tint-on` is ignored (`TintCommands.swift:42`). The owner chose the same for Linux (task 7).

## Tasks

1. Accent: `QPalette::Highlight` is `#C8742F` on light and `#E08A45` on dark, re-applied when the palette changes.
2. Glyphs: the Mac's Lucide assets (`workspace-stack`, `session-terminal`, `session-plus`, `focus-frame`) in
   `resources/glyphs`, tinted like the launcher logos.
3. Sidebar delegate: workspace bands (radius 11, 10% fill, 16% stroke, gap 4, padding 3), selection pill
   (radius 8, 20%/12% fill, 55%/35% hairline), hover 7%, session wash 9%, the Mac's default status shapes and the
   indigo flag mark.
4. Density: `sidebarDensity` (`default`|`compact`) in Settings ▸ Appearance, `sidebar.density`, `elisctl sidebar
   density`, `sidebarDensity` in `tree`.
5. Title strip: the centred session pill (agent logo · workspace › session · context · Ctrl+P hint, radius 9,
   fill 7%/12% hover, hairline 10%) opens the session palette, which lists needs-you, recent and recently closed
   sessions as the Mac switcher does. Split shows its pane state; buttons are dim glyphs.
6. Footer: new workspace, new session | workspace filter, flagged view, with the Mac glyphs and a top hairline.
7. Tint placements go: a tint colours icon, name and band or wash; `--on`/`--tint-on` and the Show On submenu are
   removed, and an older file's placement is ignored.
8. The row's second line (spans `{text,bold,italic,code,dim,color?}` on `Session::infoSpans`) with its height and the
   Settings ▸ Interface ▸ Session info picker; the CI summary feeds it later, so `session.info` is not ported.
   `session.get` keeps Linux's process-detail read. Settings ▸ Interface gets Session context; the session palette
   hangs under the pill.

## Done when

- `scripts/screenshot.sh` renders light and dark Breeze close to `site/assets/shot-desktop-*.webp`.
- Build, `ctest` and `smoke.sh` pass.
- The owner has seen the result. Tests for the new behaviour and the `docs/images/elis.png` retake come after.
