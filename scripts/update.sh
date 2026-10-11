#!/bin/bash

# Omaseiton plugin updates: a short, readable summary per plugin instead of a
# raw diff, then a yes/no, then the update.
#
# What you are shown is exactly what you get. The commit that was summarised is
# pinned, and only that commit is applied (a fast-forward merge to that exact
# hash). If the remote moved while the question was open, the newer commits are
# NOT applied; run Update again to see them. After the merge the manifest is
# validated with Omarchy's own `omarchy-plugin-validate`, and a plugin that fails
# validation is rolled back, the same safety net `omarchy-plugin-update` has.
#
# Usage:
#   update.sh            check every git-managed plugin
#   update.sh <plugin>   check just one

set -uo pipefail

export GIT_TERMINAL_PROMPT=0
export GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -oBatchMode=yes}"

PLUGINS_DIR="${OMASEITON_PLUGINS_DIR:-$HOME/.config/omarchy/plugins}"
SHOWN_COMMITS=12

# Plugin directories are other people's code, so run git with the settings that
# make a hostile .git/config or hook inert: no fsmonitor program, no hooks, and
# only the ordinary transports. Transports such as `ext::` (or any remote helper
# named in the URL) run programs, and a plugin's own .git/config can switch one
# on with a protocol.<name>.allow line, which beats any general protocol.allow
# setting. GIT_ALLOW_PROTOCOL is different: it is a strict allowlist that
# overrides every config setting, so nothing outside the list can run.
git_safe() {
  GIT_ALLOW_PROTOCOL=https:ssh:git:file git -c core.fsmonitor= -c core.hooksPath=/dev/null \
    -c core.sshCommand="$GIT_SSH_COMMAND" "$@"
}

only="${1:-}"
checked=0 current=0 updated=0 skipped=0 failed=0

valid_id() {
  [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && $1 != *..* ]]
}

# Yes/no in the terminal, using gum when there is one so it matches the theme.
ask() {
  if command -v gum >/dev/null 2>&1; then
    gum confirm "$1"
  else
    local reply
    read -r -p "$1 [y/N] " reply
    [[ $reply == [yY]* ]]
  fi
}

check_one() {
  local id="$1" dir="$PLUGINS_DIR/$1" sha count

  checked=$((checked + 1))
  if ! git_safe -C "$dir" fetch --quiet --no-recurse-submodules origin HEAD 2>/dev/null; then
    echo "$id: could not reach the remote, skipped."
    failed=$((failed + 1))
    return
  fi
  sha=$(git_safe -C "$dir" rev-parse FETCH_HEAD 2>/dev/null) || {
    echo "$id: could not read the remote, skipped."
    failed=$((failed + 1))
    return
  }

  if [[ $(git_safe -C "$dir" rev-parse HEAD) == "$sha" ]]; then
    echo "$id is up to date."
    current=$((current + 1))
    return
  fi
  if git_safe -C "$dir" merge-base --is-ancestor "$sha" HEAD 2>/dev/null; then
    echo "$id has nothing new upstream (this copy has commits of its own)."
    current=$((current + 1))
    return
  fi
  if ! git_safe -C "$dir" merge-base --is-ancestor HEAD "$sha" 2>/dev/null; then
    echo "$id: this copy and the remote have diverged, so it cannot be updated cleanly. Skipped."
    skipped=$((skipped + 1))
    return
  fi
  if [[ -n $(git_safe -C "$dir" status --porcelain --untracked-files=no 2>/dev/null) ]]; then
    echo "$id: it has local changes that an update would clash with. Skipped."
    skipped=$((skipped + 1))
    return
  fi

  count=$(git_safe -C "$dir" rev-list --count "HEAD..$sha" 2>/dev/null || echo "?")
  echo
  echo "== $id: $count new commit(s)"
  git_safe -C "$dir" --no-pager log --no-decorate --format='  %h %s' "HEAD..$sha" | head -n "$SHOWN_COMMITS"
  if [[ $count =~ ^[0-9]+$ ]] && ((count > SHOWN_COMMITS)); then
    echo "  ... and $((count - SHOWN_COMMITS)) more"
  fi
  echo "  $(git_safe -C "$dir" --no-pager diff --shortstat "HEAD" "$sha")"
  echo "  full diff: git -C '$dir' diff HEAD $sha"
  echo

  if ! ask "Update $id to ${sha:0:9}?"; then
    echo "Skipped $id."
    skipped=$((skipped + 1))
    return
  fi

  # Apply exactly the commit that was shown, never "whatever the remote has now".
  if ! git_safe -C "$dir" merge --ff-only --quiet "$sha" >/dev/null 2>&1; then
    echo "$id: could not fast-forward to ${sha:0:9}; left as it was."
    failed=$((failed + 1))
    return
  fi
  if ! omarchy-plugin-validate "$dir" >/dev/null 2>&1; then
    git_safe -C "$dir" reset --hard --quiet ORIG_HEAD >/dev/null 2>&1
    echo "$id: the update failed validation and was rolled back."
    failed=$((failed + 1))
    return
  fi
  echo "Updated $id to ${sha:0:9}."
  updated=$((updated + 1))
}

[[ -d $PLUGINS_DIR ]] || {
  echo "update.sh: no plugins installed" >&2
  exit 1
}

if [[ -n $only ]]; then
  valid_id "$only" || {
    echo "update.sh: invalid plugin id '$only'" >&2
    exit 1
  }
  [[ -L $PLUGINS_DIR/$only ]] && {
    echo "update.sh: '$only' is a symlink, so it is not updated here" >&2
    exit 1
  }
  [[ -d $PLUGINS_DIR/$only/.git ]] || {
    echo "update.sh: '$only' is not a git checkout, so there is nothing to pull from" >&2
    exit 1
  }
  check_one "$only"
else
  for dir in "$PLUGINS_DIR"/*/; do
    dir="${dir%/}"
    id=$(basename "$dir")
    [[ -L $dir ]] && continue
    [[ -d $dir/.git ]] || continue
    valid_id "$id" || continue
    check_one "$id"
  done
  if ((checked == 0)); then
    echo "No git-managed plugins installed."
    exit 0
  fi
fi

# New plugin code is on disk; ask the shell to pick it up.
if ((updated > 0)); then
  omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
fi

echo
echo "Done: $current up to date, $updated updated, $skipped skipped, $failed failed."
((failed == 0))
