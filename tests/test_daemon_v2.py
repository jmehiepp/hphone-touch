"""Exercise the real Server/Runtime/Lua engine on macOS, without device frameworks.

Usage: python3 tests/test_daemon_v2.py /path/to/hphone-host-test
Only Bridge.m is replaced with an explicit-unavailable stub; all storage,
scheduling, HTTP client, Lua and service dispatch code is the production code.
"""
import base64
import contextlib
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
EXECUTABLE = None


class DaemonV2Tests(unittest.TestCase):
    def setUp(self):
        if EXECUTABLE is None:
            self.skipTest("Pass the compiled macOS host daemon as the script argument")
        self.temp = tempfile.TemporaryDirectory()
        self.base = Path(self.temp.name)
        self.addCleanup(self.temp.cleanup)
        self.apps = self.base / "apps.plist"
        self.apps.write_bytes(plistlib.dumps({}))
        (self.base / "containers").mkdir()
        self.env = dict(os.environ, HPHONE_TEST_DATA=str(self.base), HPHONE_TEST_WEB=str(ROOT / "web"),
                        HPHONE_TEST_APPS=str(self.apps), HPHONE_TEST_CONTAINERS=str(self.base / "containers"))
        self.proc = None
        self.addCleanup(self.stop_daemon)
        self.start_daemon()

    def start_daemon(self):
        self.proc = subprocess.Popen([EXECUTABLE], env=self.env)
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            if self.proc.poll() is not None:
                self.fail(f"Daemon exited during startup ({self.proc.returncode})")
            try:
                self.token = (self.base / "token").read_text()
                self.port = int((self.base / "port").read_text())
                if self.request("GET", "status")[0] == 200:
                    return
            except (OSError, ValueError, http.client.HTTPException):
                pass
            time.sleep(.025)
        self.fail("Daemon did not become ready")

    def stop_daemon(self):
        if self.proc is not None and self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=4)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait(timeout=4)

    def request(self, method, path, body=None, auth=True):
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=4)
        headers = {"X-HPhone-Token": self.token} if auth else {}
        data = None
        if body is not None:
            data = json.dumps(body, ensure_ascii=False).encode("utf-8")
            headers["Content-Type"] = "application/json"
        try:
            connection.request(method, "/api/" + path, data, headers)
            response = connection.getresponse()
            data = response.read()
            status = response.status
            content_type = response.getheader("Content-Type", "")
            return status, json.loads(data) if "application/json" in content_type else data
        finally:
            connection.close()

    def call(self, path, body=None):
        status, data = self.request("POST" if body is not None else "GET", path, body)
        self.assertEqual(status, 200, data)
        return data

    def save(self, name, content):
        return self.call("file", {"action": "save", "name": name, "content": content})

    def run_lua(self, content, name="test.lua"):
        self.save(name, content)
        result = self.call("run", {"name": name})
        self.assertTrue(result["ok"])
        return result["id"]

    def until(self, condition, timeout=4):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            result = condition()
            if result:
                return result
            if self.proc.poll() is not None:
                self.fail(f"Daemon unexpectedly exited ({self.proc.returncode})")
            time.sleep(.025)
        self.fail("Condition was not satisfied before timeout")

    def wait_job(self, identifier, timeout=4):
        self.until(lambda: all(job["id"] != identifier for job in self.call("jobs")["jobs"]), timeout)

    def logs_for(self, identifier):
        return [row["text"] for row in self.call("status")["logs"] if row.get("script") == identifier]

    def assert_script_ok(self, identifier, marker, timeout=4):
        self.wait_job(identifier, timeout)
        logs = self.logs_for(identifier)
        self.assertTrue(any(marker in line for line in logs), logs)
        self.assertFalse(any(line.startswith("Error:") for line in logs), logs)

    def test_auth_summary_and_explicit_unavailable_bridges(self):
        for path in ("status", "summary", "jobs", "schedules", "ui", "docs", "screen"):
            self.assertEqual(self.request("GET", path, auth=False)[0], 401, path)
        self.assertEqual(self.request("POST", "stop", {}, auth=False)[0], 401)
        self.assertEqual((self.base / "token").stat().st_mode & 0o777, 0o600)
        self.assertEqual((self.base / "port").stat().st_mode & 0o777, 0o600)
        summary = self.call("summary")
        self.assertIn("running", summary)
        self.assertIn("jobs", summary)
        self.assertNotIn("logs", summary)
        self.assertNotIn("token", summary)
        self.assertEqual(self.request("GET", "run")[0], 404)
        self.assertEqual(self.request("GET", "screen")[0], 503)
        self.assertEqual(self.request("POST", "ocr", {})[0], 503)
        for path in ("input", "visual"):
            status, result = self.request("POST", path, {"operation": "unavailable", "args": {}})
            self.assertGreaterEqual(status, 400)
            self.assertIn("unavailable", result["error"].lower())

    def test_binary_files_subdirectories_and_symlink_ancestors(self):
        payload = bytes(range(256)) * 4
        self.call("fs", {"action": "write", "path": "picture/deep/sample.bin", "base64": base64.b64encode(payload).decode()})
        result = self.call("fs", {"action": "read", "path": "picture/deep/sample.bin"})
        self.assertEqual(base64.b64decode(result["base64"]), payload)
        self.assertEqual(result["size"], len(payload))
        self.assertTrue(any(row["name"] == "sample.bin" for row in self.call("fs", {"action": "list", "path": "picture/deep"})["entries"]))
        self.call("fs", {"action": "delete", "path": "picture/deep/sample.bin"})
        self.assertFalse(self.call("fs", {"action": "exists", "path": "picture/deep/sample.bin"})["exists"])
        outside = self.base / "outside"
        outside.mkdir()
        target = outside / "unchanged.bin"
        target.write_bytes(b"owned fixture")
        scripts = self.base / "scripts"
        (scripts / "final-link.bin").symlink_to(target)
        (scripts / "ancestor-link").symlink_to(outside, target_is_directory=True)
        (scripts / "real-parent").mkdir()
        (scripts / "real-parent/nested-link").symlink_to(outside, target_is_directory=True)
        for path in ("../outside/unchanged.bin", str(target), ".hidden.bin", "final-link.bin",
                     "ancestor-link/unchanged.bin", "real-parent/nested-link/unchanged.bin", "bad\\name.bin", "bad\0name.bin"):
            with self.subTest(path=path):
                status, _ = self.request("POST", "fs", {"action": "write", "path": path, "content": "must not write"})
                self.assertGreaterEqual(status, 400)
                self.assertEqual(target.read_bytes(), b"owned fixture")

    def test_append_read_failure_preserves_existing_data_and_empty_first_line(self):
        path = self.base / "scripts/oversize.txt"
        payload = b"a" * (16 * 1024 * 1024 + 1)
        path.write_bytes(payload)
        status, _ = self.request("POST", "fs", {"action": "append", "path": path.name, "content": "tail"})
        self.assertGreaterEqual(status, 400)
        self.assertEqual(path.stat().st_size, len(payload))
        self.assertEqual(path.read_bytes(), payload)
        self.call("fs", {"action": "write", "path": "lines.txt", "content": "\nsecond\n"})
        self.assertEqual(self.call("fs", {"action": "removeFirstLine", "path": "lines.txt"})["line"], "")
        self.assertEqual(self.call("fs", {"action": "read", "path": "lines.txt"})["content"], "second\n")

    def test_nested_json_is_bounded_without_crashing_daemon(self):
        identifier = self.run_lua("""
local normal = string.rep('[', 12)..'7'..string.rep(']', 12)
local value, err = jsonDecode(normal)
assert(value and not err)
assert(type(jsonEncode(value)) == 'string')
local leaf=value; for i=1,12 do leaf=leaf[1] end; assert(leaf==7)
local binaryKey='a'..string.char(0)..'b'
local escaped=jsonEncode({[binaryKey]='owned'})
local restored=jsonDecode(escaped)
assert(restored[binaryKey]=='owned' and restored.a==nil)
local deep = string.rep('[', 64)..'7'..string.rep(']', 64)
local rejected, why = jsonDecode(deep)
assert(rejected == nil and type(why) == 'string' and #why > 0)
local tree = {}; local cursor = tree
for i=1,64 do cursor.child={}; cursor=cursor.child end
local encoded, reason = jsonEncode(tree)
assert(encoded == nil and type(reason) == 'string' and #reason > 0)
print('json-depth-guard-ok')
""")
        self.assert_script_ok(identifier, "json-depth-guard-ok")
        self.assertEqual(self.call("summary")["running"], False)

    def test_four_parallel_jobs_stop_one_and_limit(self):
        identifiers = []
        for number in range(4):
            identifiers.append(self.run_lua("while true do sleep(.05) end", f"job-{number}.lua"))
        self.assertEqual(len(self.call("jobs")["jobs"]), 4)
        self.assertEqual(self.request("POST", "run", {"name": "job-0.lua"})[0], 409)
        self.assertEqual(self.call("stop", {"id": identifiers[1]})["count"], 1)
        self.wait_job(identifiers[1])
        self.assertEqual({job["id"] for job in self.call("jobs")["jobs"]}, set(identifiers) - {identifiers[1]})
        self.assertEqual(self.call("stop", {})["count"], 3)
        self.until(lambda: not self.call("jobs")["jobs"])
        self.assert_script_ok(self.run_lua("print('new-job-after-stop')"), "new-job-after-stop")

    def test_timer_persists_restart_and_deleted_script_can_be_unscheduled(self):
        self.save("timer.lua", "print('persisted-timer-fired')")
        fire = time.time() + 3
        self.call("schedule", {"action": "set", "name": "timer.lua", "fireTime": fire, "repeat": False, "interval": 0})
        self.assertEqual(len(self.call("schedules")["schedules"]), 1)
        self.assertEqual((self.base / "schedule.json").stat().st_mode & 0o777, 0o600)
        self.stop_daemon()
        self.start_daemon()
        queued = self.call("schedules")["schedules"]
        already_fired = any("persisted-timer-fired" in row["text"] for row in self.call("status")["logs"])
        self.assertTrue(any(timer["name"] == "timer.lua" for timer in queued) or already_fired)
        self.until(lambda: any("persisted-timer-fired" in row["text"] for row in self.call("status")["logs"]), timeout=6)
        self.assertEqual(self.call("schedules")["schedules"], [])
        self.call("schedule", {"action": "set", "name": "timer.lua", "fireTime": time.time()+60, "repeat": False, "interval": 0})
        self.call("schedule", {"action": "auto", "name": "timer.lua", "enabled": True})
        self.call("file", {"action": "delete", "name": "timer.lua"})
        self.call("schedule", {"action": "remove", "name": "timer.lua"})
        self.call("schedule", {"action": "auto", "name": "timer.lua", "enabled": False})
        self.assertEqual(self.call("schedules")["schedules"], [])
        self.assertEqual(self.call("schedule", {"action": "listAuto"})["paths"], [])

    def test_ui_toast_after_script_exit_and_dialog_response(self):
        self.call("ui", {"action": "heartbeat", "surface": "app"})
        identifier = self.run_lua("toast('toast-after-exit', 10); alert('alert-after-exit', 'owned fixture')")
        self.wait_job(identifier)
        events = self.call("ui")["events"]
        self.assertEqual({event["type"] for event in events}, {"toast", "alert"})
        self.assertTrue(all(event.get("target") == "app" for event in events))
        for event in events:
            self.call("ui", {"action": "respond", "id": event["id"], "button": 1})
        identifier = self.run_lua("""
local controls = {
 {type=CONTROLLER_TYPE.INPUT, key='name', value='before'},
 {type=CONTROLLER_TYPE.SWITCH, key='enabled', value=false},
 {type=CONTROLLER_TYPE.PICKER, options={'first','second'}, value=1},
 {type=CONTROLLER_TYPE.BUTTON, title='OK'}
}
local selected = dialog(controls)
assert(selected == 1 and controls[1].value == 'after' and controls[2].value == true and controls[3].value == 2)
print('dialog-response-ok')
""")
        event = self.until(lambda: next((event for event in self.call("ui")["events"] if event["type"] == "dialog"), None))
        self.assertIn(identifier, {job["id"] for job in self.call("jobs")["jobs"]})
        controls = event["controls"]
        controls[0]["value"], controls[1]["value"], controls[2]["value"] = "after", True, 2
        self.call("ui", {"action": "respond", "id": event["id"], "button": 1, "controls": controls})
        self.assert_script_ok(identifier, "dialog-response-ok")
        self.assertEqual(self.call("ui")["events"], [])

    @contextlib.contextmanager
    def http_fixture(self):
        ready, release = threading.Event(), threading.Event()
        payload = b"\x00\xffowned\x80"
        posts = []
        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass
            def do_GET(self):
                if self.path == "/slow":
                    self.send_response(200)
                    self.send_header("Content-Length", "1000000")
                    self.end_headers()
                    try:
                        self.wfile.write(b"prefix")
                        self.wfile.flush()
                        ready.set()
                        release.wait(timeout=8)
                    except OSError:
                        pass
                else:
                    self.send_response(200)
                    self.send_header("Content-Length", str(len(payload)))
                    self.end_headers()
                    self.wfile.write(payload)
            def do_POST(self):
                posts.append((self.headers.get("Content-Type"), self.rfile.read(int(self.headers.get("Content-Length", 0)))))
                self.send_response(200)
                self.send_header("Content-Length", "2")
                self.end_headers()
                self.wfile.write(b"ok")
        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        server.daemon_threads = True
        thread = threading.Thread(target=lambda: server.serve_forever(poll_interval=.05), daemon=True)
        thread.start()
        try:
            yield f"http://127.0.0.1:{server.server_port}", ready, posts
        finally:
            release.set()
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)

    def test_http_binary_json_and_stop_interrupts_inflight_response(self):
        with self.http_fixture() as (url, ready, posts):
            identifier = self.run_lua(f"""
local reply=httpGet({json.dumps(url+'/binary')})
assert(reply.ok and reply.status == 200)
assert(reply.body == string.char(0,255)..'owned'..string.char(128))
local posted=httpPost({json.dumps(url+'/json')}, {{owned='fixture'}})
assert(posted.ok and posted.body == 'ok')
print('http-fixture-ok')
""")
            self.assert_script_ok(identifier, "http-fixture-ok")
            self.assertEqual(json.loads(posts[0][1]), {"owned": "fixture"})
            self.assertTrue(posts[0][0].startswith("application/json"))
            identifier = self.run_lua(f"local result=httpGet({json.dumps(url+'/slow')}, {{timeout=30}}); print('after-http', result.ok)")
            self.assertTrue(ready.wait(timeout=3), "HTTP request did not reach local fixture")
            started = time.monotonic()
            self.call("stop", {"id": identifier})
            self.wait_job(identifier, timeout=3)
            self.assertLess(time.monotonic()-started, 3)
            self.assertFalse(self.call("summary")["running"])


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("Usage: python3 tests/test_daemon_v2.py /path/to/hphone-host-test")
    EXECUTABLE = str(Path(sys.argv[1]).resolve())
    unittest.main(argv=[sys.argv[0]], verbosity=2)
