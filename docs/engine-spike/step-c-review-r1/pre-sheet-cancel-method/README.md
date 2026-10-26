# Remote sheet key-delivery limit

At 8e345dc the new assert exposed that the prior in-process Escape did not
clear the pending Save sheet within 3 s. Earlier versions discarded the polling
result; they did not prove cancellation. The final flow cancels the actual own
sheet through the existing AppKit dismiss command and checks pending=false.
The native Cmd+Shift+S open, native page editing, and rename keys remain tested.
The remote system Save/Cancel buttons and their key delivery remain unverified.
No failed assertion is counted as PASS.
