// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// Fills open_engine::HistorySwipeHooks (patch 0501) and the page's
// HistorySwipingControl (Chromium's own per-page switch for the swiper).

#import <AppKit/AppKit.h>

#include <algorithm>

#include "base/command_line.h"
#include "base/functional/bind.h"
#include "cef/libcef/browser/browser_host_base.h"
#include "cef/libcef/browser/browser_info.h"
#include "cef/libcef/browser/browser_info_manager.h"
#include "cef/include/cef_open_page.h"
#include "cef/libcef/browser/thread_util.h"
#include "chrome/browser/renderer_host/chrome_render_widget_host_view_mac_history_swiping_control.h"
#include "chrome/browser/ui/browser_commands.h"
#import "chrome/browser/ui/cocoa/history_overlay_controller.h"
#include "content/public/browser/render_widget_host_view.h"
#include "content/public/browser/web_contents.h"
#include "open/browser/page/open_history_swipe_hooks.h"
#include "open/browser/page/open_page_state.h"

namespace open_engine {

namespace {

content::WebContents* WebContentsForBrowserId(int browser_id) {
  for (const auto& info :
       CefBrowserInfoManager::GetInstance()->GetBrowserInfoList()) {
    if (info->browser_id() == browser_id) {
      CefRefPtr<CefBrowserHostBase> browser = info->browser();
      return browser ? browser->GetWebContents() : nullptr;
    }
  }
  return nullptr;
}

int BrowserForView(void* ns_view) {
  NSView* view = (__bridge NSView*)ns_view;
  if (!view) {
    return 0;
  }
  for (const auto& info :
       CefBrowserInfoManager::GetInstance()->GetBrowserInfoList()) {
    CefRefPtr<CefBrowserHostBase> browser = info->browser();
    content::WebContents* web_contents =
        browser ? browser->GetWebContents() : nullptr;
    content::RenderWidgetHostView* rwhv =
        web_contents ? web_contents->GetRenderWidgetHostView() : nullptr;
    NSView* page = rwhv ? rwhv->GetNativeView().GetNativeNSView() : nil;
    if (page && (view == page || [view isDescendantOf:page])) {
      return info->browser_id();
    }
  }
  return 0;
}

bool DrawsOverlay(int browser_id) {
  return HistorySwipeDrawsOverlay(WebContentsForBrowserId(browser_id));
}

void Report(int browser_id, int phase, int direction, double progress) {
  ReportHistorySwipe(WebContentsForBrowserId(browser_id), phase, direction,
                     progress);
}

}  // namespace

void InstallHistorySwipeHooks(content::WebContents* web_contents) {
  HistorySwipeHooks& hooks = GetHistorySwipeHooks();
  if (!hooks.report) {
    hooks.browser_for_view = &BrowserForView;
    hooks.draws_overlay = &DrawsOverlay;
    hooks.report = &Report;
  }
  // Chromium's swiper asks this per page (shouldAllowHistorySwiping).
  if (web_contents &&
      !history_swiper::HistorySwipingControl::FromWebContents(web_contents)) {
    history_swiper::HistorySwipingControl::CreateForWebContents(
        web_contents,
        base::BindRepeating(
            [](base::WeakPtr<content::WebContents> page) {
              return HistorySwipeEnabled(page.get());
            },
            web_contents->GetWeakPtr()));
  }
}

}  // namespace open_engine

bool CefSimulateHistorySwipe(CefRefPtr<CefBrowser> browser,
                             int direction,
                             double progress) {
  CEF_REQUIRE_UIT_RETURN(false);
  if (!base::CommandLine::ForCurrentProcess()->HasSwitch("open-automation")) {
    return false;
  }
  auto host = CefBrowserHostBase::FromBrowser(browser);
  content::WebContents* web_contents = host ? host->GetWebContents() : nullptr;
  content::RenderWidgetHostView* rwhv =
      web_contents ? web_contents->GetRenderWidgetHostView() : nullptr;
  NSView* view = rwhv ? rwhv->GetNativeView().GetNativeNSView() : nil;
  if (!view) {
    return false;
  }
  // The swiper's own checks (shouldAllowHistorySwiping,
  // canNavigateInDirection).
  auto* control =
      history_swiper::HistorySwipingControl::FromWebContents(web_contents);
  if (control && !control->ShouldAllowHistorySwiping()) {
    return false;
  }
  const bool forward = direction == 1;
  if (forward ? !chrome::CanGoForward(web_contents)
              : !chrome::CanGoBack(web_contents)) {
    return false;
  }
  open_engine::InstallHistorySwipeHooks(web_contents);
  HistoryOverlayController* overlay = [[HistoryOverlayController alloc]
      initForMode:forward ? kHistoryOverlayModeForward
                          : kHistoryOverlayModeBack];
  [overlay showPanelForView:view];
  const double end = std::clamp(progress, 0.0, 1.5);
  for (double p = 0.25; p < end; p += 0.25) {
    [overlay setProgress:std::min(p, 1.0) finished:p >= 1.0];
  }
  const bool finished = end >= 1.0;
  [overlay setProgress:std::min(end, 1.0) finished:finished];
  if (finished) {
    forward ? chrome::GoForward(web_contents) : chrome::GoBack(web_contents);
  }
  [overlay dismiss];
  return true;
}
