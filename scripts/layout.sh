#!/bin/bash

# Omaseiton layout snapshots: save the bar layout, list snapshots, restore one,
# or return to the stock Omarchy bar. A snapshot is taken automatically before
# every restore, so nothing is ever lost.
#
# Usage:
#   layout.sh save mine          save the current bar as "My layout"
#   layout.sh list               JSON array of saved snapshots, newest first
#   layout.sh restore <slot>     put a snapshot back (mine, or auto-YYYYMMDD-HHMMSS)
#   layout.sh defaults           stock Omarchy bar (snapshot taken first)
#
# Snapshots live in ~/.config/omaseiton/layouts/<slot>.json. Restoring writes
# ~/.config/omarchy/shell.json atomically, the same way `omarchy bar` does,
# then asks the shell to reload it.

set -euo pipefail

CONFIG_FILE="${OMASEITON_CONFIG_FILE:-$HOME/.config/omarchy/shell.json}"
LAYOUT_DIR="${OMASEITON_LAYOUT_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/omaseiton/layouts}"
KEEP_AUTO=5

fail() {
  echo "layout.sh: $*" >&2
  exit 1
}

# The running shell's own view of its config (what the user sees right now).
live_config() {
  if [[ -n ${OMASEITON_LIVE_FILE:-} ]]; then
    cat "$OMASEITON_LIVE_FILE"
  else
    omarchy-shell shell listShellConfig
  fi
}

reload_shell() {
  [[ -n ${OMASEITON_NO_RELOAD:-} ]] && return 0
  omarchy-shell shell reloadConfig >/dev/null 2>&1 || omarchy-shell -q shell rescanPlugins >/dev/null 2>&1 || true
}

valid_slot() {
  [[ $1 =~ ^(mine|auto-[0-9]{8}-[0-9]{6}(-[0-9]+)?)$ ]]
}

# Write the live layout to a slot, atomically. Refuses to save anything that
# does not look like a bar layout, so a broken read can never overwrite a good
# snapshot.
snapshot() {
  local slot="$1" tmp
  valid_slot "$slot" || fail "invalid slot '$slot'"
  mkdir -p "$LAYOUT_DIR"
  tmp=$(mktemp "$LAYOUT_DIR/.tmp.XXXXXX")
  if ! live_config | jq -S '{savedAt: (now | todate), bar: .bar, plugins: (.plugins // [])}' >"$tmp" 2>/dev/null ||
    ! jq -e '(.bar.layout.left | type == "array") and (.bar.layout.center | type == "array") and (.bar.layout.right | type == "array")' "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"
    fail "could not read the current bar layout; nothing was saved"
  fi
  mv "$tmp" "$LAYOUT_DIR/$slot.json"
}

auto_slot() {
  local base slot n=0
  base="auto-$(date +%Y%m%d-%H%M%S)"
  slot="$base"
  while [[ -e $LAYOUT_DIR/$slot.json ]]; do
    n=$((n + 1))
    slot="$base-$n"
  done
  printf '%s\n' "$slot"
}

prune_auto() {
  local file
  # Newest first by name (timestamps sort lexically); drop everything past KEEP_AUTO.
  while IFS= read -r file; do
    rm -f -- "$file"
  done < <(find "$LAYOUT_DIR" -maxdepth 1 -name 'auto-*.json' -printf '%f\n' 2>/dev/null |
    sort -r | tail -n +"$((KEEP_AUTO + 1))" | sed "s|^|$LAYOUT_DIR/|")
}

cmd_save() {
  local slot="${1:-}"
  [[ $slot == "mine" ]] || fail "only the 'mine' slot can be saved by hand"
  snapshot mine
  echo "Saved your layout"
}

cmd_list() {
  mkdir -p "$LAYOUT_DIR"
  local file slot
  local -a rows=()
  while IFS= read -r slot; do
    file="$LAYOUT_DIR/$slot.json"
    valid_slot "$slot" || continue
    rows+=("$(jq -c --arg slot "$slot" '{slot: $slot, savedAt: (.savedAt // ""), widgets: ([.bar.layout.left, .bar.layout.center, .bar.layout.right] | map(length) | add)}' "$file" 2>/dev/null)") || true
  done < <(find "$LAYOUT_DIR" -maxdepth 1 -name '*.json' -printf '%f\n' 2>/dev/null | sed 's/\.json$//' | sort -r)
  if ((${#rows[@]} == 0)); then
    echo "[]"
  else
    printf '%s\n' "${rows[@]}" | jq -s '.'
  fi
}

cmd_restore() {
  local slot="${1:-}" file tmp
  valid_slot "$slot" || fail "invalid slot '$slot'"
  file="$LAYOUT_DIR/$slot.json"
  [[ -f $file ]] || fail "no saved layout '$slot'"
  jq -e '(.bar.layout.left | type == "array") and (.bar.layout.center | type == "array") and (.bar.layout.right | type == "array")' "$file" >/dev/null 2>&1 ||
    fail "'$slot' is not a valid layout"

  # Safety net first. If this fails we stop: never restore without a way back.
  snapshot "$(auto_slot)"
  prune_auto

  [[ -f $CONFIG_FILE ]] || echo '{"version":1}' >"$CONFIG_FILE"
  tmp=$(mktemp "$CONFIG_FILE.XXXXXX")
  if ! jq -S --slurpfile saved "$file" '.version = 1 | .bar = $saved[0].bar | .plugins = ($saved[0].plugins // [])' "$CONFIG_FILE" >"$tmp"; then
    rm -f "$tmp"
    fail "could not apply '$slot'; your bar is unchanged"
  fi
  mv "$tmp" "$CONFIG_FILE"
  reload_shell
  echo "Restored $slot"
}

cmd_defaults() {
  snapshot "$(auto_slot)"
  prune_auto
  omarchy bar defaults
}

case "${1:-}" in
  save) shift; cmd_save "$@" ;;
  list) cmd_list ;;
  restore) shift; cmd_restore "$@" ;;
  defaults) cmd_defaults ;;
  *) fail "usage: layout.sh <save mine | list | restore <slot> | defaults>" ;;
esac
