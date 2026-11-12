# Import: user hand checks (signed build)

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

## H2 — Chrome passwords: one Keychain approval
1. On the Chrome Choose step, turn on **Passwords and cookies**. Choose **Next**, then **Import**.
2. The consent step says "Import passwords and cookies from Chrome?". Choose **Import Passwords and Cookies**.
3. macOS asks once for the Keychain item **"Chrome Safe Storage"**. Enter your login password and choose **Allow**.
   - PASS: exactly one prompt, and it names "Chrome Safe Storage". No prompt names Arc or Chromium.
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

## Results
| Check | Result | Notes |
|---|---|---|
| H1 Chrome folder access | | |
| H2 Chrome Keychain approval | | |
| H3 Brave / Edge item names | | |
| H4 Safari Full Disk Access | | |
