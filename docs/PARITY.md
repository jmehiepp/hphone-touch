# HBTouch declaration comparison

This inventory covers169 entries declared in the shipped reference documentation, including dashboard entries and constants. It is not169 verified native functions. Original implementation; no binary or dashboard code copied.

The status describes source coverage. Runtime and device evidence are separate in DEVICE_TEST.md. Keychain, app groups, .hb encryption, live Safari cookies, GPS, Photos operations and complete safe-mode control are not provided.

| Entry | Source coverage | Limitation |
| --- | --- | --- |
| `editor` | partial | Selection execution and shortcuts; no syntax debugger or proprietary encryption. |
| `screen` | partial | PNG live preview, zoom, color sampling, crop, tap and swipe; no JPEG stream. |
| `multi` | partial | Color pattern snippets; up to sixteen selected points. |
| `docs` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `multi-run` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `log` | partial | Bounded polling logs, no SSE or hardware-volume stop shortcut. |
| `encrypt` | unsupported | The proprietary .hb container is not supported. |
| `paths` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `tap` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `doubleTap` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `longPress` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `touchDown` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `touchMove` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `touchUp` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `swipe` | partial | Linear interpolation; original easing is not reproduced. |
| `swipeHold` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `swipePath` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `pinch` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `scroll` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `usleep` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `sleep` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `keyPress` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `keyDown` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `keyUp` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `inputText` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `getScreenResolution` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `getScreenSize` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `getScreenScale` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `getOrientation` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `getColor` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `getColors` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `findColor` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `findColors` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `findMultiColor` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `findColorList` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `getColorCount` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `isColor` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `matchColors` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `findImage` | partial | Bounded RGB SAD search, nonoverlapping raster-order results; not score sorted. |
| `findImageTap` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `waitImage` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `waitImageTap` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `tapImage` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `screenshot` | partial | Returns a saved path; screenshotBytes() preserves the earlier binary interface. |
| `setColorTolerance` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `dumpColorsOfScreen` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `ocr` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `setOcrEngine` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `getText` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `findText` | partial | Case-insensitive matching; Unicode accent folding is not implemented. |
| `tapText` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `waitText` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `tapColors` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `tapColor` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `tapMultiColor` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `findColorTap` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `findColorsTap` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `waitColor` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `keep` | partial | Waits at most24hours per invocation, instead of infinite native waiting. |
| `keepFindingColor` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `keepFindingColors` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `keepFindingColorTap` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `keepFindingColorsTap` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `appRun` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `appKill` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `appActivate` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `appState` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `appIsActive` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `appInfo` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `frontMostAppId` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `runningApps` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `lockScreen` | unsupported | Requires a verified lock/unlock helper. |
| `unlockScreen` | unsupported | Requires a verified lock/unlock helper. |
| `isScreenLocked` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `openURL` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `execute` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `respring` | unsupported | No automatic SpringBoard restart in this build. |
| `copyText` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `clipText` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `vibrate` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `getSN` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `getLocalIP` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `getVersion` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `captureDebugInfo` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `memoryUsageOfApp` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `memoryUsageOfTotal` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `keepAutoTouchAwake` | unsupported | A system-wide idle assertion is not implemented. |
| `isKeepingAutoTouchAwake` | unsupported | No active system-wide idle assertion. |
| `toast` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `alert` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `dialog` | partial | Foreground/optional overlay forms; some overlay control types use text fields. |
| `clearDialogValues` | partial | Dialog values are not persisted in this version. |
| `runScript` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `stopScript` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `stopAllScripts` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `runningScripts` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `isScriptRunning` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `http-control` | partial | Authenticated POST routes are documented; original unauthenticated GET routes are not exposed. |
| `setTimer` | partial | Persistent timers, up to128; four concurrent scripts and missed schedules can be rejected. |
| `removeTimer` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `setAutoLaunch` | partial | Daemon startup and SpringBoard startup notification; reboot/respring behavior pending hardware test. |
| `listAutoLaunch` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `playAudio` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `stopAudio` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `pauseAudio` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `resumeAudio` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `saveToSystemAlbum` | unsupported | Photos permission/helper not implemented. |
| `clearSystemAlbum` | unsupported | Photos deletion helper not implemented. |
| `millis` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `log` | partial | Bounded polling logs, no SSE or hardware-volume stop shortcut. |
| `clearLog` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `stop` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `rootDir` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `currentDir` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `botPath` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `intToRgb` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `rgbToInt` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `centerOffsetOfPoints` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `centerOffsetOfPixels` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `table.tostring` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `string.startswith` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `airplaneMode` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `wifi` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `cellularData` | unsupported | The platform cellular toggle is unavailable. |
| `getRadios` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `★ QUAN TRỌNG` | reference note | Use only accounts and data owned by the device operator. |
| `getCookies` | partial | Offline closed-Safari cookie file only; live/WebKit session cookies are unsupported. |
| `getCookieHeader` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `getCookiesText` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `safariCookiesPath` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `getCookiesJSON` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `importCookies` | partial | Offline selected-domain writes require confirmDomain; no live Safari injection. |
| `deleteCookies` | partial | Offline selected-domain writes require confirmDomain; no live Safari injection. |
| `restoreCookies` | partial | Offline selected-domain restoration only. |
| `auto-exit` | unsupported | No automatic safe-mode changes. |
| `isSafeMode` | unsupported | No verified safe-mode detection. |
| `exitSafeMode` | unsupported | No automatic safe-mode changes. |
| `setAutoExitSafeMode` | unsupported | No automatic safe-mode changes. |
| `backupApp` | partial | Stopped third-party app data only; excludes keychain, shared groups and app binary. |
| `restoreApp` | partial | App data only; recovery backup and explicit selected bundle. No keychain restore. |
| `wipeApp` | partial | Selected stopped app data only; recovery backup. No keychain wipe. |
| `deleteBackup` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `listBackups` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `listInstalledApps` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `readFile` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `writeFile` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `appendFile` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `removeFirstLine` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `readLines` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `fileExists` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `deleteFile` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `listDir` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `jsonEncode` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `jsonDecode` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `base64Encode` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `base64Decode` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `★ Kết quả trả về` | reference note | Use only accounts and data owned by the device operator. |
| `httpGet` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `httpPost` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `httpRequest` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `setProxy` | partial | Manual unauthenticated Wi-Fi HTTP/HTTPS proxy; OS permission may deny changes. |
| `clearProxy` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `getProxy` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `fakeLocation` | unsupported | System location simulation helper not implemented. |
| `clearLocation` | unsupported | System location simulation helper not implemented. |
| `fakeLocationByIP` | unsupported | No external location provider configured. |
| `KEY_TYPE` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `CONTROLLER_TYPE` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
| `ORIENTATION_TYPE` | implemented; hardware validation pending | Original implementation. Availability depends on this iOS build and native permissions. |
