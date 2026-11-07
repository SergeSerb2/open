// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "open/browser/tab_strip/open_tab_strip.h"

#include <algorithm>

#include "base/containers/flat_map.h"
#include "base/functional/bind.h"
#include "base/logging.h"
#include "base/no_destructor.h"
#include "cef/libcef/browser/browser_context.h"
#include "cef/libcef/browser/browser_host_base.h"
#include "cef/libcef/browser/chrome/browser_util.h"
#include "cef/libcef/browser/chrome/chrome_browser_host_impl.h"
#include "cef/libcef/browser/context.h"
#include "cef/libcef/browser/request_context_impl.h"
#include "cef/libcef/browser/thread_util.h"
#include "cef/libcef/common/net/url_util.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/tab_list/tab_removed_reason.h"
#include "chrome/browser/tab_contents/tab_util.h"
#include "chrome/browser/ui/browser.h"
#include "chrome/browser/ui/browser_window/public/create_browser_window.h"
#include "chrome/browser/ui/browser_window/public/global_browser_collection.h"
#include "chrome/browser/ui/tabs/tab_enums.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"
#include "components/sessions/content/session_tab_helper.h"
#include "chrome/browser/ui/tabs/tab_model.h"
#include "components/tabs/public/tab_interface.h"
#include "content/public/browser/navigation_controller.h"
#include "content/public/browser/web_contents.h"
#include "extensions/browser/extension_action.h"
#include "extensions/browser/extension_action_manager.h"
#include "extensions/browser/extension_registry.h"
#include "open/browser/extensions/open_extensions_toolbar.h"
#include "open/browser/extensions/open_extension_window_hooks.h"
#include "open/browser/tab_strip/hidden_browser.h"
#include "open/browser/tab_strip/tab_groups.h"
#include "open/browser/tab_strip/open_browser_window.h"
#include "open/browser/tab_strip/open_hosted_platform_delegate.h"

namespace open_engine {

namespace {

base::flat_map<int, OpenTabStrip*>& Strips() {
  static base::NoDestructor<base::flat_map<int, OpenTabStrip*>> strips;
  return *strips;
}

int g_next_strip_id = 1;

}  // namespace

OpenTabStrip::OpenTabStrip(CefRefPtr<CefRequestContextImpl> request_context,
                           CefRefPtr<CefTabStripHandler> handler)
    : id_(g_next_strip_id++),
      request_context_(request_context),
      handler_(handler) {
  Strips()[id_] = this;
  GetExtensionWindowHooks().create = &OpenTabStrip::CreateExtensionWindow;
}

BrowserWindowInterface* OpenTabStrip::CreateExtensionWindow(Profile* profile,
    bool popup, const gfx::Rect& frame, const std::string& extension_id,
    const std::vector<GURL>& urls, bool focused) {
  OpenTabStrip* parent = nullptr;
  // Prefer the last active standard Open window, even while its extension
  // popup is key. Window selection intentionally follows activation history.
  GlobalBrowserCollection::GetInstance()->ForEach([&](BrowserWindowInterface* browser) {
    auto* candidate = FromBrowser(browser);
    if (!candidate || candidate->closed_ || candidate->extension_window_ ||
        candidate->GetProfile() != profile || !candidate->handler_) return true;
    parent = candidate;
    return false;
  }, BrowserCollection::Order::kActivation);
  if (!parent) return nullptr;
  CefRefPtr<OpenTabStrip> strip = parent;
  if (popup) {
    strip = new OpenTabStrip(parent->request_context_, parent->handler_);
    strip->extension_window_ = true;
    if (!strip->EnsureBrowser()) return nullptr;
    gfx::Rect initial = frame;
    if (initial.IsEmpty()) {
      initial = parent->window_->GetBounds();
      initial.ClampToCenteredSize(gfx::Size(400, 600));
    }
    strip->window_->SetInitialBounds(initial);
    // Establish only the new bridge/handler. The public open event follows
    // OnTabCreated, outside this API call and all TabStripModel observers.
    parent->handler_->OnExtensionWindowCreated(parent, strip,
        CefRect(frame.x(), frame.y(), frame.width(), frame.height()), extension_id);
  }
  const std::vector<GURL> blank{GURL("about:blank")};
  for (const auto& url : urls.empty() ? blank : urls) {
    CefRefPtr<CefClient> client;
    CefBrowserSettings settings;
    CefRefPtr<CefDictionaryValue> extra;
    strip->handler_->OnBeforeTabCreated(strip, url.spec(), client, settings, extra);
    auto browser = strip->CreateTab(client, url.spec(), settings, extra, -1, false);
    auto* contents = strip->ContentsFor(browser);
    if (contents) strip->PostRequest(Request::kCreated, contents,
        strip->browser_->tab_strip_model()->GetIndexOfWebContents(contents), true);
    else if (popup) strip->RequestClose();
  }
  if (popup) strip->RequestFrame(gfx::Rect(), focused);
  else if (focused) strip->window_->Show();
  return strip->browser_;
}

void OpenTabStrip::RequestFrame(const gfx::Rect& frame, bool focused) {
  if (!extension_window_ || closed_ || !handler_) return;
  CEF_POST_TASK(CEF_UIT, base::BindOnce([](base::WeakPtr<OpenTabStrip> self,
      gfx::Rect frame, bool focused) {
    if (self && !self->closed_ && self->handler_) self->handler_->OnExtensionWindowFrameRequested(
        self.get(), CefRect(frame.x(), frame.y(), frame.width(), frame.height()), focused);
  }, weak_ptr_factory_.GetWeakPtr(), frame, focused));
}

OpenTabStrip::~OpenTabStrip() {
  // No handler calls from here on: a call passes `this` as a
  // CefRefPtr<CefTabStrip>, which would take a reference to an object whose
  // count is already zero and delete it a second time (the toolbar closes an
  // open popup and would report it).
  handler_ = nullptr;
  toolbar_.reset();
  Strips().erase(id_);
  if (browser_) {
    browser_->tab_strip_model()->RemoveObserver(this);
  }
}

// static
OpenTabStrip* OpenTabStrip::FromId(int id) {
  auto it = Strips().find(id);
  return it == Strips().end() ? nullptr : it->second;
}

// static
OpenTabStrip* OpenTabStrip::FromBrowser(const BrowserWindowInterface* browser) {
  if (!browser) {
    return nullptr;
  }
  for (const auto& [id, strip] : Strips()) {
    if (strip->browser_ && strip->browser_.get() == browser) {
      return strip;
    }
  }
  return nullptr;
}

// static
OpenTabStrip* OpenTabStrip::FromContents(
    const content::WebContents* contents) {
  if (!contents) {
    return nullptr;
  }
  for (const auto& [id, strip] : Strips()) {
    if (strip->browser_ &&
        strip->browser_->tab_strip_model()->GetIndexOfWebContents(contents) !=
            TabStripModel::kNoTab) {
      return strip;
    }
  }
  return nullptr;
}

// static
int OpenTabStrip::IdForHost(const CefBrowserHostBase* host) {
  if (!host || !host->platform_delegate()) {
    return 0;
  }
  return OpenHostedPlatformDelegate::StripIdFor(host->platform_delegate());
}

// static
std::unique_ptr<CefBrowserPlatformDelegate>
OpenTabStrip::MaybeCreatePlatformDelegate(
    const CefBrowserCreateParams& params,
    std::unique_ptr<CefBrowserPlatformDelegateNative>& native_delegate) {
  if (!params.open_tab_strip_id || !FromId(params.open_tab_strip_id)) {
    return nullptr;
  }
  return std::make_unique<OpenHostedPlatformDelegate>(
      std::move(native_delegate), params.open_tab_strip_id);
}

void OpenTabStrip::GetCreateParamsForNewTab(content::WebContents* contents,
                                            CefBrowserCreateParams& params) {
  params.open_tab_strip_id = id_;
  if (pending_tab_ && pending_tab_->contents == contents) {
    // CreateTab: the embedder already chose the client.
    params.client = pending_tab_->client;
    params.settings = pending_tab_->settings;
    params.extra_info = pending_tab_->extra_info;
    pending_tab_.reset();
    return;
  }
  // Chromium creates this tab on its own: ask the embedder for a client.
  CefRefPtr<CefClient> client;
  CefBrowserSettings settings;
  CefRefPtr<CefDictionaryValue> extra_info;
  if (handler_) {
    handler_->OnBeforeTabCreated(this, CefString(), client, settings,
                                 extra_info);
  }
  params.client = client;
  params.settings = settings;
  params.extra_info = extra_info;
}

bool OpenTabStrip::AddPopupContents(
    std::unique_ptr<content::WebContents>& contents) {
  Browser* browser = EnsureBrowser();
  if (!browser) {
    return false;
  }
  // The embedder already knows this page from OnBeforePopup; it places the
  // tab with UpdateTab.
  ++applying_;
  browser->tab_strip_model()->AddWebContents(
      std::move(contents), TabStripModel::kNoTab, ui::PAGE_TRANSITION_LINK,
      AddTabTypes::ADD_NONE);
  --applying_;
  return true;
}

bool OpenTabStrip::RequestDiscard(content::WebContents* contents) {
  if (!handler_ || closed_) {
    return false;
  }
  auto host = ChromeBrowserHostImpl::GetBrowserForContents(contents);
  return host && IdForHost(host.get()) == id_ &&
         handler_->OnTabDiscardRequested(this, host.get());
}

void OpenTabStrip::RequestClose() {
  if (!handler_ || closed_) {
    return;
  }
  CEF_POST_TASK(CEF_UIT, base::BindOnce(&OpenTabStrip::DeliverCloseRequest,
                                        weak_ptr_factory_.GetWeakPtr()));
}

void OpenTabStrip::DeliverCloseRequest() {
  if (handler_ && !closed_) {
    handler_->OnCloseRequested(this);
  }
}

bool OpenTabStrip::IsValid() {
  return !closed_;
}

int OpenTabStrip::GetWindowId() {
  CEF_REQUIRE_UIT_RETURN(-1);
  return browser_ ? browser_->GetSessionID().id() : -1;
}

void OpenTabStrip::SetHostView(CefWindowHandle view) {
  CEF_REQUIRE_UIT_RETURN_VOID();
  host_view_ = view;
  if (window_) {
    window_->SetHostView(view);
  }
}

CefRefPtr<CefBrowser> OpenTabStrip::CreateTab(
    CefRefPtr<CefClient> client,
    const CefString& url,
    const CefBrowserSettings& settings,
    CefRefPtr<CefDictionaryValue> extra_info,
    int index,
    bool pinned) {
  CEF_REQUIRE_UIT_RETURN(nullptr);
  Browser* browser = EnsureBrowser();
  if (!browser) {
    return nullptr;
  }
  GURL gurl = url_util::MakeGURL(url, /*fixup=*/true);
  if (gurl.is_empty()) {
    // As ChromeBrowserHostImpl::Create: do not load the new tab page.
    gurl = GURL("chrome://ignore/");
  }
  TabStripModel* model = browser->tab_strip_model();
  if (index < 0 || index > model->count()) {
    index = model->count();
  }
  // Insert the page into this strip's Browser directly. Navigate() would
  // send some URLs elsewhere: an off-the-record profile opens
  // chrome://settings and similar pages in a window of the original profile
  // (browser_navigator.cc, AdjustNavigateParamsForURL).
  // CefBrowserSettings.no_renderer (fork patch 0105, tab sleeping): no
  // renderer process and no navigation until the embedder restores the tab's
  // history (CefRestoreNavigationHistory) and shows it, as Chrome creates
  // restored tabs (browser_tabrestore.cc). |url| is not loaded.
  const bool no_renderer = settings.no_renderer != 0;
  content::WebContents::CreateParams create_params(browser->GetProfile());
  if (!no_renderer) {
    create_params.site_instance =
        tab_util::GetSiteInstanceForNewTab(browser->GetProfile(), gurl);
  } else {
    create_params.desired_renderer_state =
        content::WebContents::CreateParams::kNoRendererProcess;
  }
  create_params.initially_hidden = true;
  std::unique_ptr<content::WebContents> owned =
      content::WebContents::Create(create_params);
  content::WebContents* contents = owned.get();
  pending_tab_ = PendingTab{contents, client, settings, extra_info};
  ++applying_;
  model->AddWebContents(
      std::move(owned), index, ui::PAGE_TRANSITION_TYPED,
      pinned ? AddTabTypes::ADD_PINNED : AddTabTypes::ADD_NONE);
  --applying_;
  pending_tab_.reset();
  auto host = ChromeBrowserHostImpl::GetBrowserForContents(contents);
  if (model->GetIndexOfWebContents(contents) == TabStripModel::kNoTab ||
      !host || IdForHost(host.get()) != id_) {
    LOG(ERROR) << "Open: a new tab did not land in its own tab strip";
    return nullptr;
  }
  if (no_renderer) {
    return host.get();
  }
  content::NavigationController::LoadURLParams load_params(gurl);
  load_params.transition_type = ui::PAGE_TRANSITION_TYPED;
  contents->GetController().LoadURLWithParams(load_params);
  return host.get();
}

void OpenTabStrip::UpdateTab(CefRefPtr<CefBrowser> browser,
                             int index,
                             bool pinned) {
  CEF_REQUIRE_UIT_RETURN_VOID();
  content::WebContents* contents = ContentsFor(browser);
  if (!browser_ || !contents) {
    return;
  }
  TabStripModel* model = browser_->tab_strip_model();
  int from = model->GetIndexOfWebContents(contents);
  if (from == TabStripModel::kNoTab) {
    return;
  }
  ++applying_;
  if (model->IsTabPinned(from) != pinned) {
    from = model->SetTabPinned(from, pinned);
  }
  // Pinned tabs come first; keep |index| inside the tab's own section.
  const int first_unpinned = model->IndexOfFirstNonPinnedTab();
  const int low = pinned ? 0 : first_unpinned;
  const int high = pinned ? first_unpinned - 1 : model->count() - 1;
  const int to = std::clamp(index, low, std::max(low, high));
  if (to != from) {
    model->MoveWebContentsAt(from, to, /*select_after_move=*/false);
  }
  --applying_;
}

void OpenTabStrip::ActivateTab(CefRefPtr<CefBrowser> browser) {
  CEF_REQUIRE_UIT_RETURN_VOID();
  content::WebContents* contents = ContentsFor(browser);
  if (!browser_ || !contents) {
    return;
  }
  TabStripModel* model = browser_->tab_strip_model();
  const int index = model->GetIndexOfWebContents(contents);
  if (index == TabStripModel::kNoTab || index == model->active_index()) {
    return;
  }
  ++applying_;
  model->ActivateTabAt(index);
  --applying_;
}

int OpenTabStrip::GetTabId(CefRefPtr<CefBrowser> browser) {
  CEF_REQUIRE_UIT_RETURN(-1);
  content::WebContents* contents = ContentsFor(browser);
  return contents ? sessions::SessionTabHelper::IdForTab(contents).id() : -1;
}

int OpenTabStrip::GetTabCount() {
  CEF_REQUIRE_UIT_RETURN(0);
  return browser_ ? browser_->tab_strip_model()->count() : 0;
}

CefRefPtr<CefBrowser> OpenTabStrip::GetTabAt(int index) {
  CEF_REQUIRE_UIT_RETURN(nullptr);
  if (!browser_ || index < 0 || index >= browser_->tab_strip_model()->count()) {
    return nullptr;
  }
  return ChromeBrowserHostImpl::GetBrowserForContents(
             browser_->tab_strip_model()->GetWebContentsAt(index))
      .get();
}

int OpenTabStrip::GetActiveIndex() {
  CEF_REQUIRE_UIT_RETURN(-1);
  return browser_ ? browser_->tab_strip_model()->active_index() : -1;
}

extensions::ExtensionAction* OpenTabStrip::ActionFor(
    const CefString& extension_id,
    int* tab_id) {
  Profile* profile = CefRequestContextImpl::GetProfile(request_context_);
  if (!profile) {
    return nullptr;
  }
  const extensions::Extension* extension =
      extensions::ExtensionRegistry::Get(profile)
          ->enabled_extensions()
          .GetByID(extension_id.ToString());
  if (!extension) {
    return nullptr;
  }
  content::WebContents* active =
      browser_ ? browser_->tab_strip_model()->GetActiveWebContents() : nullptr;
  *tab_id = active ? sessions::SessionTabHelper::IdForTab(active).id()
                   : extensions::ExtensionAction::kDefaultTabId;
  return extensions::ExtensionActionManager::Get(profile)->GetExtensionAction(
      *extension);
}

CefString OpenTabStrip::GetExtensionActionBadgeText(
    const CefString& extension_id) {
  CEF_REQUIRE_UIT_RETURN(CefString());
  int tab_id;
  auto* action = ActionFor(extension_id, &tab_id);
  return action ? action->GetDisplayBadgeText(tab_id) : std::string();
}

cef_color_t OpenTabStrip::GetExtensionActionBadgeColor(
    const CefString& extension_id) {
  CEF_REQUIRE_UIT_RETURN(0);
  int tab_id;
  auto* action = ActionFor(extension_id, &tab_id);
  return action ? action->GetBadgeBackgroundColor(tab_id) : 0;
}

CefString OpenTabStrip::GetExtensionActionTitle(
    const CefString& extension_id) {
  CEF_REQUIRE_UIT_RETURN(CefString());
  int tab_id;
  auto* action = ActionFor(extension_id, &tab_id);
  return action ? action->GetTitle(tab_id) : std::string();
}

bool OpenTabStrip::IsExtensionActionEnabled(const CefString& extension_id) {
  CEF_REQUIRE_UIT_RETURN(false);
  int tab_id;
  auto* action = ActionFor(extension_id, &tab_id);
  return action && action->GetIsVisible(tab_id);
}

CefRefPtr<CefRequestContextImpl> OpenTabStrip::request_context() const {
  return request_context_;
}

content::WebContents* OpenTabStrip::ActiveContents() const {
  return browser_ ? browser_->tab_strip_model()->GetActiveWebContents()
                  : nullptr;
}

bool OpenTabStrip::AreExtensionActionsReady() {
  CEF_REQUIRE_UIT_RETURN(false);
  return toolbar_ && toolbar_->IsReady();
}

Profile* OpenTabStrip::GetProfile() const {
  return browser_ ? browser_->GetProfile()
                  : CefRequestContextImpl::GetProfile(request_context_);
}

void OpenTabStrip::GetExtensionActionIds(
    std::vector<CefString>& extension_ids) {
  CEF_REQUIRE_UIT_RETURN_VOID();
  extension_ids.clear();
  const bool live = toolbar_ && toolbar_->IsReady();
  for (const auto& id : live ? toolbar_->ActionIds()
                             : OpenExtensionsToolbar::ProfileActionIds(
                                   closed_ ? nullptr : GetProfile())) {
    extension_ids.push_back(id);
  }
}

CefRefPtr<CefDictionaryValue> OpenTabStrip::GetExtensionActionState(
    const CefString& extension_id) {
  CEF_REQUIRE_UIT_RETURN(nullptr);
  if (toolbar_ && toolbar_->IsReady()) {
    return toolbar_->State(extension_id);
  }
  return closed_ ? nullptr
                 : OpenExtensionsToolbar::ProfileState(GetProfile(),
                                                       extension_id);
}

CefRefPtr<CefImage> OpenTabStrip::GetExtensionActionImage(
    const CefString& extension_id,
    int size,
    bool toolbar) {
  CEF_REQUIRE_UIT_RETURN(nullptr);
  if (toolbar_ && toolbar_->IsReady()) {
    return toolbar_->Image(extension_id, size, toolbar);
  }
  // Without the live model the toolbar image is the plain icon (no badge or
  // decorations).
  return closed_ ? nullptr
                 : OpenExtensionsToolbar::ProfileImage(GetProfile(),
                                                       extension_id, size);
}

void OpenTabStrip::SetExtensionActionPinned(const CefString& extension_id,
                                            bool pinned) {
  CEF_REQUIRE_UIT_RETURN_VOID();
  if (toolbar_) {
    toolbar_->SetPinned(extension_id, pinned);
  }
}

void OpenTabStrip::MoveExtensionAction(const CefString& extension_id,
                                       int pinned_index) {
  CEF_REQUIRE_UIT_RETURN_VOID();
  if (toolbar_) {
    toolbar_->MovePinned(extension_id, pinned_index);
  }
}

bool OpenTabStrip::ExecuteExtensionAction(const CefString& extension_id,
                                          int source) {
  CEF_REQUIRE_UIT_RETURN(false);
  return toolbar_ && toolbar_->Execute(extension_id, source);
}

void OpenTabStrip::CloseExtensionPopup() {
  CEF_REQUIRE_UIT_RETURN_VOID();
  if (toolbar_) {
    toolbar_->ClosePopup();
  }
}

bool OpenTabStrip::ExtensionPopupStaysOpenOnBlur() {
  CEF_REQUIRE_UIT_RETURN(false);
  return toolbar_ && toolbar_->PopupStaysOpenOnBlur();
}

CefRefPtr<CefListValue> OpenTabStrip::GetExtensionActionMenu(
    const CefString& extension_id,
    int source,
    int& menu_id) {
  menu_id = 0;
  CEF_REQUIRE_UIT_RETURN(nullptr);
  return toolbar_ && toolbar_->IsReady()
             ? toolbar_->Menu(extension_id, source, &menu_id)
             : nullptr;
}

bool OpenTabStrip::RunExtensionActionMenuCommand(int menu_id, int command_id) {
  CEF_REQUIRE_UIT_RETURN(false);
  return toolbar_ && toolbar_->RunMenuCommand(menu_id, command_id);
}

void OpenTabStrip::ReleaseExtensionActionMenu(int menu_id) {
  CEF_REQUIRE_UIT_RETURN_VOID();
  if (toolbar_) {
    toolbar_->ReleaseMenu(menu_id);
  }
}

void OpenTabStrip::Close() {
  CEF_REQUIRE_UIT_RETURN_VOID();
  if (closed_) {
    return;
  }
  closed_ = true;
  if (window_) {
    // Closes the remaining tabs, then the Browser (OnBrowserDidClose).
    window_->Close();
  }
}

void OpenTabStrip::OnTabStripModelChanged(
    TabStripModel* tab_strip_model,
    const TabStripModelChange& change,
    const TabStripSelectionChange& selection) {
  if (toolbar_ && !tab_strip_model->empty() &&
      selection.active_tab_changed()) {
    // Also for the embedder's own ActivateTab, as Chrome closes the popup
    // on any tab switch (ExtensionPopup::OnTabStripModelChanged).
    toolbar_->OnActiveTabChanged();
  }
  if (applying_ > 0 || closed_) {
    return;
  }
  switch (change.type()) {
    case TabStripModelChange::kInserted:
      // A tab that Chromium created (chrome.tabs.create, a welcome page).
      // Whether it is active is part of the creation request.
      for (const auto& inserted : change.GetInsert()->contents) {
        PostRequest(Request::kCreated, inserted.contents, inserted.index,
                    selection.new_contents == inserted.contents);
      }
      return;
    case TabStripModelChange::kMoved: {
      const TabStripModelChange::Move* move = change.GetMove();
      PostRequest(Request::kMove, move->contents, move->to_index, false);
      return;
    }
    case TabStripModelChange::kRemoved:
      // Closes reach the embedder through the tab's own CEF client. When the
      // active tab closes Chromium activates a neighbor; the embedder sets
      // the tab it wants with ActivateTab.
      for (const auto& removed : change.GetRemove()->contents) {
        if (removed.remove_reason !=
            TabRemovedReason::kInsertedIntoOtherTabStrip) {
          continue;
        }
        // A tab of this strip moved to another window. tabs_api.cc refuses
        // that for extensions (patch 0303); anything else is put back.
        auto host = ChromeBrowserHostImpl::GetBrowserForContents(
            removed.contents);
        if (host && IdForHost(host.get()) == id_) {
          LOG(ERROR) << "Open: a tab left its window; putting it back";
          CEF_POST_TASK(
              CEF_UIT,
              base::BindOnce(&OpenTabStrip::PutBack,
                             weak_ptr_factory_.GetWeakPtr(),
                             removed.contents->GetWeakPtr(), removed.index,
                             removed.tab && removed.tab->IsPinned()));
        }
      }
      return;
    case TabStripModelChange::kReplaced:
      // Only discards replace a tab's WebContents, and hosted tabs are never
      // discarded (IsHostedTab, patch 0303).
      LOG(ERROR) << "Open: a hosted tab's page was replaced";
      return;
    case TabStripModelChange::kSelectionOnly:
      break;
  }
  if (selection.active_tab_changed() && selection.new_contents) {
    PostRequest(Request::kActivate, selection.new_contents, -1, false);
  }
}

void OpenTabStrip::OnTabPinnedStateChanged(tabs::TabInterface* tab, int index) {
  if (applying_ > 0 || closed_ || !tab) {
    return;
  }
  PostRequest(Request::kPin, tab->GetContents(), index, tab->IsPinned());
}

Browser* OpenTabStrip::EnsureBrowser() {
  if (browser_) {
    return browser_;
  }
  if (closed_) {
    return nullptr;
  }
  Profile* profile = CefRequestContextImpl::GetProfile(request_context_);
  if (!profile || GetBrowserWindowCreationStatusForProfile(*profile) !=
                      BrowserWindowInterface::CreationStatus::kOk) {
    return nullptr;
  }

  BrowserWindowCreateParams chrome_params(extension_window_ ? BrowserWindowInterface::TYPE_POPUP : BrowserWindowInterface::TYPE_NORMAL,
                                          profile,
                                          /*from_user_gesture=*/false);
  // Open restores its own windows; Chrome's session service must not.
  chrome_params.omit_from_session_restore = true;
  chrome_params.should_trigger_session_restore = false;

  // The Browser's CEF params: tabs created in it are hosted tabs of this
  // strip (GetCreateParamsForNewTab sets their client).
  CefBrowserCreateParams cef_params;
  cef_params.request_context = request_context_.get();
  cef_params.open_tab_strip_id = id_;
  chrome_params.cef_params =
      base::MakeRefCounted<ChromeBrowserHostImpl::DelegateCreateParams>(
          cef_params);

  auto* window = new OpenBrowserWindow(profile);  // Owned by the Browser.
  chrome_params.window = window;
  window_ = window;

  browser_ = cef::BrowserForBWI(CreateBrowserWindow(std::move(chrome_params)));
  CHECK(browser_);
  window_->SetBrowser(browser_);
  window_->SetHostView(host_view_);
  browser_->tab_strip_model()->AddObserver(this);
  toolbar_ = std::make_unique<OpenExtensionsToolbar>(this, browser_);
  did_close_subscription_ =
      browser_->RegisterBrowserDidClose(base::BindRepeating(
          &OpenTabStrip::OnBrowserDidClose, weak_ptr_factory_.GetWeakPtr()));
  return browser_;
}

void OpenTabStrip::OnBrowserDidClose(BrowserWindowInterface* browser) {
  if (browser != browser_.get()) {
    return;
  }
  if (window_) {
    window_->OnBrowserClosing();
  }
  // Chrome deletes the Browser (and its window) on the next turn.
  const bool had_actions = toolbar_ && toolbar_->IsReady();
  toolbar_.reset();
  browser_->tab_strip_model()->RemoveObserver(this);
  did_close_subscription_ = {};
  browser_ = nullptr;
  window_ = nullptr;
  if (had_actions) {
    // The live model is gone: the embedder reads the profile's list now,
    // and drops the old live state (badges, popups).
    PostActionsChanged();
  }
}

void OpenTabStrip::PostActionsChanged() {
  CEF_POST_TASK(CEF_UIT, base::BindOnce(
                             [](base::WeakPtr<OpenTabStrip> self) {
                               if (self && self->handler_ && !self->closed_) {
                                 self->handler_->OnExtensionActionsChanged(
                                     CefRefPtr<CefTabStrip>(self.get()));
                               }
                             },
                             weak_ptr_factory_.GetWeakPtr()));
}

content::WebContents* OpenTabStrip::ContentsFor(
    CefRefPtr<CefBrowser> browser) const {
  auto host = CefBrowserHostBase::FromBrowser(browser);
  return host ? host->GetWebContents() : nullptr;
}

void OpenTabStrip::PostRequest(Request request,
                               content::WebContents* contents,
                               int index,
                               bool flag) {
  if (!handler_ || !contents) {
    return;
  }
  // Deliver after the TabStripModel notification unwinds: the embedder
  // answers with UpdateTab/ActivateTab, and TabStripModel is not re-entrant.
  base::WeakPtr<content::WebContents> previous, next;
  if (request == Request::kMove && browser_) {
    auto* model = browser_->tab_strip_model();
    if (index > 0 && index <= model->count())
      previous = model->GetWebContentsAt(index - 1)->GetWeakPtr();
    if (index >= 0 && index + 1 < model->count())
      next = model->GetWebContentsAt(index + 1)->GetWeakPtr();
  }
  CEF_POST_TASK(CEF_UIT, base::BindOnce(&OpenTabStrip::DeliverRequest,
                                        weak_ptr_factory_.GetWeakPtr(), request,
                                        contents->GetWeakPtr(), index, flag,
                                        previous, next));
}

void OpenTabStrip::DeliverRequest(Request request,
                                  base::WeakPtr<content::WebContents> contents,
                                  int index,
                                  bool flag,
                                  base::WeakPtr<content::WebContents> previous,
                                  base::WeakPtr<content::WebContents> next) {
  if (!handler_ || !contents || closed_) {
    return;
  }
  auto host = ChromeBrowserHostImpl::GetBrowserForContents(contents.get());
  if (!host) {
    return;
  }
  if (IdForHost(host.get()) != id_) {
    // A tab of another window (PutBack returns it there).
    return;
  }
  CefRefPtr<CefTabStrip> self(this);
  switch (request) {
    case Request::kCreated: {
      const int current =
          browser_ ? browser_->tab_strip_model()->GetIndexOfWebContents(
                         contents.get())
                   : index;
      handler_->OnTabCreated(self, host.get(), current, flag);
      break;
    }
    case Request::kActivate:
      handler_->OnTabActivateRequested(self, host.get());
      break;
    case Request::kMove:
      handler_->OnTabMoveRequested(self, host.get(), index,
          previous ? ChromeBrowserHostImpl::GetBrowserForContents(previous.get()) : nullptr,
          next ? ChromeBrowserHostImpl::GetBrowserForContents(next.get()) : nullptr);
      break;
    case Request::kPin:
      handler_->OnTabPinRequested(self, host.get(), flag);
      break;
  }
}

void OpenTabStrip::PutBack(base::WeakPtr<content::WebContents> contents,
                           int index,
                           bool pinned) {
  if (!contents || closed_) {
    return;
  }
  Browser* home = EnsureBrowser();
  if (!home || home->tab_strip_model()->GetIndexOfWebContents(
                   contents.get()) != TabStripModel::kNoTab) {
    return;
  }
  tabs::TabInterface* tab =
      tabs::TabInterface::MaybeGetFromContents(contents.get());
  BrowserWindowInterface* bwi = tab ? tab->GetBrowserWindowInterface() : nullptr;
  Browser* other = bwi ? cef::BrowserForBWI(bwi) : nullptr;
  if (!other) {
    return;
  }
  const int from = other->tab_strip_model()->GetIndexOfWebContents(
      contents.get());
  if (from == TabStripModel::kNoTab) {
    return;
  }
  std::unique_ptr<tabs::TabModel> detached =
      other->tab_strip_model()->DetachTabAtForInsertion(from);
  TabStripModel* model = home->tab_strip_model();
  ++applying_;
  model->InsertDetachedTabAt(
      std::clamp(index, 0, model->count()), std::move(detached),
      pinned ? AddTabTypes::ADD_PINNED : AddTabTypes::ADD_NONE);
  --applying_;
}

bool IsHiddenTabStripBrowser(const BrowserWindowInterface* browser) {
  return OpenTabStrip::FromBrowser(browser) != nullptr;
}

bool IsHostedTab(content::WebContents* contents) {
  return OpenTabStrip::FromContents(contents) != nullptr;
}

bool RequestHostedTabDiscard(content::WebContents* contents) {
  OpenTabStrip* strip = OpenTabStrip::FromContents(contents);
  return strip && strip->RequestDiscard(contents);
}

bool SupportsTabGroups(const cef::BrowserDelegate::CreateParams* cef_params) {
  // CEF passes only ChromeBrowserHostImpl::DelegateCreateParams here.
  return !cef_params ||
         !static_cast<const ChromeBrowserHostImpl::DelegateCreateParams*>(
              cef_params)
              ->create_params_.open_tab_strip_id;
}

}  // namespace open_engine

// static
CefRefPtr<CefTabStrip> CefTabStrip::Create(
    CefRefPtr<CefRequestContext> request_context,
    CefRefPtr<CefTabStripHandler> handler) {
  if (!CONTEXT_STATE_VALID()) {
    DCHECK(false) << "context not valid";
    return nullptr;
  }
  CEF_REQUIRE_UIT_RETURN(nullptr);
  if (!request_context) {
    request_context = CefRequestContext::GetGlobalContext();
  }
  CefRefPtr<CefRequestContextImpl> impl(
      static_cast<CefRequestContextImpl*>(request_context.get()));
  if (!impl->VerifyBrowserContext()) {
    return nullptr;
  }
  // Backstop. A context with a disk path whose Chrome profile CEF could not
  // create falls back to a unique off-the-record profile of the default
  // profile (ChromeBrowserContext::ProfileCreated). Extensions of the default
  // profile allowed in incognito could see such tabs, so these contexts get
  // no tab strip; their pages stay Alloy. OEEngine already refuses a folder
  // that is not a direct child of root_cache_path, so this fires only if CEF
  // fails for another reason. Ephemeral contexts (no disk path) are Open's
  // incognito windows and keep their tab strip.
  Profile* profile = CefRequestContextImpl::GetProfile(impl.get());
  CefBrowserContext* browser_context = impl->GetBrowserContext();
  if (profile && profile->IsOffTheRecord() && !profile->IsPrimaryOTRProfile() &&
      browser_context && !browser_context->cache_path().empty()) {
    LOG(ERROR) << "Open: no tab strip for "
               << browser_context->cache_path().value()
               << " (Chromium kept it in memory, not on disk)";
    return nullptr;
  }
  return new open_engine::OpenTabStrip(impl, handler);
}
