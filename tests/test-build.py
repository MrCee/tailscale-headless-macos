#!/usr/bin/env python3
"""Check direct Go bootstrap with local archives; no host installation/network."""
import hashlib
import json
import os
from pathlib import Path
import shlex
import subprocess
import tarfile
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/build-tailscale.sh'

class BuildTests(unittest.TestCase):
    goarch = 'amd64'
    machine = 'x86_64'
    arm_capable = '0'

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='tailscale-go-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        (self.root / 'cache').mkdir(); (self.root / 'work').mkdir()
        tree = self.root / 'archive/go/bin'; tree.mkdir(parents=True)
        go = tree / 'go'; go.write_text(f'#!/bin/sh\necho "go version go1.27.3 darwin/{self.goarch}"\n'); go.chmod(0o755)
        self.archive = self.root / 'go.tar.gz'
        with tarfile.open(self.archive, 'w:gz') as tf:
            tf.add(self.root / 'archive/go', arcname='go')
        self.metadata = [{'version': 'go1.27.3', 'stable': True, 'files': [
            {'filename': f'go1.27.3.darwin-{"arm64" if self.goarch == "amd64" else "amd64"}.tar.gz', 'sha256': '0' * 64},
            {'filename': f'go1.27.3.darwin-{self.goarch}.tar.gz', 'sha256': hashlib.sha256(self.archive.read_bytes()).hexdigest()}]}]
        self.meta = self.root / 'metadata.json'
        uname = self.root / 'uname'
        uname.write_text(f'#!/bin/sh\nif [ "$1" = -s ]; then echo Darwin; else echo {self.machine}; fi\n')
        uname.chmod(0o755)
        sysctl = self.root / 'sysctl'
        sysctl.write_text(f'#!/bin/sh\necho {self.arm_capable}\n'); sysctl.chmod(0o755)
        self.script = self.root / 'builder.sh'
        self.script.write_text(SCRIPT.read_text().replace('/usr/bin/uname', shlex.quote(str(uname)))
                               .replace('/usr/sbin/sysctl', shlex.quote(str(sysctl))))

    def run_bootstrap(self, success=True, candidate=None, required='1.27.3'):
        self.meta.write_text(json.dumps(self.metadata))
        harness = r'''
source "$TEST_SCRIPT"
detect_architecture
cache="$TEST_ROOT/cache"; work="$TEST_ROOT/work"
fetch() {
  printf '%s\n' "$1" >> "$TEST_ROOT/downloads"
  case "$1" in
    'https://go.dev/dl/?mode=json') /bin/cat "$TEST_ROOT/metadata.json" ;;
    "https://go.dev/dl/go1.27.3.darwin-$goarch.tar.gz") /bin/cat "$TEST_ROOT/go.tar.gz" ;;
    *) echo 'Unexpected URL' >&2; return 99 ;;
  esac
}
ensure_go "$TEST_REQUIRED"
printf '%s\n' "$go_bin" > "$TEST_ROOT/selected"
'''
        env = dict(os.environ, TEST_SCRIPT=str(self.script), TEST_ROOT=str(self.root),
                   TEST_REQUIRED=required, GO_BIN=str(candidate or self.root / 'missing-go'))
        result = subprocess.run(['/bin/bash', '-c', harness], env=env, capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
        return result

    def test_missing_go_downloads_verified_native_archive(self):
        self.run_bootstrap()
        self.assertTrue((self.root / 'cache/go/bin/go').exists())
        self.assertEqual((self.root / 'downloads').read_text().splitlines(), [
            'https://go.dev/dl/?mode=json', f'https://go.dev/dl/go1.27.3.darwin-{self.goarch}.tar.gz'])

    def test_checksum_mismatch_refuses_extraction(self):
        self.metadata[0]['files'][1]['sha256'] = '0' * 64
        result = self.run_bootstrap(success=False)
        self.assertIn('checksum mismatch', result.stderr)
        self.assertFalse((self.root / 'cache/go').exists())

    def test_existing_compatible_go_is_reused_without_downloads(self):
        self.run_bootstrap(candidate=self.root / 'archive/go/bin/go')
        self.assertFalse((self.root / 'downloads').exists())
        self.assertEqual((self.root / 'selected').read_text().strip(), str(self.root / 'archive/go/bin/go'))

    def test_cached_go_is_reused(self):
        self.run_bootstrap()
        (self.root / 'downloads').unlink()
        self.run_bootstrap()
        self.assertFalse((self.root / 'downloads').exists())

    def test_old_go_triggers_bootstrap(self):
        old = self.root / 'old-go'; old.write_text(f'#!/bin/sh\necho "go version go1.20.1 darwin/{self.goarch}"\n'); old.chmod(0o755)
        self.run_bootstrap(candidate=old)
        self.assertTrue((self.root / 'cache/go/bin/go').exists())

    def test_missing_native_release_fails(self):
        self.metadata[0]['files'].pop()
        self.run_bootstrap(success=False)
        self.assertFalse((self.root / 'cache/go').exists())

    def test_unstable_go_is_refused(self):
        self.metadata[0]['stable'] = False
        self.run_bootstrap(success=False)

    def test_too_old_available_go_is_refused(self):
        self.run_bootstrap(success=False, required='1.28.0')
        self.assertFalse((self.root / 'cache/go').exists())

    def test_wrong_architecture_go_is_not_reused(self):
        other = 'arm64' if self.goarch == 'amd64' else 'amd64'
        wrong = self.root / 'wrong-go'
        wrong.write_text(f'#!/bin/sh\necho "go version go1.27.3 darwin/{other}"\n')
        wrong.chmod(0o755)
        self.run_bootstrap(candidate=wrong)
        self.assertEqual((self.root / 'selected').read_text().strip(), str(self.root / 'cache/go/bin/go'))

    def run_full_build(self, wrong_arch=False):
        module = self.root / 'module'; module.mkdir()
        # Only network, compiler and Mach-O inspection are adapters. Exercise
        # main's real target selection, release/version checks and publication.
        compiler = self.root / 'fake-go'
        compiler.write_text(f'''#!/bin/sh
case "$1" in
  version) echo 'go version go1.27.3 darwin/{self.goarch}' ;;
  mod) printf '{{"Dir":"%s"}}\\n' "$TEST_ROOT/module" ;;
  *) exit 99 ;;
esac
''')
        compiler.chmod(0o755)
        (module / 'build_dist.sh').write_text(r'''#!/bin/sh
set -eu
printf '%s %s %s %s\n' "$GOOS" "$GOARCH" "${GOAMD64:-unset}" "${GOARM64:-unset}" >> "$TEST_ROOT/targets"
arch=x86_64
if [ "$GOARCH" = arm64 ]; then arch=arm64; fi
if [ "$TEST_WRONG_ARCH" = 1 ]; then arch=wrong; fi
printf '#!/bin/sh\n# arch=%s\nprintf "  long version: %%s\\n" "%s"\n' "$arch" "$TS_VERSION_LONG" > "$2"
chmod +x "$2"
''')
        lipo = self.root / 'lipo'
        lipo.write_text('#!/bin/sh\nprintf "%s\\n" "$3" >> "$TEST_ROOT/inspected"\n/usr/bin/grep -q "^# arch=$3$" "$1"\n')
        lipo.chmod(0o755)
        self.script.write_text(self.script.read_text().replace('/usr/bin/lipo', shlex.quote(str(lipo))))
        harness = r'''
source "$TEST_SCRIPT"
fetch() {
  case "$1" in
    *.mod) printf 'go 1.27.3\n' ;;
    *.info) printf '{"Version":"v1.104.2","Origin":{"Hash":"2222222222222222222222222222222222222222"}}' ;;
    *) return 99 ;;
  esac
}
main --version 1.104.2 --cache "$TEST_ROOT/cache" --output "$TEST_ROOT/output"
'''
        env = dict(os.environ, TEST_SCRIPT=str(self.script), TEST_ROOT=str(self.root),
                   TEST_WRONG_ARCH=str(int(wrong_arch)), GO_BIN=str(compiler),
                   GOARCH='wrong-inherited-target', GOAMD64='v4', GOARM64='v9.5')
        result = subprocess.run(['/bin/bash', '-c', harness], env=env, capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode == 0, not wrong_arch, result.stdout + result.stderr)
        return result

    def test_full_build_selects_native_target_and_checks_both_binaries(self):
        self.run_full_build()
        expected = 'darwin amd64 v1 unset' if self.goarch == 'amd64' else 'darwin arm64 unset v8.0'
        self.assertEqual((self.root / 'targets').read_text().splitlines(), [expected, expected])
        native = 'x86_64' if self.goarch == 'amd64' else 'arm64'
        self.assertEqual((self.root / 'inspected').read_text().splitlines(), [native, native])
        self.assertEqual((self.root / 'output/version').read_text(), '1.104.2-t222222222\n')

    def test_wrong_architecture_build_is_not_published(self):
        self.run_full_build(wrong_arch=True)
        self.assertFalse((self.root / 'output').exists())

    def test_stable_tailscale_version_filter(self):
        for version, valid in [('1.104.2', True), ('1.105.0', False), ('1.104.2-rc1', False), ('latest', False), ('1.104.2/evil', False)]:
            with self.subTest(version=version):
                result = subprocess.run(['/bin/bash', '-c', 'source "$1"; stable_version "$2"', 'test', str(SCRIPT), version], capture_output=True)
                self.assertEqual(result.returncode == 0, valid)

class AppleSiliconBuildTests(BuildTests):
    goarch = 'arm64'
    machine = 'arm64'
    arm_capable = '1'

class RosettaBuildTests(AppleSiliconBuildTests):
    machine = 'x86_64'

if __name__ == '__main__':
    unittest.main(verbosity=2)
