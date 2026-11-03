// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// Per-page state of the Open page API (cef/include/cef_open_page.h): the page
// handler, the selection flag (EP-3), the link to the selection (EP-2) and the
// history swipe options and events (EP-1). docs/plans/page-platform.md §6.

#include "open/browser/page/open_page_state.h"

#include <string>
#include <utility>
#include <vector>

#include "base/functional/bind.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "base/strings/utf_string_conversions.h"
#include "cef/include/cef_open_page.h"
#include "cef/libcef/browser/browser_host_base.h"
#include "cef/libcef/browser/thread_util.h"
#include "components/shared_highlighting/core/common/fragment_directives_utils.h"
#include "components/shared_highlighting/core/common/shared_highlighting_metrics.h"
#include "content/browser/renderer_host/render_widget_host_view_base.h"
#include "content/browser/renderer_host/text_input_manager.h"
#include "content/browser/web_contents/web_contents_impl.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/render_widget_host_view.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_contents_observer.h"
#include "content/public/browser/web_contents_user_data.h"
#include "mojo/public/cpp/bindings/callback_helpers.h"
#include "mojo/public/cpp/bindings/remote.h"
#include "services/service_manager/public/cpp/interface_provider.h"
#include "third_party/blink/public/mojom/link_to_text/link_to_text.mojom.h"

namespace open_engine {

namespace {

content::WebContents* WebContentsFor(CefRefPtr<CefBrowser> browser) {
  auto host = CefBrowserHostBase::FromBrowser(browser);
  return host ? host->GetWebContents() : nullptr;
}

class OpenPageState : public content::WebContentsObserver,
                      public content::TextInputManager::Observer,
                      public content::WebContentsUserData<OpenPageState> {
 public:
  OpenPageState(const OpenPageState&) = delete;
  OpenPageState& operator=(const OpenPageState&) = delete;
  ~OpenPageState() override { StopObservingSelection(); }

  void SetHandler(CefRefPtr<CefOpenPageHandler> handler) {
    handler_ = handler;
    if (handler_) {
      StartObservingSelection();
    }
  }
  CefRefPtr<CefOpenPageHandler> handler() const { return handler_; }

  bool has_selection() const { return has_selection_; }

  bool swipe_enabled = true;
  bool swipe_draws_overlay = true;

  void RequestSelection(CefRefPtr<CefSelectionCallback> callback) {
    content::RenderFrameHost* frame = web_contents()->GetFocusedFrame();
    if (!frame) {
      frame = web_contents()->GetPrimaryMainFrame();
    }
    content::RenderWidgetHostView* view = frame ? frame->GetView() : nullptr;
    const std::u16string text = view ? view->GetSelectedText() : u"";
    // A text directive on the top URL cannot reach a child document: text
    // only for a selection inside an iframe (page-platform EP-2).
    if (text.empty() || !frame->IsInPrimaryMainFrame() ||
        !frame->IsRenderFrameLive()) {
      callback->OnSelection(text, CefString());
      return;
    }
    // One generator request at a time; a newer request drops the older one
    // (its callback still runs once, with no link).
    fragment_receiver_.reset();
    frame->GetRemoteInterfaces()->GetInterface(
        fragment_receiver_.BindNewPipeAndPassReceiver());
    const GURL url = frame->GetLastCommittedURL();
    fragment_receiver_->RequestSelectorForSelection(
        mojo::WrapCallbackWithDefaultInvokeIfNotRun(
            base::BindOnce(&OpenPageState::OnSelector,
                           weak_factory_.GetWeakPtr(), url, text, callback),
            std::string(), shared_highlighting::LinkGenerationError::kUnknown,
            shared_highlighting::LinkGenerationReadyStatus::kRequestedAfterReady));
  }

 private:
  friend class content::WebContentsUserData<OpenPageState>;

  explicit OpenPageState(content::WebContents* web_contents)
      : content::WebContentsObserver(web_contents),
        content::WebContentsUserData<OpenPageState>(*web_contents) {}

  // Static so that the callback runs once also after the page went away.
  static void OnSelector(base::WeakPtr<OpenPageState> state,
                         const GURL& url,
                         const std::u16string& text,
                         CefRefPtr<CefSelectionCallback> callback,
                         const std::string& selector,
                         shared_highlighting::LinkGenerationError error,
                         shared_highlighting::LinkGenerationReadyStatus status) {
    std::string link;
    if (!selector.empty() &&
        error == shared_highlighting::LinkGenerationError::kNone) {
      GURL with_fragment = shared_highlighting::AppendSelectors(url, {selector});
      if (with_fragment.is_valid()) {
        link = with_fragment.spec();
      }
    }
    callback->OnSelection(text, link);
  }

  content::TextInputManager* text_input_manager() {
    return static_cast<content::WebContentsImpl*>(web_contents())
        ->GetTextInputManager();
  }

  void StartObservingSelection() {
    if (observed_manager_) {
      return;
    }
    observed_manager_ = text_input_manager();
    if (observed_manager_) {
      observed_manager_->AddObserver(this);
    }
  }

  void StopObservingSelection() {
    if (observed_manager_) {
      observed_manager_->RemoveObserver(this);
      observed_manager_ = nullptr;
    }
  }

  // content::TextInputManager::Observer:
  void OnTextSelectionChanged(
      content::TextInputManager* manager,
      content::RenderWidgetHostViewBase* updated_view) override {
    const content::TextInputManager::TextSelection* selection =
        manager->GetTextSelection(updated_view);
    SetHasSelection(selection && !selection->selected_text().empty());
  }

  // content::WebContentsObserver:
  void PrimaryPageChanged(content::Page& page) override {
    SetHasSelection(false);
  }
  void WebContentsDestroyed() override { StopObservingSelection(); }

  void SetHasSelection(bool has_selection) {
    if (has_selection == has_selection_) {
      return;
    }
    has_selection_ = has_selection;
    if (handler_) {
      auto browser = CefBrowserHostBase::GetBrowserForContents(web_contents());
      if (browser) {
        handler_->OnSelectionChanged(browser.get(), has_selection_);
      }
    }
  }

  CefRefPtr<CefOpenPageHandler> handler_;
  raw_ptr<content::TextInputManager> observed_manager_ = nullptr;
  bool has_selection_ = false;
  mojo::Remote<blink::mojom::TextFragmentReceiver> fragment_receiver_;
  base::WeakPtrFactory<OpenPageState> weak_factory_{this};

  WEB_CONTENTS_USER_DATA_KEY_DECL();
};

WEB_CONTENTS_USER_DATA_KEY_IMPL(OpenPageState);

OpenPageState* StateFor(content::WebContents* web_contents) {
  return web_contents ? OpenPageState::FromWebContents(web_contents) : nullptr;
}

}  // namespace

bool HistorySwipeEnabled(content::WebContents* web_contents) {
  OpenPageState* state = StateFor(web_contents);
  return !state || state->swipe_enabled;
}

bool HistorySwipeDrawsOverlay(content::WebContents* web_contents) {
  OpenPageState* state = StateFor(web_contents);
  return !state || state->swipe_draws_overlay;
}

void ReportHistorySwipe(content::WebContents* web_contents,
                        int phase,
                        int direction,
                        double progress) {
  OpenPageState* state = StateFor(web_contents);
  if (!state || !state->handler()) {
    return;
  }
  auto browser = CefBrowserHostBase::GetBrowserForContents(web_contents);
  if (browser) {
    state->handler()->OnHistorySwipe(browser.get(), phase, direction,
                                     progress);
  }
}

}  // namespace open_engine

bool CefSetOpenPageHandler(CefRefPtr<CefBrowser> browser,
                           CefRefPtr<CefOpenPageHandler> handler) {
  CEF_REQUIRE_UIT_RETURN(false);
  content::WebContents* web_contents = open_engine::WebContentsFor(browser);
  if (!web_contents) {
    return false;
  }
  open_engine::OpenPageState::CreateForWebContents(web_contents);
  open_engine::OpenPageState::FromWebContents(web_contents)
      ->SetHandler(handler);
  open_engine::InstallHistorySwipeHooks(web_contents);
  return true;
}

bool CefHasSelection(CefRefPtr<CefBrowser> browser) {
  CEF_REQUIRE_UIT_RETURN(false);
  auto* state = open_engine::StateFor(open_engine::WebContentsFor(browser));
  return state && state->has_selection();
}

bool CefRequestSelection(CefRefPtr<CefBrowser> browser,
                         CefRefPtr<CefSelectionCallback> callback) {
  CEF_REQUIRE_UIT_RETURN(false);
  content::WebContents* web_contents = open_engine::WebContentsFor(browser);
  if (!web_contents || !callback) {
    return false;
  }
  open_engine::OpenPageState::CreateForWebContents(web_contents);
  open_engine::OpenPageState::FromWebContents(web_contents)
      ->RequestSelection(callback);
  return true;
}

bool CefSetHistorySwipeOptions(CefRefPtr<CefBrowser> browser,
                               bool enabled,
                               bool draws_overlay) {
  CEF_REQUIRE_UIT_RETURN(false);
  content::WebContents* web_contents = open_engine::WebContentsFor(browser);
  if (!web_contents) {
    return false;
  }
  open_engine::OpenPageState::CreateForWebContents(web_contents);
  auto* state = open_engine::OpenPageState::FromWebContents(web_contents);
  state->swipe_enabled = enabled;
  state->swipe_draws_overlay = draws_overlay;
  open_engine::InstallHistorySwipeHooks(web_contents);
  return true;
}
