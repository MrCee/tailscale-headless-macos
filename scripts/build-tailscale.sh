#!/bin/bash
# Build a pinned stable CLI/daemon pair as an unprivileged user. Bash 3.2.
set -euo pipefail
export PATH=/opt/homebrew/bin:/usr/local/go/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
umask 077
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
fetch() { /usr/bin/curl --proto '=https' --tlsv1.2 --fail --silent --show-error --location --retry 2 --connect-timeout 20 --max-time 600 "$1"; }
json() { /usr/bin/plutil -extract "$1" raw -o - -; }
detect_architecture() {
  [[ $(/usr/bin/uname -s) == Darwin ]] || fail 'macOS is required.'
  local machine
  machine=$(/usr/bin/uname -m)
  # A translated Intel shell still needs native ARM64 Go and daemon binaries.
  if [[ $(/usr/sbin/sysctl -n hw.optional.arm64 2>/dev/null || true) == 1 ]]; then machine=arm64; fi
  case "$machine" in
    x86_64) goarch=amd64; native_arch=x86_64 ;;
    arm64) goarch=arm64; native_arch=arm64 ;;
    *) fail "Unsupported Mac architecture: $machine" ;;
  esac
}
stable_version() {
  [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  local minor=${1#*.}; minor=${minor%%.*}
  (( 10#$minor % 2 == 0 ))
}
latest_version() {
  local metadata version
  metadata=$(fetch 'https://pkgs.tailscale.com/stable/?mode=json') || return 1
  version=$(printf '%s' "$metadata" | json TarballsVersion) || return 1
  stable_version "$version" || return 1
  printf '%s\n' "$version"
}
version_at_least() {
  [[ $(printf '%s\n%s\n' "$1" "$2" | /usr/bin/sort -t. -k1,1n -k2,2n -k3,3n | /usr/bin/head -n 1) == "$2" ]]
}
ensure_go() {
  local required=$1 candidate info installed metadata index filename checksum archive
  candidate=${GO_BIN:-$(command -v go || true)}
  if [[ -n "$candidate" && -x "$candidate" ]]; then
    info=$(GOTOOLCHAIN=local "$candidate" version 2>/dev/null || true)
    installed=$(printf '%s\n' "$info" | /usr/bin/awk '{sub(/^go/, "", $3); print $3}')
    if [[ "$info" == *"darwin/$goarch" && "$installed" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && version_at_least "$installed" "$required"; then
      go_bin=$candidate; return 0
    fi
  fi
  candidate="$cache/go/bin/go"
  if [[ -x "$candidate" ]]; then
    info=$(GOTOOLCHAIN=local "$candidate" version 2>/dev/null || true)
    installed=$(printf '%s\n' "$info" | /usr/bin/awk '{sub(/^go/, "", $3); print $3}')
    if [[ "$info" == *"darwin/$goarch" && "$installed" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && version_at_least "$installed" "$required"; then
      go_bin=$candidate; return 0
    fi
  fi
  metadata=$(fetch 'https://go.dev/dl/?mode=json') || fail 'Cannot retrieve official Go release metadata.'
  [[ $(printf '%s' "$metadata" | json 0.stable) == true ]] || fail 'Go release is not stable.'
  installed=$(printf '%s' "$metadata" | json 0.version); installed=${installed#go}
  [[ "$installed" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && version_at_least "$installed" "$required" || fail "Latest Go cannot build this release (requires $required)."
  filename=''; checksum=''
  for (( index=0; index<200; index++ )); do
    info=$(printf '%s' "$metadata" | json "0.files.$index.filename" 2>/dev/null) || break
    if [[ "$info" == "go$installed.darwin-$goarch.tar.gz" ]]; then
      filename=$info
      checksum=$(printf '%s' "$metadata" | json "0.files.$index.sha256")
      break
    fi
  done
  [[ -n "$filename" && "$checksum" =~ ^[a-f0-9]{64}$ ]] || fail "Official Go $goarch archive/checksum unavailable."
  archive="$work/go.tar.gz"
  printf 'Downloading verified Go %s for macOS %s.\n' "$installed" "$native_arch" >&2
  fetch "https://go.dev/dl/$filename" > "$archive" || fail 'Go download failed.'
  [[ $(/usr/bin/shasum -a 256 "$archive" | /usr/bin/awk '{print $1}') == "$checksum" ]] || fail 'Go checksum mismatch; refusing to extract.'
  /bin/mkdir "$work/toolchain"
  /usr/bin/tar -xzf "$archive" -C "$work/toolchain"
  [[ $(GOTOOLCHAIN=local "$work/toolchain/go/bin/go" version) == "go version go$installed darwin/$goarch" ]] || fail 'Downloaded Go cannot run on this Mac.'
  /bin/rm -rf "$cache/go"
  /bin/mv "$work/toolchain/go" "$cache/go"
  go_bin="$cache/go/bin/go"
}
main() {
  detect_architecture
  if [[ $# == 1 && "$1" == --latest ]]; then latest_version; return; fi
  [[ $EUID != 0 ]] || fail 'Build as a normal user, not root.'
  local version='' output='' go_bin
  cache="${HOME:?}/Library/Caches/tailscale-headless"
  work=''
  while (( $# )); do
    case "$1" in
      --version|--output|--cache)
        [[ $# -ge 2 ]] || fail "Missing value for $1"
        case "$1" in --version) version=$2 ;; --output) output=$2 ;; --cache) cache=$2 ;; esac
        shift 2 ;;
      *) fail 'Usage: build-tailscale.sh --output DIR [--version X.Y.Z] [--cache DIR], or --latest' ;;
    esac
  done
  [[ "$output" == /* && "$cache" == /* ]] || fail 'Output and cache must be absolute paths.'
  [[ ! -e "$output" && ! -L "$output" ]] || fail 'Output destination already exists.'
  [[ -n "$version" ]] || version=$(latest_version)
  stable_version "$version" || fail 'Select a stable numeric Tailscale release (even minor version).'
  /bin/mkdir -p "$cache"
  # One build per cache, including toolchain replacement. Never clear a live lock.
  /bin/mkdir "$cache/build.lock" 2>/dev/null || fail "Build cache is locked: $cache/build.lock"
  work=$(/usr/bin/mktemp -d "$cache/build.XXXXXX")
  trap '/bin/rm -rf "$work"; /bin/rmdir "$cache/build.lock"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  local mod required info module_dir hash binary expected actual
  mod=$(fetch "https://proxy.golang.org/tailscale.com/@v/v$version.mod") || fail 'Cannot retrieve release Go requirement.'
  required=$(printf '%s\n' "$mod" | /usr/bin/awk '$1 == "go" {print $2; exit}')
  [[ "$required" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || fail 'Missing/invalid Go requirement.'
  [[ "$required" =~ ^[0-9]+\.[0-9]+$ ]] && required="$required.0"
  unset GOROOT
  export GOENV=off GOWORK=off GOTOOLCHAIN=local
  ensure_go "$required"
  export GOENV=off GOWORK=off GOTOOLCHAIN=local GOFLAGS='' GOPROXY=https://proxy.golang.org GOSUMDB=sum.golang.org
  export GOPRIVATE='' GONOSUMDB='' GONOPROXY='' GOINSECURE='' CGO_ENABLED=0 GOOS=darwin GOARCH="$goarch"
  unset GOAMD64 GOARM64
  if [[ "$goarch" == amd64 ]]; then export GOAMD64=v1; else export GOARM64=v8.0; fi
  export GOPATH="$cache/gopath" GOCACHE="$cache/go-build" GOMODCACHE="$cache/gopath/pkg/mod"
  export PATH="${go_bin%/*}:/usr/bin:/bin:/usr/sbin:/sbin"
  info=$("$go_bin" mod download -json "tailscale.com@v$version") || fail 'Release download/checksum verification failed.'
  module_dir=$(printf '%s' "$info" | json Dir)
  info=$(fetch "https://proxy.golang.org/tailscale.com/@v/v$version.info")
  [[ $(printf '%s' "$info" | json Version) == "v$version" ]] || fail 'Release metadata mismatch.'
  hash=$(printf '%s' "$info" | json Origin.Hash)
  [[ "$hash" =~ ^[a-f0-9]{40}$ ]] || fail 'Missing release commit hash.'
  export TS_VERSION_LONG="$version-t${hash:0:9}" TS_VERSION_GIT_HASH="$hash"
  unset TS_VERSION_OVERRIDE TS_VERSION_EXTRA_GIT_HASH TS_USE_TOOLCHAIN TAGS GOROOT
  expected=$TS_VERSION_LONG
  /bin/mkdir "$work/bin"
  for binary in tailscale tailscaled; do
    printf 'Building %s %s (darwin/%s).\n' "$binary" "$version" "$goarch" >&2
    (cd "$module_dir" && /bin/sh ./build_dist.sh -o "$work/bin/$binary" "./cmd/$binary") || fail "Build failed: $binary"
    /usr/bin/lipo "$work/bin/$binary" -verify_arch "$native_arch" || fail "Built binary is not $native_arch."
    actual=$("$work/bin/$binary" --version | /usr/bin/awk '/^[[:space:]]*long version: / {print $3; exit}')
    [[ "$actual" == "$expected" ]] || fail "Built version mismatch: $binary ($actual)"
  done
  /bin/mkdir "$output"
  /bin/cp "$work/bin/tailscale" "$work/bin/tailscaled" "$output/"
  printf '%s\n' "$expected" > "$output/version"
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
