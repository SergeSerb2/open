# Open intro

`OpenOnboarding` is entered only for a missing `State/browser.json`, or an
explicit replay. Returning and `--skip-first-run` launches leave the optional
App controller nil. No resource lookup, scene construction or player creation
runs on those paths. The `onboarding` automation command reports that boundary
as `moduleActive: false` without calling into the package.

The intro uses Open's own doorway/sun mark, procedural grain and synthesized
score. There are no reference-app assets. All scene and playback beat times
are in `IntroTimeline.beats`; the Python generator reads the same table.
The lit door uses a `#FFF3DC` → `#FFC680` gradient at 0.92 opacity. The
`#FFD9A8` spill peaks at 0.45 and settles at 0.28; it and the warm orb use
Core Animation's `screenBlendMode`. The final text uses approximately 28 pt
from the wordmark to the identity line, 18 pt to the first value, 22 pt value
rows with 6 pt gaps, and 32 pt from the last value to Continue. The settled
mark/text/button block centers at about 52.4% of the window height.

| Beat | Start (s) | End (s) |
|---|---:|---:|
| `introAnimation` | 0 | 3.3 |
| `sellIntro` | 3.3 | 9.8 |
| `sellCompleted` | 9.8 | 9.8 |
| `room` | 0 | 1 |
| `dim` | 0 | 1.5 |
| `dimFinish` | 0 | 2.5 |
| `door` | 0.3 | 1.9 |
| `sun` | 1.7 | 2.7 |
| `bellPair` | 2.3 | 2.47 |
| `spill` | 2.4 | 3.3 |
| `markMove` | 3.3 | 4.1 |
| `wordmark` | 3.3 | 4.1 |
| `line` | 4.3 | 4.9 |
| `value1` | 5.6 | 6.8 |
| `value2` | 6.8 | 8 |
| `value3` | 8 | 9.2 |
| `button` | 9.8 | 10.2 |
| `buttonSpring` | 9.8 | 11.05 |
| `plateau` | 5 | 15 |
| `subEntry` | 3.3 | 5.3 |
| `airSweep` | 2.4 | 3.3 |
| `sound` | 0 | 20 |
| `soundFade` | 15 | 19.5 |
| `idlePause` | 23.5 | 23.5 |
| `reduceFade` | 0 | 0.6 |
| `reduceButton` | 1 | 1 |
| `handoff` | 0 | 0.45 |
| `handoffSound` | 0 | 0.8 |
| `syncLead` | 0 | 0.08 |
| `soundDeadline` | 0 | 0.3 |
| `measureFrames` | 0 | 8 |
| `measureMemory` | 3 | 3 |
| `orbBlue` | 0 | 18 |
| `orbPurple` | 0 | 22 |
| `orbWarm` | 0 | 26 |

Other table constants: Reduce Motion fade 0–0.6 s, button enable 1 s;
hand-off fade 0.45 s, sound fade 0.8 s; common audio/CA scheduling lead
0.08 s; sound preparation deadline 0.3 s; frame measurement 0–8 s;
resident measurement 3 s; orb periods 18/22/26 s.

Continue replaces the foreground inside the same 1280×800 onboarding window.
The room, dim child and music keep their clocks through the setup steps below.
The intro never writes a snapshot. A small screen (both width ≤1280 and height
≤800) uses its full screen size minus 72 pt in each dimension. The mouse-transparent
dim child covers that screen at 85% black, and is excluded from ordinary window
lists and snapshots. Only final completion or closing fades music and the dim.

Esc or a scene click completes the visual tracks and enables Continue.
The music continues on its original clock. Return and Space cannot advance
before the button enable beat. Reduce Motion uses only a final-composition
cross-fade, with static orbs. Increase Contrast raises the identity line to
90% white. Core Animation owns all animation frames. Only the measurement
flag creates a display link; lifecycle work uses one-shot async deadlines.

The sound generator uses only Python's standard library and macOS afconvert.
It pins the little-endian stereo 48 kHz / 16-bit PCM SHA-256. AAC validation
allows 20 ms of duration difference, 1.5 dB per half-second RMS bin, and a
silent tail from 19.5 s (at most 8 PCM quantization steps after AAC decode).
The committed measurement JSON is also compared against regenerated PCM.
The final suspended chord resolves to Dadd9 at 17.75 s. This is the midpoint
of the spec's final phrase, whose exact resolution time was unspecified.

The v2 master plateau is approximately −14 LUFS. Normal playback uses volume
0.5 (about −20 LUFS heard); silent automation sets volume zero before player
preparation. The PCM peak is −2.90 dBFS, below the original −1 dBFS target.
This retains the v2 loudness target. Acceptance of this headroom, or a score
retune to hit both values, is a decision for the lead. No automation run emits audio.

Run the actual offscreen renderer and decoder after building their product:

```sh
Packages/OpenKit/.build/debug/onboarding-render --out .re/handoff/sections/s17/c2
Packages/OpenKit/.build/debug/onboarding-render --check-sound
python3 tools/generate-intro-sound.py --check
```

The renderer samples the same scene tracks as the real view at 0.5, 1.5,
2.6, 3.5, 5.0, 6.5, 8.0 and 10.2 s, plus the Reduce Motion final frame,
at 2x. `CARenderer` draws that layer tree into a Metal texture, preserving
the native radial gradients and blend filters. It creates an unshown window
for AppKit backing; it never orders it front. Real-window acceptance is the
separate `onboarding` e2e suite.

## Setup in the same window

Continue replaces only the foreground with Name → Import (when source data exists) → Favorites (unless import brought Favorites) → Theme → Blocker → Default browser → Ready. The shared room, dim overlay and music keep their clocks. Name is optional, trimmed and limited to 40 characters. Every selection stays in memory until Get Started. Closing the window quits without applying those selections.

`OnboardingStepsController` hosts Section 7's `FirstRunView(embeddedImport: true)` and the same `FirstRunViewModel` / `ImportWizardViewModel`. Settings ▸ Import keeps its existing wizard. Consent tokens, import idempotency, progress, reports and save errors stay in the shared implementation. The import landing save is a checkpoint; final setup owns the completed flag.

Favorites prefetch through `OpenStore.FaviconFetcher` after `sellIntro.start + syncLead` (3.38 seconds from the intro start request). A utility task performs network and store work off the main actor, with six concurrent sites, six seconds per site and twelve seconds overall. Downloads are ephemeral, with no cookies or credentials. Each resource can redirect only within its registrable site, checked by the existing PSL-backed `AdBlockSites` through `FaviconSiteResolver`. Explicit icon URLs declared by the page may use any public HTTPS CDN; icon and manifest requests permit only one redirect hop. The existing private-address checks still apply.

Discovery prefers an apple-touch icon of at least 120 pixels, then the largest manifest icon up to 512 pixels, then the largest declared icon, then `/favicon.ico`. Input stays bounded at 512 KiB and 1024 pixels per dimension. The fetcher first requires at least 64 source pixels. Only after larger candidates fail does it accept a 32–48-pixel source. These small icons always use the 24-point plate, with a maximum 2x enlargement. Static SVG is rasterized at 128 pixels; active content and external resources are refused. Source kind, dimensions and opacity are stored beside the normalized 32/64-pixel images in `AppStores.favicons`, the same store used by `AppStores.sidebarFavicons`. The sidebar cache refreshes from that store, so hand-off needs no second icon fetch.

Each 32-point icon frame draws a colored monogram immediately. Eight clear, calm hues use OKLCH lightness 0.62, chroma 0.11 and a stable hash of the site name. Their white-letter contrast is 3.46:1 or greater; the first letter is 17-point semibold. An opaque square icon fills a rounded rectangle with radius eight. A transparent icon sits at 24 points on a soft 32-point plate. The fetched icon cross-fades over the monogram in 0.25 seconds; Reduce Motion swaps it instantly. Failed requests keep the monogram with no failure UI. The preview uses the same icon views and images.

Automation `onboarding action=state` includes `favoriteTiles` with `iconState` (`monogram`, `loading`, `icon`, or `failed`), `renderedKind`, `sourceKind`, `pixelSize`, fixed frames and fade duration. Automation builds accept `--favicon-network=blocked` to fail only this prefetch before creating a session. `tools/e2e/onboarding_steps.py` verifies live downloads, blocked-network monograms, fixed geometry, Reduce Motion and the stored sidebar hand-off. Its window-only captures exclude the screen-sized dim child and include the actual window backing scale. Selected and focused close-ups and an interior pixel comparison guard against AppKit drawing a text focus band across the tile. Automation can opt into a private request/candidate trace with `OPEN_FAVICON_DIAGNOSTICS=1`; normal launches never produce it. The Notion suggestion uses its canonical `notion.com` host, so its page needs no redirect across registrable domains. Theme uses `OpenSpaceEditor`'s preset strip, color pad, state reducer and appearance bar. The selected style is applied to the focused Space at finish. Blocker uses the existing `AdBlockStore.setEnabled` global `nativeAdBlockEnabled` setting in `adblock-settings.json`, the same setting as Advanced.

`OnboardingBrandMark` supplies the intro's trimmed rounded doorway and sun to the intro, Name preview and both marks on the card. The Theme preview keeps its traffic lights, URL bar, four tinted sidebar rows and three neutral page bars live with the selected Space style. The second Favorite suggestion is Google Maps (`https://maps.google.com/`): its public manifest declares distinct product artwork. Gmail's signed-out page declares no icon and uses Google's generic fallback. Once a visited page reports its own favicon, `EngineWebContentHost.confirmFaviconForDocument` sends it through `StoredFaviconCache.report`; the page-specific store record takes precedence over the prefetch's origin fallback. Live Favorites use the engine image, and unloaded Favorites use the refreshed store cache.

The Ready card uses one original drawing routine for the screen and 1200 × 750 PNG output. Its gradient midpoint supplies the sRGB relative luminance. Above 0.55, the name uses black at 0.82 and the date uses black at 0.55; otherwise they use white and white at 0.72. The date is 17 points in the card's design coordinates. Save opens `NSSavePanel`; Shuffle cycles six deterministic patterns. The two 32-point circle buttons sit 12 points apart, centered 16 points below the card. Their white fill changes from 0.16 to 0.24 on hover, with white glyphs at 0.9. Confetti emits above the card once for 0.6 seconds, in a separate layer below the card and its text, then removes its layer. Reduce Motion uses cross-fades and no confetti.

The default-browser service runs only on Next with Yes selected. Setup awaits the existing Settings request's completion, then shows its outcome for 1.2 seconds before advancing. Automation sockets always use a bounded outcome stub (`OPEN_AUTOMATION_DEFAULT_BROWSER=already|success|declined|failed`, default declined); they never invoke the system prompt.

Get Started applies choices and uses Section 7's `finishFirstRun`: save the choices, insert and select the ordinary Welcome tab, save again, then set completion. A failure keeps Ready open for retry without adding another Welcome tab. The importer can prepare a browser early for background History and extension installs. During setup, that browser has alpha zero, cannot become key or main, and stays below the dim overlay. Hand-off enables activation and fades its alpha to one below onboarding and above the dim overlay. Onboarding rises 24 points over 0.4 seconds and fades over 0.6 seconds; dim fades over 2.5 seconds. Reduce Motion cross-fades all three over 0.3 seconds. Music fades over 0.8 seconds if still playing. Replay uses the same screens but performs no import, model, preference or default-browser writes.

The hidden-browser guard ends when the final save succeeds. A new browser window opened during the remaining dim fade starts visible and can become key. External URL requests received before Get Started stay in the existing intake queue without opening a browser or Little Open; hand-off marks the intake ready and drains them after the save.
