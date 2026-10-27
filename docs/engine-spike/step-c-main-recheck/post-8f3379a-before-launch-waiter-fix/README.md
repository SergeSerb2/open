# Partial matrix before launcher-readiness fix

Source `4a6fe77`, main `8f3379a`. Both app builds and all 19 verifier rows passed through heavy.sh (sidebar429/features258). The second Debug window invocation failed at persistence relaunch when the LaunchServices waiter could not obtain a PID. This ordinary FAIL is preserved. The supervisor finished its current suite then stopped for a harness fix. No Release or complete three-run acceptance is claimed for this phase. See launch-waiter-failure.json.
