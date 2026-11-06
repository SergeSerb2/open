// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "open/browser/tab_strip/open_browser_window.h"

#include <limits>

#import <AppKit/AppKit.h>

#include "base/command_line.h"
#include "base/functional/bind.h"
#include "base/memory/raw_ptr.h"
#include "base/observer_list.h"
#include "base/task/single_thread_task_runner.h"
#include "cef/include/internal/cef_types_mac.h"
#include "cef/libcef/browser/thread_util.h"
#include "chrome/browser/contextual_tasks/location_bar_stub.h"
#include "chrome/browser/lifetime/browser_shutdown.h"
#include "chrome/browser/ui/browser.h"
#include "chrome/browser/ui/browser_active_state_manager/browser_active_state_manager.h"
#include "chrome/browser/ui/browser_window/public/browser_window_features.h"
#include "chrome/browser/ui/browser_window/public/global_browser_collection.h"
#include "chrome/browser/ui/exclusive_access/exclusive_access_manager.h"
#include "chrome/browser/ui/exclusive_access/fullscreen_controller.h"
#include "chrome/browser/ui/find_bar/find_bar.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"
#include "chrome/browser/ui/unload_controller.h"
#include "components/input/native_web_keyboard_event.h"
#include "components/web_modal/modal_dialog_host.h"
#include "components/web_modal/web_contents_modal_dialog_host.h"
#include "content/public/browser/eye_dropper.h"
#include "content/public/browser/keyboard_event_processing_result.h"
#include "ui/base/mojom/window_show_state.mojom.h"
#include "ui/color/color_provider_key.h"
#include "ui/color/color_provider_manager.h"
#include "ui/gfx/mac/coordinate_conversion.h"
#include "ui/gfx/range/range.h"
#include "ui/native_theme/native_theme.h"
#include "open/browser/tab_strip/open_tab_strip.h"

namespace open_engine {

namespace {

int g_invalid_activation_requests = 0;

bool IsRegisteredBrowser(Browser* browser) {
  return browser && GlobalBrowserCollection::GetInstance()->FindBrowserWithID(
                        browser->GetSessionID()) == browser;
}

// Keep negative real-App proofs safe: count the call that would reach
// Chromium's collection CHECK, then refuse it only in automation. Normal
// launches never enable or update this diagnostic.
bool RefuseUnsafeActivationForAutomation(Browser* browser) {
  if (base::CommandLine::ForCurrentProcess()->HasSwitch("open-automation") &&
      !IsRegisteredBrowser(browser)) {
    if (g_invalid_activation_requests < std::numeric_limits<int>::max()) {
      ++g_invalid_activation_requests;
    }
    return true;
  }
  return false;
}

// Browser's FindBarController needs a FindBar for every tab change once find
// was used. The embedder draws its own find UI (CefBrowserHost::Find and
// CefFindHandler); this one only keeps the controller and the text.
class HiddenFindBar : public FindBar {
 public:
  FindBarController* GetFindBarController() const override {
    return controller_;
  }
  void SetFindBarController(FindBarController* controller) override {
    controller_ = controller;
  }
  void Show(bool animate, bool focus) override {}
  void Hide(bool animate) override {}
  void SetFocusAndSelection() override {}
  void ClearResults(
      const find_in_page::FindNotificationDetails& results) override {}
  void StopAnimation() override {}
  void MoveWindowIfNecessary() override {}
  void SetFindTextAndSelectedRange(const std::u16string& find_text,
                                   const gfx::Range& selected_range) override {
    find_text_ = find_text;
    selected_range_ = selected_range;
  }
  std::u16string_view GetFindText() const override { return find_text_; }
  gfx::Range GetSelectedRange() const override { return selected_range_; }
  void UpdateUIForFindResult(
      const find_in_page::FindNotificationDetails& result,
      const std::u16string& find_text) override {}
  void AudibleAlert() override {}
  bool IsFindBarVisible() const override { return false; }
  void RestoreSavedFocus() override {}
  bool HasGlobalFindPasteboard() const override { return false; }
  void UpdateFindBarForChangedWebContents() override {}
  bool CanPopulateFromSelectedText() override { return false; }
  const FindBarTesting* GetFindBarTesting() const override { return nullptr; }
  bool HasFocus() const override { return false; }
  void CloseOverlappingBubbles() override {}
  views::Widget* GetHostWidget() override { return nullptr; }

 private:
  raw_ptr<FindBarController> controller_ = nullptr;
  std::u16string find_text_;
  gfx::Range selected_range_;
};

// Dialog host for browser- and tab-modal Chrome dialogs (Web Store install
// prompt, auth). Without a Views host view they open as free-standing
// windows, as with Alloy; patch P3 sends install prompts to the embedder.
class HiddenDialogHost : public web_modal::WebContentsModalDialogHost {
 public:
  gfx::NativeView GetHostView() const override { return gfx::NativeView(); }
  gfx::Point GetDialogPosition(const gfx::Size& size) override {
    return gfx::Point();
  }
  gfx::Size GetMaximumDialogSize() override { return gfx::Size(800, 600); }
  void AddObserver(web_modal::ModalDialogHostObserver* observer) override {
    if (observer && !observers_.HasObserver(observer)) {
      observers_.AddObserver(observer);
    }
  }
  void RemoveObserver(web_modal::ModalDialogHostObserver* observer) override {
    observers_.RemoveObserver(observer);
  }

 private:
  base::ObserverList<web_modal::ModalDialogHostObserver>::Unchecked
      observers_;
};

}  // namespace

// The host view (weak: the embedder owns it) and the observers of its
// window's key state.
struct OpenBrowserWindow::HostState {
  NSView* __weak view = nil;
  NSWindow* __weak observed_window = nil;
  id __strong become_key_observer = nil;
  id __strong resign_key_observer = nil;

  NSWindow* window() const { return view.window; }

  void StopObserving() {
    NSNotificationCenter* center = NSNotificationCenter.defaultCenter;
    if (become_key_observer) {
      [center removeObserver:become_key_observer];
    }
    if (resign_key_observer) {
      [center removeObserver:resign_key_observer];
    }
    become_key_observer = nil;
    resign_key_observer = nil;
    observed_window = nil;
  }
};

OpenBrowserWindow::OpenBrowserWindow(Profile* profile)
    : profile_(profile),
      location_bar_(std::make_unique<contextual_tasks::LocationBarStub>()),
      host_(std::make_unique<HostState>()) {}

OpenBrowserWindow::~OpenBrowserWindow() {
  host_->StopObserving();
  // As BrowserView and TestBrowserWindow do before the window goes away.
  if (browser_) {
    browser_->GetFeatures().TearDownPreBrowserWindowDestruction();
    browser_ = nullptr;
  }
}

void OpenBrowserWindow::SetBrowser(Browser* browser) {
  browser_ = browser;
  if (CanActivateBrowser() && IsActive()) {
    if (RefuseUnsafeActivationForAutomation(browser_)) {
      return;
    }
    BrowserActiveStateManager::From(browser_)->DidBecomeActive();
  }
}

void OpenBrowserWindow::SetHostView(CefWindowHandle handle) {
  NSView* view = CAST_CEF_WINDOW_HANDLE_TO_NSVIEW(handle);
  host_->view = view;
  if (closing_) {
    host_->StopObserving();
    return;
  }
  NSWindow* window = view.window;
  if (window == host_->observed_window) {
    return;
  }
  host_->StopObserving();
  if (!window) {
    return;
  }
  host_->observed_window = window;
  base::WeakPtr<OpenBrowserWindow> weak = weak_ptr_factory_.GetWeakPtr();
  NSNotificationCenter* center = NSNotificationCenter.defaultCenter;
  host_->become_key_observer =
      [center addObserverForName:NSWindowDidBecomeKeyNotification
                          object:window
                           queue:nil
                      usingBlock:^(NSNotification*) {
                        if (weak) {
                          weak->OnHostWindowKeyChanged(true);
                        }
                      }];
  host_->resign_key_observer =
      [center addObserverForName:NSWindowDidResignKeyNotification
                          object:window
                           queue:nil
                      usingBlock:^(NSNotification*) {
                        if (weak) {
                          weak->OnHostWindowKeyChanged(false);
                        }
                      }];
  if (window.isKeyWindow) {
    OnHostWindowKeyChanged(true);
  }
}

void OpenBrowserWindow::OnHostWindowKeyChanged(bool key) {
  if (!CanActivateBrowser()) {
    return;
  }
  // The most recently activated Browser is chrome.windows' "current" and
  // "focused" window.
  if (key) {
    if (RefuseUnsafeActivationForAutomation(browser_)) {
      return;
    }
    BrowserActiveStateManager::From(browser_)->DidBecomeActive();
  } else {
    BrowserActiveStateManager::From(browser_)->DidBecomeInactive();
  }
}

bool OpenBrowserWindow::CanActivateBrowser() const {
  return !closing_ && IsRegisteredBrowser(browser_);
}

void OpenBrowserWindow::OnBrowserClosing() {
  closing_ = true;
  host_->StopObserving();
}

void OpenBrowserWindow::Show() {
  if (!CanActivateBrowser()) {
    return;
  }
  [host_->window() makeKeyAndOrderFront:nil];
}

void OpenBrowserWindow::ShowInactive() {
  [host_->window() orderFront:nil];
}

void OpenBrowserWindow::Hide() {}

bool OpenBrowserWindow::IsVisible() const {
  NSWindow* window = host_->window();
  return window && window.isVisible;
}

void OpenBrowserWindow::SetBounds(const gfx::Rect& bounds) {
  // chrome.windows.update with left/top/width/height.
  pending_bounds_ = bounds;
  [host_->window() setFrame:gfx::ScreenRectToNSRect(bounds) display:YES];
  if (auto* strip = OpenTabStrip::FromBrowser(browser_)) strip->RequestFrame(bounds, IsActive());
}

void OpenBrowserWindow::Close() {
  // Browser::TabStripEmpty() calls this when the last tab is gone, and
  // UnloadController::OnWindowClosing() closes remaining tabs first, then
  // calls back here. The Browser closes and is deleted asynchronously; the
  // tab strip makes a new one for its next tab. Mirrors
  // BrowserWidget::OnNativeWidgetDestroyed().
  if (!browser_) {
    return;
  }
  // Anything else that closes a window with tabs (chrome.windows.remove)
  // only asks: the embedder owns the tabs. OpenTabStrip::Close and app
  // shutdown close for real.
  OpenTabStrip* strip = OpenTabStrip::FromBrowser(browser_);
  if (strip && !strip->closing() && !browser_->tab_strip_model()->empty() &&
      !browser_shutdown::HasShutdownStarted() &&
      !browser_shutdown::IsTryingToQuit()) {
    strip->RequestClose();
    return;
  }
  // A refused embedder close request above must keep observing. A real
  // close must detach now: popup teardown can make the host key before
  // Chromium deletes the Browser on a later turn.
  OnBrowserClosing();
  UnloadController::From(browser_)->set_force_skip_warning_user_on_close(true);
  UnloadController::From(browser_)->OnWindowClosing();
}

void OpenBrowserWindow::Activate() {
  if (!CanActivateBrowser()) {
    return;
  }
  if (auto* strip = OpenTabStrip::FromBrowser(browser_)) strip->RequestFrame(GetBounds(), true);
  NSWindow* window = host_->window();
  if (!window) {
    return;
  }
  [NSApp activate];
  [window makeKeyAndOrderFront:nil];
}

void OpenBrowserWindow::Deactivate() {}

bool OpenBrowserWindow::IsActive() const {
  NSWindow* window = host_->window();
  return !closing_ && window && window.isKeyWindow;
}

ui::ZOrderLevel OpenBrowserWindow::GetZOrderLevel() const {
  return ui::ZOrderLevel::kNormal;
}

gfx::NativeWindow OpenBrowserWindow::GetNativeWindow() const {
  return gfx::NativeWindow(host_->window());
}

bool OpenBrowserWindow::IsOnCurrentWorkspace() const {
  NSWindow* window = host_->window();
  return !window || window.isOnActiveSpace;
}

bool OpenBrowserWindow::IsVisibleOnScreen() const {
  NSWindow* window = host_->window();
  return window && window.isVisible &&
         (window.occlusionState & NSWindowOcclusionStateVisible);
}

gfx::Rect OpenBrowserWindow::GetRestoredBounds() const {
  return GetBounds();
}

ui::mojom::WindowShowState OpenBrowserWindow::GetRestoredState() const {
  return ui::mojom::WindowShowState::kNormal;
}

gfx::Rect OpenBrowserWindow::GetBounds() const {
  NSWindow* window = host_->window();
  return window ? gfx::ScreenRectFromNSRect(window.frame) : pending_bounds_;
}

bool OpenBrowserWindow::IsMaximized() const {
  NSWindow* window = host_->window();
  return window && window.isZoomed;
}

bool OpenBrowserWindow::IsMinimized() const {
  NSWindow* window = host_->window();
  return window && window.isMiniaturized;
}

void OpenBrowserWindow::Maximize() {
  NSWindow* window = host_->window();
  if (window && !window.isZoomed) {
    [window zoom:nil];
  }
}

void OpenBrowserWindow::Minimize() {
  [host_->window() miniaturize:nil];
}

void OpenBrowserWindow::Restore() {
  NSWindow* window = host_->window();
  if (window.isMiniaturized) {
    [window deminiaturize:nil];
  }
}

bool OpenBrowserWindow::IsFullscreen() const {
  NSWindow* window = host_->window();
  return html_fullscreen_ ||
         (window && (window.styleMask & NSWindowStyleMaskFullScreen));
}

bool OpenBrowserWindow::DoBrowserControlsShrinkRendererSize(
    const content::WebContents* contents) const {
  return false;
}

ui::NativeTheme* OpenBrowserWindow::GetNativeTheme() {
  return ui::NativeTheme::GetInstanceForNativeUi();
}

const ui::ThemeProvider* OpenBrowserWindow::GetThemeProvider() const {
  return nullptr;
}

const ui::ColorProvider* OpenBrowserWindow::GetColorProvider() const {
  return ui::ColorProviderManager::Get().GetColorProviderFor(
      ui::ColorProviderKey());
}

int OpenBrowserWindow::GetTopControlsHeight() const {
  return 0;
}

std::vector<StatusBubble*> OpenBrowserWindow::GetStatusBubbles() {
  return {};
}

gfx::Size OpenBrowserWindow::GetContentsSize() const {
  NSView* view = host_->view;
  return view ? gfx::Size(view.bounds.size.width, view.bounds.size.height)
              : gfx::Size();
}

bool OpenBrowserWindow::GetCanResize() {
  return true;
}

ui::mojom::WindowShowState OpenBrowserWindow::GetWindowShowState() const {
  if (IsMinimized()) {
    return ui::mojom::WindowShowState::kMinimized;
  }
  if (IsFullscreen()) {
    return ui::mojom::WindowShowState::kFullscreen;
  }
  if (IsMaximized()) {
    return ui::mojom::WindowShowState::kMaximized;
  }
  return ui::mojom::WindowShowState::kNormal;
}

LocationBar* OpenBrowserWindow::GetLocationBar() const {
  return location_bar_.get();
}

ui::AcceleratorProvider* OpenBrowserWindow::GetAcceleratorProvider() {
  return nullptr;
}

PinnedToolbarActions* OpenBrowserWindow::GetPinnedToolbarActions() {
  return nullptr;
}

autofill::AutofillBubbleHandler* OpenBrowserWindow::GetAutofillBubbleHandler() {
  // Same as WebUIBrowserWindow: no autofill bubbles without Views.
  return nullptr;
}

bool OpenBrowserWindow::UpdateToolbarSecurityState() {
  return false;
}

content::KeyboardEventProcessingResult
OpenBrowserWindow::PreHandleKeyboardEvent(
    const input::NativeWebKeyboardEvent& event) {
  return content::KeyboardEventProcessingResult::NOT_HANDLED;
}

bool OpenBrowserWindow::HandleKeyboardEvent(
    const input::NativeWebKeyboardEvent& event) {
  // A key the page and the tab's CEF client left unhandled: give the main
  // menu a chance, as CefBrowserPlatformDelegateNativeMac does for Alloy.
  NSEvent* ns_event = event.os_event.Get();
  if (ns_event.type == NSEventTypeKeyDown) {
    return [[NSApp mainMenu] performKeyEquivalent:ns_event];
  }
  return false;
}

bool OpenBrowserWindow::IsTabStripEditable() const {
  return true;
}

bool OpenBrowserWindow::IsToolbarVisible() const {
  // The embedder draws the window's extension actions (fork patch P2), so
  // chrome.action.openPopup has a toolbar to open from. Other readers need a
  // BrowserView as well (iOS promo).
  return true;
}

bool OpenBrowserWindow::IsLocationBarVisible() const {
  return false;
}

bool OpenBrowserWindow::IsToolbarShowing() const {
  return false;
}

bool OpenBrowserWindow::IsUnframedModeEnabled() const {
  return false;
}

BrowserView* OpenBrowserWindow::AsBrowserView() {
  return nullptr;
}

ShowTranslateBubbleResult OpenBrowserWindow::ShowTranslateBubble(
    content::WebContents* contents,
    translate::TranslateStep step,
    const std::string& source_language,
    const std::string& target_language,
    translate::TranslateErrors error_type,
    bool is_user_gesture) {
  return ShowTranslateBubbleResult::kBrowserWindowNotValid;
}

DownloadBubbleUIController* OpenBrowserWindow::GetDownloadBubbleUIController() {
  return nullptr;
}

void OpenBrowserWindow::ConfirmBrowserCloseWithPendingDownloads(
    int download_count,
    DownloadCloseType dialog_type,
    base::OnceCallback<void(bool)> callback) {
  // The embedder owns downloads UI; never block a close on them.
  std::move(callback).Run(true);
}

std::unique_ptr<FindBar> OpenBrowserWindow::CreateFindBar() {
  return std::make_unique<HiddenFindBar>();
}

web_modal::WebContentsModalDialogHost*
OpenBrowserWindow::GetWebContentsModalDialogHost() {
  if (!dialog_host_) {
    dialog_host_ = std::make_unique<HiddenDialogHost>();
  }
  return dialog_host_.get();
}

web_modal::WebContentsModalDialogHost*
OpenBrowserWindow::GetWebContentsModalDialogHostFor(
    content::WebContents* web_contents) {
  return GetWebContentsModalDialogHost();
}

ExclusiveAccessContext* OpenBrowserWindow::GetExclusiveAccessContext() {
  return this;
}

std::string OpenBrowserWindow::GetWorkspace() const {
  return std::string();
}

bool OpenBrowserWindow::IsVisibleOnAllWorkspaces() const {
  return false;
}

std::unique_ptr<content::EyeDropper> OpenBrowserWindow::OpenEyeDropper(
    content::RenderFrameHost* frame,
    content::EyeDropperListener* listener) {
  return nullptr;
}

Profile* OpenBrowserWindow::GetProfile() {
  return profile_;
}

void OpenBrowserWindow::EnterFullscreen(
    const url::Origin& origin,
    ExclusiveAccessBubbleType bubble_type,
    FullscreenTabParams fullscreen_tab_params) {
  // The tab's CEF client hears about HTML fullscreen through
  // CefDisplayHandler::OnFullscreenModeChange and decides how to show it.
  html_fullscreen_ = true;
  NotifyFullscreenStateChanged();
}

void OpenBrowserWindow::ExitFullscreen() {
  html_fullscreen_ = false;
  NotifyFullscreenStateChanged();
}

void OpenBrowserWindow::NotifyFullscreenStateChanged() {
  // FullscreenController waits for the window to report the transition, as
  // a real window does when its state changes. Report it on the next turn.
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce(
                     [](base::WeakPtr<OpenBrowserWindow> window) {
                       if (window && window->browser_) {
                         ExclusiveAccessManager::From(window->browser_)
                             ->fullscreen_controller()
                             ->WindowFullscreenStateChanged();
                       }
                     },
                     weak_ptr_factory_.GetWeakPtr()));
}

bool OpenBrowserWindow::IsExclusiveAccessBubbleDisplayed() const {
  return false;
}

content::WebContents* OpenBrowserWindow::GetWebContentsForExclusiveAccess() {
  return browser_ ? browser_->tab_strip_model()->GetActiveWebContents()
                  : nullptr;
}

bool OpenBrowserWindow::CanUserEnterFullscreen() const {
  return true;
}

bool OpenBrowserWindow::CanUserExitFullscreen() const {
  return true;
}

void OpenBrowserWindow::DeleteBrowserWindow() {
  delete this;
}

}  // namespace open_engine

CefRefPtr<CefDictionaryValue> CefGetOpenBrowserActivationDiagnostics(bool reset) {
  CEF_REQUIRE_UIT_RETURN(nullptr);
  if (!base::CommandLine::ForCurrentProcess()->HasSwitch("open-automation")) {
    return nullptr;
  }
  if (reset) {
    open_engine::g_invalid_activation_requests = 0;
  }
  auto state = CefDictionaryValue::Create();
  state->SetInt("invalidActivationRequests",
                open_engine::g_invalid_activation_requests);
  auto* active = GlobalBrowserCollection::GetInstance()->GetActiveBrowser();
  state->SetInt("activeChromeWindowID", active ? active->GetSessionID().id() : -1);
  return state;
}
