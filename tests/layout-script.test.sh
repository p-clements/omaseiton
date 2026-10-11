#!/bin/bash
# Tests for scripts/layout.sh against temp files. No running shell needed.
# Run with: bash tests/layout-script.test.sh

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${LAYOUT_SH:-$HERE/../scripts/layout.sh}"
# ---------------------------------------------------------------------------
# SAFETY. These tests, and the mutated scripts the mutation check feeds them,
# must never be able to touch the real home directory, the real shell.json or
# the running shell. A mutant once did exactly that, so three layers guard it:
#   1. HOME is a scratch folder for the whole run;
#   2. `omarchy` and `omarchy-shell` are guard commands that refuse to run, unless
#      a test puts its own stub first (and the stubs refuse to run outside scratch);
#   3. a canary: the real shell.json's checksum is compared before and after, and
#      the run FAILS if it changed.
# ---------------------------------------------------------------------------
REAL_CONFIG="$HOME/.config/omarchy/shell.json"
canary_before="$(sha256sum "$REAL_CONFIG" 2>/dev/null || echo absent)"
WORK="$(mktemp -d)"
export HOME="$WORK/home"
export TMPDIR="$WORK/tmp"
mkdir -p "$HOME" "$WORK/guard" "$TMPDIR"
unset XDG_CONFIG_HOME XDG_STATE_HOME
for guarded in omarchy omarchy-shell; do
  printf '#!/bin/bash\necho "FORBIDDEN in tests: %s $*" >&2\nexit 97\n' "$guarded" >"$WORK/guard/$guarded"
  chmod +x "$WORK/guard/$guarded"
done
export PATH="$WORK/guard:$PATH"
finish() {
  local status=$?
  chmod -R u+rwx "$WORK" 2>/dev/null
  rm -rf "$WORK"
  if [[ "$(sha256sum "$REAL_CONFIG" 2>/dev/null || echo absent)" != "$canary_before" ]]; then
    echo "CANARY: the real shell.json CHANGED during this test run. Something escaped the sandbox." >&2
    status=1
  fi
  exit "$status"
}
trap finish EXIT

export OMASEITON_ID="x.me"
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
fails() { ! "$@"; }
jq_ok() { jq -e "$2" "$1" >/dev/null 2>&1; }

# every scenario gets its own directory, so one cannot affect another
fresh() {
  SCEN="$WORK/$1"
  rm -rf "$SCEN"
  mkdir -p "$SCEN"
  export OMASEITON_CONFIG_FILE="$SCEN/shell.json"
  export OMASEITON_LAYOUT_DIR="$SCEN/layouts"
  export OMASEITON_LIVE_FILE="$SCEN/live.json"
  unset OMASEITON_REOPEN_FLAG OMASEITON_REOPEN_SCREEN
}
run() { bash "$SCRIPT" "$@"; }

# a live bar: third-party widgets, a tray pin, a settings blob, Omaseiton second on the right
write_live() {
  cat >"$OMASEITON_LIVE_FILE" <<'EOF'
{"version":1,"bar":{"id":"live.bar","position":"top","transparent":true,"centerAnchor":"a.clock","layout":{
  "left":[{"id":"a.menu"}],
  "center":[{"id":"a.clock","format":"HH:mm"},{"id":"x.radar"}],
  "right":[{"id":"a.tray","pinned":["1Password_status_icon_1"]},{"id":"x.me"}]}},
 "plugins":[{"id":"live.plugin"}]}
EOF
}
# an on-disk config with unrelated settings that a restore must never touch
write_config() {
  cat >"$OMASEITON_CONFIG_FILE" <<'EOF'
{"version":1,"idle":{"lock":300},"disabledPlugins":["old.plugin"],"plugins":[{"id":"keep.plugin","setting":1}],
 "bar":{"id":"keep.bar","transparent":false,"layout":{"left":[],"center":[{"id":"a.clock"}],"right":[]}}}
EOF
}
slots() { bash "$SCRIPT" list | jq -r '.[].slot'; }
newest_auto() { bash "$SCRIPT" list | jq -r 'map(select(.slot | startswith("auto-")))[0].slot'; }

# ---------------------------------------------------------------- save
fresh save
write_live
write_config
run save mine >/dev/null
M="$OMASEITON_LAYOUT_DIR/mine.json"
check "save writes mine.json" test -f "$M"
check "save keeps third-party widgets" jq_ok "$M" '[.bar.layout.center[].id] == ["a.clock","x.radar"]'
check "save keeps widget settings" jq_ok "$M" '.bar.layout.right[0].pinned == ["1Password_status_icon_1"]'
check "save keeps position, transparency and anchor" jq_ok "$M" '.bar.position == "top" and .bar.transparent == true and .bar.centerAnchor == "a.clock"'
check "save does NOT keep which bar plugin is active" jq_ok "$M" '.bar | has("id") | not'
check "save does NOT keep the plugins list" jq_ok "$M" 'has("plugins") | not'
check "save stamps a time and a reason" jq_ok "$M" '(.savedAt | length > 0) and .reason == "save"'
check "no temp files are left behind" test -z "$(find "$OMASEITON_LAYOUT_DIR" -name '.tmp.*')"
check "first save makes no backup" test "$(slots | grep -c '^auto-' || true)" -eq 0

# saving again keeps the version being replaced
cp "$M" "$SCEN/mine.v1"
sed -i 's/HH:mm/HH:mm:ss/' "$OMASEITON_LIVE_FILE"
run save mine >/dev/null
check "second save replaces My layout" jq_ok "$M" '.bar.layout.center[0].format == "HH:mm:ss"'
check "second save keeps the old one as an automatic backup" test "$(slots | grep -c '^auto-')" -eq 1
backup="$OMASEITON_LAYOUT_DIR/$(newest_auto).json"
check "the backup is the version that was replaced" jq_ok "$backup" '.bar.layout.center[0].format == "HH:mm" and .reason == "save"'

# only 'mine' can be saved by hand; other names are refused
check "rejects path-like slot names" fails bash "$SCRIPT" save ../evil
check "rejects auto slot by hand" fails bash "$SCRIPT" save auto-20260101-000000
check "rejects empty slot" fails bash "$SCRIPT" save ""

# a broken read must never replace a good snapshot
cp "$M" "$SCEN/mine.before"
echo 'not json' >"$SCEN/bad.json"
check "unreadable live config is refused" fails env OMASEITON_LIVE_FILE="$SCEN/bad.json" bash "$SCRIPT" save mine
echo '{"bar":{}}' >"$SCEN/nolanes.json"
check "a bar without lanes is refused" fails env OMASEITON_LIVE_FILE="$SCEN/nolanes.json" bash "$SCRIPT" save mine
check "refused saves leave the snapshot untouched" cmp -s "$M" "$SCEN/mine.before"

# ---------------------------------------------------------------- restore
fresh restore
write_live
write_config
run save mine >/dev/null
M="$OMASEITON_LAYOUT_DIR/mine.json"
# a hostile snapshot: tries to switch the bar plugin, enable a plugin, and smuggle keys in
jq '.bar.id = "evil.bar" | .plugins = [{"id":"evil.keylogger"}] | .disabledPlugins = ["x"] | .idle = {"lock": 1} | .bar.layout.extra = 5' "$M" >"$SCEN/hostile.json"
cp "$SCEN/hostile.json" "$M"
run restore mine >/dev/null
C="$OMASEITON_CONFIG_FILE"
check "restore applies the lanes" jq_ok "$C" '[.bar.layout.center[].id] == ["a.clock","x.radar"]'
check "restore applies transparency, position and anchor" jq_ok "$C" '.bar.transparent == true and .bar.position == "top" and .bar.centerAnchor == "a.clock"'
check "restore keeps which bar plugin is active" jq_ok "$C" '.bar.id == "keep.bar"'
check "restore ignores a hostile bar.id" jq_ok "$C" '.bar.id != "evil.bar"'
check "restore keeps the plugins list as it was" jq_ok "$C" '.plugins == [{"id":"keep.plugin","setting":1}]'
check "restore keeps disabledPlugins" jq_ok "$C" '.disabledPlugins == ["old.plugin"]'
check "restore keeps unrelated settings" jq_ok "$C" '.idle.lock == 300'
check "restore leaves an automatic snapshot of what was live" test "$(slots | grep -c '^auto-')" -eq 1
check "that snapshot says why" jq_ok "$OMASEITON_LAYOUT_DIR/$(newest_auto).json" '.reason == "restore"'
check "an odd extra key under bar.layout does not break restore" jq_ok "$C" '.bar.layout | has("left")'

# unknown, malformed and corrupt things change nothing
cp "$C" "$SCEN/config.before"
check "unknown slot fails" fails bash "$SCRIPT" restore auto-20200101-000000
check "path-like slot fails" fails bash "$SCRIPT" restore '../../etc/passwd'
check "slot with a newline fails" fails bash "$SCRIPT" restore $'mine\nx'
printf '{"bar":{"layout":{"left":1}}}' >"$OMASEITON_LAYOUT_DIR/auto-20200101-000000.json"
check "a corrupt snapshot is refused" fails bash "$SCRIPT" restore auto-20200101-000000
check "none of those changed the config" cmp -s "$C" "$SCEN/config.before"
rm -f "$OMASEITON_LAYOUT_DIR/auto-20200101-000000.json"

# a restore sets the bar's settings to the snapshot's, including "no anchor"
fresh anchor
write_live
cat >"$OMASEITON_CONFIG_FILE" <<'EOF'
{"version":1,"bar":{"position":"bottom","transparent":true,"centerAnchor":"stale.anchor","layout":{"left":[],"center":[],"right":[]}}}
EOF
mkdir -p "$OMASEITON_LAYOUT_DIR"
printf '{"savedAt":"x","bar":{"layout":{"left":[],"center":[{"id":"a.clock"}],"right":[]}}}' >"$OMASEITON_LAYOUT_DIR/mine.json"
run restore mine >/dev/null
check "a snapshot without an anchor removes the old anchor" jq_ok "$OMASEITON_CONFIG_FILE" '.bar | has("centerAnchor") | not'
check "a snapshot without a position removes the old position" jq_ok "$OMASEITON_CONFIG_FILE" '.bar | has("position") | not'
check "and without transparency, the old setting is removed too" jq_ok "$OMASEITON_CONFIG_FILE" '.bar | has("transparent") | not'

# only slots that this script itself names are accepted, even if such a file exists
fresh names
write_live
write_config
mkdir -p "$OMASEITON_LAYOUT_DIR"
printf '{"savedAt":"x","bar":{"layout":{"left":[],"center":[{"id":"planted.w"}],"right":[]}}}' >"$OMASEITON_LAYOUT_DIR/auto-zzz.json"
cp "$OMASEITON_LAYOUT_DIR/auto-zzz.json" "$OMASEITON_LAYOUT_DIR/other.json"
check "a planted auto-* file with a made-up name is refused" fails bash "$SCRIPT" restore auto-zzz
check "a planted file with any other name is refused" fails bash "$SCRIPT" restore other
check "neither is listed" bash -c "[[ \$(bash '$SCRIPT' list) == '[]' ]]"
check "and nothing was applied" jq_ok "$OMASEITON_CONFIG_FILE" '[.bar.layout.center[].id] | index("planted.w") == null'

# string entries and an empty lane are fine
fresh strings
write_live
printf '{"version":1,"bar":{"layout":{"left":["a.menu"],"center":[],"right":[]}}}' >"$OMASEITON_CONFIG_FILE"
printf '{"savedAt":"x","bar":{"layout":{"left":["a.menu",{"id":"a.b"}],"center":[],"right":["a.tray"]}}}' >"$SCEN/s.json"
mkdir -p "$OMASEITON_LAYOUT_DIR" && cp "$SCEN/s.json" "$OMASEITON_LAYOUT_DIR/mine.json"
run restore mine >/dev/null
check "string and object entries are both accepted" jq_ok "$OMASEITON_CONFIG_FILE" '.bar.layout.left | length == 2'

# ---------------------------------------------------------------- Omaseiton stays on the bar
fresh self
write_live # x.me is second in the right lane
write_config
printf '{"savedAt":"x","bar":{"layout":{"left":[{"id":"a.menu"}],"center":[{"id":"a.clock"}],"right":[{"id":"a.tray"},{"id":"a.power"}]}}}' >"$SCEN/lacks-me.json"
mkdir -p "$OMASEITON_LAYOUT_DIR" && cp "$SCEN/lacks-me.json" "$OMASEITON_LAYOUT_DIR/mine.json"
run restore mine >/dev/null
check "self returns to the spot it was in" jq_ok "$OMASEITON_CONFIG_FILE" '[.bar.layout.right[].id] == ["a.tray","x.me","a.power"]'
check "self appears once" jq_ok "$OMASEITON_CONFIG_FILE" '[.bar.layout[] | arrays | .[] | .id] | map(select(. == "x.me")) | length == 1'

printf '{"savedAt":"x","bar":{"layout":{"left":[],"center":[],"right":[{"id":"x.me"},{"id":"a.tray"}]}}}' >"$OMASEITON_LAYOUT_DIR/mine.json"
run restore mine >/dev/null
check "a snapshot that has self keeps its own position, with no duplicate" jq_ok "$OMASEITON_CONFIG_FILE" '[.bar.layout.right[].id] == ["x.me","a.tray"]'

cat >"$OMASEITON_LIVE_FILE" <<'EOF'
{"version":1,"bar":{"layout":{"left":[{"id":"a.menu"},{"id":"x.me"}],"center":[],"right":[]}}}
EOF
printf '{"savedAt":"x","bar":{"layout":{"left":[],"center":[{"id":"a.clock"}],"right":[]}}}' >"$OMASEITON_LAYOUT_DIR/mine.json"
run restore mine >/dev/null
check "self returns to the lane it was in (left)" jq_ok "$OMASEITON_CONFIG_FILE" '[.bar.layout.left[].id] == ["x.me"]'

cat >"$OMASEITON_LIVE_FILE" <<'EOF'
{"version":1,"bar":{"layout":{"left":[],"center":[],"right":[{"id":"a.tray"}]}}}
EOF
printf '{"savedAt":"x","bar":{"layout":{"left":[],"center":[],"right":[{"id":"a.power"}]}}}' >"$OMASEITON_LAYOUT_DIR/mine.json"
run restore mine >/dev/null
check "with no known spot, self goes to the start of the right lane" jq_ok "$OMASEITON_CONFIG_FILE" '[.bar.layout.right[].id] == ["x.me","a.power"]'

# ---------------------------------------------------------------- Omarchy default
fresh defaults
write_live
write_config
mkdir -p "$SCEN/bin"
# `omarchy bar defaults` writes under $HOME. The script must run it in a throwaway home,
# never against the real config path.
cat >"$SCEN/bin/omarchy" <<'EOF'
#!/bin/bash
[[ $1 == bar && $2 == defaults ]] || exit 1
# refuse to write anywhere but the test's scratch area, whatever HOME says
[[ $HOME == "$STUB_ALLOWED"* ]] || { echo "stub omarchy refused: HOME is $HOME" >&2; exit 97; }
mkdir -p "$HOME/.config/omarchy"
printf '{"version":1,"bar":{"layout":{"left":[{"id":"a.menu"}],"center":[{"id":"a.clock"}],"right":[{"id":"a.tray"},{"id":"a.power"}]}}}' >"$HOME/.config/omarchy/shell.json"
echo "$HOME" >"$STUB_HOME_LOG"
EOF
chmod +x "$SCEN/bin/omarchy"
export STUB_HOME_LOG="$SCEN/stub-home"
export STUB_ALLOWED="$WORK/"
cp "$OMASEITON_CONFIG_FILE" "$SCEN/config.before"
PATH="$SCEN/bin:$PATH" run defaults >/dev/null
C="$OMASEITON_CONFIG_FILE"
check "the stock command ran in a throwaway home, not the one the script was started with" bash -c "[[ \$(cat '$STUB_HOME_LOG') != '$HOME' ]]"
check "and nothing was written under the starting home" test ! -e "$HOME/.config/omarchy/shell.json"
check "default removes other third-party widgets" jq_ok "$C" '[.bar.layout[] | arrays | .[] | .id] | index("x.radar") == null'
check "default keeps self where it was, in one write" jq_ok "$C" '[.bar.layout.right[].id] == ["a.tray","x.me","a.power"]'
check "default keeps the active bar plugin and unrelated settings" jq_ok "$C" '.bar.id == "keep.bar" and .idle.lock == 300 and .plugins == [{"id":"keep.plugin","setting":1}]'
check "default took a snapshot first" test "$(slots | grep -c '^auto-')" -eq 1
check "the snapshot still has the widget the default removed" jq_ok "$OMASEITON_LAYOUT_DIR/$(newest_auto).json" '[.bar.layout[] | arrays | .[] | .id] | index("x.radar") != null'

# if the stock command is missing, the packaged defaults file is used instead
fresh defaults-fallback
write_live
write_config
mkdir -p "$SCEN/omarchy/config/omarchy"
printf '{"bar":{"layout":{"left":[{"id":"d.menu"}],"center":[],"right":[{"id":"d.tray"}]}}}' >"$SCEN/omarchy/config/omarchy/shell.json"
OMARCHY_PATH="$SCEN/omarchy" run defaults >/dev/null
check "(the guard 'omarchy' failed, so the packaged defaults were used) fallback keeps self" jq_ok "$OMASEITON_CONFIG_FILE" '[.bar.layout.right[].id] | index("d.tray") != null and index("x.me") != null'

# ---------------------------------------------------------------- snapshots: order, pruning, safety
fresh prune
write_live
write_config
mkdir -p "$OMASEITON_LAYOUT_DIR"
for i in 1 2 3 4 5; do
  printf '{"savedAt":"2026-01-0%sT00:00:00Z","reason":"restore","bar":{"layout":{"left":[],"center":[{"id":"old.%s"}],"right":[]}}}' "$i" "$i" >"$OMASEITON_LAYOUT_DIR/auto-2026010$i-000000.json"
done
printf '{"savedAt":"x","bar":{"layout":{"left":[],"center":[{"id":"mine.w"}],"right":[]}}}' >"$OMASEITON_LAYOUT_DIR/mine.json"

# restoring the OLDEST snapshot must work even though taking a snapshot prunes it
printf '{"savedAt":"x","bar":{"layout":{"left":[],"center":[{"id":"oldest.w"}],"right":[]}}}' >"$OMASEITON_LAYOUT_DIR/auto-20250101-000000.json"
check "restoring the oldest snapshot succeeds" run restore auto-20250101-000000 >/dev/null
check "and it applied that snapshot" jq_ok "$OMASEITON_CONFIG_FILE" '[.bar.layout.center[].id] | index("oldest.w") != null'
check "afterwards only five automatic snapshots remain" test "$(slots | grep -c '^auto-')" -eq 5
newest="$(newest_auto)"
check "the snapshot just taken is the newest" bash -c "[[ '$newest' == auto-$(date +%Y%m%d)-* ]]"
check "and it survived pruning" test -f "$OMASEITON_LAYOUT_DIR/$newest.json"
check "the oldest snapshots were the ones dropped" test ! -f "$OMASEITON_LAYOUT_DIR/auto-20250101-000000.json"
check "My layout is never pruned" test -f "$OMASEITON_LAYOUT_DIR/mine.json"

# a burst of restores: the newest safety snapshot is always kept, and in order
fresh burst
write_config
mkdir -p "$OMASEITON_LAYOUT_DIR"
printf '{"savedAt":"x","bar":{"layout":{"left":[],"center":[],"right":[]}}}' >"$OMASEITON_LAYOUT_DIR/mine.json"
for i in 1 2 3 4 5 6 7 8 9; do
  printf '{"version":1,"bar":{"layout":{"left":[],"center":[{"id":"gen.%s"}],"right":[]}}}' "$i" >"$OMASEITON_LIVE_FILE"
  run restore mine >/dev/null
done
check "a burst keeps exactly five automatic snapshots" test "$(slots | grep -c '^auto-')" -eq 5
newest="$OMASEITON_LAYOUT_DIR/$(newest_auto).json"
check "the newest snapshot is the last state, not an older one" jq_ok "$newest" '.bar.layout.center[0].id == "gen.9"'
kept=$(for s in $(slots | grep '^auto-'); do jq -r '.bar.layout.center[0].id' "$OMASEITON_LAYOUT_DIR/$s.json"; done | sort | tr '\n' ' ')
check "the five kept are the five newest (gen.5 to gen.9)" test "$kept" = "gen.5 gen.6 gen.7 gen.8 gen.9 "
check "list is newest first" bash -c "[[ \$(bash '$SCRIPT' list | jq -r '[.[] | select(.slot | startswith(\"auto-\")) | .slot] == ([.[] | select(.slot | startswith(\"auto-\")) | .slot] | sort | reverse)') == true ]]"
check "list reports a reason and a widget count" bash -c "bash '$SCRIPT' list | jq -e 'all(.[]; has(\"reason\") and (.widgets | type == \"number\"))' >/dev/null"

# a failed restore must not cost the user any snapshot
fresh readonly
write_live
write_config
mkdir -p "$OMASEITON_LAYOUT_DIR"
printf '{"savedAt":"x","bar":{"layout":{"left":[],"center":[{"id":"w"}],"right":[]}}}' >"$OMASEITON_LAYOUT_DIR/mine.json"
chmod 555 "$SCEN"
before=$(find "$OMASEITON_LAYOUT_DIR" -name 'auto-*.json' | wc -l)
if [[ $(id -u) -ne 0 ]]; then
  check "restore fails when the config directory is read-only" fails bash "$SCRIPT" restore mine
  check "a failed restore leaves no extra snapshot" test "$(find "$OMASEITON_LAYOUT_DIR" -name 'auto-*.json' | wc -l)" -eq "$before"
fi
chmod 755 "$SCEN"

# a config that cannot be read as JSON: the restore stops, the file is untouched, no snapshot is left behind
fresh badconfig
write_live
printf 'this is not json' >"$OMASEITON_CONFIG_FILE"
mkdir -p "$OMASEITON_LAYOUT_DIR"
printf '{"savedAt":"x","bar":{"layout":{"left":[],"center":[{"id":"w"}],"right":[]}}}' >"$OMASEITON_LAYOUT_DIR/mine.json"
check "an unreadable shell.json stops the restore" fails bash "$SCRIPT" restore mine
check "and shell.json is left exactly as it was" test "$(cat "$OMASEITON_CONFIG_FILE")" = "this is not json"
check "and no snapshot is left behind" test "$(find "$OMASEITON_LAYOUT_DIR" -name 'auto-*.json' | wc -l)" -eq 0
check "and no temp file is left next to it" test "$(find "$SCEN" -maxdepth 1 -name 'shell.json.*' | wc -l)" -eq 0

# two snapshots in the same instant must not overwrite each other (a clock that repeats itself)
fresh sameinstant
write_live
write_config
mkdir -p "$OMASEITON_LAYOUT_DIR" "$SCEN/bin"
printf '{"savedAt":"x","bar":{"layout":{"left":[],"center":[{"id":"w"}],"right":[]}}}' >"$OMASEITON_LAYOUT_DIR/mine.json"
cat >"$SCEN/bin/date" <<'EOF'
#!/bin/bash
# the slot-name format always returns one of two values, the same one three times running
if [[ $1 == "+%Y%m%d-%H%M%S-%N" ]]; then
  n=$(cat "$DATE_COUNTER" 2>/dev/null || echo 0)
  echo $((n + 1)) >"$DATE_COUNTER"
  if (( n < 3 )); then echo "20260101-000000-000000001"; else echo "20260101-000000-00000000$((n))"; fi
else
  exec /usr/bin/date "$@"
fi
EOF
chmod +x "$SCEN/bin/date"
export DATE_COUNTER="$SCEN/date-counter"
PATH="$SCEN/bin:$PATH" run restore mine >/dev/null
PATH="$SCEN/bin:$PATH" run restore mine >/dev/null
check "a repeated name is never reused: both snapshots exist" test "$(find "$OMASEITON_LAYOUT_DIR" -name 'auto-*.json' | wc -l)" -eq 2

# ---------------------------------------------------------------- symlinks and permissions
fresh symlink
write_live
mkdir -p "$SCEN/dotfiles"
write_config
mv "$OMASEITON_CONFIG_FILE" "$SCEN/dotfiles/shell.json"
chmod 644 "$SCEN/dotfiles/shell.json"
ln -s "$SCEN/dotfiles/shell.json" "$OMASEITON_CONFIG_FILE"
mkdir -p "$OMASEITON_LAYOUT_DIR"
printf '{"savedAt":"x","bar":{"layout":{"left":[],"center":[{"id":"linked.w"}],"right":[]}}}' >"$OMASEITON_LAYOUT_DIR/mine.json"
run restore mine >/dev/null
check "a symlinked shell.json is still a symlink" test -L "$OMASEITON_CONFIG_FILE"
check "the file it points at was updated" jq_ok "$SCEN/dotfiles/shell.json" '[.bar.layout.center[].id] | index("linked.w") != null'
check "its permissions were kept" test "$(stat -c %a "$SCEN/dotfiles/shell.json")" = "644"

# ---------------------------------------------------------------- reopen breadcrumb
fresh reopen
write_live
write_config
mkdir -p "$OMASEITON_LAYOUT_DIR"
printf '{"savedAt":"x","bar":{"layout":{"left":[],"center":[],"right":[]}}}' >"$OMASEITON_LAYOUT_DIR/mine.json"
OMASEITON_REOPEN_FLAG="$SCEN/state/reopen" OMASEITON_REOPEN_SCREEN="DP-2" run restore mine >/dev/null
check "restore leaves the reopen flag naming the monitor" test "$(cat "$SCEN/state/reopen")" = "DP-2"

# ---------------------------------------------------------------- list
fresh list
check "an empty folder lists as []" test "$(bash "$SCRIPT" list)" = "[]"
write_live
run save mine >/dev/null
check "list counts widgets in the three lanes" bash -c "bash '$SCRIPT' list | jq -e '.[0].widgets == 5' >/dev/null"

echo "layout script tests passed ($pass checks)"
