# Release user steps

The agent does not run these setup or publish steps without the user's approval.
Run the commands in a local terminal. Do not paste passwords or private keys in
chat, source, logs, or the PR. The pipeline does not upload files or create tags.

The local dry run uses the dev engine. Its file feed proves shape and signatures
only; the App cannot consume it. Production still needs an official engine,
complete Chromium credits, final release notes, and the Step 8 updater controller.
See [the receipt](release/s16-pipeline-verification.md) for the current limits.

The agent packages and checks signatures on the M5 without launching the exact
app or its mounted DMG app. Supplemental smoke runs only on a separate temporary
DLV copy on the M1, under its own screen lock. The agent imports the DMG-bound
`m1-smoke.json` receipt before the final M5 summary. The exact artifact's expected
Library Validation refusal is static evidence only (§4.4). Never relaunch a build
that failed to load. If a build crashes, stop on-screen work and tell the lead.
For the Section 16 run, set `OPEN_RELEASE_HEAVY_WRAPPER` to
`/Users/serge/.t3/projects/open/.re/handoff/sections/s16/s16-heavy.sh`.
The pipeline uses that scheduler for its internal fetch and build commands.
The default scheduler for later releases is `heavy.sh`.
The first M5 run prepares the artifact, then exits 1 until its required M1 smoke
receipt exists. A missing or mismatched receipt cannot pass A-2/A-3/A-11.

## U-1: Apple Developer Program membership

This unlocks a Developer ID certificate and notarization. Open
https://developer.apple.com/programs/enroll/ and complete individual enrollment.
Then open Xcode → Settings → Accounts and add the enrolled Apple Account.
This fills the account's program membership. It does not fill an environment
variable. U-2 uses it next.

Agent verification after U-2, with approval:

```bash
security find-identity -v -p codesigning > /dev/null
```

A zero exit alone does not prove enrollment. U-2 must also find the exact identity.

## U-2: Developer ID Application certificate

This unlocks production app signing. In Xcode → Settings → Accounts, select the
team → Manage Certificates → + → Developer ID Application. Install the certificate
and its private key in the login Keychain. Copy its full identity name locally:

```bash
security find-identity -v -p codesigning
export OPEN_SIGN_IDENTITY='Developer ID Application: <certificate name> (<TeamID>)'
```

The identity name is `OPEN_SIGN_IDENTITY`. `--identity` can override it. The
pipeline never selects a certificate by itself. It reads the Team ID from the
chosen name. It does not log the identity lookup.

Agent verification, with approval:

```bash
security find-identity -v -p codesigning | grep -F "\"$OPEN_SIGN_IDENTITY\"" > /dev/null
```

## U-3: Notary credentials

This unlocks app and DMG notarization. Create an app-specific password at
https://account.apple.com/ → Sign-In and Security → App-Specific Passwords.
Use the interactive command below. Enter the Apple Account, Team ID and password
at its prompts. Do not pass the password as a shell argument.

```bash
export OPEN_NOTARY_PROFILE=open-notary
xcrun notarytool store-credentials "$OPEN_NOTARY_PROFILE"
```

This fills a Keychain profile. `OPEN_NOTARY_PROFILE` selects it. The default is
`open-notary`. The agent does not create or change the profile.

Agent verification, with approval:

```bash
xcrun notarytool history --keychain-profile "${OPEN_NOTARY_PROFILE:-open-notary}" > /dev/null
```

## After U-3: launch check of the first signed build

This step needs no new credential. It answers one launch question that only a
signed, notarized build can answer.

Local ad-hoc builds pay a Gatekeeper `syspolicyd` `ChangetimeScan` before
Open's own code runs: median about 150 ms per launch (Section 16 window,
2026-11-08: 56 of 56 Open launches scanned, 0 of 14 floor-app launches). A full
Open run also advances the executable's change time, so the next launch scans
again. Without the scan, the measured sidebar time is near the 250 ms budget.
The full evidence is in `docs/launch-diagnostics.md` (PR #251).

The question: does the notarized, stapled build installed in `/Applications`
still pay this scan on every launch?

Steps for the agent, with the user's approval, on the first signed build:

1. Install the stapled DMG's App in `/Applications` (copy from the mounted DMG).
2. Launch it from the Dock or Finder once, quit it, then launch it twice more the
   same way. Note the local times of each launch.
3. After each launch, collect the security log for that minute:

```bash
log show --start '<YYYY-MM-DD HH:MM:SS>' --end '<YYYY-MM-DD HH:MM:SS>' \
  --signpost --info --debug \
  --predicate 'process == "syspolicyd" AND eventMessage CONTAINS[c] "Open.app"'
```

4. Record for each launch whether a `ChangetimeScan` ran and its duration, and
   the App's `sidebarDrawn` from its launch receipt.
5. Record the static state once: `codesign --verify --deep --strict`,
   `xcrun stapler validate`, `spctl --assess --type execute --verbose=4`, and
   whether `com.apple.quarantine` is present (absence is a result).

Result rule: if launches 2 and 3 show no scan, the release build meets the
launch path that the budget assumes, and the ad-hoc cost is a development-only
effect. If they still scan, the change-time writer inside a full Open run must
be found and removed before launch work can meet the budget.

## U-4: Sparkle signing key and backup

This unlocks signed updates. Losing this key prevents installed copies from
trusting future updates. Approve key creation before running these commands.
The pinned tools are Sparkle 2.10.1. They are installed outside the repository:

```bash
export OPEN_SPARKLE_TOOLS="$HOME/Developer/open-release-tools/sparkle-2.10.1/bin"
export OPEN_SPARKLE_KEY_ACCOUNT=ed25519
"$OPEN_SPARKLE_TOOLS/generate_keys" --account "$OPEN_SPARKLE_KEY_ACCOUNT"
```

Paste the printed **public** key into `App/Info.plist` → `SUPublicEDKey`.
The pinned tool's default Keychain account is `ed25519`. The plan's earlier
`org.sparkle-project.Sparkle` account wording was incorrect.
Export one private backup outside the repository. Store it in a password manager.
Delete the temporary export in the same session:

```bash
umask 077
open_sparkle_backup=$(mktemp "${TMPDIR:-/tmp}/open-sparkle-backup.XXXXXX")
"$OPEN_SPARKLE_TOOLS/generate_keys" --account "$OPEN_SPARKLE_KEY_ACCOUNT" -x "$open_sparkle_backup"
printf 'Backup file: %s\n' "$open_sparkle_backup"
```

Use the password manager's file-import command to import that displayed path.
Do not print the file's contents. Confirm that the backup is saved. Then delete
the temporary file in the same terminal session:

```bash
rm -f "$open_sparkle_backup"
unset open_sparkle_backup
```

Production uses that Keychain account by default. For a private file supplied by
the user instead, set `OPEN_SPARKLE_KEY_FILE` to its absolute path outside the
checkout and use `chmod 600` on it. The file must be at most 4096 bytes.
Leave this variable unset for Keychain use.
Both pinned tools support `--ed-key-file`; the pipeline checks their help first.
The file contains the base64 private seed exported by the tool. Never put it
under `build/release`.

If the tools are absent, install the pinned archive. This creates no key.
The expected hash is the GitHub release asset digest:

```bash
(
  set -e
  open_sparkle_install=$(mktemp -d "${TMPDIR:-/tmp}/open-sparkle-tools.XXXXXX")
  trap 'rm -rf "$open_sparkle_install"' EXIT
  curl -fL --output "$open_sparkle_install/Sparkle-2.10.1.tar.xz" https://github.com/sparkle-project/Sparkle/releases/download/2.10.1/Sparkle-2.10.1.tar.xz
  cd "$open_sparkle_install"
  printf '%s  %s\n' 1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27 Sparkle-2.10.1.tar.xz | shasum -a 256 -c -
  mkdir -p "$HOME/Developer/open-release-tools/sparkle-2.10.1"
  tar -xJf Sparkle-2.10.1.tar.xz -C "$HOME/Developer/open-release-tools/sparkle-2.10.1" bin
)
```

Agent verification, after all preflight source prerequisites are ready and with
approval for the selected Keychain account or private file:

```bash
tools/release.sh --preflight-only
```

This signs a random temporary probe. CryptoKit verifies it with the plist's
public key. A wrong private key fails before any certificate lookup, notary
request, build, or release signing. No private key is printed or exported.

## U-5: GitHub Pages

This unlocks public appcast hosting. Complete U-8 first. In the selected public
repository, open Settings → Pages → Build and deployment → Deploy from a branch.
Choose `gh-pages` and `/ (root)`. Save. The initial branch/feed commit is part of
the approved U-7 publish step. If `gh-pages` does not exist, first approve that
initial U-7 commit, then return to Pages settings. Until that commit, a 404 is
expected.

Set `OPEN_RELEASE_FEED_URL` to the full stable feed URL chosen under U-8.
The default is `https://sergeserb2.github.io/open-releases/appcast.xml`. Beta runs use
`appcast-beta.xml` in the same directory. The pipeline sets the staged app's
`SUFeedURL` before signing. It leaves the source plist unchanged.

Agent verification after the approved feed publish:

```bash
curl --fail --silent --show-error --head "$OPEN_RELEASE_FEED_URL" > /dev/null
curl --fail --silent --show-error "$OPEN_RELEASE_FEED_URL" | xmllint --noout -
```

Verify the current enclosure's URL and signature with the U-7 command below.
A successful web page redirect does not prove a feed exists.

## U-6: License, patent and security review

This unlocks the first public release. Read `docs/release/licenses.md`, the full
credits from the official engine, `docs/release/license-audit.md`, and
`docs/engine-patches.md` → Security review.
Review the adblock, regex and aho-corasick notes and the list-parser fuzz work.
Confirm the MPL source offer, any GPL assets, and H.264/AAC distribution posture
in the release PR. Confirm the license choice for the bundled filter lists; Open
distributes them unmodified. Review the EasyList and EasyPrivacy pins, headers,
and GPL-3.0-or-later / CC BY-SA 3.0 alternatives in the inventory.
Counsel is the user's choice.

This fills a written review decision in the PR. It does not fill a credential.
Set `Public MPL source location:` in `docs/release/licenses.md` under U-8.

Agent verification after the source offer and official credits exist:

```bash
python3 tools/generate-acknowledgements.py build/release-review/Credits.rtf --require-cef-credits
```

The agent also reads the written decision. This command does not replace it.

## U-7: Approval for each public release

This unlocks tagging and upload for one exact build. Review its manifest,
checksum, acceptance table and notes. Approve the exact tag and artifact hashes
in the release PR. The agent then uses the reviewed §8.4 commands printed by
`tools/release.sh`: tag first, release assets next, feed last. Choose the target
repository from U-8 explicitly when using `gh release create --repo <owner/repo>`.
The pipeline's origin-based publish examples apply only if origin is that target.
No setup approval also approves publication.

This fills the release PR's approval. It does not fill an environment variable.
The lead also records approved runtime/About/update evidence in
`build/release/<marketing>-<build>/acceptance.json`. It contains the exact
`dmg_sha256`, an `evidence` path, and true values only for completed checks:
`launch`, `helpers`, `mounted_launch`, `about`, and `real_update` (or
`no_predecessor` for the first release). The file is at most 16384 bytes.
`release.sh` never launches an exact artifact, in any mode. The STOP-rule still
applies; a future production runtime check needs separate lead authorization.
Re-running `tools/release.sh` verifies the receipt against the final DMG hash.
Do not create success fields without real evidence.
Agent verification after the approved upload:

```bash
curl --fail --silent --show-error --head "${OPEN_RELEASE_DOWNLOAD_PREFIX%/}/Open-<marketing>.dmg" > /dev/null
curl --fail --silent --show-error "$OPEN_RELEASE_FEED_URL" | xmllint --noout -
```

For the exact approved build, the agent also runs the command below. Replace
`<marketing>-<build>` with the reviewed version and build. The generated verifier
uses the source plist public key. It reads no private key or Keychain account.

```bash
python3 - 'build/release/<marketing>-<build>' <<'PYVERIFY'
from pathlib import Path
import hashlib, os, plistlib, subprocess, sys, tempfile, urllib.request
import xml.etree.ElementTree as ET
release = Path(sys.argv[1]).resolve()
ns = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
with urllib.request.urlopen(os.environ['OPEN_RELEASE_FEED_URL'], timeout=20) as source:
    xml = source.read(4194305)
assert len(xml) <= 4194304
feed = ET.fromstring(xml)
local = ET.parse(release / 'appcast.xml').getroot()
build = local.findtext('./channel/item/' + ns + 'version')
item, = [x for x in feed.iter('item') if x.findtext(ns + 'version') == build]
enclosure = item.find('enclosure')
name = 'Open-' + item.findtext(ns + 'shortVersionString') + '.dmg'
assert enclosure.get('url') == os.environ['OPEN_RELEASE_DOWNLOAD_PREFIX'].rstrip('/') + '/' + name
checksum = (release / (name + '.sha256')).read_text().split()[0]
expected_length = (release / name).stat().st_size
assert int(enclosure.get('length')) == expected_length
public = plistlib.loads(Path('App/Info.plist').read_bytes())['SUPublicEDKey']
with tempfile.TemporaryDirectory(prefix='open-published-verify-') as temp:
    archive = Path(temp) / name
    digest = hashlib.sha256()
    count = 0
    with urllib.request.urlopen(enclosure.get('url'), timeout=30) as source, archive.open('wb') as output:
        for chunk in iter(lambda: source.read(1048576), b''):
            count += len(chunk)
            assert count <= expected_length
            output.write(chunk)
            digest.update(chunk)
    assert digest.hexdigest() == checksum
    assert archive.stat().st_size == int(enclosure.get('length'))
    subprocess.run([str(release / '.staging/verify-ed25519'), public,
                    enclosure.get(ns + 'edSignature'), str(archive)], check=True)
print('Published DMG checksum and public-key signature: PASS')
PYVERIFY
```

The real predecessor-update check remains a separate acceptance row. The first
release records no shipped predecessor.

## U-8: Public source and download location

This unlocks U-5, public downloads and the MPL source offer. Choose to make the
current repository public or use a public mirror. The agent does not make this
choice. In GitHub Settings → General → Danger Zone, change repository visibility,
or create the chosen public mirror and publish the required shipped sources.
The current repository is private.

Set the URLs for the chosen host. The download prefix is the complete URL of
**this tag's** asset directory, including its version. Update it for each release.
The defaults below are proposals until the user selects that location:

```bash
export OPEN_RELEASE_FEED_URL='https://sergeserb2.github.io/open-releases/appcast.xml'
export OPEN_RELEASE_DOWNLOAD_PREFIX='https://github.com/SergeSerb2/open-releases/releases/download/v<marketing>/'
```

Also fill `Public MPL source location:` and the exact source-offer links in
`docs/release/licenses.md`. Do not use a private repository as a public source offer.

Agent verification compares each published MPL source file with the exact shipped
source. Fill the two paths below from the U-8 source inventory. Run this command
for each file in that inventory. It sends no GitHub token:

```bash
(
  set -e
  open_release_source_url='<anonymous URL for this shipped MPL source file>'
  open_release_source_path='<matching local shipped source file>'
  open_release_source_check=$(mktemp "${TMPDIR:-/tmp}/open-source-check.XXXXXX")
  trap 'rm -f "$open_release_source_check"' EXIT
  curl --fail --silent --show-error --location --max-time 30 --max-filesize 67108864 "$open_release_source_url" --output "$open_release_source_check"
  cmp "$open_release_source_path" "$open_release_source_check"
)
```

U-5 and U-7 verify the anonymous feed and DMG content. After approval for the next
production preflight, the agent also runs:

```bash
tools/release.sh --preflight-only
```

## U-9: iCloud Keychain passkey entitlement

This unlocks iCloud Keychain passkeys in Open (the system passkey sheet). Open
ships without it: security keys and phone passkeys (hybrid) already work through
Chromium's WebAuthn dialog. The source is `docs/plans/passwords-autofill.md`
(D-8, §12 Q-3, and the line that names this item U-9).

Chromium checks the managed entitlement
`com.apple.developer.web-browser.public-key-credential` at runtime. Apple must
approve it for the Team, and the signed build then needs a matching provisioning
profile. It needs U-1 and U-2 first.

User steps:

1. In the Apple Developer portal, request the managed capability for web-browser
   public-key credentials for the App ID `io.github.sergeserb2.open`.
2. When Apple approves it, create a Developer ID provisioning profile for that
   App ID with the capability, and download it.
3. Tell the agent the local path of the downloaded profile. Do not commit it.

This fills no environment variable yet. The agent then changes, in one reviewed PR:
`App/Open.entitlements` (add the entitlement), `docs/plans/release.md` §4.2 (its
entitlement list), and `tools/release.sh` (embed the profile as
`Contents/embedded.provisionprofile` before signing).

Agent verification, with approval, on the signed app:

```bash
codesign -d --entitlements - build/release/<marketing>-<build>/Open.app 2>/dev/null \
  | grep -F com.apple.developer.web-browser.public-key-credential
security cms -D -i build/release/<marketing>-<build>/Open.app/Contents/embedded.provisionprofile \
  | grep -F com.apple.developer.web-browser.public-key-credential
```

Then the passwords P-20 passkey run without the virtual authenticator
(passwords-autofill plan §9.5) must pass on that signed build.

After the source work, user setup, and review gates pass, the production command is:

`tools/release.sh`

## Status (2026-11-12, user-approved, done by the lead)

| Step | State |
|---|---|
| U-1, U-2 | Done before: "Developer ID Application" identity for team 78A5P57U23 is in the M5 login Keychain. |
| U-3 | Done: Keychain profile `open-notary` stored on the M5; `notarytool history` passes. |
| U-4 | Done: the existing Sparkle key (Keychain account `ed25519`) is used; its public key is in `App/Info.plist`. The private-key backup to a password manager is still the user's step. |
| U-8 | Decided: public repository `SergeSerb2/open-releases` (releases, feed, MPL sources). The development repository stays private. Feed: `https://sergeserb2.github.io/open-releases/appcast.xml`. |
| U-5 | Open: enable Pages on `gh-pages` after the first approved feed commit. |
| U-6, U-7 | Open: per-release review and approval. |
