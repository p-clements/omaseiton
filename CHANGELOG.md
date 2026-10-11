# Changelog

## 0.2.1

- Replace the generic puzzle-piece icon with a theme-aware vector emblem matching the project artwork
- Keep saved layout contents, including private inline plugin settings, out of process arguments during restore; read them through stdin instead
- Complete the screenshot gallery and refresh panel, layout and marketplace preview images
- Simplify the README and move artwork provenance and font details to the asset build notes

## 0.2.0

First public release.

- A tree of bar plugins grouped by foldable lane, with **L C R** lane buttons, up/down reorder and an on/off toggle
- An Available list for installed bar plugins that are switched off
- One key rule: plain keys move the highlight, Shift moves the plugin (`Shift+↑↓` reorders, `Shift+←→` changes lane, `1 2 3` jump to a lane). Letters are read from the key itself, so CapsLock does not change them, and a held key never repeats a change
- Keys work as soon as the dropdown opens, and the highlight stays on the plugin after each move
- **Layouts**: save the bar as "My layout", restore it, or return to the Omarchy default. Restoring replaces only `bar.layout`, `bar.position`, `bar.transparent` and `bar.centerAnchor`, always takes a snapshot first (and so does saving over "My layout"), keeps Omaseiton on the bar, follows symlinks and keeps permissions
- **Update** shows a short summary per plugin and applies exactly the commit it showed, with validation and rollback. Git runs with hooks, filesystem-monitor programs and unusual transports disabled. Before, a large update opened git's pager, which looked like a hang
- After a move, the dropdown reopens on the same monitor
- Tests for every claim in the README, a mutation check, and a CI run of the marketplace's own manifest and security checks
