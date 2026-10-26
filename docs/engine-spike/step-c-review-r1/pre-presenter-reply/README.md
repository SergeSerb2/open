# Native Save input method failure (retained)

App binaries: 2a18169. Both window suites again passed their 53 functional
checks. Release launch budgets remained FAIL under load. The new shell quit
case observed zero captures after in-process Return (background work was pending).
The second Save action could not regain a browser key window while an owned
remote panel remained key. These ordinary method failures are preserved; no
foreign foreground interruption was observed. Later Release commands loaded
the new presenter-reply command while still running the old binaries, and
failed with unknown command / native-key context. These are not accepted passes.

The final runner replies to the actual pending Save presenter through the
socket and executes the same production capture completion, with the real
engine and file write. This covers the caller path. The remote system Save
button itself remains unverified. Native page editing and inline rename still
use real key routes.
