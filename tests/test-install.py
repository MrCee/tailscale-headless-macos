#!/usr/bin/env python3
"""Test the public install entrypoint without touching the host installation.

Each case copies only install.sh into a temporary checkout. Internal installers
and OS commands are recording stubs; fixed system paths are mapped to temporary
directories. The actual entrypoint's validation and routing run unchanged.
"""
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]

DISPATCH = r'''
import json, os, pathlib, sys
name, args = sys.argv[1], sys.argv[2:]
root = pathlib.Path(os.environ["TEST_INSTALL_ROOT"])
def event(component):
    with (root / "events.jsonl").open("a") as stream:
        stream.write(json.dumps({"component": component, "args": args}) + "\n")
helpers = {"install-headless.sh": ("base", "TEST_BASE_EXIT"),
           "install-auto-updates.sh": ("updates", "TEST_UPDATER_EXIT"),
           "remove-auto-updates.sh": ("remove-updates", "TEST_REMOVER_EXIT")}
if name in helpers:
    component, exit_variable = helpers[name]
    event(component)
    result = int(os.environ.get(exit_variable, "0"))
    if component == "base" and not result:
        (root / "base-created").touch()
    sys.exit(result)
if name == "launchctl":
    if len(args) == 2 and args[0] == "print":
        if args[1] == "system/com.tailscale.headless-updater":
            loaded = os.environ.get("TEST_UPDATER_LOADED") == "1"
        else:
            loaded = os.environ.get("TEST_DAEMON_LOADED") == "1" or (root / "base-created").exists()
        if loaded:
            print("state = running")
        sys.exit(0 if loaded else 113)
elif name == "brew" and args == ["--prefix"]:
    print(root / "homebrew")
    sys.exit(0)
elif name == "uname" and args == ["-s"]:
    print("Darwin")
    sys.exit(0)
elif name == "id":
    print("501" if "-u" in args else "brewowner")
    sys.exit(0)
elif name == "pgrep" and args == ["-x", "tailscaled"]:
    sys.exit(0 if os.environ.get("TEST_UNMANAGED_DAEMON") == "1" else 1)
event("FORBIDDEN:" + name)
print("Unexpected host command denied: " + name + " " + repr(args), file=sys.stderr)
sys.exit(97)
'''


@unittest.skipUnless(Path("/bin/zsh").is_file() and os.geteuid() != 0,
                     "Run installer orchestration tests as a regular user with zsh")
class InstallTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="tailscale-install-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.checkout = self.root / "checkout"
        self.checkout.mkdir()
        self.stubs = self.root / "stubs"
        self.stubs.mkdir()
        self.prefix = self.root / "homebrew"
        (self.prefix / "bin").mkdir(parents=True)
        self.launchdaemons = self.root / "LaunchDaemons"
        self.launchdaemons.mkdir()
        (self.root / "events.jsonl").write_text("")
        self.dispatch = self.root / "dispatch.py"
        self.dispatch.write_text(DISPATCH)
        wrapper = '#!/bin/sh\nexec "$TEST_PYTHON" "$TEST_DISPATCH" "${0##*/}" "$@"\n'
        for name in ("sudo", "launchctl", "brew", "uname", "id", "pgrep", "curl", "plutil",
                     "PlistBuddy", "pkill", "killall", "chown", "chmod", "install"):
            target = self.stubs / name
            target.write_text(wrapper)
            target.chmod(0o755)
        (self.prefix / "bin/brew").symlink_to(self.stubs / "brew")
        scripts = self.checkout / "scripts"
        scripts.mkdir()
        for name in ("install-headless.sh", "install-auto-updates.sh", "remove-auto-updates.sh"):
            target = scripts / name
            target.write_text(wrapper)
            target.chmod(0o755)

        source = (REPO / "install.sh").read_text()
        # Rewrite OS endpoints only, never conditionals or orchestration logic.
        endpoints = {
            "/usr/bin/sudo": self.stubs / "sudo", "/bin/launchctl": self.stubs / "launchctl",
            "/usr/bin/uname": self.stubs / "uname", "/usr/bin/id": self.stubs / "id",
            "/usr/bin/pgrep": self.stubs / "pgrep",
            "/usr/bin/curl": self.stubs / "curl", "/usr/bin/plutil": self.stubs / "plutil",
            "/usr/libexec/PlistBuddy": self.stubs / "PlistBuddy",
            "/Library/LaunchDaemons": self.launchdaemons,
            "/Library/PrivilegedHelperTools": self.root / "PrivilegedHelperTools",
            "/usr/local": self.prefix, "/opt/homebrew": self.root / "arm-homebrew",
            "/var/run": self.root / "run",
        }
        for original, replacement in endpoints.items():
            source = source.replace(original, str(replacement))
        # A fixed production PATH can still be used while its commands resolve
        # to stubs. Absolute commands above are separately redirected.
        source = source.replace("export PATH=", f"export PATH={shlex.quote(str(self.stubs))}:")
        self.entrypoint = self.checkout / "install.sh"
        self.entrypoint.write_text(source)
        self.entrypoint.chmod(0o755)
        self.defaults = {
            "TAILNET_DOMAIN": "test-tailnet.ts.net",
            "BREW_BIN": str(self.prefix / "bin/brew"),
            "LAUNCHD_LABEL": "com.example.tailscaled",
            "LAUNCHD_PLIST": str(self.launchdaemons / "com.example.tailscaled.plist"),
            "TAILSCALED_SOCKET": str(self.root / "run/tailscaled.socket"),
            "STATE_DIR": str(self.root / "state"),
            "STATE_FILE": str(self.root / "state/tailscaled.state"),
            "LOG_OUT": str(self.root / "tailscaled.log"),
            "LOG_ERR": str(self.root / "tailscaled.err"),
        }
        self.write_config()

    def write_config(self, **overrides):
        values = dict(self.defaults, **overrides)
        (self.checkout / ".env").write_text("".join(
            f"{key}={shlex.quote(str(value))}\n" for key, value in values.items()))

    def events(self):
        return [json.loads(line) for line in (self.root / "events.jsonl").read_text().splitlines()]

    def run_install(self, *arguments, success=True, **controls):
        env = os.environ.copy()
        # Prevent the caller's configuration from influencing the isolated run.
        for name in tuple(self.defaults) + ("AUTO_UPDATE", "AUTO_UPDATE_HOUR", "AUTO_UPDATE_MINUTE"):
            env.pop(name, None)
        env.update(TEST_INSTALL_ROOT=str(self.root), TEST_PYTHON=sys.executable,
                   TEST_DISPATCH=str(self.dispatch), PATH=f"{self.stubs}:{env.get('PATH', '')}")
        env.update({key: str(value) for key, value in controls.items()})
        result = subprocess.run(["/bin/zsh", "-f", str(self.entrypoint), *arguments],
                                cwd=self.checkout, env=env, capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
        forbidden = [item for item in self.events() if item["component"].startswith("FORBIDDEN:")]
        self.assertEqual(forbidden, [], result.stdout + result.stderr)
        return result

    def test_new_install_enables_updates_by_default(self):
        self.run_install()
        events = self.events()
        self.assertEqual([item["component"] for item in events], ["base", "updates"])
        args = events[1]["args"]
        self.assertEqual(args[args.index("--hour") + 1], "4")
        self.assertEqual(args[args.index("--minute") + 1], "15")
        self.assertEqual(args[args.index("--label") + 1], "com.example.tailscaled")
        self.assertEqual(args[args.index("--socket") + 1], self.defaults["TAILSCALED_SOCKET"])

    def test_existing_daemon_skips_base_install(self):
        self.run_install(TEST_DAEMON_LOADED=1)
        self.assertEqual([item["component"] for item in self.events()], ["updates"])
        self.assertFalse((self.root / "base-created").exists())

    def test_explicit_false_opts_out_of_updates_on_new_install(self):
        self.write_config(AUTO_UPDATE="false")
        self.run_install()
        self.assertEqual([item["component"] for item in self.events()], ["base"])

    def test_false_removes_existing_schedule_without_rebuilding_daemon(self):
        self.write_config(AUTO_UPDATE="false")
        self.run_install(TEST_DAEMON_LOADED=1, TEST_UPDATER_LOADED=1)
        self.assertEqual([item["component"] for item in self.events()], ["remove-updates"])

    def test_false_without_existing_schedule_leaves_daemon_untouched(self):
        self.write_config(AUTO_UPDATE="false")
        self.run_install(TEST_DAEMON_LOADED=1)
        self.assertEqual(self.events(), [])

    def test_custom_schedule_is_passed_to_internal_installer(self):
        self.write_config(AUTO_UPDATE_HOUR="6", AUTO_UPDATE_MINUTE="45")
        self.run_install(TEST_DAEMON_LOADED=1)
        args = self.events()[0]["args"]
        self.assertEqual(args[args.index("--hour") + 1], "6")
        self.assertEqual(args[args.index("--minute") + 1], "45")

    def test_invalid_configuration_fails_before_any_installation(self):
        cases = ({"AUTO_UPDATE": "maybe"}, {"AUTO_UPDATE_HOUR": "24"},
                 {"AUTO_UPDATE_MINUTE": "60"}, {"LAUNCHD_LABEL": "bad/label"},
                 {"LAUNCHD_LABEL": ".bad-label"}, {"LAUNCHD_LABEL": "-bad-label"},
                 {"LAUNCHD_PLIST": str(self.root / "wrong.plist")},
                 {"TAILSCALED_SOCKET": "relative.socket"})
        for values in cases:
            with self.subTest(values=values):
                self.write_config(**values)
                self.run_install(success=False)
                self.assertEqual(self.events(), [])

    def test_placeholder_tailnet_fails_before_new_install(self):
        self.write_config(TAILNET_DOMAIN="your-tailnet.ts.net")
        self.run_install(success=False)
        self.assertEqual(self.events(), [])

    def test_unmanaged_daemon_blocks_new_install(self):
        self.run_install(success=False, TEST_UNMANAGED_DAEMON=1)
        self.assertEqual(self.events(), [])

    def test_existing_daemon_can_be_maintained_without_env_file(self):
        (self.checkout / ".env").unlink()
        self.run_install(TEST_DAEMON_LOADED=1)
        self.assertEqual([item["component"] for item in self.events()], ["updates"])

    def test_fresh_install_requires_env_before_calling_helpers(self):
        (self.checkout / ".env").unlink()
        self.run_install(success=False)
        self.assertEqual(self.events(), [])

    def test_base_failure_does_not_schedule_updates_or_report_completion(self):
        result = self.run_install(success=False, TEST_BASE_EXIT=9)
        self.assertEqual([item["component"] for item in self.events()], ["base"])
        self.assertNotIn("INSTALL COMPLETE", result.stdout.upper())

    def test_updater_failure_does_not_report_completed_install(self):
        result = self.run_install(success=False, TEST_UPDATER_EXIT=8)
        self.assertEqual([item["component"] for item in self.events()], ["base", "updates"])
        self.assertNotIn("INSTALL COMPLETE", result.stdout.upper())
        self.assertIn("incomplete", (result.stdout + result.stderr).lower())

    def test_new_install_check_does_not_call_installers(self):
        self.run_install("--check")
        self.assertEqual(self.events(), [])

    def test_existing_check_calls_only_read_only_updater_preflight(self):
        self.run_install("--check", TEST_DAEMON_LOADED=1)
        self.assertEqual([item["component"] for item in self.events()], ["updates"])
        self.assertIn("--check", self.events()[0]["args"])

    def test_unknown_argument_fails_without_side_effects(self):
        self.run_install("--unknown-option", success=False)
        self.assertEqual(self.events(), [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
