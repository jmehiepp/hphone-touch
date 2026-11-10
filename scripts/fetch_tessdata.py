"""Fetch original upstream Apache-2.0 OCR models, pinned by commit and SHA256."""
import hashlib
from pathlib import Path
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
COMMIT = "87416418657359cb625c412a48b6e1d6d41c29bd"
FILES = {
    "eng.traineddata": "7d4322bd2a7749724879683fc3912cb542f19906c83bcc1a52132556427170b2",
    "vie.traineddata": "79df64caf7bcfb2a27df5042ecb6121e196eada34da774956995747636d5bfa1",
    "LICENSE": "cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30",
}

def fetch(destination=ROOT/"vendor/tessdata"):
    destination.mkdir(parents=True, exist_ok=True)
    for name, expected in FILES.items():
        path = destination/name
        if path.is_file() and hashlib.sha256(path.read_bytes()).hexdigest() == expected:
            continue
        request = urllib.request.Request(
            f"https://raw.githubusercontent.com/tesseract-ocr/tessdata_fast/{COMMIT}/{name}",
            headers={"User-Agent": "HPhoneTouch-build"},
        )
        with urllib.request.urlopen(request, timeout=60) as response:
            payload = response.read(16*1024*1024+1)
        if len(payload) > 16*1024*1024 or hashlib.sha256(payload).hexdigest() != expected:
            raise RuntimeError(f"Pinned tessdata integrity failed: {name}")
        temporary = path.with_suffix(path.suffix+".tmp")
        temporary.write_bytes(payload)
        temporary.replace(path)
    print("Verified upstream tessdata_fast eng/vie models and Apache-2.0 license")

if __name__ == "__main__":
    fetch()
