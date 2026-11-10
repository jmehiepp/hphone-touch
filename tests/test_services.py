"""Test the real service data engine using fake, isolated app containers on macOS."""
import json
import os
from pathlib import Path
import plistlib
import subprocess
import struct
import sys
import tempfile
import unittest


class ServicesTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.data = self.root / "HPhoneTouch"
        self.data.mkdir()
        self.containers = self.root / "containers"
        self.app = self.containers / "sample-app"
        (self.app / "Documents").mkdir(parents=True)
        (self.app / "Library").mkdir()
        (self.app / "Documents/state.txt").write_text("owned test data", encoding="utf-8")
        (self.app / ".com.apple.mobile_container_manager.metadata.plist").write_bytes(b"container identity")
        self.mapfile = self.root / "apps.plist"
        self.write_map()
        self.cookiefile = self.root / "Cookies.binarycookies"
        self.cookiefile.write_bytes(self.cookie_fixture())
        env = dict(os.environ, HPHONE_TEST_DATA=str(self.data), HPHONE_TEST_CONTAINERS=str(self.containers), HPHONE_TEST_APPS=str(self.mapfile), HPHONE_TEST_COOKIE_FILE=str(self.cookiefile))
        self.proc = subprocess.Popen([sys.argv[1]], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, env=env)

    def write_map(self, pid=0):
        self.mapfile.write_bytes(plistlib.dumps({"com.example.owned": {"bundleId":"com.example.owned", "dataContainer":str(self.app), "testPid":pid}}))

    @staticmethod
    def cookie_fixture():
        records = []
        for domain, name, value in ((".example.test", "owned", "synthetic-only"), ("other.test", "keep", "unrelated-fixture")):
            record = bytearray(56)
            # Deliberately pack strings out of header order to exercise offsets.
            offsets = {}
            for field, text in (("value", value), ("path", "/"), ("name", name), ("domain", domain)):
                offsets[field] = len(record)
                record += text.encode() + b"\0"
            struct.pack_into("<I", record, 0, len(record))
            struct.pack_into("<I", record, 8, 5)
            struct.pack_into("<4I", record, 16, *(offsets[field] for field in ("domain", "name", "path", "value")))
            struct.pack_into("<2d", record, 40, 2000000000 - 978307200, 1700000000 - 978307200)
            records.append(record)
        page = bytearray(b"\0\0\1\0" + struct.pack("<I", len(records)) + bytes(4*len(records)+4))
        for index, record in enumerate(records):
            struct.pack_into("<I", page, 8+index*4, len(page))
            page += record
        footer = struct.pack(">I", sum(page[::4]) & 0xffffffff) + bytes.fromhex("07172005") + b"fixture-metadata"
        return b"cook" + struct.pack(">2I", 1, len(page)) + page + footer

    def tearDown(self):
        self.proc.stdin.close()
        self.proc.wait(timeout=5)
        self.proc.stdout.close()
        self.temp.cleanup()

    def call(self, op, **args):
        self.proc.stdin.write(json.dumps({"operation":op,"arguments":args})+"\n")
        self.proc.stdin.flush()
        line = self.proc.stdout.readline()
        self.assertTrue(line, "Service process exited unexpectedly")
        return json.loads(line)

    def test_backup_restore_wipe_recovery(self):
        result = self.call("backupApp", bundleId="com.example.owned", name="first")
        self.assertTrue(result["ok"], result)
        self.assertFalse(result["value"]["hasKeychain"])
        self.assert_payload_matches_manifest(Path(result["value"]["path"]))
        (self.app / "Documents/state.txt").write_text("changed")
        self.assertFalse(self.call("restoreApp", bundleId="com.example.owned", name="first")["ok"])
        restored = self.call("restoreApp", bundleId="com.example.owned", name="first", confirmBundle="com.example.owned")
        self.assertTrue(restored["ok"], restored)
        self.assertEqual((self.app / "Documents/state.txt").read_text(), "owned test data")
        self.assertTrue(restored["recoveryBackup"].startswith("before-restore-"))
        wiped = self.call("wipeApp", bundleId="com.example.owned", confirmBundle="com.example.owned")
        self.assertTrue(wiped["ok"], wiped)
        self.assertFalse((self.app / "Documents").exists())
        self.assertEqual((self.app / ".com.apple.mobile_container_manager.metadata.plist").read_bytes(), b"container identity")
        recovery = self.call("restoreApp", bundleId="com.example.owned", name=wiped["recoveryBackup"], confirmBundle="com.example.owned")
        self.assertTrue(recovery["ok"], recovery)
        self.assertEqual((self.app / "Documents/state.txt").read_text(), "owned test data")
        self.assertGreaterEqual(len(self.call("listBackups", bundleId="com.example.owned")["value"]), 4)

    def assert_payload_matches_manifest(self, folder):
        import hashlib
        import stat
        manifest = json.loads((folder / "manifest.json").read_text())
        root = folder / "data"
        self.assertEqual({p.relative_to(root).as_posix() for p in root.rglob("*")}, {row["path"] for row in manifest["entries"]})
        for row in manifest["entries"]:
            path = root / row["path"]
            actual = path.stat()
            self.assertEqual(stat.S_ISDIR(actual.st_mode), bool(row["directory"]), row)
            self.assertEqual(stat.S_IMODE(actual.st_mode), row["mode"], row)
            if not row["directory"]:
                self.assertEqual(actual.st_size, row["size"], row)
                self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), row["sha256"], row)

    def test_backup_restore_through_parent_path_alias(self):
        # macOS /var -> /private/var and user-chosen aliases must yield the same
        # relative manifest paths when NSURL canonicalizes enumeration roots.
        self.proc.stdin.close()
        self.proc.wait(timeout=5)
        self.proc.stdout.close()
        alias = self.root / "parent-alias"
        alias.symlink_to(self.root, target_is_directory=True)
        env = dict(os.environ, HPHONE_TEST_DATA=str(alias / "HPhoneTouch"), HPHONE_TEST_CONTAINERS=str(self.containers), HPHONE_TEST_APPS=str(self.mapfile), HPHONE_TEST_COOKIE_FILE=str(self.cookiefile))
        self.proc = subprocess.Popen([sys.argv[1]], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, env=env)
        saved = self.call("backupApp", bundleId="com.example.owned", name="alias")
        self.assertTrue(saved["ok"], saved)
        self.assert_payload_matches_manifest(Path(saved["value"]["path"]))
        (self.app / "Documents/state.txt").write_text("changed")
        restored = self.call("restoreApp", bundleId="com.example.owned", name="alias", confirmBundle="com.example.owned")
        self.assertTrue(restored["ok"], restored)
        self.assertEqual((self.app / "Documents/state.txt").read_text(), "owned test data")

    def test_tampered_backup_does_not_replace_data(self):
        first = self.call("backupApp", bundleId="com.example.owned", name="first")
        payload = Path(first["value"]["path"]) / "data/Documents/state.txt"
        payload.write_text("tampered")
        result = self.call("restoreApp", bundleId="com.example.owned", name="first", confirmBundle="com.example.owned")
        self.assertFalse(result["ok"], result)
        self.assertEqual(result["code"], "integrity")
        self.assertEqual((self.app / "Documents/state.txt").read_text(), "owned test data")

    def test_paths_symlink_running_and_system_app_protection(self):
        for name in ("../escape", "/tmp/escape", ".hidden", "a/b"):
            self.assertFalse(self.call("backupApp", bundleId="com.example.owned", name=name)["ok"])
        outside = self.root / "outside"
        outside.write_text("outside unchanged")
        link = self.app / "Documents/link"
        link.symlink_to(outside)
        self.assertFalse(self.call("backupApp", bundleId="com.example.owned", name="symlink")["ok"])
        self.assertEqual(outside.read_text(), "outside unchanged")
        link.unlink()
        self.write_map(pid=123)
        self.assertFalse(self.call("backupApp", bundleId="com.example.owned", name="running")["ok"])
        self.write_map()
        self.assertFalse(self.call("appKill", bundleId="com.apple.springboard")["ok"])

    def test_execute_timeout_and_output_bound(self):
        self.assertEqual(self.call("execute", command="printf owned-shell")["value"]["output"], "owned-shell")
        timeout = self.call("execute", command="sleep 10", timeout=.1)
        self.assertTrue(timeout["value"]["timedOut"])
        self.assertFalse(self.call("execute", command="true", timeout=100)["ok"])
        overflow = self.call("execute", command="yes bounded-output", timeout=3)
        self.assertTrue(overflow["value"]["truncated"])
        self.assertLessEqual(len(overflow["value"]["output"]), 1048576)

    def test_quota_backup_root_and_recovery_journal(self):
        huge = self.app / "Documents/sparse"
        with huge.open("wb") as stream:
            stream.truncate(512 * 1024 * 1024 + 1)
        result = self.call("backupApp", bundleId="com.example.owned", name="over-limit")
        self.assertFalse(result["ok"], result)
        huge.unlink()
        target = self.root / "outside-backups"
        target.mkdir()
        backups = self.data / "backups"
        # A failed over-limit backup may leave its empty per-app directory.
        import shutil
        shutil.rmtree(backups)
        backups.symlink_to(target, target_is_directory=True)
        self.assertFalse(self.call("backupApp", bundleId="com.example.owned", name="escape")["ok"])
        self.assertEqual(list(target.iterdir()), [])
        backups.unlink()
        self.assertTrue(self.call("backupApp", bundleId="com.example.owned", name="normal")["ok"])
        (self.app / ".hphone-transaction.json").write_text('{"interrupted":true}')
        blocked = self.call("restoreApp", bundleId="com.example.owned", name="normal", confirmBundle="com.example.owned")
        self.assertFalse(blocked["ok"], blocked)
        self.assertEqual(blocked["code"], "recovery")
        self.assertEqual((self.app / "Documents/state.txt").read_text(), "owned test data")

    def test_cookie_domain_edit_and_recovery_preserves_other_sites(self):
        found = self.call("getCookies", domain="example.test")
        self.assertTrue(found["ok"], found)
        self.assertEqual(len(found["value"]), 1)
        self.assertTrue(found["value"][0]["httpOnly"])
        self.assertEqual(found["value"][0]["expiry"], 2000000000)
        self.assertEqual(self.call("getCookies", domain="ample.test")["value"], [])
        self.assertFalse(self.call("deleteCookies", domain="example.test")["ok"])
        cookie = {"domain":".example.test", "name":"owned", "value":"changed-fixture", "path":"/", "secure":True, "httpOnly":True, "expiry":2000000000}
        imported = self.call("importCookies", domain="example.test", confirmDomain="example.test", cookies=[cookie])
        self.assertTrue(imported["ok"], imported)
        self.assertEqual(imported["value"], 1)
        self.assertTrue(self.cookiefile.read_bytes().endswith(b"fixture-metadata"))
        self.assertEqual(self.call("getCookieHeader", domain="example.test")["value"], "owned=changed-fixture")
        self.assertEqual(self.call("deleteCookies", domain="other.test", confirmDomain="other.test")["value"], 1)
        self.assertTrue(self.call("restoreCookies", domain="other.test", confirmDomain="other.test")["ok"])
        self.assertEqual(self.call("getCookieHeader", domain="other.test")["value"], "keep=unrelated-fixture")
        self.assertEqual(self.call("getCookieHeader", domain="example.test")["value"], "owned=changed-fixture")
        self.assertIn("#HttpOnly_", self.call("getCookiesText", domain="example.test")["value"])
        self.assertEqual(self.cookiefile.stat().st_mode & 0o777, 0o600)

    def test_malformed_cookie_bounds_and_external_path_refused(self):
        baseline = self.cookie_fixture()
        for length in (0, 4, 7, 15, 20, 30, len(baseline)-30):
            self.cookiefile.write_bytes(baseline[:length])
            self.assertFalse(self.call("getCookies")["ok"])
        for field, value in ((4, 0xffffffff), (8, 0xffffffff), (16, 0xffffffff), (20, 0xffffffff)):
            broken = bytearray(baseline)
            struct.pack_into(">I" if field in (4, 8) else "<I", broken, field, value)
            self.cookiefile.write_bytes(broken)
            self.assertFalse(self.call("getCookies")["ok"])
        self.cookiefile.write_bytes(baseline)
        self.assertFalse(self.call("getCookies", file="/etc/passwd")["ok"])
        rejected = self.call("importCookies", domain="example.test", confirmDomain="example.test", cookies=[{"domain":"other.test","name":"x","value":"x"}])
        self.assertFalse(rejected["ok"])
        self.assertEqual(self.cookiefile.read_bytes(), baseline)

    def test_host_radio_proxy_are_explicitly_disabled(self):
        self.assertFalse(self.call("wifi", enabled=False)["ok"])
        self.assertFalse(self.call("airplaneMode", enabled=True)["ok"])
        self.assertFalse(self.call("setProxy", proxy="127.0.0.1:9999")["ok"])
        radios = self.call("getRadios")
        self.assertTrue(radios["ok"])
        self.assertIsNone(radios["value"]["wifi"])
        self.assertIsNone(radios["value"]["airplane"])


if __name__ == "__main__":
    unittest.main(argv=[sys.argv[0]], verbosity=2)
