# AppleScript: external sender consent parity (PB4 row 1)

Date: 2026-11-12. Target: Arc 1.172.2 (90755) at `/Applications/Arc.app`, read only. Our own words; the
term list is in `applescript-dictionary-terms.json` (names, codes, types, access only).

## What macOS shows, and what decides it

When another app (Terminal running `osascript`, Script Editor, Raycast, a JXA script) first sends an
Apple event to a scriptable app, macOS asks the user: "“‹sender›” wants access to control “‹target›”."
The user's answer is stored per sender and target pair (System Settings ▸ Privacy & Security ▸
Automation). Denied → the sender gets error -1743; "would ask" in a read-only check is -1744. The
target app cannot change this prompt's text. What the target controls:

| Fact | Arc 1.172.2 | Open | Evidence |
|---|---|---|---|
| `NSAppleScriptEnabled` | true | true | `plutil -p Contents/Info.plist` |
| `OSAScriptingDefinition` | `Arc.sdef` | `Open.sdef` | same |
| Dictionary terms (classes, properties, elements, commands, codes, types, access) | 71 terms | the same 71, plus the standard `set` command (`coresetd`) for property setters | `.re/pb4/sdef_terms.py` over both sdef files; e2e `applescript` row `H5_consent_declarations` |
| `access-group identifier="*"` (lets sandboxed senders with a scripting-targets entitlement use these commands) | on `make` and `count` | on `make` and `count` | `grep access-group` on both sdef files; `H5_consent_declarations` |
| `NSAppleEventsUsageDescription` (text shown when *this* app sends events to others) | absent | present (plan §11 H4) | `plutil -p`; Open's product code sends no Apple events, only OPEN_AUTOMATION builds script themselves (no consent for self) |
| Apple-events entitlement | none | none | `codesign -d --entitlements` |
| Code identity that keeps a stored consent | designated requirement = bundle identifier + Developer ID team | local builds: ad-hoc `cdhash` (consent is asked again after every rebuild); production `tools/release.sh` requires a Developer ID identity (identifier + team, like Arc) | `codesign -d -r-` |

Result: parity holds for everything the target app controls. The prompt itself, and the user's
choice, are macOS's. The only behaviour difference a user can see is on unsigned local builds, where
macOS asks again after each rebuild; signed releases keep the answer like Arc does.

## Not automated

Agents never answer a system consent dialog (AGENTS.md rule 4), so the external rows stay BLOCKED
(`gate-exceptions.json`: `applescript/A1_JXA`, `applescript/external_osascript`). The read-only check
(`AEDeterminePermissionToAutomateTarget`, ask = false) records the state each run.

## Arc hand checks for the user (do not run as an agent)

These answer the open questions in `features-advanced.md` §10.4. Run them in Script Editor against
Arc, then tell the lead the results (Open matches the guessed behaviour today):

1. `tell application "Arc" to execute active tab of front window javascript "1 + 2"` → is the result
   the text `3`? Then `... javascript "throw new Error('x')"` → which error number and message?
2. `tell application "Arc" to make new space` (and `make new space at front window`) → does Arc create
   a Space, or return an error (which number)?
3. With three pinned tabs, `set location of tab 3 of front window to "unpinned"`, then back to
   `"pinned"` → where does the tab land in each section (top or bottom)?
