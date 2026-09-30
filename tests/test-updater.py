#!/usr/bin/env python3
"""Exercise updater transactions in temporary directories; never sudo or launchctl.

Only macOS/privilege adapters are replaced. Real shell control flow, binary
inspection, symlink resolution, backups, markers and EXIT recovery are exercised.
"""
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/update-tailscale.sh"
OLD = "1.100.0-told"
NEW = "1.102.4-tnew"

HARNESS = r'''
source "$TEST_SCRIPT"
production_brew_as_owner=$(declare -f brew_as_owner)
load_config() {
  runtime_dir="$TEST_ROOT/runtime"
  config="$runtime_dir/config.plist"
  brew_prefix="$TEST_ROOT/brew"
  brew_bin="$brew_prefix/bin/brew"
  brew_user=brewowner
  brew_uid=501
  service_label=com.example.tailscaled
  service=system/$service_label
  service_plist="$TEST_ROOT/service.plist"
  socket="$TEST_ROOT/socket"
  cli="$brew_prefix/bin/tailscale"
  daemon="$brew_prefix/bin/tailscaled"
  recovery="$runtime_dir/recovery"
  pending="$runtime_dir/TRANSACTION_PENDING"
  marker="$runtime_dir/RECOVERY_REQUIRED"
  lock_dir="$TEST_ROOT/shared.lock"
}
load_config
action() { printf '%s\n' "$*" >> "$TEST_ROOT/actions"; }
preflight() { :; }
secure_path() { [[ -e "$1" && ! -L "$1" ]]; }
json_value() {
  "$TEST_PYTHON" -c 'import json,sys
v=json.load(sys.stdin)
for key in sys.argv[1].split("."): v=v[key]
print(str(v).lower() if isinstance(v,bool) else v)' "$1"
}
status_json() { /bin/cat "$TEST_ROOT/status.json"; }
running_image() { /bin/cat "$TEST_ROOT/image"; }
install_recovery_file() { /bin/cp "$1" "$2" && /bin/chmod "$3" "$2"; }
set_status() {
  "$TEST_PYTHON" -c 'import json,sys
json.dump({"Version":sys.argv[2],"BackendState":"Running","Self":{"ID":sys.argv[3],"Online":sys.argv[4]=="true"}},open(sys.argv[1],"w"))' \
    "$TEST_ROOT/status.json" "$1" "$2" "$3"
}
brew_as_owner() {
  action "brew $*"
  case "$1" in
    update) [[ "$SCENARIO" != metadata_failure ]] ;;
    outdated)
      [[ "$SCENARIO" != outdated_failure ]] || return 1
      case "$SCENARIO" in
        current|external|revision|missing_old|read_only) ;;
        *) printf 'tailscale\n'; return 1 ;;
      esac ;;
    upgrade)
      [[ "$SCENARIO" != pinned ]] || return 0
      /bin/ln -sfn "$TEST_ROOT/new/tailscaled" "$daemon"
      /bin/ln -sfn "$TEST_ROOT/new/tailscale" "$cli"
      case "$SCENARIO" in
        partial_failure) return 1 ;;
        signal) kill -TERM "$$" ;;
        mismatch) /bin/ln -sfn "$TEST_ROOT/old/tailscale" "$cli" ;;
      esac ;;
    *) return 2 ;;
  esac
}
restart_service() {
  action restart
  [[ "$SCENARIO" != restart_failure ]] || return 1
  printf '%s\n' "$candidate_daemon" > "$TEST_ROOT/image"
  local online=true node=original-node version="$candidate_version"
  [[ "$SCENARIO" != offline && "$SCENARIO" != recovery_failure ]] || online=false
  [[ "$SCENARIO" != identity_change ]] || node=wrong-node
  [[ "$SCENARIO" != version_prefix ]] || version="${candidate_version}extra"
  set_status "$version" "$node" "$online"
}
wait_healthy() { healthy "$1" "$2"; }
install_recovery_service() {
  action recover
  [[ "$SCENARIO" != recovery_failure ]] || return 1
  printf '%s\n' "$recovery/tailscaled" > "$TEST_ROOT/image"
  set_status "$original_version" "$original_node" true
}
if [[ "$SCENARIO" == bootstrap_failure ]]; then
  # Exercise the real wrapper against the isolated launchctl recording stub.
  eval "$production_brew_as_owner"
fi
transaction_active=0
lock_held=0
if [[ "$SCENARIO" == read_only ]]; then
  main --check
else
  trap finish EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
  acquire_lock
  perform_update
fi
'''


class UpdaterTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="tailscale-updater-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.runtime = self.root / "runtime"
        self.runtime.mkdir()
        (self.runtime / "config.plist").write_text("original configuration\n")
        (self.root / "service.plist").write_text("original service plist\n")
        (self.root / "state").write_text("must remain untouched\n")
        (self.root / "actions").write_text("")
        self.bin = self.root / "brew/bin"
        self.bin.mkdir(parents=True)
        self.old = self.make_keg("1.100.0", OLD)
        self.new = self.make_keg("1.102.4", NEW)
        (self.root / "old").symlink_to(self.old)
        (self.root / "new").symlink_to(self.new)
        self.link_pair(self.old)
        (self.root / "image").write_text(str(self.old / "tailscaled") + "\n")
        self.write_status(OLD)

    def make_keg(self, name, version):
        directory = self.root / "brew/Cellar/tailscale" / name / "bin"
        directory.mkdir(parents=True)
        for binary in ("tailscale", "tailscaled"):
            path = directory / binary
            path.write_text("#!/bin/sh\nprintf '%s\\n' " + shlex.quote(version.split("-")[0]) +
                            " " + shlex.quote("  long version: " + version) + "\n")
            path.chmod(0o755)
        return directory

    def link_pair(self, directory):
        for binary in ("tailscale", "tailscaled"):
            link = self.bin / binary
            link.unlink(missing_ok=True)
            link.symlink_to(directory / binary)

    def write_status(self, version, online=True):
        (self.root / "status.json").write_text(json.dumps({
            "Version": version, "BackendState": "Running",
            "Self": {"ID": "original-node", "Online": online}}))

    def run_case(self, scenario, success=False, retained_lock=False, script=SCRIPT, extra_env=None):
        env = os.environ.copy()
        env.update(TEST_ROOT=str(self.root), TEST_SCRIPT=str(script),
                   TEST_PYTHON=sys.executable, SCENARIO=scenario)
        env.update(extra_env or {})
        result = subprocess.run(["/bin/bash", "-c", HARNESS], env=env,
                                capture_output=True, text=True, timeout=25)
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
        self.assertEqual((self.root / "state").read_text(), "must remain untouched\n")
        self.assertEqual((self.root / "shared.lock").exists(), retained_lock)
        return result

    def make_bootstrap_stub(self, exit_code=0):
        recorded = self.root / "launchctl-argv.json"
        stub = self.root / "launchctl-stub"
        body = ("import json,sys\n"
                f"json.dump(sys.argv[1:],open({str(recorded)!r},'w'))\n"
                f"sys.exit({exit_code})\n")
        stub.write_text("#!/bin/sh\nexec " + shlex.quote(sys.executable) + " -c " +
                        shlex.quote(body) + ' "$@"\n')
        stub.chmod(0o755)
        script = self.root / "updater-with-bootstrap-stub.sh"
        script.write_text(SCRIPT.read_text().replace("/bin/launchctl", shlex.quote(str(stub))))
        return script, recorded

    def actions(self):
        return (self.root / "actions").read_text().splitlines()

    def assert_recovered(self):
        self.assertIn("recover", self.actions())
        self.assertTrue((self.runtime / "RECOVERY_REQUIRED").is_file())
        self.assertFalse((self.runtime / "TRANSACTION_PENDING").exists())
        self.assertEqual((self.runtime / "recovery/service-original.plist").read_text(),
                         "original service plist\n")
        self.assertEqual((self.runtime / "recovery/config-original.plist").read_text(),
                         "original configuration\n")
        self.assertEqual((self.runtime / "recovery/tailscaled").read_bytes(),
                         (self.old / "tailscaled").read_bytes())
        self.assertEqual(json.loads((self.root / "status.json").read_text())["Version"], OLD)

    def test_current_package_does_not_restart(self):
        self.run_case("current", success=True)
        self.assertEqual(self.actions(), ["brew update --quiet", "brew outdated --formula tailscale"])
        self.assertFalse((self.runtime / "recovery").exists())

    def test_homebrew_adopts_user_bootstrap_then_nonroot_credentials(self):
        script, recorded = self.make_bootstrap_stub()
        shell = ('source "$TEST_SCRIPT"\n'
                 'brew_user=brewowner; brew_uid=501; brew_prefix=/opt/homebrew\n'
                 'brew_bin=/opt/homebrew/bin/brew\n'
                 'brew_as_owner update --quiet\n')
        env = dict(os.environ, TEST_SCRIPT=str(script))
        result = subprocess.run(["/bin/bash", "-c", shell], env=env,
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        args = json.loads(recorded.read_text())
        self.assertEqual(args[:8], ["asuser", "501", "/usr/bin/sudo", "-n", "-H", "-u",
                                   "brewowner", "/usr/bin/env"])
        self.assertEqual(args[-3:], ["/opt/homebrew/bin/brew", "update", "--quiet"])
        self.assertIn("GIT_TERMINAL_PROMPT=0", args)
        self.assertIn("GIT_SSH_COMMAND=/usr/bin/ssh -o BatchMode=yes", args)
        self.assertIn("HOMEBREW_NO_INSTALL_CLEANUP=1", args)

    def test_bootstrap_context_failure_leaves_daemon_and_recovery_untouched(self):
        script, recorded = self.make_bootstrap_stub(exit_code=77)
        self.run_case("bootstrap_failure", script=script)
        self.assertEqual(json.loads(recorded.read_text())[:2], ["asuser", "501"])
        self.assertEqual(self.actions(), [])
        self.assertFalse((self.runtime / "recovery").exists())
        self.assertFalse((self.runtime / "RECOVERY_REQUIRED").exists())
        self.assertFalse((self.runtime / "TRANSACTION_PENDING").exists())
        self.assertEqual((self.root / "image").read_text().strip(), str(self.old / "tailscaled"))

    def test_invalid_homebrew_owner_uid_fails_before_bootstrap(self):
        script, recorded = self.make_bootstrap_stub()
        id_stub = self.root / "id-stub"
        id_stub.write_text('#!/bin/sh\nprintf "%s\\n" "$TEST_UID"\nexit "$TEST_ID_EXIT"\n')
        id_stub.chmod(0o755)
        script.write_text(script.read_text().replace("/usr/bin/id", shlex.quote(str(id_stub))))
        shell = r'''
source "$TEST_SCRIPT"
runtime_dir="$TEST_ROOT/runtime"; config="$runtime_dir/config.plist"
secure_path() { :; }
plist_value() {
  case "$2" in
    BrewBin) printf '/usr/local/bin/brew\n' ;;
    BrewUser) printf 'brewowner\n' ;;
    BrewPrefix) printf '/usr/local\n' ;;
    ServiceLabel) printf 'com.example.tailscaled\n' ;;
    ServicePlist) printf '/Library/LaunchDaemons/com.example.tailscaled.plist\n' ;;
    Socket) printf '/var/run/tailscaled.socket\n' ;;
  esac
}
load_config
brew_as_owner update --quiet
'''
        for uid, id_exit in (("0", "0"), ("invalid", "0"), ("", "1")):
            with self.subTest(uid=uid, id_exit=id_exit):
                env = dict(os.environ, TEST_SCRIPT=str(script), TEST_ROOT=str(self.root),
                           TEST_UID=uid, TEST_ID_EXIT=id_exit)
                result = subprocess.run(["/bin/bash", "-c", shell], env=env,
                                        capture_output=True, text=True, timeout=10)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertFalse(recorded.exists())

    def test_read_only_check_never_updates_or_creates_runtime_files(self):
        before = sorted(p.relative_to(self.root) for p in self.root.rglob("*"))
        self.run_case("read_only", success=True)
        self.assertEqual(before, sorted(p.relative_to(self.root) for p in self.root.rglob("*")))
        self.assertEqual(self.actions(), [])

    def test_successful_upgrade_preserves_service_and_identity(self):
        self.run_case("upgrade", success=True)
        self.assertEqual(self.actions()[-2:], ["brew upgrade --formula tailscale", "restart"])
        self.assertFalse((self.runtime / "RECOVERY_REQUIRED").exists())
        self.assertFalse((self.runtime / "TRANSACTION_PENDING").exists())
        self.assertEqual((self.root / "service.plist").read_text(), "original service plist\n")
        self.assertEqual(json.loads((self.root / "status.json").read_text())["Version"], NEW)

    def test_metadata_and_version_query_failure_do_not_trigger_recovery(self):
        for scenario in ("metadata_failure", "outdated_failure"):
            with self.subTest(scenario=scenario):
                self.run_case(scenario)
                self.assertFalse((self.runtime / "RECOVERY_REQUIRED").exists())
                self.assertFalse((self.runtime / "recovery").exists())
                self.assertNotIn("restart", self.actions())

    def test_partial_upgrade_failure_recovers_independent_backup(self):
        self.run_case("partial_failure")
        self.assert_recovered()
        # Homebrew's new links remain consistent; recovery never rewires them.
        self.assertEqual((self.bin / "tailscaled").resolve(), self.new / "tailscaled")

    def test_mismatched_installed_binaries_recover_before_restart(self):
        self.run_case("mismatch")
        self.assert_recovered()
        self.assertNotIn("restart", self.actions())

    def test_restart_failure_recovers(self):
        self.run_case("restart_failure")
        self.assert_recovered()

    def test_failed_health_checks_recover(self):
        for scenario in ("offline", "identity_change", "version_prefix"):
            with self.subTest(scenario=scenario):
                # Each scenario gets an independent transaction.
                with UpdaterTests("test_current_package_does_not_restart") as case:
                    case.run_case(scenario)
                    case.assert_recovered()

    def test_term_during_upgrade_recovers(self):
        self.run_case("signal")
        self.assert_recovered()

    def test_external_upgrade_restarts_using_retained_old_keg_for_recovery(self):
        self.link_pair(self.new)
        self.run_case("external", success=True)
        self.assertIn("restart", self.actions())
        self.assertNotIn("brew upgrade --formula tailscale", self.actions())
        self.assertEqual((self.runtime / "recovery/tailscaled").read_bytes(),
                         (self.old / "tailscaled").read_bytes())

    def test_homebrew_revision_restarts_even_with_same_long_version(self):
        revision = self.make_keg("1.100.0_1", OLD)
        self.link_pair(revision)
        self.run_case("revision", success=True)
        self.assertIn("restart", self.actions())
        self.assertEqual((self.root / "image").read_text().strip(), str(revision / "tailscaled"))

    def test_missing_retained_old_keg_fails_without_mutation(self):
        self.link_pair(self.new)
        for binary in self.old.iterdir():
            binary.unlink()
        result = self.run_case("missing_old")
        self.assertIn("No retained Homebrew binaries match", result.stderr)
        self.assertEqual(self.actions(), [])
        self.assertFalse((self.runtime / "RECOVERY_REQUIRED").exists())

    def test_existing_recovery_marker_blocks_all_updates(self):
        (self.runtime / "RECOVERY_REQUIRED").write_text("review required")
        self.run_case("current")
        self.assertEqual(self.actions(), [])

    def test_interrupted_transaction_recovers_before_any_homebrew_call(self):
        self.run_case("upgrade", success=True)
        (self.root / "actions").write_text("")
        (self.runtime / "TRANSACTION_PENDING").write_text(OLD)
        self.run_case("current")
        self.assertEqual(self.actions(), ["recover"])
        self.assert_recovered()

    def test_recovery_failure_preserves_markers_and_blocks_retry(self):
        self.run_case("recovery_failure")
        self.assertTrue((self.runtime / "RECOVERY_REQUIRED").exists())
        self.assertTrue((self.runtime / "TRANSACTION_PENDING").exists())
        (self.root / "actions").write_text("")
        self.run_case("current")
        self.assertEqual(self.actions(), [])

    def test_shared_lock_blocks_mutation_and_is_not_removed(self):
        lock = self.root / "shared.lock"
        lock.mkdir()
        (lock / "pid").write_text(str(os.getpid()))
        result = self.run_case("current", retained_lock=True)
        self.assertIn("lock is held", result.stderr)
        self.assertEqual(self.actions(), [])
        self.assertEqual((lock / "pid").read_text(), str(os.getpid()))

    def test_pinned_noop_does_not_switch_service_to_recovery(self):
        result = self.run_case("pinned")
        self.assertIn("pinned", result.stderr)
        self.assertNotIn("recover", self.actions())
        self.assertFalse((self.runtime / "RECOVERY_REQUIRED").exists())

    def __enter__(self):
        self.setUp()
        return self

    def __exit__(self, *args):
        self.doCleanups()


if __name__ == "__main__":
    unittest.main(verbosity=2)
