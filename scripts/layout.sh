#!/bin/bash

# Omaseiton layout snapshots: save the bar layout, list snapshots, restore one,
# or return to the stock Omarchy bar. A snapshot is taken automatically before
# every restore, and before "My layout" is overwritten, so nothing is lost.
#
# Usage:
#   layout.sh save mine          save the current bar as "My layout"
#   layout.sh list               JSON array of saved snapshots, newest first
#   layout.sh restore <slot>     put a snapshot back (mine, or auto-YYYYMMDD-HHMMSS-NNNNNNNNN)
#   layout.sh defaults           the stock Omarchy bar (snapshot taken first)
#
# What a snapshot holds, and what a restore changes in shell.json, is exactly:
#   bar.layout, bar.position, bar.transparent, bar.centerAnchor
# It never touches bar.id (which bar plugin is active), the plugins list,
# disabledPlugins, idle settings, or anything else.
#
# Snapshots live in ~/.config/omaseiton/layouts/<slot>.json. A restore replaces
# shell.json atomically (the file is replaced through its symlink target, in its
# own directory, keeping its permissions), then asks the shell to reload it.
#
# Omaseiton always stays on the bar: if a restored layout (or the Omarchy
# default) does not include it, it is put back exactly where it was, in the same
# write, so the way to undo a restore is never taken away.

set -euo pipefail

CONFIG_FILE="${OMASEITON_CONFIG_FILE:-$HOME/.config/omarchy/shell.json}"
LAYOUT_DIR="${OMASEITON_LAYOUT_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/omaseiton/layouts}"
KEEP_AUTO=5

# This plugin's own id, read from the manifest next to the scripts folder.
SELF_ID="${OMASEITON_ID:-$(jq -r '.id // empty' "$(dirname "${BASH_SOURCE[0]}")/../manifest.json" 2>/dev/null || true)}"
SELF_ID="${SELF_ID:-io.github.p-clements.omaseiton}"

# The bar keys a snapshot holds and a restore applies. Nothing else.
JQ_BAR_SUBSET='{position, transparent, centerAnchor, layout} | with_entries(select(.value != null))'

# Insert {id: $id} at $spot (section + index) unless a lane already has it.
# Only the three lanes are inspected, so an odd extra key under bar.layout, or a
# lane that is not a list, cannot break this.
# shellcheck disable=SC2016  # $id and $spot are jq variables, not shell ones
JQ_ENSURE='def entry_id: if type == "object" then .id else . end;
def ensure($id; $spot):
  if ([.bar.layout | (.left, .center, .right) | arrays | .[] | entry_id] | index($id)) != null then .
  else ((.bar.layout[$spot.section] | if type == "array" then . else [] end) as $lane
    | .bar.layout[$spot.section] = ($lane[0:$spot.index] + [{id: $id}] + $lane[$spot.index:]))
  end;'

JQ_LAYOUT_OK='(.bar.layout.left | type == "array") and (.bar.layout.center | type == "array") and (.bar.layout.right | type == "array")'

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

# Leave the breadcrumb that makes the rebuilt bar reopen the dropdown on the
# right monitor. The dropdown asks for this by exporting OMASEITON_REOPEN_FLAG.
touch_reopen() {
  [[ -n ${OMASEITON_REOPEN_FLAG:-} ]] || return 0
  mkdir -p "$(dirname "$OMASEITON_REOPEN_FLAG")" 2>/dev/null || return 0
  printf '%s' "${OMASEITON_REOPEN_SCREEN:-}" >"$OMASEITON_REOPEN_FLAG" 2>/dev/null || true
}

valid_slot() {
  [[ $1 =~ ^(mine|auto-[0-9]{8}-[0-9]{6}(-[0-9]{1,9})?)$ ]]
}

# Where Omaseiton sits on the bar right now: {"section": ..., "index": ...}.
# Falls back to the start of the right lane if it is not on the bar.
self_spot() {
  live_config | jq -c --arg id "$SELF_ID" '
    . as $c
    | [["left", "center", "right"][] as $s
       | ($c.bar.layout[$s] | if type == "array" then . else [] end) | to_entries[]
       | select((if (.value | type) == "object" then .value.id else .value end) == $id)
       | {section: $s, index: .key}]
    | .[0] // {section: "right", index: 0}' 2>/dev/null || echo '{"section":"right","index":0}'
}

# Write the live bar to a snapshot file, atomically. Refuses to save anything
# that does not look like a bar layout, so a broken read can never replace a
# good snapshot. $1 is the slot, $2 the reason ("save" / "restore").
snapshot() {
  local slot="$1" reason="$2" tmp
  valid_slot "$slot" || fail "invalid slot '$slot'"
  mkdir -p "$LAYOUT_DIR"
  tmp=$(mktemp "$LAYOUT_DIR/.tmp.XXXXXX")
  if ! live_config | jq -S --arg reason "$reason" "{savedAt: (now | todate), reason: \$reason, bar: (.bar | $JQ_BAR_SUBSET)}" >"$tmp" 2>/dev/null ||
    ! jq -e "$JQ_LAYOUT_OK" "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"
    fail "could not read the current bar layout; nothing was saved"
  fi
  mv "$tmp" "$LAYOUT_DIR/$slot.json"
}

# A new automatic slot name. Fixed-width nanoseconds make names sort by time, and
# a name is never reused, so a burst of snapshots can never overwrite each other.
auto_slot() {
  local slot
  slot="auto-$(date +%Y%m%d-%H%M%S-%N)"
  while [[ -e $LAYOUT_DIR/$slot.json ]]; do
    slot="auto-$(date +%Y%m%d-%H%M%S-%N)"
  done
  printf '%s\n' "$slot"
}

# Keep the newest KEEP_AUTO automatic snapshots. Only called after a restore has
# succeeded, so failures can never push real history out. Names are compared
# without ".json", so the newest always sorts first.
prune_auto() {
  local slot
  while IFS= read -r slot; do
    rm -f -- "$LAYOUT_DIR/$slot.json"
  done < <(find "$LAYOUT_DIR" -maxdepth 1 -name 'auto-*.json' -printf '%f\n' 2>/dev/null |
    sed 's/\.json$//' | sort -r | tail -n +"$((KEEP_AUTO + 1))")
}

# Replace shell.json atomically. If it is a symlink (a dotfiles repo, say), the
# file it points at is replaced and the link is left alone. The new file is made
# in the same directory and keeps the old file's permissions.
write_config() {
  local new="$1" real
  real=$(readlink -f "$CONFIG_FILE")
  chmod --reference="$real" "$new" 2>/dev/null || chmod 600 "$new"
  mv "$new" "$real"
}

# Apply a saved bar: $1 is JSON {"bar": {...}}, $2 the reason for the safety snapshot.
apply_bar() {
  local saved="$1" reason="$2" spot snap tmp real
  jq -e "$JQ_LAYOUT_OK" <<<"$saved" >/dev/null 2>&1 || fail "that is not a valid layout"
  spot=$(self_spot)

  # Safety net first. If this fails we stop: never restore without a way back.
  snap=$(auto_slot)
  snapshot "$snap" "$reason"

  [[ -f $CONFIG_FILE ]] || { mkdir -p "$(dirname "$CONFIG_FILE")" && echo '{"version":1}' >"$CONFIG_FILE"; }
  real=$(readlink -f "$CONFIG_FILE")
  tmp=$(mktemp "$real.XXXXXX") || {
    rm -f "$LAYOUT_DIR/$snap.json"
    fail "cannot write next to $real; your bar is unchanged"
  }
  if ! jq -S --argjson saved "$saved" --arg id "$SELF_ID" --argjson spot "$spot" \
    "$JQ_ENSURE .bar = (((.bar // {}) | del(.position, .transparent, .centerAnchor, .layout)) + (\$saved.bar | $JQ_BAR_SUBSET))
      | ensure(\$id; \$spot)" "$real" >"$tmp" 2>/dev/null; then
    rm -f "$tmp" "$LAYOUT_DIR/$snap.json"
    fail "could not apply the layout; your bar is unchanged"
  fi
  touch_reopen
  write_config "$tmp" || {
    rm -f "$tmp" "$LAYOUT_DIR/$snap.json"
    fail "could not replace $real; your bar is unchanged"
  }

  prune_auto
  reload_shell
}

cmd_save() {
  local slot="${1:-}" backup
  [[ $slot == "mine" ]] || fail "only the 'mine' slot can be saved by hand"
  # Saving replaces "My layout", so keep the version being replaced.
  if [[ -f $LAYOUT_DIR/mine.json ]]; then
    backup=$(auto_slot)
    if jq -S '.reason = "save"' "$LAYOUT_DIR/mine.json" >"$LAYOUT_DIR/.tmp.backup.$$" 2>/dev/null; then
      mv "$LAYOUT_DIR/.tmp.backup.$$" "$LAYOUT_DIR/$backup.json"
    else
      rm -f "$LAYOUT_DIR/.tmp.backup.$$"
    fi
  fi
  snapshot mine save
  prune_auto
  echo "Saved your layout"
}

cmd_list() {
  mkdir -p "$LAYOUT_DIR"
  local slot
  local -a rows=()
  while IFS= read -r slot; do
    valid_slot "$slot" || continue
    rows+=("$(jq -c --arg slot "$slot" '{slot: $slot, savedAt: (.savedAt // ""), reason: (.reason // ""), widgets: ([.bar.layout | (.left, .center, .right) | arrays | length] | add // 0)}' "$LAYOUT_DIR/$slot.json" 2>/dev/null)") || true
  done < <(find "$LAYOUT_DIR" -maxdepth 1 -name '*.json' -printf '%f\n' 2>/dev/null | sed 's/\.json$//' | sort -r)
  if ((${#rows[@]} == 0)); then
    echo "[]"
  else
    printf '%s\n' "${rows[@]}" | jq -s '.'
  fi
}

cmd_restore() {
  local slot="${1:-}" file saved
  valid_slot "$slot" || fail "invalid slot '$slot'"
  file="$LAYOUT_DIR/$slot.json"
  [[ -f $file ]] || fail "no saved layout '$slot'"
  # Read it into memory first: the snapshot taken below can prune old ones,
  # including this one, and the restore must not depend on the file still being there.
  saved=$(cat "$file") || fail "cannot read '$slot'"
  apply_bar "$saved" restore
  echo "Restored $slot"
}

# The stock bar, worked out the way `omarchy bar defaults` does it (including
# optional widgets for installed services) but in a throwaway home directory, so
# the real config is not written until our own single, safe write.
stock_bar() {
  local tmp_home out defaults
  tmp_home=$(mktemp -d)
  if HOME="$tmp_home" omarchy bar defaults >/dev/null 2>&1 && [[ -s $tmp_home/.config/omarchy/shell.json ]]; then
    out=$(jq -c '{bar: .bar}' "$tmp_home/.config/omarchy/shell.json" 2>/dev/null || true)
  fi
  rm -rf "$tmp_home"
  if [[ -z ${out:-} ]]; then
    defaults="${OMARCHY_PATH:-/usr/share/omarchy}/config/omarchy/shell.json"
    out=$(jq -c '{bar: .bar}' "$defaults" 2>/dev/null || true)
  fi
  [[ -n $out ]] || fail "could not work out the Omarchy default bar"
  printf '%s\n' "$out"
}

cmd_defaults() {
  local stock
  stock=$(stock_bar)
  apply_bar "$stock" restore
  echo "Restored the Omarchy default bar"
}

case "${1:-}" in
  save)
    shift
    cmd_save "$@"
    ;;
  list) cmd_list ;;
  restore)
    shift
    cmd_restore "$@"
    ;;
  defaults) cmd_defaults ;;
  *) fail "usage: layout.sh <save mine | list | restore <slot> | defaults>" ;;
esac
