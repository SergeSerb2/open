// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef OPEN_BROWSER_TAB_STRIP_OPEN_BROWSER_WINDOW_H_
#define OPEN_BROWSER_TAB_STRIP_OPEN_BROWSER_WINDOW_H_

#include <memory>
#include <string>
#include <vector>

#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "cef/include/internal/cef_mac.h"
#include "chrome/browser/ui/browser_window.h"
#include "chrome/browser/ui/exclusive_access/exclusive_access_context.h"

class Browser;
class Profile;

namespace contextual_tasks {
class LocationBarStub;
}

namespace web_modal {
class WebContentsModalDialogHost;
}

namespace open_engine {
class OpenAutofillBubbleHandler;

// The BrowserWindow of a hidden tab-strip Browser (docs/engine-patches.md,
// P1). It has no Views: it stands for one Open window. GetNativeWindow is the
// window of the embedder's host view, bounds and activation come from that
// NSWindow, unhandled keys go to the main menu, and HTML fullscreen is
// reported to the tab's CEF client, whose embedder decides what to show.
// Owned by its Browser (deleted through DeleteBrowserWindow).
class OpenBrowserWindow : public BrowserWindow, public ExclusiveAccessContext {
 public:
  explicit OpenBrowserWindow(Profile* profile);
  OpenBrowserWindow(const OpenBrowserWindow&) = delete;
  OpenBrowserWindow& operator=(const OpenBrowserWindow&) = delete;
  ~OpenBrowserWindow() override;

  // Called once the Browser that owns this window exists.
  void SetBrowser(Browser* browser);
  void SetInitialBounds(const gfx::Rect& bounds) { pending_bounds_ = bounds; }
  // The embedder view whose NSWindow this window stands for (may be null).
  void SetHostView(CefWindowHandle view);
  // Stop native key notifications before close callbacks tear down popups.
  // The Browser and this window can remain alive until the next run-loop turn.
  void OnBrowserClosing();

  // ui::BaseWindow:
  void Show() override;
  void ShowInactive() override;
  void Hide() override;
  bool IsVisible() const override;
  void SetBounds(const gfx::Rect& bounds) override;
  void Close() override;
  void Activate() override;
  void Deactivate() override;
  bool IsActive() const override;
  void FlashFrame(bool flash) override {}
  ui::ZOrderLevel GetZOrderLevel() const override;
  void SetZOrderLevel(ui::ZOrderLevel order) override {}
  gfx::NativeWindow GetNativeWindow() const override;
  bool IsOnCurrentWorkspace() const override;
  bool IsVisibleOnScreen() const override;
  gfx::Rect GetRestoredBounds() const override;
  ui::mojom::WindowShowState GetRestoredState() const override;
  gfx::Rect GetBounds() const override;
  bool IsMaximized() const override;
  bool IsMinimized() const override;
  void Maximize() override;
  void Minimize() override;
  void Restore() override;
  bool IsFullscreen() const override;  // Also ExclusiveAccessContext.

  // BrowserWindow:
  void SetTopControlsShownRatio(content::WebContents* web_contents,
                                float ratio) override {}
  bool DoBrowserControlsShrinkRendererSize(
      const content::WebContents* contents) const override;
  ui::NativeTheme* GetNativeTheme() override;
  const ui::ThemeProvider* GetThemeProvider() const override;
  const ui::ColorProvider* GetColorProvider() const override;
  int GetTopControlsHeight() const override;
  void SetTopControlsGestureScrollInProgress(bool in_progress) override {}
  std::vector<StatusBubble*> GetStatusBubbles() override;
  void UpdateTitleBar() override {}
  void UpdateLoadingAnimations(bool is_visible) override {}
  void OnActiveTabChanged(content::WebContents* old_contents,
                          content::WebContents* new_contents,
                          int index,
                          int reason) override {}
  void OnTabDetached(content::WebContents* contents, bool was_active) override {
  }
  gfx::Size GetContentsSize() const override;
  void SetContentsSize(const gfx::Size& size) override {}
  bool GetCanResize() override;
  ui::mojom::WindowShowState GetWindowShowState() const override;
  LocationBar* GetLocationBar() const override;
  ui::AcceleratorProvider* GetAcceleratorProvider() override;
  PinnedToolbarActions* GetPinnedToolbarActions() override;
  autofill::AutofillBubbleHandler* GetAutofillBubbleHandler() override;
  void SetFocusToLocationBar(bool is_user_initiated) override {}
  void UpdateReloadStopState(bool is_loading, bool force) override {}
  void UpdateToolbar(content::WebContents* contents) override {}
  bool UpdateToolbarSecurityState() override;
  void UpdateCustomTabBarVisibility(bool visible, bool animate) override {}
  void ResetToolbarTabState(content::WebContents* contents) override {}
  void FocusToolbar() override {}
  void ToolbarSizeChanged(bool is_animating) override {}
  void TabDraggingStatusChanged(bool is_dragging) override {}
  void LinkOpeningFromGesture(WindowOpenDisposition disposition) override {}
  void FocusAppMenu() override {}
  void ShowAppMenu() override {}
  void PreHandleDragUpdate(const content::DropData& drop_data,
                           const gfx::PointF& point) override {}
  void PreHandleDragExit() override {}
  void HandleDragEnded() override {}
  content::KeyboardEventProcessingResult PreHandleKeyboardEvent(
      const input::NativeWebKeyboardEvent& event) override;
  bool HandleKeyboardEvent(const input::NativeWebKeyboardEvent& event) override;
  bool IsTabStripEditable() const override;
  void DisableTabStripEditingForTesting() override {}
  bool IsToolbarVisible() const override;
  bool IsLocationBarVisible() const override;
  bool IsToolbarShowing() const override;
  bool IsUnframedModeEnabled() const override;
  void ShowChromeLabs() override {}
  BrowserView* AsBrowserView() override;
  void ShowUpdateChromeDialog() override {}
  void ShowBookmarkBubble(const GURL& url, bool already_bookmarked) override {}
  void ShowIntentPickerBubble(
      std::vector<apps::IntentPickerAppInfo> app_info,
      bool show_stay_in_chrome,
      bool show_remember_selection,
      apps::IntentPickerBubbleType bubble_type,
      const std::optional<url::Origin>& initiating_origin,
      IntentPickerResponse callback) override {}
  ShowTranslateBubbleResult ShowTranslateBubble(
      content::WebContents* contents,
      translate::TranslateStep step,
      const std::string& source_language,
      const std::string& target_language,
      translate::TranslateErrors error_type,
      bool is_user_gesture) override;
  DownloadBubbleUIController* GetDownloadBubbleUIController() override;
  void ConfirmBrowserCloseWithPendingDownloads(
      int download_count,
      DownloadCloseType dialog_type,
      base::OnceCallback<void(bool)> callback) override;
  std::unique_ptr<FindBar> CreateFindBar() override;
  web_modal::WebContentsModalDialogHost* GetWebContentsModalDialogHost()
      override;
  web_modal::WebContentsModalDialogHost* GetWebContentsModalDialogHostFor(
      content::WebContents* web_contents) override;
  void ShowAvatarBubbleFromAvatarButton(bool is_source_keyboard) override {}
  void MaybeShowProfileSwitchIPH() override {}
  void MaybeShowSupervisedUserProfileSignInIPH() override {}
  void ShowHatsDialog(
      const std::string& site_id,
      const std::optional<std::string>& hats_histogram_name,
      const std::optional<uint64_t> hats_survey_ukm_id,
      base::OnceClosure success_callback,
      base::OnceClosure failure_callback,
      const SurveyBitsData& product_specific_bits_data,
      const SurveyStringData& product_specific_string_data) override {}
  void ShowIncognitoClearBrowsingDataDialog() override {}
  void ShowIncognitoHistoryDisclaimerDialog() override {}
  ExclusiveAccessContext* GetExclusiveAccessContext() override;
  std::string GetWorkspace() const override;
  bool IsVisibleOnAllWorkspaces() const override;
  void ShowEmojiPanel() override {}
  void ShowCaretBrowsingDialog() override {}
  std::unique_ptr<content::EyeDropper> OpenEyeDropper(
      content::RenderFrameHost* frame,
      content::EyeDropperListener* listener) override;
  void CreateTabSearchBubble() override {}
  void CloseTabSearchBubble() override {}

  // ExclusiveAccessContext:
  Profile* GetProfile() override;
  void EnterFullscreen(const url::Origin& origin,
                       ExclusiveAccessBubbleType bubble_type,
                       FullscreenTabParams fullscreen_tab_params) override;
  void ExitFullscreen() override;
  void UpdateExclusiveAccessBubble(
      const ExclusiveAccessBubbleParams& params,
      ExclusiveAccessBubbleHideCallback first_hide_callback) override {}
  bool IsExclusiveAccessBubbleDisplayed() const override;
  void OnExclusiveAccessUserInput() override {}
  content::WebContents* GetWebContentsForExclusiveAccess() override;
  bool CanUserEnterFullscreen() const override;
  bool CanUserExitFullscreen() const override;

 protected:
  void DeleteBrowserWindow() final;

 private:
  struct HostState;  // ObjC state (host view, window observers).

  void OnHostWindowKeyChanged(bool key);
  bool CanActivateBrowser() const;
  void NotifyFullscreenStateChanged();

  const raw_ptr<Profile> profile_;
  raw_ptr<Browser> browser_ = nullptr;
  std::unique_ptr<contextual_tasks::LocationBarStub> location_bar_;
  std::unique_ptr<HostState> host_;
  std::unique_ptr<OpenAutofillBubbleHandler> autofill_handler_;
  std::unique_ptr<web_modal::WebContentsModalDialogHost> dialog_host_;
  bool html_fullscreen_ = false;
  bool closing_ = false;
  gfx::Rect pending_bounds_;

  base::WeakPtrFactory<OpenBrowserWindow> weak_ptr_factory_{this};
};

}  // namespace open_engine

#endif  // OPEN_BROWSER_TAB_STRIP_OPEN_BROWSER_WINDOW_H_
