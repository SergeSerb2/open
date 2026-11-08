# Arc first launch and onboarding

Target: Arc 1.170.0 (89123), installed at `/Applications/Arc.app`. The bundle version was read with `/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString'` and `-c 'Print :CFBundleVersion'` on `Contents/Info.plist`.

This is static research, not a recorded first run. The intro timers, window construction, music, and setup step builder are recovered. Authentication reachability, some conditions, and the final browser reveal remain **PARTIAL**. In particular, this build contains “Arc is no longer accepting new signups” and a `signUpsDisabledByFeatureFlag` state. The presence of older setup screens does not prove that a new member can reach them. Evidence: `FUN_10185144c`; SignUp fields at `0x103e2de7c`.

All addresses below belong to the saved `Arc-arm64` program in `ArcMain.gpr`. `FUN_` names are Ghidra address labels. Swift metadata supplies the named types, fields, and cases. Raw receipts remain in the main checkout's git-ignored `.re/handoff/sections/s17/re/` (called **R** below). No media, images, or decompiled code are included here.

| Evidence key | Receipts in R | Method |
|---|---|---|
| I | `intro-decomp-annotated.txt`, `intro-views-decomp-annotated.txt` | Saved-project, read-only decompilation of Welcome, backgrounds, and window controllers |
| S | `setup-launch-decomp-annotated.txt`, `details-decomp-annotated.txt`, `final-trace-decomp-annotated.txt` | Saved-project, read-only decompilation of setup, auth, and launch references |
| T | `swift-onboarding-resolved.json`, `swift-fields-resolved.json`, `swift-summary.txt` | ARM64 Swift field descriptors and enum cases |
| D | `skip-intro-disasm.txt`, `wizard-init-disasm.txt`, `wizard-init-tail-disasm.txt`, `existing-user-disasm.txt`, `launch-guard-disasm.txt`, `background-resource-disasm.txt` | `xcrun llvm-objdump --disassemble --no-show-raw-insn --start-address=… --stop-address=…` |
| A | `ARC_AuthFeature-assetutil.json`, `ARCUI-assetutil.json` | `xcrun assetutil --info <installed bundle>/Contents/Resources/Assets.car`; metadata only |
| M | `media-metadata.json`, `additional-media-metadata.json`, `music-astats.txt`, `music-ebur128.txt`, `demo-scene-times.txt` | `ffprobe`, `sips`, JSON header fields, and numeric-only `ffmpeg` filters |
| X | `arc-strings.txt`, `auth-region.txt`, `welcome-region.txt`, `nm.txt`, `objc.txt`, `swift-and-refs.txt`, `fast-literal-refs.json` | `strings -a`, `nm`, Objective-C metadata, and string-address references |

The Ghidra command used the existing project only:

```sh
source tools/rea-env.sh
export GHIDRA_INSTALL_DIR=/opt/homebrew/opt/ghidra/libexec
GHIDRA_HEADLESS_MAXMEM=16G "$GHIDRA_INSTALL_DIR/support/analyzeHeadless" \
  "$OPEN_GHIDRA_DIR" ArcMain -process Arc-arm64 -noanalysis -readOnly \
  -scriptPath "$HOME/Library/Caches/OpenRE/ghidra-scripts-s17" \
  -postScript RangeDecomp.java "$R/<receipt>.txt" <addresses>
```

The script path has no dot folders. The logs record that read-only changes were discarded. Ghidra 12.2 could not load the saved `AppleSilicon/swift` compiler specification and used its default. Large Swift switch reducers sometimes lose branches. Missing decompiler branches are not evidence that a behavior is absent. Evidence: `*-ghidra.log` in R.

## §1. Sequence overview and clocks

These are scheduled delays, not measured launch latency. **T** starts at Welcome reducer `onAppear`; **F** at foreground appearance; **L** at logo appearance; **W** at window-background setup; **M** at audio playback. Their alignment needs a user capture. User input can also advance Welcome before its timers. Evidence: I, `1018942d4`, `10188be54`, `10188abbc`, `101845440`, `10188fda0`.

| Local time | Event | Evidence and limit |
|---|---|---|
| Launch + unknown | Wizard chooses Welcome, sign-in, or a feature-flag auth route | D, `10183ba00–10183c178`; no launch-to-view delay recovered |
| Window creation | Center a separate 1280 × 800-point unboxing window, with small-screen adjustment | I, `101890820` |
| Overlay + 0–1.5 s | Main-screen black dim layer fades in | I, `1018467f4`; ease-in/ease-out |
| M + 0 | `viewDidLoad` starts Welcome music at player volume 0.3 | I, `10188fc98`, `10188fda0` |
| T + 0 | `introAnimation`; Welcome foreground is empty | T, `103e2f00c`; I, `101889260`, `1018942d4` |
| T + 3.3 s | Move to `sellIntro` | I, `1018942d4`, delay `0xce4` milliseconds |
| L + 1.0 s | Logo becomes visible, reaches scale 1 and vertical offset 0 | I, `10188abbc`, `10188ae74` |
| L + 2.0 s | Logo starts a 1.25-second linear move toward vertical offset −20 | I, `10188b298` |
| L + 3.15 s | Logo begins its exit spring | I, `10188b698`; 1 + 1 + 1.15-second callbacks |
| F + 4.0 s | Set headline to “A browser for you.” | I, `10188a030`, `10188a31c` |
| W + 4.5 s | Normal path finalizes window settings with a 1-second transition | I, `101845440`, `101845730`; immediate auth path also exists |
| F + 5.6 s | Reveal the progression button | I, `10188a31c`, `10188a644`; 4 + 1.6 seconds |
| T + 9.8 s | Move to `sellCompleted` | I, `1018942d4`; 3.3 + 6.5 seconds |
| Click + 0.2 s | Intro button sends `nextPressed` | I, `10188c04c`, `10188c300` |
| User-paced | Welcome completion leads into auth; setup is conditional | T, wizard stages `103e2d620`; S, step builder `101811c04` |
| M + 15–21.336 s | Encoded music falls toward silence and reaches its file end | M, `music-astats.txt`, `media-metadata.json`; early-stop policy unknown |
| User-paced | Final setup button says “Get Started” | S, `10186c7dc`; step `finished` |
| Handoff + unknown | Manager closes unboxing when visibility state becomes false | I, `101891cc0`; browser reveal is unresolved |

**Deduction:** if F and L start at entry to `sellIntro`, the headline is near T + 7.3 s and the button near T + 8.9 s. These are not confirmed wall-clock beats. Do not align the 18.27-second demo file or the 21.336-second music file with T without a capture.

## §2. Window and background

### Window construction

`UnboxingWindowController` creates `AuthFeature.UnboxingWindow` with content size **1280 × 800 points**. If the main screen is both at most 1280 points wide and at most 800 points high, it uses the screen dimensions minus **72 points** in each axis. It uses screen frame dimensions, not a measured video resolution. Evidence: I, `101890820`, `initWithContentRect:styleMask:backing:defer:`.

The style mask is **0x8007**: titled, closable, miniaturizable, and full-size content view. The resizable bit is absent. Backing is buffered (2); defer is false. The title is localized “Sign In to Arc”, but title visibility is hidden and the titlebar is transparent. The window is clear and nonopaque. It starts without a shadow, movement, background dragging, or window tabbing. It is centered. Its three standard window buttons are hidden initially. Evidence: I, `101890820`, `1018912e8`.

The presentation function creates the controller and calls `makeKeyAndOrderFront:`. A separate manager owns the controller while its visibility state is true. This proves a separate onboarding window. It does not establish whether a browser window already exists behind it. No native full-screen transition was proved. Evidence: I, `10183f2cc`, `101891cc0`.

### Dimming and layers

A second window covers the **main screen**. Its style mask is 0x8000. It is clear and is added as a child below the unboxing window (order −1). Its black layer has alpha **0.85**. The layer fades from 0 to 1 over **1.5 seconds**, using ease-in/ease-out. This screen-sized dimmer is not proof that the unboxing window enters native full screen. Evidence: I, `1018467f4`.

The background has `none`, `sellIntro`, and `auth` configurations. Selection depends on wizard and Welcome state. `WindowBackgroundView` stores grain and mask radii, orb opacity/scale/rotation, blob scale, and background opacity. A static grain layer uses opacity **0.4**; an animated-grain path also exists. Exact composition and visible appearance still need capture. Evidence: T, `103e2e550`, `103e2e658`; I, `1018452e0`, `10183fa38`.

The background-video path resolves ARCUI's `background` resource; the orb path resolves `orb`. `AnimatedVideoView` uses `AVPlayerLooper`. A `demo` QuickTime resource is used by the setup/theme split UI. It is not proved to be the full Welcome intro. Evidence: I, `101844ec4 → 100a71b5c`, `1018404bc → 100a71bb8`, `1018442b0`, `10184bbb4`; D, resource initializers `100a71b68`, `100a71bc4`.

Normal background setup waits **4.5 seconds** before `finalizedWindowSettings`; another path uses zero delay. The normal transition uses SwiftUI ease-in/ease-out **1 second** and `NSAnimationContext` **1 second**. Settings bits enable movement and shadow. Background callbacks also contain ease-in/ease-out **0.75 seconds delayed 3.7**, ease-out **1 second**, linear **6 seconds**, and ease-in/ease-out **1 second delayed 3.75**. Their exact layer-to-property mapping is incomplete. Evidence: I, `101845440`, `101845730`, `1018496f8`, `1018499c0`.

### Resource facts, not copied assets

| Resource or color | Metadata fact | Evidence |
|---|---|---|
| Auth `Accent`, `WindowBackground`, `ButtonBackground` | sRGB **#3139FB**, alpha 1 | A, named color records |
| Auth `CardBackground` | Light **#E6E7FF**; dark **#8C8DAB** | A, appearance-specific records |
| Auth `SplitViewLeftBackground` | Light white; dark **#1E1E1E** | A |
| Auth `Title` | Light black; dark white | A |
| Auth `Logo` | Light **#3139FB**; dark **#6CBADA** | A |
| Auth `WelcomeLogo` | Preserved vector; nominal 120 × 101 at 1× and 240 × 202 at 2× | A; I, `10188a818` selects this name |
| Auth catalog | `grain`, `LogoWithBackdrop`, `ContentIntro1`, `ContentIntro2` exist | A; catalog names do not prove their screen order |
| ARCUI `glow` | Vector rendition; 81 × 27 at 1×, 162 × 54 at 2× | A, `ARCUI-assetutil.json`; exact intro use unresolved |
| `static-bg.png` | 2880 × 1800 pixels | M, `sips -g pixelWidth -g pixelHeight` on installed file |
| ARCUI `background.mp4` | 8 s; H.264, 100 × 100, 30 fps | M, `ffprobe -show_streams -show_format -of json` |
| ARCUI `orb.mp4` | 6 s; H.264, 100 × 100, 30 fps | M, same command |
| ARCUI `logo-wave.json` | 225 × 225; 60 fps; frames 0–180, or 3 s | M, numeric `w/h/fr/ip/op` header fields only |
| Auth `demo.mov` | 18.266667 s; HEVC, 1920 × 1280, 30 fps, 548 frames; no audio stream | M, `media-metadata.json` |

The Welcome logo's link to `logo-wave.json` is **unproved**. The recovered view explicitly names `WelcomeLogo`. No `glow-video` or `grain-no-blend` placement is established by this trace. A resource name alone cannot establish a visible layer or animation.

## §3. Intro stages and interaction

Welcome has one `step` field. Its three cases are **`introAnimation` → `sellIntro` → `sellCompleted`**. Actions are `_moveToNextStep`, `onAppear`, `nextPressed`, `completed`, and `_reset`. Evidence: T, `103e2eff0`, `103e2f00c`, `103e2efa4`.

On appearance at step 0, the reducer schedules step 1 after **3300 ms**. Entry to step 1 schedules step 2 after **6500 ms**. `nextPressed` can move 0→1 and 1→2. At step 2 it emits completion and sets `shouldSkipUnboxingVideo=true`. `_reset` restores step 0 and emits `onAppear`. No automatic completion timer after step 2 was recovered. Evidence: I, `1018942d4`; T, settings enum `103de34ec`, ordinal 90 / **0x5a**.

Step 0 returns an empty Welcome foreground. Nonzero steps construct the logo, headline, and progression button. This does not mean that the background is empty at step 0. Evidence: I, `101889260`.

| Local logo time | Target values and animation | Evidence (I) |
|---|---|---|
| L + 0 | Opacity 0, blur 25, scale 0.5, vertical offset +250; spring response 1.25, damping fraction 0.9, blend 0 | `10188bd48` |
| L + 1.0 s | Opacity 1, blur **1**, scale 1, offset 0; schedules another 1 s | `10188abbc`, `10188ae74` |
| L + 2.0 s | Linear animation 1.25 s toward vertical offset −20; next callback after 1.15 s | `10188b298` |
| L + 3.15 s | Exit spring response 1.25, damping 0.9, blend 0; opacity target **−1**, blur 25, scale 0.5, offset −350 | `10188b698`; values are code targets, not measured rendered pixels |

The headline starts empty. Four seconds after foreground appearance it becomes **“A browser for you.”** After another **1.6 seconds**, the button's targets become opacity 1, offset 0, and blur 0. Its initial targets are opacity 0, offset +125, and blur 30. The button uses a spring with response **1.25**, damping **0.9**, and blend **0**. Evidence: I, `10188b88c`, `10188be54`, `10188a030`, `10188a31c`, `10188a644`, `101889610`.

The intro progression button has the default action keyboard shortcut (**Return**). Its callback waits **0.2 seconds**, then sends `nextPressed` in a transaction. The caption was not resolved. “Get Started” is confirmed only for final Setup below; it must not be assigned to this button without more evidence. Evidence: I, `101889610`, `10188c04c`, `10188c300`.

`shouldSkipUnboxingVideo` skips the **Welcome stage**, not just `demo.mov`. Launch code reads preference 0x5a and passes it to the wizard constructor. In the ordinary constructor branch, false initializes Welcome step 0; true initializes sign-in (wizard stage 2). An earlier feature-flag branch can choose sign-up. QA copy also says that skip-intro goes directly to sign-in, where account creation is available. Evidence: D, `1017cf91c`, `1017cfb44`, `10183ba00`, `10183c05c–10183c178`; X, `arc-strings.txt:111062`.

## §4. Music facts and other sounds

`UnboxingViewController.viewDidLoad` adds its hosting view, then calls `playBackgroundMusic()`. That routine creates an `AVAudioPlayer` only when the wizard stage is Welcome. It loads `intro-music` as `audio/mpeg`, sets volume **0.3**, and calls `play`. Failure copy is “Could not play audio file during onboarding.” Evidence: I, `10188fc98`, `10188fda0`; X, that string and controller symbols.

The queried controller code did not reveal a loop-count setter, explicit player fade, preference-mute check, or explicit stop call. This is a bounded negative result. It does not prove that other code cannot stop playback. Early dismissal, stage changes, and controller teardown need capture or a complete ownership trace. Evidence: I, controller range `10188fc98–101890820`.

The installed MP3 lasts **21.336 seconds**, stereo **48 kHz**, **320 kb/s**. Whole-file integrated loudness is **−9.3 LUFS**, loudness range **11.8 LU**, and true peak **−0.9 dBFS**. These are decoded-file measurements before the app's 0.3 player gain, system volume, and output route. Evidence: M, `media-metadata.json`, final summary in `music-ebur128.txt`.

The table uses one-second decoded windows. RMS describes average signal level; sample peak is the largest decoded sample in that window. Both are in dBFS. The last window is partial. Evidence: M, `music-astats.txt`, `Overall.RMS_level` and `Overall.Peak_level`.

| Seconds from file start | RMS dBFS | Sample peak dBFS |
|---|---:|---:|
| 0–1 | −31.14 | −13.61 |
| 1–2 | −22.58 | −8.92 |
| 2–3 | −20.62 | −8.19 |
| 3–4 | −19.09 | −6.27 |
| 4–5 | −14.91 | −2.64 |
| 5–6 | −11.05 | −0.99 |
| 6–7 | −10.49 | −0.86 |
| 7–8 | −10.18 | −0.86 |
| 8–9 | −10.05 | −0.89 |
| 9–10 | −10.33 | −0.92 |
| 10–11 | −10.31 | −0.92 |
| 11–12 | −10.09 | −0.92 |
| 12–13 | −10.21 | −0.95 |
| 13–14 | −9.91 | −0.98 |
| 14–15 | −10.11 | −0.99 |
| 15–16 | −11.50 | −1.25 |
| 16–17 | −15.99 | −4.25 |
| 17–18 | −22.96 | −10.27 |
| 18–19 | −32.43 | −18.46 |
| 19–20 | −48.00 | −33.12 |
| 20–21 | −73.38 | −55.80 |
| 21–21.336 | −104.48 | −91.33 |

The envelope supports a rise over about **0–5 s**, a broad loud section over **5–15 s**, then a strong fall over **15–21 s**. The largest one-second RMS is at 13–14 s; the largest sample peaks occur at 6–8 s. This describes the encoded signal, not a proved player fade. No reliable tempo, musical key, instrument description, or code-linked beat synchronization was established. Evidence: table above; I, `10188fda0` starts playback without a recovered cue map.

Numeric-only reproduction, reading installed resources directly:

```sh
ffprobe -v error -show_streams -show_format -of json "$music"
ffmpeg -hide_banner -nostats -i "$music" \
  -af 'asetnsamples=n=48000:p=0,astats=metadata=1:reset=1,ametadata=print:file=-' \
  -f null -
ffmpeg -hide_banner -nostats -i "$music" -af ebur128=peak=true -f null -
ffmpeg -hide_banner -nostats -i "$demo" \
  -vf "select='gt(scene,0.15)',showinfo" -an -f null -
```

Here `$music` and `$demo` name `intro-music.mp3` and `demo.mov` in the installed `ARC_AuthFeature.bundle/Contents/Resources/`. Output is text only. The demo scene-score threshold 0.15 yielded one selected timestamp, **1.0 s**. It supplies no visual scene identity or storyboard. Evidence: M, `demo-scene-times.txt`.

For other sounds, `SoundEffectClient` exposes `isEnabled`, `setIsEnabled`, `preload`, and `play`. The recovered `SoundEffects.SoundEffect` metadata has `capture`. The preference `playUserInterfaceSoundsDisabled` exists (ordinal **0x62**). **No onboarding `SoundEffectClient` event was proved.** Music uses a direct `AVAudioPlayer`; its link to that preference remains unresolved. Evidence: T, `103e380ec`, `103e380d0`, `103de34ec`; I, `10188fda0`.

## §5. Authentication and setup steps

### Wizard and auth branches

Wizard stage declarations are `welcome`, `syncSetup`, `signIn`, `signUp`, and `setup`. This is enum order, not a linear walkthrough. Auth, sync migration, member status, and flags select branches. Evidence: T, `103e2d620`; S, `10183ba00` and `AuthReducer` trace.

Sign-in has email, password, password reveal, a modal, and `forceOnboardingFlow`. Its actions include continue, account creation, forgotten password, and Escape. Copy includes “Welcome back to Arc.”, “Create an account”, and “Forgot your password”. Sign-up state has email, name, password, terms, and `signUpsDisabledByFeatureFlag`. Its password copy asks for at least eight characters with a letter and a number; its name helper permits a nickname. Evidence: T, `103e2dbf8`, `103e2dc68`, `103e2de7c`, `103e2df34`; X, `auth-region.txt`.

This version can instead show **“Arc is no longer accepting new signups”**, with Dia download/copy-link actions. The exact live flag and server response were not queried. Account creation cannot be treated as a guaranteed working route in this build. Evidence: S, `10185144c`; T, `downloadDiaPressed`, `copyDiaLinkPressed`, `signUpsDisabled`.

Sync setup has `enableSync`, next, skip, and completion actions. Copy covers recovery phrases, a new recovery card, migration in progress, starting fresh, and doing setup later in Settings. The full branch order and defaults were not resolved. Evidence: T, `103e2e2d4`, `103e2e2f0`; X, `auth-region.txt`.

### Actual setup order

Step declarations alone put theme before Favorites. The **builder** supplies a different conditional sequence:

`importSource? → importFromSafari? → topApps? (early) → importBookmarks? → safariPasswordImportOptions? → importSafariKeychain? → topApps? (late) → spaceStyleEditor → adBlockers? → arcMax? → defaultBrowser → finished`

The two Favorites placements have mutually conditioned branches. Omitted entries use sentinel **0xb**, then are filtered. Configuration updates preserve progress. Exact unnamed flags and the Favorites-placement predicate remain unresolved. Evidence: S, `101811c04`, `101811698`; T, step cases `103e2daac`.

| Step | What it asks or shows | Choices, conditions, and evidence |
|---|---|---|
| `importSource` | “Get us up\nto speed.”; import from another browser | Browser/source selection. Conditional. S, `10180fd08`, `10180fdb8`, `101811c04`; T, `sources`, `browserSelection` |
| `importFromSafari` | Safari import | Safari source discriminant 6 and available profiles affect this branch. Full Disk Access copy explains Safari-history access and says it can be removed afterwards. S, `10180ff10`, `10181011c`, `101811c04` |
| `importBookmarks` | Bookmark import recommendation with a browser-name placeholder | Conditional import branch. S, `1018101d0`, `1018102a0`, `101811c04` |
| `safariPasswordImportOptions` | “Autofill your passwords.” | “Import Passwords from Safari” or “Add iCloud Passwords Extension”; extension marked “Recommended”. OS ≥14 participates in this branch. S, `10180ffc0`, `101810070`, `101870c28`, `101811c04` |
| `importSafariKeychain` | Safari/Keychain password import branch | Conditional after Safari options; exact prompt and back/skip behavior unresolved. T, step `103e2daac`; S, `101811c04` |
| `topApps` | “Choose the apps you use most.”; choose sidebar Favorites | Selectable apps; can occur early or late. Exact initial selection unresolved. S, `10180f634`, `10180f6e4`; T, `selectedTopApps`, `topAppTapped` |
| `spaceStyleEditor` | “Pick a color, any color”; “Add some flair with a theme.” | Theme editing and a random action. S, `10180f4d8`, `10180f588`; T, `_spaceStyleEditor`, `randomTapped` |
| `adBlockers` | “No more ads or trackers.” | Included/optional built-in blocker copy; “Use all imported ad blockers”. Native-blocker capability and a flag gate the step. S, `10180f798`, `10180f848`, `10180f8f4`, `101811c04`; X, label |
| `arcMax` | Arc Max explanation and privacy copy | `supportsArcMax` gates it; primary button “Enable Arc Max”. Opt-in initializes false. S, `10180f9a0` onward, `101810f24`, `101811c04`, `10186c7dc` |
| `defaultBrowser` | “Go steady with Arc?” | Choices include “, still exploring my options.” and “, make Arc default.” Exact initial choice unresolved. S, `1018103e0`, `101810490`; X, suffix strings |
| `finished` | Arc Card; “Welcome to Arc, %@” | Personalized final card; primary button “Get Started”. S, `10180f3ac`, `10181053c`, `10186c7dc` |

`Setup.State` stores all steps, mode, feature flags, importer state, theme state, selected apps, member-card configuration, modal, browser selection, capability flags, and step index. Initialization sets step index **0**, no presented modal, and Max opt-in **false**. The iCloud-extension choice starts **unset** (tri-state value 2). Default-browser and initial-app values come from helpers that were not resolved. Evidence: T, `103e2d9dc`; S, `101810f24`.

Existing-user mode 2 is not the ordinary new-member setup path: its configuration assertion says that updating steps while an existing user signs in “shouldn't happen”. Separate auth logs state “Bypassing any wizard steps because the member is pre-existing” and “Keeping all ad blockers to not interrupt existing members.” The exact enclosing member predicate remains incomplete. Evidence: S, `101811c04`; D, `1017d1bc8`, `1017d1cf0`.

### Progress, back, skip, and keys

Setup's primary label is **“Enable Arc Max”** at step 8, **“Get Started”** at step 10, and **“Next”** elsewhere. It has a default Return shortcut and an enabled-state binding. The enabled predicate was not decoded, so some steps may block progress. Evidence: S, `10186c7dc`, `10186b924`, getter `101812638`.

`ProgressionButton` supports primary/secondary styles and back/forward directions. Enabled press scales to **0.98**; enabled hover scales to **1.02**; idle/disabled scale is **1**. Its spring has response **0.3**, damping **0.45**, and blend **0**. Evidence: T, `103e2e90c`, `103e2e994`, `103e2e9bc`; S, `10186237c`.

`NewSetupView.TransitionDirection` is back/forward. Title and description use asymmetric offset transitions: title spring **0.4/0.8/0**, description spring **0.5/0.8/0** (response/damping/blend). Footnotes use an opacity transition, ease-in/ease-out **0.12 s**. Optional messaging also uses spring **0.5/0.8/0**. Offset distances remain unresolved. Evidence: T, `103e2ebfc`; S, `10186cc24`, `10186b4f8`.

Skip-label variants are **“Do this later”**, **“Skip for now”**, **“Not now”**, custom, and none. Actions include `nextButtonTapped(isSkipped)`, `previousButtonTapped`, `skipTapped`, `onPressEscape`, `finishImportingButtonTapped`, and modal-background tap. This proves affordances and routed actions, not a complete per-step skip/back matrix. That matrix, Escape results, and focus traversal need capture or more reducer tracing. Evidence: T, `103e2d990`, `103e2d804`; S, `10186bd64`, callback `1018734f8`.

## §6. End of unboxing and first browser window

When the unboxing visibility state becomes false, the manager marks the close as manual, calls `close`, and clears its controller. `closeCurrentItem` checks auth state and can emit a reducer action instead of closing directly. The complete Cmd+W policy remains unresolved. Evidence: I, `101891cc0`, `1018914b0 → 1017ce27c`.

There is an overlay fade from **1 to 0 over 2.5 s**, with ease-in/ease-out. Another window-layer routine has a **0.4 s** position animation and **0.6 s** opacity fade. Their exact triggers and animated key paths were not fully mapped. They do not establish a browser-frame morph or a specific final reveal. Evidence: I, `1018477e4`, `101847f70`.

The binary has browser context type **`unboxing`**, `unboxing_frame_id`, `afterUnboxing`, `onWillEnterAppAsNewUser`, and the public URL **`https://arc.net/welcome-to-arc`**. This supports an in-browser onboarding handoff, but does not prove which tab is selected first. The frame-ID references occur at `1018198e8` and `10181a54c`; the containing reducer switch is incomplete. Evidence: X, exact strings and `swift-and-refs.txt`; S, containing reducer `1018193a8`.

The sidebar welcome tab type has `legacy` and `modernGetStarted` cases. `WelcomeToArcCellState` and native cell symbols exist. The first selected variant and its dismissal policy were not recovered. Evidence: T, `103dfceb8`; X, `WelcomeToArcCellState` / `WelcomeToArcCellView` symbols.

Arc101 has steps `pinTabs`, `spaces`, `splitView`, and `newTab`. Declaration order does not establish playlist order. Its state stores active/hovered/played steps, playlist restart, video ID, hover delay, playing state, reveal flags, an onboarding timer, and a keyboard-shortcut tracker. Actions include step click, appear, shortcuts education, and Help Center. Analytics records hover/tap interaction types. Evidence: T, `103e472e0`, `103e47348`, `103e47790`, `103e112f4`, `103e11334`.

Copy includes **“Here are the basics.”**, **“Learn Essential Shortcuts”**, and **“Help & Resources”**. Four bundled videos cover new tab, pinning, Space swiping, and Split View. Each is **8.5 s**, HEVC **1920 × 1200**, **60 fps**, with no audio stream. This is resource duration, not a proved auto-advance interval. Evidence: X, `welcome-region.txt`; M, `ARC_WelcomeToArcFeature.bundle` entries in `media-metadata.json`.

## §7. Returning users and launch guards

The preference enum includes **`hasLaunchedBefore`** (ordinal 2), **`shouldSkipUnboxingVideo`** (90), and **`playUserInterfaceSoundsDisabled`** (98). Only the intro-skip gate was traced through construction (§3). The exact read/write points for `hasLaunchedBefore`, interrupted first-run resume, and fully signed-in launch remain unresolved. Evidence: T, `103de34ec`; D, skip-intro and wizard-constructor receipts.

`forceOnboardingFlow`, “Force unboxing flow”, and “Onboarding QA Tool” exist. QA copy describes an onboarding sandbox/reset path. These are evidence of diagnostic paths, not instructions to run them against user data. No QA path was executed. Evidence: T, SignIn fields; X, `arc-strings.txt:111060–111062` and exact labels.

Launch telemetry names **`app_launch_to_first_window`** and **`app_launched_to_first_window_appeared`** exist. `finishedOnboarding` appears in session paths at `1017cd664` and `1017cdbf4`. `launchInProgressSentinel` is a storage filename enum case. The queried `100d8d888`, `100e77e50`, and `10218d5b0` family format/hash that enum; they do not prove a launch guard. **No numeric launch timeout, minimum intro hold, or first-window deadline was recovered.** Evidence: X, telemetry strings; S/D, listed addresses and `launch-guard-disasm.txt`.

## §8. Accessibility and Reduce Motion

| View or path | Recovered behavior | Evidence |
|---|---|---|
| Grain | Static grain remains; animated-grain branch requires Reduce Motion off | I, `10183fa38` |
| Background video | `play()` is called only with Reduce Motion off in this path | I, `101844380`; still-frame appearance unresolved |
| Continuous transform | Infinite 32-second animation requires Reduce Motion off | I, `101844660` |
| Setup appearance | Reads `NSWorkspace.accessibilityDisplayShouldReduceMotion`; stores its inverse in local SwiftUI state | S, `1018719e4` |

**Deduction:** the last state write likely gates confetti, since `NewSetupView` has a `_confetti` field. The exact field-offset mapping was not proved. No universal Reduce Motion guard was established for the Welcome logo/button springs, dim-window fades, all setup transitions, or music. VoiceOver labels, contrast, focus order, and behavior when the setting changes mid-flow remain unverified. Evidence: T, `NewSetupView` fields; S, `1018719e4`; bounded I/S trace above.

## §9. Questions for a user capture

Capture must be user-driven. A recording should identify the exact Arc build, member status, flag-dependent route, Reduce Motion setting, and whether intro-skip was already set. Static evidence above cannot settle these points:

1. From process launch, when do the first visible window and the dimmer appear? Is any browser window behind them? Does the intro use native full screen on any display?
2. How do T, F, L, W, and M align? Does the logo use a wave animation? What do the orb, glow, grain, and demo show at each beat?
3. What is the intro button caption? When can Return or a click first act? Can rapid input skip stages while timers remain pending?
4. Does music continue through auth and setup? Does it stop, fade, or restart on skip, back, close, or completion? Does the UI-sound setting mute it? Are there other sound events?
5. In build 89123, can a new member pass the sign-up gate? How do existing-member, sync recovery, migration, forced-onboarding, and offline/error routes differ?
6. What is the exact setup list for each browser and Safari/OS/capability combination? Which Favorites placement is chosen? What are the initial app, default-browser, and blocker selections?
7. For each step, which buttons appear, when is Next enabled, what does Skip save, and where do Back/Escape/Return go? How do import failures and permission denial recover?
8. At “Get Started”, does the existing window change frame, fade, or close before a browser opens? Which window, Space, tab, welcome-cell variant, or Arc101 card appears first?
9. What are the Arc101 initial step, auto-play order, hover delay, repeat policy, shortcut tracking, and welcome-cell dismissal rules?
10. On a second launch, after a partial first run, and with Reduce Motion on, which states resume and which animations remain? What does VoiceOver announce?

No screen recording, real auth flow, live feature-flag query, or launch-latency measurement was performed. These gaps remain separate from the confirmed static and numeric findings.
