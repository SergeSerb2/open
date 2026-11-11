# Historical download Retry loses its terminal callback

Historical Retry is a user-reachable v1 blocker. It opens the saved source URL
under the recorded Profile. An attachment in that new Chrome tab can finish its
bytes after Chromium closes the initial tab, but Open never receives the terminal
download update. The Library row then stays in progress.

The fix belongs to the engine lane. The callback owner must have the Profile's
lifetime rather than the originating browser's lifetime. The lead approved one
temporary gate deferral on 2026-11-10; this does not establish working Retry.
There is no separate App download path or workaround.

## Real-App evidence

Two M1 socket-driven runs at source `3666eabd576084ca5c7ded1b30670addfa3e5060`
reproduced the same failure: a focused history flow and the full Downloads suite.
They used the recorded engine distribution with SHA-256
`891c23539c5638e89a87195e34780fec2b478bfa242b6775bfd38a334f008e67`.
The full run has 85 passing rows and three failed rows: `history_retry`, the
independent `idle_zero` observation, and the suite error caused by Retry.
Both runs completed owned-process cleanup, with no new crash or system dialog.

The Retry receipt records this order:

1. The native Library menu invokes Retry for a saved row in the second Profile.
2. Open creates a Chrome tab and the engine selects a download destination.
3. The transfer reports 131072 of 131072 bytes in the correct Profile.
4. The new initial tab is destroyed. No retained detached page remains.
5. No terminal callback arrives. The transfer stays `inProgress`, so the existing
   `history_retry` predicate fails after its bounded wait.

Private evidence, relative to the Plan A worktree:

- `.re/gate-health/step3/m1-resume-1900-copy/.re/gate-health/step3-resume-1900/downloads-history/results-downloads-debug.json`
- `.re/gate-health/step3/m1-resume-1900-copy/.re/gate-health/step3-resume-1900/downloads-full/results-downloads-debug.json`

These are synthetic local HTTP transfers. No personal download data was used.

## Source boundary

Read-only source inspection of the pinned CEF embedding layer proves where the
notification ends. Paths are relative to the shared Chromium source root:

- `cef/libcef/browser/download_manager_delegate_impl.cc:331-344`,
  `CefDownloadManagerDelegateImpl::OnDownloadUpdated`, obtains the associated
  browser and only calls its download handler when that browser still exists.
- The same file at `483-492`, `OnBrowserDestroyed`, clears that association. Its
  comment states that the download continues silently until it completes or the
  browser context is destroyed.

`App/PageChrome/DownloadsCenter.swift`, `retry(_:)`, uses
`settingsPresenter.openURL(_:profileID:)`. This creates the initial attachment
tab whose close reaches that CEF boundary. Retaining only a weak Profile in
`OEClient` cannot restore a callback that CEF no longer sends. That experiment
was removed after the failed real-App proof.

The engine lane must keep terminal updates safe after tab close, preserve Profile
attribution, and stop delivery after Profile destruction. Run the unchanged Retry
predicate against the repaired engine, as well as close-during-transfer and
Profile-retirement flows. Remove the exact `downloads/history_retry` deferral
when that engine patch lands. Other Downloads failures remain gate failures.

## Source preparation, 2026-11-11

At the E1–E3 audit checkpoint,
`Engine/fork/patches/cef/1001-download-handler-lifetime.patch` was prepared
but disabled in the CEF series. The lead's E4 ruling on 2026-11-11 enables it
for source application and CEF API generation in the same official engine
build. Compilation still needs the explicit build-window approval. Source
preparation does not establish end-to-end acceptance; the
`downloads/history_retry` deferral remains.

The proposed route retains each associated download's original handler in
`CefDownloadManagerDelegateImpl`, whose owner is the Profile's DownloadManager.
Browser destruction clears the raw browser pointer, as before. Later updates
use the retained handler with a null browser. Item destruction releases the
handler; `ResetManager` invalidates callback handles and removes every item.
The existing manager-owned Web Store exception in patch 0305 stays unchanged.

The public `OnDownloadUpdated` annotation must permit a null browser. This is
part of patch 1001. Both generated wrapper directions currently reject a null
browser (`cef/libcef_dll/cpptoc/download_handler_cpptoc.cc`,
`cef/libcef_dll/ctocpp/download_handler_ctocpp.cc`). After build approval,
`engine-apply` detects the public-header patch and regenerates the CEF API;
do not edit generated wrappers by hand.

The OpenEngine companion must also preserve the original context with a weak
reference in `OEClient`. Its existing `OnDownloadUpdated` fallback chooses
Default when the page is gone, which would misattribute a named Profile's
terminal update. Capture `content.context` when creating the client, retain no
page or Profile, and reject delivery when that context is absent or closing.
The prepared companion is delivered with the private engine audit as
`E-download-openengine-companion.patch`; it is not applied to the App sources.
Enabling only the CEF patch is not a complete fix.

The source-only checks pass against pinned Chromium `d0c02bfad08` and CEF
`4fa4ab516da`: `git -C <src>/cef apply -p2 --check <patch-1001>` and
`git apply --check <OpenEngine-companion>`. Raw receipts are in the engine
lane's `.re/engine-audit/13-patch-check.txt` and
`.re/engine-audit/15-companion-check.txt`. No tree writer ran.

After approval, run the unchanged `downloads/history_retry` predicate, normal
and close-during-transfer downloads, named-Profile attribution, Profile
retirement, and the Web Store download flow. No fix or performance gain is
claimed from source preparation alone.
