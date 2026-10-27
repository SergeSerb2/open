# Code review r1 regression evidence

The identical composed native lifecycle harness was compiled against frozen
`3504776` production code and the fixes. All 24 OpenSidebar files in the old
package match the frozen commit byte for byte. Both builds use identical
`Checks.swift` and `MediaLifecycleChecks.swift`; the receipt records their hashes.
All hosts stay offscreen at (−20000, −20000). These are real store/view/native
layer flows, with synthetic media hosts, not isolated unit tests.

- Old code: **12 PASS, 18 FAIL**. C1, C2 and C4 gates fail.
- Fixed focused lifecycle: **30 PASS, 0 FAIL**.
- Existing focused motion suite: **49 PASS, 0 FAIL** after the code fixes.
- Full final sidebar flow: **558 PASS, 0 FAIL**, including both focused suites.
- C1 checks hover in/out and fourth-source publication with no height change.
  The fourth source uses a pre-existing tab, so the check isolates media motion
  from the unrelated new-tab row insertion fade.
- C2 checks collapsed/expanded stacks, both motion modes, every drag step and
  final model/presentation widths. Starting a drag during expansion cancels
  existing media motion too.
- C3 checks expanded add/remove; MC6/MC8/MC10/MC15 assertions live in the full flow.
- C4 hides within the 0.3 s collapse delay and shows without another pointer event.
- C5 remains a manual user check. No tracking-area behavior change was made.

```sh
Packages/OpenKit/.build/release/sidebar-render check --media-lifecycle-only
```

[Old failures](old-lifecycle-check.log), [fixed lifecycle](fixed-lifecycle-check.log),
[existing motion](fixed-motion-check.log), [provenance and hashes](negative-control.json),
[full final sidebar flow](../sidebar-check.log).

| Finding | Status | Change and evidence |
|---|---|---|
| C1: Reduce Motion blink | Fixed | One 0.1 s container CATransition cross-fades the subtree. Pager and child frames apply immediately. Hover in/out and same-height fourth-source checks reject opacity-from-zero and verify full pager/container opacity at +16 ms. |
| C2: width drag trails and re-animates | Fixed | Container/card flags allow animation only for media changes. Width drags cancel existing media animations and apply geometry with implicit actions disabled. 400 → 228 pt drags check every step for no keys and exact model/presentation widths, in both motion modes and expanded/collapsed states. |
| C3: missing assertions | Added | MC6 asserts exit collapse, MC8 asserts collapsed 33 pt rest, MC10 asserts Peek opacity restoration. Expanded add/remove checks assert visible title rows and C=145 → 74. MC15 asserts one root cross-fade and full presentation opacity. |
| C4: hidden sidebar keeps stale expansion | Fixed | Hide cancels collapse work and resets an unforced stack to collapsed without animation. Hide/show within the 0.3 s delay checks C=55, 33 pt cards, no pending collapse, and clean layers. |
| C5: removal under real pointer | Manual check pending | No tracking-area behavior change. §8.5 asks the user to expand two cards, click the top title or Close, move over the tab list, and confirm collapse. The agent cannot confirm this without driving the real pointer. |
| C6: stale flags and dead hitTest branch | Fixed | §8.2 uses expanded\|title:N and points to §13.8.4; the card returns super.hitTest after its visibility/retiring guard. |
