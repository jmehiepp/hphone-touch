# Native services interface

`HPService(operation, arguments)` returns a JSON dictionary `{ok, value?, error?, code?}`. Failure is explicit; a missing entitlement, symbol or helper never produces a fake success. Callers must inspect `ok` before reading `value`. `HPServiceCapabilities()` describes this build's available service mechanisms, not physical-device test results.

| Operation | Arguments | `value` |
| --- | --- | --- |
| `appInfo` | `bundleId` | `bundleId, displayName, bundlePath, dataContainer, executable, version, applicationType` |
| `listInstalledApps` | none | array of app-info dictionaries |
| `appRun` | `bundleId` | launch accepted (does not imply foreground) |
| `appActivate` | `bundleId, timeout=10` (0–30 seconds) | foreground confirmed boolean |
| `appState`, `appIsActive` | `bundleId` | `ACTIVATED`, `DEACTIVATED`, `NOT RUNNING`; or boolean |
| `frontMostAppId`, `runningApps` | none | identifier; or identifier array |
| `appKill` | `bundleId` | SIGTERM dispatched to verified app executable; SpringBoard and HPhone Touch protected |
| `openURL` | `url` | URL accepted by LaunchServices |
| `copyText`, `clipText` | `text`; none | boolean; clipboard string |
| `deviceInfo`, `captureDebugInfo` | none | model, kernel, OS, PID, UID, local IP, own memory; foreground when available |
| `getSN`, `getLocalIP` | none | serial when permitted; Wi-Fi IPv4 or empty string |
| `memoryUsageOfTotal`, `memoryUsageOfApp` | none; `bundleId` | resident bytes |
| `brightness` | optional `value` 0–1 | brightness read back from UIScreen |
| `isScreenLocked` | none | SpringBoard lock state |
| `vibrate` | none | vibration dispatched |
| `playAudio` | absolute `path`, `times=1` (-1=loop, 0=once) | playback started |
| `stopAudio`, `pauseAudio`, `resumeAudio` | none | operation accepted, failure when no loaded player |
| `execute` | `command`, `timeout=15` (0.1–30 s) | `output, exitCode, signal, timedOut, truncated` |
| `backupApp` | `bundleId, name` | `{ok,path,name,dataSize,keychainCount:0,hasKeychain:false}` |
| `restoreApp` | `bundleId, name, confirmBundle` | data replacement result plus `recoveryBackup` at outer level |
| `wipeApp` | `bundleId, confirmBundle` | data wipe result plus `recoveryBackup` at outer level |
| `listBackups` | optional `bundleId` | array `{bundleId,name,date,dataSize,hasKeychain:false}` |
| `deleteBackup` | `bundleId, name` | boolean |
| `overlay` | optional `enabled`, `lastScript` | stored preferences (disabled by default); helper load/runtime validation still required |
| `airplaneMode` / `radioAirplane`, `wifi` / `radioWifi` | optional `enabled` | radio boolean; write must be confirmed by read-back within 2 s |
| `getRadios` | none | `{airplane,wifi,cellular:null,errors}`; unavailable readings are null |
| `getProxy` | none | `{enabled,host,port,username}` for the current en0 Wi-Fi service |
| `setProxy` | `proxy:"host:port"` or explicit `host,port` | committed/applied boolean; authenticated proxies currently rejected |
| `clearProxy` | none | disables HTTP/HTTPS/SOCKS/PAC/discovery on the selected Wi-Fi service |
| `getCookies`, `getCookieHeader`, `getCookiesJSON`, `getCookiesText` | optional `domain,file` | offline Safari-cookie records, header, JSON or Netscape text |
| `safariCookiesPath` | optional `file` | allowed existing binary-cookie jar path |
| `importCookies` | `domain,confirmDomain,cookies` array or JSON string, optional `file` | imported count, preserving cookies outside the target domain |
| `deleteCookies`, `restoreCookies` | `domain,confirmDomain`, optional `file` | removed count; restored boolean |

App-data operations only target a real, selected third-party app data container resolved by LaunchServices. The daemon must be able to verify that the app is stopped. System apps, this tool's own data, bundles, shared app groups, symlinks, hard links and special files are excluded. Backup names are flat; data lives in the private HPhone Touch backups folder. A backup is limited to 512 MiB and 50,000 entries. It includes relative file names, sizes, modes and SHA256 hashes. These are **app-data-only** backups; they do not include keychain, app-group containers, app binaries or activation credentials.

Restore validates the complete payload against the manifest, stages files inside the target container, then replaces top-level data through renames. The container-manager metadata is preserved. Restore and wipe first create an automatic recovery backup and require `confirmBundle` to exactly equal `bundleId`. Immediate failures roll back; interrupted multi-file replacements retain a `.hphone-transaction.json` journal and old data for recovery. A pending journal blocks further replacement. Automatic recovery after a power interruption is not yet implemented. Never test destructive operations against personal data to establish initial compatibility.

`execute` runs a minimal-environment shell as the current daemon user (mobile on iPhone), captures at most 1 MiB, and kills its process group on timeout/output overflow. It does not elevate privileges. Caller-supplied scripts are trusted owner code. Cancellation of Lua does not automatically interrupt an already executing bounded service call.

Safari live-cookie access, cross-app keychain, proxy authentication, cellular toggling, global GPS, and an effective global keep-awake assertion require separate helpers and are explicitly unsupported here. `keepAutoTouchAwake(true)` reports an error instead of claiming that a daemon-local UIKit flag controls other apps. No system-wide safe-mode marker or jailbreak setting is changed.

Radio calls dynamically load AppSupport/WiFiKit and check selectors. A setter must read back the desired state within two seconds. Available symbols do not prove permission or effective hardware state on every firmware. Proxy calls dynamically load SystemConfiguration, acquire a non-blocking preferences lock, select only the current set's en0 service, save a private pre-change plist, commit/apply and check the stored result. Permission/entitlement failures are returned. A failed apply attempts to restore the previous configuration and reports whether rollback succeeded. Host tests explicitly disable both radio/proxy paths so tests cannot change the build machine's network.

Cookie access is **offline only**: Safari must be stopped. It reads its known cookie jar, or an explicit `.binarycookies` fixture confined to HPhone Touch's scripts directory. Domain matching uses the exact hostname or a dot-separated subdomain boundary, rather than an unsafe arbitrary substring. Changes require a domain and matching `confirmDomain`; `"*"` explicitly selects the whole jar. Imports merge cookies by domain/name/path. Unchanged records and footer metadata survive byte-for-byte. Delete/restore preserve unrelated domains. A private `.hphonebak` file is created before mutation; restore first preserves the current jar as `.before-restore.hphonebak`. Files are written through a same-directory temporary file, fsynced and renamed atomically. A final before/after comparison rejects concurrently changed jars. Limits: 8 MiB, 20,000 records; imports at most 10,000. Aggregate decoded record bytes are capped to reject overlapping-offset memory amplification. Cookies are returned only through the authenticated API and never logged or sent to a third party. Synthetic tests are not proof that Safari on a particular firmware accepts a modified jar; physical testing should use a disposable test site/session.

Primary API references consulted for this implementation:

- [Frida's SpringBoard API declarations](https://github.com/frida/frida-core/blob/main/src/darwin/springboard.h) and [framework loading](https://github.com/frida/frida-core/blob/main/src/darwin/springboard.m).
- [Theos LaunchServices workspace declarations](https://github.com/theos/headers/blob/master/MobileCoreServices/LSApplicationWorkspace.h), [app proxy](https://github.com/theos/headers/blob/master/MobileCoreServices/LSApplicationProxy.h) and [bundle proxy](https://github.com/theos/headers/blob/master/MobileCoreServices/LSBundleProxy.h).
- [Apple process-information ABI](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/proc_info.h), [UIPasteboard](https://developer.apple.com/documentation/uikit/uipasteboard), [AVAudioPlayer](https://developer.apple.com/documentation/avfaudio/avaudioplayer).
- [RadiosPreferences runtime declaration](https://github.com/nst/iOS-Runtime-Headers/blob/master/PrivateFrameworks/AppSupport.framework/RadiosPreferences.h), [WFClient runtime declaration](https://github.com/nst/iOS-Runtime-Headers/blob/master/PrivateFrameworks/WiFiKit.framework/WFClient.h). These are direct runtime-header observations, not Apple public API guarantees.
- Apple's own [network configuration API](https://github.com/apple-oss-distributions/configd/blob/main/SystemConfiguration.fproj/SCNetworkConfiguration.h) and [proxy schema definitions](https://github.com/apple-oss-distributions/configd/blob/main/SystemConfiguration.fproj/SCSchemaDefinitions.h).
- Primary cookie-format research by [Joachim Metz](https://github.com/libyal/dtformats/blob/main/documentation/Safari%20Cookies.asciidoc), [creachadair](https://gist.github.com/creachadair/ba843bd92c2cfc78dc5e1a53b44775a3) and [cixtor](https://github.com/cixtor/binarycookies). The parser/encoder is original code based on format facts; no parser implementation was copied.

The code and tests are independently written. Reference declarations are not evidence that private APIs work on every iOS/RootHide combination. Fake-container host tests and physical-device checks must be reported separately.
