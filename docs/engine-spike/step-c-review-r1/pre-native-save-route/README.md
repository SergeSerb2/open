# Save automation bring-up (retained)

Binaries: 632f13e. Both window suites passed all 53 functional checks, including
the four new focus cases. Release launch budgets failed under load.
Debug shell reached the new shutdown case, where a direct NSSavePanel.ok call
raised an AppKit exception. This is a harness defect, fixed by configuring the
real sheet and pressing native Return. Debug actions passed inline rename,
then its second Save action had no browser-key menu context after Cancel.
The fixture now establishes its exact browser key window before that separate
action and waits for its real enabled menu state.

The remaining Release shell/actions commands loaded the updated runner while
the old binaries were still installed. Their unknown configure command/menu
context failures are retained, not accepted. The final matrix rebuilds both
configurations and uses the same immutable source throughout.
