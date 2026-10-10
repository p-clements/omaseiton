<p align="center">
  <img src="assets/banner.svg" alt="Omaseiton: everything in its place on your Omarchy bar" width="100%">
</p>

<p align="center">
  <b>See every widget on your Omarchy bar, grouped by lane. Reorder, move and toggle them from one dropdown.</b>
</p>

<p align="center">
  <img alt="license" src="https://img.shields.io/badge/license-MIT-blue">
  <img alt="omarchy plugin" src="https://img.shields.io/badge/omarchy-bar--widget-7aa2f7">
</p>

---

## The name

**Omaseiton** is *Omarchy* + **整頓 (seiton)**, the Japanese word for putting things in order. It is the second of the 5S workplace principles: "a place for everything, and everything in its place."

## What it is

Omaseiton is a bar widget for the [Omarchy](https://omarchy.org) shell. Click its icon and a dropdown lists every widget on your bar, split into **Left**, **Center** and **Right** lanes, followed by the bar widgets you have installed but switched off.

> Screenshots are tracked in [docs/SCREENSHOTS.md](docs/SCREENSHOTS.md).

| | |
|---|---|
| **Lanes at a glance** | Every widget on the bar, in order, with its plugin id and whether it is built in, a plugin or a clone. |
| **Reorder** | Move a widget earlier or later in its lane. |
| **Change lane** | Send a widget to the neighbouring lane in one click. |
| **Toggle** | Switch a widget off the bar, or switch an available one back on. |
| **Native look** | Built from Omarchy's own UI components and theme colours, so it follows `omarchy theme set` automatically. |
| **Keyboard first** | `j`/`k` move the cursor, `h`/`l` change lane, `Shift+J`/`Shift+K` reorder, `Space` toggles, `Esc` closes. |
| **Plugin shortcuts** | Browse the [Omarchy marketplace](https://plugins.omarchy.org), add a plugin from a git URL, update your git plugins, or reset the layout. |

## Install

```bash
omarchy plugin add https://github.com/<you>/omaseiton.git --enable
```

Then look for the puzzle-piece icon on your bar.

To install from a local clone while developing, copy the repo into `~/.config/omarchy/plugins/pclements.omaseiton/`, then run `omarchy-shell shell rescanPlugins` and enable it with `omarchy plugin enable pclements.omaseiton`.

## Remove

```bash
omarchy plugin remove pclements.omaseiton
```

## Keys

| Key | Action |
|---|---|
| `j` / `k` or `↓` / `↑` | Move the cursor |
| `h` / `l` or `←` / `→` | Move the selected widget to the previous or next lane |
| `Shift+K` / `Shift+J` | Move the selected widget earlier or later in its lane |
| `Space` / `Enter` | Switch the selected widget off (or on, in the Available list) |
| `Esc` | Close |

## How it works, and what it touches

Omaseiton never edits `shell.json` itself. Every change goes through the same shell calls the `omarchy bar` and `omarchy plugin` commands use:

| Action | Call |
|---|---|
| Reorder / change lane | `omarchy-shell shell moveBarWidget <id> <placement>` |
| Switch off | `omarchy-shell shell setPluginEnabled <id> false` |
| Switch on | `omarchy-shell shell enablePlugin <id> {}` |
| Reset layout | `omarchy bar defaults` (needs a second click to confirm) |
| Browse / Add / Update | `omarchy-launch-webapp`, `omarchy-plugin-add`, `omarchy-plugin-update` |

Things worth knowing:

- **Switching a widget off removes its entry from the layout**, including inline settings such as the clock format. Omarchy does this, not Omaseiton. Switching it back on gives you the defaults.
- **The bar rebuilds after every change.** Omaseiton leaves a small marker file in `~/.local/state/omaseiton/` so the new instance reopens the dropdown. The marker is deleted straight away.
- Omaseiton will not offer to switch itself off.
- It does not use `sudo`, `systemctl`, the network, or bundled binaries.

## Develop

```bash
node tests/layout.test.js          # layout logic, no Quickshell needed
omarchy plugin validate .          # manifest check
```

The layout and move logic lives in [`Layout.js`](Layout.js) and is tested on its own. The UI is in [`Deck.qml`](Deck.qml) (the dropdown) and [`BarWidget.qml`](BarWidget.qml) (the bar icon).

## Roadmap

- Per-widget settings from each plugin's declared schema
- Undo for layout changes
- Clone, open folder and remove actions per row
- "Update available" badges
- Drag and drop (Omarchy's bar already supports dragging icons directly)

## License

[MIT](LICENSE)
