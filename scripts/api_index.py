"""Build the independent API inventory from declaration names and this implementation."""
import json
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
UNSUPPORTED = {
    'encrypt':'The proprietary .hb container is not supported.',
    'lockScreen':'Requires a verified lock/unlock helper.', 'unlockScreen':'Requires a verified lock/unlock helper.',
    'respring':'No automatic SpringBoard restart in this build.',
    'saveToSystemAlbum':'Photos permission/helper not implemented.', 'clearSystemAlbum':'Photos deletion helper not implemented.',
    'auto-exit':'No automatic safe-mode changes.', 'isSafeMode':'No verified safe-mode detection.',
    'exitSafeMode':'No automatic safe-mode changes.', 'setAutoExitSafeMode':'No automatic safe-mode changes.',
    'cellularData':'The platform cellular toggle is unavailable.',
    'fakeLocation':'System location simulation helper not implemented.',
    'clearLocation':'System location simulation helper not implemented.',
    'fakeLocationByIP':'No external location provider configured.',
    'keepAutoTouchAwake':'A system-wide idle assertion is not implemented.',
    'isKeepingAutoTouchAwake':'No active system-wide idle assertion.',
}
PARTIAL = {
    'editor':'Selection execution and shortcuts; no syntax debugger or proprietary encryption.',
    'screen':'PNG live preview, zoom, color sampling, crop, tap and swipe; no JPEG stream.',
    'multi':'Color pattern snippets; up to sixteen selected points.',
    'log':'Bounded polling logs, no SSE or hardware-volume stop shortcut.',
    'http-control':'Authenticated POST routes are documented; original unauthenticated GET routes are not exposed.',
    'swipe':'Linear interpolation; original easing is not reproduced.',
    'screenshot':'Returns a saved path; screenshotBytes() preserves the earlier binary interface.',
    'findImage':'Bounded RGB SAD search, nonoverlapping raster-order results; not score sorted.',
    'findText':'Unicode case/diacritic folding, including Vietnamese; depends on OCR engine quality.',
    'dialog':'Foreground/optional overlay forms; some overlay control types use text fields.',
    'clearDialogValues':'Dialog values are not persisted in this version.',
    'setAutoLaunch':'Daemon startup and SpringBoard startup notification; reboot/respring behavior pending hardware test.',
    'backupApp':'Stopped third-party app data only; excludes keychain, shared groups and app binary.',
    'restoreApp':'App data only; recovery backup and explicit selected bundle. No keychain restore.',
    'wipeApp':'Selected stopped app data only; recovery backup. No keychain wipe.',
    'getCookies':'Offline closed-Safari cookie file only; live/WebKit session cookies are unsupported.',
    'importCookies':'Offline selected-domain writes require confirmDomain; no live Safari injection.',
    'deleteCookies':'Offline selected-domain writes require confirmDomain; no live Safari injection.',
    'restoreCookies':'Offline selected-domain restoration only.',
    'setProxy':'Manual unauthenticated Wi-Fi HTTP/HTTPS proxy; OS permission may deny changes.',
    'setTimer':'Persistent timers, up to128; four concurrent scripts and missed schedules can be rejected.',
    'keep':'Waits at most24hours per invocation, instead of infinite native waiting.',
}
EXAMPLES = {
 'getScreenResolution':'local w, h = getScreenResolution()\nprint(w, h)',
 'swipe':'swipe(600, 700, 150, 700, 400)',
 'findColors':'local points = findColors({{0x007AFF, 0, 0}}, 1, nil, false, false, false, 15)\nprint(table.tostring(points))',
 'ocr':'for _, item in ipairs(ocr({languages={"vi"}, engine="tesseract"})) do print(item.text) end',
 'httpGet':'local r = httpGet("https://example.com", {timeout=10})\nprint(r.status)',
 'dialog':'local form = {{type="INPUT", title="Name", value=""}, {type="BUTTON", title="OK"}}\nprint(dialog(form), form[1].value)',
 'setTimer':'setTimer(botPath(), os.time()+60, false, 0)',
}
def generate():
    catalog=json.loads((ROOT/'docs/reference-catalog.json').read_text(encoding='utf-8'))
    items=[]
    for item in catalog['items']:
        name=item['name']; status='implemented; hardware validation pending'
        description='Original implementation. Availability depends on this iOS build and native permissions.'
        if name in UNSUPPORTED: status='unsupported';description=UNSUPPORTED[name]
        elif name in PARTIAL: status='partial';description=PARTIAL[name]
        if name.startswith('★'):status='reference note';description='Use only accounts and data owned by the device operator.'
        items.append({**item,'signature':name,'status':status,'description':description,'example':EXAMPLES.get(name,'')})
    (ROOT/'api.json').write_text(json.dumps({'version':'0.2.1','referenceCount':len(items),'items':items},ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    lines=['# HBTouch declaration comparison','','This inventory covers169 entries declared in the shipped reference documentation, including dashboard entries and constants. It is not169 verified native functions. Original implementation; no binary or dashboard code copied.','','The status describes source coverage. Runtime and device evidence are separate in DEVICE_TEST.md. Keychain, app groups, .hb encryption, live Safari cookies, GPS, Photos operations and complete safe-mode control are not provided.','','| Entry | Source coverage | Limitation |','| --- | --- | --- |']
    for item in items:lines.append(f"| `{item['name']}` | {item['status']} | {item['description']} |")
    (ROOT/'docs/PARITY.md').write_text('\n'.join(lines)+'\n',encoding='utf-8')
    return items
if __name__=='__main__':
    items=generate();print(f'Indexed {len(items)} reference declarations')
