#!/usr/bin/env python3
"""Exercise real transaction/recovery control flow using isolated OS adapters."""
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/update-tailscale.sh'
OLD = '1.100.0-t111111111'
NEW = '1.104.2-t222222222'
HARNESS = r'''
source "$TEST_SCRIPT"
load_config() {
  runtime_dir="$TEST_ROOT/runtime"; config="$runtime_dir/config.plist"
  binary_root="$TEST_ROOT/binaries"; build_user=builduser; build_uid=501
  service_label=com.example.tailscaled; service=system/$service_label
  service_plist="$TEST_ROOT/service.plist"; socket="$TEST_ROOT/socket"
  cli="$binary_root/current/tailscale"; daemon="$binary_root/current/tailscaled"
  recovery="$runtime_dir/recovery"; pending="$runtime_dir/TRANSACTION_PENDING"
  marker="$runtime_dir/RECOVERY_REQUIRED"; lock_dir="$TEST_ROOT/shared.lock"
}
load_config
action() { printf '%s\n' "$*" >> "$TEST_ROOT/actions"; }
preflight() { :; }
secure_path() { [[ -e "$1" && ! -L "$1" ]]; }
json_value() {
  "$TEST_PYTHON" -c 'import json,sys
v=json.load(sys.stdin)
for k in sys.argv[1].split("."): v=v[k]
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
build_as_user() {
  action "lookup $*"
  [[ "$SCENARIO" != metadata_failure ]] || return 1
  case "$SCENARIO" in current|read_only) printf '1.100.0\n' ;; downgrade) printf '1.98.0\n' ;; *) printf '1.104.2\n' ;; esac
}
build_candidate() {
  action "build $*"
  [[ "$SCENARIO" != build_failure && "$SCENARIO" != mismatch ]] || return 1
  candidate_cli="$binary_root/releases/new/tailscale"
  candidate_daemon="$binary_root/releases/new/tailscaled"
  candidate_version=$(binary_version "$candidate_daemon")
}
production_select=$(declare -f select_current)
select_current() {
  action "select $1"
  if [[ "$SCENARIO" == switch_failure && "$1" != "$recovery" ]]; then return 1; fi
  eval "$production_select"
  select_current "$1"
  # Reinstall this recording wrapper for any later recovery call.
  eval "$recording_select"
  if [[ "$SCENARIO" == signal && "$1" != "$recovery" ]]; then kill -TERM "$$"; fi
}
recording_select=$(declare -f select_current)
restart_service() {
  action restart
  [[ "$SCENARIO" != restart_failure ]] || return 1
  printf '%s\n' "$candidate_daemon" > "$TEST_ROOT/image"
  local online=true node=original-node version="$candidate_version"
  [[ "$SCENARIO" != offline && "$SCENARIO" != recovery_failure ]] || online=false
  [[ "$SCENARIO" != identity_change ]] || node=wrong-node
  [[ "$SCENARIO" != version_mismatch ]] || version="${candidate_version}extra"
  set_status "$version" "$node" "$online"
}
wait_healthy() { healthy "$1" "$2"; }
install_recovery_service() {
  action recover
  [[ "$SCENARIO" != recovery_failure ]] || return 1
  printf '%s\n' "$recovery/tailscaled" > "$TEST_ROOT/image"
  set_status "$original_version" "$original_node" true
}
transaction_active=0; lock_held=0
if [[ "$SCENARIO" == read_only ]]; then
  main --check
  [[ "$native_arch" == "${TEST_EXPECT_ARCH:-x86_64}" ]]
else
  trap finish EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  acquire_lock
  perform_update
fi
'''

class UpdaterTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='tailscale-updater-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.runtime = self.root / 'runtime'; self.runtime.mkdir()
        (self.runtime / 'config.plist').write_text('original config\n')
        (self.root / 'service.plist').write_text('original plist\n')
        (self.root / 'state').write_text('preserve state\n')
        (self.root / 'actions').touch()
        self.old = self.make_pair('old', OLD)
        self.new = self.make_pair('new', NEW)
        (self.root / 'binaries/current').symlink_to(self.old)
        (self.root / 'image').write_text(str(self.old / 'tailscaled'))
        (self.root / 'status.json').write_text(json.dumps({
            'Version': OLD, 'BackendState': 'Running',
            'Self': {'ID': 'original-node', 'Online': True}}))
        # Make read-only main checks architecture-independent on CI runners.
        uname = self.root / 'uname'; uname.write_text('#!/bin/sh\nif [ "$1" = -s ]; then echo Darwin; else echo "${TEST_MACHINE:-x86_64}"; fi\n'); uname.chmod(0o755)
        sysctl = self.root / 'sysctl'; sysctl.write_text('#!/bin/sh\necho "${TEST_ARM64:-0}"\n'); sysctl.chmod(0o755)
        self.script = self.root / 'updater.sh'
        self.script.write_text(SCRIPT.read_text().replace('/usr/bin/uname', shlex.quote(str(uname))).replace('/usr/sbin/sysctl', shlex.quote(str(sysctl))))

    def make_pair(self, name, version):
        directory = self.root / 'binaries/releases' / name; directory.mkdir(parents=True)
        for binary in ('tailscale', 'tailscaled'):
            path = directory / binary
            path.write_text("#!/bin/sh\nprintf '%s\\n' " + shlex.quote(version.split('-')[0]) + ' ' + shlex.quote('  long version: ' + version) + '\n')
            path.chmod(0o755)
        return directory

    def test_native_candidate_validation_and_existing_release_reuse(self):
        lipo = self.root / 'lipo'
        lipo.write_text('#!/bin/sh\nprintf "%s\\n" "$3" >> "$TEST_ROOT/architectures"\n[ "$3" = "$TEST_BINARY_ARCH" ]\n')
        lipo.chmod(0o755)
        chown = self.root / 'chown'; chown.write_text('#!/bin/sh\nexit 0\n'); chown.chmod(0o755)
        self.script.write_text(self.script.read_text().replace('/usr/bin/lipo', shlex.quote(str(lipo)))
                               .replace('/usr/sbin/chown', shlex.quote(str(chown))))
        harness = r'''
source "$TEST_SCRIPT"
binary_root="$TEST_ROOT/binaries"; build_user=test; native_arch="$TEST_NATIVE_ARCH"
secure_path() { [[ -e "$1" && ! -L "$1" ]]; }
install_recovery_file() { /bin/cp "$1" "$2" && /bin/chmod "$3" "$2"; }
build_as_user() {
  [[ "$3" == --output ]] || return 99
  /bin/mkdir "$4"
  /bin/cp "$binary_root/releases/new/tailscale" "$binary_root/releases/new/tailscaled" "$4/"
}
trap '[[ -z "${build_staging:-}" ]] || /bin/rm -rf "$build_staging"' EXIT
build_candidate 1.104.2
'''
        for native in ('x86_64', 'arm64'):
            with self.subTest(native=native):
                env = dict(os.environ, TEST_SCRIPT=str(self.script), TEST_ROOT=str(self.root),
                           TEST_NATIVE_ARCH=native, TEST_BINARY_ARCH=native)
                # Exercise both a new release and the already-present path.
                for _ in range(2):
                    result = subprocess.run(['/bin/bash', '-c', harness], env=env, capture_output=True, text=True, timeout=15)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertTrue(all(arch == native for arch in (self.root / 'architectures').read_text().splitlines()))
                (self.root / 'architectures').unlink()
                env['TEST_BINARY_ARCH'] = 'wrong'
                result = subprocess.run(['/bin/bash', '-c', harness], env=env, capture_output=True, text=True, timeout=15)
                self.assertNotEqual(result.returncode, 0)
                (self.root / 'architectures').unlink()

    def test_apple_silicon_and_rosetta_updater_preflight(self):
        for machine in ('arm64', 'x86_64'):
            with self.subTest(machine=machine):
                self.run_case('read_only', success=True, TEST_MACHINE=machine,
                              TEST_ARM64='1', TEST_EXPECT_ARCH='arm64')
                self.assertEqual(self.actions(), [])

    def run_case(self, scenario, success=False, retained_lock=False, **controls):
        env = dict(os.environ, TEST_ROOT=str(self.root), TEST_SCRIPT=str(self.script), TEST_PYTHON=sys.executable, SCENARIO=scenario)
        env.update(controls)
        result = subprocess.run(['/bin/bash', '-c', HARNESS], env=env, capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
        self.assertEqual((self.root / 'state').read_text(), 'preserve state\n')
        self.assertEqual((self.root / 'shared.lock').exists(), retained_lock)
        return result

    def actions(self):
        return (self.root / 'actions').read_text().splitlines()

    def assert_recovered(self):
        self.assertIn('recover', self.actions())
        self.assertTrue((self.runtime / 'RECOVERY_REQUIRED').exists())
        self.assertFalse((self.runtime / 'TRANSACTION_PENDING').exists())
        self.assertEqual((self.runtime / 'recovery/tailscaled').read_bytes(), (self.old / 'tailscaled').read_bytes())
        self.assertEqual((self.runtime / 'recovery/service-original.plist').read_text(), 'original plist\n')
        self.assertEqual((self.root / 'binaries/current').resolve(), self.runtime / 'recovery')
        self.assertEqual(json.loads((self.root / 'status.json').read_text())['Version'], OLD)

    def test_build_wrapper_drops_root_and_cleans_environment(self):
        recorded = self.root / 'argv.json'
        stub = self.root / 'launchctl-stub'
        body = 'import json,sys; json.dump(sys.argv[1:],open(' + repr(str(recorded)) + ', "w"))'
        stub.write_text('#!/bin/sh\nexec ' + shlex.quote(sys.executable) + ' -c ' + shlex.quote(body) + ' "$@"\n')
        stub.chmod(0o755)
        dscl = self.root / 'dscl-stub'; dscl.write_text('#!/bin/sh\necho "NFSHomeDirectory: /Users/builduser"\n'); dscl.chmod(0o755)
        script = self.root / 'wrapper.sh'
        script.write_text(SCRIPT.read_text().replace('/bin/launchctl', shlex.quote(str(stub))).replace('/usr/bin/dscl', shlex.quote(str(dscl))))
        shell = 'source "$1"; build_uid=501; build_user=builduser; runtime_dir=/protected/runtime; build_as_user --version 1.104.2 --output /tmp/output'
        result = subprocess.run(['/bin/bash', '-c', shell, 'test', str(script)], capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        args = json.loads(recorded.read_text())
        self.assertEqual(args[:9], ['asuser', '501', '/usr/bin/sudo', '-n', '-H', '-u', 'builduser', '/usr/bin/env', '-i'])
        self.assertIn('HOME=/Users/builduser', args)
        self.assertEqual(args[-5:], ['/protected/runtime/build-tailscale.sh', '--version', '1.104.2', '--output', '/tmp/output'])

    def test_current_release_needs_no_build_or_restart(self):
        self.run_case('current', success=True)
        self.assertEqual(self.actions(), ['lookup --latest'])
        self.assertFalse((self.runtime / 'recovery').exists())

    def test_successful_update_preserves_identity_state_and_plist(self):
        self.run_case('upgrade', success=True)
        self.assertIn('build 1.104.2', self.actions())
        self.assertEqual(self.actions()[-1], 'restart')
        self.assertEqual((self.root / 'binaries/current').resolve(), self.new)
        self.assertEqual((self.root / 'service.plist').read_text(), 'original plist\n')
        self.assertFalse((self.runtime / 'TRANSACTION_PENDING').exists())
        self.assertFalse((self.runtime / 'RECOVERY_REQUIRED').exists())

    def test_lookup_failure_does_not_change_daemon(self):
        self.run_case('metadata_failure')
        self.assertEqual((self.root / 'binaries/current').resolve(), self.old)
        self.assertFalse((self.runtime / 'recovery').exists())

    def test_build_failure_does_not_start_transaction(self):
        self.run_case('build_failure')
        self.assertNotIn('restart', self.actions())
        self.assertFalse((self.runtime / 'RECOVERY_REQUIRED').exists())
        self.assertFalse((self.runtime / 'recovery').exists())

    def test_mismatched_build_fails_before_switch(self):
        self.run_case('mismatch')
        self.assertEqual((self.root / 'binaries/current').resolve(), self.old)
        self.assertNotIn('recover', self.actions())

    def test_automatic_downgrade_refused(self):
        self.run_case('downgrade')
        self.assertEqual(self.actions(), ['lookup --latest'])

    def test_switch_failure_recovers(self):
        self.run_case('switch_failure'); self.assert_recovered()

    def test_restart_failure_recovers(self):
        self.run_case('restart_failure'); self.assert_recovered()

    def test_offline_update_recovers(self):
        self.run_case('offline'); self.assert_recovered()

    def test_changed_identity_recovers(self):
        self.run_case('identity_change'); self.assert_recovered()

    def test_version_mismatch_recovers(self):
        self.run_case('version_mismatch'); self.assert_recovered()

    def test_signal_during_switch_recovers(self):
        self.run_case('signal'); self.assert_recovered()

    def test_interrupted_transaction_recovers_before_lookup(self):
        self.run_case('upgrade', success=True)
        (self.root / 'actions').write_text('')
        (self.runtime / 'TRANSACTION_PENDING').write_text(OLD)
        self.run_case('current'); self.assert_recovered()
        self.assertFalse(any(a.startswith('lookup') for a in self.actions()))

    def test_recovery_failure_retains_markers_and_blocks_retry(self):
        self.run_case('recovery_failure')
        self.assertTrue((self.runtime / 'RECOVERY_REQUIRED').exists())
        self.assertTrue((self.runtime / 'TRANSACTION_PENDING').exists())
        (self.root / 'actions').write_text('')
        self.run_case('current'); self.assertEqual(self.actions(), [])

    def test_recovery_hold_blocks_updates(self):
        (self.runtime / 'RECOVERY_REQUIRED').touch()
        self.run_case('current'); self.assertEqual(self.actions(), [])

    def test_live_lock_is_not_removed(self):
        lock = self.root / 'shared.lock'; lock.mkdir(); (lock / 'pid').write_text(str(os.getpid()))
        self.run_case('current', retained_lock=True)
        self.assertEqual(self.actions(), [])

    def test_read_only_check_does_not_build_or_write(self):
        before = sorted(p.relative_to(self.root) for p in self.root.rglob('*'))
        self.run_case('read_only', success=True)
        self.assertEqual(before, sorted(p.relative_to(self.root) for p in self.root.rglob('*')))
        self.assertEqual(self.actions(), [])

if __name__ == '__main__':
    unittest.main(verbosity=2)
