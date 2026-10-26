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
  binary_root=/Library/PrivilegedHelperTools/com.tailscale.headless
  build_user=$(plist_value "$config" BuildUser) || die 'Missing BuildUser.'
  service_label=$(plist_value "$config" ServiceLabel) || die 'Missing ServiceLabel.'
  service_plist=$(plist_value "$config" ServicePlist) || die 'Missing ServicePlist.'
  socket=$(plist_value "$config" Socket) || die 'Missing Socket.'
  [[ "$build_user" =~ ^[A-Za-z_][A-Za-z0-9_.-]*$ ]] || die 'Invalid build user.'
  build_uid=$(/usr/bin/id -u "$build_user") || die 'Build user does not exist.'
  [[ "$build_uid" =~ ^[1-9][0-9]*$ ]] || die 'Build user must have a valid non-root UID.'
  [[ "$service_label" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die 'Invalid service label.'
  [[ "$service_plist" == "/Library/LaunchDaemons/$service_label.plist" ]] || die 'Unexpected service plist location.'
  [[ "$socket" == /* && "$socket" != *$'\n'* ]] || die 'Socket must be an absolute path.'
  service="system/$service_label"
  cli="$binary_root/current/tailscale"
  recovery="$runtime_dir/recovery"
  pending="$runtime_dir/TRANSACTION_PENDING"
  marker="$runtime_dir/RECOVERY_REQUIRED"
  lock_dir=/var/run/com.tailscale.headless-updater.lock
}

preflight() {
  secure_path "$service_plist" || die 'The service plist must be root-owned and not writable by group or others.'
  [[ $(plist_value "$service_plist" Label) == "$service_label" ]] || die 'Service label changed.'
  daemon=$(plist_value "$service_plist" ProgramArguments:0) || die 'Missing daemon executable.'
  [[ "$daemon" == "$binary_root/current/tailscaled" ]] || die 'Daemon executable is not the managed Go build.'
  [[ $(plist_value "$service_plist" RunAtLoad) == true ]] || die 'RunAtLoad is not enabled.'
  [[ $(plist_value "$service_plist" KeepAlive) == true ]] || die 'KeepAlive must be true.'
  secure_path "$binary_root" && secure_path "$binary_root/releases" && secure_path "$runtime_dir/build-tailscale.sh" || die 'Binary and build helper directories must be protected.'
  /bin/launchctl print "$service" >/dev/null || die 'Tailscale is not loaded as the configured system service.'
}

candidate_pair() {
  candidate_cli=$(resolve_path "$cli") || return 1
  candidate_daemon=$(resolve_path "$daemon") || return 1
  case "$candidate_daemon" in "$binary_root"/releases/*/tailscaled) ;; *) return 1 ;; esac
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
      n"$binary_root"/releases/*/tailscaled|n"$recovery"/tailscaled)
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

build_as_user() {
  # Execute downloaded source as the configured non-root user, with a clean
  # environment, even when the scheduler runs before anyone logs in.
  /bin/launchctl asuser "$build_uid" /usr/bin/sudo -n -H -u "$build_user" /usr/bin/env -i \
    HOME="$(/usr/bin/dscl . -read "/Users/$build_user" NFSHomeDirectory | /usr/bin/sed 's/^NFSHomeDirectory: //')" \
    PATH=/usr/local/go/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin \
    "$runtime_dir/build-tailscale.sh" "$@" </dev/null
}

select_current() {
  local selection
  selection=$(/usr/bin/mktemp -d "$binary_root/.select.XXXXXX") || return 1
  /bin/ln -s "$1" "$selection/current" || return 1
  /bin/mv -fh "$selection/current" "$binary_root/current" || return 1
  /bin/rmdir "$selection"
}

build_candidate() {
  local staging version=$1
  build_staging=$(/usr/bin/mktemp -d /private/tmp/tailscale-build.XXXXXX) || return 1
  /usr/sbin/chown "$build_user" "$build_staging" || return 1
  build_as_user --version "$version" --output "$build_staging/bin" || return 1
  staging=$(/usr/bin/mktemp -d "$binary_root/releases/.new.XXXXXX") || return 1
  install_recovery_file "$build_staging/bin/tailscale" "$staging/tailscale" 0755 || return 1
  install_recovery_file "$build_staging/bin/tailscaled" "$staging/tailscaled" 0755 || return 1
  /bin/chmod 0755 "$staging" || return 1
  candidate_cli="$staging/tailscale"
  candidate_daemon="$staging/tailscaled"
  candidate_version=$(binary_version "$candidate_daemon") || return 1
  [[ "${candidate_version%%-*}" == "$version" && $(binary_version "$candidate_cli") == "$candidate_version" ]] || return 1
  /usr/bin/lipo "$candidate_cli" -verify_arch "$native_arch" && /usr/bin/lipo "$candidate_daemon" -verify_arch "$native_arch" || return 1
  local destination="$binary_root/releases/$candidate_version"
  # Never overwrite an existing release that might still be running.
  if [[ -e "$destination" || -L "$destination" ]]; then
    secure_path "$destination" && secure_path "$destination/tailscale" && secure_path "$destination/tailscaled" || return 1
    [[ $(binary_version "$destination/tailscale") == "$candidate_version" && $(binary_version "$destination/tailscaled") == "$candidate_version" ]] || return 1
    /usr/bin/lipo "$destination/tailscale" -verify_arch "$native_arch" && /usr/bin/lipo "$destination/tailscaled" -verify_arch "$native_arch" || return 1
    /bin/rm -rf "$staging" || return 1
  else
    /bin/mv "$staging" "$destination" || return 1
  fi
  candidate_cli="$destination/tailscale"
  candidate_daemon="$destination/tailscaled"
  /bin/rm -rf "$build_staging"
  build_staging=''
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
  log 'Restoring the saved daemon; Tailscale state is preserved.'
  secure_path "$recovery" && secure_path "$recovery/version" && secure_path "$recovery/node-id" || return 1
  original_version=$(/bin/cat "$recovery/version") || return 1
  original_node=$(/bin/cat "$recovery/node-id") || return 1
  secure_path "$recovery/tailscaled" && secure_path "$recovery/service-original.plist" || return 1
  [[ $(binary_version "$recovery/tailscaled") == "$original_version" ]] || return 1
  select_current "$recovery" || return 1
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
  [[ -z "${build_staging:-}" ]] || /bin/rm -rf "$build_staging"
  if [[ ${lock_held:-0} == 1 ]]; then
    /bin/rm -f "$lock_dir/pid"
    /bin/rmdir "$lock_dir"
  fi
  exit "$result"
}

perform_update() {
  local snapshot current_image target current_short
  [[ ! -e "$marker" ]] || die "Automatic updates are suspended: $marker."
  if [[ -e "$pending" ]]; then
    transaction_active=1
    die 'An interrupted update was found; restoring the saved daemon.'
  fi
  preflight
  candidate_pair || die 'Installed CLI and daemon must be matching managed binaries.'
  snapshot=$(status_json) || die 'Cannot read the running daemon status.'
  original_node=$(printf '%s' "$snapshot" | json_value Self.ID) || die 'Cannot read device identity.'
  original_version=$(printf '%s' "$snapshot" | json_value Version) || die 'Cannot read daemon version.'
  [[ -n "$original_node" && -n "$original_version" ]] || die 'Missing running identity/version.'
  current_image=$(running_image) || die 'Cannot determine the running executable; no changes made.'
  healthy "$original_version" "$current_image" || die 'Existing daemon is not online and healthy; no changes made.'
  original_daemon="$current_image"
  original_cli="${original_daemon%/*}/tailscale"
  [[ $(binary_version "$original_daemon") == "$original_version" && $(binary_version "$original_cli") == "$original_version" ]] || die 'Retained binaries do not match the running daemon.'
  log "Checking stable Tailscale releases; daemon $original_version is online."
  target=$(build_as_user --latest) || die 'Stable release lookup failed; daemon left untouched.'
  [[ "$target" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 'Invalid stable release metadata.'
  current_short=${original_version%%-*}
  if [[ "$target" == "$current_short" && "$candidate_daemon" == "$current_image" ]]; then
    log 'Tailscale is current; no build or restart needed.'
    return 0
  fi
  [[ $(printf '%s\n%s\n' "$target" "$current_short" | /usr/bin/sort -t. -k1,1n -k2,2n -k3,3n | /usr/bin/head -n 1) == "$current_short" ]] || die 'Refusing an automatic downgrade.'
  build_candidate "$target" || die 'Go build or validation failed; daemon left untouched.'
  prepare_recovery || die 'Cannot prepare independent recovery copies; daemon left untouched.'
  printf '%s\n' "$original_version" > "$pending" || die 'Cannot record transaction.'
  transaction_active=1
  select_current "${candidate_daemon%/*}" || die 'Cannot switch release; restoring saved daemon.'
  log "Starting built daemon $candidate_version from $candidate_daemon."
  restart_service || die 'Daemon restart failed; restoring saved daemon.'
  wait_healthy "$candidate_version" "$candidate_daemon" || die 'New daemon failed health checks; restoring saved daemon.'
  /bin/rm "$pending" || die 'Cannot finalize successful update.'
  transaction_active=0
  log "SUCCESS: $candidate_version is online with the original device identity."
}

main() {
  runtime_dir=$(cd -P "$(/usr/bin/dirname "${BASH_SOURCE[0]}")" && pwd)
  config="$runtime_dir/config.plist"
  transaction_active=0
  lock_held=0
  [[ $# == 0 || ( $# == 1 && "$1" == --check ) ]] || die 'Usage: update-tailscale.sh [--check]'
  [[ $(/usr/bin/uname -s) == Darwin ]] || die 'macOS is required.'
  native_arch=$(/usr/bin/uname -m)
  if [[ $(/usr/sbin/sysctl -n hw.optional.arm64 2>/dev/null || true) == 1 ]]; then native_arch=arm64; fi
  case "$native_arch" in x86_64|arm64) ;; *) die "Unsupported Mac architecture: $native_arch" ;; esac
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
