"""Exercise the actual HTTP/Lua daemon compiled for macOS with unavailable native bridges."""
import http.client
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]

class DaemonTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.base = Path(cls.temp.name)
        env = dict(os.environ, HPHONE_TEST_DATA=str(cls.base), HPHONE_TEST_WEB=str(ROOT/"web"))
        cls.proc = subprocess.Popen([sys.argv[1]], env=env)
        for _ in range(100):
            path = cls.base/"token"
            if path.exists():
                cls.token = path.read_text()
                try:
                    if cls.request("GET", "/api/status")[0] == 200:
                        return
                except OSError:
                    pass
            if cls.proc.poll() is not None:
                raise RuntimeError("Daemon exited during startup")
            time.sleep(.05)
        raise RuntimeError("Daemon did not start")

    @classmethod
    def tearDownClass(cls):
        cls.proc.terminate()
        cls.proc.wait(timeout=5)
        cls.temp.cleanup()

    @classmethod
    def request(cls, method, path, body=None, auth=True):
        conn = http.client.HTTPConnection("127.0.0.1", 8765, timeout=5)
        headers = {"X-HPhone-Token": cls.token} if auth else {}
        if body is not None:
            headers["Content-Type"] = "application/json"
        conn.request(method, path, json.dumps(body) if body is not None else None, headers)
        response = conn.getresponse()
        data = response.read()
        status = response.status
        conn.close()
        return status, json.loads(data) if response.getheader("Content-Type", "").startswith("application/json") else data

    def call(self, path, body=None):
        status, data = self.request("POST" if body is not None else "GET", "/api/"+path, body)
        self.assertEqual(status, 200, data)
        return data

    def wait_script(self):
        for _ in range(100):
            if not self.call("status")["running"]:
                return
            time.sleep(.02)
        self.fail("Script did not stop")

    def test_auth_and_static(self):
        self.assertEqual(self.request("GET", "/api/status", auth=False)[0], 401)
        self.assertEqual(self.request("POST", "/api/stop", {}, auth=False)[0], 401)
        self.assertEqual(self.request("GET", "/api/run")[0], 404)
        self.assertIn(b"HPhone Touch", self.request("GET", "/", auth=False)[1])
        self.assertEqual(self.request("GET", "/../control", auth=False)[0], 404)
        self.assertEqual((self.base/"token").stat().st_mode & 0o777, 0o600)

    def test_script_roundtrip_and_paths(self):
        self.call("file", {"action":"save", "name":"test.lua", "content":"print('Tiếng Việt')"})
        self.assertIn("test.lua", self.call("files")["files"])
        self.assertEqual(self.call("file", {"action":"read", "name":"test.lua"})["content"], "print('Tiếng Việt')")
        for name in ("../escape.lua", "/tmp/escape.lua", ".hidden.lua", "bad.txt", "x\\bad.lua"):
            self.assertEqual(self.request("POST", "/api/file", {"action":"save", "name":name, "content":"bad"})[0], 400)
        outside = self.base/"outside"
        outside.write_text("unchanged")
        link = self.base/"scripts/link.lua"
        link.symlink_to(outside)
        self.assertEqual(self.request("POST", "/api/file", {"action":"save", "name":"link.lua", "content":"bad"})[0], 400)
        self.assertEqual(outside.read_text(), "unchanged")
        self.call("file", {"action":"delete", "name":"test.lua"})
        self.assertNotIn("test.lua", self.call("files")["files"])

    def test_lua_execution_stop_and_memory(self):
        self.call("file", {"action":"save", "name":"run.lua", "content":"print('lua-engine-ok', 2+3)"})
        self.call("run", {"name":"run.lua"})
        self.wait_script()
        self.assertTrue(any("lua-engine-ok\t5" in row["text"] for row in self.call("status")["logs"]))
        self.call("file", {"action":"save", "name":"run.lua", "content":"while true do end"})
        self.call("run", {"name":"run.lua"})
        self.assertEqual(self.request("POST", "/api/run", {"name":"run.lua"})[0], 409)
        self.call("stop", {})
        self.wait_script()
        self.call("file", {"action":"save", "name":"run.lua", "content":"local x=string.rep('a',40*1024*1024)"})
        self.call("run", {"name":"run.lua"})
        self.wait_script()
        self.assertTrue(any("memory" in row["text"] for row in self.call("status")["logs"]))

    def test_native_unavailable_is_explicit(self):
        self.assertEqual(self.request("GET", "/api/screen")[0], 503)
        self.assertEqual(self.request("POST", "/api/ocr", {})[0], 503)
        self.assertEqual(self.request("POST", "/api/tap", {"x":10,"y":10})[0], 503)

if __name__ == "__main__":
    unittest.main(argv=[sys.argv[0]], verbosity=2)
