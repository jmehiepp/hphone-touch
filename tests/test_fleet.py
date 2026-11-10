"""Fleet orchestration contract tests; do not require an iPhone or SSH credentials."""
import json
import hashlib
from pathlib import Path
import socket
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "pc"))
from fleet import DeviceSession, FleetController, FleetError, PinStore, authenticate, read_script, read_status, script_name


def udid(number):
    return f"{number:040x}"


class Tracker:
    def __init__(self):
        self.lock = threading.Lock()
        self.active = self.peak = 0
        self.by_device = {}
        self.device_peak = {}


class FakeSession:
    def __init__(self, number, tracker, fail=False):
        self.udid = udid(number)
        self.tracker = tracker
        self.fail = fail
        self.calls = []
        self.closed = False

    def close(self):
        self.closed = True

    def call(self, path, body=None):
        self.calls.append((path, body))
        with self.tracker.lock:
            self.tracker.active += 1
            self.tracker.peak = max(self.tracker.peak, self.tracker.active)
            self.tracker.by_device[self.udid] = self.tracker.by_device.get(self.udid, 0) + 1
            self.tracker.device_peak[self.udid] = max(self.tracker.device_peak.get(self.udid, 0), self.tracker.by_device[self.udid])
        try:
            time.sleep(.015)
            if self.fail:
                raise RuntimeError("password=private-secret token=private-token")
            return {"ok": True, "running": False, "jobs": [], "capabilities": {"version": "test", "token": "private-token"},
                    "token": "private-token", "logs": [{"text": "private-script-text"}]}
        finally:
            with self.tracker.lock:
                self.tracker.active -= 1
                self.tracker.by_device[self.udid] -= 1


class FleetTests(unittest.TestCase):
    def test_bounded_parallel_batch_and_partial_failure(self):
        controller = FleetController(workers=3)
        tracker = Tracker()
        for number in range(12):
            controller.attach(FakeSession(number, tracker, fail=number == 5))
        results = controller.batch([udid(n) for n in range(12)], "status")
        self.assertEqual(sum(row["ok"] for row in results), 11)
        self.assertLessEqual(tracker.peak, 3)
        self.assertGreater(tracker.peak, 1)
        report = json.dumps(controller.export())
        for secret in ("private-token", "private-secret", "private-script-text"):
            self.assertNotIn(secret, report)
            self.assertNotIn(secret, json.dumps(results))
        self.assertEqual(next(row for row in results if not row["ok"])["code"], "device_operation")
        controller.close()

    def test_upload_precedes_run_and_deduplicates(self):
        tracker = Tracker()
        controller = FleetController()
        session = FakeSession(1, tracker)
        controller.attach(session)
        results = controller.batch([session.udid, session.udid], "upload_run", name="task.lua", content="print('ok')")
        self.assertEqual(len(results), 1)
        self.assertEqual([call[0] for call in session.calls], ["file", "run", "summary"])
        self.assertEqual(session.calls[0][1]["content"], "print('ok')")

    def test_same_device_operations_are_serialized(self):
        controller = FleetController(workers=2)
        tracker = Tracker()
        controller.attach(FakeSession(1, tracker))
        threads = [threading.Thread(target=lambda: controller.batch([udid(1)], "status")) for _ in range(3)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join()
        self.assertEqual(tracker.device_peak[udid(1)], 1)

    def test_worker_limit_shared_by_concurrent_batches(self):
        controller = FleetController(workers=4)
        tracker = Tracker()
        for number in range(16):
            controller.attach(FakeSession(number, tracker))
        threads = [threading.Thread(target=lambda start=start: controller.batch([udid(n) for n in range(start, start+8)], "status")) for start in (0, 8)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join()
        self.assertLessEqual(tracker.peak, 4)
        self.assertGreater(tracker.peak, 1)

    def test_disconnect_and_reconnect_clear_old_session(self):
        controller = FleetController()
        tracker = Tracker()
        first, second = FakeSession(1, tracker), FakeSession(1, tracker)
        controller.attach(first)
        controller.attach(second)
        self.assertTrue(first.closed)
        self.assertFalse(second.closed)
        controller.detach(udid(1))
        self.assertTrue(second.closed)
        self.assertFalse(controller.batch([udid(1)], "status")[0]["ok"])
        controller.close()
        late = FakeSession(2, tracker)
        with self.assertRaises(FleetError):
            controller.attach(late)
        self.assertTrue(late.closed)

    def test_script_names_and_utf8(self):
        for name in ("../bad.lua", "/bad.lua", ".hidden.lua", "bad.txt", "x\\bad.lua"):
            with self.assertRaises(FleetError):
                script_name(name)
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "task.lua"
            path.write_bytes(b"\xef\xbb\xbfprint('ok')")
            self.assertEqual(read_script(path), ("task.lua", "print('ok')"))
            path.write_bytes(b"\xff")
            with self.assertRaises(FleetError):
                read_script(path)

    def test_summary_falls_back_only_for_older_endpoint_not_other_errors(self):
        calls = []
        def call(path):
            calls.append(path)
            if path == "summary":
                raise FleetError("http_404", "old endpoint")
            return {"running": False}
        self.assertFalse(read_status(SimpleNamespace(call=call))["running"])
        self.assertEqual(calls, ["summary", "status"])
        calls.clear()
        def unauthorized(path):
            calls.append(path)
            raise FleetError("token_expired", "token expired")
        with self.assertRaises(FleetError):
            read_status(SimpleNamespace(call=unauthorized))
        self.assertEqual(calls, ["summary"])

    def test_host_key_change_is_not_silently_accepted(self):
        with tempfile.TemporaryDirectory() as temp:
            pins = PinStore(temp)
            pins.remember(udid(1), "a" * 64)
            pins.check(udid(1), "a" * 64)
            with self.assertRaises(FleetError):
                pins.check(udid(1), "b" * 64)
            self.assertEqual(json.loads(next(Path(temp).glob("*.json")).read_text())["sha256"], "a" * 64)

    def test_wrong_host_key_blocks_password_authentication(self):
        attempts = []
        closed = []
        class FakeTransport:
            def __init__(self, sock):
                pass
            def start_client(self, timeout):
                pass
            def get_remote_server_key(self):
                return SimpleNamespace(asbytes=lambda: b"changed-public-key")
            def auth_password(self, username, password):
                attempts.append(True)
            def close(self):
                closed.append(True)
        sock = SimpleNamespace(setblocking=lambda _: None, settimeout=lambda _: None)
        fake_paramiko = SimpleNamespace(Transport=FakeTransport, AuthenticationException=type("AuthenticationException", (Exception,), {}))
        with tempfile.TemporaryDirectory() as temp:
            pins = PinStore(temp)
            original = hashlib.sha256(b"original-public-key").hexdigest()
            pins.remember(udid(1), original)
            with patch.dict(sys.modules, {"paramiko": fake_paramiko}):
                with self.assertRaises(FleetError) as error:
                    authenticate(udid(1), "mobile", "never-send-this-password", pins, connector=lambda *_: sock)
            self.assertEqual(error.exception.code, "host_key_changed")
            self.assertEqual(attempts, [])
            self.assertEqual(closed, [True])
            self.assertEqual(json.loads(next(Path(temp).glob("*.json")).read_text())["sha256"], original)

    def test_expired_token_detaches_fleet_session(self):
        tracker = Tracker()
        controller = FleetController()
        session = FakeSession(1, tracker)
        session.call = lambda *_: (_ for _ in ()).throw(FleetError("token_expired", "Token đã đổi; kết nối lại bằng SSH"))
        controller.attach(session)
        self.assertFalse(controller.batch([udid(1)], "status")[0]["ok"])
        self.assertTrue(session.closed)
        self.assertNotIn(udid(1), controller.sessions)
        self.assertEqual(controller.batch([udid(1)], "status")[0]["code"], "not_connected")

    def test_usb_http_token_header_and_expired_token(self):
        received = []
        statuses = iter((200, 401))
        def connect(device, port):
            self.assertEqual(device, udid(9))
            self.assertEqual(port, 19090)
            client, server = socket.socketpair()
            def respond():
                with server:
                    data = bytearray()
                    while b"\r\n\r\n" not in data:
                        data.extend(server.recv(8192))
                    received.append(bytes(data))
                    status = next(statuses)
                    body = b'{"running":false}'
                    server.sendall(f"HTTP/1.1 {status} Result\r\nContent-Type: application/json\r\nContent-Length: {len(body)}\r\nConnection: close\r\n\r\n".encode() + body)
            threading.Thread(target=respond, daemon=True).start()
            return client
        token = "a" * 32
        session = DeviceSession(udid(9), token, 19090, connect)
        self.assertFalse(session.call("status")["running"])
        self.assertIn(("X-HPhone-Token: " + token).encode(), received[0])
        self.assertNotIn(token.encode(), received[0].split(b"\r\n")[0])
        with self.assertRaises(FleetError) as error:
            session.call("status")
        self.assertEqual(error.exception.code, "token_expired")
        self.assertEqual(session._token, "")
        self.assertNotIn(token, repr(session))


if __name__ == "__main__":
    unittest.main(verbosity=2)
