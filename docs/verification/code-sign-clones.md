# Code-sign clone cache

Fork 0106 caches one code-sign clone for each install path in
`~/Library/Application Support/Open/CodeSignClones`. The directory name is the
uppercase SHA256 of the app bundle path, not a content hash. `identity` validates
the executable; a shared `flock` on `lease` protects a clone used by a live process.
See `Engine/fork/src/chrome/browser/mac/open_code_sign_clone.cc`.

After the first content paint, the shell asks OpenEngine to prune obsolete
clones. Empty native windows and onboarding start maintenance after their native
first frame and a two-second delay. Pages without paint entries use the existing
two-second startup fallback. All enumeration and deletion run on a utility worker.
Content launches dispatch deletion only after the paint callback.

The worker keeps the current install-path directory. For another hash directory,
it opens the private lease without following symlinks, takes a nonblocking
exclusive lock, and verifies both the lease inode and directory inode against
their names. A busy lease is left alone. An unleased directory is atomically
renamed to a private retirement name, then removed while the exclusive lease
stays held. A later launch retries interrupted retirement names and incomplete
directories. The scan repeats after removals, because directory mutation can
change enumeration cursors. Names are streamed; no list grows with cache size.
Symlinks are unlinked during recursive removal, never followed. Invalid ownership,
permissions, or lease types fail closed and are retried on later launches.

Deletion ships with the companion fork 0106 producer guard, which checks its
lease inode after lock acquisition and conversion. This covers a launch paused between opening a lease and locking it:
it must use the ordinary temporary clone if cleanup retired that lease in the
meantime. The engine owner qualifies and adopts this companion guard separately.

## Real-App regression

Build an automation Release app through `heavy.sh`, then run on a disposable Mac:

```sh
~/Library/Caches/OpenRE/scripts/heavy.sh \
  /usr/bin/lockf -k /tmp/open-onscreen-e2e.lock \
  python3 tools/e2e/code_sign_clones.py \
  --bundle /absolute/path/Open.app --out .re/clones/acceptance
```

The harness uses private profiles and the shipping Chrome runtime. It seeds three
full obsolete clone directories, an interrupted retirement, an incomplete clone,
a shared lease held by the live harness process, and symlink sentinels. It checks
automatic launch cleanup, current-clone reuse, live-lease preservation and removal
on the next launch after release, blank-page and empty-native-window maintenance,
and zero surviving owned processes/windows. It records five process-start-to-paint
launches and proves cleanup scheduling follows paint. `--baseline` records the old
leak; `--compare <baseline-report.json>` checks the matched five-launch median
against a 1.10 maximum factor. Rental measurements are separate from physical-Mac
release timing budgets. Raw logs and paths stay in ignored `.re/` storage.
