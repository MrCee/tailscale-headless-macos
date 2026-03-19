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
  echo "Copy .env.example to .env and edit it first."
  exit 1
fi

source "${ENV_FILE}"

: "${TAILNET_DOMAIN:?TAILNET_DOMAIN is required}"

echo "============================================================"
echo "TAILSCALE HEADLESS MACOS MAGICDNS REPAIR"
echo "============================================================"
echo "ROOT_DIR        : ${ROOT_DIR}"
echo "TAILNET_DOMAIN  : ${TAILNET_DOMAIN}"
echo "============================================================"

echo
echo "---- ensure resolver directory ----"
sudo mkdir -p /etc/resolver

echo
echo "---- remove stale tailnet resolver files ----"
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

    echo "Removing stale resolver: ${resolver_file}"
    sudo rm -f "${resolver_file}"
  done
else
  echo "No stale tailnet resolver files found"
fi

echo
echo "---- remove legacy resolver files we manage ----"
sudo rm -f /etc/resolver/ts.net
sudo rm -f "/etc/resolver/${TAILNET_DOMAIN}"
sudo rm -f /etc/resolver/search.tailscale

echo
echo "---- write resolver files ----"
printf "nameserver 100.100.100.100\nsearch_order 1\ntimeout 5\n" | sudo tee /etc/resolver/ts.net >/dev/null
printf "nameserver 100.100.100.100\nsearch_order 1\ntimeout 5\n" | sudo tee "/etc/resolver/${TAILNET_DOMAIN}" >/dev/null
printf "# Added by tailscaled\nsearch %s\n" "${TAILNET_DOMAIN}" | sudo tee /etc/resolver/search.tailscale >/dev/null

sudo chown root:wheel /etc/resolver/ts.net "/etc/resolver/${TAILNET_DOMAIN}" /etc/resolver/search.tailscale
sudo chmod 644 /etc/resolver/ts.net "/etc/resolver/${TAILNET_DOMAIN}" /etc/resolver/search.tailscale

echo
echo "---- flush DNS caches ----"
sudo dscacheutil -flushcache
sudo killall -HUP mDNSResponder 2>/dev/null || true
sudo killall mDNSResponderHelper 2>/dev/null || true
sleep 2

echo
echo "---- resolver files ----"
ls -la /etc/resolver
echo
echo "---- /etc/resolver/ts.net ----"
cat /etc/resolver/ts.net
echo
echo "---- /etc/resolver/${TAILNET_DOMAIN} ----"
cat "/etc/resolver/${TAILNET_DOMAIN}"
echo
echo "---- /etc/resolver/search.tailscale ----"
cat /etc/resolver/search.tailscale

echo
echo "MAGICDNS REPAIR COMPLETE"
