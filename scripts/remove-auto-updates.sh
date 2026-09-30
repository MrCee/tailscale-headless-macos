#!/bin/zsh -f
# Stop scheduled updates without disconnecting Tailscale or deleting its state.
set -eu
set -o pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
readonly updater_label=com.tailscale.headless-updater
readonly runtime_dir=/Library/PrivilegedHelperTools/com.tailscale.headless-updater
readonly updater_plist=/Library/LaunchDaemons/com.tailscale.headless-updater.plist
readonly lifecycle_lock=/var/run/com.tailscale.headless-updater.lock
lock_held=false
cleanup() {
  local result=$?
  trap - EXIT
  if [[ "$lock_held" == true ]]; then
    /usr/bin/sudo -n /bin/rm -f "$lifecycle_lock/pid"
    /usr/bin/sudo -n /bin/rmdir "$lifecycle_lock"
  fi
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if (( $# )); then
  print 'Internal helper. Use AUTO_UPDATE=false in .env and run ./install.sh to disable updates.'
  exit 1
fi
/usr/bin/sudo -v
/usr/bin/sudo -n /bin/mkdir "$lifecycle_lock" || { print -u2 'Updater/lifecycle lock exists. Wait for the other operation or investigate a stale lock.'; exit 1; }
lock_held=true
print -r -- "$$" | /usr/bin/sudo -n /usr/bin/tee "$lifecycle_lock/pid" >/dev/null
if /bin/launchctl print "system/$updater_label" >/dev/null 2>&1; then
  if /bin/launchctl print "system/$updater_label" | /usr/bin/grep -q 'state = running'; then
    print -u2 'An update is running. Wait until it finishes before removing the updater.'
    exit 1
  fi
fi
if /bin/launchctl print "system/$updater_label" >/dev/null 2>&1; then
  /usr/bin/sudo -n /bin/launchctl bootout "system/$updater_label"
fi
/usr/bin/sudo -n /bin/rm -f "$updater_plist"
# Preserve runtime/recovery files: a rolled-back daemon may depend on those binaries.
print 'Scheduled updates removed. Tailscale remains running.'
print -r -- "Recovery files and the installed updater remain at $runtime_dir."
print 'The update log remains at /var/log/tailscale-headless-update.log.'
