# Release user steps

The agent does not run these setup or publish steps without the user's approval.
Run the commands in a local terminal. Do not paste passwords or private keys in
chat, source, logs, or the PR. The pipeline does not upload files or create tags.

The local dry run uses the dev engine. Its file feed proves shape and signatures
only; the App cannot consume it. Production still needs an official engine,
complete Chromium credits, final release notes, and the Step 8 updater controller.
See [the receipt](release/s16-pipeline-verification.md) for the current limits.

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
# Import this file into the password manager without printing it.
rm -f "$open_sparkle_backup"
unset open_sparkle_backup
```

Production uses that Keychain account by default. For a private file supplied by
the user instead, set `OPEN_SPARKLE_KEY_FILE` to its absolute path outside the
checkout and use `chmod 600` on it. Leave this variable unset for Keychain use.
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
the approved U-7 publish step. Until that commit, a 404 is expected.

Set `OPEN_RELEASE_FEED_URL` to the full stable feed URL chosen under U-8.
The default is `https://sergeserb2.github.io/open/appcast.xml`. Beta runs use
`appcast-beta.xml` in the same directory. The pipeline sets the staged app's
`SUFeedURL` before signing. It leaves the source plist unchanged.

Agent verification after the approved feed publish:

```bash
curl --fail --silent --show-error --head "$OPEN_RELEASE_FEED_URL" > /dev/null
```

Also fetch and validate the XML. Verify the current enclosure's URL and signature.
A successful web page redirect does not prove a feed exists.

## U-6: License, patent and security review

This unlocks the first public release. Read `docs/release/licenses.md`, the full
credits from the official engine, and `docs/engine-patches.md` → Security review.
Review the adblock, regex and aho-corasick notes and the list-parser fuzz work.
Confirm the MPL source offer, any GPL assets, and H.264/AAC distribution posture
in the release PR. Counsel is the user's choice.

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
Agent verification after the approved upload:

```bash
curl --fail --silent --show-error --head "${OPEN_RELEASE_DOWNLOAD_PREFIX%/}/Open-<marketing>.dmg" > /dev/null
curl --fail --silent --show-error "$OPEN_RELEASE_FEED_URL" | xmllint --noout -
```

The agent compares downloaded bytes with the approved checksum and verifies the
Ed25519 signature with `SUPublicEDKey`. The real predecessor-update check remains
a separate acceptance row. The first release records no shipped predecessor.

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
export OPEN_RELEASE_FEED_URL='https://sergeserb2.github.io/open/appcast.xml'
export OPEN_RELEASE_DOWNLOAD_PREFIX='https://github.com/SergeSerb2/open/releases/download/v<marketing>/'
```

Also fill `Public MPL source location:` and the exact source-offer links in
`docs/release/licenses.md`. Do not use a private repository as a public source offer.

Agent verification uses anonymous requests to the selected source file, feed and
DMG. It checks file content, not just a 200 status. After approval for the next
production preflight, run:

```bash
tools/release.sh --preflight-only
```

## U-9: not defined in the plan

Neither release plan §10 nor the release follow-ups defines U-9. No action,
environment variable or verification command is assigned to it. The lead must
name it before it can become a release requirement.

After the source work, user setup, and review gates pass, the production command is:

`tools/release.sh`
