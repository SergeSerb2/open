# Hosted DevTools and user style sheets

A hosted Chrome-style tab has no `CefBrowserView`. CEF patch 0302 lets its next DevTools opening use an embedder delegate. `CefSetOpenDevToolsDockDelegate` consumes one registration. Without a registration, the existing window mode remains available. `OEDevToolsDock` puts the frontend in a frameless child window over its AppKit dock view and follows the view's size and visibility.

Both popup callbacks permit a null opener view. This is part of the API contract: `GetDelegateForPopupBrowserView` and `OnPopupBrowserViewCreated` must reach the embedder for a hosted tab. Previously their generated C API wrappers rejected the null opener. The dock delegate was found, but the App callback never ran, and CEF opened its default 800 by 600 window. The D4 real-App row checks attachment, Console and Network selection, resizing, close, and reopening in window mode.

`setUserStyleSheet(_:forKey:)` sends keyed, user-origin CSS to the renderer and saves it in the browser's extra info for replacement renderers. CEF patch 0601 applies saved sheets at main-frame commit. An empty CSS value removes the sheet; its CEF argument is optional so the generated wrapper forwards removal. The real-App `user_style_sheet` row checks insertion, navigation, replacement, removal, and the absence of injected DOM style nodes.

## English product names

Chromium patch 0508 changes `IDS_PASSWORDS_AUTHENTICATION_PROMPT_PREFIX` to `Open is trying to $1`. Verification reads the shipped English `locale.pak`; it does not open the macOS authentication dialog.

Patch 0509 updates another 570 English resource IDs that refer to the browser itself, including password-manager prompts, permissions, downloads, extension messages, certificate errors, and default-browser labels. The audit starts from the compiled macOS English locale and its GRIT resource maps. It changes message text and preserves resource IDs, placeholders, URLs, and source metadata. Open ships English only.

The audit preserves 49 entries that credit upstream authors or refer to separate mobile products. The license sentence names Open as the browser and keeps the linked Chromium project credit. Internal directory names, preference names, framework names, and Keychain identifiers remain unchanged. The macOS source scan found only initial-preferences file names outside the localized messages; these are internal paths.

Build and real-App receipts for this change are recorded in the engine PR. The shared recorded distribution remains at its previous revision during candidate testing.
