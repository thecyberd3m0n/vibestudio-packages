# shellcheck shell=bash
# Shared config and helpers for seeding/publishing the apt repo to Cloudflare R2.
# Sourced by seed-r2-repo.sh and publish-to-r2.sh.

# --- Repo layout constants (main / aarch64 only for now) --------------------
APT_REPO_NAME="termux-main"
APT_DISTRIBUTION="stable"
APT_COMPONENT="main"
APT_ARCHITECTURES="aarch64"
# Path prefix inside the bucket. Public URL is $R2_PUBLIC_BASE_URL/$APT_PREFIX.
APT_PREFIX="apt/termux-main"
# aptly's local metadata DB is stateful and runners are ephemeral, so we persist
# it in the same bucket and restore it on each run.
DB_OBJECT_KEY="apt/_aptly-db/aptly-db.tar.zst"

R2_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() { echo "ERROR: $*" >&2; exit 1; }

# Load credentials/config from an untracked env file if present.
[[ -f "$R2_DIR/r2.env" ]] && . "$R2_DIR/r2.env"

require_env() {
	local missing=()
	local v
	for v in "$@"; do
		[[ -n "${!v:-}" ]] || missing+=("$v")
	done
	(( ${#missing[@]} == 0 )) || die "Missing required env: ${missing[*]} (set them in $R2_DIR/r2.env or the environment)"
}

require_env R2_ACCOUNT_ID R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_BUCKET GPG_KEY_ID

R2_S3_ENDPOINT="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"
APT_PUBLISH_TARGET="s3:r2:${APT_PREFIX}/"

# aptly root (metadata DB + package pool references) and rendered config.
APTLY_ROOTDIR="${APTLY_ROOTDIR:-$HOME/.aptly}"
APTLY_CONFIG="${APTLY_CONFIG:-$R2_DIR/.aptly.conf}"

# aptly's S3 publisher reads these AWS_* vars directly (no CLI needed).
export AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID"
export AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
export AWS_DEFAULT_REGION="auto"
export AWS_REGION="auto"

# Ad-hoc rclone remote "r2" (configured entirely via env, no config file) used
# to store/restore the aptly metadata DB tarball in the same bucket.
export RCLONE_CONFIG_R2_TYPE="s3"
export RCLONE_CONFIG_R2_PROVIDER="Cloudflare"
export RCLONE_CONFIG_R2_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID"
export RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
export RCLONE_CONFIG_R2_ENDPOINT="$R2_S3_ENDPOINT"
export RCLONE_CONFIG_R2_REGION="auto"
# R2 doesn't implement the S3 bucket-existence/create check rclone does by default.
export RCLONE_CONFIG_R2_NO_CHECK_BUCKET="true"

ensure_tools() {
	local t
	for t in "$@"; do
		command -v "$t" >/dev/null 2>&1 || die "Required tool '$t' not found in PATH"
	done
}

# Ubuntu ships aptly 1.5.0, which still emits an empty x-amz-acl header that R2
# rejects ("acl: none" only works from 1.6.x). Prefer a repo-local 1.6+ binary.
APTLY_BIN="${APTLY_BIN:-}"
if [[ -z "$APTLY_BIN" ]]; then
	if [[ -x "$R2_DIR/bin/aptly" ]]; then
		APTLY_BIN="$R2_DIR/bin/aptly"
	else
		APTLY_BIN="aptly"
	fi
fi
command -v "$APTLY_BIN" >/dev/null 2>&1 || [[ -x "$APTLY_BIN" ]] \
	|| die "aptly >= 1.6 not found (set APTLY_BIN or place binary at $R2_DIR/bin/aptly)"

aptly_cmd() { "$APTLY_BIN" -config="$APTLY_CONFIG" "$@"; }

render_aptly_config() {
	# region is a label only (ignored when endpoint is set). acl=none because R2
	# has no canned ACLs; public read is served via the r2.dev URL. disableMultiDel
	# for R2 S3 batch-delete compatibility. Credentials come from the AWS_* env.
	cat > "$APTLY_CONFIG" <<EOF
{
  "rootDir": "${APTLY_ROOTDIR}",
  "gpgProvider": "gpg",
  "S3PublishEndpoints": {
    "r2": {
      "region": "auto",
      "bucket": "${R2_BUCKET}",
      "endpoint": "${R2_S3_ENDPOINT}",
      "acl": "none",
      "disableMultiDel": true
    }
  }
}
EOF
}

# Import the signing key into the local gpg keyring if it isn't already present
# (used by CI, where GPG_SIGNING_KEY holds the armored private key).
ensure_gpg_key() {
	if gpg --list-secret-keys "$GPG_KEY_ID" >/dev/null 2>&1; then
		return 0
	fi
	[[ -n "${GPG_SIGNING_KEY:-}" ]] || die "Signing key $GPG_KEY_ID not in gpg keyring and GPG_SIGNING_KEY is unset"
	if [[ -f "$GPG_SIGNING_KEY" ]]; then
		gpg --batch --import "$GPG_SIGNING_KEY"
	else
		printf '%s' "$GPG_SIGNING_KEY" | gpg --batch --import
	fi
	gpg --list-secret-keys "$GPG_KEY_ID" >/dev/null 2>&1 || die "Failed to import signing key $GPG_KEY_ID"
}

# Emit the aptly gpg passphrase flags on stdout (as separate lines) for the
# caller to read into an array. Empty when the key has no passphrase.
gpg_pass_args() {
	[[ -n "${GPG_PASSPHRASE:-}" ]] || return 0
	local pf; pf="$(mktemp)"
	printf '%s' "$GPG_PASSPHRASE" > "$pf"
	# Caller is responsible for the process lifetime; temp file is short-lived.
	printf -- '-batch\n-passphrase-file=%s\n' "$pf"
}

r2_db_push() {
	local tmp; tmp="$(mktemp -d)"
	local base; base="$(basename "$APTLY_ROOTDIR")"
	# Persist only aptly's metadata DB, not its local package pool: the pool
	# (all debs, many GB) already lives in R2 and aptly skips existing objects
	# by checksum, so shipping it would re-upload everything on every publish.
	tar -C "$(dirname "$APTLY_ROOTDIR")" --exclude="$base/pool" -c "$base" \
		| zstd -q -o "$tmp/db.tar.zst"
	rclone copyto "$tmp/db.tar.zst" "r2:$R2_BUCKET/$DB_OBJECT_KEY"
	rm -rf "$tmp"
	echo "Saved aptly DB to r2:$R2_BUCKET/$DB_OBJECT_KEY"
}

r2_db_pull() {
	local tmp; tmp="$(mktemp -d)"
	if rclone copyto "r2:$R2_BUCKET/$DB_OBJECT_KEY" "$tmp/db.tar.zst" >/dev/null 2>&1; then
		rm -rf "$APTLY_ROOTDIR"
		mkdir -p "$(dirname "$APTLY_ROOTDIR")"
		zstd -dq "$tmp/db.tar.zst" -c | tar -C "$(dirname "$APTLY_ROOTDIR")" -x
		rm -rf "$tmp"
		echo "Restored aptly DB from R2"
		return 0
	fi
	rm -rf "$tmp"
	echo "No aptly DB found in R2 (not seeded yet)"
	return 1
}
