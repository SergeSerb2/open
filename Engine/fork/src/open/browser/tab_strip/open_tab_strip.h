// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef OPEN_BROWSER_TAB_STRIP_OPEN_TAB_STRIP_H_
#define OPEN_BROWSER_TAB_STRIP_OPEN_TAB_STRIP_H_

#include <memory>
#include <optional>

#include "base/callback_list.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "cef/include/cef_tab_strip.h"
#include "chrome/browser/ui/tabs/tab_strip_model_observer.h"

class Browser;
class BrowserWindowInterface;
class Profile;
class CefBrowserHostBase;
class CefBrowserPlatformDelegate;
class CefBrowserPlatformDelegateNative;
class CefRequestContextImpl;
struct CefBrowserCreateParams;

namespace content {
class WebContents;
}

namespace extensions {
class ExtensionAction;
}

namespace open_engine {

class OpenBrowserWindow;
class OpenExtensionsToolbar;

// CefTabStrip (cef/include/cef_tab_strip.h): one hidden Chrome Browser
// (TYPE_NORMAL, an OpenBrowserWindow, no Views) per embedder window and
// profile. Its tabs are Chrome style browsers whose WebContents views the
// embedder hosts. Chromium's own tab changes (chrome.tabs and friends) are
// reported to the CefTabStripHandler as requests; the embedder answers with
// UpdateTab/ActivateTab. Lives on the UI thread.
//
// The Browser exists while the strip has tabs: Chrome closes a Browser whose
// last tab goes away (Browser::TabStripEmpty), so the strip makes a new one
// for its next tab, and GetWindowId changes then.
class OpenTabStrip : public CefTabStrip, public TabStripModelObserver {
 public:
  OpenTabStrip(CefRefPtr<CefRequestContextImpl> request_context,
               CefRefPtr<CefTabStripHandler> handler);
  OpenTabStrip(const OpenTabStrip&) = delete;
  OpenTabStrip& operator=(const OpenTabStrip&) = delete;

  // Hooks used by Engine/fork/patches/cef/0302-open-hosted-tabs.patch.

  // The strip with |id|, or nullptr.
  static OpenTabStrip* FromId(int id);
  // The strip whose hidden Browser is |browser|, or nullptr.
  static OpenTabStrip* FromBrowser(const BrowserWindowInterface* browser);
  // The strip whose hidden Browser has the tab |contents|, or nullptr.
  static OpenTabStrip* FromContents(const content::WebContents* contents);
  // The strip id of |host| if it is a hosted tab, or 0.
  static int IdForHost(const CefBrowserHostBase* host);
  // The platform delegate for create params that carry a strip id, or
  // nullptr (CefBrowserPlatformDelegate::Create).
  static std::unique_ptr<CefBrowserPlatformDelegate>
  MaybeCreatePlatformDelegate(
      const CefBrowserCreateParams& params,
      std::unique_ptr<CefBrowserPlatformDelegateNative>& native_delegate);

  // ChromeBrowserDelegate::SetAsDelegate: fills client, settings and extra
  // info for a tab that is being created in this strip's Browser.
  void GetCreateParamsForNewTab(content::WebContents* contents,
                                CefBrowserCreateParams& params);
  // ChromeBrowserHostImpl::AddNewContents: adds a popup of a hosted tab to
  // this strip instead of a new Browser. Returns false, and leaves
  // |contents|, if there is no Browser.
  bool AddPopupContents(std::unique_ptr<content::WebContents>& contents);
  // chrome.tabs.discard of |contents|: asks the handler. True if the
  // embedder will unload the tab.
  bool RequestDiscard(content::WebContents* contents);
  // OpenBrowserWindow::Close for a window that still has tabs and is not
  // closing (chrome.windows.remove): asks the handler instead.
  void RequestClose();

  int id() const { return id_; }
  // True once Close() was called: the Browser may close for real.
  bool closing() const { return closed_; }
  CefRefPtr<CefTabStripHandler> handler() const { return handler_; }
  CefRefPtr<CefRequestContextImpl> request_context() const;
  // The active tab's WebContents, or nullptr.
  content::WebContents* ActiveContents() const;

  // CefTabStrip:
  bool IsValid() override;
  int GetWindowId() override;
  void SetHostView(CefWindowHandle view) override;
  CefRefPtr<CefBrowser> CreateTab(CefRefPtr<CefClient> client,
                                  const CefString& url,
                                  const CefBrowserSettings& settings,
                                  CefRefPtr<CefDictionaryValue> extra_info,
                                  int index,
                                  bool pinned) override;
  void UpdateTab(CefRefPtr<CefBrowser> browser,
                 int index,
                 bool pinned) override;
  void ActivateTab(CefRefPtr<CefBrowser> browser) override;
  int GetTabId(CefRefPtr<CefBrowser> browser) override;
  int GetTabCount() override;
  CefRefPtr<CefBrowser> GetTabAt(int index) override;
  int GetActiveIndex() override;
  CefString GetExtensionActionBadgeText(const CefString& extension_id) override;
  cef_color_t GetExtensionActionBadgeColor(
      const CefString& extension_id) override;
  CefString GetExtensionActionTitle(const CefString& extension_id) override;
  bool IsExtensionActionEnabled(const CefString& extension_id) override;
  bool AreExtensionActionsReady() override;
  void GetExtensionActionIds(std::vector<CefString>& extension_ids) override;
  CefRefPtr<CefDictionaryValue> GetExtensionActionState(
      const CefString& extension_id) override;
  CefRefPtr<CefImage> GetExtensionActionImage(const CefString& extension_id,
                                              int size,
                                              bool toolbar) override;
  void SetExtensionActionPinned(const CefString& extension_id,
                                bool pinned) override;
  void MoveExtensionAction(const CefString& extension_id,
                           int pinned_index) override;
  bool ExecuteExtensionAction(const CefString& extension_id,
                              int source) override;
  void CloseExtensionPopup() override;
  bool ExtensionPopupStaysOpenOnBlur() override;
  CefRefPtr<CefListValue> GetExtensionActionMenu(const CefString& extension_id,
                                                 int source,
                                                 int& menu_id) override;
  bool RunExtensionActionMenuCommand(int menu_id, int command_id) override;
  void ReleaseExtensionActionMenu(int menu_id) override;
  void Close() override;

  // TabStripModelObserver:
  void OnTabStripModelChanged(
      TabStripModel* tab_strip_model,
      const TabStripModelChange& change,
      const TabStripSelectionChange& selection) override;
  void OnTabPinnedStateChanged(tabs::TabInterface* tab, int index) override;

 private:
  enum class Request { kCreated, kActivate, kMove, kPin };

  struct PendingTab {
    // The tab's WebContents: only that tab takes these values.
    raw_ptr<content::WebContents> contents;
    CefRefPtr<CefClient> client;
    CefBrowserSettings settings;
    CefRefPtr<CefDictionaryValue> extra_info;
  };

  ~OpenTabStrip() override;

  // The action of |extension_id| and the tab id it is read for (the active
  // tab, or the default when the strip has none). nullptr if unknown.
  extensions::ExtensionAction* ActionFor(const CefString& extension_id,
                                         int* tab_id);

  Browser* EnsureBrowser();
  void OnBrowserDidClose(BrowserWindowInterface* browser);
  // The profile, for the action list without a live model; nullptr if the
  // context is not ready.
  Profile* GetProfile() const;
  // CefTabStripHandler::OnExtensionActionsChanged on a later turn.
  void PostActionsChanged();
  content::WebContents* ContentsFor(CefRefPtr<CefBrowser> browser) const;
  void PostRequest(Request request,
                   content::WebContents* contents,
                   int index,
                   bool flag);
  void DeliverRequest(Request request,
                      base::WeakPtr<content::WebContents> contents,
                      int index,
                      bool flag);
  void DeliverCloseRequest();
  // A hosted tab of this strip left for another window's strip (an
  // extension API this fork does not refuse): moves it back to |index|.
  void PutBack(base::WeakPtr<content::WebContents> contents,
               int index,
               bool pinned);

  const int id_;
  CefRefPtr<CefRequestContextImpl> request_context_;
  CefRefPtr<CefTabStripHandler> handler_;
  CefWindowHandle host_view_ = kNullWindowHandle;
  raw_ptr<Browser> browser_ = nullptr;
  raw_ptr<OpenBrowserWindow> window_ = nullptr;
  base::CallbackListSubscription did_close_subscription_;
  // The tab that CreateTab is adding; consumed by GetCreateParamsForNewTab.
  std::optional<PendingTab> pending_tab_;
  // Greater than zero while the strip changes its own model for the
  // embedder; those changes are not requests.
  int applying_ = 0;
  bool closed_ = false;
  // Chrome's toolbar action model for the Browser (fork patch P2); exists
  // with the Browser. The embedder hears when it comes and goes.
  std::unique_ptr<OpenExtensionsToolbar> toolbar_;

  IMPLEMENT_REFCOUNTING(OpenTabStrip);
  base::WeakPtrFactory<OpenTabStrip> weak_ptr_factory_{this};
};

}  // namespace open_engine

#endif  // OPEN_BROWSER_TAB_STRIP_OPEN_TAB_STRIP_H_
