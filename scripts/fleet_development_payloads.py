"""Preserve official executable code; add explicit development entitlements.

These are labelled development payloads, not upstream release binaries. The two
debugging entitlements let Apple's USB accessibility audit service activate UI
elements. No kernel code or exploit implementation is patched by this script.
Only the separate fleet branch builds these; nothing is published to APT.
"""
from pathlib import Path
import hashlib
import json
import plistlib
import subprocess
import sys
import urllib.request
import zipfile

OUT = Path('fleet-development-output')
OUT.mkdir(exist_ok=True)
SIGNER = str(Path(sys.argv[1]).resolve())
SOURCES = {
    'PersistenceHelper_Embedded': (
        'https://github.com/opa334/TrollStore/releases/download/2.1.1/PersistenceHelper_Embedded',
        'f0915cb7a608522ef84a43c6617433037e030ff68f5db89a6bb982f8430a0cb9'),
    'Dopamine-roothide-3.0.13-30.ipa': (
        'https://github.com/roothide/Dopamine2-roothide/releases/download/3.0.13-30/Dopamine.tipa',
        '98bc39c88161da1671eda56bd4139c85507b9089a8fdae80b333e975b88438f9'),
}

def digest(data):
    return hashlib.sha256(data).hexdigest()

def development_signature(path):
    raw = subprocess.check_output(['ldid', '-e', str(path)])
    entitlements = plistlib.loads(raw)
    entitlements['get-task-allow'] = True
    entitlements['task_for_pid-allow'] = True
    entitlements_path = path.with_name(path.name + '.entitlements.plist')
    entitlements_path.write_bytes(plistlib.dumps(entitlements))
    subprocess.run([SIGNER, '--entitlements', str(entitlements_path), str(path)], check=True)
    actual = plistlib.loads(subprocess.check_output(['ldid', '-e', str(path)]))
    assert actual == entitlements
    entitlements_path.unlink()

manifest = {'purpose': 'Owner-authorized USB UI automation development signatures',
            'kernel_or_executable_code_patches': False, 'sources': {}, 'outputs': {}}
for name, (url, expected) in SOURCES.items():
    with urllib.request.urlopen(url, timeout=120) as response:
        data = response.read()
    assert digest(data) == expected, f'Upstream SHA256 mismatch: {name}'
    manifest['sources'][name] = {'url': url, 'sha256': expected}
    if name == 'PersistenceHelper_Embedded':
        target = OUT / 'PersistenceHelper_Embedded_USBDevelopment'
        target.write_bytes(data)
        development_signature(target)
    else:
        original = OUT / name
        original.write_bytes(data)
        unpacked = OUT / 'unpacked'
        with zipfile.ZipFile(original) as archive:
            archive.extractall(unpacked)
        infos = list(unpacked.glob('Payload/*.app/Info.plist'))
        assert len(infos) == 1
        info = plistlib.loads(infos[0].read_bytes())
        assert info['CFBundleIdentifier'] == 'com.opa334.Dopamine-roothide'
        executable = infos[0].parent / info['CFBundleExecutable']
        development_signature(executable)
        target = OUT / 'Dopamine-roothide-3.0.13-30-USBDevelopment.tipa'
        with zipfile.ZipFile(target, 'w', zipfile.ZIP_DEFLATED) as archive:
            for entry in sorted(unpacked.rglob('*')):
                if entry.is_file():
                    archive.write(entry, entry.relative_to(unpacked))
        original.unlink()
        # Only package the finished output and manifest; no loose app in artifact.
        import shutil
        shutil.rmtree(unpacked)
    manifest['outputs'][target.name] = {'sha256': digest(target.read_bytes()), 'size': target.stat().st_size}
(OUT / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
