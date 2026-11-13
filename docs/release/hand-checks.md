# Release hand checks (signed build)

One list of the checks that only the user can run on the signed release build. Sections: A import from
other browsers (IMC, IMF), B Import from Arc secrets, C system permissions and gestures (the gate's BLOCKED
rows), D the signed-build launch check. Record each result in the table at the end.

## A. Import from other browsers

Agents cannot run these checks: they need a real Keychain prompt, a System Settings grant, or the user's own
browsers. Run them once with the signed release build. Each check takes about 2 minutes.
Send back only the result lines ("H1: PASS", or what you saw). Do not send any names, URLs or passwords.

Before you start: quit Open. Have Chrome installed with at least one saved password. Brave or Edge is optional (H3).

## H1 — Chrome folder access (no prompt expected)
1. Open Open. Choose **Settings ▸ General ▸ Import from another browser ▸ Import…**.
2. Look at the browser list.
   - PASS: Chrome is in the list, and selecting it does not show "No access".
   - If macOS shows a prompt like "Open would like to access data from other apps", write down its exact text
     and which button you chose. This settles F3 question 4 (macOS data protection on other browsers' folders).
3. Select **Chrome**, then **Next**. PASS: the Choose step shows counts ("Found: N") for Bookmarks and History.

## H2 — Chrome passwords: one Keychain read
1. On the Chrome Choose step, turn on **Passwords and cookies**. Choose **Next**, then **Import**.
2. The consent step says "Import passwords and cookies from Chrome?". Choose **Import Passwords and Cookies**.
3. macOS asks for the Keychain item **"Chrome Safe Storage"**. Enter your login password and choose **Allow**.
   - PASS (LEAD 20:15): Open reads Chrome Safe Storage once. macOS may show up to two prompts for that one read
     (the app list, then the team ID list), and both name "Chrome Safe Storage". No prompt names Arc or Chromium.
     Write down how many prompts you saw.
4. PASS: the Report shows "Passwords: N imported" with N > 0.
5. Open **Settings ▸ Passwords**. PASS: a password that you saved in Chrome is listed.
6. Deny path (optional): run steps 1–3 again and choose **Deny**. PASS: the Report says "Keychain access was not
   granted. Passwords and cookies were not imported." Bookmarks and history still import.

## H3 — Brave / Edge Keychain item names (GUESS in code)
Open uses these items (`BrowserSourceDescriptor.keychainItem`). The Chrome name is proven; the others are a guess.

| Browser | Service (item name) | Account |
|---|---|---|
| Chrome, Chrome Canary | Chrome Safe Storage | Chrome |
| Brave | Brave Safe Storage *(guess)* | Brave *(guess)* |
| Edge | Microsoft Edge Safe Storage *(guess)* | Microsoft Edge *(guess)* |
| Vivaldi | Vivaldi Safe Storage *(guess)* | Vivaldi *(guess)* |
| Chromium | Chromium Safe Storage | Chromium |

1. Open **Keychain Access** (in /Applications/Utilities). Search for **Safe Storage**.
2. For Brave and Edge (if installed), write down the exact **Name** and **Account** of each item.
   - PASS: they match the table. If not, send the exact Name and Account; these are labels, not secrets.
3. Optional: repeat H2 with Brave or Edge. PASS: one prompt that names that browser's item.

## H4 — Safari Full Disk Access
1. Quit Safari. In **Settings ▸ General ▸ Import from another browser ▸ Import…**, select **Safari**, then **Next**.
2. PASS: Open says "Open needs Full Disk Access to import from Safari." and opens System Settings at
   **Privacy & Security ▸ Full Disk Access** (this matches Arc).
3. Turn on **Open** in that list. Return to Open without restarting it.
   - PASS: within a few seconds the import continues to the Choose step with counts for Bookmarks and History.
   - If macOS asks you to quit and reopen Open, write down the text, reopen, and run step 1 again.
4. Import. PASS: the Report shows bookmarks and history; a pinned folder "Imported from Safari" appears.
5. You can turn Full Disk Access off again afterwards.

## H5 — Firefox: real profile data (signed build)
1. Quit Firefox. In **Settings ▸ General ▸ Import from another browser ▸ Import…**, select **Firefox**, then **Next**.
2. PASS: the Choose step shows counts for Bookmarks, History and Passwords from your real Firefox profile.
3. Import. PASS: the Report shows the counts; your Firefox open tabs appear; a password you saved in Firefox is in
   **Settings ▸ Passwords**.

## H6 — Firefox Primary Password
Only if your Firefox profile uses a Primary Password.
1. Repeat H5 with **Passwords** on. PASS: Open asks for the Primary Password once; with the right password the
   passwords import; with a wrong password the Report says the passwords were not imported, and bookmarks and
   history still import.

## H7 — Safari Full Disk Access continues by itself
Part of H4 step 3: after you turn on Full Disk Access, do not touch Open. PASS: within a few seconds the import
moves on to the Choose step without a restart. Write down if macOS asks you to quit and reopen.

## B. Import from Arc: passwords, cookies, cards and addresses

## H8 — "Arc Safe Storage" approval (real Arc data)
1. Quit Arc. In Open, **Settings ▸ General ▸ Import from Arc…**, turn on **Passwords and cookies**, then **Import**.
2. macOS asks once for the Keychain item **"Arc Safe Storage"**. Enter your login password and choose **Allow**.
   - PASS: exactly one prompt, and it names "Arc Safe Storage".
3. PASS: the Report shows passwords and cookies imported; a site where you were signed in to Arc opens signed in;
   a saved Arc password is in **Settings ▸ Passwords**.
4. Deny path (optional): repeat and choose **Deny**. PASS: the Report says passwords and cookies were not imported,
   and everything else still imports.

## C. System permissions and gestures (gate rows that wait for the user)

## H9 — Keychain error path (passwords PW-KC1)
*Steps not yet confirmed by the passwords owner: PW-KC1 has no written definition (tools/e2e/passwords.py marks it a user hand check).*
In **Settings ▸ Passwords**, open a saved password and choose **Show**. When macOS asks for your login password,
choose **Cancel**. PASS: Open shows the password stays hidden, with no error dialog and no crash.

## H10 — Web notifications (page N1)
On a site that sends notifications (allow it in Site Control), trigger one. If macOS asks whether Open may send
notifications, choose **Allow**. PASS: the notification appears in macOS Notification Center; a click opens its tab.

## H11 — Camera and microphone (media recording card, sleep F3)
On a video-call test page, allow the camera and microphone in Open and in the macOS prompt. PASS: the sidebar
shows the recording indicator and the media card; the tab is not put to sleep while it records.

## H12 — Trackpad smart zoom (page Z3, U-S1)
On a web page, double-tap with two fingers on the trackpad. PASS: the page zooms in; a second double-tap zooms out.

## H13 — Translation with the macOS language pack (page X1)
Install the French → English language in System Settings (Translation Languages). Open a French page and
choose **Translate**. PASS: the page shows in English.

## H14 — Automation from other apps (AppleScript A1, external osascript)
In Terminal: `osascript -e 'tell application "Open" to get the URL of active tab of front window'`. When macOS asks
whether Terminal may control Open, choose **OK**. PASS: the URL of the current tab prints.

## D. First signed build

## H15 — Launch check after notarization
Run the steps in `docs/release-user-steps.md` → "After U-3: launch check of the first signed build".

## Results
Agent run (IMF, 2026-11-12). Build: the signed, notarized 0.1.0 DMG from main 9e035540 (SHA-256 a6c8fd1b…,
Team 78A5P57U23, `spctl`: Notarized Developer ID). H3 and parts of H1/H4 also ran on DMG e (ad-hoc) on an
earlier rented Mac. Where: a rented Mac (macOS 27.2, SIP disabled). Data: TEST data only. The test profiles
were made by Chrome, Brave, Edge and Firefox on that Mac; the logins in them are synthetic. The Keychain items
were in a separate TEST keychain with a known password. Only local test pages on 127.0.0.1 were used.

| Check | Result | Notes |
|---|---|---|
| H1 Chrome folder access | PASS | Chrome is in the list, no "No access", and no macOS data-protection prompt. Choose shows "Found: 2" for bookmarks, tabs and history, and "Found: 1" for passwords. Same result on DMG e. |
| H2 Chrome Keychain approval | PASS (LEAD 20:15 rule) | Open reads the item once (one `SecItemCopyMatching`). macOS shows **two** prompts, and both name "Chrome Safe Storage" (none names Arc or Chromium). 1: "Open wants to use your confidential information stored in “Chrome Safe Storage” in your keychain." 2: "Open wants to access key “Chrome Safe Storage” in your keychain." (the partition-list check). After two Allows, the Report shows "Passwords: 1 imported, 0 already in Open", and the login is in Open's store. The Deny path passes: "Keychain access was not granted. Passwords and cookies were not imported.", and a new bookmark still imports. The test item had Chrome's access list and team ID (EQHXZ8M8AV), like the item Chrome makes. The first run recorded FAIL against "exactly one prompt"; the lead changed the rule (two prompts for one read pass). **User:** count the prompts with a real Chrome item. |
| H3 Brave / Edge item names | PASS | Made by Brave and Edge on first launch: Name "Brave Safe Storage", Account "Brave"; Name "Microsoft Edge Safe Storage", Account "Microsoft Edge". Both match the table. Vivaldi not checked. |
| H4 Safari Full Disk Access | USER (real Mac) | SIP is off on rented Macs, so macOS does not protect `~/Library/Safari`. Open read Safari's history without Full Disk Access, so the FDA prompt flow cannot appear there. The import itself works ("Import finished.", history imported). |
| H5 Firefox real data | PASS | Profile made by Firefox 159 (its default bookmarks, three local visits, session restore). The synthetic logins (`openkit firefox-fixture`) were copied in, because Firefox's UI cannot be automated. Choose: Bookmarks 4, History 3, Passwords 3, Open tabs 3. The Report shows the same counts; the three tabs are in the sidebar and the three logins are in Open's password store. |
| H6 Firefox Primary Password | PASS | Open asks in a secure field (AXSecureTextField). A wrong password gives "The Primary Password is not correct"; bookmarks (6) and history still import, and no login is added. The right password imports 3 passwords. |
| H7 Safari FDA continues by itself | USER (real Mac) | Same reason as H4. |
| H8 Arc Safe Storage approval | NOT RUN (user) | Needs real Arc data. |
| H9 Keychain error path | PASS, with a naming bug | Opening a saved password shows the macOS prompt; Cancel leaves the list with no password shown, no error dialog and no crash (same pid). **Bug:** the prompt title is "Chromium is trying to show passwords" (body: "Enter your password to continue with “Open”."). It must name Open. |
| H10 Web notifications | USER (real Mac) | Open's site prompt "Allow 127.0.0.1 to send you notifications?" → Allow works, and the page sent its notification (page title "sent"). The rented Mac shows no banners at all: a control `osascript` notification did not show either, and usernoted kept Open at "Denied" with no visible prompt. |
| H11 Camera and microphone | NOT RUN (user) | Needs a real camera and microphone. |
| H12 Trackpad smart zoom | NOT RUN (user) | Needs a trackpad. |
| H13 Translation | PASS | French page → "Translation Available" → Translate → Apple's "Download Languages to Translate" sheet → French and English downloaded → the page shows in English. |
| H14 Automation from other apps | PASS | The osascript line, run in Terminal.app: macOS asked "“Terminal” wants access to control “Open”…" → Allow; it printed the active tab URL (rc=0). "front window" is the main browser window, not a Little Open window. |
| H15 Signed-build launch check | R | R runs it on the M1. |

Other findings from this run:
- Safari import: on a fresh Safari profile, Bookmarks was "Not found" but ticked by default, and the Report then said
  "Some selected data could not be imported." Fixed: a data type with "Not found" is now unticked and disabled
  (Settings ▸ Import and onboarding); e2e row `import_other_browsers/safari_not_found_unticked`.
- The Chrome Report listed Chrome's built-in "Google Docs Offline" and "Chrome Web Store Payments" under Extensions.
  Fixed in #519 (IMC): extensions with install location 5 or 10, or `was_installed_by_default`, are not offered;
  e2e suite `import-browsers`.
- The password reveal prompt says "Chromium is trying to show passwords": an engine string, handed to E3 (LEAD 20:15).
- First launch on rented Macs showed "Allow “Open” to access your microphone?". Log proof: coreaudiod asked TCC for
  the Open main process during onboarding. The only audio device there is BlackHole 2ch, the default output and
  input. Open only plays sounds (AVAudioPlayer: intro sound, sound effects), so playback on a device that has input
  starts the check. No prompt is expected on a Mac with normal speakers. **User:** confirm that the first launch
  shows no microphone prompt.
- Firefox 159 ships a Rust logins store (`logins.db`). Filed in `docs/followups.md`.

## For the user (a real Mac)
These need SIP on, real notification banners, real data, or real hardware. Agents cannot run them on rented Macs.

| Item | What to check |
|---|---|
| H2 prompt count | With a real Chrome item: how many prompts appear for one import (one or two pass), and that each names "Chrome Safe Storage". |
| H4 / H7 | Safari Full Disk Access: the System Settings flow, and that the import continues by itself. |
| H8 | Arc Safe Storage approval with real Arc data. |
| H10 | Web notifications: the macOS prompt, the banner, and a click that opens the tab. |
| H11 | Camera and microphone with real devices. |
| H12 | Trackpad smart zoom. |
| First-launch microphone | A normal first launch (onboarding with its intro sound) shows **no** "Allow “Open” to access your microphone?" prompt. |
| H15 | R runs it. |
