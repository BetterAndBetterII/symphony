#!/usr/bin/env bash
set -euo pipefail

REPO="BetterAndBetterII/symphony"
GITHUB_API="https://api.github.com/repos/${REPO}"

INSTALL_BIN_DIR="${SYMPHONY_BIN_DIR:-$HOME/.local/bin}"
INSTALL_ROOT_DIR="${SYMPHONY_ROOT_DIR:-$HOME/.local/share/symphony}"

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

need_cmd curl
need_cmd tar
need_cmd python3

OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
case "$OS" in
  linux|darwin) ;;
  *)
    echo "Unsupported OS: $OS" >&2
    exit 1
    ;;
esac

ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|amd64) ARCH="x86_64" ;;
  arm64|aarch64) ARCH="arm64" ;;
  *)
    echo "Unsupported architecture: $ARCH" >&2
    exit 1
    ;;
esac

TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

echo "Fetching latest release metadata for ${REPO}..."
RELEASE_JSON="$(curl -fsSL "${GITHUB_API}/releases/latest")"

export WANT_OS="$OS"
export WANT_ARCH="$ARCH"

read -r TAG ASSET_NAME DOWNLOAD_URL < <(
  python3 - <<'PY' <<<"$RELEASE_JSON"
import json
import os
import sys

data = json.load(sys.stdin)

tag = (data.get("tag_name") or "").strip()
assets = data.get("assets") or []

want_name = f"symphony-{tag}-{os.environ['WANT_OS']}-{os.environ['WANT_ARCH']}.tar.gz"

download_url = ""
for asset in assets:
  if (asset.get("name") or "").strip() == want_name:
    download_url = (asset.get("browser_download_url") or "").strip()
    break

if not tag:
  raise SystemExit("Failed to read tag_name from GitHub release metadata")

if not download_url:
  raise SystemExit(
    "No matching release asset found. "
    f"Expected: {want_name}. "
    "Check the release workflow output/assets."
  )

print(tag, want_name, download_url)
PY
)

echo "Latest version: ${TAG}"
echo "Downloading: ${ASSET_NAME}"

ARCHIVE_PATH="${TMP_DIR}/${ASSET_NAME}"
curl -fL --retry 3 --retry-delay 1 -o "$ARCHIVE_PATH" "$DOWNLOAD_URL"

VERSION_DIR="${INSTALL_ROOT_DIR}/${TAG}"
mkdir -p "$VERSION_DIR"

echo "Installing to: ${VERSION_DIR}"
rm -rf "${VERSION_DIR}/symphony"
tar -xzf "$ARCHIVE_PATH" -C "$VERSION_DIR"

if [[ ! -x "${VERSION_DIR}/symphony/bin/symphony" ]]; then
  echo "Install failed: missing executable ${VERSION_DIR}/symphony/bin/symphony" >&2
  exit 1
fi

mkdir -p "$INSTALL_ROOT_DIR"
ln -sfn "${VERSION_DIR}/symphony" "${INSTALL_ROOT_DIR}/current"

mkdir -p "$INSTALL_BIN_DIR"
WRAPPER_PATH="${INSTALL_BIN_DIR}/symphony"

cat >"$WRAPPER_PATH" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

INSTALL_ROOT_DIR="${SYMPHONY_ROOT_DIR:-$HOME/.local/share/symphony}"
REL_DIR="${INSTALL_ROOT_DIR}/current"
REL_BIN="${REL_DIR}/bin/symphony"

if [[ ! -x "$REL_BIN" ]]; then
  echo "symphony is not installed (missing $REL_BIN)" >&2
  exit 1
fi

# Default: run the service in the foreground using ./WORKFLOW.md from the current directory.
if [[ $# -eq 0 ]]; then
  exec "$REL_BIN" start
fi

# Advanced usage: allow users to invoke release commands directly.
exec "$REL_BIN" "$@"
SH

chmod +x "$WRAPPER_PATH"

echo
echo "Installed: ${WRAPPER_PATH}"

if ! echo "$PATH" | tr ':' '\n' | grep -Fxq "$INSTALL_BIN_DIR"; then
  echo "NOTE: ${INSTALL_BIN_DIR} is not on your PATH."
  echo "Add this to your shell profile:"
  echo "  export PATH=\"${INSTALL_BIN_DIR}:\$PATH\""
fi
