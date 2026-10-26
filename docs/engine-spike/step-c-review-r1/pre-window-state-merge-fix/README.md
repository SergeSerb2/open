# Initial merge failure (retained)

All six invocations used the first merged binaries built at `4e6206e`.
`window-state` had two appActive dictionary keys after merging #104 and Step C;
Swift trapped on the first such request. These are ordinary FAIL attempts,
not foreground interruptions. The later sourceHead fields reflect the source
checkout when each command ended; the source was committed to `632f13e` during
the Release commands, but those binaries still came from `4e6206e`.

The fix removes the duplicate key, rebuilds both configurations, and reruns the
same checks. Receipts in the parent directory are from those rebuilt inputs.
