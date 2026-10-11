#!/bin/bash
# Tests for scripts/update.sh using throwaway git repos and stub commands.
# Run with: bash tests/update-script.test.sh

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${UPDATE_SH:-$HERE/../scripts/update.sh}"
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

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
mkdir -p "$WORK/bin"

# --- stubs --------------------------------------------------------------------
# gum: logs the question; runs $GUM_HOOK first if set (to change the world while
# the question is open); answers from $GUM_ANSWER (default no).
cat >"$WORK/bin/gum" <<'EOF'
#!/bin/bash
echo "$*" >>"$STUB_LOG.gum"
[[ -z ${GUM_HOOK:-} ]] || bash -c "$GUM_HOOK"
[[ ${GUM_ANSWER:-no} == yes ]]
EOF
# omarchy-plugin-validate: logs the directory; passes unless $VALIDATE_FAIL is set
cat >"$WORK/bin/omarchy-plugin-validate" <<'EOF'
#!/bin/bash
echo "$*" >>"$STUB_LOG.validate"
[[ -z ${VALIDATE_FAIL:-} ]]
EOF
cat >"$WORK/bin/omarchy-shell" <<'EOF'
#!/bin/bash
echo "$*" >>"$STUB_LOG.shell"
EOF
# omarchy-plugin-update must never be called: its --yes skips the review of what is applied
cat >"$WORK/bin/omarchy-plugin-update" <<'EOF'
#!/bin/bash
echo "$*" >>"$STUB_LOG.forbidden"
exit 99
EOF
chmod +x "$WORK/bin/"*
export PATH="$WORK/bin:$PATH"

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
head_of() { git -C "$OMASEITON_PLUGINS_DIR/$1" rev-parse HEAD; }

fresh() {
  SCEN="$WORK/$1"
  rm -rf "$SCEN"
  mkdir -p "$SCEN/plugins"
  export OMASEITON_PLUGINS_DIR="$SCEN/plugins"
  export STUB_LOG="$SCEN/stub"
  unset GUM_ANSWER GUM_HOOK VALIDATE_FAIL
}
make_plugin() { # make_plugin <id>
  local id="$1"
  git init -q -b main "$SCEN/origin-$id"
  echo one >"$SCEN/origin-$id/a.txt"
  git -C "$SCEN/origin-$id" add -A
  git -C "$SCEN/origin-$id" commit -q -m "first"
  git clone -q "$SCEN/origin-$id" "$OMASEITON_PLUGINS_DIR/$id"
}
commit_upstream() { # commit_upstream <id> <n>
  local id="$1" n="$2" i
  for ((i = 1; i <= n; i++)); do
    echo "$i" >>"$SCEN/origin-$id/a.txt"
    git -C "$SCEN/origin-$id" commit -q -am "change $i"
  done
}
run() { bash "$SCRIPT" "$@" 2>&1; }

# pager marker: a pager that leaves a file if git ever starts it
cat >"$WORK/pager" <<'EOF'
#!/bin/bash
touch "$PAGER_MARK"
cat
EOF
chmod +x "$WORK/pager"
export PAGER_MARK="$WORK/pager-was-used"

# ---------------------------------------------------------------- up to date
fresh current
make_plugin current.plugin
out="$(run current.plugin)"
check "up to date is reported" grep -q "current.plugin is up to date." <<<"$out"
check "up to date never prompts" test ! -e "$STUB_LOG.gum"
check "summary counts it" grep -q "1 up to date, 0 updated" <<<"$out"

# ---------------------------------------------------------------- behind: summary, no, yes
fresh behind
make_plugin behind.plugin
commit_upstream behind.plugin 2
start="$(head_of behind.plugin)"
out="$(GUM_ANSWER=no run behind.plugin || true)"
check "shows the commit count" grep -q "2 new commit(s)" <<<"$out"
check "lists the commit subjects" grep -q "change 2" <<<"$out"
check "shows a one-line stat" grep -q "1 file changed" <<<"$out"
check "does not dump a diff" fails grep -q -E '^(\+\+\+ |diff --git)' <<<"$out"
check "points at the full diff, for that exact commit" grep -q "full diff: git -C" <<<"$out"
check "asks before updating" grep -q "Update behind.plugin" "$STUB_LOG.gum"
check "no means skipped" grep -q "Skipped behind.plugin." <<<"$out"
check "no means the plugin is untouched" test "$(head_of behind.plugin)" = "$start"
check "no means no validation and no rescan" test ! -e "$STUB_LOG.validate" -a ! -e "$STUB_LOG.shell"

pinned="$(git -C "$SCEN/origin-behind.plugin" rev-parse HEAD)"
out="$(GUM_ANSWER=yes run behind.plugin)"
check "yes moves the plugin to the commit that was shown" test "$(head_of behind.plugin)" = "$pinned"
check "yes validates that directory" grep -qx "$OMASEITON_PLUGINS_DIR/behind.plugin" "$STUB_LOG.validate"
check "yes asks the shell to rescan, once" test "$(grep -c rescanPlugins "$STUB_LOG.shell")" -eq 1
check "yes is counted" grep -q "1 updated" <<<"$out"
check "omarchy-plugin-update (and its --yes) is never used" test ! -e "$STUB_LOG.forbidden"

# ---------------------------------------------------------------- the attack: the remote moves while the question is open
fresh race
make_plugin race.plugin
commit_upstream race.plugin 1
shown="$(git -C "$SCEN/origin-race.plugin" rev-parse HEAD)"
# while the question is open: a sneaky commit lands upstream, and something else (another
# fetch, say) updates the plugin's FETCH_HEAD to it. Only the commit that was shown may be applied.
export GUM_HOOK="echo 'evil' > '$SCEN/origin-race.plugin/evil.qml' && git -C '$SCEN/origin-race.plugin' add -A && git -C '$SCEN/origin-race.plugin' commit -q -m 'sneaky' && git -C '$OMASEITON_PLUGINS_DIR/race.plugin' fetch -q origin HEAD"
out="$(GUM_ANSWER=yes run race.plugin)"
unset GUM_HOOK
check "the remote really did move on" test "$(git -C "$SCEN/origin-race.plugin" rev-parse HEAD)" != "$shown"
check "only the commit that was shown was applied" test "$(head_of race.plugin)" = "$shown"
check "the commit pushed mid-prompt is not on disk" test ! -e "$OMASEITON_PLUGINS_DIR/race.plugin/evil.qml"
out="$(GUM_ANSWER=no run race.plugin || true)"
check "running Update again shows the newer commit" grep -q "sneaky" <<<"$out"

# ---------------------------------------------------------------- validation failure rolls back
fresh rollback
make_plugin bad.plugin
commit_upstream bad.plugin 1
start="$(head_of bad.plugin)"
status=0
out="$(VALIDATE_FAIL=1 GUM_ANSWER=yes run bad.plugin)" || status=$?
check "a failed validation is reported" grep -q "failed validation and was rolled back" <<<"$out"
check "and rolled back to where it was" test "$(head_of bad.plugin)" = "$start"
check "and the run fails" test "$status" -ne 0
check "a rolled-back plugin does not trigger a rescan" test ! -e "$STUB_LOG.shell"

# ---------------------------------------------------------------- states that must not be offered as updates
fresh states
make_plugin diverged.plugin
make_plugin ahead.plugin
make_plugin dirty.plugin
# diverged: a local commit and a different upstream commit
echo local >"$OMASEITON_PLUGINS_DIR/diverged.plugin/local.txt"
git -C "$OMASEITON_PLUGINS_DIR/diverged.plugin" add -A
git -C "$OMASEITON_PLUGINS_DIR/diverged.plugin" commit -q -m "local work"
commit_upstream diverged.plugin 1
# ahead: only local commits, nothing new upstream
echo local >"$OMASEITON_PLUGINS_DIR/ahead.plugin/local.txt"
git -C "$OMASEITON_PLUGINS_DIR/ahead.plugin" add -A
git -C "$OMASEITON_PLUGINS_DIR/ahead.plugin" commit -q -m "local work"
# dirty: uncommitted change to a tracked file, with an update waiting
commit_upstream dirty.plugin 1
echo tweak >>"$OMASEITON_PLUGINS_DIR/dirty.plugin/a.txt"
local_head="$(head_of diverged.plugin)"
out="$(GUM_ANSWER=yes run || true)"
check "a diverged plugin is skipped with a reason" grep -q "diverged.plugin: this copy and the remote have diverged" <<<"$out"
check "a diverged plugin keeps its local commit" test "$(head_of diverged.plugin)" = "$local_head"
check "local commits with nothing new upstream are not an update" grep -q "ahead.plugin has nothing new upstream" <<<"$out"
check "a plugin with local changes is skipped" grep -q "dirty.plugin: it has local changes" <<<"$out"
check "none of them was prompted" test ! -e "$STUB_LOG.gum"
check "none of them counted as updated" grep -q "0 updated" <<<"$out"
check "the uncommitted change survived" grep -q tweak "$OMASEITON_PLUGINS_DIR/dirty.plugin/a.txt"

# ---------------------------------------------------------------- long histories, sweeps, bad input
fresh sweep
make_plugin busy.plugin
make_plugin current.plugin
commit_upstream busy.plugin 15
mkdir -p "$OMASEITON_PLUGINS_DIR/not-a-git-plugin"
out="$(GUM_ANSWER=no run || true)"
check "long histories are trimmed" grep -q "and 3 more" <<<"$out"
check "the newest commits are the ones shown" grep -q "change 15" <<<"$out"
check "a sweep ignores folders that are not git checkouts" fails grep -q "not-a-git-plugin" <<<"$out"
check "a sweep visits current plugins too" grep -q "current.plugin is up to date." <<<"$out"
check "a sweep summarises" grep -q "Done:" <<<"$out"

fresh unreachable
make_plugin gone.plugin
rm -rf "$SCEN/origin-gone.plugin"
status=0
out="$(run gone.plugin)" || status=$?
check "an unreachable remote is reported" grep -q "could not reach the remote" <<<"$out"
check "and fails the run" test "$status" -ne 0

fresh input
make_plugin real.plugin
mkdir -p "$OMASEITON_PLUGINS_DIR/not-a-git-plugin"
check "an invalid id is refused" fails bash "$SCRIPT" '../evil'
check "an id with a newline is refused" fails bash "$SCRIPT" $'real.plugin\nx'
check "a non-git plugin is refused" fails bash "$SCRIPT" not-a-git-plugin
ln -s "$OMASEITON_PLUGINS_DIR/real.plugin" "$OMASEITON_PLUGINS_DIR/linked.plugin"
check "a symlinked plugin is refused by name" fails bash "$SCRIPT" linked.plugin
out="$(run || true)"
check "a symlinked plugin is skipped in a sweep" fails grep -q "linked.plugin" <<<"$out"
mkdir -p "$SCEN/empty/not-a-git-plugin"
out="$(OMASEITON_PLUGINS_DIR="$SCEN/empty" bash "$SCRIPT" 2>&1)"
check "a folder with no git plugins is a clean no-op" grep -q "No git-managed plugins installed." <<<"$out"
check "a missing plugins folder fails clearly" bash -c "OMASEITON_PLUGINS_DIR='$SCEN/nowhere' bash '$SCRIPT' 2>&1 | grep -q 'no plugins installed'"

# ---------------------------------------------------------------- a plugin's own .git/config cannot run code through us
fresh hostile
make_plugin hostile.plugin
commit_upstream hostile.plugin 1
cat >"$SCEN/fsmon.sh" <<'EOF'
#!/bin/bash
touch "$HOSTILE_MARK"
EOF
cat >"$SCEN/hook.sh" <<'EOF'
#!/bin/bash
touch "$HOSTILE_MARK"
EOF
chmod +x "$SCEN/fsmon.sh" "$SCEN/hook.sh"
export HOSTILE_MARK="$SCEN/hostile-code-ran"
git -C "$OMASEITON_PLUGINS_DIR/hostile.plugin" config core.fsmonitor "$SCEN/fsmon.sh"
git -C "$OMASEITON_PLUGINS_DIR/hostile.plugin" config core.sshCommand "$SCEN/hook.sh"
mkdir -p "$OMASEITON_PLUGINS_DIR/hostile.plugin/.git/hooks"
for h in reference-transaction post-merge post-checkout pre-auto-gc; do
  cp "$SCEN/hook.sh" "$OMASEITON_PLUGINS_DIR/hostile.plugin/.git/hooks/$h"
done
GUM_ANSWER=yes run hostile.plugin >/dev/null || true
check "no fsmonitor, hook or ssh command from the plugin's own config ran" test ! -e "$HOSTILE_MARK"
check "and the update itself still worked" test "$(head_of hostile.plugin)" = "$(git -C "$SCEN/origin-hostile.plugin" rev-parse HEAD)"

# ext:: transports run commands. The remote URL and the policy that allows it both live in the
# plugin's own .git/config, which is data from someone else. (A first draft of this test used a
# quoted command that never runs even when allowed; `ext::touch FILE` is the form that does.)
fresh ext
make_plugin ext.plugin
git -C "$OMASEITON_PLUGINS_DIR/ext.plugin" remote set-url origin "ext::touch $SCEN/ext-ran"
git -C "$OMASEITON_PLUGINS_DIR/ext.plugin" config protocol.ext.allow always
# first prove the attack is real: with the same config and plain git, the command runs
git -C "$OMASEITON_PLUGINS_DIR/ext.plugin" fetch --quiet origin HEAD >/dev/null 2>&1 || true
check "(control) plain git really would run the command" test -e "$SCEN/ext-ran"
rm -f "$SCEN/ext-ran"
status=0
run ext.plugin >/dev/null || status=$?
check "through update.sh, an ext:: remote runs nothing" test ! -e "$SCEN/ext-ran"
check "and it is reported as a failure" test "$status" -ne 0

# a remote helper (git-remote-NAME) is also a way to run a program named by the URL
fresh helper
make_plugin helper.plugin
cat >"$WORK/bin/git-remote-zzz" <<'EOF'
#!/bin/bash
touch "$HELPER_MARK"
exit 1
EOF
chmod +x "$WORK/bin/git-remote-zzz"
export HELPER_MARK="$SCEN/helper-ran"
git -C "$OMASEITON_PLUGINS_DIR/helper.plugin" remote set-url origin "zzz::anything"
git -C "$OMASEITON_PLUGINS_DIR/helper.plugin" config protocol.zzz.allow always
git -C "$OMASEITON_PLUGINS_DIR/helper.plugin" fetch --quiet origin HEAD >/dev/null 2>&1 || true
check "(control) plain git really would run the helper" test -e "$HELPER_MARK"
rm -f "$HELPER_MARK"
run helper.plugin >/dev/null || true
check "through update.sh, an unknown transport's helper is never run" test ! -e "$HELPER_MARK"
rm -f "$WORK/bin/git-remote-zzz"

# ---------------------------------------------------------------- git never opens a pager (needs a pseudo-terminal)
if command -v script >/dev/null 2>&1; then
  fresh pager
  make_plugin pager.plugin
  commit_upstream pager.plugin 3
  rm -f "$PAGER_MARK"
  GIT_PAGER="$WORK/pager" PAGER="$WORK/pager" GUM_ANSWER=no script -qec "bash '$SCRIPT' pager.plugin" /dev/null >/dev/null 2>&1 || true
  check "with a real terminal attached, no pager is started" test ! -e "$PAGER_MARK"
fi

echo "update script tests passed ($pass checks)"
