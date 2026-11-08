// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef OPEN_BROWSER_MEDIA_OPEN_DOCUMENT_PIP_HOST_H_
#define OPEN_BROWSER_MEDIA_OPEN_DOCUMENT_PIP_HOST_H_

#include <memory>
#include <optional>

#include "base/memory/weak_ptr.h"
#include "cef/include/cef_media_controller.h"
#include "content/public/browser/web_contents_delegate.h"
#include "content/public/browser/web_contents_observer.h"
#include "content/public/browser/web_contents_user_data.h"
#include "third_party/blink/public/mojom/picture_in_picture_window_options/picture_in_picture_window_options.mojom.h"
#include "ui/gfx/geometry/rect.h"
#include "ui/gfx/geometry/size.h"

namespace open_engine {

class OpenDocumentPictureInPictureSession;

// EM-7 (docs/plans/media-pip.md §6): Document Picture in Picture shown in the
// embedder's own window. Modelled on Chromium's standalone DocumentPipHost
// (chrome/browser/ui/views/picture_in_picture/document_pip_host.cc), with an
// NSView in place of a Views widget. Attached to the opener; owns the child
// WebContents and is its delegate. Chromium's DocumentPictureInPicture
// controller keeps its rules (one PiP app-wide, close when the opener
// navigates or goes away); the embedder sees the session as a
// CefPictureInPictureWindow whose GetState has "kind": "document".
// Everything runs on the browser UI thread (the main thread).
class OpenDocumentPipHost
    : public content::WebContentsUserData<OpenDocumentPipHost>,
      public content::WebContentsObserver,
      public content::WebContentsDelegate {
 public:
  ~OpenDocumentPipHost() override;
  OpenDocumentPipHost(const OpenDocumentPipHost&) = delete;
  OpenDocumentPipHost& operator=(const OpenDocumentPipHost&) = delete;

  // Takes |child| and reports the session to |handler|. Registers Chromium's
  // controller first, which closes any other Picture in Picture.
  void Show(std::unique_ptr<content::WebContents> child,
            blink::mojom::PictureInPictureWindowOptions options,
            CefRefPtr<CefMediaControllerHandler> handler,
            CefRefPtr<CefBrowser> browser);

  // From OpenDocumentPictureInPictureSession (the embedder's calls).
  void* view() const;
  CefRefPtr<CefDictionaryValue> GetState() const;
  void SetWindowFrame(const gfx::Rect& frame_in_screen, bool visible);
  void ExecuteAction(const std::string& action,
                     CefRefPtr<CefDictionaryValue> args);

  // content::WebContentsObserver (the opener):
  void TitleWasSet(content::NavigationEntry* entry) override;

  // content::WebContentsDelegate (the child):
  blink::mojom::DisplayMode GetDisplayMode(
      const content::WebContents* web_contents) override;
  void CloseContents(content::WebContents* source) override;
  bool IsContentsActive(content::WebContents* contents) override;
  void SetContentsBounds(content::WebContents* source,
                         const gfx::Rect& bounds) override;
  content::WebContents* OpenURLFromTab(
      content::WebContents* source,
      const content::OpenURLParams& params,
      base::OnceCallback<void(content::NavigationHandle&)>
          navigation_handle_callback) override;
  content::WebContents* AddNewContents(
      content::WebContents* source,
      std::unique_ptr<content::WebContents> new_contents,
      const GURL& target_url,
      WindowOpenDisposition disposition,
      const blink::mojom::WindowFeatures& window_features,
      bool user_gesture,
      bool* was_blocked) override;
  bool HandleKeyboardEvent(content::WebContents* source,
                           const input::NativeWebKeyboardEvent& event) override;
  std::optional<gfx::Rect> GetWindowBoundsInScreen() override;

 private:
  friend class content::WebContentsUserData<OpenDocumentPipHost>;
  explicit OpenDocumentPipHost(content::WebContents* opener);

  // Ends the shown session: the embedder hears OnPictureInPictureClosed, then
  // the child goes (Chromium's controller sees it and notifies the opener).
  void ClosePipWindow(bool post_closed = false);
  void ScheduleChanged();

  std::unique_ptr<content::WebContents> child_;
  blink::mojom::PictureInPictureWindowOptions options_;
  gfx::Size requested_size_;
  CefRefPtr<CefMediaControllerHandler> handler_;
  CefRefPtr<CefBrowser> browser_;
  CefRefPtr<OpenDocumentPictureInPictureSession> session_;
  gfx::Rect frame_in_screen_;
  bool frame_reported_ = false;
  bool changed_pending_ = false;

  base::WeakPtrFactory<OpenDocumentPipHost> weak_ptr_factory_{this};

  WEB_CONTENTS_USER_DATA_KEY_DECL();
};

}  // namespace open_engine

#endif  // OPEN_BROWSER_MEDIA_OPEN_DOCUMENT_PIP_HOST_H_
