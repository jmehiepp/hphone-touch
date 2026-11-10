# Native input and visual dispatcher

Original HPhone Touch implementation. This document describes actual source
behavior, not a claim of hardware verification or HBTouch equivalence.

`HPInput(operation, args)` and `HPVisual(operation, args)` return dictionaries:
`{ok:true, ...}` or `{error:message}`. Cancellation variants accept a native
`BOOL (^)(void)` callback, checked during gesture waits and pixel searches.
Coordinates are physical portrait pixels with a top-left origin.

Every call accepts optional `owner`, default `http`. A Lua VM should receive a
unique owner and call `HPReleaseInputOwner(owner)` when exiting. That function
releases its held fingers and keyboard keys and drops its retained screen.
Gesture cleanup releases only fingers newly acquired by that gesture. An
already-held finger cannot be acquired by another owner or reused by a gesture.
Input operations are serialized with a recursive lock; a call waits at most
one second for it, then returns an explicit busy error so HTTP workers remain
available for Stop/Status. Simultaneous scripts share one real display and are
not isolated from each other's app state.

## Input operations

| Operation | Arguments |
| --- | --- |
| `touchDown`, `touchMove`, `touchUp` | `id` (integer 1–30, default 1), `x`, `y` |
| `tap` | `x,y,count=1,interval_us=100000,ms=50,id=1` |
| `doubleTap` | `x,y,gap_ms=100,id=1` |
| `longPress` | `x,y,ms=800,id=1` |
| `swipe` | `x1,y1,x2,y2,ms=300,steps=ceil(ms/16),id=1` |
| `swipeHold` | `x1,y1,x2,y2,hold_ms=500,move_ms=300,end_hold_ms=0,id=1` |
| `swipePath` | `points:[[x,y],...],ms=500,steps=ceil(ms/16),id=1` |
| `pinch` | `cx,cy,startDist,endDist,ms=400`; reserves fingers 1 and 2 |
| `keyDown`, `keyUp`, `keyPress` | `key` string |
| `inputText` | `text`, `delay_us=30000` |
| `releaseAll` | releases this owner's state |

Swipes interpolate linearly through the supplied points, not HBTouch's easing.
At most 4096 points/steps, 60 seconds per duration and 120 seconds per complete
gesture. Coordinates and numeric arguments are checked for NaN, infinity and
range. Down/move/up require valid state and the same owner. Touch events contain
all currently held fingers so moving one finger does not lift the others.

Physical keys: `home`, `power`, `volumeUp`, `volumeDown` and corresponding
`HOME_BUTTON`, `POWER_BUTTON`, `VOLUME_UP_BUTTON`, `VOLUME_DOWN_BUTTON` strings.
Keyboard keys include ASCII printable characters, Enter/Return, Delete/
Backspace, Tab, Escape, arrows, Cmd, Ctrl, Shift and Alt. ASCII input uses US
HID keyboard mappings with Shift as needed, at most 120 seconds per call; the
target's keyboard layout can affect inserted characters. Non-ASCII input writes the clipboard
and dispatches Cmd+V; it replaces the existing clipboard. The focused target
must support paste. `dispatched:true` means events were submitted, not that the
target app acknowledged or inserted text.

## Visual operations

| Operation | Arguments | Result fields |
| --- | --- | --- |
| `resolution` | none | `width,height,scale` |
| `keepScreen` | `enabled` | `enabled` |
| `getColor` | integer `x,y` | `color` as 0xRRGGBB integer |
| `getColors` | `points:[[x,y],...]` | `colors` |
| `findColor` | `color,count=0,region,tolerance=0,rightToLeft,bottomToTop` | `points:[[x,y],...],truncated` |
| `findColors` | `colors,count=0,region,tolerance=0,rightToLeft,bottomToTop` | `points,truncated` |
| `matchColors` | `colors:[[x,y,color,tolerance?],...],tolerance=0` | `match` |
| `colorCount` | `color,region,tolerance=0` | `count` |
| `findImage` | absolute `image,count=0,threshold=.9,region,step=1` | `matches,truncated` |
| `screenshot` | optional `region` | `pngBase64,width,height` |

`region` is `[x,y,width,height]`, entirely inside the captured display. Omit it
for the full screen. Color tolerances are per channel, integers 0–255.
`findColors` pattern rows are `[color,dx,dy,tolerance?]`; object form supports
`{color,dx,dy,tolerance,any,not}`. Offsets are relative to each candidate origin.
At most 256 pattern points and 10,000 coordinate/color results. `count:0` scans
until the result cap and sets `truncated` when it reaches that cap.

Image matching is RGB sum of absolute differences normalized to 0–1, with
fully transparent template pixels skipped. It returns raster-order,
non-overlapping matches `{x,y,w,h,centerX,centerY,score}`. A match is suppressed
when its rectangle overlaps an earlier accepted match; it is not globally
sorted by score. Template file must resolve inside the tool's `scripts`
directory, be at most 8 MiB and at most 2048×2048 pixels. At most 1000 matches.
The image-search comparison budget is 250 million channel operations per call;
the color-pattern budget is 250 million point tests per call. Exhaustion is an
explicit error, not an empty result. Reduce the region, increase step or use a
more distinctive template when a search exceeds its budget.

Pixel buffers are owned BGRA8 memory, bounded to 32 MiB each. `keepScreen(true)`
retains a snapshot per owner, at most four owners and 16 MiB retained total; repeated reads use it until
disabled or the owner exits. This freezes visual queries only. It does not stop
the physical screen or affect the existing live PNG/OCR routes.

The previously verified legacy CPU Vision OCR through CVPixelBuffer is
preserved. `HPOCRWithOptions(options,cancelled)` adds a separate options route
with pixel extents and optional original upstream Tesseract support.

## OCR options

Options: `engine:"auto"|"vision"|"tesseract"`, `languages:["en","vi"]`,
`region:[x,y,w,h]`, `words:false`, `level:"fast"|"accurate"`, and
`timeout_ms:15000` (100–30000). Default engine `auto` chooses Tesseract when
Vietnamese is requested, Vision otherwise. Default language is English and
default Vision level is Fast. `items` contain `{text,confidence,x,y,width,
height,centerX,centerY}`, in physical pixels with a top-left origin. Regions
are cropped before recognition. Word mode uses real engine word bounding
boxes, not equally divided text boxes. An unavailable/unsupported engine
returns an explicit error; Vietnamese does not fall back silently to Vision.

Tesseract is loaded optionally from RootHide's `libtesseract.5.dylib`,
`libtesseract.4.dylib` or `libtesseract.dylib`. It requires the exported opaque
C API and progress-monitor APIs, matching Tesseract 4/5. Install a compatible
runtime through Sileo and restart the HPhone Touch daemon if absent; no root
service or bundled HBTouch libraries are used. The library's dependencies
must also be installed by the package manager. `tesseractRuntimePresent`
reports whether the required C symbols loaded, not recognition accuracy.

`scripts/fetch_tessdata.py` downloads and verifies upstream English/Vietnamese
integer models plus their Apache-2.0 license, pinned to commit
`87416418657359cb625c412a48b6e1d6d41c29bd`. Models ship in the package's
`/usr/share/hphone-touch/tessdata`; the model hashes are fixed in that script.
The Tesseract path converts BGRA to RGB, uses LSTM-only mode and sparse-text
page segmentation. Each request creates and destroys its own engine under
the shared OCR lock. Recognition supports cancellation and a native monitor
deadline; loading/initializing the engine cannot be interrupted in C. Vision
is synchronous during its recognition call and checks cancellation before
and after that call. Only one OCR request executes at a time.

## Verification

`tests/test_screen_algorithms.c` checks BGRA channel order, exact/tolerant color
matching, relative offsets, inverse/any predicates, scan order, region bounds,
transparent templates, SAD score and cancellation. Native HID/clipboard,
pixel orientation, captures and gesture effects still require a real iPhone.

Primary API references consulted:

- [Apple IOHIDFamily digitizer implementation](https://github.com/apple-oss-distributions/IOHIDFamily/blob/main/IOHIDFamily/IOHIDEvent.cpp)
- [WebKit's iOS HID event generator](https://github.com/WebKit/WebKit/blob/main/Tools/WebKitTestRunner/ios/HIDEventGenerator.mm)
- [screendump's original HID keyboard sender](https://github.com/julioverne/screendump/blob/master/screendump/main.mm)
- [Upstream Tesseract C API](https://github.com/tesseract-ocr/tesseract/blob/main/include/tesseract/capi.h)
- [Upstream tessdata_fast models and license](https://github.com/tesseract-ocr/tessdata_fast/tree/87416418657359cb625c412a48b6e1d6d41c29bd)

The bridge extends HPhone Touch's existing device-verified digitizer envelope.
No HBTouch implementation or assets were copied.
