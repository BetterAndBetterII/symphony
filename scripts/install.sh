#!/bin/sh
set -eu

APP_NAME="Symphony"
DEFAULT_REPO="BetterAndBetterII/symphony"

fail() {
  echo "Error: $*" >&2
  exit 1
}

info() {
  printf '==> %s\n' "$*"
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

normalize_version() {
  case "$1" in
    v*)
      echo "$1"
      ;;
    *)
      echo "v$1"
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

write_wrapper() {
  wrapper_path=$1

  cat > "$wrapper_path" <<'WRAPPER'
#!/bin/sh
set -eu

data_root=${SYMPHONY_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/symphony}
release_bin="$data_root/current/release/bin/symphony"

if [ ! -x "$release_bin" ]; then
  echo "Symphony is not installed under $data_root/current. Re-run the installer." >&2
  exit 1
fi

exec "$release_bin" eval 'SymphonyElixir.CLI.main(System.argv())' "$@"
WRAPPER

  chmod +x "$wrapper_path"
}

need_cmd curl
need_cmd tar
need_cmd mktemp
need_cmd dirname
need_cmd mkdir
need_cmd ln
need_cmd rm
need_cmd mv
need_cmd cat
need_cmd find
need_cmd head

repo=${SYMPHONY_REPO:-$DEFAULT_REPO}
release_base_url=${SYMPHONY_RELEASE_BASE_URL:-"https://github.com/${repo}/releases"}
os=$(normalize_os "$(uname -s)") || fail "unsupported platform: $(uname -s) (supported: Linux x86_64)"
arch=$(normalize_arch "$(uname -m)") || fail "unsupported architecture: $(uname -m) (supported: Linux x86_64)"
bin_dir=${SYMPHONY_BIN_DIR:-${XDG_BIN_HOME:-$HOME/.local/bin}}
data_root=${SYMPHONY_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/symphony}

if [ -n "${SYMPHONY_VERSION:-}" ]; then
  version_tag=$(normalize_version "$SYMPHONY_VERSION")
  requested_label=$version_tag
  asset_name="symphony-${version_tag}-${os}-${arch}.tar.gz"
  download_url="${release_base_url}/download/${version_tag}/${asset_name}"
else
  requested_label="latest"
  asset_name="symphony-${os}-${arch}.tar.gz"
  download_url="${release_base_url}/latest/download/${asset_name}"
fi

tmp_root=$(mktemp -d)
archive_path="$tmp_root/$asset_name"
cleanup() {
  rm -rf "$tmp_root"
}
trap cleanup EXIT INT TERM

info "Downloading ${APP_NAME} ${requested_label} for ${os}/${arch}"
curl -fsSL "$download_url" -o "$archive_path" || fail "download failed: $download_url"

info "Extracting release payload"
tar -xzf "$archive_path" -C "$tmp_root"

package_dir=$(find "$tmp_root" -mindepth 1 -maxdepth 1 -type d | head -n 1)
[ -n "$package_dir" ] || fail "release archive did not contain an installable payload"
[ -f "$package_dir/VERSION" ] || fail "release payload is missing VERSION metadata"

version=$(cat "$package_dir/VERSION")
[ -n "$version" ] || fail "release payload VERSION file is empty"

if [ -n "${SYMPHONY_VERSION:-}" ]; then
  requested_version=$(strip_version_prefix "$SYMPHONY_VERSION")
  actual_version=$(strip_version_prefix "$version")
  [ "$requested_version" = "$actual_version" ] ||
    fail "downloaded payload version ${version} does not match requested version ${SYMPHONY_VERSION}"
fi

target_dir="$data_root/$version"
release_bin="$target_dir/release/bin/symphony"

info "Installing ${APP_NAME} ${version} into $target_dir"
mkdir -p "$data_root"
rm -rf "$target_dir"
mv "$package_dir" "$target_dir"
ln -sfn "$target_dir" "$data_root/current"

mkdir -p "$bin_dir"
write_wrapper "$bin_dir/symphony"

[ -x "$release_bin" ] || fail "installed payload is missing release/bin/symphony"

info "Installed binary: $bin_dir/symphony"
info "Current release: $data_root/current"

case ":$PATH:" in
  *":$bin_dir:"*)
    ;;
  *)
    printf 'Note: add %s to PATH to run `symphony` from new shells.\n' "$bin_dir"
    ;;
esac

printf 'Run `symphony` from any project directory. It will create `WORKFLOW.md` when missing.\n'
