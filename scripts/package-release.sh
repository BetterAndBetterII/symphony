#!/bin/sh
set -eu

fail() {
  echo "error: $*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

normalize_os() {
  case "$1" in
    Linux|linux)
      echo "linux"
      ;;
    *)
      return 1
      ;;
  esac
}

normalize_arch() {
  case "$1" in
    x86_64|amd64)
      echo "amd64"
      ;;
    *)
      return 1
      ;;
  esac
}

strip_version_prefix() {
  case "$1" in
    v*)
      echo "${1#v}"
      ;;
    *)
      echo "$1"
      ;;
  esac
}

SCRIPT_DIR=$(CDPATH='' cd "$(dirname "$0")" && pwd -P)
REPO_ROOT=$(CDPATH='' cd "$SCRIPT_DIR/.." && pwd -P)
ELIXIR_DIR="$REPO_ROOT/elixir"
OUTPUT_DIR=${OUTPUT_DIR:-"$REPO_ROOT/dist"}
OS_INPUT=${1:-$(uname -s)}
ARCH_INPUT=${2:-$(uname -m)}

need_cmd mix
need_cmd tar
need_cmd mktemp
need_cmd cp
need_cmd rm
need_cmd find
need_cmd sed
need_cmd head
need_cmd sha256sum

os=$(normalize_os "$OS_INPUT") || fail "unsupported release OS: $OS_INPUT (supported: Linux)"
arch=$(normalize_arch "$ARCH_INPUT") || fail "unsupported release architecture: $ARCH_INPUT (supported: x86_64)"

version=$(sed -n 's/.*version: "\([^"]*\)".*/\1/p' "$ELIXIR_DIR/mix.exs" | head -n 1)
[ -n "$version" ] || fail "failed to resolve Mix project version"

if [ -n "${SYMPHONY_RELEASE_VERSION:-}" ]; then
  requested_version=$(strip_version_prefix "$SYMPHONY_RELEASE_VERSION")
  [ "$requested_version" = "$version" ] ||
    fail "release version mismatch: requested ${SYMPHONY_RELEASE_VERSION} but elixir/mix.exs is ${version}"
fi

artifact_root="symphony-v${version}-${os}-${arch}"
versioned_asset="${artifact_root}.tar.gz"
latest_asset="symphony-${os}-${arch}.tar.gz"
checksum_file="symphony-${os}-${arch}.sha256"

build_root=$(mktemp -d)
release_root="$build_root/release"
package_root="$build_root/$artifact_root"
cleanup() {
  rm -rf "$build_root"
}
trap cleanup EXIT INT TERM

mkdir -p "$OUTPUT_DIR"
rm -f "$OUTPUT_DIR/$versioned_asset" "$OUTPUT_DIR/$latest_asset" "$OUTPUT_DIR/$checksum_file"

(
  cd "$ELIXIR_DIR"
  MIX_ENV=prod mix release symphony --overwrite --path "$release_root"
)

[ -x "$release_root/bin/symphony" ] || fail "release build did not produce release/bin/symphony"

mkdir -p "$package_root/release"
printf '%s\n' "$version" > "$package_root/VERSION"
cp -R "$release_root/." "$package_root/release/"

(
  cd "$build_root"
  tar -czf "$OUTPUT_DIR/$versioned_asset" "$artifact_root"
)
cp "$OUTPUT_DIR/$versioned_asset" "$OUTPUT_DIR/$latest_asset"

(
  cd "$OUTPUT_DIR"
  sha256sum "$versioned_asset" "$latest_asset" > "$checksum_file"
)

printf 'Built %s\n' "$OUTPUT_DIR/$versioned_asset"
printf 'Built %s\n' "$OUTPUT_DIR/$latest_asset"
printf 'Built %s\n' "$OUTPUT_DIR/$checksum_file"
