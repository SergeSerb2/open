# Main / PR #93 merge follow-up

Merged origin/main `6f88195bf1c069f7e2503a3db7355a35a6c49e90` (Extensions P2) into #96 with a merge commit. The only conflict was in `docs/followups.md`; both the Site Control global-off calibration note and the new Extensions follow-ups were kept. The merge brings the upstream Engine/OpenEngine/OpenWeb/App toolbar and popup implementation, fixtures, e2e support, and docs. No Site Control product or harness source, Package target, or verification command changed.

Per the lead's 2026-10-26 22:48 ruling, the preceding 22/22 full gate remains valid for unchanged parts. The post-merge focused build and `sitecontrol-render` gate both PASS. See the summary and complete focused check log here. The quiet-M5 <8 ms product check remains with the lead.
