#!/bin/zsh -f
# One entry point for headless Tailscale and its included automatic updates.
set -eu
set -o pipefail

readonly ROOT_DIR=${0:A:h}
readonly ENV_FILE="$ROOT_DIR/.env"
readonly UPDATER_LABEL=com.tailscale.headless-updater
readonly UPDATER_PLIST=/Library/LaunchDaemons/com.tailscale.headless-updater.plist
CHECK_ONLY=false

fail() { print -u2 -r -- "ERROR: $*"; exit 1; }
usage() {
  print 'Usage: ./install.sh [--check]'
  print 'Installs headless Tailscale with automatic updates, or maintains an existing installation.'
  print 'Fresh setup: configure .env first. Existing compatible installations can use the defaults.'
  print '--check validates the setup without changing installed files or services.'
}
case "${1:-}" in
  '') (( $# == 0 )) || { usage >&2; exit 1; } ;;
  --check) (( $# == 1 )) || { usage >&2; exit 1; }; CHECK_ONLY=true ;;
  --help|-h) usage; exit 0 ;;
  *) usage >&2; exit 1 ;;
esac
[[ $EUID != 0 ]] || fail 'Run ./install.sh as your normal Homebrew user, without sudo. Administrator authentication is requested when needed.'
[[ $(/usr/bin/uname -s) == Darwin ]] || fail 'This installer requires macOS.'

# This file is local user configuration; it is never sourced by a root job.
if [[ -f "$ENV_FILE" ]]; then source "$ENV_FILE"; fi
AUTO_UPDATE=${AUTO_UPDATE:-true}
AUTO_UPDATE_HOUR=${AUTO_UPDATE_HOUR:-4}
AUTO_UPDATE_MINUTE=${AUTO_UPDATE_MINUTE:-15}
BREW_BIN=${BREW_BIN:-brew}
LAUNCHD_LABEL=${LAUNCHD_LABEL:-com.tailscale.tailscaled}
LAUNCHD_PLIST=${LAUNCHD_PLIST:-/Library/LaunchDaemons/${LAUNCHD_LABEL}.plist}
TAILSCALED_SOCKET=${TAILSCALED_SOCKET:-/var/run/tailscaled.socket}

case "${AUTO_UPDATE:l}" in
  true|yes|1) AUTO_UPDATE=true ;;
  false|no|0) AUTO_UPDATE=false ;;
  *) fail 'AUTO_UPDATE must be true or false.' ;;
esac
[[ "$AUTO_UPDATE_HOUR" == <0-23> && "$AUTO_UPDATE_MINUTE" == <0-59> ]] || fail 'AUTO_UPDATE_HOUR must be 0-23 and AUTO_UPDATE_MINUTE must be 0-59.'
[[ "$LAUNCHD_LABEL" == [A-Za-z0-9]* && "$LAUNCHD_LABEL" != *[^A-Za-z0-9._-]* ]] || fail 'Invalid LAUNCHD_LABEL.'
[[ "$LAUNCHD_PLIST" == "/Library/LaunchDaemons/$LAUNCHD_LABEL.plist" ]] || fail 'LAUNCHD_PLIST must match the configured service label in /Library/LaunchDaemons.'
[[ "$TAILSCALED_SOCKET" == /* && "$TAILSCALED_SOCKET" != *$'\n'* ]] || fail 'TAILSCALED_SOCKET must be an absolute path.'
BREW_BIN=$(command -v "$BREW_BIN") || fail 'Homebrew is required. Install it from https://brew.sh, then rerun ./install.sh.'
[[ "$BREW_BIN" == /* && -x "$BREW_BIN" ]] || fail 'BREW_BIN must resolve to an executable absolute path.'
BREW_PREFIX=$("$BREW_BIN" --prefix)
[[ "$BREW_PREFIX" == /usr/local || "$BREW_PREFIX" == /opt/homebrew ]] || fail 'Only standard Intel and Apple Silicon Homebrew prefixes are supported.'

readonly UPDATE_INSTALLER="$ROOT_DIR/scripts/install-auto-updates.sh"
readonly UPDATE_REMOVER="$ROOT_DIR/scripts/remove-auto-updates.sh"
readonly BASE_INSTALLER="$ROOT_DIR/scripts/install-headless.sh"
[[ -x "$UPDATE_INSTALLER" && -x "$UPDATE_REMOVER" && -x "$BASE_INSTALLER" ]] || fail 'The download is incomplete: required installation helpers are missing.'
update_args=(--brew "$BREW_BIN" --label "$LAUNCHD_LABEL" --socket "$TAILSCALED_SOCKET" --hour "$AUTO_UPDATE_HOUR" --minute "$AUTO_UPDATE_MINUTE")

EXISTING=false
if /bin/launchctl print "system/$LAUNCHD_LABEL" >/dev/null 2>&1; then
  EXISTING=true
else
  # A partial installation needs diagnosis before any script replaces its state
  # or kills a daemon that may belong to a different service.
  [[ ! -e "$LAUNCHD_PLIST" ]] || fail 'The Tailscale plist exists but its service is not loaded. Repair that service before rerunning installation.'
  if /usr/bin/pgrep -x tailscaled >/dev/null 2>&1; then
    fail 'A tailscaled process is already running outside the selected service. Set the correct LAUNCHD_LABEL in .env before continuing.'
  fi
  [[ -f "$ENV_FILE" ]] || fail 'Fresh setup requires .env. Copy .env.example to .env and set your TAILNET_DOMAIN, then rerun ./install.sh.'
  [[ -n "${TAILNET_DOMAIN:-}" && "$TAILNET_DOMAIN" == *.ts.net && "$TAILNET_DOMAIN" != your-tailnet.ts.net && "$TAILNET_DOMAIN" != example-tailnet.ts.net ]] || fail 'Set your own TAILNET_DOMAIN in .env before installing.'
fi

print '============================================================'
print 'TAILSCALE HEADLESS MACOS SETUP'
print '============================================================'
if [[ "$EXISTING" == true ]]; then
  print 'Existing system daemon detected. Its state, authentication, hostname and DNS settings will be preserved.'
else
  print 'Fresh setup will install the daemon, configure MagicDNS and authenticate Tailscale.'
fi
if [[ "$AUTO_UPDATE" == true ]]; then
  printf 'Automatic updates are included: at boot and daily at %02d:%02d local time.\n' "$AUTO_UPDATE_HOUR" "$AUTO_UPDATE_MINUTE"
else
  print 'AUTO_UPDATE=false: automatic updates will be disabled; the Tailscale daemon remains installed.'
fi

if [[ "$CHECK_ONLY" == true ]]; then
  if [[ "$EXISTING" == true && "$AUTO_UPDATE" == true ]]; then
    "$UPDATE_INSTALLER" --check "${update_args[@]}"
  else
    print 'Configuration checks passed. No installed files or services changed.'
  fi
  exit 0
fi

if [[ "$EXISTING" == false ]]; then
  # Older .env files inherit the same service defaults in the base installer.
  export BREW_BIN LAUNCHD_LABEL LAUNCHD_PLIST TAILSCALED_SOCKET
  if ! "$BASE_INSTALLER"; then
    fail 'Daemon installation did not complete. Automatic updates were not configured.'
  fi
fi
if [[ "$AUTO_UPDATE" == true ]]; then
  if ! "$UPDATE_INSTALLER" "${update_args[@]}"; then
    fail 'Setup is incomplete: automatic updates could not be configured. Resolve the reported issue, then rerun ./install.sh; the existing daemon will be preserved.'
  fi
  print 'INSTALL COMPLETE: headless Tailscale and automatic updates are configured.'
  print 'Update results: /var/log/tailscale-headless-update.log'
else
  if [[ -f "$UPDATER_PLIST" ]] || /bin/launchctl print "system/$UPDATER_LABEL" >/dev/null 2>&1; then
    "$UPDATE_REMOVER" || fail 'Could not disable automatic updates; the daemon was left untouched.'
  fi
  print 'INSTALL COMPLETE: headless Tailscale is configured; automatic updates were explicitly disabled.'
fi
