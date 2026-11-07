# Passwords, autofill, and imported Arc secrets: implementation plan

Status: plan, 2026-10-26. Closes the two P0 gaps in [status.md](../status.md) §3.1 (gap 1: Open's own password manager; gap 2: writing imported Arc passwords, cookies, cards, and addresses) and the §5.4 decision "Password manager approach".

Readers: the engine lead (fork patches, §4), the OpenEngine owner (§5), and shell implementers (§6, §8). Each step in §10 is one PR.

Inputs. Read these first; this plan does not repeat them:

- RE: [re/passwords-autofill.md](../re/passwords-autofill.md) (PW-1…PW-12, written for this plan), [re/arccore-engine.md](../re/arccore-engine.md) §2, [re/interaction-states.md](../re/interaction-states.md) §18, [re/features-core.md](../re/features-core.md) §4.4 and §5.2.
- Import: [import-phase2.md](import-phase2.md) §3 and its lead decisions; `Packages/OpenKit/Sources/OpenImport/ChromiumCrypto.swift` (`SecretsImportConsent`), `ArcSecrets.swift`, `SyntheticSecretsFixture.swift`; [first-run.md](first-run.md) §5.4 and D7.
- Engine: [engine-api.md](../engine-api.md), [engine-patches.md](../engine-patches.md), [engine-fork.md](../engine-fork.md), and PR #53 (`m7/ext-p1-tabstrip`): hosted Chrome style tabs in a hidden Chrome `Browser` per Open window.
- Shell: [app-shell.md](app-shell.md) §4.9, [settings-library.md](settings-library.md) (P-7…P-10, §5.8), [profiles.md](profiles.md) §5–§6 and §8.4, [release.md](release.md) C-11 and §4.4.
- Coordination: the extensions UI plan (PR #58, `docs/plans/extensions-ui.md` §3.11) specifies the same Arc sheet dialog (EX-15). §6.1 below shares one component with it.

Chromium paths are relative to `~/Developer/open-engine/chromium_git/chromium/src` (Chromium 156.0.8078.48, CEF 8078). Line numbers are from that tree on 2026-10-25.

## Goal

An Arc user who switches to Open keeps their logins and can keep saving and filling passwords, cards, and addresses, the way Arc did it:

1. Open offers to save or update a password after a sign-in, with Arc's sheet and text.
2. Open fills saved passwords, cards, and addresses from a dropdown under the field, only after a user action.
3. "Manage Passwords" and Settings ▸ Profiles ▸ Passwords / Credit Cards open the manage pages for that profile.
4. Import from Arc writes Arc's passwords, cookies, cards, and addresses into the matching Open profile, behind the existing consent token, and can run again without duplicates.
5. Every secret is encrypted at rest with the key in the Keychain item "Open Safe Storage" (account "Open"), and with no other key.

## Success criteria

1. On a fixture login page in a hosted tab, a successful sign-in shows the save sheet within 1 s of the post-login page load. "Save" stores the login; reloading the form and clicking the username field shows the login in the dropdown (§9.2 P-1…P-4).
2. A changed password shows the update sheet without "Never on this site". "Save" replaces the stored password (P-5).
3. "Never on this site" stores a blocked entry; the next sign-in on that site shows no sheet (P-6).
4. No field is filled on page load. Filling needs a click or key press in the dropdown (P-7). Cross-origin iframes follow Chromium's rules unchanged (P-8).
5. A card form and an address form show their sheets; saved data appears in the dropdown and fills on selection (P-9…P-12).
6. "Manage Passwords" (command bar), the Passwords row, and the dropdown footer open `chrome://password-manager/passwords` for the right profile (P-13, P-14).
7. Nothing crashes on any password, card, address, or passkey path in a hosted tab (P-15; §2 names one crash that exists today and one rule that prevents another).
8. A persistent cookie and a session cookie survive quit and relaunch; `Cookies` stores them encrypted (C-1…C-3).
9. Import of a synthetic two-profile Arc fixture writes each record to the mapped Open profile only; a second run adds 0 records; a forced stop after any step and a re-run end in the same state (I-1…I-8).
10. No code path reads, creates, or writes "Chromium Safe Storage". Real secrets are never written under Chromium's mock key (K-1…K-3, P-22, I-8).
11. No unit tests. Every check runs the real app (AGENTS.md rule 6).

## Non-goals

- Google Password Manager, sync, account storage, password sharing, Password Checkup and leak detection (no Google services; Arc turned off the leak prompt, PW-4).
- Arc's Safari CSV upload flow and its "password import prompt" (PW-8). Chromium's own Password Manager page keeps its CSV import (§6.3).
- The macOS Passwords app or iCloud Keychain passwords (Arc did not use them, PW-8). Users who want them install Apple's "iCloud Passwords" extension (extensions plan).
- A native Open replacement for the fill dropdown, the generation popup, or the Manage pages in v1 (D-3, D-4).
- Importing Arc's Touch ID passkeys (they are bound to Arc's Keychain access group, PW-7) and Arc's stored CVCs.
- Import from browsers other than Arc.

## 0. Locked inputs (do not re-derive)

| Input | Source |
|---|---|
| Never write Chromium SQLite files from Swift; never copy Arc blobs; the engine writes through Chromium store APIs | import-phase2 §3.7 and decision summary |
| Agents never read the real "Arc Safe Storage" item or real Arc secrets; verify with synthetic fixtures only | import-phase2 lead decisions; status §5.3 |
| `SecretsImportConsent.grantedByUser(reason:)` is the only consent token; only the explicit "Import Passwords and Cookies" button creates it | `ChromiumCrypto.swift`; first-run D7; `ImportWizard.swift` |
| Open's key: "Open Safe Storage" / "Open"; ad-hoc builds use Chromium's mock key | release C-11; `App/main.swift`; `OEEngine.mm:28-29, 360-371` |
| Chrome style tabs are hosted in a hidden Chrome `Browser` (`OpenBrowserWindow`, no `BrowserView`) | PR #53, engine-patches P1 status |
| Per-profile isolation of logins, cookies, and autofill data | features-core §5.2 r4; profiles §5.3 |
| Engine profile layout is moving to `<data root>/Engine/<profile dir>` with `root_cache_path = <data root>/Engine` | profiles.md (as it lands); followups "Engine (profiles)" |
| Fork patch rules: hooks as small patches, new code in the overlay under `//open/`, new CEF API as overlay headers under `cef/include/` with generated C API | engine-fork.md; engine-patches.md "How the patches are stored" |

The layout change does not touch this plan: every engine call here takes an `OEBrowserContext`, never a path.

## 1. Arc facts this plan uses

Full evidence in [re/passwords-autofill.md](../re/passwords-autofill.md).

| Fact | Id |
|---|---|
| Chromium's `PasswordManager`, autofill, and payments run in ArcCore. Swift gets save requests: login (`isUpdate`, `save`, `cancel`, `neverAskAgain`), card (`save`, `cancel`), address (`save`, `cancel`). | PW-1 |
| Prompts are one Arc sheet (`Dialogs.DialogInfo`, `-[NSWindow beginSheet:completionHandler:]`). Text: password "Save password for <host>?" / "Save this password?", body "That way, it’ll be auto-filled next time", buttons Save / Never on this site / No (update: no "Never"); card "Save this card?", "That way, it can be auto-filled next time", Save / Not Now; address "Save Address?", "Saved addresses will appear in auto-fill next time you order something.", Save / No Thanks. | PW-2 |
| The dropdown and generation popup are Chromium's Views popups (guess, strong). | PW-3 |
| Arc shows no account chooser, no auto sign-in prompt, no leak warning, no card unmask prompt. | PW-4 |
| Manage Passwords = `arc://password-manager/passwords`; Credit Cards = `arc://settings/payments`; no Addresses row. | PW-5 |
| Key item "Arc Safe Storage" (guess, strong); os_crypt async provider. | PW-6 |
| Passkeys: iCloud Keychain (managed entitlement) and Chromium's Touch ID authenticator. | PW-7 |
| No macOS Passwords app integration. | PW-8 |
| Arc's importer: Chromium-style `ProfileWriter`, cookie manager, "skip existing cookies". | PW-9 |
| Password generation: probably off. | PW-10 |

## 2. Current state (verified 2026-10-25)

Engine, on `main` plus PR #53:

- Hosted tabs get Chrome's tab helpers: autofill client and `ChromePasswordManagerClient` (`chrome/browser/ui/tab_helpers.cc:276-317`), `ManagePasswordsUIController` (575), `TabDialogs` (579). So Chromium already detects forms, offers saves, and can fill.
- The save bubble never shows: `PasswordBubbleViewBase::ShowBubble` returns when the window has no `ToolbarButtonProvider` (`chrome/browser/ui/views/passwords/password_bubble_view_base.cc:64-68`).
- Card and address prompts never show: `OpenBrowserWindow::GetAutofillBubbleHandler()` returns null (PR #53 `Engine/fork/src/open/browser/tab_strip/open_browser_window.mm:381-384`). The card path checks for null (`chrome/browser/ui/autofill/payments/save_card_bubble_controller_impl.cc:824-847`). The address path looks up a `BrowserView` and gets null (`chrome/browser/ui/autofill/address_bubbles_controller.cc:58-62`, `chrome/browser/ui/views/frame/browser_view.cc:1203-1220`).
- Crash risk 1: after a local card fill, Chromium may offer card re-auth. `MandatoryReauthBubbleControllerImpl` dereferences the bubble handler with no null check (`chrome/browser/ui/autofill/payments/mandatory_reauth_bubble_controller_impl.cc:294-300`). With PR #53 that is a null dereference.
- Rule for any new handler: Chromium dereferences the bubble that `AutofillBubbleHandler` returns (`SetBubbleView(*handler->Show…())`, `save_card_bubble_controller_impl.cc:849-855`). A handler that returns null from such a call crashes, so H-2 never returns null.
- The dropdown probably works today: on macOS, `CanShowRootPopup` needs only the field's NSWindow (`chrome/browser/ui/views/autofill/popup/popup_view_views.cc:144-160`), and `PasswordGenerationPopupView::Create` needs only the container view (`chrome/browser/ui/views/passwords/password_generation_popup_view_views.cc:496-506`). Not tested yet (Step 0).
- WebAuthn and HTTP auth dialogs are web-modal (`constrained_window::ShowWebModalDialogViewsOwned`, `chrome/browser/ui/views/webauthn/authenticator_request_dialog_view_controller_views.cc:54`). PR #53's dialog host has no host view, so they do not show.
- Keychain: `OEEngine` sets "Open Safe Storage"/"Open" through `CefSettings.keychain_service_name`/`keychain_account_name` (`Engine/OpenEngine/src/OEEngine.mm:28-29, 360-363`). CEF writes them into `KeychainPassword::GetServiceName()`/`GetAccountName()` (`cef/libcef/common/chrome/chrome_main_delegate_cef.cc:345-357`). Chromium's defaults would be "Chromium Safe Storage"/"Chromium" (`components/os_crypt/common/keychain_password_mac.mm:35-38`). Ad-hoc builds add `--use-mock-keychain` (`OEEngine.mm:369-371`; `App/main.swift`).
- No OpenEngine API exists for prompts, credential prefs, counts, or import writes.

Shell and libraries:

- Settings ▸ Profiles already has "Privacy and Security", "Passwords", "Credit Cards", "Notifications", "Clear Browsing Data" rows (`OpenSettings/ProfilesPane.swift:179-183`). They call `SettingsActions.openProfileSubpage(profileID:page:)`; no App adapter exists.
- The command `manage-passwords` exists in the registry (`OpenCommands/CommandRegistry.swift:387`) with no handler.
- The import wizard has the consent step and engine-ready copy; `canImportPasswordsAndCookies` defaults to false (`OpenSettings/SettingsActions.swift:60`; `ImportWizard.swift:124-154`).
- `ArcSecretsReader` decrypts logins, cookies, addresses, and cards into borrowed records behind the token (`ArcSecrets.swift`). It skips blocked logins and reads no notes, no element names, and no cookie SameSite, priority, source, or partition fields.

## 3. Decisions

| # | Decision | Why |
|---|---|---|
| D-1 | Use Chromium's built-in password manager, autofill, and local payments in the fork. Open replaces only UI. Extensions (1Password, Bitwarden) keep working next to it. | Arc does the same (PW-1). Closes status §5.4. |
| D-2 | Save and update prompts are an Open sheet (§6.1) fed by OpenEngine (§5.1). Chromium keeps the state machine (`ManagePasswordsUIController`, `SaveUpdateBubbleController`, `SaveCardBubbleController`, `SaveAddressBubbleController`). | Arc's sheet and text (PW-2). Keeps Chromium's save logic exact. |
| D-3 | Keep Chromium's Views dropdown and generation popup. No OpenEngine dropdown API in v1. Their "Manage…" footers route to Open (§4.2 H-4). | Arc parity (PW-3). Chromium's keyboard, a11y, and security checks come for free. |
| D-4 | Manage pages are Chromium WebUI in an Open tab: `chrome://password-manager/passwords`, `chrome://settings/payments`, `chrome://settings/addresses`. | Arc parity (PW-5). |
| D-5 | Replace Chromium's dialogs that Arc turned off with empty implementations: account chooser, auto sign-in first run, leak warning, card unmask, autofill error (§4.2 H-6). Other autofill bubbles with no Open UI close as "not interacted". | PW-4; no `BrowserView` to host them. |
| D-6 | Fill on account select on: never fill on page load (§4.5). | Brief: fill only on a user gesture. Chromium already waits in cross-origin iframes, on PSL matches, and on insecure pages (`components/password_manager/core/browser/password_form_filling.cc:224-262`). |
| D-7 | Password generation stays off in v1 (Chromium's default without sync). | Arc probably had none (PW-10). Screenshot S-4 confirms. |
| D-8 | Passkeys: v1 ships security keys and phones (hybrid) through Chromium's WebAuthn dialog in a real dialog host (§4.2 H-7). iCloud Keychain passkeys follow when Apple grants the managed entitlement (U-8, §12 Q-3). No Chromium Touch ID authenticator in v1. | Arc had both (PW-7); release.md §4 excludes restricted entitlements from v1. |
| D-9 | Key: "Open Safe Storage"/"Open" only. With the mock key, the engine shows no password or card save prompt and the import refuses real secrets (§7.1). | Release C-11; the mock key is public. |
| D-10 | The import writes per kind and per profile through store APIs in the engine: logins, then addresses and cards, then cookies. Existing Open data wins. Each step ends at a durability barrier and a ledger entry (§8). | Re-runs add nothing; a crash loses at most one step. Matches Arc's "skip existing cookies" (PW-9). |
| D-11 | Leak detection, Password Checkup, and Credential Management auto sign-in are off by default (§4.5). | No Google services; Arc showed no leak or auto sign-in UI (PW-4). |

## 4. Engine bridge (fork patches, series `05xx`)

Series numbers: `00xx` ad block, `01xx` tab sleep, `03xx` extensions, `04xx` media (media-pip.md). This plan takes `05xx`. All patches depend on P1 (`0301`, `0302`).

### 4.1 Chromium components we keep

| Component | Where | Role in Open |
|---|---|---|
| `password_manager::PasswordManager`, `PasswordFormManager` | `components/password_manager/core/browser/` | Detects sign-in forms, decides save vs. update, fills |
| `ChromePasswordManagerClient` | `chrome/browser/password_manager/chrome_password_manager_client.cc` | Per-tab client; `PromptUserToSaveOrUpdatePassword` (403-443) hands the form to `ManagePasswordsUIController` |
| `ManagePasswordsUIController` | `chrome/browser/ui/passwords/manage_passwords_ui_controller.cc` | Prompt state machine; `ShowBubble()` → `TabDialogs` (1536-1540) is our hook |
| `SaveUpdateBubbleController` | `chrome/browser/ui/passwords/bubble_controllers/save_update_bubble_controller.h:19-37` | Our prompt answers call `OnSaveClicked`, `OnNeverForThisSiteClicked`, `OnNotNowClicked` |
| Profile password store (`LoginDatabase`) | `components/password_manager/core/browser/password_store/` | Storage, encrypted with the Open key |
| `BrowserAutofillManager`, `FormDataImporter`, `AddressDataManager`, `PaymentsDataManager` | `components/autofill/core/browser/` | Form parsing, save offers, storage of addresses and local cards |
| `ChromeAutofillClient`, `AutofillPopupControllerImpl`, `PopupViewViews` | `chrome/browser/ui/autofill/`, `chrome/browser/ui/views/autofill/popup/` | Dropdown (kept as is, D-3) |
| `SaveCardBubbleControllerImpl`, `SaveAddressBubbleController`, `UpdateAddressBubbleController` | `chrome/browser/ui/autofill/…` | Card and address prompt state; our handler (H-2) shows them |
| `autofill::BubbleManager` | `chrome/browser/ui/autofill/bubble_manager.cc` | Queues password and autofill bubbles per tab; kept |
| `ChromeWebAuthenticationDelegate`, `AuthenticatorRequestDialogController` | `chrome/browser/webauthn/` | Passkeys and security keys (D-8) |
| `os_crypt_async` `KeychainKeyProvider` | `components/os_crypt/async/browser/keychain_key_provider.mm` | Encryption key from "Open Safe Storage" (tag `v10`, line 28) |
| Password Manager and Settings WebUI | `chrome/browser/ui/webui/password_manager/`, `chrome/browser/resources/settings/` | Manage pages (D-4) |
| `network::mojom::CookieManager` | `services/network/public/mojom/cookie_manager.mojom` | Cookie import (`GetAllCookies` 412, `SetCanonicalCookie` 450-452, `FlushCookieStore` 511) |

### 4.2 UI hooks we replace

| Id | Chromium call | Today in a hosted tab | Open replacement | Patch |
|---|---|---|---|---|
| H-1 | `TabDialogsViews::ShowManagePasswordsBubble` / `HideManagePasswordsBubble` (`chrome/browser/ui/views/tab_dialogs_views.cc:63-80`), reached from `ManagePasswordsUIController::ShowBubble()` (`manage_passwords_ui_controller.cc:1536-1547`) after `BubbleManager` approves it (`QueueOrShowBubble`, 1668-1680) | Bubble returns early (no toolbar) | `open_engine::OpenPasswordPromptRouter::Show(web_contents, user_action)`: maps the controller state (table below) to a `CefSavePrompt` or to nothing. Returns `true` when Open handled it. The hook runs for every WebContents that has an Open client, hidden strip or not. | `chromium/0501-open-password-prompt-routing.patch` (one hunk per method in `tab_dialogs_views.cc`) |
| H-2 | `BrowserWindow::GetAutofillBubbleHandler()` and `AutofillBubbleHandler::Get(browser->GetUnownedUserDataHost())` | null | `open_engine::OpenAutofillBubbleHandler`, owned by `OpenBrowserWindow` and registered as unowned user data on the `Browser` (the way `AutofillBubbleHandlerImpl` does at `chrome/browser/ui/views/autofill/autofill_bubble_handler_impl.cc:98-102`). It forwards save card, save address, and update address to `CefSavePrompt`. Every other method returns a `NullAutofillBubble` (never null) and posts `OnBubbleClosed(kNotInteracted)` or the type's equivalent. | overlay `open/browser/autofill/open_autofill_bubble_handler.{h,cc}`; one line in PR #53's `open_browser_window.mm` (overlay) |
| H-3 | `address_bubbles_controller.cc:55-99` reaches the handler through `BrowserWindow::FindBrowserWindowWithWebContents` (a `BrowserView` lookup) | null; no prompt | Use `AutofillBubbleHandler::Get(tab->GetBrowserWindowInterface()->GetUnownedUserDataHost())`, as the TODO at line 96 already asks (crbug.com/381390420) | `chromium/0502-open-address-bubble-handler-lookup.patch` |
| H-4 | `ChromePasswordManagerClient::NavigateToManagePasswordsPage` (1409-1421) and `ChromeAutofillClient::ShowAutofillSettings` | Expected: a singleton tab in the hidden `Browser`, which P1 adopts as an unplaced Today tab (Step 0 confirms) | `CefOpenAutofillHandler::OnOpenAutofillPage(browser, page)`; the shell opens the page by its own rule (§6.3). Falls through to Chromium when no handler is set. | `chromium/0503-open-autofill-page-routing.patch` |
| H-5 | `ManagePasswordsUIController::UpdateBubbleAndIconVisibility` (1230-1275) | Updates a page action icon that nobody draws | Keep. Step 0 confirms it does not crash (`BrowserActions` and `ManagePasswordsPageActionController` exist for hidden browsers: `browser_window_features.cc:348`, `tab_features.cc:357-361`). Add null checks only if Step 0 finds a crash. | none expected |
| H-6 | `CreateAccountChooserPromptView`, `CreateAutoSigninPromptView`, `CreateCredentialLeakPromptView` (`chrome/browser/ui/passwords/password_dialog_prompts.h`), `CreateCardUnmaskPromptView`, `CreateAndShowAutofillErrorDialog` | Views dialogs with no host | Empty implementations, as in Arc (PW-4). Each posts its controller's close call from its `Show…` method (account chooser and auto sign-in: `CredentialManagerDialogController::OnCloseDialog()`, `credential_manager_dialog_controller_impl.cc:209`; leak: `CredentialLeakDialogController::OnCloseDialog()`), so `navigator.credentials.get` resolves with `null` instead of hanging | `chromium/0504-open-null-credential-dialogs.patch` (the five factories, under `open_engine::IsOpenWebContents()`) |
| H-7 | `OpenBrowserWindow::GetWebContentsModalDialogHost()` (PR #53: host without a view) | WebAuthn and HTTP auth dialogs do not show | A real `WebContentsModalDialogHost`: host view = the hosted tab's parent NSView, position = top center of the page view at its top edge (Chrome's placement; guess for Arc), max size = page view size. Chromium's Views dialogs then show as child windows of the Open window. | overlay change in `open_browser_window.mm`; no new patch |

Password states (`components/password_manager/core/common/password_manager_ui.h`) and what H-1 does:

| State | Open |
|---|---|
| `PENDING_PASSWORD_STATE` | Save sheet |
| `PENDING_PASSWORD_UPDATE_STATE` | Update sheet |
| `MANAGE_STATE` with `user_action` | Open Manage Passwords (§6.3) |
| `KEYCHAIN_ERROR_STATE` | Toast "Open couldn't use your Keychain, so this password wasn't saved." (Open text) |
| All other states (confirmations, auto sign-in, move to account, biometric promos, passkey confirmations, password change) | Nothing shown; the router calls `OnBubbleShown()` then `OnBubbleHidden()` so the controller does not wait |

The router creates a `SaveUpdateBubbleController(PasswordsModelDelegateFromWebContents(wc), kAutomatic or kUserAction)`. Its constructor calls `OnBubbleShown()`; `OnBubbleClosing()` reports interactions and calls `OnBubbleHidden()` (`password_bubble_controller_base.cc:23, 31-36`). Answers: Save → `OnSaveClicked()`; Never → `OnNeverForThisSiteClicked()`; No / Esc → `OnNotNowClicked()`; withdrawn or tab gone → only `OnBubbleClosing()`. Then always `OnBubbleClosing()`.

Card and address answers: card Save → `OnSaveButton({})` then `OnBubbleClosed(kAccepted)`; Not Now → `OnBubbleClosed(kCancelled)`; withdrawn → `kNotInteracted` (`PaymentsUiClosedReason`, `components/autofill/core/browser/ui/payments/payments_ui_closed_reasons.h:14-28`). Address Save → `OnUserDecision(kAccepted, profile)`; No Thanks → `kDeclined`; withdrawn → `kIgnored` (`AddressPromptUserDecision`, `components/autofill/core/browser/foundations/autofill_client.h:213-233`), then `OnBubbleClosed()`.

### 4.3 New CEF API (overlay header `cef/include/cef_open_autofill.h`)

Guarded with `CEF_API_ADDED(CEF_API_VERSION_EXPERIMENTAL)`; C API generated by `cef/tools/version_manager.py` (engine-fork.md, P1 section). Shape (the engine lead may adjust names; the ObjC contract in §5 is fixed):

```cpp
typedef enum {
  CEF_SAVE_PROMPT_PASSWORD, CEF_SAVE_PROMPT_PASSWORD_UPDATE,
  CEF_SAVE_PROMPT_CARD, CEF_SAVE_PROMPT_ADDRESS, CEF_SAVE_PROMPT_ADDRESS_UPDATE,
} cef_save_prompt_kind_t;
typedef enum {
  CEF_SAVE_PROMPT_ANSWER_SAVE, CEF_SAVE_PROMPT_ANSWER_NEVER,
  CEF_SAVE_PROMPT_ANSWER_DISMISS, CEF_SAVE_PROMPT_ANSWER_IGNORED,
} cef_save_prompt_answer_t;
typedef enum {
  CEF_AUTOFILL_PAGE_PASSWORDS, CEF_AUTOFILL_PAGE_PAYMENT_METHODS, CEF_AUTOFILL_PAGE_ADDRESSES,
} cef_autofill_page_t;

/*--cef(source=library)--*/
class CefSavePrompt : public virtual CefBaseRefCounted {
 public:
  virtual cef_save_prompt_kind_t GetKind() = 0;
  virtual CefString GetOrigin() = 0;        // main frame origin, serialized
  virtual CefString GetDisplayHost() = 0;   // url_formatter::FormatOriginForSecurityDisplay, scheme omitted
  virtual CefString GetUsername() = 0;      // password kinds; may be empty
  virtual CefString GetCardLabel() = 0;     // card: network and last four
  virtual CefString GetAddressLabel() = 0;  // address: one line
  virtual bool IsUserInitiated() = 0;
  virtual bool IsAnswered() = 0;
  virtual void Answer(cef_save_prompt_answer_t answer) = 0;  // first call wins
};

/*--cef(source=client)--*/
class CefOpenAutofillHandler : public virtual CefBaseRefCounted {
 public:
  virtual void OnShowSavePrompt(CefRefPtr<CefBrowser> browser, CefRefPtr<CefSavePrompt> prompt) {}
  virtual void OnWithdrawSavePrompt(CefRefPtr<CefBrowser> browser, CefRefPtr<CefSavePrompt> prompt) {}
  virtual void OnOpenAutofillPage(CefRefPtr<CefBrowser> browser, cef_autofill_page_t page) {}
};
/*--cef()--*/
void CefSetOpenAutofillHandler(CefRefPtr<CefOpenAutofillHandler> handler);  // process-wide, UI thread

/*--cef(source=client)--*/
class CefOpenImportCallback : public virtual CefBaseRefCounted {
 public:
  // Counts only. Runs on the UI thread after the batch is durable (§8.3).
  virtual void OnComplete(int added, int existing, int failed) = 0;
};
/*--cef(source=client)--*/
class CefOpenCountsCallback : public virtual CefBaseRefCounted {
 public:
  virtual void OnCounts(int logins, int blocked_sites, int cards, int addresses, int cookies) = 0;
};
/*--cef(source=library)--*/
class CefOpenProfileData : public virtual CefBaseRefCounted {
 public:
  static CefRefPtr<CefOpenProfileData> GetForContext(CefRefPtr<CefRequestContext> context);
  virtual void GetCounts(CefRefPtr<CefOpenCountsCallback> callback) = 0;
  // Each list item is a dictionary with the keys in §5.3. Secret values are
  // CefBinaryValue; the engine zeroes its copies after the write.
  virtual void ImportLogins(CefRefPtr<CefListValue> logins, CefRefPtr<CefOpenImportCallback> callback) = 0;
  virtual void ImportAddresses(CefRefPtr<CefListValue> addresses, CefRefPtr<CefOpenImportCallback> callback) = 0;
  virtual void ImportCards(CefRefPtr<CefListValue> cards, CefRefPtr<CefOpenImportCallback> callback) = 0;
  virtual void ImportCookies(CefRefPtr<CefListValue> cookies, CefRefPtr<CefOpenImportCallback> callback) = 0;
};
```

Prefs need no new API: OpenEngine uses `CefRequestContext::SetPreference` / `GetPreference` with `credentials_enable_service`, `autofill.profile_enabled`, `autofill.credit_card_enabled` (`components/password_manager/core/common/password_manager_pref_names.h:46`; `components/autofill/core/common/autofill_prefs.h:94, 145`).

Overlay implementation files (compiled into `libcef_static` through `//open/open_libcef_sources.gni`, as in P1):

- `open/browser/autofill/open_password_prompt_router.{h,cc}` (H-1)
- `open/browser/autofill/open_autofill_bubble_handler.{h,cc}` (H-2)
- `open/browser/autofill/open_save_prompt_impl.{h,cc}` (`CefSavePrompt`)
- `open/browser/autofill/open_profile_data_impl.{h,cc}` (`CefOpenProfileData`, §8)
- `open/browser/autofill/open_autofill_handler_registry.{h,cc}` (`CefSetOpenAutofillHandler`, `IsOpenWebContents`)

### 4.4 Patch list

```text
# Engine/fork/patches/chromium/series
0501-open-password-prompt-routing.patch      # H-1: tab_dialogs_views.cc routes password bubbles to Open
0502-open-address-bubble-handler-lookup.patch # H-3: address bubbles find the handler on the Browser
0503-open-autofill-page-routing.patch        # H-4: "Manage passwords/addresses/payment methods" go to Open
0504-open-null-credential-dialogs.patch      # H-6: account chooser, auto sign-in, leak, card unmask, error dialog
0505-open-autofill-defaults.patch            # §4.5: fill on account select on; leak detection and auto sign-in off
```

Manifest paths:

- 0501: `chrome/browser/ui/views/tab_dialogs_views.cc`
- 0502: `chrome/browser/ui/autofill/address_bubbles_controller.cc`
- 0503: `chrome/browser/password_manager/chrome_password_manager_client.cc`, `chrome/browser/ui/autofill/chrome_autofill_client.cc`
- 0504: `chrome/browser/ui/views/passwords/account_chooser_dialog_view.cc`, `auto_signin_first_run_dialog_view.cc`, `credential_leak_dialog_view.cc`, `chrome/browser/ui/views/autofill/payments/card_unmask_prompt_views.cc`, `autofill_error_dialog_view_native_views.cc` (each holds its `Create…` factory in 156). Arc replaced the same factories (PW-4).
- 0505: `components/password_manager/core/browser/features/password_features.cc` (`kFillOnAccountSelect` default, line 113-115), `components/password_manager/core/browser/password_manager.cc` or the pref registration file for the two defaults.

No CEF series patch is needed: the API header and its implementation are overlay files, and PR #53 already adds `//open/open_libcef_sources.gni` to CEF's `BUILD.gn`.

### 4.5 Defaults

| Setting | Default | How |
|---|---|---|
| `kFillOnAccountSelect` ("fill-on-account-select") | on | 0505 (Chromium default is off, `password_features.cc:113-115`) |
| `credentials_enable_service` (offer to save passwords) | on | Chromium default; with the mock key, prompts are suppressed instead (§7.1) |
| `autofill.profile_enabled`, `autofill.credit_card_enabled` | on | Chromium default; card prompts suppressed with the mock key (§7.1) |
| `profile.password_manager_leak_detection` | off | 0505 (no Google services, D-11) |
| `credentials_enable_autosignin` | off | 0505 (no auto sign-in UI, D-11) |
| `password_manager.biometric_authentication_filling` | off (Chromium default) | user can turn it on in the Password Manager settings page |
| Password generation | off (no sync, `password_feature_manager_impl.cc:28-36`) | unchanged |
| Card mandatory re-auth | Q-2 | — |

### 4.6 Crash-proofing for hosted tabs

1. H-2 never returns null from any `AutofillBubbleHandler` method. This removes crash risk 1 and follows the rule in §2.
2. H-6 removes every Views dialog that needs a missing anchor.
3. Step 0 runs the §9.2 flows on today's fork before any patch and records every crash with a symbolized stack (engine-api.md "Debugging crashes"). Each crash gets a null check in the patch that owns its file.
4. Every page where a user can sign in must be a `.chrome` page inside an `OEBrowser`: tabs, Split View panes, Peek, Little Open. `pages` (automation) must show a browser id for each. A page outside a strip has no Open client, and H-1 then falls back to Chromium (which shows nothing).

## 5. OpenEngine API (exact)

New public header `Engine/OpenEngine/include/OpenEngine/OEAutofill.h`, added to `OpenEngine.h`. Main-thread classes are `NS_SWIFT_UI_ACTOR`, as in the rest of OpenEngine.

### 5.1 Save prompts

```objc
typedef NS_ENUM(NSInteger, OESavePromptKind) {
  OESavePromptKindPassword = 0,
  OESavePromptKindPasswordUpdate,
  OESavePromptKindCard,
  OESavePromptKindAddress,
  OESavePromptKindAddressUpdate,
} NS_SWIFT_NAME(OESavePrompt.Kind);

typedef NS_ENUM(NSInteger, OESavePromptAnswer) {
  OESavePromptAnswerSave = 0,        // "Save"
  OESavePromptAnswerNeverForSite,    // "Never on this site" (password save only)
  OESavePromptAnswerDismiss,         // "No", "Not Now", "No Thanks", Esc
  OESavePromptAnswerIgnored,         // closed without a choice
} NS_SWIFT_NAME(OESavePrompt.Answer);

NS_SWIFT_UI_ACTOR
OE_EXPORT @interface OESavePrompt : NSObject
@property(nonatomic, readonly) OESavePromptKind kind;
@property(nonatomic, readonly, copy) NSString* origin;        // "https://accounts.example.com"
@property(nonatomic, readonly, copy) NSString* displayHost;   // "accounts.example.com"
@property(nonatomic, readonly, copy, nullable) NSString* username;      // password kinds; not shown in v1 UI
@property(nonatomic, readonly, copy, nullable) NSString* cardLabel;     // "Visa •••• 4242"
@property(nonatomic, readonly, copy, nullable) NSString* addressLabel;  // one line
@property(nonatomic, readonly) BOOL offersNeverForSite;       // YES only for OESavePromptKindPassword
@property(nonatomic, readonly) BOOL isUserInitiated;
@property(nonatomic, readonly) BOOL isAnswered;
@property(nonatomic, readonly, weak, nullable) OEWebContent* webContent;
/// The first call wins; later calls do nothing. A prompt that is released
/// unanswered answers OESavePromptAnswerIgnored.
- (void)answer:(OESavePromptAnswer)answer;
@end

typedef NS_ENUM(NSInteger, OEAutofillPage) {
  OEAutofillPagePasswords = 0,      // chrome://password-manager/passwords
  OEAutofillPagePaymentMethods,     // chrome://settings/payments
  OEAutofillPageAddresses,          // chrome://settings/addresses
} NS_SWIFT_NAME(OEAutofillPage);
```

New optional `OEWebContentDelegate` methods (main thread):

```objc
/// Chromium wants to offer a save. Show the sheet now or queue it (§6.1).
/// Not implemented → the engine answers OESavePromptAnswerIgnored.
- (void)webContent:(OEWebContent*)webContent showSavePrompt:(OESavePrompt*)prompt
    NS_SWIFT_NAME(webContent(_:showSavePrompt:));
/// Chromium no longer wants the prompt (navigation, a newer prompt, tab
/// closing). The prompt is already answered as Ignored; remove it.
- (void)webContent:(OEWebContent*)webContent withdrawSavePrompt:(OESavePrompt*)prompt
    NS_SWIFT_NAME(webContent(_:withdrawSavePrompt:));
/// A Chromium "Manage…" link (dropdown footer, H-4).
- (void)webContent:(OEWebContent*)webContent openAutofillPage:(OEAutofillPage)page
    NS_SWIFT_NAME(webContent(_:openAutofillPage:));
```

### 5.2 Per-profile switches, counts, and page URLs

Names follow Arc's `ArcBrowserContextPreferences` (PW-1).

```objc
NS_SWIFT_UI_ACTOR
OE_EXPORT @interface OECredentialCounts : NSObject
@property(nonatomic, readonly) NSInteger logins;        // saved passwords, blocked sites excluded
@property(nonatomic, readonly) NSInteger blockedSites;  // "Never on this site" entries
@property(nonatomic, readonly) NSInteger cards;         // local cards
@property(nonatomic, readonly) NSInteger addresses;     // local addresses
@property(nonatomic, readonly) NSInteger cookies;
@end

@interface OEBrowserContext (Autofill)
@property(nonatomic) BOOL passwordSavingEnabled;           // credentials_enable_service
@property(nonatomic, readonly) BOOL canEnablePasswordSaving; // NO: ephemeral context, mock key (§7.1), or policy
@property(nonatomic) BOOL creditCardsSavingEnabled;        // autofill.credit_card_enabled
@property(nonatomic, readonly) BOOL canEnableCreditCardsSaving;
@property(nonatomic) BOOL addressesSavingEnabled;          // autofill.profile_enabled
- (void)fetchCredentialCountsWithCompletion:(void (^)(OECredentialCounts* counts))completion
    NS_SWIFT_NAME(fetchCredentialCounts(completion:));     // imports as async
+ (NSURL*)URLForAutofillPage:(OEAutofillPage)page;
@end
```

### 5.3 Import write API

```objc
/// Records copy strings. Secret bytes come in NSMutableData; the engine
/// copies them and overwrites the NSMutableData with zeros before it
/// returns from the import call. The caller zeroes its own buffers.
NS_SWIFT_UI_ACTOR
OE_EXPORT @interface OEImportedLogin : NSObject
- (instancetype)initWithSignonRealm:(NSString*)signonRealm
                          originURL:(NSString*)originURL
                          actionURL:(nullable NSString*)actionURL
                    usernameElement:(NSString*)usernameElement
                           username:(NSString*)username
                    passwordElement:(NSString*)passwordElement
                           password:(NSMutableData*)passwordUTF8  // empty for blocked entries
                             scheme:(NSInteger)scheme             // logins.scheme (0 HTML, 1 Basic, 2 Digest, 3 Other, 4 Username only)
                      blockedByUser:(BOOL)blockedByUser
                        dateCreated:(NSDate*)dateCreated
                       dateLastUsed:(nullable NSDate*)dateLastUsed
               datePasswordModified:(nullable NSDate*)datePasswordModified
                          timesUsed:(NSInteger)timesUsed
                               note:(nullable NSMutableData*)noteUTF8 NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

NS_SWIFT_UI_ACTOR
OE_EXPORT @interface OEImportedCookie : NSObject
- (instancetype)initWithName:(NSString*)name
                       value:(NSMutableData*)valueUTF8
                      domain:(NSString*)hostKey          // ".example.com" or "example.com"
                        path:(NSString*)path
                    creation:(NSDate*)creation
                  expiration:(nullable NSDate*)expiration // nil = session cookie
                  lastAccess:(nullable NSDate*)lastAccess
                  lastUpdate:(nullable NSDate*)lastUpdate
                      secure:(BOOL)secure
                    httpOnly:(BOOL)httpOnly
                    sameSite:(NSInteger)sameSite          // cookies.samesite (-1 unspecified, 0 none, 1 lax, 2 strict)
                    priority:(NSInteger)priority          // cookies.priority (0 low, 1 medium, 2 high)
                sourceScheme:(NSInteger)sourceScheme      // cookies.source_scheme
                  sourcePort:(NSInteger)sourcePort        // cookies.source_port
             topFrameSiteKey:(nullable NSString*)topFrameSiteKey  // partitioned cookies; nil otherwise
        hasCrossSiteAncestor:(BOOL)hasCrossSiteAncestor NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

NS_SWIFT_UI_ACTOR
OE_EXPORT @interface OEImportedAddress : NSObject
- (instancetype)initWithGUID:(NSString*)guid
                      fields:(NSDictionary<NSNumber*, NSString*>*)fields   // address_type_tokens.type → value (Chromium FieldType, same build)
         verificationStatuses:(NSDictionary<NSNumber*, NSNumber*>*)statuses // address_type_tokens.verification_status
                    useCount:(NSInteger)useCount
                     useDate:(NSDate*)useDate
                dateModified:(nullable NSDate*)dateModified
                languageCode:(nullable NSString*)languageCode NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

NS_SWIFT_UI_ACTOR
OE_EXPORT @interface OEImportedCard : NSObject
- (instancetype)initWithGUID:(NSString*)guid
                  nameOnCard:(NSString*)nameOnCard
             expirationMonth:(NSInteger)month
              expirationYear:(NSInteger)year
                      number:(NSMutableData*)digitsASCII   // 12–19 digits, no spaces
                    nickname:(nullable NSString*)nickname
                    useCount:(NSInteger)useCount
                     useDate:(nullable NSDate*)useDate NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

NS_SWIFT_UI_ACTOR
OE_EXPORT @interface OEImportResult : NSObject
@property(nonatomic, readonly) NSInteger added;
@property(nonatomic, readonly) NSInteger existing;   // already in Open; left as is (§8.4)
@property(nonatomic, readonly) NSInteger failed;     // rejected by Chromium's checks (bad cookie, empty profile, …)
@end

@interface OEBrowserContext (SecretsImport)
/// Each call writes one batch (at most 256 records) and completes on the main
/// thread only after the batch is durable (§8.3). Calls on one context run in
/// order. An ephemeral context fails with OEErrorDomain / OEErrorEphemeralContext
/// (new code 7 in OEDefines.h, after OEErrorUnsupported = 6).
- (void)importLogins:(NSArray<OEImportedLogin*>*)logins
          completion:(void (^)(OEImportResult* _Nullable result, NSError* _Nullable error))completion;
- (void)importAddresses:(NSArray<OEImportedAddress*>*)addresses
             completion:(void (^)(OEImportResult* _Nullable result, NSError* _Nullable error))completion;
- (void)importCards:(NSArray<OEImportedCard*>*)cards
         completion:(void (^)(OEImportResult* _Nullable result, NSError* _Nullable error))completion;
- (void)importCookies:(NSArray<OEImportedCookie*>*)cookies
           completion:(void (^)(OEImportResult* _Nullable result, NSError* _Nullable error))completion;
@end
```

Dictionary keys at the CEF boundary (§4.3) are the initializer parameter names in snake case (`signon_realm`, `origin_url`, …, `top_frame_site_key`). Secrets travel as `CefBinaryValue`.

Engine-side mapping:

- Logins: `PasswordForm` (`signon_realm`, `url`, `action`, `username_element`, `username_value`, `password_element`, `password_value` from UTF-8, `scheme`, `blocked_by_user`, `date_created`, `date_last_used`, `date_password_modified`, `times_used_in_html_form`, `notes`), then `password_manager::FromPasswordForm` and `PasswordStoreInterface::AddLogins(forms, completion)` (`password_store_interface.h:96-97`). This is what `ProfileWriter::AddPasswordForm` does (`chrome/browser/importer/profile_writer.cc:91-101`), with a completion.
- Cookies: `net::CanonicalCookie::FromStorage(…, CanonicalCookieFromStorageCallSite::kCookieManager)` (`net/cookies/canonical_cookie.h:221-238`), partition key from `CookiePartitionKey::FromStorage(top_frame_site_key, has_cross_site_ancestor)` (`net/cookies/cookie_partition_key.h:139`), then `SetCanonicalCookie` with `CookieOptions::MakeAllInclusive()` and a source URL built from scheme, domain, and port. A cookie that `FromStorage` rejects, or whose `CookieAccessResult` is not included, counts as `failed`.
- Addresses: `AutofillProfile` with the Arc GUID and `RecordType::kLocalOrSyncable`, fields set with their verification status, then `AddressDataManager::AddProfile` (`components/autofill/core/browser/data_manager/addresses/address_data_manager.cc:287-303`).
- Cards: `CreditCard` local, with the Arc GUID, then `PaymentsDataManager::AddCreditCard` (`components/autofill/core/browser/data_manager/payments/payments_data_manager.cc:1495-1515`).

### 5.4 Capability flags

```objc
@interface OEEngine (Autofill)
/// YES when the running engine has the 05xx patches and §5.3.
@property(nonatomic, readonly) BOOL supportsSecretsImport;
/// YES when the engine encrypts with the mock key (--use-mock-keychain).
@property(nonatomic, readonly) BOOL usesMockKeychain;
@end
```

### 5.5 OpenWeb (Swift protocols for OpenKit)

`Packages/OpenKit/Sources/OpenWeb/OpenWeb.swift` gains:

```swift
public enum SavePromptKind: Sendable { case password, passwordUpdate, card, address, addressUpdate }
public enum SavePromptAnswer: Sendable { case save, neverForSite, dismiss }

@MainActor public protocol SavePromptRequest: AnyObject {
    var kind: SavePromptKind { get }
    var displayHost: String { get }
    var offersNeverForSite: Bool { get }
    var isAnswered: Bool { get }
    func answer(_ answer: SavePromptAnswer)
}
```

`App/EngineBridge.swift` makes `OESavePrompt` conform. The secrets sink for the import is a protocol in `OpenImport` (§8.1), not in OpenWeb, so `OpenImport` keeps depending on `OpenModel` only.

## 6. UI

### 6.1 Save sheet

One shared component for sheet dialogs: `Packages/OpenKit/Sources/OpenDesign/DialogSheet.swift` (AppKit, no SwiftUI): `DialogSheetPanel` (an `NSPanel`, style `.borderless`, `hasShadow = true`, shown with `NSWindow.beginSheet(_:completionHandler:)`) and `DialogSheetView`. The save sheet uses it with `Typography.promptTitle` and `.promptBody`, matching `ExtensionPromptView` without its icon. `ExtensionPromptSheet` stays unchanged; adopting the shared component with its icon and body list is a later follow-up.

Layout. Values come from the extensions UI plan's sheet; they stay guesses until screenshot S-1.

| Element | Value | Token |
|---|---|---|
| Sheet | width 420; padding 24; corner radius 12; background `Core.popoverBackground`; no icon in v1 (guess) | `DialogSheetMetrics.width`, `.padding`, `.cornerRadius` |
| Title | top 24, left 24, width 372; 15 Semibold; `Core.foregroundPrimary`; up to 2 lines, then middle-truncate the host | `Typography.promptTitle` |
| Body | title bottom + 8; 13 Regular; `Core.foregroundSecondary`; up to 3 lines | `Typography.promptBody` |
| Button row | body bottom + 20; height 28; 24 from the bottom edge | `DialogSheetMetrics.buttonHeight` |
| Buttons | corner radius 8; minimum width 88; gap 8; label 13 Medium; default fill `Core.brandBlue` with white text; other fill `SidebarColors.itemBackground` with `Core.foregroundPrimary`; each shows its key hint ("↩", "esc") in `Typography.keycap` at 0.6 opacity after the label | `DialogSheetMetrics.buttonRadius`, `.buttonMinWidth`, `.buttonGap` |
| Order | right aligned: secondary, then default (rightmost). "Never on this site" is left aligned at x 24 (guess; macOS three-button order). | — |
| Height | fits content: 24 + title + 8 + body + 20 + 28 + 24 (about 140 with a one-line title and body) | — |

Text (Arc's, PW-2):

| Kind | Title | Body | Buttons, left to right |
|---|---|---|---|
| Password | "Save password for <displayHost>?" ("Save this password?" when the host is empty) | "That way, it’ll be auto-filled next time" | "Never on this site" · "No" · "Save" |
| Password update | same as Password | same | "No" · "Save" |
| Card | "Save this card?" | "That way, it can be auto-filled next time" | "Not Now" · "Save" |
| Address, address update | "Save Address?" | "Saved addresses will appear in auto-fill next time you order something." | "No Thanks" · "Save" |

Arc writes the password and card bodies without a final period; keep that. `<displayHost>` is `OESavePrompt.displayHost` (scheme removed, `www.` kept as Chromium formats it). The username and card number are not shown (Arc shows neither).

Keyboard: Return = "Save". Esc and Cmd-. = "No" / "Not Now" / "No Thanks". Tab and Shift-Tab move between buttons when Full Keyboard Access is on; Space presses the focused button. "Never on this site" has no shortcut. Closing the window or quitting releases the prompt unanswered, so the engine answers "ignored". It is not a "No": Chromium counts "No" toward hiding future prompts (`SaveUpdateBubbleController::IsMaxDismissalCountReached`).

Accessibility: the panel has role `AXSheet`, label = title text. The title is `AXHeading`. The default button has `AXDefaultButton`; the dismiss button `AXCancelButton`. On show, post `NSAccessibility.Notification.announcementRequested` with title and body (VoiceOver moves into the sheet). With Reduce Motion, the sheet appears without the slide.

Queue rules (`Packages/OpenKit/Sources/OpenFeatures/SavePromptPresenter.swift`, one per window):

1. Show at once when the prompt's page is the focused pane of a visible window and no sheet is open on that window.
2. Else queue it (FIFO, at most 3 per window; a new prompt for the same page replaces the older one, which the engine has already withdrawn; a fourth prompt drops the oldest unanswered, which the engine then answers "ignored" on release). Show it when its page becomes the focused pane.
3. Peek pages attach to the window that shows the Peek; Little Open pages to the Little Open window.
4. `withdrawSavePrompt` removes the prompt from the queue or closes the sheet without an answer.
5. A page in a Space of another window, or in a background Space, waits until shown. A page that closes drops its prompt.
6. No timeout: Arc's sheet waits for an answer (PW-2).
7. After "Save", show no confirmation (Arc shows none we know of; screenshot S-3).

Renders: a new `features-render save-sheet --kind password|update|card|address --out FILE [--scale 1|2] [--appearance light|dark]` draws the four sheets offscreen (`docs/m4/save-sheet-*.png` next to the other feature renders), with fixture hosts only. `features-render check` asserts each sheet's frame and button order.

Step 3 also has a real-App mock path, compiled only with `OPEN_AUTOMATION`: `save-prompt` enqueues synthetic kind/host metadata through each window's production presenter. Answers click real sheet buttons; unanswered release emits `ignored`. `tools/e2e/engine_e2e.py --only passwords` dispatches the M-* rows in `tools/e2e/passwords.py`. These prove sheet UI and request lifetimes before the engine bridge; P-* engine/storage rows remain Step 4. Queue length in automation counts waiting requests (maximum three), separate from the visible sheet. No credentials are displayed or stored by this path. Arc visual parity still needs S-1.

### 6.2 Fill dropdown (Chromium's)

Open keeps Chromium's `PopupViewViews` and `PasswordGenerationPopupViewViews` (D-3). Open adds nothing to their layout. For reference and for review against screenshot S-2:

| Item | Value |
|---|---|
| Window | Views widget, child window of the Open window, anchored under the field (above it when there is no room); minimum width 156 (`popup_view_views.cc:128`) |
| Rows | Chromium layout (`ChromeLayoutProvider`); icons 16 or 20 pt (`popup_cell_utils.cc:76-79`); a password row shows the username and a masked password |
| Footer | "Manage passwords…" / "Manage addresses…" / "Manage payment methods…" (Chromium strings) → H-4 → §6.3 |
| Colors | Chromium's color pipeline, which follows the macOS light or dark appearance |
| Keyboard | Down and Up move; Return or Tab accepts; Esc closes; typing filters. Keys reach the popup through the renderer, so `keyEquivalentHandler` and Open's reserved shortcuts are unaffected |
| Accessibility | `kListBox` with option rows (`popup_view_views.cc:374-377`); Chromium announces the selected row |
| Security | Clicks right after the popup opens are ignored (`autofill_popup_controller_impl.cc:545-551`); the popup hides when the pointer is locked |

Checks Open owns: the popup must not open behind the command bar, a Peek, or the Little Open window, and must close when the sidebar hides or the window changes Space. §9.2 P-16 covers these.

### 6.3 Manage pages

| Entry | Opens |
|---|---|
| Command bar "Manage Passwords" (`manage-passwords`) | `chrome://password-manager/passwords` in the focused Space |
| Settings ▸ Profiles ▸ Passwords (`ProfilePage.passwords`) | same page, for the profile selected in Settings |
| Settings ▸ Profiles ▸ Credit Cards (`.paymentMethods`) | `chrome://settings/payments` |
| Settings ▸ Profiles ▸ Privacy and Security (`.privacy`) | `chrome://settings/privacy` |
| Settings ▸ Profiles ▸ Notifications (`.notifications`) | `chrome://settings/content/notifications` |
| Dropdown footers (H-4) | the matching page, in the page's own Space |

Placement rule (guess; Arc's exact rule is unknown): select an existing tab with the same URL path in the target Space; else open a new Today tab at the top (Arc placement, `open` command). Target Space: the focused Space if it uses the target profile; else the most recently focused Space of that profile, which then gets focus. If no Space uses the profile, the Settings row is disabled and its tooltip reads "Assign this Profile to a Space to manage its passwords." (Open text).

The shell's Manage routing uses `AutofillPages.swift`: it searches the explicit target Space's pinned and Today trees (folders and split panes included), matches scheme/host/path, selects the existing tab, or inserts at Today index 0. Private factories refuse the route, and private command bars exclude Manage Passwords. Settings Passwords and Credit Cards call the same helper through the existing Section 10 adapter. That adapter currently chooses the first Space for the selected Profile and retains its no-Space `openProfilePage` fallback; the target-priority and disabled-row behavior above remain planned. Engine dropdown callbacks and save/fill integration remain separate work.

The pages are Chromium's WebUI in a hosted tab (they need a Chrome style page). Open does not restyle them. Two dependencies:

- Branding: Chromium strings say "Chromium" on these pages (`chrome/app/chromium_strings.grd`, `IDS_PRODUCT_NAME`). The product name must read "Open" before release (Q-5).
- URL display: Arc showed `arc://…` (PW-5). Q-4 decides whether Open shows `open://…`.

Viewing a password on the page asks for Touch ID or the Mac password (Chromium's `password_manager_util_mac.mm`). Chromium's page also offers CSV import and export of passwords; Open keeps both.

Addresses: Arc has no Addresses row (PW-5). Open adds none in v1 (Q-1). Addresses are reachable from the payments page's side menu and from the dropdown footer.

### 6.4 Settings switches

Arc's 1.170 Profiles pane has no switches for saving (IS §18). Open shows none in v1; the switches stay on Chromium's pages (Password Manager ▸ Settings, Payment methods, Addresses). `OEBrowserContext.passwordSavingEnabled` and friends exist for automation, for the mock-key rule, and for a later Settings design if S-5 shows Arc had switches.

### 6.5 Passkeys

- v1: Chromium's WebAuthn dialog (Views) shows through the real dialog host (H-7), centered at the top of the page. Security keys over USB and phones over hybrid (QR code and Bluetooth) work. The app already has the `bluetooth` and `usb` entitlements (release.md §4).
- After U-8: iCloud Keychain passkeys use the system sheet. That needs `com.apple.developer.web-browser.public-key-credential` (managed; Apple approves it), which Chromium checks at runtime (`device/fido/mac/icloud_keychain_sys.mm:228-240`), plus a provisioning profile. release.md's entitlement list changes then.
- Not in v1: Chromium's Touch ID authenticator. It needs the restricted `keychain-access-groups` entitlement `<Team ID>.<bundle id>.webauthn` (`chrome/browser/webauthn/chrome_web_authentication_delegate.cc:394-408`). Arc's Touch ID passkeys cannot move to Open anyway (PW-7); the import report says so (§8.6).

### 6.6 HTTP authentication

Chromium's HTTP auth dialog is web-modal too. With H-7 it shows, and the password manager fills it and offers to save from it. Arc used its own dialog (PW-11). Restyling it belongs to app-shell §4.9, not this plan.

## 7. Security

### 7.1 Keychain

1. One item: service "Open Safe Storage", account "Open". The engine creates it on first use with a random password (`keychain_password_mac.mm:99-110`); its access list holds the signed Open app. Only the browser process reads it; the network service gets the key over Mojo from `os_crypt_async`.
2. Never "Chromium Safe Storage". OpenEngine always sets both names before `CefInitialize` (`OEEngine.mm:360-363`). Step 2 adds a startup assertion: if `configuration.keychainServiceName` is empty or equals "Chromium Safe Storage", `start(configuration:)` throws.
3. Arc's key: Swift reads "Arc Safe Storage" (probe order in `probeChromiumKeychainPair`) once per import run, after consent, derives the AES key, and zeroes the password at once (`ChromiumCrypto.swift`). The Arc key never reaches the engine or disk.
4. Mock key: ad-hoc builds encrypt with Chromium's public mock key. So when `OEEngine.usesMockKeychain` is YES:
   - The engine shows no password or card save prompt: H-1 and H-2 answer every save prompt as ignored without calling the shell (`open_engine::SecretsPromptsAllowed()` is false). No pref is written, so a later signed build on the same data keeps the user's settings. Addresses are not secrets and still prompt.
   - `canEnablePasswordSaving` and `canEnableCreditCardsSaving` return NO.
   - `canImportPasswordsAndCookies` is false (§7.4); the wizard shows its "can't be imported yet" copy.
   - The e2e harness passes `--open-allow-mock-keychain-secrets`, which makes `SecretsPromptsAllowed()` true for fixture data. The switch never lifts the import rule; only the synthetic fixture command (§9.1) writes imported records on a mock-key build.
5. Release builds: release.md §4.4 already treats repeated Keychain prompts as a defect. §9.5 adds the checks.

### 7.2 At rest

| Data | Where (engine profile dir) | Encrypted |
|---|---|---|
| Passwords, password notes | `Login Data` (`logins.password_value`, `password_notes.value`) | Yes, `v10` AES-128-CBC with the Open key |
| Site, username, form fields | `Login Data` | No (Chromium design) |
| Cookie values | `Cookies` (`encrypted_value`) | Yes |
| Card numbers | `Web Data` (`credit_cards.card_number_encrypted`) | Yes |
| Card name, expiry, nickname; addresses; form history | `Web Data` | No (Chromium design) |

Profile folders are created with mode 0700 (`S_IRWXU` in `base::CreateDirectory`, `base/files/file_util_posix.cc:1257`); §9.2 P-18 checks it. Open writes no secret to its own stores, logs, snapshots, or the import ledger.

### 7.3 Filling rules

- No fill on page load: fill on account select (D-6). Accepting a dropdown row is the only way to fill.
- Chromium hides filled values from page JavaScript until the user interacts (`PasswordValueGatekeeper`, `components/autofill/content/renderer/password_autofill_agent.h:377-381`).
- Cross-origin iframes: Chromium's policy unchanged. Passwords wait for a selection in a cross-origin iframe (`password_form_filling.cc:246-247`). Address and card values fill across frames only under `AutofillDriverRouter::IsSafeToFill` (`components/autofill/core/browser/foundations/autofill_driver_router.h:171-201`): same origin as the clicked field, or main origin with the `autofill` permissions policy, and sensitive card fields never from the main origin into another origin's frame.
- Insecure pages: Chromium waits for a selection on HTTP pages and refuses card fill on non-secure contexts.
- Incognito: no saving or filling from the profile (`IsSavingAndFillingEnabled` needs `!IsOffTheRecord()`, `chrome_password_manager_client.cc:302-317`).
- Open changes none of these rules.

### 7.4 Import consent flow

1. Wizard Choose step: "Passwords and cookies" is OFF by default (`ImportPlan.secretsRequested`).
2. Turning it on adds the Passwords step. Copy is the existing engine-ready copy (`ImportWizard.swift:126-127`); first-run uses its S-3 line.
3. Only "Import Passwords and Cookies" calls `consentToSecrets()`; the adapter creates `SecretsImportConsent.grantedByUser(reason: "import-wizard")` inside the import task, never earlier, never stored.
4. The adapter refuses (no token, no Keychain call) unless `canImportPasswordsAndCookies` is true: `OEEngine.supportsSecretsImport && !OEEngine.usesMockKeychain`.
5. Keychain: metadata probe (no UI), one data read (one macOS prompt), key derived once per run.
6. Denial or a missing item: E-3 in the report; the non-secret import is unaffected; no second prompt in the run (first-run §6.6).
7. "Continue Without Passwords" and Cancel create no token and call no Keychain API (existing PR #24 rule; the external `swiftc` check in model.md stays valid).

### 7.5 Memory and logs

- Keep import-phase2 §7: counts only in logs and reports; no URL, username, cookie name with host, or value.
- Records are converted to OE objects in batches of at most 256; the importer zeroes its records after each batch; the engine zeroes its `NSMutableData` copies (§5.3).
- `OESavePrompt.username` is never logged; the automation event log records `kind` and `displayHost` only, and only for fixture hosts.

## 8. Import write path

### 8.1 Shape and profile mapping

New in `OpenImport` (no engine import):

```swift
/// The engine side of the secrets import. App/SecretsImportSink.swift
/// implements it over OEBrowserContext (§5.3). The CLI uses a counting sink.
/// The sink copies what it needs before it returns; the importer zeroes the
/// batch right after (zeroSecrets() on each record).
@MainActor public protocol SecretsImportSink: AnyObject {
    func importLogins(_ batch: borrowing [ImportedLoginRecord]) async throws -> SecretsWriteResult
    func importAddresses(_ batch: borrowing [ImportedAddressRecord]) async throws -> SecretsWriteResult
    func importCards(_ batch: borrowing [ImportedCardRecord]) async throws -> SecretsWriteResult
    func importCookies(_ batch: borrowing [ImportedCookieRecord]) async throws -> SecretsWriteResult
}
public struct SecretsWriteResult: Sendable { public var added, existing, failed: Int }

@MainActor public final class ArcSecretsImporter {
    public init(arcUserData: URL, ledger: SecretsImportLedger)
    /// One run. `sinks` maps each Arc profile directory name to the sink of
    /// its Open profile (profiles.md §8.1 mapping). Returns counts only.
    public func run(key: [UInt8], consent: SecretsImportConsent,
                    sinks: [String: SecretsImportSink]) async throws -> ArcSecretsImportReport
    /// e2e only (§9.3). Builds its own two-profile fixture from the known mock
    /// password and reads it through the existing internal
    /// `SecretsReadAccess.synthetic` path. Takes no path, key, or ciphertext
    /// (model.md PR #24 rule), so it cannot reach real Arc data.
    public static func runSyntheticFixture(sinks: [String: SecretsImportSink]) async throws -> ArcSecretsImportReport
}
```

Threading: the importer runs on the main actor. A batch reader (`ArcSecretsBatchReader`, new, non-`Sendable`, in `ArcSecrets.swift`) returns at most 256 owned records per call from an open copy of one file. Reading and decrypting one batch is a few milliseconds of SQLite and AES work (guess; Step 5 measures it). Between batches the importer awaits the engine, so the UI stays responsive. Records never cross an actor boundary, which keeps them non-`Sendable` as import-phase2 §3.3 requires. The existing borrowing `readWithKey` stays for the CLI.

- Mapping: the same table that `ArcImport` uses for Spaces (`profileID(for:)`; profiles.md §8.1): Arc profile directory basename ↔ Open `dataDirectoryName` ↔ `ProfileID`. The App builds one sink per mapped profile from that profile's `OEBrowserContext` (created through the profile context registry if not yet live). A profile with no Arc directory gets no sink. An Arc directory with no Open profile is skipped and counted.
- One Keychain read serves all Arc profiles: Chromium uses one key per app.
- Batches: at most 256 records; after the sink returns, the importer zeroes every record of the batch and drops it. One file set in memory at a time (import-phase2 §7).

**Section 15 implementation erratum (2026-11-06):** `SecretsImportSink` adds an optional `openProfileID: UUID?` property with a default `nil` implementation. The App can supply its opaque Open profile ID for the ledger without changing `run(key:consent:sinks:)`. The required `runSyntheticFixture(sinks:)` entry remains. A second synthetic overload accepts a destination ledger and `stopAfter` step for CLI recovery verification; it accepts no source path, key, or ciphertext. Its fixed synthetic scenarios also cover batching, field-size boundaries, an empty source, and nonlocal address filtering.

### 8.2 Reader changes (`ArcSecrets.swift`)

| Record | Add |
|---|---|
| `ImportedLoginRecord` | `usernameElement`, `passwordElement`, `scheme`, `dateLastUsed`, `datePasswordModified`, `noteBytes` (from `password_notes.value`, decrypted, for the row with an empty `key`: Chromium's user-visible note, `components/password_manager/core/browser/password_form.h:551`); blocked rows (`blacklisted_by_user = 1`) are passed through with empty password instead of skipped; federated rows (`federation_url` not empty) are skipped and counted |
| `ImportedCookieRecord` | `creation`, `lastAccess`, `lastUpdate`, `sameSite`, `priority`, `sourceScheme`, `sourcePort`, `topFrameSiteKey`, `hasCrossSiteAncestor` (columns from `net/extras/sqlite/sqlite_persistent_cookie_store.cc`, schema of the source DB version) |
| `ImportedAddressRecord` | `verificationStatuses`, `dateModified`, `languageCode`; only `record_type = 0` rows (`address_autofill_table.cc:50-65`) |
| `ImportedCardRecord` | `nickname`, `useCount`, `useDate`; CVCs are not read |

Columns missing in an older source DB read as defaults. The synthetic fixture (§9.3) covers each new column.

**Section 15 implementation erratum (2026-11-06):** Cookie expiry is a lifetime, so a valid future expiry is not subject to the activity timestamp limit of now + 24 hours used by the earlier reader. A zero expiry remains a session cookie. Only activity timestamps use that limit. Batches visit at most 256 source rows as well as returning at most 256 records, so a file of skipped rows also yields between reads. Selected fields are limited to 16 KiB each, 64 KiB per row, and address token values to 64 KiB per address (512 tokens maximum); oversized input is refused before copying it into Swift records.

### 8.3 Write order and durability

Per mapped profile, in Local State order (Default first):

| Step | Source file | Sink calls | Durable when |
|---|---|---|---|
| 1 | `Login Data` | `importLogins` | `AddLogins` completion ran (`LoginDatabase` writes are SQLite statements, `login_database.cc:1342-1425`) |
| 2 | `Web Data` | `importAddresses`, then `importCards` | a read through the same web data service returns (web DB tasks run in order and commit per task, `components/webdata/common/web_database_backend.cc:87-97`) |
| 3 | `Cookies` | `importCookies` | `FlushCookieStore()` completion ran (`cookie_manager.mojom:511`; the store otherwise commits every 30 s or 512 changes, `sqlite_persistent_cookie_store.cc:1235-1237`) |

Why this order: passwords are the smallest and most valuable set; cookies are the largest and the only set a crash would otherwise leave half in memory. After step 3, the App reloads live tabs of that profile once, so they pick up imported sessions.

### 8.4 Idempotency (existing Open data wins)

| Kind | Key | Rule |
|---|---|---|
| Login | (`signon_realm`, `username_value`) | Before the first batch, the engine reads all logins of the profile once (`GetAllLogins`, `password_store_interface.h:165`). A record whose key exists is `existing`, whatever its password: Open's newer password wins. This matters because `AddLogin` replaces on a primary key conflict (`login_database.cc:1411-1425`). Blocked entry: key (`signon_realm`, blocked). Notes are added only with a new login. |
| Cookie | (name, domain, path, partition key) | The engine reads `GetAllCookies` once; existing keys are `existing` (Arc's "skip existing cookies", PW-9). Others go through `SetCanonicalCookie`, which also replaces nothing then. |
| Address | GUID, then content | `AddProfile` skips an existing GUID or an equal profile (`address_data_manager.cc:732-740`). The engine counts those as `existing`. |
| Card | GUID, then content | `AddCreditCard` skips an existing GUID or equal contents (`payments_data_manager.cc:1504-1515`). |

So a second run reports `added = 0` for every kind (§9.3 I-3).

### 8.5 Ledger and crash recovery

File `<data root>/State/secrets-import.json`, written atomically (temp file and rename) after each durable step. No secret, URL, host, or username. Shape:

```json
{ "version": 1, "runID": "UUID", "started": "2026-10-25T23:30:00-07:00",
  "profiles": { "Default": { "openProfile": "<ProfileID>",
    "logins": {"state": "done", "added": 12, "existing": 0, "failed": 0},
    "webData": {"state": "done", "addresses": [1,0,0], "cards": [0,0,0]},
    "cookies": {"state": "pending"} } },
  "finished": null }
```

- On launch, an unfinished ledger shows in the wizard's Report as: "The last import stopped before it finished. Import again to add the rest." (Open text). Re-running is safe (§8.4). The next run starts a new `runID`; it does not skip steps, because only the engine knows what exists.
- A crash inside a step loses at most that step's not-yet-durable writes; the re-run adds them.

### 8.6 Report

The wizard Report (`ImportWizard.swift`) replaces the single "Passwords and cookies" count with four lines when secrets ran: "Passwords: <added> imported, <existing> already in Open", and the same for "Cookies", "Addresses", "Cards". Failures add "<n> couldn't be imported". When Arc had passkeys in its Touch ID store, the report cannot know it; the Passwords step body adds one sentence: "Passkeys saved only in Arc stay in Arc. Sign in to those sites again to create new ones." (Open text).

### 8.7 CLI

`openkit import-arc-secrets` keeps `--dry-run` (counts, no Keychain without `--allow-keychain-access`). It gains no write mode: writes need the engine and run only in the App. `openkit verify-secrets-fixture` runs `ArcSecretsImporter` with a counting sink over the extended fixture and prints per-kind counts, so the reader changes in §8.2 have a CLI check.

**Section 15 implementation erratum (2026-11-06):** The CLI adds `--stop-after logins|webData|cookies`. It stops after the first profile's selected durable step, checks the unfinished ledger, and repeats all steps with a new run ID against the same sinks and ledger. `tools/verify-all.sh --only verify-secrets-fixture` runs the normal and three recovery commands plus the external consent compile check. These are OpenKit sink-contract checks; engine durability, App relaunch, and wizard wiring still need the engine acceptance in §9.3.

## 9. Verification (end to end; no unit tests)

### 9.1 Fixtures

- Server: `tools/e2e/fixtures/passwords/server.py` (Python standard library, `-I`), one port, started by the harness. Hosts through Open's `additionalSwitches`: `--host-resolver-rules=MAP *.example.com 127.0.0.1:<port>` (rule syntax: `net/dns/mapped_host_resolver.h:41`). Origins: `http://login.example.com`, `http://other.example.com` (cross-site), `http://localhost:<port>` (secure context for cards and passkeys).
- Pages (our own HTML, synthetic data only): `login.html` (username + password, POST `/login` → 302 `/welcome`), `change.html` (current + new password), `signup.html` (`autocomplete="new-password"`), `iframe.html` (main page on `other.example.com` with the login form in an `http://login.example.com` iframe), `address.html` (shipping form with `autocomplete` tokens), `card.html` (on `localhost`, card number `4111 1111 1111 1111`, a future expiry), `cookies` endpoints (`/set-cookies` sets the cookies in §9.4; `/echo-cookies` returns the names it received as JSON), `webauthn.html` (on `localhost`, `navigator.credentials.create` and `get`).
- Credentials are fixture strings (`fixture-user`, `fixture-password-1`). No real site, no real account.

Automation additions (`docs/automation.md`; App automation only, which the app enables only with its automation flag):

| Command | Args | Result |
|---|---|---|
| `policy` | `savePrompt`: `record` / `save` / `never` / `dismiss` / `hold` | Answer save sheets automatically or hold them |
| `save-prompt` | `answer` | Answer the held sheet through the real sheet buttons |
| `credentials` | `profile` | `OECredentialCounts` |
| `import-secrets-fixture` | `map`: fixture Arc directory → Open profile name (default `{"Default": "Default", "Profile 1": "Work"}`) | Runs `ArcSecretsImporter.runSyntheticFixture` (§8.1) with the real App sinks, returns counts; refuses unless the build is Debug or `--open-e2e` is set |
| `events` | — | Adds `savePrompt` (`kind`, `displayHost`, `answer`) and `autofillPage` events |

### 9.2 Suite `--only passwords` (`tools/e2e/engine_e2e.py`, `--style chrome`, `--open-allow-mock-keychain-secrets`)

| # | Flow | Pass when |
|---|---|---|
| P-1 | Sign in on `login.html` | `savePrompt` event kind `password`, host `login.example.com`; sheet visible in `snapshot`; title text matches §6.1 |
| P-2 | Answer Save | `credentials.logins == 1` |
| P-3 | Reload `login.html`; `click` the username field | A child window of Open appears (`windows`) with the dropdown; `snapshot` saved |
| P-4 | `key` Down, Return | Both fields hold the fixture values (`eval` after the gesture) |
| P-5 | `change.html` with a new password | kind `passwordUpdate`; no "Never on this site" button; after Save, the dropdown fills the new password |
| P-6 | New site, answer Never | `blockedSites == 1`; signing in again shows no sheet |
| P-7 | Open `login.html` and read the fields right after load | Both empty (no fill on load) |
| P-8 | `iframe.html` | The dropdown offers the credential in the iframe only after a click; nothing fills on load |
| P-9 | `address.html` submit | kind `address`; Save → `addresses == 1` |
| P-10 | Second address form, click a field | Dropdown shows the address; selection fills name, street, city, postal code |
| P-11 | `card.html` submit | kind `card`; Save → `cards == 1` |
| P-12 | Card form again, select the card | Number, name, expiry filled; no crash if Chromium offers re-auth (crash risk 1) |
| P-13 | Command bar "Manage Passwords" | A tab at `chrome://password-manager/passwords` in the focused Space; page shows 1 password row (`eval` on the page DOM) |
| P-14 | Dropdown footer "Manage passwords…" | `autofillPage` event, then the same tab is selected (no second tab) |
| P-15 | Every flow above | Open's process alive; no crash report in `~/Library/Logs/DiagnosticReports` newer than the run |
| P-16 | Open the command bar while a dropdown is up; switch Space; hide the sidebar | The dropdown closes each time |
| P-17 | Second profile (`space-create profile:"Work"`), same login page | No dropdown entry; `credentials(profile:"Work").logins == 0` |
| P-18 | After the run | `Login Data` copy: `password_value` of every row starts with `v10`; the fixture password bytes are not in the file; `stat` mode of the engine dir is 0700 |
| P-19 | Incognito window, sign in | No sheet |
| P-20 | `webauthn.html` with a DevTools virtual authenticator (`WebAuthn.enable`, `WebAuthn.addVirtualAuthenticator`, ctap2, usb) | `create` and `get` resolve |
| P-21 | `webauthn.html` without a virtual authenticator | Chromium's WebAuthn dialog shows as a child window (`windows`, `snapshot`); Esc closes it; the promise rejects with `NotAllowedError` |
| P-22 | Relaunch without `--open-allow-mock-keychain-secrets` (mock-key build); sign in on a new fixture site | No sheet, no `savePrompt` event; `logins` unchanged; `canEnablePasswordSaving` is false |
| P-23 | On `login.html` with a saved login, `eval` `navigator.credentials.get({password: true})` | Resolves to `null` within 2 s; no dialog window |

### 9.3 Suite `--only secrets-import`

The fixture extends `SyntheticSecretsFixture`: two Arc profile directories (`Default`, `Profile 1`) and a `Local State` listing both, generated in a fresh `0o700` temp dir from the known mock password, with the full column sets of §8.2. Contents: per profile 3 logins on `login.example.com` and `other.example.com` (one with a note), 1 blocked site, 1 federated row, 4 cookies (persistent, session, HttpOnly, partitioned), 1 expired cookie, 1 address, 1 card. The two profiles hold different usernames and cookie names.

| # | Flow | Pass when |
|---|---|---|
| I-1 | `space-create profile:"Work"`; map `Profile 1` → Work; `import-secrets-fixture` | Counts per profile: logins 3, blocked 1, addresses 1, cards 1, cookies 4 added; federated 1 and expired 1 skipped |
| I-2 | Open `login.html` in each profile | Each dropdown shows only its own profile's usernames |
| I-3 | Run `import-secrets-fixture` again | `added == 0` for every kind; counts unchanged |
| I-4 | Save a new password for a fixture username in Open, then import again | `existing` counts it; the dropdown fills Open's newer password |
| I-5 | Kill Open (`SIGKILL`) right after the logins step reports done; relaunch; import again | Ledger shows the unfinished run; final counts equal I-1; no duplicates |
| I-6 | Same with the kill during the cookie step | Same as I-5 |
| I-7 | `/echo-cookies` in each profile after a relaunch | Each profile sends only its imported cookie names |
| I-8 | Wizard on a mock-key build (with or without the e2e flag) | Passwords step shows "can't be imported yet"; no consent token is created (automation counts adapter calls) |

`openkit verify-secrets-fixture` (CLI) prints the same per-kind counts with a counting sink.

### 9.4 Cookie round trip (in `--only passwords`)

| # | Flow | Pass when |
|---|---|---|
| C-1 | `/set-cookies` on `login.example.com` sets `oe_persist` (Max-Age 1 day, HttpOnly), `oe_session` (no expiry), `oe_lax` (SameSite=Lax, 1 day); `quit`; relaunch with the same `OPEN_USER_DATA` | `/echo-cookies` returns all three (session cookies persist: `persist_session_cookies`, profiles §6.2) |
| C-2 | Same, then `SIGKILL` 35 s after `/set-cookies`; relaunch | All three present (store committed within its 30 s interval) |
| C-3 | Copy of `Cookies` | The three rows have empty `value` and an `encrypted_value` starting with `v10` |

### 9.5 Keychain checks (Developer ID build only; after U-1 and U-2)

| # | Check | Pass when |
|---|---|---|
| K-1 | `security find-generic-password -s "Open Safe Storage" -a Open` (attributes only; never `-w` or `-g`) | Item exists after the first saved password |
| K-2 | Launch the same build twice | No Keychain prompt on the second launch (release §4.4) |
| K-3 | `security find-generic-password -s "Chromium Safe Storage"` before and after a run | Open created no such item (same result before and after) |

Ad-hoc builds cannot run K-1…K-3; the report says so.

### 9.6 Never

- Never run against the user's real Open data root or real Arc data. Every suite uses a fresh temp root.
- Never call the real "Arc Safe Storage" item. The fixture path makes no Keychain call (import-phase2 lead decision).
- Never paste usernames, cookie values, or page text beyond fixture strings into results or PRs.

## 10. Implementation order

| Step | Owner | Work | Files | Acceptance |
|---|---|---|---|---|
| 0 | engine lead | Probe today's fork with P1: run §9.2 P-1, P-3, P-9, P-11, P-12, P-21 by hand through automation (passwords added through `chrome://password-manager` "Add"). Record what shows and every crash. | `docs/engine-spike/results-passwords-probe.json`; notes in `docs/engine-patches.md` | Results committed; crash list with stacks |
| 1 | engine lead | Patches 0501–0505; overlay `open/browser/autofill/*`; H-2 and H-7 in `open_browser_window.mm` | `Engine/fork/patches/chromium/05xx-*`, `manifest`, `series`; overlay files | Engine builds; Step 0 flows run with no crash; Chromium's own bubbles never appear |
| 2 | OpenEngine | §5 API; mock-key rule; startup name assertion; `docs/engine-api.md` section "Passwords and autofill" | `Engine/OpenEngine/include/OpenEngine/OEAutofill.h`, `src/OEAutofill.mm`, `OEWebContent.mm`, `OEEngine.mm`, `OEClient.mm` | Automation can list prompts and counts on the fork build |
| 3 | shell | `DialogSheet` (shared), `SavePromptPresenter`, OpenWeb protocol, `features-render` sheet renders; design review by the lead and an Opus designer | `OpenDesign/DialogSheet.swift`, `OpenDesign/Typography.swift` (2 tokens), `OpenFeatures/SavePromptPresenter.swift`, `OpenWeb/OpenWeb.swift`, `features-render` scene | `features-render check` passes with the new renders |
| 4 | shell (App) | Delegate wiring, Manage pages (§6.3), `manage-passwords` handler, `openProfileSubpage` adapter, automation commands, `--only passwords` suite | `App/EngineBridge.swift`, `App/…` window glue (app-shell files), `App/Automation/*`, `tools/e2e/engine_e2e.py`, `tools/e2e/fixtures/passwords/*` | §9.2 and §9.4 all pass; results in `docs/engine-spike/results-passwords.json` |
| 5 | shell + import | §8: reader fields, `ArcSecretsImporter`, ledger, `App/SecretsImportSink.swift`, wizard gate and Report, first-run copy (§14), `--only secrets-import` | `OpenImport/ArcSecrets.swift`, `OpenImport/ArcSecretsImporter.swift` (new), `OpenImport/SecretsImportLedger.swift` (new), `OpenImport/SyntheticSecretsFixture.swift`, `OpenSettings/ImportWizard.swift`, `App/SecretsImportSink.swift` | §9.3 all pass; `openkit verify-secrets-fixture` passes; the PR #24 external compile check still rejects token-less calls |
| 6 | release | After U-1/U-2: K-1…K-3. After U-8: iCloud passkey entitlement and a P-20 run without the virtual authenticator | `App/Open.entitlements`, release docs | §9.5 passes |

Steps 0–2 queue behind P1 in the shared Chromium tree (engine-patches lead decision 1). Step 3 can start now (no engine). Each PR runs `tools/verify-all.sh` (AGENTS.md rule 10).

## 11. Risks

| Risk | Mitigation |
|---|---|
| Hidden `Browser` code paths that expect a `BrowserView` crash on password or autofill events | Step 0 probe; H-2 null objects; H-6 null dialogs; P-15 crash check on every flow |
| Chromium's dropdown misbehaves as a child of a non-Views window (focus, z-order, Space switch) | P-3, P-16; fallback is an Open dropdown driven by `AutofillPopupView::Create` — a new plan if needed |
| The modal sheet blocks the window and annoys users | It is Arc's behavior (PW-2). Revisit after S-1 |
| Mock-key dev builds: users who run ad-hoc builds daily cannot save passwords | Intended (§7.1). Signed builds (U-2) remove it |
| Cookie import into a profile whose tabs are live | Existing-wins rule; reload after step 3 |
| CEF API churn across rebases | Overlay headers only; patches are one or two hunks each |
| Chromium strings say "Chromium" on Manage pages | Q-5 |

## 12. Open questions (recommendation first)

| # | Question | Recommendation |
|---|---|---|
| Q-1 | Add an "Addresses" row to Settings ▸ Profiles? | No. Arc has none (PW-5). Addresses stay reachable from the payments page and the dropdown footer. |
| Q-2 | Card re-auth before filling (Chromium "mandatory re-auth": Touch ID or Mac password before a card fills)? | Turn it on by default for new profiles (pref `autofill.payment_methods_mandatory_reauth`, `autofill_prefs.h:214-215`), with no opt-in bubble. Cards are the most sensitive data here, and the system prompt needs no Open UI. Arc's choice is unknown. |
| Q-3 | iCloud Keychain passkeys in v1? | Yes: request the managed entitlement now (new user item U-8). Ship security keys and phones without it. |
| Q-4 | Show Chromium pages as `open://…` in the URL field and command bar? | Yes, as a display alias only (the engine still loads `chrome://`). Arc showed `arc://…` (PW-5). Small shell item for app-shell §4.3; not in this plan. |
| Q-5 | Rename Chromium's product name strings to "Open"? | Yes, in P5 (trim and brand): `chrome/app/theme/chromium/BRANDING` and `IDS_PRODUCT_NAME` in `chromium_strings.grd`. Needed before release because the Manage pages show it. |
| Q-6 | Keep the Credential Management account chooser off (Arc parity) even though some sites use `navigator.credentials.get`? | Yes. Sites fall back to their form; the dropdown still fills. |
| Q-7 | Show the username in the save sheet? | No (Arc shows only the host). Revisit after S-1. |

## 13. Screenshots needed from the user (Arc, their own Mac)

Agents may not launch Arc (AGENTS.md rule 4). Use a throwaway test account on a site you trust; do not capture real passwords.

| # | Capture | Answers |
|---|---|---|
| S-1 | The save password sheet after signing in to a site; then the same for a changed password; then "Save this card?" and "Save Address?" if you can trigger them (a test shop form) | Sheet size, icon, button order, colors (§6.1 guesses) |
| S-2 | Click a username field on a site where Arc saved a password; capture the dropdown | Chromium popup or an Arc variant (PW-3) |
| S-3 | The moment after pressing "Save" | Any confirmation toast |
| S-4 | A sign-up form's new password field (click it) | Does Arc offer "Suggest strong password"? (D-7) |
| S-5 | Settings ▸ Profiles ▸ click "Passwords", then "Credit Cards" | What opens, and whether a switch shows (§6.4) |
| S-6 | The URL field while `arc://password-manager/passwords` is open | URL display (Q-4) |

## 14. Doc follow-ups (in the PRs of §10)

- `docs/engine-patches.md`: add P9 "Passwords and autofill bridge" pointing here (Step 1).
- `docs/engine-api.md`: new section from §5 (Step 2).
- `docs/automation.md`: §9.1 commands (Step 4).
- `docs/plans/first-run.md` §5.4 and S-3: remove "until the browser engine can store secrets, this step checks and counts only" once Step 5 lands.
- `docs/plans/release.md` §4: entitlement change after Q-3 and U-8.
- `docs/status.md`: §1.15 "Write imported secrets", §1.17 "Password manager", §3.1 gaps 1–2, §5.4 decision → planned, citing this plan.
- `docs/plans/settings-library.md` P-9: the row label is "Credit Cards" (IS §18; the code already says so); Arc's symbol for it is `creditcard.and.123` (PW-5).

## Appendix A. Chromium source index

| Topic | File:lines |
|---|---|
| Tab helpers that attach the managers | `chrome/browser/ui/tab_helpers.cc:276-317, 575, 579` |
| Save prompt entry | `chrome/browser/password_manager/chrome_password_manager_client.cc:403-443` |
| Saving and filling enabled | same file `:302-317` |
| Manage page navigation | same file `:1409-1421` |
| Prompt state machine | `chrome/browser/ui/passwords/manage_passwords_ui_controller.cc:217-254, 1230-1320, 1425-1437, 1536-1547, 1668-1680` |
| `TabDialogs` | `chrome/browser/ui/tab_dialogs.h`; `chrome/browser/ui/views/tab_dialogs_views.cc:22-29, 63-80` |
| Views bubble exits without toolbar | `chrome/browser/ui/views/passwords/password_bubble_view_base.cc:54-68` |
| Save controller | `chrome/browser/ui/passwords/bubble_controllers/save_update_bubble_controller.h:19-37`; `password_bubble_controller_base.cc:23, 31-36` |
| Password UI states | `components/password_manager/core/common/password_manager_ui.h` |
| Autofill bubble handler | `chrome/browser/ui/autofill/autofill_bubble_handler.h`; `chrome/browser/ui/views/autofill/autofill_bubble_handler_impl.cc:98-102`; `chrome/browser/ui/views/frame/browser_view.cc:1203-1220, 5238-5245` |
| Card bubble | `chrome/browser/ui/autofill/payments/save_card_bubble_controller_impl.cc:824-855` |
| Address bubble | `chrome/browser/ui/autofill/address_bubbles_controller.cc:55-99` |
| Re-auth null dereference | `chrome/browser/ui/autofill/payments/mandatory_reauth_bubble_controller_impl.cc:294-300` |
| Bubble queue | `chrome/browser/ui/autofill/bubble_controller_base.h`; `bubble_manager.cc:23-41` |
| Dropdown | `chrome/browser/ui/views/autofill/popup/popup_view_views.cc:128, 144-160, 374-377, 1970-1982`; `chrome/browser/ui/autofill/autofill_popup_controller_impl.cc:545-551` |
| Generation popup | `chrome/browser/ui/views/passwords/password_generation_popup_view_views.cc:496-506`; `components/password_manager/core/browser/password_feature_manager_impl.cc:28-36` |
| Fill on load rules | `components/password_manager/core/browser/password_form_filling.cc:62-67, 224-262` (cross-origin iframe: 246-247); `features/password_features.cc:113-115` |
| Value gatekeeper | `components/autofill/content/renderer/password_autofill_agent.h:377-381` |
| Cross-frame fill policy | `components/autofill/core/browser/foundations/autofill_driver_router.h:171-201` |
| Prefs | `components/password_manager/core/common/password_manager_pref_names.h:35, 46, 217, 261`; `components/autofill/core/common/autofill_prefs.h:94, 145` |
| `ProfileWriter` | `chrome/browser/importer/profile_writer.cc:91-101, 332-339` |
| Login store | `components/password_manager/core/browser/password_store/password_store_interface.h:90-97, 165`; `login_database.cc:1342-1425` |
| Address and card stores | `address_data_manager.cc:287-303, 732-740`; `payments_data_manager.cc:1495-1515`; `address_autofill_table.cc:50-65` |
| Cookies | `net/cookies/canonical_cookie.h:52-62, 221-238`; `services/network/public/mojom/cookie_manager.mojom:412, 450-452, 511`; `net/extras/sqlite/sqlite_persistent_cookie_store.cc:1235-1237` |
| Web DB commits | `components/webdata/common/web_database_backend.cc:87-97, 195-200` |
| Keychain names | `components/os_crypt/common/keychain_password_mac.mm:35-38, 75-110`; `cef/libcef/common/chrome/chrome_main_delegate_cef.cc:345-357`; `components/os_crypt/async/browser/keychain_key_provider.mm:28` |
| WebAuthn | `chrome/browser/webauthn/chrome_web_authentication_delegate.cc:389-410`; `device/fido/mac/icloud_keychain_sys.mm:228-240`; `chrome/browser/ui/views/webauthn/authenticator_request_dialog_view_controller_views.cc:22-54` |
| Host resolver rules | `net/dns/mapped_host_resolver.h:41` |

## Appendix B. Lead decisions

None yet.

## Appendix — Lead decisions (2026-10-26)

- Approved. Use Chromium's built-in password manager and autofill in the fork, with Open's own Arc-style UI. Engine work queues after #53 (P1) and the profiles engine-root fix, because the import writes into the per-profile engine data at `Engine/<profile dir>`.
- Q-1 No "Addresses" row in Settings ▸ Profiles (Arc parity).
- Q-2 Card mandatory re-auth is on by default for new profiles, with no opt-in bubble.
- Q-3 iCloud Keychain passkeys: request the managed entitlement. This becomes release user item **U-9**, not U-8: U-8 is already the public-repo or mirror decision. Security keys and phone passkeys ship without it.
- Q-4 Chromium pages show as `open://…`. This is a display alias only; the engine loads `chrome://`. It is shared with the extensions UI plan, which decided the same.
- Q-5 Rename Chromium's product-name strings to "Open" in P5 (trim and brand), before release.
- Q-6 The Credential Management account chooser stays off (Arc parity).
- Q-7 The save sheet shows only the host, no username. Revisit after S-1.
- Import consent rules stay as they are (import-phase2 lead decisions). Never touch the user's real Arc secrets without their explicit consent in the app.
- The screenshots go into the user's single combined Arc capture session.
