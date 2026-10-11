# Artwork and build notes

The banner artwork and raster emblem were generated with ChatGPT image generation using [prompt.txt](prompt.txt). The name, kanji and tagline were added as vector text in the SVG sources. The small bar and panel emblem is drawn separately in [Emblem.qml](../../Emblem.qml) so it stays legible and follows the desktop theme.

The banner and preview use Noto Serif CJK JP, JetBrains Mono (Nerd Font build) and Geist, under the SIL Open Font License. These fonts render the images and are not bundled with the plugin.

Rebuild from the repository root with:

```bash
bash assets/src/build-banner.sh
bash assets/src/build-preview.sh
```

The build scripts require ImageMagick, librsvg's `rsvg-convert`, and the fonts above. The preview uses the current panel render in `docs/panel.png`. Screenshot provenance is documented in [docs/SCREENSHOTS.md](../../docs/SCREENSHOTS.md).
