"""USB-only HPhone Touch fleet controller. No device credentials are written to disk."""
from __future__ import annotations

import asyncio
from concurrent.futures import ThreadPoolExecutor, as_completed
import hashlib
import http.client
import json
from pathlib import Path
import re
import threading
import time

MAX_SCRIPT_BYTES = 700 * 1024
MAX_RESPONSE_BYTES = 2 * 1024 * 1024
DATA_ROOT = "/rootfs/var/mobile/Library/HPhoneTouch"


class FleetError(Exception):
    """Only prewritten, non-secret messages may cross the GUI/export boundary."""

    def __init__(self, code, message):
        super().__init__(message)
        self.code = code
        self.safe_message = message


def validate_udid(value):
    if not isinstance(value, str) or not re.fullmatch(r"[A-Fa-f0-9-]{24,41}", value):
        raise FleetError("invalid_device", "Mã thiết bị không hợp lệ")
    return value


def script_name(value):
    if not isinstance(value, str) or not re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9_. -]{0,75}\.lua", value):
        raise FleetError("invalid_script", "Tên script .lua không hợp lệ (tối đa 80 ký tự)")
    return value


def read_script(path):
    file = Path(path)
    script_name(file.name)
    if file.stat().st_size > MAX_SCRIPT_BYTES:
        raise FleetError("script_size", "Script vượt 700 KiB")
    try:
        content = file.read_text(encoding="utf-8-sig")
    except UnicodeError:
        raise FleetError("script_encoding", "Script phải là UTF-8") from None
    return file.name, content


async def _usb_socket(udid, port):
    from pymobiledevice3.usbmux import list_devices

    devices = [d for d in await list_devices() if d.is_usb and d.matches_udid(udid)]
    if len(devices) != 1:
        raise FleetError("usb_missing", "Không tìm thấy đúng iPhone qua USB")
    return await asyncio.wait_for(devices[0].connect(port), 6)


def usb_socket(udid, port):
    return asyncio.run(_usb_socket(udid, port))


async def _discover():
    from pymobiledevice3.lockdown import create_using_usbmux
    from pymobiledevice3.usbmux import list_devices

    devices = [d for d in await list_devices() if d.is_usb]

    async def describe(device):
        row = {"udid": device.serial, "name": "iPhone", "model": "", "ios": "", "paired": False}
        try:
            async with await create_using_usbmux(serial=device.serial, connection_type="USB", pair_timeout=3) as client:
                values = client.all_values
                row.update(name=values.get("DeviceName", "iPhone"), model=values.get("ProductType", ""),
                           ios=values.get("ProductVersion", ""), paired=True)
        except Exception:
            row["issue"] = "Mở khóa iPhone và bấm Tin cậy máy tính"
        return row

    return await asyncio.gather(*(describe(device) for device in devices))


def discover():
    return asyncio.run(_discover())


class PinStore:
    """Stores SSH public-key fingerprints only, separate from session secrets."""

    def __init__(self, folder):
        self.folder = Path(folder)
        self.lock = threading.Lock()

    def check(self, udid, fingerprint):
        path = self.folder / (validate_udid(udid) + ".json")
        with self.lock:
            if path.exists():
                try:
                    previous = json.loads(path.read_text(encoding="utf-8"))["sha256"]
                except (ValueError, KeyError, OSError):
                    raise FleetError("host_key_file", "Không đọc được khóa SSH đã ghi nhận") from None
                if previous != fingerprint:
                    raise FleetError("host_key_changed", "Khóa SSH đã đổi; dừng kết nối và kiểm tra đúng máy")

    def remember(self, udid, fingerprint):
        self.check(udid, fingerprint)
        with self.lock:
            self.folder.mkdir(parents=True, exist_ok=True)
            path = self.folder / (validate_udid(udid) + ".json")
            temporary = path.with_suffix(".tmp")
            temporary.write_text(json.dumps({"sha256": fingerprint, "transport": "USB"}), encoding="utf-8")
            temporary.replace(path)


class DeviceSession:
    def __init__(self, udid, token, port, connector=usb_socket):
        self.udid = validate_udid(udid)
        if not re.fullmatch(r"[0-9A-Fa-f]{32}", token):
            raise FleetError("invalid_token", "Token HPhone Touch không hợp lệ")
        if not 1024 <= int(port) <= 65535:
            raise FleetError("invalid_port", "Cổng HPhone Touch không hợp lệ")
        self._token = token
        self.port = int(port)
        self._connector = connector
        self.lock = threading.RLock()

    def close(self):
        with self.lock:
            self._token = ""

    def call(self, path, body=None):
        if not self._token:
            raise FleetError("session_closed", "Cần kết nối lại thiết bị")
        if not re.fullmatch(r"[a-z]+", path):
            raise FleetError("invalid_api", "API không hợp lệ")
        encoded = json.dumps(body, ensure_ascii=False).encode("utf-8") if body is not None else None
        if encoded is not None and len(encoded) > 1048576:
            raise FleetError("request_size", "Yêu cầu vượt 1 MiB")
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=20)
        try:
            conn.sock = self._connector(self.udid, self.port)
            conn.sock.setblocking(True)
            conn.sock.settimeout(20)
            headers = {"X-HPhone-Token": self._token}
            if encoded is not None:
                headers["Content-Type"] = "application/json"
            conn.request("POST" if body is not None else "GET", "/api/" + path, encoded, headers)
            response = conn.getresponse()
            data = response.read(MAX_RESPONSE_BYTES + 1)
            if len(data) > MAX_RESPONSE_BYTES:
                raise FleetError("response_size", "Phản hồi thiết bị quá lớn")
            if response.status == 401:
                self.close()
                raise FleetError("token_expired", "Token đã đổi; kết nối lại bằng SSH")
            if response.status == 409:
                raise FleetError("device_busy", "Thiết bị đang bận hoặc script đã chạy")
            if response.status != 200:
                raise FleetError("http_" + str(response.status), "API thiết bị trả HTTP " + str(response.status))
            value = json.loads(data)
            if not isinstance(value, dict):
                raise FleetError("invalid_response", "Phản hồi API không hợp lệ")
            if value.get("error") or value.get("ok") is False:
                raise FleetError("api_failed", "Thiết bị từ chối thao tác; xem log trên iPhone")
            return value
        except FleetError:
            raise
        except (OSError, ValueError, http.client.HTTPException):
            raise FleetError("usb_request", "Mất kết nối USB hoặc daemon chưa sẵn sàng") from None
        finally:
            conn.close()


def authenticate(udid, username, password, pins, connector=usb_socket):
    """Password lives only in this call; the resulting session stores only its API token."""
    import paramiko

    validate_udid(udid)
    if username not in ("mobile", "root") or not isinstance(password, str) or not password:
        raise FleetError("credentials", "Chọn tài khoản và nhập mật khẩu SSH của máy này")
    transport = None
    client = None
    try:
        sock = connector(udid, 22)
        sock.setblocking(True)
        sock.settimeout(12)
        transport = paramiko.Transport(sock)
        transport.start_client(timeout=12)
        fingerprint = hashlib.sha256(transport.get_remote_server_key().asbytes()).hexdigest()
        pins.check(udid, fingerprint)
        transport.auth_password(username, password)
        if not transport.is_authenticated():
            raise FleetError("ssh_auth", "SSH không xác thực được; kiểm tra tài khoản và mật khẩu")
        channel = transport.open_session(timeout=10)
        channel.settimeout(10)
        try:
            channel.exec_command("dpkg --print-architecture")
            architecture = bytearray()
            while len(architecture) < 128:
                chunk = channel.recv(128)
                if not chunk:
                    break
                architecture.extend(chunk)
            if architecture.decode("ascii", errors="replace").strip() != "iphoneos-arm64e":
                raise FleetError("bootstrap", "Máy chưa có môi trường Dopamine RootHide phù hợp")
        finally:
            channel.close()
        client = paramiko.SFTPClient.from_transport(transport)
        token = port = None
        for folder in (DATA_ROOT, "/var/mobile/Library/HPhoneTouch"):
            try:
                with client.open(folder + "/token", "rb") as stream:
                    token = stream.read(129).decode("ascii").strip()
                with client.open(folder + "/port", "rb") as stream:
                    port = int(stream.read(16).decode("ascii").strip())
                break
            except (OSError, ValueError):
                continue
        if token is None or port is None:
            raise FleetError("package_missing", "Không đọc được token/cổng; cài và mở HPhone Touch trên iPhone")
        session = DeviceSession(udid, token, port, connector)
        read_status(session)
        pins.remember(udid, fingerprint)
        return session
    except FleetError:
        raise
    except paramiko.AuthenticationException:
        raise FleetError("ssh_auth", "SSH không xác thực được; kiểm tra tài khoản và mật khẩu") from None
    except Exception:
        raise FleetError("ssh_connection", "Không kết nối được SSH qua USB; kiểm tra OpenSSH, cáp và máy đã mở khóa") from None
    finally:
        password = ""
        if client is not None:
            client.close()
        if transport is not None:
            transport.close()


def read_status(session):
    try:
        return session.call("summary")
    except FleetError as error:
        if error.code != "http_404":
            raise
        # Compatibility with installed 0.1 versions; 0.2 avoids copying full logs.
        return session.call("status")


def status_summary(value):
    caps = value.get("capabilities", {})
    return {"running": bool(value.get("running")), "jobs": len(value.get("jobs", [])),
            "version": str(caps.get("version", value.get("version", "")))[:32] if isinstance(caps, dict) else ""}


class FleetController:
    def __init__(self, workers=4):
        if not 1 <= workers <= 8:
            raise ValueError("workers must be 1..8")
        self.workers = workers
        self.worker_gate = threading.BoundedSemaphore(workers)
        self.sessions = {}
        self.records = {}
        self.lock = threading.RLock()
        self.operation_locks = {}
        self.closed = False

    def update_devices(self, devices):
        with self.lock:
            present = {row["udid"] for row in devices}
            for row in devices:
                udid = validate_udid(row["udid"])
                record = self.records.setdefault(udid, {"udid": udid, "state": "chưa kết nối"})
                for key in ("name", "model", "ios", "paired"):
                    if key in row:
                        record[key] = row[key]
                record["usb"] = True
            for udid, record in self.records.items():
                if udid not in present:
                    record["usb"] = False
                    record["state"] = "đã rút USB"

    def attach(self, session):
        with self.lock:
            if self.closed:
                session.close()
                raise FleetError("controller_closed", "Cửa sổ điều phối đã đóng")
            previous = self.sessions.get(session.udid)
            if previous is not None:
                previous.close()
            self.sessions[session.udid] = session
            self.operation_locks.setdefault(session.udid, threading.Lock())
            self.records.setdefault(session.udid, {"udid": session.udid}).update(state="đã kết nối", error="", usb=True)

    def detach(self, udid):
        with self.lock:
            session = self.sessions.pop(udid, None)
            if session is not None:
                session.close()
            self.records.setdefault(udid, {"udid": udid}).update(state="đã ngắt kết nối", running=False)

    def _perform(self, udid, action, name=None, content=None):
        with self.lock:
            session = self.sessions.get(udid)
            operation_lock = self.operation_locks.setdefault(udid, threading.Lock())
        if session is None:
            raise FleetError("not_connected", "Cần kết nối SSH cho thiết bị này trước")
        with operation_lock, self.worker_gate:
            if action in ("upload", "upload_run"):
                script_name(name)
                if not isinstance(content, str) or len(content.encode("utf-8")) > MAX_SCRIPT_BYTES:
                    raise FleetError("script_size", "Script không hợp lệ hoặc vượt 700 KiB")
                session.call("file", {"action": "save", "name": name, "content": content})
            if action in ("run", "upload_run"):
                session.call("run", {"name": script_name(name)})
            elif action == "stop":
                session.call("stop", {})
            elif action not in ("status", "upload"):
                raise FleetError("invalid_action", "Thao tác không hợp lệ")
            summary = status_summary(read_status(session))
            with self.lock:
                self.records.setdefault(udid, {"udid": udid}).update(**summary, state="đang chạy" if summary["running"] else "sẵn sàng",
                    error="", last_action=action, checked_at=time.strftime("%Y-%m-%dT%H:%M:%S%z"))
            return {"udid": udid, "ok": True, **summary}

    def batch(self, udids, action, name=None, content=None, progress=None):
        """Each device reports independently; a failing device cannot abort the other devices."""
        selected = list(dict.fromkeys(validate_udid(udid) for udid in udids))
        results = []
        with ThreadPoolExecutor(max_workers=self.workers, thread_name_prefix="hphone-usb") as executor:
            tasks = {executor.submit(self._perform, udid, action, name, content): udid for udid in selected}
            for future in as_completed(tasks):
                udid = tasks[future]
                try:
                    result = future.result()
                except Exception as error:
                    code = error.code if isinstance(error, FleetError) else "device_operation"
                    message = error.safe_message if isinstance(error, FleetError) else "Thao tác thất bại; kiểm tra thiết bị và kết nối lại"
                    result = {"udid": udid, "ok": False, "code": code, "message": message}
                    if code in ("token_expired", "session_closed"):
                        self.detach(udid)
                    with self.lock:
                        self.records.setdefault(udid, {"udid": udid}).update(state="lỗi", error=message, last_action=action)
                results.append(result)
                if progress is not None:
                    progress(result)
        return results

    def export(self):
        keys = ("udid", "name", "model", "ios", "paired", "usb", "state", "running", "jobs", "version", "last_action", "checked_at", "error")
        with self.lock:
            return [{key: row[key] for key in keys if key in row} for _, row in sorted(self.records.items())]

    def close(self):
        with self.lock:
            self.closed = True
            for session in self.sessions.values():
                session.close()
            self.sessions.clear()
