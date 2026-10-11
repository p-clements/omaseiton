# Security

## Reporting a problem

Please report security problems **privately**, not in a public issue: use GitHub's "Report a vulnerability" button on the repository's Security tab.
You will get an answer as soon as I can give one. This is a personal project, so there is no formal response time.

## What kind of software this is

Omaseiton is an Omarchy shell plugin. **Omarchy plugins are not sandboxed**: they run as your user and can read and change anything you can. Omaseiton asks for nothing beyond that, but you should read the code before installing any plugin, this one included. It is small: the logic is in [`Layout.js`](Layout.js), the interface in [`Deck.qml`](Deck.qml) and [`BarWidget.qml`](BarWidget.qml), and the only two scripts are [`scripts/layout.sh`](scripts/layout.sh) and [`scripts/update.sh`](scripts/update.sh).

[What it touches](README.md#what-it-touches) lists every file it writes and every command it runs, and each of those statements has a test.

## What it is designed to withstand

Other plugins' manifests, other plugins' git folders, and the files Omaseiton itself keeps are all treated as untrusted data:

- **Names and ids from other plugins** are shown as plain text, passed to commands as separate arguments (never joined into a shell string), and checked against a strict pattern where they become file names.
- **Saved layouts** can contain anything, so a restore applies only four settings (`bar.layout`, `bar.position`, `bar.transparent`, `bar.centerAnchor`) and ignores the rest. A planted snapshot cannot switch the active bar plugin or enable a plugin.
- **Slot names** (the names of saved layouts) must match a fixed pattern; `../`, newlines and unknown names are refused, including when a file with such a name exists.
- **Updating other plugins** applies exactly the commit that was shown, and runs git with hooks, filesystem-monitor programs and every transport outside `https`, `ssh`, `git` and `file` disabled, so a hostile `.git/config` in a plugin folder cannot run code through Omaseiton.
- **Writing `shell.json`** is atomic, keeps the file's permissions, follows a symlink to its target instead of replacing the link, and never happens without a safety snapshot first.
- **Private inline settings** in saved layouts are passed to `jq` through stdin during restore, never through process arguments visible to other local users.

## What it is not designed to withstand

- Anything that can already run code as you. That includes any other installed plugin: it can read and change Omaseiton's files and `shell.json` directly.
- A hostile `OMASEITON_*` environment variable. Those variables exist only so the tests can point the scripts at scratch files.

## How that is checked

The tests live in [`tests/`](tests). The shell tests run in a sandbox (a scratch `HOME`, guard commands that refuse to run `omarchy` for real, and a canary on your real `shell.json`), and a mutation check deliberately breaks the code to prove the tests notice. CI also runs the Omarchy plugin marketplace's own security scanner against this repository, pinned to a specific version of that scanner.
