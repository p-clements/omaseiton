# Changelog

## 0.2.0 (unreleased)

- Layouts: save your bar as "My layout", restore it, or return to the Omarchy default. A snapshot is taken before every restore (last five kept)
- One key rule: plain keys move the highlight, Shift moves the widget (Shift+↑↓ reorders, Shift+←→ changes lane, 1 2 3 jump to a lane)
- Navigate with ↑↓ jk, Home End, and [ ] between lanes; keys work as soon as the dropdown opens
- The highlight stays on the widget after each move, so a key can be pressed repeatedly
- Two hint lines: the keys that always work, and what the keys do for the current row
- Reorder buttons are ▲ ▼ to match the keys
- Update now shows a short summary per plugin and asks before applying. Before, a large update opened git's pager, which looked like a hang
- Removed the old Reset button, which replaced the layout with no way back

## 0.1.0

- First version: a tree of bar widgets grouped by foldable lane, with L C R lane buttons, up/down reorder and an on/off toggle
- Available list for installed bar widgets that are switched off
- Marketplace, Add, Update and Reset shortcuts
- Keyboard navigation
