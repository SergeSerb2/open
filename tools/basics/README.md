# Basics clips

The four clips on the Welcome basics page (`App/Resources/Basics/`) are
recordings of the real app. Nothing in them is drawn by hand except the pointer
and the drag image, and nothing retimes the app's own motion.

| File | Role |
|---|---|
| `site/` | Our own fixture pages, served on fictional `.example` hosts |
| `demo.py` | Builds a fresh scripted profile per clip, starts the recorder, runs the clip timeline over the automation socket, logs every pointer move and drag step with host-clock times |
| `recorder.swift` | ScreenCaptureKit display capture minus every other app, cropped to the browser window, native 2x, ProRes 422 HQ plus per-frame host times |
| `post.py` | Constant 60 fps by host time, draws our pointer and AppKit's drag image, fills the window corners, encodes HEVC Main `hvc1`, writes posters and the manifest |
| `pacing.py` | Stock frame-detector ledgers of the page motion for `tools/perf/pacing_gate.py` |
| `clips-manifest.json` | Source commit, frame counts and SHA-256 of every bundled file |

## Rules the scripts keep

- Input goes only through the automation socket: the virtual pointer (`mouse`),
  `key`, and `basics-demo` for sidebar drags. A socket cannot run a WindowServer
  drag, so `basics-demo drag-begin/over/end` drives the same drag-source state and
  `NSDraggingDestination` callbacks that AppKit calls during a real drag. The drop
  line, folder target, split overlay and drop are the app's own response.
- No network: `--host-resolver-rules=MAP *.example 127.0.0.1:PORT, MAP * ~NOTFOUND`.
- Display capture, not window capture: macOS marks a captured window with a
  sharing indicator over its traffic lights. Display capture of only this app
  keeps tooltips and popovers (their own windows) and is not shifted by the
  transparent sidebar drop-rail windows.
- The recorder launches through `/usr/bin/open -g`, then `demo.py` takes
  activation back for Open before the timeline starts (an inactive window hides
  tooltip panels).

## Recording (M1, under the screen lock)

The M1 has the approved `~/Applications/OpenCapture.app` pixel launcher. Build an
automation Release app on the M5 and copy it with `tools/` to the M1:

```sh
OPEN_AUTOMATION=1 OPEN_BUILD_DIR=build/demo ~/Library/Caches/OpenRE/scripts/heavy.sh tools/build.sh Release
# on the M1, in the copy:
~/Library/Caches/OpenRE/scripts/heavy.sh xcrun swiftc -O -swift-version 6 -parse-as-library tools/basics/recorder.swift -o recorder
OPEN_BASICS_SOURCE=<commit> /usr/bin/lockf -k /tmp/open-onscreen-e2e.lock python3 tools/basics/demo.py \
  --app Open.app --out rec --recorder ./recorder \
  --launcher ~/Applications/OpenCapture.app --pixels tools/capture/pixels.sh
```

Then, on any Mac with the recordings:

```sh
python3 tools/basics/post.py rec out --crf 18
cp out/basics-*.mp4 out/basics-*.jpg App/Resources/Basics/
cp out/basics-manifest.json tools/basics/clips-manifest.json
```

`demo.py --dry` runs a timeline without the recorder and writes in-app snapshots
every 0.5 s, for checking a script on any Mac.

Known limit: Open's Space-button tooltip shows in the app during the Spaces clip
(the driver logs it at each click) but is not in the capture yet.
