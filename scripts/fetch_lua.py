"""Fetch official Lua 5.4.9 sources at a pinned commit and SHA256."""
import hashlib
import io
from pathlib import Path
import tarfile
import urllib.request

VERSION = "5.4.9"
COMMIT = "312b9efaa1061c2c4cad08554dbc1351c3270eef"
SHA256 = "037711bab2600009d396dd83df7c64e51eb402447196e71b56ee9d70ae022115"
ROOT = Path(__file__).resolve().parents[1]

def main():
    archive_path = ROOT / "vendor/lua-github.tar.gz"
    if archive_path.exists():
        data = archive_path.read_bytes()
    else:
        data = urllib.request.urlopen(f"https://codeload.github.com/lua/lua/tar.gz/{COMMIT}", timeout=30).read()
    if hashlib.sha256(data).hexdigest() != SHA256:
        raise SystemExit("Lua SHA256 mismatch")
    dest = ROOT / "vendor/lua"
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as archive:
        for member in archive.getmembers():
            relative = Path(member.name).relative_to(f"lua-{COMMIT}")
            if member.isfile() and len(relative.parts)==1 and (relative.suffix in (".c", ".h") or relative.name=="README.md"):
                if ".." in relative.parts or relative.is_absolute():
                    raise SystemExit("Unsafe Lua archive path")
                if relative.name in ("onelua.c", "ltests.c", "ltests.h"):
                    continue
                path = dest / "src" / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(archive.extractfile(member).read())
    print(f"Lua {VERSION}: SHA256 verified, sources ready")

if __name__ == "__main__":
    main()
