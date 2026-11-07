// Copyright (c) 2026 The Open Authors. All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are
// met:
//
//    * Redistributions of source code must retain the above copyright
// notice, this list of conditions and the following disclaimer.
//    * Redistributions in binary form must reproduce the above
// copyright notice, this list of conditions and the following disclaimer
// in the documentation and/or other materials provided with the
// distribution.
//    * Neither the name of Google Inc. nor the name Chromium Embedded
// Framework nor the names of its contributors may be used to endorse
// or promote products derived from this software without specific prior
// written permission.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
// "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
// LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
// A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
// OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
// SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
// LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
// DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
// THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
//
// ---------------------------------------------------------------------------
//
// Open fork API (docs/engine-patches.md, P1). The contents of this file must
// follow a specific format in order to support the CEF translator tool. See
// the translator.README.txt file in the tools directory for more information.
//

#ifndef CEF_INCLUDE_CEF_TAB_STRIP_H_
#define CEF_INCLUDE_CEF_TAB_STRIP_H_
#pragma once

#include "include/cef_api_hash.h"
#include "include/cef_base.h"
#include "include/cef_browser.h"
#include "include/cef_client.h"
#include "include/cef_image.h"
#include "include/cef_request_context.h"
#include "include/cef_values.h"

#if CEF_API_ADDED(CEF_EXPERIMENTAL)

class CefTabStrip;

///
/// Receives tab changes that Chromium starts on its own, for example from the
/// chrome.tabs extension API. The embedder owns tab order, pinning, and
/// activation: Chromium asks through this handler, and the embedder applies
/// its decision with the CefTabStrip methods. The methods of this class are
/// called on the browser process UI thread.
///
/*--cef(source=client,added=experimental)--*/
class CefTabStripHandler : public virtual CefBaseRefCounted {
 public:
  ///
  /// A new extension popup strip was created. Set its handler now, before its
  /// tabs are made. Do not close it inside this callback. |requested_frame|
  /// is in Chrome screen coordinates (top-left), empty when not specified.
  ///
  /*--cef()--*/
  virtual void OnExtensionWindowCreated(CefRefPtr<CefTabStrip> parent,
      CefRefPtr<CefTabStrip> window, const CefRect& requested_frame,
      const CefString& extension_id) {}
  ///
  /// chrome.windows.update requested bounds/focus for this popup strip.
  /// Delivered outside Chromium's notification. Host views report actual bounds.
  ///
  /*--cef()--*/
  virtual void OnExtensionWindowFrameRequested(CefRefPtr<CefTabStrip> window,
      const CefRect& frame, bool focused) {}
  ///
  /// Chromium is about to create a tab in |tab_strip| on its own (for example
  /// chrome.tabs.create or an extension welcome page). |target_url| is the
  /// URL that the tab will load. Set |client|, |settings| and |extra_info|
  /// for the new browser; they default to empty values.
  ///
  /*--cef(optional_param=target_url)--*/
  virtual void OnBeforeTabCreated(CefRefPtr<CefTabStrip> tab_strip,
                                  const CefString& target_url,
                                  CefRefPtr<CefClient>& client,
                                  CefBrowserSettings& settings,
                                  CefRefPtr<CefDictionaryValue>& extra_info) {}

  ///
  /// Chromium added |browser| to |tab_strip| at |index|. |active| is true if
  /// Chromium asked for the new tab to be the active tab. The embedder should
  /// adopt the tab (show it, place it with UpdateTab) or close it. Not called
  /// for tabs created with CefTabStrip::CreateTab or popups whose opener is in
  /// this tab strip.
  ///
  /*--cef()--*/
  virtual void OnTabCreated(CefRefPtr<CefTabStrip> tab_strip,
                            CefRefPtr<CefBrowser> browser,
                            int index,
                            bool active) {}

  ///
  /// Chromium made |browser| the active tab of |tab_strip| (for example
  /// chrome.tabs.update with active: true). Call ActivateTab with the tab the
  /// embedder wants active.
  ///
  /*--cef()--*/
  virtual void OnTabActivateRequested(CefRefPtr<CefTabStrip> tab_strip,
                                      CefRefPtr<CefBrowser> browser) {}

  ///
  /// Chromium moved |browser| to |index| in |tab_strip| (chrome.tabs.move).
  /// |previous| and |next| are the neighbours at the model notification,
  /// not at delivery time. Either can be null (or have closed meanwhile).
  /// Call UpdateTab with the position the embedder wants.
  ///
  /*--cef(optional_param=previous,optional_param=next)--*/
  virtual void OnTabMoveRequested(CefRefPtr<CefTabStrip> tab_strip,
                                  CefRefPtr<CefBrowser> browser,
                                  int index,
                                  CefRefPtr<CefBrowser> previous,
                                  CefRefPtr<CefBrowser> next) {}

  ///
  /// Chromium pinned or unpinned |browser| (chrome.tabs.update with pinned).
  /// Call UpdateTab with the pinned state the embedder wants.
  ///
  /*--cef()--*/
  virtual void OnTabPinRequested(CefRefPtr<CefTabStrip> tab_strip,
                                 CefRefPtr<CefBrowser> browser,
                                 bool pinned) {}

  ///
  /// Chromium asks to unload |browser| (chrome.tabs.discard). The embedder's
  /// own tab sleep decides: return true if it will unload the tab. Do not
  /// close the tab from inside this call. Chromium never discards tabs of a
  /// tab strip on its own (memory pressure, Memory Saver), because a discard
  /// would replace the tab's page.
  ///
  /*--cef()--*/
  virtual bool OnTabDiscardRequested(CefRefPtr<CefTabStrip> tab_strip,
                                     CefRefPtr<CefBrowser> browser) {
    return false;
  }

  ///
  /// Chromium asks to close the window of |tab_strip| while it still has
  /// tabs (chrome.windows.remove). The window stays open. To close it, the
  /// embedder closes its tabs or calls CefTabStrip::Close.
  ///
  /*--cef()--*/
  virtual void OnCloseRequested(CefRefPtr<CefTabStrip> tab_strip) {}

  ///
  /// The toolbar action of |extension_id| changed for this window's tabs
  /// (chrome.action.setBadgeText, setTitle, setIcon, enable, and so on, or
  /// the active tab changed). Read its state with the CefTabStrip
  /// GetExtensionAction* methods. Coalesced: at most one call per action per
  /// message loop turn.
  ///
  /*--cef()--*/
  virtual void OnExtensionActionUpdated(CefRefPtr<CefTabStrip> tab_strip,
                                        const CefString& extension_id) {}

  ///
  /// The list, order, or pinning of the toolbar actions changed (install,
  /// uninstall, enable, disable, pin, unpin, move), or the live model came
  /// or went (AreExtensionActionsReady changed). Read it again with
  /// GetExtensionActionIds.
  ///
  /*--cef()--*/
  virtual void OnExtensionActionsChanged(CefRefPtr<CefTabStrip> tab_strip) {}

  ///
  /// The user ran |extension_id|'s action while it is disabled for the
  /// active tab. Chrome shows the action's context menu instead; show
  /// GetExtensionActionMenu.
  ///
  /*--cef()--*/
  virtual void OnExtensionActionMenuRequested(CefRefPtr<CefTabStrip> tab_strip,
                                              const CefString& extension_id) {}

  ///
  /// Chromium is about to open the popup of |extension_id|'s action. Set
  /// |client|, |settings| and |extra_info| for the popup's browser.
  ///
  /*--cef()--*/
  virtual void OnBeforeExtensionPopupCreated(
      CefRefPtr<CefTabStrip> tab_strip,
      const CefString& extension_id,
      CefRefPtr<CefClient>& client,
      CefBrowserSettings& settings,
      CefRefPtr<CefDictionaryValue>& extra_info) {}

  ///
  /// The popup of |extension_id|'s action opened as |browser|: a Chrome
  /// extension popup (chrome.extension.getViews({type: "popup"}) lists it)
  /// whose view the embedder hosts, like a tab of this strip. |source| is 0
  /// for a user action, 1 for a keyboard command, and 2 for
  /// chrome.action.openPopup(). The popup is not loaded yet; see
  /// OnExtensionPopupReady.
  ///
  /*--cef()--*/
  virtual void OnExtensionPopupOpened(CefRefPtr<CefTabStrip> tab_strip,
                                      CefRefPtr<CefBrowser> browser,
                                      const CefString& extension_id,
                                      int source) {}

  ///
  /// The popup asked for a new size (Chrome's limits: 25x25 to 800x600).
  ///
  /*--cef()--*/
  virtual void OnExtensionPopupResized(CefRefPtr<CefTabStrip> tab_strip,
                                       CefRefPtr<CefBrowser> browser,
                                       int width,
                                       int height) {}

  ///
  /// The popup's first load stopped: show it now (Chrome shows its bubble at
  /// this point).
  ///
  /*--cef()--*/
  virtual void OnExtensionPopupReady(CefRefPtr<CefTabStrip> tab_strip,
                                     CefRefPtr<CefBrowser> browser) {}

  ///
  /// The popup is closing (window.close(), CloseExtensionPopup, Escape, the
  /// active tab changed, the extension unloaded or crashed, or the window
  /// closed). Remove its view; the browser closes after this call.
  ///
  /*--cef()--*/
  virtual void OnExtensionPopupClosed(CefRefPtr<CefTabStrip> tab_strip,
                                      CefRefPtr<CefBrowser> browser) {}
};

///
/// One hidden Chrome browser window (a Chrome Browser with a TabStripModel
/// and no Views) whose tabs the embedder hosts in its own views. Extensions
/// see it as a normal window: chrome.windows and chrome.tabs report its tabs,
/// their order, the active tab, and its native window. Create one per
/// embedder window and profile. The methods of this class must be called on
/// the browser process UI thread.
///
/*--cef(source=library,added=experimental)--*/
class CefTabStrip : public virtual CefBaseRefCounted {
 public:
  ///
  /// Replaces the request handler, before adopting an extension popup strip.
  ///
  /*--cef()--*/
  virtual void SetHandler(CefRefPtr<CefTabStripHandler> handler) = 0;
  ///
  /// Creates a tab strip for |request_context| (the global context if empty).
  /// Returns nullptr if the context is not initialized yet.
  ///
  /*--cef(optional_param=request_context,optional_param=handler)--*/
  static CefRefPtr<CefTabStrip> Create(
      CefRefPtr<CefRequestContext> request_context,
      CefRefPtr<CefTabStripHandler> handler);

  ///
  /// Returns true until Close is called.
  ///
  /*--cef()--*/
  virtual bool IsValid() = 0;

  ///
  /// Returns the chrome.windows id of this tab strip.
  ///
  /*--cef()--*/
  virtual int GetWindowId() = 0;

  ///
  /// Sets the embedder view whose window is this tab strip's native window
  /// (bounds, focus, and dialog anchoring). Pass nullptr to clear it.
  ///
  /*--cef(optional_param=view)--*/
  virtual void SetHostView(CefWindowHandle view) = 0;

  ///
  /// Creates a Chrome style browser as a tab of this strip at |index| (-1 for
  /// the end). The browser has no native parent: put the view returned by
  /// CefBrowserHost::GetWindowHandle in an embedder view. The new tab is not
  /// active. Returns nullptr on failure.
  ///
  /*--cef(optional_param=client,optional_param=url,optional_param=extra_info)--*/
  virtual CefRefPtr<CefBrowser> CreateTab(
      CefRefPtr<CefClient> client,
      const CefString& url,
      const CefBrowserSettings& settings,
      CefRefPtr<CefDictionaryValue> extra_info,
      int index,
      bool pinned) = 0;

  ///
  /// Moves the tab of |browser| to |index| and sets its pinned state. Pinned
  /// tabs always come first, so |index| may be adjusted.
  ///
  /*--cef()--*/
  virtual void UpdateTab(CefRefPtr<CefBrowser> browser,
                         int index,
                         bool pinned) = 0;

  ///
  /// Makes the tab of |browser| the active tab.
  ///
  /*--cef()--*/
  virtual void ActivateTab(CefRefPtr<CefBrowser> browser) = 0;

  ///
  /// Returns the chrome.tabs id of |browser|, or -1 if it has none.
  ///
  /*--cef()--*/
  virtual int GetTabId(CefRefPtr<CefBrowser> browser) = 0;

  ///
  /// Returns the number of tabs.
  ///
  /*--cef()--*/
  virtual int GetTabCount() = 0;

  ///
  /// Returns the browser of the tab at |index|, or nullptr.
  ///
  /*--cef()--*/
  virtual CefRefPtr<CefBrowser> GetTabAt(int index) = 0;

  ///
  /// Returns the index of the active tab, or -1.
  ///
  /*--cef()--*/
  virtual int GetActiveIndex() = 0;

  ///
  /// Returns the badge text of |extension_id|'s toolbar action for the active
  /// tab, or an empty string.
  ///
  /*--cef()--*/
  virtual CefString GetExtensionActionBadgeText(
      const CefString& extension_id) = 0;

  ///
  /// Returns the badge background color of |extension_id|'s toolbar action
  /// for the active tab, or 0 if the extension set none.
  ///
  /*--cef()--*/
  virtual cef_color_t GetExtensionActionBadgeColor(
      const CefString& extension_id) = 0;

  ///
  /// Returns the title (tooltip) of |extension_id|'s toolbar action for the
  /// active tab, or an empty string.
  ///
  /*--cef()--*/
  virtual CefString GetExtensionActionTitle(const CefString& extension_id) = 0;

  ///
  /// Returns true if |extension_id|'s toolbar action is enabled for the
  /// active tab.
  ///
  /*--cef()--*/
  virtual bool IsExtensionActionEnabled(const CefString& extension_id) = 0;

  ///
  /// Returns true while Chrome's toolbar action model for this window is
  /// live: it needs the hidden Browser, which exists only while the strip
  /// has tabs. Without it, GetExtensionActionIds, GetExtensionActionState
  /// and GetExtensionActionImage read the profile's action list (pins and
  /// tab-independent defaults, "live" false), and actions cannot run.
  ///
  /*--cef()--*/
  virtual bool AreExtensionActionsReady() = 0;

  ///
  /// Fills |extension_ids| with every toolbar action of this window's
  /// profile: pinned actions in pinned order first, then the others in
  /// Chrome's order.
  ///
  /*--cef()--*/
  virtual void GetExtensionActionIds(std::vector<CefString>& extension_ids) = 0;

  ///
  /// Returns the state of |extension_id|'s action for the active tab, or
  /// nullptr. Keys: "name", "title", "accessibleName", "tooltip",
  /// "badgeText" (strings); "badgeBackgroundColor" (ARGB int, 0 when the
  /// extension set none); "badgeTextColor" (ARGB int, absent when
  /// automatic); "enabled", "hasPopup", "pinned", "wantsToRun",
  /// "showingPopup", "live" (bools); "pinnedIndex" (int, -1 when unpinned);
  /// "siteAccess" (int: 0 none, 1 on click, 2 on site, 3 on all sites,
  /// 4 blocked for this site, 5 granted for this tab only, as after an
  /// activeTab click).
  ///
  /*--cef()--*/
  virtual CefRefPtr<CefDictionaryValue> GetExtensionActionState(
      const CefString& extension_id) = 0;

  ///
  /// Returns |extension_id|'s action image for the active tab, |size| DIP
  /// square, with 1x and 2x representations. With |toolbar| true it is the
  /// image Chrome's toolbar draws (badge, disabled state, decorations);
  /// otherwise the plain action icon. nullptr if unknown.
  ///
  /*--cef()--*/
  virtual CefRefPtr<CefImage> GetExtensionActionImage(
      const CefString& extension_id,
      int size,
      bool toolbar) = 0;

  ///
  /// Pins or unpins |extension_id|'s action (the profile's
  /// extensions.pinned_extensions pref; every window of the profile
  /// follows).
  ///
  /*--cef()--*/
  virtual void SetExtensionActionPinned(const CefString& extension_id,
                                        bool pinned) = 0;

  ///
  /// Moves the pinned action |extension_id| to |pinned_index|.
  ///
  /*--cef()--*/
  virtual void MoveExtensionAction(const CefString& extension_id,
                                   int pinned_index) = 0;

  ///
  /// Runs |extension_id|'s action for the active tab as the user would: opens
  /// its popup, or fires chrome.action.onClicked, and runs blocked scripts
  /// when the extension wants to run. |source| is 0 for a toolbar button, 1
  /// for a menu entry, 2 for a keyboard command. Returns false for an
  /// unknown action or without a live model (AreExtensionActionsReady). A
  /// disabled action calls OnExtensionActionMenuRequested instead.
  ///
  /*--cef()--*/
  virtual bool ExecuteExtensionAction(const CefString& extension_id,
                                      int source) = 0;

  ///
  /// Closes the open action popup, if any.
  ///
  /*--cef()--*/
  virtual void CloseExtensionPopup() = 0;

  ///
  /// Returns true while the open popup must stay open when it loses focus,
  /// as in Chrome (ExtensionPopup::CloseUnlessBlockedByInspectionOrJSDialog):
  /// an app-modal JavaScript dialog is showing, a web-modal dialog of the
  /// popup is showing (WebAuthn, passkeys), or DevTools inspects the popup.
  /// False without a popup.
  ///
  /*--cef()--*/
  virtual bool ExtensionPopupStaysOpenOnBlur() = 0;

  ///
  /// Returns the context menu of |extension_id|'s action (Chrome's
  /// ExtensionContextMenuModel): a list of dictionaries with "command"
  /// (int), "label" (string, "&&" for a literal "&"), "enabled", "checked",
  /// "separator" (bools), and "submenu" (list, optional). |source| is 0 for
  /// a toolbar action and 1 for a menu item. |menu_id| receives the menu's
  /// id: the strip keeps this menu's model until
  /// RunExtensionActionMenuCommand or ReleaseExtensionActionMenu with that
  /// id, the action goes away, or the live model goes away. Returns nullptr
  /// (|menu_id| 0) for an unknown action or without a live model.
  ///
  /*--cef()--*/
  virtual CefRefPtr<CefListValue> GetExtensionActionMenu(
      const CefString& extension_id,
      int source,
      int& menu_id) = 0;

  ///
  /// Runs |command_id| of menu |menu_id| and releases the menu. Returns false
  /// if the menu is gone or has no enabled item |command_id|.
  ///
  /*--cef()--*/
  virtual bool RunExtensionActionMenuCommand(int menu_id, int command_id) = 0;

  ///
  /// Releases menu |menu_id| without running a command.
  ///
  /*--cef()--*/
  virtual void ReleaseExtensionActionMenu(int menu_id) = 0;

  ///
  /// Closes the remaining tabs and the hidden window. The object is invalid
  /// afterwards.
  ///
  /*--cef()--*/
  virtual void Close() = 0;
};

///
/// Automation diagnostic, available only with --open-automation on the UI
/// thread. Returns the invalid host activation request count and the active
/// Chrome window id, or nullptr outside automation. With |reset|, clears the
/// count before returning it. Unsafe requests are counted and refused in
/// automation so a regression reports a failure without ending the process.
///
/*--cef(added=experimental)--*/
CefRefPtr<CefDictionaryValue> CefGetOpenBrowserActivationDiagnostics(bool reset);

#endif  // CEF_API_ADDED(CEF_EXPERIMENTAL)

#endif  // CEF_INCLUDE_CEF_TAB_STRIP_H_
