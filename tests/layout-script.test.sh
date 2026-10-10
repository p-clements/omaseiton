#!/bin/bash
# Tests for scripts/layout.sh against temp files. No running shell needed.
# Run with: bash tests/layout-script.test.sh

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../scripts/layout.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export OMASEITON_CONFIG_FILE="$WORK/shell.json"
export OMASEITON_LAYOUT_DIR="$WORK/layouts"
export OMASEITON_LIVE_FILE="$WORK/live.json"
export OMASEITON_NO_RELOAD=1

pass=0
check() {
  local name="$1"
  shift
  if "$@"; then
    pass=$((pass + 1))
  else
    echo "FAIL: $name" >&2
    exit 1
  fi
}

jq_eq() { [[ $(jq -c "$2" "$1") == "$3" ]]; }

# --- a "live" layout with third-party widgets, a tray pin and a settings blob
cat >"$OMASEITON_LIVE_FILE" <<'EOF'
{"version":1,"bar":{"position":"top","transparent":true,"layout":{
  "left":[{"id":"a.menu"}],
  "center":[{"id":"a.clock","format":"HH:mm"},{"id":"x.radar"}],
  "right":[{"id":"a.tray","pinned":["1Password_status_icon_1"]}]}},
 "plugins":[]}
EOF
# the on-disk config differs (e.g. already reset to defaults)
cat >"$OMASEITON_CONFIG_FILE" <<'EOF'
{"version":1,"idle":{"lock":300},"bar":{"transparent":false,"layout":{"left":[],"center":[{"id":"a.clock"}],"right":[]}},"plugins":[]}
EOF

# save
bash "$SCRIPT" save mine >/dev/null
check "save writes mine.json" test -f "$OMASEITON_LAYOUT_DIR/mine.json"
check "save keeps third-party widgets" jq_eq "$OMASEITON_LAYOUT_DIR/mine.json" '.bar.layout.center | map(.id)' '["a.clock","x.radar"]'
check "save keeps widget settings" jq_eq "$OMASEITON_LAYOUT_DIR/mine.json" '.bar.layout.right[0].pinned' '["1Password_status_icon_1"]'
check "save stamps a time" jq -e '.savedAt | length > 0' "$OMASEITON_LAYOUT_DIR/mine.json" >/dev/null
check "no temp files left" test -z "$(find "$OMASEITON_LAYOUT_DIR" -name '.tmp.*')"

# only 'mine' can be saved by hand
check "rejects other slot names" bash -c "! bash '$SCRIPT' save ../evil 2>/dev/null"
check "rejects auto slot by hand" bash -c "! bash '$SCRIPT' save auto-20260101-000000 2>/dev/null"

# a broken read must never overwrite a good snapshot
cp "$OMASEITON_LAYOUT_DIR/mine.json" "$WORK/mine.before"
echo 'not json' >"$OMASEITON_LIVE_FILE.bad"
OMASEITON_LIVE_FILE="$OMASEITON_LIVE_FILE.bad" bash "$SCRIPT" save mine 2>/dev/null && { echo "FAIL: bad read saved"; exit 1; }
check "bad read leaves snapshot untouched" cmp -s "$OMASEITON_LAYOUT_DIR/mine.json" "$WORK/mine.before"
echo '{"bar":{}}' >"$OMASEITON_LIVE_FILE.empty"
OMASEITON_LIVE_FILE="$OMASEITON_LIVE_FILE.empty" bash "$SCRIPT" save mine 2>/dev/null && { echo "FAIL: empty layout saved"; exit 1; }
check "layout without lanes is refused" cmp -s "$OMASEITON_LAYOUT_DIR/mine.json" "$WORK/mine.before"

# restore: applies the layout, keeps unrelated keys, snapshots first
bash "$SCRIPT" restore mine >/dev/null
check "restore brings back widgets" jq_eq "$OMASEITON_CONFIG_FILE" '.bar.layout.center | map(.id)' '["a.clock","x.radar"]'
check "restore brings back transparency" jq_eq "$OMASEITON_CONFIG_FILE" '.bar.transparent' 'true'
check "restore keeps unrelated config" jq_eq "$OMASEITON_CONFIG_FILE" '.idle.lock' '300'
check "restore left an automatic snapshot" test "$(find "$OMASEITON_LAYOUT_DIR" -name 'auto-*.json' | wc -l)" -eq 1
auto_file="$(find "$OMASEITON_LAYOUT_DIR" -name 'auto-*.json' | head -n1)"
check "the snapshot holds what was live before" jq_eq "$auto_file" '.bar.layout.center | map(.id)' '["a.clock","x.radar"]'

# restore of something that does not exist changes nothing
cp "$OMASEITON_CONFIG_FILE" "$WORK/config.before"
check "unknown slot fails" bash -c "! bash '$SCRIPT' restore auto-20200101-000000 2>/dev/null"
check "unknown slot changes nothing" cmp -s "$OMASEITON_CONFIG_FILE" "$WORK/config.before"
check "bad slot name fails" bash -c "! bash '$SCRIPT' restore '../../etc/passwd' 2>/dev/null"

# a corrupt snapshot is refused and the config is untouched
echo '{"bar":{"layout":{"left":1}}}' >"$OMASEITON_LAYOUT_DIR/auto-20200101-000000.json"
check "corrupt snapshot refused" bash -c "! bash '$SCRIPT' restore auto-20200101-000000 2>/dev/null"
check "corrupt snapshot changes nothing" cmp -s "$OMASEITON_CONFIG_FILE" "$WORK/config.before"
rm -f "$OMASEITON_LAYOUT_DIR/auto-20200101-000000.json"

# only the newest KEEP_AUTO automatic snapshots are kept
for i in 1 2 3 4 5 6 7 8; do
  printf '{"savedAt":"x","bar":{"layout":{"left":[],"center":[],"right":[]}}}' >"$OMASEITON_LAYOUT_DIR/auto-2020010$i-000000.json"
done
bash "$SCRIPT" restore mine >/dev/null
check "old automatic snapshots are pruned" test "$(find "$OMASEITON_LAYOUT_DIR" -name 'auto-*.json' | wc -l)" -eq 5
check "mine is never pruned" test -f "$OMASEITON_LAYOUT_DIR/mine.json"
check "oldest were the ones dropped" test ! -f "$OMASEITON_LAYOUT_DIR/auto-20200101-000000.json"

# list
out="$(bash "$SCRIPT" list)"
check "list is a JSON array" jq -e 'type == "array"' <<<"$out" >/dev/null
check "list has mine" jq -e 'map(.slot) | index("mine") != null' <<<"$out" >/dev/null
check "list counts widgets" jq -e 'map(select(.slot == "mine"))[0].widgets == 4' <<<"$out" >/dev/null
check "list is newest first" jq -e '(map(.slot) | map(select(startswith("auto-"))) ) as $a | $a == ($a | sort | reverse)' <<<"$out" >/dev/null
rm -rf "$OMASEITON_LAYOUT_DIR"
check "empty list is []" test "$(bash "$SCRIPT" list)" = "[]"

echo "layout script tests passed ($pass checks)"
