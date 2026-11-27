#!/usr/bin/env bash
# Usage: vibe-patches/apply.sh revert|apply
# Patches live in vibe-patches/<pkg>/*.patch (git diff against repo root).
# revert: undo applied patches (run BEFORE merging upstream, so upstream never conflicts with us)
# apply:  re-apply patches (run AFTER the merge). Patches that no longer apply are listed
#         in $GITHUB_OUTPUT as failed=... and skipped.
set -uo pipefail
cd "$(dirname "$0")/.."
mode="${1:?revert|apply}"
failed=""
if [ "$mode" = revert ]; then
  for p in $(ls -r vibe-patches/*/*.patch 2>/dev/null); do
    git apply -R --check "$p" 2>/dev/null && git apply -R "$p"
  done
else
  for p in vibe-patches/*/*.patch; do
    [ -e "$p" ] || continue
    if git apply -R --check "$p" 2>/dev/null; then continue; fi   # already applied
    if git apply "$p"; then echo "applied $p"; else echo "::warning::patch failed: $p"; failed="$failed $p"; fi
  done
fi
[ -n "${GITHUB_OUTPUT:-}" ] && echo "failed=${failed# }" >> "$GITHUB_OUTPUT"
git add -A packages x11-packages root-packages
exit 0
