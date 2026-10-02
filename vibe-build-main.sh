#!/bin/bash
# Build every main-repo (packages/) package for the target arch, ignoring errors.
# Dependencies are built from source (required because of the custom
# TERMUX_APP__PACKAGE_NAME/prefix, which makes prebuilt Termux debs incompatible).
#
# Run this INSIDE the builder container via run-docker.sh so the proper AppArmor
# build profile is active (it permits writes to the repo output/ dir):
#   TERMUX_DOCKER_EXEC_EXTRA_ARGS="--env TERMUX_PKG_MAKE_PROCESSES=10 --env TERMUX_ARCH=aarch64" \
#       ./scripts/run-docker.sh ./vibe-build-main.sh
#
# Logs/markers are written under $HOME (outside the repo) so they are always
# writable. Resumable: packages with a marker in $HOME/vibe-build-logs/done/ are skipped.

set -u

cd "$(dirname "$0")"

# Keep package builds non-interactive: corepack otherwise prompts before
# downloading pnpm/yarn and blocks the build (and would hang CI forever).
export COREPACK_ENABLE_DOWNLOAD_PROMPT=0

ARCH="${TERMUX_ARCH:-aarch64}"
LOGDIR="$HOME/vibe-build-logs"
DONEDIR="$LOGDIR/done"
FAILED="$LOGDIR/failed.txt"
SUMMARY="$LOGDIR/summary.log"
mkdir -p "$DONEDIR"
: > "$FAILED"

log() { echo "$(date '+%H:%M:%S') $*" | tee -a "$SUMMARY"; }

# Remove per-package build scratch to keep disk bounded. Preserves the download
# cache (_cache*) and built-package markers (.built-packages); installed deps live
# under /data, so this only drops regenerable src/build trees.
clean_scratch() {
	find "$HOME/.termux-build" -mindepth 1 -maxdepth 1 -type d \
		! -name '_*' ! -name '.*' -exec rm -rf {} + 2>/dev/null || true
}

mapfile -t pkgdirs < <(ls -d packages/*/ | sort)
total=${#pkgdirs[@]}
log "Starting main-repo build: arch=$ARCH cores=${TERMUX_PKG_MAKE_PROCESSES:-nproc} total=$total"

i=0
ok=0
fail=0
for d in "${pkgdirs[@]}"; do
	pkg=$(basename "$d")
	i=$((i + 1))
	if [ -e "$DONEDIR/$pkg" ]; then
		echo "[$i/$total] SKIP $pkg (already built)"
		ok=$((ok + 1))
		continue
	fi
	start=$(date +%s)
	if ./build-package.sh -a "$ARCH" "$d" > "$LOGDIR/$pkg.log" 2>&1; then
		touch "$DONEDIR/$pkg"
		ok=$((ok + 1))
		log "[$i/$total] OK   $pkg ($(( $(date +%s) - start ))s)"
	else
		fail=$((fail + 1))
		echo "$pkg" >> "$FAILED"
		log "[$i/$total] FAIL $pkg (see $LOGDIR/$pkg.log)"
	fi
	clean_scratch
done

log "DONE. ok=$ok fail=$fail. Failed packages listed in $FAILED"
