#!/bin/bash

# Omaseiton plugin updates: a short, readable summary per plugin instead of a
# raw diff, then a yes/no. The update itself is done by Omarchy's own
# `omarchy-plugin-update`, so its fast-forward-only merge, manifest validation
# and automatic rollback all still apply.
#
# Usage:
#   update.sh            check every git-managed plugin
#   update.sh <plugin>   check just one

set -uo pipefail

export GIT_TERMINAL_PROMPT=0
export GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -oBatchMode=yes}"

PLUGINS_DIR="${OMASEITON_PLUGINS_DIR:-$HOME/.config/omarchy/plugins}"
SHOWN_COMMITS=12

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
  local id="$1" dir="$PLUGINS_DIR/$1" count

  checked=$((checked + 1))
  if ! git -C "$dir" fetch --quiet origin HEAD 2>/dev/null; then
    echo "$id: could not reach the remote, skipped."
    failed=$((failed + 1))
    return
  fi

  if [[ $(git -C "$dir" rev-parse HEAD) == "$(git -C "$dir" rev-parse FETCH_HEAD)" ]]; then
    echo "$id is up to date."
    current=$((current + 1))
    return
  fi

  count=$(git -C "$dir" rev-list --count HEAD..FETCH_HEAD 2>/dev/null || echo "?")
  echo
  echo "== $id: $count new commit(s)"
  git -C "$dir" --no-pager log --no-decorate --format='  %h %s' "HEAD..FETCH_HEAD" | head -n "$SHOWN_COMMITS"
  if [[ $count =~ ^[0-9]+$ ]] && ((count > SHOWN_COMMITS)); then
    echo "  ... and $((count - SHOWN_COMMITS)) more"
  fi
  echo "  $(git -C "$dir" --no-pager diff --shortstat HEAD FETCH_HEAD)"
  echo "  full diff: git -C '$dir' diff HEAD FETCH_HEAD"
  echo

  if ask "Update $id?"; then
    if omarchy-plugin-update "$id" --yes; then
      updated=$((updated + 1))
    else
      failed=$((failed + 1))
    fi
  else
    echo "Skipped $id."
    skipped=$((skipped + 1))
  fi
}

[[ -d $PLUGINS_DIR ]] || { echo "update.sh: no plugins installed" >&2; exit 1; }

if [[ -n $only ]]; then
  valid_id "$only" || { echo "update.sh: invalid plugin id '$only'" >&2; exit 1; }
  [[ -d $PLUGINS_DIR/$only/.git ]] || { echo "update.sh: '$only' is not a git checkout, so there is nothing to pull from" >&2; exit 1; }
  check_one "$only"
else
  for dir in "$PLUGINS_DIR"/*/; do
    [[ -d $dir/.git ]] || continue
    check_one "$(basename "$dir")"
  done
  if ((checked == 0)); then
    echo "No git-managed plugins installed."
    exit 0
  fi
fi

echo
echo "Done: $current up to date, $updated updated, $skipped skipped, $failed failed."
((failed == 0))
