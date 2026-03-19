#!/bin/zsh
set -euo pipefail

echo "---- sudo authentication upfront ----"
sudo -v

(
  while true; do
    sudo -n true 2>/dev/null || exit 0
    sleep 30
  done
) &
SUDO_KEEPALIVE_PID=$!

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${ROOT_DIR}/.env"

cleanup() {
  local ec=$?

  if [[ -n "${SUDO_KEEPALIVE_PID:-}" ]]; then
    kill "${SUDO_KEEPALIVE_PID}" 2>/dev/null || true
  fi

  exit "${ec}"
}
trap cleanup EXIT INT TERM

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "ERROR: .env not found in ${ROOT_DIR}"
  exit 1
fi

source "${ENV_FILE}"

BREW_BIN="${BREW_BIN:-brew}"
if ! command -v "${BREW_BIN}" >/dev/null 2>&1; then
  echo "ERROR: brew not found via BREW_BIN=${BREW_BIN}"
  exit 1
fi

BREW_PREFIX="$("${BREW_BIN}" --prefix)"
TS="${BREW_PREFIX}/bin/tailscale"
TSD="${BREW_PREFIX}/bin/tailscaled"

LAUNCHD_LABEL="${LAUNCHD_LABEL:-com.tailscale.tailscaled}"
LAUNCHD_PLIST="${LAUNCHD_PLIST:-/Library/LaunchDaemons/${LAUNCHD_LABEL}.plist}"
STATE_DIR="${STATE_DIR:-/var/lib/tailscale}"
STATE_FILE="${STATE_FILE:-${STATE_DIR}/tailscaled.state}"
LOG_OUT="${LOG_OUT:-/var/log/tailscaled.log}"
LOG_ERR="${LOG_ERR:-/var/log/tailscaled.log}"
TAILSCALED_SOCKET="${TAILSCALED_SOCKET:-/var/run/tailscaled.socket}"
TAILNET_DOMAIN="${TAILNET_DOMAIN:-}"

echo "============================================================"
echo "TAILSCALE HEADLESS MACOS UNINSTALL"
echo "============================================================"
echo "ROOT_DIR            : ${ROOT_DIR}"
echo "BREW_BIN            : ${BREW_BIN}"
echo "BREW_PREFIX         : ${BREW_PREFIX}"
echo "TS                  : ${TS}"
echo "TSD                 : ${TSD}"
echo "LAUNCHD_LABEL       : ${LAUNCHD_LABEL}"
echo "LAUNCHD_PLIST       : ${LAUNCHD_PLIST}"
echo "STATE_DIR           : ${STATE_DIR}"
echo "STATE_FILE          : ${STATE_FILE}"
echo "LOG_OUT             : ${LOG_OUT}"
echo "LOG_ERR             : ${LOG_ERR}"
echo "TAILSCALED_SOCKET   : ${TAILSCALED_SOCKET}"
echo "TAILNET_DOMAIN      : ${TAILNET_DOMAIN:-<unset>}"
echo "============================================================"
echo

echo "---- disconnect if available ----"
if [[ -x "${TS}" ]]; then
  sudo "${TS}" down 2>/dev/null || true
else
  echo "tailscale binary not found at: ${TS} (continuing)"
fi

echo
echo "---- stop daemon ----"
sudo launchctl bootout "system/${LAUNCHD_LABEL}" 2>/dev/null || true
sudo launchctl remove "${LAUNCHD_LABEL}" 2>/dev/null || true
sudo pkill -x tailscaled 2>/dev/null || true
sudo rm -f "${LAUNCHD_PLIST}" "${TAILSCALED_SOCKET}"

echo
echo "---- remove launchd / state / logs ----"
sudo rm -f "${LAUNCHD_PLIST}"
sudo rm -f "${LOG_OUT}"
[[ "${LOG_ERR}" == "${LOG_OUT}" ]] || sudo rm -f "${LOG_ERR}"
sudo rm -rf "${STATE_DIR}"
sudo rm -rf /Library/Application\ Support/Tailscale
sudo rm -rf /Library/Caches/Tailscale
sudo rm -f /Library/Preferences/com.tailscale.ipn.macos.plist
sudo rm -f /Library/PrivilegedHelperTools/com.tailscale.ipn.macsys
sudo rm -rf /Library/SystemExtensions/*/com.tailscale.ipn.macos.systemextension 2>/dev/null || true

echo
echo "---- remove resolver files ----"
sudo rm -f /etc/resolver/ts.net
sudo rm -f /etc/resolver/search.tailscale
if [[ -n "${TAILNET_DOMAIN}" ]]; then
  sudo rm -f "/etc/resolver/${TAILNET_DOMAIN}"
fi

echo
echo "---- remove stale tailnet resolver files ----"
stale_resolvers=(/etc/resolver/*.ts.net(N))
if (( ${#stale_resolvers[@]} )); then
  for resolver_file in "${stale_resolvers[@]}"; do
    echo "Removing stale resolver: ${resolver_file}"
    sudo rm -f "${resolver_file}"
  done
else
  echo "No stale tailnet resolver files found"
fi

echo
echo "---- flush DNS caches ----"
sudo dscacheutil -flushcache 2>/dev/null || true
sudo killall -HUP mDNSResponder 2>/dev/null || true
sudo killall mDNSResponderHelper 2>/dev/null || true

echo
echo "---- optional brew uninstall ----"
case "${REMOVE_BREW_PACKAGE:-false}" in
  true|TRUE|yes|YES|1)
    "${BREW_BIN}" uninstall tailscale 2>/dev/null || true
    ;;
  false|FALSE|no|NO|0|"")
    echo "Skipping Homebrew uninstall (set REMOVE_BREW_PACKAGE=true in .env to remove it)"
    ;;
  *)
    echo "WARNING: invalid REMOVE_BREW_PACKAGE value: ${REMOVE_BREW_PACKAGE}"
    echo "Skipping Homebrew uninstall"
    ;;
esac

echo
echo "---- final checks ----"
ls -la /etc/resolver 2>/dev/null || true
echo
sudo launchctl print "system/${LAUNCHD_LABEL}" 2>/dev/null || true
echo
pgrep -lf tailscale 2>/dev/null || true
echo
if command -v "${BREW_BIN}" >/dev/null 2>&1; then
  "${BREW_BIN}" list --formula 2>/dev/null | grep -x tailscale || true
fi

echo
echo "============================================================"
echo "UNINSTALL COMPLETE"
echo "============================================================"
