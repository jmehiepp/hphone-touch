"""Package-format fixtures test APT validation; fixtures are never shipped as binaries."""
import gzip
import hashlib
import importlib.util
import io
from pathlib import Path
import plistlib
import struct
import tarfile
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("apt_repo", Path(__file__).resolve().parents[1]/"scripts/apt_repo.py")
apt = importlib.util.module_from_spec(spec)
spec.loader.exec_module(apt)

def tar(files, executable_scripts=True):
    out = io.BytesIO()
    with tarfile.open(fileobj=out, mode="w:gz") as archive:
        for name, data in files.items():
            info = tarfile.TarInfo(name)
            info.size = len(data)
            if name in ("postinst", "prerm") and executable_scripts:
                info.mode = 0o755
            archive.addfile(info, io.BytesIO(data))
    return out.getvalue()

def ar(files):
    out = b"!<arch>\n"
    for name, data in files.items():
        out += f"{name+'/':<16}{0:<12}{0:<6}{0:<6}{'100644':<8}{len(data):<10}`\n".encode()+data+(b"\n" if len(data)%2 else b"")
    return out

def fixture(cpu_subtype=0, minimum=15<<16, executable_scripts=True):
    # Structural Mach-O header only: these fixtures are not executable packages.
    binary = struct.pack("<8I", 0xfeedfacf, 0x0100000c, cpu_subtype, 2, 1, 24, 0, 0)+struct.pack("<6I", 0x32, 24, 2, minimum, 26<<16, 0)
    payload = {"usr/bin/hphone-touchd":binary, "Applications/HPhoneTouch.app/HPhoneTouch":binary,
               "Applications/HPhoneTouch.app/Info.plist":plistlib.dumps({"CFBundleIdentifier":apt.PACKAGE+".app"}),
               "Library/LaunchDaemons/io.github.jmehiepp.hphone-touch.plist":plistlib.dumps({"UserName":"mobile", "ProgramArguments":["/usr/bin/hphone-touchd"]}),
               "usr/share/hphone-touch/licenses/Lua.txt":b"license"}
    for name in ("index.html", "app.js", "style.css"):
        payload["usr/share/hphone-touch/web/"+name] = b"fixture"
    control = {"control":f"Package: {apt.PACKAGE}\nVersion: 0.1.0\nArchitecture: iphoneos-arm64e\nDescription: fixture\n".encode(),
               "postinst":b"#!/bin/sh\nexit 0\n", "prerm":b"#!/bin/sh\nexit 0\n"}
    return ar({"debian-binary":b"2.0\n", "control.tar.gz":tar(control, executable_scripts), "data.tar.gz":tar(payload)})

class AptTests(unittest.TestCase):
    def test_index_hashes_and_roundtrip(self):
        with tempfile.TemporaryDirectory() as folder:
            base = Path(folder)
            package = base/"fixture.deb"
            package.write_bytes(fixture())
            apt.generate([package], base/"out")
            content = (base/"out/Packages").read_bytes()
            self.assertEqual(gzip.decompress((base/"out/Packages.gz").read_bytes()), content)
            fields = apt.fields(content.decode())
            self.assertEqual(fields["SHA256"], hashlib.sha256(package.read_bytes()).hexdigest())
            self.assertEqual(fields["Size"], str(package.stat().st_size))
            self.assertIn(hashlib.sha256(content).hexdigest(), (base/"out/Release").read_text())

    def test_rejects_arm64e_and_newer_minimum(self):
        for options in ({"cpu_subtype":2}, {"minimum":16<<16}):
            with self.subTest(options=options), tempfile.TemporaryDirectory() as folder:
                path = Path(folder)/"fixture.deb"
                path.write_bytes(fixture(**options))
                with self.assertRaises(ValueError):
                    apt.validate_deb(path)

    def test_rejects_truncated_archive(self):
        with self.assertRaises(ValueError):
            list(apt.ar_members(fixture()[:-10]))

    def test_rejects_nonexecutable_maintainer_scripts(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)/"fixture.deb"
            path.write_bytes(fixture(executable_scripts=False))
            with self.assertRaises(ValueError):
                apt.validate_deb(path)

if __name__ == "__main__":
    unittest.main(verbosity=2)
