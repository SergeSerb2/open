// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "open/browser/extensions/open_extension_popup.h"

#include <utility>

#include "base/functional/bind.h"
#include "cef/libcef/browser/browser_host_base.h"
#include "cef/libcef/browser/browser_platform_delegate.h"
#include "cef/libcef/browser/chrome/chrome_browser_delegate.h"
#include "cef/libcef/browser/chrome/chrome_browser_host_impl.h"
#include "cef/libcef/browser/request_context_impl.h"
#include "chrome/browser/devtools/devtools_toggle_action.h"
#include "chrome/browser/devtools/devtools_window.h"
#include "chrome/browser/extensions/extension_view_host.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/render_widget_host_view.h"
#include "content/public/browser/web_contents.h"
#include "open/browser/extensions/open_extensions_toolbar.h"
#include "open/browser/tab_strip/open_tab_strip.h"

namespace open_engine {

namespace {

// https://developer.chrome.com/docs/extensions/reference/api/action#popup
// (chrome/browser/ui/extensions/extension_popup_types.h).
constexpr gfx::Size kMinSize = {25, 25};
constexpr gfx::Size kMaxSize = {800, 600};

}  // namespace

OpenExtensionPopup::OpenExtensionPopup(
    OpenExtensionsToolbar* toolbar,
    std::string action_id,
    std::unique_ptr<extensions::ExtensionViewHost> host,
    bool inspect_with_devtools,
    ShowPopupCallback callback,
    int source)
    : toolbar_(toolbar),
      action_id_(std::move(action_id)),
      host_(std::move(host)),
      inspect_with_devtools_(inspect_with_devtools),
      shown_callback_(std::move(callback)),
      source_(source) {
  host_->set_view(this);
  // window.close() in the popup. Unretained: `this` owns `host_`, so the
  // handler cannot run after `this` is gone.
  host_->SetCloseHandler(base::BindOnce(
      &OpenExtensionPopup::HandleCloseExtensionHost, base::Unretained(this)));
  WebContentsObserver::Observe(host_->host_contents());
  auto* main_frame = host_->host_contents()->GetPrimaryMainFrame();
  if (main_frame->IsRenderFrameLive()) {
    SetUpNewMainFrame(main_frame);
  }
}

OpenExtensionPopup::~OpenExtensionPopup() {
  if (shown_callback_) {
    std::move(shown_callback_).Run(nullptr);
  }
  host_->set_view(nullptr);
  // `host_` owns the WebContents; destroying it closes the CEF browser.
}

bool OpenExtensionPopup::Start() {
  OpenTabStrip* strip = toolbar_->strip();
  content::WebContents* active = strip->ActiveContents();
  auto opener =
      active ? ChromeBrowserHostImpl::GetBrowserForContents(active) : nullptr;
  if (!opener) {
    return false;
  }
  // The same Chrome style params as the strip's tabs: the popup's view is
  // its WebContents view, which the embedder parents (hosted platform
  // delegate).
  CefBrowserCreateParams params;
  params.request_context = strip->request_context().get();
  params.open_tab_strip_id = strip->id();
  if (auto handler = strip->handler()) {
    handler->OnBeforeExtensionPopupCreated(strip, action_id_, params.client,
                                           params.settings, params.extra_info);
  }
  auto platform_delegate = CefBrowserPlatformDelegate::Create(params);
  if (!platform_delegate) {
    return false;
  }
  auto browser_host = ChromeBrowserDelegate::CreateBrowserHostForPopup(
      host_->host_contents(), params.settings, params.client,
      params.extra_info, std::move(platform_delegate),
      /*is_devtools_popup=*/false, opener.get());
  // CEF configures auto-resize from its own setting whenever the render view
  // is ready (CefBrowserContentsDelegate::RenderViewReady); with it unset
  // that disables the popup's auto-resize.
  browser_host->SetAutoResizeEnabled(
      true, CefSize(kMinSize.width(), kMinSize.height()),
      CefSize(kMaxSize.width(), kMaxSize.height()));
  browser_ = browser_host.get();
  if (auto handler = strip->handler()) {
    handler->OnExtensionPopupOpened(strip, browser_, action_id_, source_);
  }
  host_->CreateRendererSoon();
  return true;
}

void OpenExtensionPopup::NotifyClosing() {
  if (closing_) {
    return;
  }
  closing_ = true;
  OpenTabStrip* strip = toolbar_->strip();
  if (auto handler = strip->handler(); handler && browser_) {
    handler->OnExtensionPopupClosed(strip, browser_);
  }
}

gfx::NativeView OpenExtensionPopup::native_view() const {
  return host_->host_contents()->GetNativeView();
}

gfx::NativeView OpenExtensionPopup::GetNativeView() {
  return native_view();
}

void OpenExtensionPopup::ResizeDueToAutoResize(
    content::WebContents* web_contents,
    const gfx::Size& new_size) {
  OpenTabStrip* strip = toolbar_->strip();
  if (auto handler = strip->handler(); handler && browser_ && !closing_) {
    handler->OnExtensionPopupResized(strip, browser_, new_size.width(),
                                     new_size.height());
  }
}

void OpenExtensionPopup::RenderFrameCreated(
    content::RenderFrameHost* render_frame_host) {
  // Only the initial main frame, not speculative ones.
  if (render_frame_host == host_->host_contents()->GetPrimaryMainFrame()) {
    SetUpNewMainFrame(render_frame_host);
  }
}

bool OpenExtensionPopup::HandleKeyboardEvent(
    content::WebContents* source,
    const input::NativeWebKeyboardEvent& event) {
  // Unhandled keys reach the embedder through the popup's CEF client.
  return false;
}

void OpenExtensionPopup::OnLoaded() {
  if (shown_callback_) {
    std::move(shown_callback_).Run(host_.get());
  }
  OpenTabStrip* strip = toolbar_->strip();
  if (auto handler = strip->handler(); handler && browser_ && !closing_) {
    handler->OnExtensionPopupReady(strip, browser_);
  }
  if (inspect_with_devtools_) {
    DevToolsWindow::OpenDevToolsWindow(
        host_->host_contents(), DevToolsToggleAction::ShowConsolePanel(),
        DevToolsOpenedByAction::kContextMenuInspect);
  }
}

void OpenExtensionPopup::RenderFrameHostChanged(
    content::RenderFrameHost* old_host,
    content::RenderFrameHost* new_host) {
  // A speculative main frame swapped in (RenderFrameCreated skipped it). The
  // initial main frame has no renderer frame yet.
  if (new_host != host_->host_contents()->GetPrimaryMainFrame() || !old_host) {
    return;
  }
  SetUpNewMainFrame(new_host);
}

void OpenExtensionPopup::SetUpNewMainFrame(
    content::RenderFrameHost* render_frame_host) {
  if (auto* view = render_frame_host->GetView()) {
    view->EnableAutoResize(kMinSize, kMaxSize);
  }
}

void OpenExtensionPopup::HandleCloseExtensionHost(
    extensions::ExtensionHost* host) {
  toolbar_->PopupWantsClose(this);
}

}  // namespace open_engine
