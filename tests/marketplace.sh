#!/bin/bash
# Runs tests/marketplace.mjs against the marketplace's own scripts.
#
# Usage:
#   bash tests/marketplace.sh                   fetch the marketplace at the pinned commit below
#   bash tests/marketplace.sh <checkout>        use a marketplace checkout you already have
#
# The commit is pinned on purpose: a moving target would make CI results depend
# on whatever the marketplace changed overnight. Bump it deliberately.

set -euo pipefail

MARKETPLACE_REPO="https://github.com/omacom/omarchy-plugin-marketplace.git"
MARKETPLACE_SHA="5df900b5f148cf74817e3f797ab2746e468ed60e"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -n ${1:-} ]]; then
  checkout="$1"
else
  checkout="$(mktemp -d)"
  trap 'rm -rf "$checkout"' EXIT
  git -C "$checkout" init -q
  git -C "$checkout" fetch -q --depth 1 "$MARKETPLACE_REPO" "$MARKETPLACE_SHA"
  git -C "$checkout" checkout -q FETCH_HEAD
  (cd "$checkout" && npm ci --silent --ignore-scripts)
fi

node "$HERE/marketplace.mjs" "$checkout/scripts"
