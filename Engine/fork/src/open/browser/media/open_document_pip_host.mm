// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "open/browser/media/open_document_pip_host.h"

#import <AppKit/AppKit.h>

#include <utility>

#include "base/functional/bind.h"
#include "base/strings/utf_string_conversions.h"
#include "base/task/sequenced_task_runner.h"
#include "cef/libcef/browser/thread_util.h"
#include "chrome/browser/picture_in_picture/picture_in_picture_window_manager.h"
#include "components/input/native_web_keyboard_event.h"
#include "content/public/browser/document_picture_in_picture_window_controller.h"
#include "content/public/browser/picture_in_picture_window_controller.h"
#include "content/public/browser/web_contents.h"
#include "open/browser/media/open_media_controller.h"
#include "open/browser/media/open_media_hooks.h"
#include "third_party/blink/public/mojom/manifest/display_mode.mojom.h"
#include "ui/gfx/native_ui_types.h"

namespace open_engine {

// The embedder's handle on one shown Document PiP (CefPictureInPictureWindow,
// as EM-4's video session). Invalid once the session ends.
class OpenDocumentPictureInPictureSession : public CefPictureInPictureWindow {
 public:
  explicit OpenDocumentPictureInPictureSession(
      base::WeakPtr<OpenDocumentPipHost> host)
      : host_(std::move(host)) {}
  OpenDocumentPictureInPictureSession(
      const OpenDocumentPictureInPictureSession&) = delete;
  OpenDocumentPictureInPictureSession& operator=(
      const OpenDocumentPictureInPictureSession&) = delete;

  void Invalidate() { host_ = nullptr; }

  // CefPictureInPictureWindow:
  bool IsValid() override {
    CEF_REQUIRE_UIT_RETURN(false);
    return !!host_;
  }
  CefWindowHandle GetVideoView() override {
    CEF_REQUIRE_UIT_RETURN(nullptr);
    return host_ ? static_cast<CefWindowHandle>(host_->view()) : nullptr;
  }
  CefRefPtr<CefDictionaryValue> GetState() override {
    CEF_REQUIRE_UIT_RETURN(nullptr);
    return host_ ? host_->GetState() : CefDictionaryValue::Create();
  }
  void SetWindowFrame(const CefRect& frame, bool visible) override {
    CEF_REQUIRE_UIT();
    if (host_) {
      host_->SetWindowFrame(
          gfx::Rect(frame.x, frame.y, frame.width, frame.height), visible);
    }
  }
  void ExecuteAction(const CefString& action,
                     CefRefPtr<CefDictionaryValue> args) override {
    CEF_REQUIRE_UIT();
    if (host_) {
      host_->ExecuteAction(action.ToString(), args);
    }
  }

 private:
  ~OpenDocumentPictureInPictureSession() override = default;

  base::WeakPtr<OpenDocumentPipHost> host_;

  IMPLEMENT_REFCOUNTING(OpenDocumentPictureInPictureSession);
};

bool MaybeHostDocumentPictureInPicture(
    content::WebContents* opener,
    std::unique_ptr<content::WebContents>& child) {
  if (!opener || !child) {
    return false;
  }
  std::optional<blink::mojom::PictureInPictureWindowOptions> options =
      child->GetPictureInPictureOptions();
  if (!options.has_value()) {
    return false;
  }
  OpenMediaController* controller = OpenMediaController::FromWebContents(opener);
  CefRefPtr<CefMediaControllerHandler> handler;
  CefRefPtr<CefBrowser> browser;
  if (!controller || !controller->GetPictureInPictureHost(&handler, &browser)) {
    return false;
  }
  OpenDocumentPipHost::CreateForWebContents(opener);
  OpenDocumentPipHost::FromWebContents(opener)->Show(
      std::move(child), std::move(*options), handler, browser);
  return true;
}

WEB_CONTENTS_USER_DATA_KEY_IMPL(OpenDocumentPipHost);

OpenDocumentPipHost::OpenDocumentPipHost(content::WebContents* opener)
    : content::WebContentsUserData<OpenDocumentPipHost>(*opener),
      content::WebContentsObserver(opener) {}

OpenDocumentPipHost::~OpenDocumentPipHost() {
  // The opener is going away (Chromium's controller closes with it). The
  // embedder hears it on the next turn, not from inside the opener's teardown.
  ClosePipWindow(/*post_closed=*/true);
}

void OpenDocumentPipHost::Show(
    std::unique_ptr<content::WebContents> child,
    blink::mojom::PictureInPictureWindowOptions options,
    CefRefPtr<CefMediaControllerHandler> handler,
    CefRefPtr<CefBrowser> browser) {
  ClosePipWindow();
  child_ = std::move(child);
  options_ = std::move(options);
  requested_size_ = gfx::Size(static_cast<int>(options_.width),
                              static_cast<int>(options_.height));
  handler_ = handler;
  browser_ = browser;
  frame_reported_ = false;
  child_->SetDelegate(this);
  // Chromium's side first (as the Browser-backed and standalone paths do): it
  // closes any other Picture in Picture and ties the child to the opener.
  PictureInPictureWindowManager::GetInstance()->EnterDocumentPictureInPicture(
      web_contents(), child_.get());
  session_ = new OpenDocumentPictureInPictureSession(
      weak_ptr_factory_.GetWeakPtr());
  // Synchronous, as EM-4's open: the embedder places the view now.
  handler_->OnPictureInPictureOpened(browser_, session_.get());
}

void* OpenDocumentPipHost::view() const {
  return child_ ? (__bridge void*)child_->GetNativeView().GetNativeNSView()
                : nullptr;
}

CefRefPtr<CefDictionaryValue> OpenDocumentPipHost::GetState() const {
  CefRefPtr<CefDictionaryValue> state = CefDictionaryValue::Create();
  state->SetString("kind", "document");
  // The size the page asked for (CSS px); a later resizeTo updates it.
  state->SetInt("naturalWidth", requested_size_.width());
  state->SetInt("naturalHeight", requested_size_.height());
  state->SetInt("playbackState", 0);
  state->SetInt("controls", 0);
  state->SetBool("disallowReturnToOpener", options_.disallow_return_to_opener);
  state->SetString("sourceTitle",
                   web_contents() ? web_contents()->GetTitle() : u"");
  return state;
}

void OpenDocumentPipHost::SetWindowFrame(const gfx::Rect& frame_in_screen,
                                         bool visible) {
  frame_in_screen_ = frame_in_screen;
  frame_reported_ = true;
}

void OpenDocumentPipHost::ExecuteAction(const std::string& action,
                                        CefRefPtr<CefDictionaryValue> args) {
  if (action != "close" || !child_) {
    return;
  }
  // As the video window: behavior 1 pauses (the user's Close), 2 is Back to
  // Tab. Chromium's controller asks the child to close (pagehide runs, so the
  // page can take its elements back) and ends in CloseContents. Posted: the
  // embedder may call from inside its own callback.
  const bool pause = args && args->GetInt("behavior") == 1;
  base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce(
                     [](base::WeakPtr<OpenDocumentPipHost> host, bool pause) {
                       if (!host || !host->child_ || !host->web_contents()) {
                         return;
                       }
                       content::PictureInPictureWindowController::
                           GetOrCreateDocumentPictureInPictureController(
                               host->web_contents())
                               ->Close(pause);
                     },
                     weak_ptr_factory_.GetWeakPtr(), pause));
}

void OpenDocumentPipHost::ClosePipWindow(bool post_closed) {
  if (!child_) {
    return;
  }
  // The embedder takes the view out of its window first, then the child goes
  // (the deletion is posted after the notice). Destroying the child tells
  // Chromium's controller (OnChildContentsDestroyed), which notifies the opener.
  CefRefPtr<OpenDocumentPictureInPictureSession> ended = session_;
  session_ = nullptr;
  if (ended) {
    ended->Invalidate();
    if (post_closed) {
      base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
          FROM_HERE,
          base::BindOnce(
              [](CefRefPtr<CefMediaControllerHandler> handler,
                 CefRefPtr<CefBrowser> browser,
                 CefRefPtr<OpenDocumentPictureInPictureSession> ended) {
                handler->OnPictureInPictureClosed(browser, ended.get());
              },
              handler_, browser_, ended));
    } else {
      handler_->OnPictureInPictureClosed(browser_, ended.get());
    }
  }
  std::unique_ptr<content::WebContents> child = std::move(child_);
  child->SetDelegate(nullptr);
  handler_ = nullptr;
  browser_ = nullptr;
  base::SequencedTaskRunner::GetCurrentDefault()->DeleteSoon(FROM_HERE,
                                                            std::move(child));
}

void OpenDocumentPipHost::ScheduleChanged() {
  if (changed_pending_) {
    return;
  }
  changed_pending_ = true;
  base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce(
                     [](base::WeakPtr<OpenDocumentPipHost> host) {
                       if (!host) {
                         return;
                       }
                       host->changed_pending_ = false;
                       if (host->session_ && host->handler_) {
                         host->handler_->OnPictureInPictureChanged(
                             host->browser_, host->session_.get());
                       }
                     },
                     weak_ptr_factory_.GetWeakPtr()));
}

// content::WebContentsObserver (the opener):

void OpenDocumentPipHost::TitleWasSet(content::NavigationEntry* entry) {
  ScheduleChanged();
}

// content::WebContentsDelegate (the child):

blink::mojom::DisplayMode OpenDocumentPipHost::GetDisplayMode(
    const content::WebContents* web_contents) {
  return blink::mojom::DisplayMode::kPictureInPicture;
}

void OpenDocumentPipHost::CloseContents(content::WebContents* source) {
  // window.close() in the PiP document, or the end of the controller's Close.
  ClosePipWindow();
}

bool OpenDocumentPipHost::IsContentsActive(content::WebContents* contents) {
  return true;
}

void OpenDocumentPipHost::SetContentsBounds(content::WebContents* source,
                                            const gfx::Rect& bounds) {
  // window.resizeTo/resizeBy (with a user gesture): the embedder resizes its
  // window to the new requested size. Moves stay the embedder's choice.
  if (bounds.size().IsEmpty() || bounds.size() == requested_size_) {
    return;
  }
  requested_size_ = bounds.size();
  ScheduleChanged();
}

content::WebContents* OpenDocumentPipHost::OpenURLFromTab(
    content::WebContents* source,
    const content::OpenURLParams& params,
    base::OnceCallback<void(content::NavigationHandle&)>
        navigation_handle_callback) {
  // A navigation of the PiP document itself closes it (Chromium's rule).
  if (params.disposition == WindowOpenDisposition::CURRENT_TAB) {
    base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE, base::BindOnce(&OpenDocumentPipHost::ClosePipWindow,
                                  weak_ptr_factory_.GetWeakPtr(), false));
    return nullptr;
  }
  // Links to other windows open from the opener.
  content::WebContents* opener = web_contents();
  if (opener && opener->GetDelegate()) {
    return opener->GetDelegate()->OpenURLFromTab(
        opener, params, std::move(navigation_handle_callback));
  }
  return nullptr;
}

content::WebContents* OpenDocumentPipHost::AddNewContents(
    content::WebContents* source,
    std::unique_ptr<content::WebContents> new_contents,
    const GURL& target_url,
    WindowOpenDisposition disposition,
    const blink::mojom::WindowFeatures& window_features,
    bool user_gesture,
    bool* was_blocked) {
  content::WebContents* opener = web_contents();
  if (opener && opener->GetDelegate()) {
    return opener->GetDelegate()->AddNewContents(
        opener, std::move(new_contents), target_url, disposition,
        window_features, user_gesture, was_blocked);
  }
  if (was_blocked) {
    *was_blocked = true;
  }
  return nullptr;
}

bool OpenDocumentPipHost::HandleKeyboardEvent(
    content::WebContents* source,
    const input::NativeWebKeyboardEvent& event) {
  // Keys the page did not use reach the App's menus (Cmd+W, Cmd+Q), as in
  // any of the App's windows.
  NSEvent* ns_event = event.os_event.Get();
  if (!ns_event || ns_event.type != NSEventTypeKeyDown) {
    return false;
  }
  return [[NSApp mainMenu] performKeyEquivalent:ns_event];
}

std::optional<gfx::Rect> OpenDocumentPipHost::GetWindowBoundsInScreen() {
  if (!frame_reported_) {
    return std::nullopt;
  }
  return frame_in_screen_;
}

}  // namespace open_engine
