// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#import <AppKit/AppKit.h>

#include <cmath>
#include <utility>

#include "base/functional/bind.h"
#include "base/logging.h"
#include "base/memory/weak_ptr.h"
#include "base/task/single_thread_task_runner.h"
#include "cef/include/cef_open_page.h"
#include "cef/libcef/browser/browser_host_base.h"
#include "cef/libcef/browser/thread_util.h"
#include "content/browser/renderer_host/render_widget_host_impl.h"
#include "content/browser/renderer_host/render_widget_host_view_mac.h"
#include "content/public/browser/navigation_handle.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/weak_document_ptr.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_contents_observer.h"
#include "content/public/browser/web_contents_user_data.h"
#include "mojo/public/cpp/bindings/callback_helpers.h"

namespace {

// This state belongs to the WebContents, not its URL or reusable renderer.
class OpenFramePresentation
    : public content::WebContentsObserver,
      public content::WebContentsUserData<OpenFramePresentation> {
 public:
  ~OpenFramePresentation() override { Cancel(); }

  bool Request(int64_t id, const gfx::Size& pixels, double scale, bool retain,
               CefRefPtr<CefOpenFramePresentationCallback> callback) {
    Cancel();
    auto* frame = web_contents()->GetPrimaryMainFrame();
    auto* view = frame ? frame->GetView() : nullptr;
    if (!frame || !frame->IsRenderFrameLive() || !view || !view->IsShowing())
      return false;
    NSView* native = view->GetNativeView().GetNativeNSView();
    if (!native.window || !native.superview || native.isHiddenOrHasHiddenAncestor)
      return false;
    auto* widget = content::RenderWidgetHostImpl::From(frame->GetRenderWidgetHost());
    if (!widget || widget->IsHidden())
      return false;
    id_ = id;
    ++epoch_;
    pixels_ = pixels;
    scale_ = scale;
    requested_at_ = base::TimeTicks::Now();
    document_ = frame->GetWeakDocumentPtr();
    view_ = static_cast<content::RenderWidgetHostViewMac*>(view)->GetWeakPtr();
    widget_ = widget->GetWeakPtr();
    native_ = native;
    parent_ = native.superview;
    window_ = native.window;
    callback_ = callback;
    static_cast<content::RenderWidgetHostViewMac*>(view)
        ->SetOpenRetainSurfaceForResize(retain);
    widget->RequestOpenFramePresentation(
        id, pixels, static_cast<float>(scale),
        mojo::WrapCallbackWithDefaultInvokeIfNotRun(
            base::BindOnce(&OpenFramePresentation::Presented,
                           weak_factory_.GetWeakPtr(), epoch_),
            base::TimeTicks()));
    return true;
  }

  void CancelIfMatching(int64_t id) {
    if (id == id_)
      Cancel();
  }

 private:
  friend class content::WebContentsUserData<OpenFramePresentation>;
  explicit OpenFramePresentation(content::WebContents* contents)
      : content::WebContentsObserver(contents),
        content::WebContentsUserData<OpenFramePresentation>(*contents) {}

  void Cancel() {
    ++epoch_;
    if (!callback_)
      return;
    if (widget_)
      widget_->CancelOpenFramePresentation(id_);
    if (view_)
      static_cast<content::RenderWidgetHostViewMac*>(view_.get())
          ->SetOpenRetainSurfaceForResize(false);
    Finish(base::TimeTicks());
  }

  void Finish(base::TimeTicks time) {
    auto callback = std::move(callback_);
    const int64_t id = id_;
    // Never call the embedder from a WebContents/renderer observer stack.
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE, base::BindOnce(
            [](base::WeakPtr<OpenFramePresentation> state, uint64_t epoch,
               CefRefPtr<CefOpenFramePresentationCallback> done,
               int64_t request_id, base::TimeTicks presented) {
              const bool current = state && state->epoch_ == epoch &&
                  state->MatchesCurrentView(presented);
              done->OnFramePresented(request_id,
                  !current || presented.is_null() ? 0 :
                      presented.since_origin().InSecondsF());
            }, weak_factory_.GetWeakPtr(), epoch_, std::move(callback), id, time));
  }

  void Presented(uint64_t epoch, base::TimeTicks time) {
    if (VLOG_IS_ON(1)) {
      auto* frame = document_.AsRenderFrameHostIfValid();
      VLOG(1) << "OpenFramePresentation browser id=" << id_
              << " epoch=" << epoch << "/" << epoch_
              << " pending=" << !!callback_ << " null=" << time.is_null()
              << " after_request=" << (time >= requested_at_)
              << " frame=" << (frame && frame->IsRenderFrameLive() &&
                               frame == web_contents()->GetPrimaryMainFrame())
              << " view=" << (view_ && frame && frame->GetView() == view_.get() &&
                              view_->IsShowing())
              << " widget=" << (widget_ && frame &&
                                frame->GetRenderWidgetHost() == widget_.get() &&
                                !widget_->IsHidden())
              << " native=" << (native_ && native_.window == window_ &&
                                native_.superview == parent_ &&
                                !native_.isHiddenOrHasHiddenAncestor)
              << " have="
              << (view_ ? view_->GetCompositorViewportPixelSize().ToString()
                        : std::string("none"))
              << "@" << (view_ ? view_->GetDeviceScaleFactor() : 0.f)
              << " want=" << pixels_.ToString() << "@" << scale_;
    }
    if (epoch != epoch_ || !callback_)
      return;
    const bool valid = MatchesCurrentView(time);
    if (view_)
      static_cast<content::RenderWidgetHostViewMac*>(view_.get())
          ->SetOpenRetainSurfaceForResize(false);
    Finish(valid ? time : base::TimeTicks());
  }

  bool MatchesCurrentView(base::TimeTicks time) const {
    auto* frame = document_.AsRenderFrameHostIfValid();
    return !time.is_null() && time >= requested_at_ && frame &&
        frame == web_contents()->GetPrimaryMainFrame() &&
        frame->IsRenderFrameLive() && view_ && frame->GetView() == view_.get() &&
        widget_ && frame->GetRenderWidgetHost() == widget_.get() &&
        !widget_->IsHidden() && view_->IsShowing() && native_ &&
        native_.window == window_ && native_.superview == parent_ &&
        !native_.isHiddenOrHasHiddenAncestor &&
        view_->GetCompositorViewportPixelSize() == pixels_ &&
        std::abs(view_->GetDeviceScaleFactor() - scale_) < 0.00001;
  }

  void DidStartNavigation(content::NavigationHandle* navigation) override {
    if (navigation->IsInPrimaryMainFrame())
      Cancel();
  }
  void PrimaryPageChanged(content::Page&) override { Cancel(); }
  void OnVisibilityChanged(content::Visibility visibility) override {
    if (visibility != content::Visibility::VISIBLE)
      Cancel();
  }
  void PrimaryMainFrameRenderProcessGone(base::TerminationStatus) override {
    Cancel();
  }
  void RenderFrameHostChanged(content::RenderFrameHost*,
                             content::RenderFrameHost*) override { Cancel(); }
  void WebContentsDestroyed() override { Cancel(); }

  int64_t id_ = 0;
  uint64_t epoch_ = 0;
  gfx::Size pixels_;
  double scale_ = 0;
  base::TimeTicks requested_at_;
  content::WeakDocumentPtr document_;
  base::WeakPtr<content::RenderWidgetHostViewBase> view_;
  base::WeakPtr<content::RenderWidgetHostImpl> widget_;
  NSView* __weak native_ = nil;
  NSView* __weak parent_ = nil;
  NSWindow* __weak window_ = nil;
  CefRefPtr<CefOpenFramePresentationCallback> callback_;
  base::WeakPtrFactory<OpenFramePresentation> weak_factory_{this};
  WEB_CONTENTS_USER_DATA_KEY_DECL();
};
WEB_CONTENTS_USER_DATA_KEY_IMPL(OpenFramePresentation);

content::WebContents* ContentsFor(CefRefPtr<CefBrowser> browser) {
  auto host = CefBrowserHostBase::FromBrowser(browser);
  return host ? host->GetWebContents() : nullptr;
}
}  // namespace

bool CefRequestOpenFramePresentation(
    CefRefPtr<CefBrowser> browser, int64_t request_id, int pixel_width,
    int pixel_height, double scale, bool retain_surface,
    CefRefPtr<CefOpenFramePresentationCallback> callback) {
  CEF_REQUIRE_UIT_RETURN(false);
  auto* contents = ContentsFor(browser);
  if (!contents || browser->GetHost()->IsWindowRenderingDisabled() ||
      !callback || request_id <= 0 || pixel_width <= 0 ||
      pixel_height <= 0 || pixel_width > 32768 || pixel_height > 32768 ||
      !std::isfinite(scale) || scale <= 0 || scale > 16)
    return false;
  OpenFramePresentation::CreateForWebContents(contents);
  return OpenFramePresentation::FromWebContents(contents)->Request(
      request_id, gfx::Size(pixel_width, pixel_height), scale, retain_surface,
      callback);
}

void CefCancelOpenFramePresentation(CefRefPtr<CefBrowser> browser,
                                     int64_t request_id) {
  CEF_REQUIRE_UIT();
  auto* contents = ContentsFor(browser);
  auto* state = contents ? OpenFramePresentation::FromWebContents(contents) : nullptr;
  if (state)
    state->CancelIfMatching(request_id);
}
