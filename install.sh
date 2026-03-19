#!/bin/zsh
set -euo pipefail

echo "---- sudo authentication upfront ----"
sudo -v

(
  while true; do
    sudo -n -v 2>/dev/null || exit 0
    sleep 30
  done
) &
SUDO_KEEPALIVE_PID=$!

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${ROOT_DIR}/.env"
PLIST_TMP=""
TEMPLATE=""
BREW_PREFIX=""
TS=""
TSD=""

cleanup() {
  local ec=$?

  if [[ -n "${PLIST_TMP:-}" && -f "${PLIST_TMP}" ]]; then
    rm -f "${PLIST_TMP}" 2>/dev/null || true
  fi

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
: "${LAUNCHD_LABEL:?LAUNCHD_LABEL is required}"
: "${LAUNCHD_PLIST:?LAUNCHD_PLIST is required}"
: "${STATE_DIR:?STATE_DIR is required}"
: "${STATE_FILE:?STATE_FILE is required}"
: "${LOG_OUT:?LOG_OUT is required}"
: "${LOG_ERR:?LOG_ERR is required}"

if [[ "${TAILNET_DOMAIN}" == "your-tailnet.ts.net" || "${TAILNET_DOMAIN}" == "example-tailnet.ts.net" ]]; then
  echo "ERROR: TAILNET_DOMAIN is still set to the example value"
  echo "Edit .env and set your real tailnet domain before running install.sh"
  exit 1
fi

if [[ "${TAILNET_DOMAIN}" != *.ts.net ]]; then
  echo "ERROR: TAILNET_DOMAIN must end with .ts.net"
  echo "Current value: ${TAILNET_DOMAIN}"
  exit 1
fi

BREW_BIN="${BREW_BIN:-brew}"
TAILSCALED_SOCKET="${TAILSCALED_SOCKET:-/var/run/tailscaled.socket}"
TAILSCALED_WAIT_SECONDS="${TAILSCALED_WAIT_SECONDS:-20}"

if ! command -v "${BREW_BIN}" >/dev/null 2>&1; then
  echo "ERROR: brew not found via BREW_BIN=${BREW_BIN}"
  exit 1
fi

bool_to_flag() {
  local value="$1"
  local flag_true="$2"
  local flag_false="$3"

  case "${value:l}" in
    true|yes|1)  echo "${flag_true}" ;;
    false|no|0)  echo "${flag_false}" ;;
    *)
      echo "ERROR: invalid boolean value: ${value}" >&2
      exit 1
      ;;
  esac
}

get_macos_hostname() {
  local detected=""

  detected="$(scutil --get LocalHostName 2>/dev/null || true)"
  if [[ -z "${detected}" ]]; then
    detected="$(scutil --get ComputerName 2>/dev/null || true)"
  fi
  if [[ -z "${detected}" ]]; then
    detected="$(hostname -s 2>/dev/null || true)"
  fi

  print -r -- "${detected}"
}

BREW_PREFIX="$("${BREW_BIN}" --prefix)"
TS="${BREW_PREFIX}/bin/tailscale"
TSD="${BREW_PREFIX}/bin/tailscaled"
TEMPLATE="${ROOT_DIR}/templates/com.tailscale.tailscaled.plist.template"
PLIST_TMP="$(mktemp)"

ACCEPT_ROUTES="${ACCEPT_ROUTES:-true}"
ACCEPT_DNS="${ACCEPT_DNS:-true}"
RUN_TAILSCALE_UP="${RUN_TAILSCALE_UP:-true}"
TAILSCALE_EXTRA_FLAGS="${TAILSCALE_EXTRA_FLAGS:-}"

ACCEPT_ROUTES_FLAG="$(bool_to_flag "${ACCEPT_ROUTES}" "--accept-routes" "--accept-routes=false")"
ACCEPT_DNS_FLAG="$(bool_to_flag "${ACCEPT_DNS}" "--accept-dns=true" "--accept-dns=false")"

MACOS_HOSTNAME="$(get_macos_hostname)"

if [[ -z "${TS_HOSTNAME:-}" ]]; then
  if [[ -n "${MACOS_HOSTNAME}" ]]; then
    TS_HOSTNAME="${MACOS_HOSTNAME}"
    echo "INFO: TS_HOSTNAME not set; using detected macOS hostname: ${TS_HOSTNAME}"
  else
    echo "ERROR: TS_HOSTNAME is not set and no macOS hostname could be detected"
    exit 1
  fi
fi

if [[ -n "${MACOS_HOSTNAME}" && "${TS_HOSTNAME}" != "${MACOS_HOSTNAME}" ]]; then
  echo "WARNING: TS_HOSTNAME differs from detected macOS hostname"
  echo "Configured TS_HOSTNAME : ${TS_HOSTNAME}"
  echo "Detected macOS name    : ${MACOS_HOSTNAME}"
fi

if [[ ! -f "${TEMPLATE}" ]]; then
  echo "ERROR: missing LaunchDaemon template: ${TEMPLATE}"
  exit 1
fi

echo "============================================================"
echo "TAILSCALE HEADLESS MACOS INSTALL"
echo "============================================================"
echo "ROOT_DIR              : ${ROOT_DIR}"
echo "BREW_BIN              : ${BREW_BIN}"
echo "BREW_PREFIX           : ${BREW_PREFIX}"
echo "TS                    : ${TS}"
echo "TSD                   : ${TSD}"
echo "HOSTNAME              : ${TS_HOSTNAME}"
echo "MACOS_HOSTNAME        : ${MACOS_HOSTNAME:-<unknown>}"
echo "TAILNET_DOMAIN        : ${TAILNET_DOMAIN}"
echo "LAUNCHD_LABEL         : ${LAUNCHD_LABEL}"
echo "LAUNCHD_PLIST         : ${LAUNCHD_PLIST}"
echo "STATE_DIR             : ${STATE_DIR}"
echo "STATE_FILE            : ${STATE_FILE}"
echo "LOG_OUT               : ${LOG_OUT}"
echo "LOG_ERR               : ${LOG_ERR}"
echo "TAILSCALED_SOCKET     : ${TAILSCALED_SOCKET}"
echo "TAILSCALED_WAIT_SECS  : ${TAILSCALED_WAIT_SECONDS}"
echo "============================================================"

echo
echo "---- install / relink tailscale ----"
HOMEBREW_NO_AUTO_UPDATE=1 "${BREW_BIN}" install tailscale
"${BREW_BIN}" unlink tailscale 2>/dev/null || true
"${BREW_BIN}" link --overwrite --force tailscale

[[ -x "${TS}" ]] || { echo "ERROR: missing ${TS}"; exit 1; }
[[ -x "${TSD}" ]] || { echo "ERROR: missing ${TSD}"; exit 1; }

echo
echo "---- prepare runtime directories ----"
sudo mkdir -p "${STATE_DIR}" /var/log /var/run /etc/resolver
sudo chown root:wheel "${STATE_DIR}"
sudo chmod 700 "${STATE_DIR}"
sudo touch "${LOG_OUT}" "${LOG_ERR}"
sudo chown root:wheel "${LOG_OUT}" "${LOG_ERR}"
sudo chmod 644 "${LOG_OUT}" "${LOG_ERR}"

echo
echo "---- render LaunchDaemon plist ----"
sed \
  -e "s|__LAUNCHD_LABEL__|${LAUNCHD_LABEL}|g" \
  -e "s|__TAILSCALED_PATH__|${TSD}|g" \
  -e "s|__STATE_FILE__|${STATE_FILE}|g" \
  -e "s|__LOG_OUT__|${LOG_OUT}|g" \
  -e "s|__LOG_ERR__|${LOG_ERR}|g" \
  "${TEMPLATE}" > "${PLIST_TMP}"

sudo cp "${PLIST_TMP}" "${LAUNCHD_PLIST}"
sudo chown root:wheel "${LAUNCHD_PLIST}"
sudo chmod 644 "${LAUNCHD_PLIST}"
sudo plutil -lint "${LAUNCHD_PLIST}"

echo
echo "---- clean old daemon state ----"
sudo launchctl bootout system "${LAUNCHD_PLIST}" 2>/dev/null || true
sudo launchctl bootout "system/${LAUNCHD_LABEL}" 2>/dev/null || true
sudo launchctl remove "${LAUNCHD_LABEL}" 2>/dev/null || true
sudo pkill -x tailscaled 2>/dev/null || true
sudo rm -f "${TAILSCALED_SOCKET}"
sleep 1

echo
echo "---- bootstrap daemon ----"
BOOTSTRAP_OK=false

sudo launchctl enable "system/${LAUNCHD_LABEL}" 2>/dev/null || true

if sudo launchctl bootstrap system "${LAUNCHD_PLIST}"; then
  sudo launchctl kickstart -k "system/${LAUNCHD_LABEL}" 2>/dev/null || true
  BOOTSTRAP_OK=true
else
  echo "WARNING: launchctl bootstrap failed."
  echo "Attempting recovery via kickstart..."
  sudo launchctl kickstart -k "system/${LAUNCHD_LABEL}" 2>/dev/null || true

  if sudo launchctl print "system/${LAUNCHD_LABEL}" >/dev/null 2>&1; then
    BOOTSTRAP_OK=true
  else
    echo "Falling back to manual daemon start for this session."
    sudo /bin/sh -c "exec '${TSD}' --state='${STATE_FILE}' --socket='${TAILSCALED_SOCKET}' >>'${LOG_OUT}' 2>>'${LOG_ERR}'" &
  fi
fi

echo
echo "---- wait for tailscaled ----"
typeset -i i=1
while (( i <= TAILSCALED_WAIT_SECONDS )); do
  if [[ -S "${TAILSCALED_SOCKET}" ]]; then
    break
  fi
  sleep 1
  (( i++ ))
done

if [[ -S "${TAILSCALED_SOCKET}" ]]; then
  echo "tailscaled socket present: ${TAILSCALED_SOCKET}"
else
  echo "WARNING: tailscaled socket not present after wait: ${TAILSCALED_SOCKET}"
  echo
  echo "---- daemon diagnostics ----"
  sudo launchctl print "system/${LAUNCHD_LABEL}" 2>/dev/null || true
  echo
  echo "---- log tail stdout ----"
  sudo tail -n 40 "${LOG_OUT}" 2>/dev/null || true
  echo
  echo "---- log tail stderr ----"
  sudo tail -n 40 "${LOG_ERR}" 2>/dev/null || true
fi

echo
echo "---- configure MagicDNS resolver files ----"
echo "Cleaning stale tailnet resolver files..."
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

printf "nameserver 100.100.100.100\nsearch_order 1\ntimeout 5\n" | sudo tee /etc/resolver/ts.net >/dev/null
printf "nameserver 100.100.100.100\nsearch_order 1\ntimeout 5\n" | sudo tee "/etc/resolver/${TAILNET_DOMAIN}" >/dev/null
printf "# Added by tailscaled\nsearch %s\n" "${TAILNET_DOMAIN}" | sudo tee /etc/resolver/search.tailscale >/dev/null

sudo chown root:wheel /etc/resolver/ts.net "/etc/resolver/${TAILNET_DOMAIN}" /etc/resolver/search.tailscale
sudo chmod 644 /etc/resolver/ts.net "/etc/resolver/${TAILNET_DOMAIN}" /etc/resolver/search.tailscale

echo
echo "---- flush DNS caches ----"
sudo dscacheutil -flushcache
sudo killall -HUP mDNSResponder 2>/dev/null || true
sleep 2

echo
echo "---- versions ----"
"${TS}" version
"${TSD}" --version || true

case "${RUN_TAILSCALE_UP:l}" in
  true|yes|1)
    echo
    echo "---- authenticate / enforce settings ----"
    if [[ ! -S "${TAILSCALED_SOCKET}" ]]; then
      echo "ERROR: tailscaled socket missing, refusing to run tailscale up"
      exit 1
    fi
    # shellcheck disable=SC2086
    sudo "${TS}" up --reset --hostname="${TS_HOSTNAME}" "${ACCEPT_ROUTES_FLAG}" "${ACCEPT_DNS_FLAG}" ${=TAILSCALE_EXTRA_FLAGS}
    ;;
  false|no|0)
    echo
    echo "---- skipping tailscale up because RUN_TAILSCALE_UP=${RUN_TAILSCALE_UP} ----"
    ;;
  *)
    echo "ERROR: invalid RUN_TAILSCALE_UP value: ${RUN_TAILSCALE_UP}" >&2
    exit 1
    ;;
esac

echo
echo "---- summary ----"
"${TS}" status || true
"${TS}" ip -4 || true
pgrep -fl tailscaled || true
sudo launchctl print "system/${LAUNCHD_LABEL}" 2>/dev/null | sed -n '1,35p' || true

echo
echo "NOTE: hostname and peer metadata may take a few seconds to converge."
echo "If the summary appears stale, re-run: ${TS} status"

echo
if [[ "${BOOTSTRAP_OK}" == "true" ]]; then
  echo "INSTALL COMPLETE"
else
  echo "INSTALL COMPLETE (manual tailscaled fallback used)"
fi
