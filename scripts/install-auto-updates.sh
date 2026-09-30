#!/bin/zsh -f
# Internal stage of install.sh: schedule updates for the authenticated daemon.
set -eu
set -o pipefail
export PATH=/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin
umask 022

readonly source_dir=${0:A:h}
readonly updater_label=com.tailscale.headless-updater
readonly runtime_dir=/Library/PrivilegedHelperTools/com.tailscale.headless-updater
readonly updater_plist=/Library/LaunchDaemons/com.tailscale.headless-updater.plist
readonly lifecycle_lock=/var/run/com.tailscale.headless-updater.lock
lock_held=false
brew_bin=''
service_label=com.tailscale.tailscaled
socket=/var/run/tailscaled.socket
update_hour=4
update_minute=15
check_only=false

usage() {
  print 'Internal setup helper. Use ./install.sh for normal installation.'
  print 'Options: [--check] [--brew PATH] [--label LABEL] [--socket PATH] [--hour 0-23] [--minute 0-59]'
  print 'Run as the Homebrew owner. Installation requests sudo once; --check never requests it.'
}
fail() { print -u2 -r -- "ERROR: $*"; exit 1; }
while (( $# )); do
  case "$1" in
    --check) check_only=true; shift ;;
    --help|-h) usage; exit 0 ;;
    --brew|--label|--socket|--hour|--minute)
      (( $# >= 2 )) || fail "Missing value for $1"
      case "$1" in
        --brew) brew_bin=$2 ;;
        --label) service_label=$2 ;;
        --socket) socket=$2 ;;
        --hour) update_hour=$2 ;;
        --minute) update_minute=$2 ;;
      esac
      shift 2 ;;
    *) usage >&2; fail "Unknown argument: $1" ;;
  esac
done
[[ $EUID != 0 ]] || fail 'Run this script as your normal Homebrew user, without sudo.'
[[ $(/usr/bin/uname -s) == Darwin ]] || fail 'This installer requires macOS.'
[[ "$service_label" == [A-Za-z0-9]* && "$service_label" != *[^A-Za-z0-9._-]* ]] || fail 'Invalid service label.'
[[ "$update_hour" == <0-23> && "$update_minute" == <0-59> ]] || fail 'Invalid update time.'
[[ "$socket" == /* && "$socket" != *$'\n'* ]] || fail 'The socket must be an absolute path.'
if [[ -z "$brew_bin" ]]; then brew_bin=$(command -v brew) || fail 'Homebrew not found.'; fi
[[ "$brew_bin" == /* && -x "$brew_bin" ]] || fail 'Use an absolute path to the Homebrew executable.'
brew_prefix=$("$brew_bin" --prefix)
[[ "$brew_prefix" == /usr/local || "$brew_prefix" == /opt/homebrew ]] || fail 'Only standard Intel and Apple Silicon Homebrew prefixes are supported.'
brew_bin="$brew_prefix/bin/brew"
[[ -x "$brew_bin" ]] || fail 'The standard Homebrew executable is missing.'
[[ -x "$brew_prefix/bin/tailscale" && -x "$brew_prefix/bin/tailscaled" ]] || fail 'Install headless Tailscale first.'
brew_user=$(/usr/bin/stat -f %Su "$brew_prefix/Cellar/tailscale")
[[ "$brew_user" == "$(/usr/bin/id -un)" ]] || fail "Run as the Homebrew owner: $brew_user"
[[ $(/usr/bin/id -u "$brew_user") != 0 ]] || fail 'Homebrew must not be owned by root.'
readonly service_plist=/Library/LaunchDaemons/${service_label}.plist
[[ -f "$service_plist" ]] || fail "Missing daemon plist: $service_plist"
[[ ! -L "$runtime_dir" && ! -L "$updater_plist" ]] || fail 'Unexpected symlink at installation destination.'
[[ ! -e "$runtime_dir/RECOVERY_REQUIRED" ]] || fail 'A previous update rolled back. Resolve recovery before reinstalling.'
[[ ! -e "$runtime_dir/TRANSACTION_PENDING" ]] || fail 'An interrupted update requires recovery before reinstalling.'
daemon_path=$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$service_plist")
[[ "$daemon_path" == "$brew_prefix/bin/tailscaled" || "$daemon_path" == "$brew_prefix/opt/tailscale/bin/tailscaled" ]] || fail 'Existing daemon does not use the expected Homebrew binary.'
[[ $(/usr/libexec/PlistBuddy -c 'Print :RunAtLoad' "$service_plist") == true ]] || fail 'Enable RunAtLoad on the existing daemon first.'
[[ $(/usr/libexec/PlistBuddy -c 'Print :KeepAlive' "$service_plist") == true ]] || fail 'Enable KeepAlive on the existing daemon first.'
/bin/launchctl print "system/$service_label" >/dev/null || fail 'The existing daemon is not loaded.'
snapshot=$(/usr/bin/curl --fail --silent --show-error --max-time 5 --unix-socket "$socket" http://local-tailscaled.sock/localapi/v0/status)
[[ $(print -r -- "$snapshot" | /usr/bin/plutil -extract BackendState raw -o - -) == Running ]] || fail 'Connect and authenticate the existing daemon first.'
/bin/bash -n "$source_dir/update-tailscale.sh"

staging_dir=$(/usr/bin/mktemp -d)
cleanup() {
  local result=$?
  trap - EXIT
  /bin/rm -rf "$staging_dir"
  if [[ "$lock_held" == true ]]; then
    /usr/bin/sudo -n /bin/rm -f "$lifecycle_lock/pid"
    /usr/bin/sudo -n /bin/rmdir "$lifecycle_lock"
  fi
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
config="$staging_dir/config.plist"
plist="$staging_dir/updater.plist"
/usr/bin/plutil -create xml1 "$config"
for key value in \
  BrewBin "$brew_bin" BrewUser "$brew_user" BrewPrefix "$brew_prefix" \
  ServiceLabel "$service_label" ServicePlist "$service_plist" Socket "$socket"; do
  /usr/bin/plutil -insert "$key" -string "$value" "$config"
done
/usr/bin/plutil -create xml1 "$plist"
/usr/bin/plutil -insert Label -string "$updater_label" "$plist"
/usr/bin/plutil -insert ProgramArguments -json '[]' "$plist"
/usr/bin/plutil -insert ProgramArguments.0 -string "$runtime_dir/update-tailscale.sh" "$plist"
/usr/bin/plutil -insert RunAtLoad -bool YES "$plist"
/usr/bin/plutil -insert StartCalendarInterval -json '{}' "$plist"
/usr/bin/plutil -insert StartCalendarInterval.Hour -integer "$update_hour" "$plist"
/usr/bin/plutil -insert StartCalendarInterval.Minute -integer "$update_minute" "$plist"
/usr/bin/plutil -insert ProcessType -string Background "$plist"
/usr/bin/plutil -insert Nice -integer 10 "$plist"
/usr/bin/plutil -insert StandardOutPath -string /var/log/tailscale-headless-update.log "$plist"
/usr/bin/plutil -insert StandardErrorPath -string /var/log/tailscale-headless-update.log "$plist"
/usr/bin/plutil -lint "$config" "$plist"
print -r -- "Daemon: $service_label ($daemon_path)"
print -r -- "Homebrew: $brew_bin, running as $brew_user"
printf 'Schedule: each boot and daily at %02d:%02d local time.\n' "$update_hour" "$update_minute"
print 'Updates may briefly interrupt Tailscale connections when the daemon restarts.'
if [[ "$check_only" == true ]]; then
  print 'Preflight passed. No installed files or services changed.'
  exit 0
fi

/usr/bin/sudo -v
/usr/bin/sudo -n /bin/mkdir "$lifecycle_lock" || fail 'Updater/lifecycle lock exists. Wait for the other operation or investigate a stale lock.'
lock_held=true
print -r -- "$$" | /usr/bin/sudo -n /usr/bin/tee "$lifecycle_lock/pid" >/dev/null
[[ ! -e "$runtime_dir/RECOVERY_REQUIRED" ]] || fail 'An update rolled back while installation was waiting. Resolve recovery first.'
[[ ! -e "$runtime_dir/TRANSACTION_PENDING" ]] || fail 'An interrupted update requires recovery before reinstalling.'
if /bin/launchctl print "system/$updater_label" >/dev/null 2>&1; then
  if /bin/launchctl print "system/$updater_label" | /usr/bin/grep -q 'state = running'; then
    fail 'The updater is currently running. Wait until it finishes before reinstalling.'
  fi
  /usr/bin/sudo -n /bin/launchctl bootout "system/$updater_label"
fi
/usr/bin/sudo -n /usr/bin/install -d -o root -g wheel -m 0755 "$runtime_dir"
for installed_file in update-tailscale.sh config.plist; do
  [[ ! -L "$runtime_dir/$installed_file" ]] || fail "Unexpected symlink: $runtime_dir/$installed_file"
done
/usr/bin/sudo -n /usr/bin/install -o root -g wheel -m 0755 "$source_dir/update-tailscale.sh" "$runtime_dir/update-tailscale.sh"
/usr/bin/sudo -n /usr/bin/install -o root -g wheel -m 0644 "$config" "$runtime_dir/config.plist"
/usr/bin/sudo -n /usr/bin/install -o root -g wheel -m 0644 "$plist" "$updater_plist"
/usr/bin/sudo -n /bin/launchctl enable "system/$service_label"
/usr/bin/sudo -n /bin/launchctl enable "system/$updater_label"
/usr/bin/sudo -n /bin/launchctl bootstrap system "$updater_plist"
# A RunAtLoad attempt may observe the installation lock and exit. Start a fresh
# attempt after releasing it; launchd will not duplicate an already-running job.
/usr/bin/sudo -n /bin/rm -f "$lifecycle_lock/pid"
/usr/bin/sudo -n /bin/rmdir "$lifecycle_lock"
lock_held=false
/usr/bin/sudo -n /bin/launchctl kickstart "system/$updater_label"
/bin/launchctl print "system/$updater_label"
print 'Updater installed. The first check is scheduled now; its result is in /var/log/tailscale-headless-update.log.'
