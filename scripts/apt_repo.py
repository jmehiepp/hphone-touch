"""Validate native .debs and generate a flat APT repository for Sileo."""
from __future__ import annotations
import argparse
import email.utils
import gzip
import hashlib
import io
from pathlib import Path
import plistlib
import shutil
import struct
import tarfile

PACKAGE = "io.github.jmehiepp.hphone-touch"

def ar_members(data):
    if data[:8] != b"!<arch>\n":
        raise ValueError("Not a Debian ar archive")
    pos = 8
    while pos < len(data):
        header = data[pos:pos+60]
        if len(header) != 60 or header[58:60] != b"`\n":
            raise ValueError("Invalid ar header")
        name = header[:16].decode().strip().rstrip("/")
        size = int(header[48:58])
        if size < 0 or pos+60+size > len(data):
            raise ValueError("Truncated ar member")
        yield name, data[pos+60:pos+60+size]
        pos += 60 + size + size % 2

def tar_files(data):
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:*") as archive:
        result = {}
        for member in archive.getmembers():
            name = member.name.removeprefix("./").lstrip("/")
            if ".." in Path(name).parts:
                raise ValueError("Unsafe archive path")
            if member.isfile():
                result[name] = archive.extractfile(member).read()
        return result

def fields(text):
    result = {}
    key = None
    for line in text.splitlines():
        if line.startswith((" ", "\t")) and key:
            result[key] += "\n" + line
        elif line:
            key, value = line.split(":", 1)
            if key in result:
                raise ValueError("Duplicate control field")
            result[key] = value.strip()
    return result

def verify_macho(binary):
    if len(binary) < 32 or binary[:4] != b"\xcf\xfa\xed\xfe":
        raise ValueError("Expected a thin 64-bit Mach-O")
    _, cpu, subtype, kind, count, size, flags, reserved = struct.unpack_from("<8I", binary)
    if cpu != 0x0100000C or subtype & 0xFFFFFF != 0:
        raise ValueError("Expected ARM64 ALL, compatible with iPhone 6s")
    pos = 32
    minimum = None
    for _ in range(count):
        cmd, length = struct.unpack_from("<II", binary, pos)
        if length < 8 or pos+length > len(binary):
            raise ValueError("Invalid Mach-O command")
        if cmd == 0x32:
            platform, minimum, sdk = struct.unpack_from("<III", binary, pos+8)
            if platform != 2:
                raise ValueError("Expected physical iOS platform")
        elif cmd == 0x25:
            minimum = struct.unpack_from("<I", binary, pos+8)[0]
        pos += length
    if minimum is None or minimum > (15 << 16):
        raise ValueError("Native minimum iOS exceeds 15.0 or is missing")

def validate_deb(path):
    data = path.read_bytes()
    members = dict(ar_members(data))
    if members.get("debian-binary") != b"2.0\n":
        raise ValueError("Invalid Debian version")
    control_blob = next(v for k, v in members.items() if k.startswith("control.tar"))
    payload_blob = next(v for k, v in members.items() if k.startswith("data.tar"))
    control = tar_files(control_blob)
    metadata = fields(control["control"].decode())
    if metadata.get("Package") != PACKAGE or metadata.get("Architecture") != "iphoneos-arm64e":
        raise ValueError("Unexpected package identity / RootHide architecture")
    payload = tar_files(payload_blob)
    required = ["usr/bin/hphone-touchd", "Applications/HPhoneTouch.app/HPhoneTouch",
                "Applications/HPhoneTouch.app/Info.plist", "usr/share/hphone-touch/web/index.html",
                "usr/share/hphone-touch/web/app.js", "usr/share/hphone-touch/web/style.css",
                "Library/LaunchDaemons/io.github.jmehiepp.hphone-touch.plist",
                "usr/share/hphone-touch/licenses/Lua.txt"]
    for name in required:
        if name not in payload:
            raise ValueError(f"Missing payload: {name}")
    for name in required[:2]:
        verify_macho(payload[name])
    info = plistlib.loads(payload[required[2]])
    if info["CFBundleIdentifier"] != PACKAGE+".app":
        raise ValueError("Unexpected bundle identifier")
    daemon = plistlib.loads(payload[required[6]])
    if daemon.get("UserName") != "mobile" or daemon.get("ProgramArguments") != ["/usr/bin/hphone-touchd"]:
        raise ValueError("Unexpected daemon identity/path")
    for script in ("postinst", "prerm"):
        if script not in control or b"\r" in control[script] or not control[script].startswith(b"#!/bin/sh\n"):
            raise ValueError(f"Missing/invalid maintainer script: {script}")
    return metadata

def generate(packages, dest):
    dest.mkdir(parents=True, exist_ok=True)
    pool = dest / "pool"
    pool.mkdir(exist_ok=True)
    entries = []
    for source in packages:
        metadata = validate_deb(source)
        target = pool / source.name
        shutil.copyfile(source, target)
        data = target.read_bytes()
        metadata.update(Filename=f"pool/{target.name}", Size=str(len(data)),
                        MD5sum=hashlib.md5(data).hexdigest(), SHA256=hashlib.sha256(data).hexdigest(),
                        SHA512=hashlib.sha512(data).hexdigest())
        entries.append("\n".join(f"{k}: {v}" for k, v in metadata.items()))
    content = ("\n\n".join(entries)+"\n\n").encode()
    (dest/"Packages").write_bytes(content)
    (dest/"Packages.gz").write_bytes(gzip.compress(content, mtime=0))
    release = ["Origin: HPhone Touch", "Label: HPhone Touch", "Suite: stable", "Codename: stable",
               "Architectures: iphoneos-arm64e", "Description: HPhone Touch experimental RootHide packages",
               "Date: "+email.utils.formatdate(usegmt=True)]
    for algorithm, title in (("md5", "MD5Sum"), ("sha256", "SHA256"), ("sha512", "SHA512")):
        release.append(title+":")
        for name in ("Packages", "Packages.gz"):
            blob = (dest/name).read_bytes()
            release.append(f" {hashlib.new(algorithm, blob).hexdigest()} {len(blob)} {name}")
    (dest/"Release").write_text("\n".join(release)+"\n", encoding="utf-8", newline="\n")
    (dest/".nojekyll").touch()
    (dest/"index.html").write_text('''<!doctype html><html lang="vi"><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>HPhone Touch · Sileo</title><style>body{font:16px/1.7 system-ui;max-width:680px;margin:60px auto;padding:20px;color:#dae6fa;background:#101a2c}a{color:#91b9ff}code{overflow-wrap:anywhere}</style><h1>HPhone Touch</h1><p>Công cụ Lua độc lập cho iPhone RootHide. Bản 0.1 thử nghiệm; cần kiểm tra trên máy thử trước khi triển khai hàng loạt.</p><p>Trong Sileo → Sources → +, thêm:</p><code>https://jmehiepp.github.io/hphone-touch/</code><p><a href="sileo://source/https://jmehiepp.github.io/hphone-touch/">Thêm vào Sileo</a></p><p>iOS 15+ · RootHide · ARM64 (iPhone 6s). Kho công khai chưa ký Release; không dùng để phân phối bản sản xuất.</p><p><a href="https://github.com/jmehiepp/hphone-touch">Mã nguồn, hướng dẫn và giới hạn</a></p></html>''', encoding="utf-8")
    print(f"Validated {len(entries)} package(s); APT repository generated: {dest}")

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("packages", type=Path)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    debs = sorted(args.packages.glob("*.deb"))
    if not debs:
        raise SystemExit("No compiled .deb: refusing to publish an empty repository")
    generate(debs, args.destination)
