#!/bin/bash
# Tests for scripts/update.sh using throwaway git repos and stub commands.
# Run with: bash tests/update-script.test.sh

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../scripts/update.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export OMASEITON_PLUGINS_DIR="$WORK/plugins"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
mkdir -p "$OMASEITON_PLUGINS_DIR" "$WORK/bin"

# stubs: `gum confirm` answers from $GUM_ANSWER, and omarchy-plugin-update records its arguments
cat >"$WORK/bin/gum" <<'EOF'
#!/bin/bash
echo "$*" >>"$STUB_LOG.gum"
[[ ${GUM_ANSWER:-no} == yes ]]
EOF
cat >"$WORK/bin/omarchy-plugin-update" <<'EOF'
#!/bin/bash
echo "$*" >>"$STUB_LOG.update"
EOF
chmod +x "$WORK/bin/gum" "$WORK/bin/omarchy-plugin-update"
export PATH="$WORK/bin:$PATH"
export STUB_LOG="$WORK/stub"

# a pager that leaves a marker if git ever starts it
cat >"$WORK/pager" <<'EOF'
#!/bin/bash
touch "$WORK_MARK"
cat
EOF
chmod +x "$WORK/pager"
export GIT_PAGER="$WORK/pager" PAGER="$WORK/pager" WORK_MARK="$WORK/pager-was-used"

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

make_plugin() { # make_plugin <id>: an origin repo plus a clone under plugins/
  local id="$1"
  git init -q -b main "$WORK/origin-$id"
  echo one >"$WORK/origin-$id/a.txt"
  git -C "$WORK/origin-$id" add -A
  git -C "$WORK/origin-$id" commit -q -m "first"
  git clone -q "$WORK/origin-$id" "$OMASEITON_PLUGINS_DIR/$id"
}

commit_upstream() { # commit_upstream <id> <n>: n new commits on the origin
  local id="$1" n="$2" i
  for ((i = 1; i <= n; i++)); do
    echo "$i" >>"$WORK/origin-$id/a.txt"
    git -C "$WORK/origin-$id" commit -q -am "change $i"
  done
}

run() { bash "$SCRIPT" "$@" 2>&1; }

make_plugin current.plugin
make_plugin behind.plugin
mkdir -p "$OMASEITON_PLUGINS_DIR/not-a-git-plugin"
commit_upstream behind.plugin 2

# an up to date plugin never prompts
out="$(run current.plugin)"
check "up to date is reported" grep -q "current.plugin is up to date." <<<"$out"
check "up to date does not prompt" test ! -e "$STUB_LOG.gum"
check "summary line counts it" grep -q "1 up to date, 0 updated" <<<"$out"

# a plugin that is behind: summary, then a no
out="$(GUM_ANSWER=no run behind.plugin || true)"
check "shows the commit count" grep -q "2 new commit(s)" <<<"$out"
check "lists the commit subjects" grep -q "change 2" <<<"$out"
check "shows a one-line stat" grep -q "1 file changed" <<<"$out"
check "does not dump a diff" bash -c "! grep -q '^+++ \\|^diff --git' <<<'$out'"
check "points at the full diff" grep -q "full diff: git -C" <<<"$out"
check "asks before updating" grep -q "Update behind.plugin?" "$STUB_LOG.gum"
check "no answer means skipped" grep -q "Skipped behind.plugin." <<<"$out"
check "no answer means no update" test ! -e "$STUB_LOG.update"
check "the pager is never started" test ! -e "$WORK_MARK"

# ... and a yes hands over to Omarchy's updater, for that plugin only, with --yes
out="$(GUM_ANSWER=yes run behind.plugin)"
check "yes calls omarchy-plugin-update" grep -qx "behind.plugin --yes" "$STUB_LOG.update"
check "yes is counted" grep -q "1 updated" <<<"$out"

# many commits are trimmed
make_plugin busy.plugin
commit_upstream busy.plugin 15
out="$(GUM_ANSWER=no run busy.plugin || true)"
check "long histories are trimmed" grep -q "and 3 more" <<<"$out"
check "the newest commits are the ones shown" grep -q "change 15" <<<"$out"

# whole sweep: skips non-git folders, visits the rest
rm -f "$STUB_LOG.gum" "$STUB_LOG.update"
out="$(GUM_ANSWER=no run || true)"
check "sweep ignores non-git folders" bash -c "! grep -q 'not-a-git-plugin' <<<'$out'"
check "sweep checks the plugins that are current" grep -q "current.plugin is up to date." <<<"$out"
check "sweep summarises" grep -q "Done:" <<<"$out"

# an unreachable remote is reported and the script exits non-zero
make_plugin gone.plugin
rm -rf "$WORK/origin-gone.plugin"
out="$(run gone.plugin || true)"
check "unreachable remote is reported" grep -q "could not reach the remote" <<<"$out"
check "unreachable remote fails the run" bash -c "! bash '$SCRIPT' gone.plugin >/dev/null 2>&1"

# bad input
check "invalid id is refused" bash -c "! bash '$SCRIPT' '../evil' >/dev/null 2>&1"
check "a non-git plugin is refused" bash -c "! bash '$SCRIPT' not-a-git-plugin >/dev/null 2>&1"
mkdir -p "$WORK/empty/not-a-git-plugin"
out="$(OMASEITON_PLUGINS_DIR="$WORK/empty" bash "$SCRIPT" 2>&1)"
check "a folder with no git plugins is a clean no-op" grep -q "No git-managed plugins installed." <<<"$out"
check "a missing plugins folder fails clearly" bash -c "OMASEITON_PLUGINS_DIR='$WORK/nowhere' bash '$SCRIPT' 2>&1 | grep -q 'no plugins installed'"

echo "update script tests passed ($pass checks)"
