#!/bin/bash
# One-time seed of the R2 apt repo from locally-built .deb files.
# Run this once from your build machine after the local build populates output/.
#
# Usage: scripts/r2/seed-r2-repo.sh [DEBS_DIR]
#   DEBS_DIR defaults to ./output (where the Termux build system writes debs).

set -euo pipefail

cd "$(dirname "$0")/../.."
. scripts/r2/_r2-common.sh

DEBS_DIR="${1:-output}"
[[ -d "$DEBS_DIR" ]] || die "Debs directory '$DEBS_DIR' not found"

ensure_tools gpg rclone zstd
ensure_gpg_key

mapfile -t DEBS < <(find "$DEBS_DIR" -type f -name '*.deb' | sort)
(( ${#DEBS[@]} > 0 )) || die "No .deb files found under '$DEBS_DIR'"
echo "Found ${#DEBS[@]} .deb files under $DEBS_DIR"

render_aptly_config

# Create the local repo if it doesn't exist yet.
if ! aptly_cmd repo list -raw | grep -qx "$APT_REPO_NAME"; then
	aptly_cmd repo create \
		-distribution="$APT_DISTRIBUTION" \
		-component="$APT_COMPONENT" \
		"$APT_REPO_NAME"
fi

echo "Adding packages to '$APT_REPO_NAME'..."
aptly_cmd repo add -force-replace "$APT_REPO_NAME" "${DEBS[@]}"

mapfile -t PASS_ARGS < <(gpg_pass_args)

if aptly_cmd publish list -raw | awk '{print $2}' | grep -qx "$APT_DISTRIBUTION"; then
	echo "Repo already published; updating..."
	aptly_cmd publish update "${PASS_ARGS[@]}" \
		-gpg-key="$GPG_KEY_ID" \
		"$APT_DISTRIBUTION" "$APT_PUBLISH_TARGET"
else
	echo "Publishing repo to $APT_PUBLISH_TARGET ..."
	aptly_cmd publish repo "${PASS_ARGS[@]}" \
		-architectures="$APT_ARCHITECTURES" \
		-gpg-key="$GPG_KEY_ID" \
		"$APT_REPO_NAME" "$APT_PUBLISH_TARGET"
fi

r2_db_push

cat <<EOF

Seed complete. Verify with:
  curl -fsS ${R2_PUBLIC_BASE_URL:-https://<your-pub>.r2.dev}/${APT_PREFIX}/dists/${APT_DISTRIBUTION}/Release | head
  curl -fsS ${R2_PUBLIC_BASE_URL:-https://<your-pub>.r2.dev}/${APT_PREFIX}/dists/${APT_DISTRIBUTION}/InRelease | head
EOF
