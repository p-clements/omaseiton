# Screenshots

The README includes the images below. The panel and layout images render the actual QML with the current live plugin list in an isolated window; the bar image is a cropped live desktop capture. Theme comparison renders use stock palettes without changing the desktop theme.

| File                        | What it shows                                                      |
| --------------------------- | ------------------------------------------------------------------ |
| `docs/panel.png`            | Native dropdown with plugins grouped by lane and inline controls   |
| `docs/layouts.png`          | Layouts expanded, showing Omarchy default and the saved My layout  |
| `docs/bar.png`              | Live Omarchy bar with Omaseiton's open-circle-and-lanes emblem     |
| `docs/themes.png`           | The same dropdown in Tokyo Night and Catppuccin Latte              |
| `preview.png`               | Marketplace preview built from the emblem and current panel render |
| `docs/demo.gif`             | A 30-second walkthrough: reorder, switch off, save, restore        |
| `assets/social-preview.png` | 1280 x 640 image for GitHub's Settings > Social preview            |

No open application content is included in the live bar capture.

**How the demo clip was made.** The real `Deck.qml` and `scripts/layout.sh` run against a simulated bar: Omarchy's stock layout held in a scratch file, with a stand-in for `omarchy-shell` that applies moves to that file. A scripted timeline presses the dropdown's own keys, and every frame is rendered offscreen straight from the Qt scene, so no real screen is captured and no real bar or saved layout is touched (a checksum of the real `shell.json` and layouts folder is compared before and after). The behaviour is real; the bar is simulated.
