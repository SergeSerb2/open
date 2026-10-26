// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef OPEN_BROWSER_EXTENSIONS_OPEN_EXTENSION_POPUP_H_
#define OPEN_BROWSER_EXTENSIONS_OPEN_EXTENSION_POPUP_H_

#include <memory>
#include <string>

#include "base/memory/raw_ptr.h"
#include "cef/include/cef_browser.h"
#include "chrome/browser/extensions/extension_view.h"
#include "chrome/browser/ui/extensions/extension_popup_types.h"
#include "content/public/browser/web_contents_observer.h"

namespace extensions {
class ExtensionHost;
class ExtensionViewHost;
}

namespace open_engine {

class OpenExtensionsToolbar;

// One open action popup (fork patch P2): a real ExtensionViewHost of type
// kExtensionPopup, so chrome.extension.getViews({type: "popup"}) lists it,
// with a CEF browser attached to its WebContents so the embedder hosts it
// like any page. Port of chrome/browser/ui/android/extensions/
// extension_action_popup_contents.cc: auto-resize within Chrome's limits,
// window.close(), and the "shown" callback when the first load stops.
class OpenExtensionPopup : public extensions::ExtensionView,
                           public content::WebContentsObserver {
 public:
  OpenExtensionPopup(OpenExtensionsToolbar* toolbar,
                     std::string action_id,
                     std::unique_ptr<extensions::ExtensionViewHost> host,
                     bool inspect_with_devtools,
                     ShowPopupCallback callback,
                     int source);
  OpenExtensionPopup(const OpenExtensionPopup&) = delete;
  OpenExtensionPopup& operator=(const OpenExtensionPopup&) = delete;
  ~OpenExtensionPopup() override;

  // Attaches the CEF browser and starts loading. False if the window has no
  // tab to open it from (the popup is then dropped).
  bool Start();
  // Tells the handler the popup is closing; the destructor then closes the
  // page (the ExtensionViewHost owns the WebContents).
  void NotifyClosing();

  const std::string& action_id() const { return action_id_; }
  gfx::NativeView native_view() const;

  // extensions::ExtensionView:
  gfx::NativeView GetNativeView() override;
  void ResizeDueToAutoResize(content::WebContents* web_contents,
                             const gfx::Size& new_size) override;
  void RenderFrameCreated(content::RenderFrameHost* render_frame_host) override;
  bool HandleKeyboardEvent(content::WebContents* source,
                           const input::NativeWebKeyboardEvent& event) override;
  void OnLoaded() override;

  // content::WebContentsObserver:
  void RenderFrameHostChanged(content::RenderFrameHost* old_host,
                              content::RenderFrameHost* new_host) override;

 private:
  void SetUpNewMainFrame(content::RenderFrameHost* render_frame_host);
  void HandleCloseExtensionHost(extensions::ExtensionHost* host);

  const raw_ptr<OpenExtensionsToolbar> toolbar_;
  const std::string action_id_;
  std::unique_ptr<extensions::ExtensionViewHost> host_;
  const bool inspect_with_devtools_;
  ShowPopupCallback shown_callback_;
  const int source_;
  CefRefPtr<CefBrowser> browser_;
  bool closing_ = false;
};

}  // namespace open_engine

#endif  // OPEN_BROWSER_EXTENSIONS_OPEN_EXTENSION_POPUP_H_
