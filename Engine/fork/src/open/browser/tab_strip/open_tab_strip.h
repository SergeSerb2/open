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
#include "base/scoped_observation.h"
#include "chrome/browser/extensions/extension_action_dispatcher.h"
#include "chrome/browser/ui/tabs/tab_strip_model_observer.h"

class Browser;
class BrowserWindowInterface;
class CefBrowserHostBase;
class CefBrowserPlatformDelegate;
class CefBrowserPlatformDelegateNative;
class CefRequestContextImpl;
struct CefBrowserCreateParams;

namespace content {
class WebContents;
}

namespace open_engine {

class OpenBrowserWindow;

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
class OpenTabStrip : public CefTabStrip,
                     public TabStripModelObserver,
                     public extensions::ExtensionActionDispatcher::Observer {
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

  int id() const { return id_; }

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
  void Close() override;

  // TabStripModelObserver:
  void OnTabStripModelChanged(
      TabStripModel* tab_strip_model,
      const TabStripModelChange& change,
      const TabStripSelectionChange& selection) override;
  void OnTabPinnedStateChanged(tabs::TabInterface* tab, int index) override;

  // extensions::ExtensionActionDispatcher::Observer:
  void OnExtensionActionUpdated(
      extensions::ExtensionAction* extension_action,
      content::WebContents* web_contents,
      content::BrowserContext* browser_context) override;
  void OnShuttingDown() override;

 private:
  enum class Request { kCreated, kActivate, kMove, kPin };

  struct PendingTab {
    CefRefPtr<CefClient> client;
    CefBrowserSettings settings;
    CefRefPtr<CefDictionaryValue> extra_info;
  };

  ~OpenTabStrip() override;

  // The action of |extension_id| and the tab id it is read for (the active
  // tab, or the default when the strip has none). nullptr if unknown.
  extensions::ExtensionAction* ActionFor(const CefString& extension_id,
                                         int* tab_id);
  void DeliverActionUpdate(const std::string& extension_id);

  Browser* EnsureBrowser();
  void OnBrowserDidClose(BrowserWindowInterface* browser);
  content::WebContents* ContentsFor(CefRefPtr<CefBrowser> browser) const;
  void PostRequest(Request request,
                   content::WebContents* contents,
                   int index,
                   bool flag);
  void DeliverRequest(Request request,
                      base::WeakPtr<content::WebContents> contents,
                      int index,
                      bool flag);

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
  base::ScopedObservation<extensions::ExtensionActionDispatcher,
                          extensions::ExtensionActionDispatcher::Observer>
      action_observation_{this};

  IMPLEMENT_REFCOUNTING(OpenTabStrip);
  base::WeakPtrFactory<OpenTabStrip> weak_ptr_factory_{this};
};

}  // namespace open_engine

#endif  // OPEN_BROWSER_TAB_STRIP_OPEN_TAB_STRIP_H_
