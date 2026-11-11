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
