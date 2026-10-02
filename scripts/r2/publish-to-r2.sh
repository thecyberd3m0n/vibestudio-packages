#!/bin/bash
# Add freshly-built .deb files to the R2 apt repo and republish.
# Used by CI (and safe to run locally). Requires the repo to be seeded first.
#
# Usage: scripts/r2/publish-to-r2.sh DEB_OR_DIR [DEB_OR_DIR ...]

set -euo pipefail

cd "$(dirname "$0")/../.."
. scripts/r2/_r2-common.sh

(( $# > 0 )) || die "Usage: $0 DEB_OR_DIR [DEB_OR_DIR ...]"

ensure_tools gpg rclone zstd dpkg-deb
ensure_gpg_key

# Collect .deb paths from the given files and/or directories.
DEBS=()
for arg in "$@"; do
	if [[ -d "$arg" ]]; then
		while IFS= read -r f; do DEBS+=("$f"); done \
			< <(find "$arg" -type f -name '*.deb' | sort)
	elif [[ -f "$arg" && "$arg" == *.deb ]]; then
		DEBS+=("$arg")
	else
		die "Not a .deb file or directory: $arg"
	fi
done
(( ${#DEBS[@]} > 0 )) || die "No .deb files to publish"
echo "Publishing ${#DEBS[@]} .deb files"

render_aptly_config

# Restore the aptly metadata DB from R2; the repo must already exist (seeded).
r2_db_pull || die "aptly DB not found in R2 — run scripts/r2/seed-r2-repo.sh first"
aptly_cmd repo list -raw | grep -qx "$APT_REPO_NAME" \
	|| die "Repo '$APT_REPO_NAME' missing from restored DB"

# Drop any existing versions of these packages first so the repo stays
# latest-only and same-version rebuilds don't collide in the pool.
NAMES=()
for _deb in "${DEBS[@]}"; do
	NAMES+=("$(dpkg-deb -f "$_deb" Package)")
done
if (( ${#NAMES[@]} )); then
	aptly_cmd repo remove "$APT_REPO_NAME" "${NAMES[@]}" || true
fi

aptly_cmd repo add -force-replace "$APT_REPO_NAME" "${DEBS[@]}"

mapfile -t PASS_ARGS < <(gpg_pass_args)
aptly_cmd publish update "${PASS_ARGS[@]}" \
	-gpg-key="$GPG_KEY_ID" \
	"$APT_DISTRIBUTION" "$APT_PUBLISH_TARGET"

# Drop pool objects no longer referenced by the repo (frees R2 space).
aptly_cmd db cleanup || true

r2_db_push
echo "Published update to $APT_PUBLISH_TARGET"
