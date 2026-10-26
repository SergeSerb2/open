# Shutdown record observation (retained)

The first Release shell run at app 8e345dc reached six passing checks, but
attempted to open shutdown-order.json before it existed. A separate actual
Release quit probe confirmed both environment flags, the exact executable,
and all four final phases. The final check waits for the complete
engineShutdownEnd record, then asserts every original ordering condition and
also rejects forced process cleanup. Quit diagnostics retain delivery and
executable observations. This is an observation fix; the original failed
attempt remains a FAIL, not a pass.
