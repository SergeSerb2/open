# Passwords, autofill, passkeys, and import in Arc 1.170.0

Scope: how Arc saves, fills, and manages passwords, payment cards, and addresses; what it does for passkeys; and how its importer writes secrets. Input for [plans/passwords-autofill.md](../plans/passwords-autofill.md).

Method: metadata tools and strings only on ArcCore (no Ghidra on ArcCore, per [README](README.md)); three read-only queries on the shared `ArcMain` Ghidra project (`-readOnly -noanalysis`). Raw output: `.re/passwords/` (git-ignored): `arccore-objc-methods.txt`, `arccore-save-request-classes.txt`, `arccore-selectors.txt`, `arccore-arc-source-paths.txt`, `arccore-arc-file-neighbors.txt`, `arccore-views-classes.txt`, `arc-main-password-strings.txt`, `arc-main-prompt-strings.txt`, `arcmain-prompts-ghidra.txt`, `arcmain-presenter-ghidra.txt`, `arcmain-presenter2-ghidra.txt`. Ghidra scripts: `~/Library/Caches/OpenRE/ghidra-scripts-pw/` (`AdrpBatch.java`, copied from the `-scc` set; `DecompAt.java`, new). No Arc launch, no desktop input, no Keychain access, no secret read.

Shorthand: `objc-methods` = `.re/arccore/objc-methods.txt`; `selectors` = `.re/arccore/objc-selectors.txt`; `core-strings` = `.re/arccore/strings-arccore.txt`; `main-strings` = `.re/arccore/strings-arc-main.txt`; `paths` = `.re/arccore/arc-source-paths.txt`.

## Summary

| # | Finding | Confidence |
|---|---|---|
| PW-1 | Arc runs Chromium's own password manager, autofill, and payments code in ArcCore. ADK gets three engine-owned save requests and answers them. | Proven |
| PW-2 | Save prompts for passwords, cards, and addresses are one Arc sheet dialog on the page's window, with Arc's own text. | Proven (text, sheet call); look not captured |
| PW-3 | The fill dropdown and the generation popup are Chromium's Views popups, drawn inside ArcCore. | Strong guess |
| PW-4 | Arc replaces several Chromium password and card dialogs with empty ("Null") implementations. | Proven |
| PW-5 | Manage Passwords and Credit Cards are Chromium's WebUI pages, opened under Arc's `arc://` scheme. | Proven |
| PW-6 | Arc's encryption key is a Keychain item named `<product> Safe Storage`, so "Arc Safe Storage". | Strong guess |
| PW-7 | Arc supports passkeys: iCloud Keychain passkeys through the system, and Chromium's Touch ID authenticator. | Proven (entitlements, strings, prefs key) |
| PW-8 | Arc does not use the macOS Passwords app or iCloud Keychain for passwords. It recommends Apple's "iCloud Passwords" extension and imports Safari's CSV export. | Proven |
| PW-9 | Arc's importer writes into the profile with Chromium store APIs and its own `ProfileWriter`; cookies go through the cookie manager, with a "skip existing cookies" option. | Proven (names); details guess |
| PW-10 | Password generation is compiled in but probably off. | Guess |
| PW-11 | HTTP authentication uses an Arc dialog that the password manager can fill. | Proven (API) |
| PW-12 | A default Arc profile keeps Chromium's default prefs for saving and autofill. | Proven on this Mac |

## PW-1. Chromium's managers, Arc's prompts

- ArcCore ObjC classes (`objc-methods`, `grep -i "SaveRequest\|LoginCredentials"`):
  - `ArcLoginCredentialsSaveRequest`: `isUpdate`, `save`, `cancel`, `neverAskAgain`.
  - `ArcCreditCardInfoSaveRequest`: `save`, `cancel`.
  - `ArcAddressEntrySaveRequest`: `save`, `cancel`.
  - `ArcLoginCredentials`: `url`, `username`, `password` (used by the HTTP auth path, PW-11).
  - Each wraps a `std::shared_ptr` to an `arc::…SaveRequest::Impl` (type encodings in `objc-methods`).
- UI delegate selectors (`selectors`): `webContents:didSubmitCredentials:`, `webContents:didSubmitCreditCardInfo:`, `webContents:didSubmitAddressEntry:`. Type strings in `main-strings`: `v32@0:8@"ArcWebContents"16@"ArcLoginCredentialsSaveRequest"24` and the card and address twins.
- Per-profile switches on `ArcBrowserContextPreferences`: `canEnablePasswordSaving`, `passwordSavingEnabled`, `setPasswordSavingEnabled:`, `canEnableCreditCardsSaving`, `creditCardsSavingEnabled`, `setCreditCardsSavingEnabled:` (`objc-methods`). No address switch exists.
- Swift glue names (`main-strings`): `ADKClient._showSavePasswordPrompt`, `ADKClient._showSaveCreditCardPrompt`, `ADKClient._showSaveAddressEntryPrompt`.

Reading: the engine decides when to offer a save (Chromium's `PasswordManager`, `FormDataImporter`), then hands Swift one request object. Swift shows the prompt and calls exactly one answer.

## PW-2. The save prompts

Ghidra (`AdrpBatch.java` with needles on the prompt strings; output `arcmain-prompts-ghidra.txt`):

| Prompt | Function | Title | Body | Buttons |
|---|---|---|---|---|
| Password, save | `FUN_101350010` (`showSavePasswordPrompt(_:request:url:)`) | "Save password for " + host + "?"; "Save this password?" when there is no host | "That way, it’ll be auto-filled next time" (no final period) | "Save", "Never on this site", "No" |
| Password, update (`isUpdate == true`) | same | same title | same body | "Save", "No" (the code adds "Never on this site" only when `isUpdate` is false) |
| Card | `FUN_101350ae8` (`showSaveCreditCardPrompt(_:request:url:)`) | "Save this card?" | "That way, it can be auto-filled next time" | "Save", "Not Now" |
| Address | `FUN_101351248` (`showSaveAddressEntryPrompt(_:request:url:)`) | "Save Address?" | "Saved addresses will appear in auto-fill next time you order something." | "Save", "No Thanks" |

- Short labels are Swift small-string immediates in the decompiled code, decoded by hand: `0x65766153` = "Save", `0x6f4e` = "No", `0x776f4e20746f4e` = "Not Now", `0x6b6e616854206f4e`+`0x73` = "No Thanks", `0x6968742065766153`+`0x3f647261632073` = "Save this card?", `0x6464412065766153`+`0x3f73736572` = "Save Address?".
- Long strings are referenced as Swift literals (needle address − 0x20): "Save this password?" `0x1039babc0`, "Save password for " `0x1039bad40`, "Never on this site" `0x1039bac50`.
- The title for a URL is built with `_StringGuts.grow` from "Save password for ", one inserted string, and "?" (`0x3f`). Guess: the inserted string is the URL's host.
- No window: each function logs "[save … prompt] Unable to find window associated with web content frame" and shows nothing.
- All three call one presenter, `FUN_100fc5d64` (`arcmain-presenter-ghidra.txt`). It turns the title and body into `SwiftUI.LocalizedStringKey`, then runs a block on `NSRunLoop.mainRunLoop` with `performInModes:block:` in `NSRunLoopCommonModes` and `NSModalPanelRunLoopMode`.
- The block (`FUN_100fc67f8` → `FUN_100fc63a8`, `arcmain-presenter2-ghidra.txt`) creates a `Dialogs.DialogInfo` (`_TtC7Dialogs10DialogInfo`) and calls `-[NSWindow beginSheet:completionHandler:]`.
- So the prompt is a window sheet: the same `Dialogs` sheet as the extension install prompt (EX-15 in the extensions UI branch). The window is blocked until the user answers.
- Not captured: the sheet's size, colors, button order, and whether it shows an icon.

## PW-3. The fill dropdown

- `core-strings` holds the element ids of Chromium's Views autofill popup (`PopupViewViews::kAutofillSuggestionElementId` and 11 more) and the class names `PopupViewViews` and `PasswordGenerationPopupViewViews` (`arccore-views-classes.txt`). These come from `chrome/browser/ui/views/autofill/popup/popup_view_views.cc` and `chrome/browser/ui/views/passwords/password_generation_popup_view_views.cc`, so that code is linked.
- No ADK selector shows an autofill popup (`selectors`, `grep -i autofill`: only Touch Bar names such as `showCreditCardAutofillWithController:` from Chromium's Mac Touch Bar code).
- Arc's own `arc/browser/ui/autofill_popup_view.cc` (`paths`) has one string next to it: "Blocked keyboard interaction with an obscured autofill popup" (`arccore-arc-file-neighbors.txt`). Chromium 156 has no such string. Guess: Arc added a check that refuses keyboard accept while something covers the popup.
- Strong guess: the dropdown that Arc users saw is Chromium's Views popup, a child window over the page, with Chromium's layout. Screenshot needed (plan §13 S-2).

## PW-4. Chromium dialogs that Arc turns off

From the strings next to each Arc file (`arccore-arc-file-neighbors.txt`):

| Arc file | Replaces | Arc behavior |
|---|---|---|
| `arc/browser/ui/password_dialog_prompts.cc` | `CreateAccountChooserPromptView`, `CreateAutoSigninPromptView`, `CreateCredentialLeakPromptView` | `NullAccountChooserPrompt`, `NullAutoSigninFirstRunPrompt`, `NullCredentialLeakPrompt`: nothing shows |
| `arc/browser/ui/create_card_unmask_prompt_view.cc` | `CreateCardUnmaskPromptView` | `NullCardUnmaskPrompt` |
| `arc/browser/ui/autofill_error_dialog_view.cc` | `CreateAndShowAutofillErrorDialog` | `NullAutofillErrorDialogView` |
| `arc/browser/ui/password_cross_domain_confirmation_popup_view.cc` | `PasswordCrossDomainConfirmationPopupView::Show` | Arc implementation (look unknown) |
| `arc/browser/ui/autofill_field_promo_view.cc` | `AutofillFieldPromoView::CreateAndShow` | Arc implementation |
| `arc/browser/ui/chrome_password_protection_service.cc` | `safe_browsing::ShowPasswordReuseModalWarningDialog` | Arc implementation |
| `arc/browser/ui/dialogs/webauthn_dialog.cc` | WebAuthn dialog (`WebAuthnDialog`) | Arc implementation (look unknown) |

Reading: no Credential Management account chooser, no auto sign-in first-run prompt, and no leak warning in Arc.

## PW-5. Manage Passwords and Credit Cards

- `main-strings` near `ADK/BrowserChromium.swift`: `settings/privacy`, `password-manager/passwords`, `settings/payments`, `settings/content/notifications`, `settings/clearBrowserData`, `settings/searchEngines`, `settings/content/siteDetails?site=`, `settings/manageProfile`, `extensions/shortcuts`, `settings/languages`, `settings/performance`.
- Full URLs in `main-strings`: `arc://password-manager/passwords`, `arc://settings/searchEngines`, `arc://settings/help`, `arc://extensions`. Arc shows Chromium's WebUI under its own scheme.
- The Profiles pane strings (`main-strings` near `PreferencesFeature/ProfilePreferencesViewController+Profiles.swift`): "Your Data and Settings", "Privacy and Security", SF Symbol `creditcard.and.123`, "Clear Browsing Data". "Passwords", "Credit Cards", and "Notifications" are shared strings elsewhere in the table. The order on screen is in [interaction-states.md](interaction-states.md) §18.
- So the "Passwords" row and the "Manage Passwords" command bar action open `arc://password-manager/passwords`, and "Credit Cards" opens `arc://settings/payments` (strong guess for the row targets; the URLs are proven).
- Arc has no "Addresses" row. Addresses live on Chromium's settings pages.
- Action names `onTogglePasswordSaving`, `onDidTogglePasswordSaving`, `onChangePasswordPreferencesTapped`, `onToggleCreditCardsSaving`, `onDidToggleCreditCardsSaving`, `onChangeCreditCardsPreferencesTapped` exist (`main-strings`). The 1.170 pane shows rows with arrows (IS §18). Guess: the switches are reducer actions from an older layout, or live behind the row. Screenshot needed (§13 S-5).

## PW-6. Keychain key

- ArcCore's `components/os_crypt/common/keychain_password_mac.mm` strings: " Safe Storage", `mock_password`, "Keychain lookup failed" (`core-strings`). The service name is the product name plus " Safe Storage". Guess (strong): "Arc Safe Storage", account "Arc". The first consented import run confirms it (import-phase2 Q1).
- Arc's importer reads other browsers' keys with the format "saltysalt%s Safe Storage" next to `brave`/`Brave`, `chrome`/`Chrome` (`core-strings`).
- Arc's profile Preferences (key names only, read-only) has `password_manager.profile_store_migrated_to_os_crypt_async`: Arc uses Chromium's async key provider (`components/os_crypt/async/browser/keychain_key_provider.mm`).
- Arc warns when encryption fails: "ARCCore encryption is not available on startup. Certain core features like cookies, password manager etc. may not work as expected." (`main-strings`).

## PW-7. Passkeys

- Entitlements: `com.apple.developer.web-browser.public-key-credential` = true, Keychain access groups `…webauthn` and `…auth` ([bundle-anatomy.md](bundle-anatomy.md) §8).
- `main-strings`: `S6N382Y83G.company.thebrowser.browser.webauthn`. This is Chromium's Touch ID authenticator group, `<Team ID>.<bundle id>.webauthn` (`chrome/browser/webauthn/chrome_web_authentication_delegate.cc:394-395`).
- Arc Preferences on this Mac has the key `webauthn.touchid.metadata_secret` (value not read). Chromium writes it in `TouchIdAuthenticatorConfigForProfile` (same file, 389-410).
- `selectors` has `requestAuthorizationForPublicKeyCredentials:`, `authorizationStateForPlatformCredentials`, `platformCredentialsForRelyingParty:completionHandler:`, `isDeviceConfiguredForPasskeys`. These are the `ASAuthorizationWebBrowserPublicKeyCredentialManager` calls in Chromium's iCloud Keychain code (`device/fido/mac/icloud_keychain_sys.mm`, which also checks the entitlement at 228-240).
- `core-strings`: `AuthenticatorRequestDialogView`; Arc has its own `arc/browser/ui/dialogs/webauthn_dialog.cc`.
- Conclusion: Arc supported passkeys in iCloud Keychain (system UI) and in Chromium's per-profile Touch ID store. Touch ID passkeys live in Arc's Keychain access group, so no other app can read or import them.

## PW-8. macOS Passwords app and iCloud Keychain

- No ADK or ArcCore API reads macOS passwords. Arc's onboarding recommends Apple's Chrome extension instead: "To log into sites without typing your passwords, we recommend you install Apple's iCloud Passwords Extension." with `installiCloudPasswordsExtension`, `PasswordManagerExtensionID`, `iCloudPasswordsExtension`, and flags `i-cloud-passwords-in-onboarding-enabled`, `i-cloud-passwords-configuration-url` (`main-strings`).
- Safari import is manual: "Upload your Passwords.csv file to Arc", "Exporting Safari Passwords", "Want us to delete Passwords.csv?", and the Keychain Access steps text (`main-strings`); ArcCore `arc/utility/importer/safari_exported_data_importer.cc` with "Unable to find Safari passwords CSV file" (`core-strings`).
- A "password import prompt" sheet exists (`PasswordImportPromptSheetWindow`, `eligibleToSeePasswordImportPrompt`, `hasShownPasswordImportPrompt`), with events `password_import_prompt_shown` / `_will_import` / `_dismissed`.

## PW-9. Arc's importer

- `paths`: `arc/browser/importer/arc_external_process_importer_host.cc`, `chrome_importer_utils.cc`, `import_source_catalog.cc`, `importer_list.cc`, `importer_manager.cc`, `profile_writer.cc`; `arc/utility/importer/chrome_importer.cc`, `chrome_importer_arc_parts.cc`, `importer_overrides.cc`, `safari_exported_data_importer.cc`.
- `import_source_catalog.cc` neighbors list bundle ids including `com.brave.Browser`, `com.vivaldi.Vivaldi`, `com.operasoftware.OperaGX`, and `company.thebrowser.Browser` (Arc itself).
- `importer_manager.cc` neighbors: "Cookie manager not available", "Didn't pass any supported category to import". `profile_writer.cc` neighbor: "A cookie could not be included". Guess: cookies are written with `network::mojom::CookieManager::SetCanonicalCookie`, and the inclusion status is checked.
- `selectors`: `import:withCategories:withAllowedExtensions:withBookmarkImportTargets:skipExistingCookies:withDelegate:error:`, `importPasswords:`, `didImportCategoryStart:withCategory:`, `didImportCategoryEnd:withCategory:withError:`, `didImportLockDialogShow:withDialogBody:completion:`.
- Reading: Arc imports per category, reports start and end per category, can skip cookies that already exist, and asks the user to close a locked source browser.

## PW-10. Password generation

- The generation code is linked (`PasswordGenerationPopupViewViews`, histogram names `PasswordGeneration.*` in `core-strings`).
- Chromium enables generation only when password sync is active (`components/password_manager/core/browser/password_feature_manager_impl.cc:28-36`). Arc has no Google sign-in.
- Guess: Arc did not offer generated passwords. Screenshot needed (plan §13 S-4).

## PW-11. HTTP authentication

- `ArcWebLoginDialog`: `isProxyLogin`, `isURLPotentiallyTrustworthy`, `authority`, `accept:with:`, `cancel`, `close` (`objc-methods`).
- Selectors `webContents:showWebLoginDialog:`, `webContentsDidCloseWebLoginDialog:`, `webContents:didAutoFillWebLoginDialog:` (`selectors`). The fill arrives as an `ArcLoginCredentials` (url, username, password).

Capture update, 2026-11-13 (C13-AUTH, Arc 1.172.2): the Basic-auth sheet is
413 × 257 pt and centered over the whole browser window. It shows “Sign in to
127.0.0.1”, “Your connection to this site is private.”, Username and Password
labels/placeholders, and Cancel / Sign in. The server's realm is absent.
Username starts focused. The password field conceals typed text; Return from
that field submits. Evidence: `.re/capture/s13/m1/arc/v2/002-auth-cancel-light/`
and `002-auth-cancel-dark/`, `auth-{light,dark}-dialog.{png,ax.json}`.

Sheet-relative AX text bounds in points (the field bounds describe the editable
text, not its surrounding background): title (19,19,375,23), body
(19,60,229.5,18), Username label (19,103,67,18), Username field
(99,103,288,18), Password label (19,158,67,18), Password field
(99,158,288,18), Cancel text (241,213,63,18), Sign in text
(324,213,63,18). The same light AX frame above supplies these measurements.

Cancel renders the fixture's 401 response in the same tab. Wrong credentials
produce another sheet with empty fields, Username focused, and no added error
text. Accepted credentials load the fixture's 200 page and offer the existing
save-password sheet (“Save password for 127.0.0.1?” / “That way, it’ll be
auto-filled next time”; Never on this site / No / Save). Evidence:
`.re/capture/s13/m1/arc/v3/004-auth-complete-no-save/`, the wrong-password,
success and `auth-after-no` PNG/AX pairs and request status receipts. This
follow-up exits 0 and quits normally after No. No password was saved, so this
capture does not prove saved-password refill; the fill API evidence above
remains separate.

Open implementation status (2026-11-13): the captured save offer is required;
there is no capture-based exception to omit it. `OPEN_HTTP_AUTH` guards the
sheet and the shell's credential-result handoff. That handoff checks transport,
host, effective port, realm, authentication scheme, and proxy flag, and ignores
late results after typing, answer, withdrawal, or sheet replacement.
Proxy fill stays disabled until the engine supplies the proxy's own protection
space; a target-page origin must not select a proxy password. Rejected saved
credentials must not refill a retry in the same authentication attempt.
`OPEN_HTTP_AUTH_ENGINE` additionally guards the request/answer/cancel adapter.
Normal-tab delegates forward to the same factory as standalone pages.

Password-manager integration is **not complete**: E3's declared
`OEAuthenticationRequest` API has no saved-credential lookup or successful-auth
callback, and its CEF LoginDelegate path bypasses Chromium's password-manager
integration. `OEAutofill.h` and `cef_open_autofill.h` expose credential counts
and imports, but no credential lookup or update; import preserves existing
entries. An engine-owned implementation must supply the guarded
`HTTPAuthPasswordManagerRequest` handoff and issue the existing `OESavePrompt`
only after confirmed acceptance. Its existing save/update presenter and answer
path can then be reused. The shell must not infer acceptance from a later page
load, use import as update, or create another credential store. These are Open
implementation requirements, not captured Arc internals. Default builds keep
both flags off; no auth runtime or saved-refill acceptance is claimed.

## PW-12. Default prefs on this Mac

Read-only key check of `~/Library/Application Support/Arc/User Data/Default/Preferences` (key names and presence only; no values printed):

- Absent, so Chromium defaults apply (all on): `credentials_enable_service`, `credentials_enable_autosignin`, `autofill.profile_enabled`, `autofill.credit_card_enabled`, `profile.password_manager_leak_detection`.
- Present: `password_manager` (`account_store_backup_password_cleaning_last_timestamp`, `account_store_migrated_to_os_crypt_async`, `profile_store_backup_password_cleaning_last_timestamp`, `profile_store_migrated_to_os_crypt_async`), `webauthn.touchid.metadata_secret`, `autofill.autofill_ai`, `autofill.last_version_deduped`.

## Open questions (need the user)

1. Sheet look for the three save prompts: size, icon, button order (§13 S-1).
2. Dropdown look: Chromium's popup or an Arc variant (§13 S-2).
3. Does Arc show a confirmation after Save (toast or none)? No string was found (§13 S-3).
4. Generated password offer on a sign-up page (§13 S-4).
5. What the Passwords and Credit Cards rows open, and whether a switch is shown (§13 S-5).
