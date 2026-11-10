# Build from repository root: pyinstaller --clean --noconfirm pc/HPhoneTouchFleet.spec
from pathlib import Path
root = Path(SPECPATH).resolve().parent
a = Analysis([str(root / 'pc' / 'app.py')], pathex=[str(root / 'pc')],
             binaries=[], datas=[], hiddenimports=['pymobiledevice3.usbmux', 'pymobiledevice3.lockdown'],
             hookspath=[], hooksconfig={}, runtime_hooks=[], excludes=[])
pyz = PYZ(a.pure)
exe = EXE(pyz, a.scripts, a.binaries, a.datas, [], name='HPhoneTouchFleet',
          debug=False, strip=False, upx=False, console=False)
