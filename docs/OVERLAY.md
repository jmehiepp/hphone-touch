# Optional SpringBoard controls

The original `overlay/HPhoneOverlay.m` helper has a single injection filter: `com.apple.springboard`. It uses no method hooks. It creates a pass-through window that receives touches only inside its draggable 46-point button, or while the user interacts with a displayed control menu/dialog. Other apps retain their normal touch handling.

The helper is disabled by default. It checks `/var/mobile/Library/HPhoneTouch/ui-preferences.json` every two seconds. Set `{ "overlayEnabled": true, "lastScript": "hello.lua" }` through the authenticated `overlay` service to opt in. The helper must already have been loaded into SpringBoard before this preference can show a button. Installing/enabling does **not** trigger a respring or reboot. Until SpringBoard next loads the dylib, the setting is only a stored preference, not proof that an overlay is active.

The button opens run-last-script, choose-script, stop-all, open-app and hide actions. Script execution is always the daemon's authenticated loopback API; the helper does not execute Lua. The menu displays up to 40 scripts. The last script defaults to `hello.lua`. Gray indicates a daemon connection failure, red a running script, navy idle. It never removes or modifies another tool's overlay.

The token and port are read from the same real mobile data directory as the app, checked, and sent only to `http://127.0.0.1:<port>/api/`. NSURLSession is ephemeral, without cookie storage or URL cache. No token is logged, copied to the clipboard or exposed to a LAN listener.

UI event protocol:

```
GET /api/ui
{ "events": [{ "id": "...", "type": "toast|alert|dialog", "message": "...",
               "title": "...", "target": "overlay", "controls": [...] }] }

POST /api/ui
{ "action": "respond", "id": "...", "button": 1, "controls": [...] }
```

All requests use `X-HPhone-Token`. Event IDs are deduplicated in memory; responses must be idempotent in the daemon. `target: app` events are skipped by the overlay. A toast is acknowledged immediately and displayed for three seconds. Alerts respond on OK. Dialogs support labels, buttons, text input, secure input, text-view values, picker values and booleans. In this initial native helper, TEXTVIEW, PICKER and SWITCH are rendered as labeled text fields (picker accepts its option text; switch true/false), rather than richer dedicated controls. Returned pickers use a 1-based option index when text matches. Remembering dialog values belongs to the daemon. These UI differences must not be called full HBTouch interface parity.

Each enabled poll also sends `POST /api/ui {"action":"heartbeat","surface":"overlay"}`. The daemon can use a recent heartbeat (for example, less than five seconds old) to route events to a loaded overlay, rather than interpreting the stored enable preference as proof that its dylib is active. An unknown heartbeat response is harmless; it does not prevent status polling or normal controls.

The helper requires real iPhone testing after a deliberate SpringBoard reload. Its compilation alone does not confirm scene integration, cross-app overlay visibility, keyboard interaction or background API access on every iOS release. If it cannot be loaded or enabled, the foreground app can still handle the same UI events. Unloading/hiding the helper does not modify safe-mode flags or attempt recovery from another tweak's failures.
