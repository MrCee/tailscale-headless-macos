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

: "${TS_HOSTNAME:?TS_HOSTNAME is required}"
: "${TAILNET_DOMAIN:?TAILNET_DOMAIN is required}"
: "${LAUNCHD_LABEL:?LAUNCHD_LABEL is required}"

BREW_BIN="${BREW_BIN:-brew}"
if ! command -v "${BREW_BIN}" >/dev/null 2>&1; then
  echo "ERROR: brew not found via BREW_BIN=${BREW_BIN}"
  exit 1
fi

BREW_PREFIX="$("${BREW_BIN}" --prefix)"
TS="${BREW_PREFIX}/bin/tailscale"
TSD="${BREW_PREFIX}/bin/tailscaled"

TAILSCALED_SOCKET="${TAILSCALED_SOCKET:-/var/run/tailscaled.socket}"

EXPECTED_RESOLVER_TAILNET="/etc/resolver/${TAILNET_DOMAIN}"
EXPECTED_RESOLVER_TSNET="/etc/resolver/ts.net"
EXPECTED_RESOLVER_SEARCH="/etc/resolver/search.tailscale"

echo "============================================================"
echo "TAILSCALE HEADLESS MACOS VERIFY"
echo "============================================================"
date
echo "ROOT_DIR            : ${ROOT_DIR}"
echo "BREW_BIN            : ${BREW_BIN}"
echo "BREW_PREFIX         : ${BREW_PREFIX}"
echo "TS                  : ${TS}"
echo "TSD                 : ${TSD}"
echo "TS_HOSTNAME         : ${TS_HOSTNAME}"
echo "TAILNET_DOMAIN      : ${TAILNET_DOMAIN}"
echo "LAUNCHD_LABEL       : ${LAUNCHD_LABEL}"
echo "TAILSCALED_SOCKET   : ${TAILSCALED_SOCKET}"
echo

echo "---- binaries ----"
ls -l "${TS}" "${TSD}" 2>/dev/null || true
"${TS}" version 2>/dev/null || true
echo

echo "---- daemon ----"
pgrep -fl tailscaled || true
sudo launchctl print "system/${LAUNCHD_LABEL}" 2>/dev/null | sed -n '1,40p' || true
echo

echo "---- tailscale ----"
"${TS}" status || true
"${TS}" ip -4 || true
echo
"${TS}" dns status --all || true
echo

echo "---- socket ----"
if [[ -S "${TAILSCALED_SOCKET}" ]]; then
  echo "[OK] tailscaled socket present: ${TAILSCALED_SOCKET}"
else
  echo "[WARN] tailscaled socket missing: ${TAILSCALED_SOCKET}"
fi
echo

echo "---- resolver files ----"
ls -la /etc/resolver 2>/dev/null || true
echo

if [[ -f "${EXPECTED_RESOLVER_TSNET}" ]]; then
  echo "---- ${EXPECTED_RESOLVER_TSNET} ----"
  cat "${EXPECTED_RESOLVER_TSNET}"
  echo
else
  echo "[WARN] missing resolver: ${EXPECTED_RESOLVER_TSNET}"
  echo
fi

if [[ -f "${EXPECTED_RESOLVER_TAILNET}" ]]; then
  echo "---- ${EXPECTED_RESOLVER_TAILNET} ----"
  cat "${EXPECTED_RESOLVER_TAILNET}"
  echo
else
  echo "[WARN] missing resolver: ${EXPECTED_RESOLVER_TAILNET}"
  echo
fi

if [[ -f "${EXPECTED_RESOLVER_SEARCH}" ]]; then
  echo "---- ${EXPECTED_RESOLVER_SEARCH} ----"
  cat "${EXPECTED_RESOLVER_SEARCH}"
  echo
else
  echo "[WARN] missing resolver: ${EXPECTED_RESOLVER_SEARCH}"
  echo
fi

echo "---- stale resolver check ----"
found_stale=0
stale_resolvers=(/etc/resolver/*.ts.net(N))
if (( ${#stale_resolvers[@]} )); then
  for resolver_file in "${stale_resolvers[@]}"; do
    resolver_name="$(basename "${resolver_file}")"

    if [[ "${resolver_name}" == "ts.net" ]]; then
      continue
    fi

    if [[ "${resolver_name}" == "${TAILNET_DOMAIN}" ]]; then
      continue
    fi

    echo "[WARN] stale resolver file detected: ${resolver_file}"
    found_stale=1
  done
fi

if [[ "${found_stale}" -eq 0 ]]; then
  echo "[OK] no stale tailnet resolver files detected"
fi
echo

echo "---- macOS DNS ----"
scutil --dns | grep -i "ts.net\|tailscale\|tail" -A4 -B2 || true
echo

echo "---- direct tests ----"
ping -c 1 100.100.100.100 2>/dev/null || true
echo
nslookup "${TS_HOSTNAME}.${TAILNET_DOMAIN}" 100.100.100.100 2>/dev/null || true
echo
dscacheutil -q host -a name "${TS_HOSTNAME}.${TAILNET_DOMAIN}" 2>/dev/null || true
echo

echo "---- logs ----"
sudo tail -n 30 /var/log/tailscaled.log 2>/dev/null || true
echo

echo "---- verdict ----"
if [[ -x "${TS}" ]]; then
  echo "[OK] tailscale binary detected"
else
  echo "[WARN] tailscale binary not detected"
fi

if [[ -x "${TSD}" ]]; then
  echo "[OK] tailscaled binary detected"
else
  echo "[WARN] tailscaled binary not detected"
fi

if pgrep -x tailscaled >/dev/null 2>&1; then
  echo "[OK] tailscaled process detected"
else
  echo "[WARN] tailscaled process not detected"
fi

if [[ -S "${TAILSCALED_SOCKET}" ]]; then
  echo "[OK] tailscaled socket present"
else
  echo "[WARN] tailscaled socket missing"
fi

if [[ -f "${EXPECTED_RESOLVER_TSNET}" ]]; then
  echo "[OK] ts.net resolver present"
else
  echo "[WARN] ts.net resolver missing"
fi

if [[ -f "${EXPECTED_RESOLVER_TAILNET}" ]]; then
  echo "[OK] tailnet resolver present"
else
  echo "[WARN] tailnet resolver missing"
fi

if [[ -f "${EXPECTED_RESOLVER_SEARCH}" ]]; then
  echo "[OK] search.tailscale resolver present"
else
  echo "[WARN] search.tailscale resolver missing"
fi

echo
echo "VERIFY COMPLETE"
