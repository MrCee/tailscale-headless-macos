#!/bin/bash
# macOS Bash 3.2 compatible. Configuration is an installed, root-owned plist.
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
umask 077

log() { printf '%s %s\n' "$(/bin/date '+%Y-%m-%d %H:%M:%S %Z')" "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }
plist_value() { /usr/libexec/PlistBuddy -c "Print :$2" "$1"; }
json_value() { /usr/bin/plutil -extract "$1" raw -o - -; }

secure_path() {
  local mode
  [[ ! -L "$1" && -e "$1" ]] || return 1
  [[ $(/usr/bin/stat -f %u "$1") == 0 ]] || return 1
  mode=$(/usr/bin/stat -f %Lp "$1") || return 1
  (( (8#$mode & 8#022) == 0 ))
}

resolve_path() {
  local path="$1" target count=0
  while :; do
    path="$(cd -P "$(/usr/bin/dirname "$path")" && pwd)/$(/usr/bin/basename "$path")" || return 1
    [[ -L "$path" ]] || break
    (( count += 1 ))
    (( count <= 40 )) || return 1
    target=$(/usr/bin/readlink "$path") || return 1
    case "$target" in /*) path="$target" ;; *) path="${path%/*}/$target" ;; esac
  done
  printf '%s\n' "$path"
}

binary_version() {
  local output result
  output=$("$1" --version) || return 1
  result=$(printf '%s\n' "$output" | /usr/bin/awk '/^[[:space:]]*long version: / {sub(/^[[:space:]]*long version: /, ""); print; exit}')
  [[ "$result" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][A-Za-z0-9.-]+)?$ ]] || return 1
  printf '%s\n' "$result"
}

load_config() {
  secure_path "$runtime_dir" && secure_path "$config" || die 'Runtime directory and config.plist must be root-owned and not writable by group or others.'
  brew_bin=$(plist_value "$config" BrewBin) || die 'Missing BrewBin.'
  brew_user=$(plist_value "$config" BrewUser) || die 'Missing BrewUser.'
  brew_prefix=$(plist_value "$config" BrewPrefix) || die 'Missing BrewPrefix.'
  service_label=$(plist_value "$config" ServiceLabel) || die 'Missing ServiceLabel.'
  service_plist=$(plist_value "$config" ServicePlist) || die 'Missing ServicePlist.'
  socket=$(plist_value "$config" Socket) || die 'Missing Socket.'
  [[ "$brew_prefix" == /usr/local || "$brew_prefix" == /opt/homebrew ]] || die 'Expected the Intel or Apple Silicon Homebrew prefix.'
  [[ "$brew_bin" == "$brew_prefix/bin/brew" ]] || die 'BrewBin must be BrewPrefix/bin/brew.'
  [[ "$brew_user" =~ ^[A-Za-z_][A-Za-z0-9_.-]*$ ]] || die 'Invalid Homebrew user.'
  brew_uid=$(/usr/bin/id -u "$brew_user") || die 'The configured Homebrew owner does not exist.'
  [[ "$brew_uid" =~ ^[1-9][0-9]*$ ]] || die 'Homebrew must run as an owner with a valid non-root UID.'
  [[ "$service_label" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die 'Invalid service label.'
  [[ "$service_plist" == "/Library/LaunchDaemons/$service_label.plist" ]] || die 'Unexpected service plist location.'
  [[ "$socket" == /* && "$socket" != *$'\n'* ]] || die 'Socket must be an absolute path.'
  service="system/$service_label"
  cli="$brew_prefix/bin/tailscale"
  recovery="$runtime_dir/recovery"
  pending="$runtime_dir/TRANSACTION_PENDING"
  marker="$runtime_dir/RECOVERY_REQUIRED"
  lock_dir=/var/run/com.tailscale.headless-updater.lock
}

preflight() {
  secure_path "$service_plist" || die 'The service plist must be root-owned and not writable by group or others.'
  [[ $(plist_value "$service_plist" Label) == "$service_label" ]] || die 'Service label changed.'
  daemon=$(plist_value "$service_plist" ProgramArguments:0) || die 'Missing daemon executable.'
  [[ "$daemon" == "$brew_prefix/bin/tailscaled" || "$daemon" == "$brew_prefix/opt/tailscale/bin/tailscaled" ]] || die 'Daemon executable is not a supported Homebrew path.'
  [[ $(plist_value "$service_plist" RunAtLoad) == true ]] || die 'RunAtLoad is not enabled.'
  [[ $(plist_value "$service_plist" KeepAlive) == true ]] || die 'KeepAlive must be true.'
  [[ -x "$brew_bin" ]] || die 'Homebrew executable is missing.'
  [[ $(/usr/bin/stat -f %Su "$brew_prefix/Cellar/tailscale") == "$brew_user" ]] || die 'Homebrew owner changed.'
  /bin/launchctl print "$service" >/dev/null || die 'Tailscale is not loaded as the configured system service.'
}

candidate_pair() {
  candidate_cli=$(resolve_path "$cli") || return 1
  candidate_daemon=$(resolve_path "$daemon") || return 1
  case "$candidate_daemon" in "$brew_prefix"/Cellar/tailscale/*/bin/tailscaled) ;; *) return 1 ;; esac
  [[ "$candidate_cli" == "${candidate_daemon%/*}/tailscale" ]] || return 1
  [[ -x "$candidate_cli" && -x "$candidate_daemon" ]] || return 1
  candidate_version=$(binary_version "$candidate_daemon") || return 1
  [[ $(binary_version "$candidate_cli") == "$candidate_version" ]]
}

status_json() {
  /usr/bin/curl --fail --silent --show-error --max-time 5 \
    --unix-socket "$socket" http://local-tailscaled.sock/localapi/v0/status
}

running_image() {
  local pid images image
  pid=$(/bin/launchctl print "$service" | /usr/bin/awk '$1 == "pid" && $2 == "=" {print $3; exit}') || return 1
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  images=$(/usr/sbin/lsof -a -p "$pid" -d txt -Fn 2>/dev/null) || return 1
  while IFS= read -r image; do
    case "$image" in
      n"$brew_prefix"/Cellar/tailscale/*/bin/tailscaled|n"$recovery"/tailscaled)
        printf '%s\n' "${image#n}"; return 0 ;;
    esac
  done <<< "$images"
  return 1
}

healthy() {
  local snapshot image
  snapshot=$(status_json 2>/dev/null) || return 1
  [[ $(printf '%s' "$snapshot" | json_value BackendState) == Running ]] || return 1
  [[ $(printf '%s' "$snapshot" | json_value Self.Online) == true ]] || return 1
  [[ $(printf '%s' "$snapshot" | json_value Self.ID) == "$original_node" ]] || return 1
  [[ $(printf '%s' "$snapshot" | json_value Version) == "$1" ]] || return 1
  image=$(running_image) || return 1
  [[ "$image" == "$2" ]]
}

wait_healthy() {
  local attempt
  for (( attempt=0; attempt<12; attempt++ )); do
    if healthy "$1" "$2"; then return 0; fi
    /bin/sleep 5
  done
  return 1
}

brew_as_owner() {
  # sudo changes credentials, but does not adopt the user's bootstrap/audit
  # context. Homebrew's macOS sandbox needs that context to reach trustd.agent
  # for Go TLS verification. asuser does not require an Aqua login session.
  /bin/launchctl asuser "$brew_uid" /usr/bin/sudo -n -H -u "$brew_user" /usr/bin/env \
    PATH="$brew_prefix/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    NONINTERACTIVE=1 HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ANALYTICS=1 \
    GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/usr/bin/false SSH_ASKPASS=/usr/bin/false \
    GIT_SSH_COMMAND='/usr/bin/ssh -o BatchMode=yes' \
    HOMEBREW_NO_INSTALL_CLEANUP=1 HOMEBREW_NO_CLEANUP_FORMULAE=tailscale \
    HOMEBREW_UPDATE_TO_TAG=1 "$brew_bin" "$@" </dev/null
}

acquire_lock() {
  local attempt
  for (( attempt=0; attempt<4; attempt++ )); do
    if /bin/mkdir -m 0700 "$lock_dir" 2>/dev/null; then
      lock_held=1
      printf '%s\n' "$$" > "$lock_dir/pid"
      return 0
    fi
    (( attempt == 3 )) || /bin/sleep 1
  done
  die 'Updater/installer lock is held; no changes made. Inspect the lock before manually clearing a stale lock.'
}

install_recovery_file() { /usr/bin/install -o root -g wheel -m "$3" "$1" "$2"; }

prepare_recovery() {
  local staging
  staging=$(/usr/bin/mktemp -d "$runtime_dir/recovery.new.XXXXXX") || return 1
  install_recovery_file "$original_cli" "$staging/tailscale" 0755 || return 1
  install_recovery_file "$original_daemon" "$staging/tailscaled" 0755 || return 1
  install_recovery_file "$service_plist" "$staging/service-original.plist" 0600 || return 1
  install_recovery_file "$config" "$staging/config-original.plist" 0600 || return 1
  printf '%s\n' "$original_version" > "$staging/version" || return 1
  printf '%s\n' "$original_node" > "$staging/node-id" || return 1
  [[ $(binary_version "$staging/tailscaled") == "$original_version" && $(binary_version "$staging/tailscale") == "$original_version" ]] || return 1
  if [[ -e "$recovery" ]]; then
    secure_path "$recovery" || return 1
    # All contents are updater-owned; no Tailscale state is stored here.
    /bin/rm -rf "$recovery" || return 1
  fi
  /bin/mv "$staging" "$recovery"
}

restart_service() { /bin/launchctl kickstart -k "$service"; }

install_recovery_service() {
  local staged="$recovery/service-recovery.plist"
  install_recovery_file "$recovery/service-original.plist" "$staged" 0600 || return 1
  /usr/libexec/PlistBuddy -c "Set :ProgramArguments:0 $recovery/tailscaled" "$staged" || return 1
  /usr/bin/plutil -lint "$staged" >/dev/null || return 1
  # Preserve a valid plist on disk even if unloading/reloading the job fails.
  install_recovery_file "$staged" "$service_plist" 0644 || return 1
  if /bin/launchctl print "$service" >/dev/null 2>&1; then
    /bin/launchctl bootout "$service" || return 1
  fi
  /bin/launchctl bootstrap system "$service_plist" || return 1
  /bin/launchctl kickstart "$service"
}

recover_previous() {
  printf '%s\n' 'Automatic updates are suspended. Review the updater log and recovery directory before repairing/reinstalling.' > "$marker" || return 1
  log 'Restoring the saved daemon; Tailscale state and Homebrew package links are preserved.'
  secure_path "$recovery" && secure_path "$recovery/version" && secure_path "$recovery/node-id" || return 1
  original_version=$(/bin/cat "$recovery/version") || return 1
  original_node=$(/bin/cat "$recovery/node-id") || return 1
  secure_path "$recovery/tailscaled" && secure_path "$recovery/service-original.plist" || return 1
  [[ $(binary_version "$recovery/tailscaled") == "$original_version" ]] || return 1
  install_recovery_service || return 1
  wait_healthy "$original_version" "$recovery/tailscaled" || return 1
  /bin/rm -f "$pending" || return 1
  log 'RECOVERED: previous daemon is online with the same device identity. Automatic updates remain suspended.'
}

finish() {
  local result=$?
  trap - EXIT INT TERM HUP
  set +e
  if [[ ${transaction_active:-0} == 1 ]]; then
    if ! recover_previous; then
      log "RECOVERY FAILED: inspect $marker and $recovery; manual attention is required." >&2
    fi
    result=1
  fi
  if [[ ${lock_held:-0} == 1 ]]; then
    /bin/rm -f "$lock_dir/pid"
    /bin/rmdir "$lock_dir"
  fi
  exit "$result"
}

perform_update() {
  local snapshot outdated outdated_result=0 current_image candidate
  [[ ! -e "$marker" ]] || die "Automatic updates are suspended: $marker."
  if [[ -e "$pending" ]]; then
    transaction_active=1
    die 'An interrupted update was found; restoring the saved daemon.'
  fi
  preflight
  candidate_pair || die 'Installed CLI and daemon must be matching Homebrew binaries.'
  snapshot=$(status_json) || die 'Cannot read the running daemon status.'
  original_node=$(printf '%s' "$snapshot" | json_value Self.ID) || die 'Cannot read device identity.'
  original_version=$(printf '%s' "$snapshot" | json_value Version) || die 'Cannot read daemon version.'
  [[ -n "$original_node" && -n "$original_version" ]] || die 'Missing running daemon identity/version.'
  current_image=$(running_image) || die 'Cannot determine the running daemon executable with lsof; no changes made.'
  healthy "$original_version" "$current_image" || die 'Existing daemon is not online and healthy; no changes made.'
  original_daemon="$current_image"
  original_cli="${original_daemon%/*}/tailscale"
  # An external Homebrew upgrade can leave the old daemon process running.
  # Its exact keg is preferred; a matching retained keg also permits recovery.
  if [[ ! -x "$original_daemon" || ! -x "$original_cli" ]] || \
     [[ $(binary_version "$original_daemon" 2>/dev/null) != "$original_version" || $(binary_version "$original_cli" 2>/dev/null) != "$original_version" ]]; then
    original_daemon=''
    for candidate in "$brew_prefix"/Cellar/tailscale/*/bin/tailscaled; do
      [[ -x "$candidate" && -x "${candidate%/*}/tailscale" ]] || continue
      if [[ $(binary_version "$candidate") == "$original_version" && $(binary_version "${candidate%/*}/tailscale") == "$original_version" ]]; then
        original_daemon="$candidate"; original_cli="${candidate%/*}/tailscale"; break
      fi
    done
    [[ -n "$original_daemon" ]] || die "No retained Homebrew binaries match running version $original_version. Restore that keg or restart/recover manually before enabling updates."
  fi
  log "Checking Homebrew; daemon $original_version is online."
  brew_as_owner update --quiet || die 'Homebrew metadata update failed; daemon left untouched.'
  # Homebrew deliberately exits 1 when a specifically named formula is outdated.
  outdated=$(brew_as_owner outdated --formula tailscale) || outdated_result=$?
  case "$outdated_result:$outdated" in
    0:|0:tailscale|1:tailscale) ;;
    *) die 'Could not check Homebrew version; daemon left untouched.' ;;
  esac
  if [[ -z "$outdated" && "$candidate_version" == "$original_version" && "$candidate_daemon" == "$current_image" ]]; then
    log 'Tailscale is current in Homebrew and the installed daemon is running; no restart needed.'
    return 0
  fi
  prepare_recovery || die 'Could not prepare independent recovery copies; daemon left untouched.'
  printf '%s\n' "$original_version" > "$pending" || die 'Could not record update transaction.'
  transaction_active=1
  if [[ -n "$outdated" ]]; then
    brew_as_owner upgrade --formula tailscale || die 'Package upgrade failed; restoring the saved daemon.'
  fi
  candidate_pair || die 'Updated binaries are missing or mismatched; restoring the saved daemon.'
  if [[ -n "$outdated" && "$candidate_version" == "$original_version" && "$candidate_daemon" == "$current_image" ]]; then
    # A pinned package can produce a successful Homebrew no-op.
    /bin/rm "$pending" || die 'Could not finalize the unchanged package check.'
    transaction_active=0
    die 'Homebrew reports Tailscale outdated but made no change; check whether the formula is pinned.'
  fi
  log "Starting installed daemon $candidate_version from $candidate_daemon."
  restart_service || die 'Daemon restart failed; restoring the saved daemon.'
  wait_healthy "$candidate_version" "$candidate_daemon" || die 'New daemon failed connectivity, identity, executable, or version checks; restoring the saved daemon.'
  /bin/rm "$pending" || die 'Could not finalize the successful update.'
  transaction_active=0
  log "SUCCESS: $candidate_version is online with the original Tailscale device identity."
}

main() {
  runtime_dir=$(cd -P "$(/usr/bin/dirname "${BASH_SOURCE[0]}")" && pwd)
  config="$runtime_dir/config.plist"
  transaction_active=0
  lock_held=0
  [[ $# == 0 || ( $# == 1 && "$1" == --check ) ]] || die 'Usage: update-tailscale.sh [--check]'
  load_config
  if [[ $# == 1 ]]; then
    [[ ! -e "$marker" && ! -e "$pending" ]] || die 'Recovery is required; inspect the updater log and recovery directory.'
    preflight
    candidate_pair || die 'Installed CLI and daemon binaries are missing or mismatched.'
    snapshot=$(status_json) || die 'Cannot read daemon status.'
    log "Configuration OK; installed $candidate_version; daemon $(printf '%s' "$snapshot" | json_value Version); state $(printf '%s' "$snapshot" | json_value BackendState); online $(printf '%s' "$snapshot" | json_value Self.Online)."
    return 0
  fi
  [[ $EUID == 0 ]] || die 'Run updates through the installed system LaunchDaemon.'
  trap finish EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
  acquire_lock
  perform_update
}

# Sourcing exposes functions to the isolated behavioral tests without running them.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
