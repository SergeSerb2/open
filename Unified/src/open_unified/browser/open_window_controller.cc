// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "open_unified/browser/open_window_controller.h"

#include <algorithm>
#include <utility>

#include "base/functional/bind.h"
#include "base/strings/string_util.h"
#include "base/strings/utf_string_conversions.h"
#include "base/task/sequenced_task_runner.h"
#include "base/time/time.h"
#include "chrome/browser/content_settings/host_content_settings_map_factory.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/views/frame/browser_view.h"
#include "components/content_settings/core/browser/host_content_settings_map.h"
#include "components/content_settings/core/common/content_settings.h"
#include "components/content_settings/core/common/content_settings_types.h"
#include "components/favicon/content/content_favicon_driver.h"
#include "components/find_in_page/find_notification_details.h"
#include "components/find_in_page/find_types.h"
#include "components/input/native_web_keyboard_event.h"
#include "components/javascript_dialogs/tab_modal_dialog_manager.h"
#include "components/web_modal/web_contents_modal_dialog_manager.h"
#include "content/public/browser/browser_context.h"
#include "content/public/browser/navigation_controller.h"
#include "content/public/browser/navigation_handle.h"
#include "content/public/browser/render_widget_host_view.h"
#include "content/public/browser/web_contents.h"
#include "open_unified/browser/open_boost_controller.h"
#include "open_unified/browser/open_browser_service.h"
#include "open_unified/browser/open_chromium_hooks.h"
#include "open_unified/browser/open_model_util.h"
#include "open_unified/browser/platform/open_platform.h"
#include "open_unified/core/adblock/open_adblock_profile_service.h"
#include "open_unified/core/commands/command_registry.h"
#include "open_unified/core/routing/routing_evaluator.h"
#include "open_unified/core/store/sqlite_stores.h"
#include "open_unified/core/suggest/suggest_engine.h"
#include "open_unified/ui/webui/open_ipc_contract.h"
#include "open_unified/ui/webui/open_settings_ui.h"
#include "open_unified/ui/webui/open_webui_config.h"
#include "third_party/skia/include/core/SkColor.h"
#include "ui/base/accelerators/accelerator_manager.h"
#include "ui/base/clipboard/scoped_clipboard_writer.h"
#include "ui/display/display.h"
#include "ui/display/screen.h"
#include "ui/events/event.h"
#include "ui/events/keycodes/keyboard_codes.h"
#include "ui/native_theme/native_theme.h"
#include "ui/views/controls/webview/webview.h"
#include "ui/views/event_monitor.h"
#include "ui/views/focus/focus_manager.h"
#include "ui/views/widget/widget.h"
#include "url/gurl.h"
#include "url/origin.h"

namespace open_unified {

namespace {

constexpr char kDefaultSearchTemplate[] = "https://www.google.com/search?q=%s";

SkColor ToSkColor(const RGBAColor& c) {
  return SkColorSetARGB(static_cast<U8CPU>(c.a * 255.0 + 0.5),
                        static_cast<U8CPU>(c.r * 255.0 + 0.5),
                        static_cast<U8CPU>(c.g * 255.0 + 0.5),
                        static_cast<U8CPU>(c.b * 255.0 + 0.5));
}

SuggestMode ToSuggestMode(CommandBarMode mode) {
  switch (mode) {
    case CommandBarMode::kEditCurrentUrl:
      return SuggestMode::kEditCurrentUrl;
    case CommandBarMode::kSearchActions:
      return SuggestMode::kSearchActions;
    case CommandBarMode::kSearchTabs:
      return SuggestMode::kSearchTabs;
    case CommandBarMode::kNewTab:
    case CommandBarMode::kLittleOpen:
      return SuggestMode::kNewTab;
  }
  return SuggestMode::kNewTab;
}

SuggestScope ToSuggestScope(CommandBarScope scope, const std::string& site) {
  switch (scope) {
    case CommandBarScope::kActions:
      return SuggestScope::Actions();
    case CommandBarScope::kTabs:
      return SuggestScope::Tabs();
    case CommandBarScope::kSiteSearch:
      return SuggestScope::SiteSearch(site);
    case CommandBarScope::kNone:
      return SuggestScope::All();
  }
  return SuggestScope::All();
}

CommandBarRowKind ToRowKind(SuggestionKind kind) {
  switch (kind) {
    case SuggestionKind::kNavigate:
      return CommandBarRowKind::kNavigate;
    case SuggestionKind::kSearch:
      return CommandBarRowKind::kSearch;
    case SuggestionKind::kSwitchToTab:
      return CommandBarRowKind::kSwitchToTab;
    case SuggestionKind::kHistory:
      return CommandBarRowKind::kHistory;
    case SuggestionKind::kCalculator:
      return CommandBarRowKind::kCalculator;
    case SuggestionKind::kAction:
      return CommandBarRowKind::kAction;
    case SuggestionKind::kSiteSearch:
    case SuggestionKind::kSiteSearchHint:
      return CommandBarRowKind::kSiteSearch;
  }
  return CommandBarRowKind::kNavigate;
}

std::string_view RowKindName(CommandBarRowKind kind) {
  switch (kind) {
    case CommandBarRowKind::kNavigate:
      return "navigate";
    case CommandBarRowKind::kHistory:
      return "history";
    case CommandBarRowKind::kSwitchToTab:
      return "switchToTab";
    case CommandBarRowKind::kSwitchToSplit:
      return "switchToSplit";
    case CommandBarRowKind::kSearch:
      return "search";
    case CommandBarRowKind::kSearchSuggestion:
      return "searchSuggestion";
    case CommandBarRowKind::kAction:
      return "action";
    case CommandBarRowKind::kCalculator:
      return "calculator";
    case CommandBarRowKind::kSiteSearch:
      return "siteSearch";
    case CommandBarRowKind::kCurrentPage:
      return "currentPage";
  }
  return "navigate";
}

ContentSettingsType ToContentSettingsType(SitePermissionKind kind) {
  switch (kind) {
    case SitePermissionKind::kCamera:
      return ContentSettingsType::MEDIASTREAM_CAMERA;
    case SitePermissionKind::kMicrophone:
      return ContentSettingsType::MEDIASTREAM_MIC;
    case SitePermissionKind::kLocation:
      return ContentSettingsType::GEOLOCATION;
    case SitePermissionKind::kNotifications:
      return ContentSettingsType::NOTIFICATIONS;
    case SitePermissionKind::kPopups:
      return ContentSettingsType::POPUPS;
  }
  return ContentSettingsType::POPUPS;
}

SitePermissionSetting ToPermissionSetting(ContentSetting setting) {
  switch (setting) {
    case CONTENT_SETTING_ALLOW:
      return SitePermissionSetting::kAllow;
    case CONTENT_SETTING_BLOCK:
      return SitePermissionSetting::kBlock;
    default:
      return SitePermissionSetting::kAsk;
  }
}

// Open commands bound as window accelerators (their CommandRegistry
// shortcuts, user overrides included), registered at high priority so they
// win over Chromium's accelerator table and, through
// BrowserView::PreHandleKeyboardEvent, over the page. Navigation (Back,
// Forward, Reload), zoom, Print and the like keep Chromium's own handling.
constexpr CommandId kWindowAcceleratorCommands[] = {
    CommandId::kNewTab,
    CommandId::kOpenCommandBar,
    CommandId::kToggleSidebar,
    CommandId::kArchiveTab,
    CommandId::kCopyUrl,
    CommandId::kPinUnpinTab,
    CommandId::kAddSplitView,
    CommandId::kCloseSplitPane,
    CommandId::kNextSpace,
    CommandId::kPreviousSpace,
    CommandId::kNextTab,
    CommandId::kPreviousTab,
    CommandId::kViewLibrary,
    CommandId::kViewHistory,
    CommandId::kViewArchive,
    CommandId::kViewDownloads,
    CommandId::kSettings,
    CommandId::kFind,
    CommandId::kFindNext,
    CommandId::kFindPrevious,
    CommandId::kTabSwitcherForward,
    CommandId::kTabSwitcherBackward,
    CommandId::kNewLittleOpenWindow,
    CommandId::kGoToTab1,
    CommandId::kGoToTab2,
    CommandId::kGoToTab3,
    CommandId::kGoToTab4,
    CommandId::kGoToTab5,
    CommandId::kGoToTab6,
    CommandId::kGoToTab7,
    CommandId::kGoToTab8,
    CommandId::kGoToTab9,
    CommandId::kGoToSpace1,
    CommandId::kGoToSpace2,
    CommandId::kGoToSpace3,
    CommandId::kGoToSpace4,
    CommandId::kGoToSpace5,
    CommandId::kGoToSpace6,
    CommandId::kGoToSpace7,
    CommandId::kGoToSpace8,
    CommandId::kGoToSpace9,
};

// Index 0..8 of a Go to Tab / Go to Space command, or -1.
int GoToTabIndex(CommandId command) {
  const int n = static_cast<int>(command) - static_cast<int>(CommandId::kGoToTab1);
  return n >= 0 && n < 9 ? n : -1;
}
int GoToSpaceIndex(CommandId command) {
  const int n =
      static_cast<int>(command) - static_cast<int>(CommandId::kGoToSpace1);
  return n >= 0 && n < 9 ? n : -1;
}

// Seeds longer than this are cut (docs/re/page-chrome.md §1).
constexpr size_t kFindSeedMaxLength = 40;
// MRU entries kept per window, and HUD items offered.
constexpr size_t kMruLimit = 64;
constexpr size_t kSwitcherItemLimit = 32;

// CommandRegistry key tokens ("f", "tab", "left", "f12", "[") -> VKEY.
ui::KeyboardCode KeyCodeForToken(std::string_view token) {
  if (token.size() == 1) {
    const char c = token[0];
    if (c >= 'a' && c <= 'z') {
      return static_cast<ui::KeyboardCode>(ui::VKEY_A + (c - 'a'));
    }
    if (c >= '0' && c <= '9') {
      return static_cast<ui::KeyboardCode>(ui::VKEY_0 + (c - '0'));
    }
    switch (c) {
      case '[':
        return ui::VKEY_OEM_4;
      case ']':
        return ui::VKEY_OEM_6;
      case ',':
        return ui::VKEY_OEM_COMMA;
      case '.':
        return ui::VKEY_OEM_PERIOD;
      case '/':
        return ui::VKEY_OEM_2;
      case '-':
        return ui::VKEY_OEM_MINUS;
      case '=':
        return ui::VKEY_OEM_PLUS;
      case ';':
        return ui::VKEY_OEM_1;
      case '\'':
        return ui::VKEY_OEM_7;
      case '\\':
        return ui::VKEY_OEM_5;
      case '`':
        return ui::VKEY_OEM_3;
      default:
        return ui::VKEY_UNKNOWN;
    }
  }
  static constexpr struct {
    std::string_view name;
    ui::KeyboardCode code;
  } kNamed[] = {
      {"tab", ui::VKEY_TAB},         {"escape", ui::VKEY_ESCAPE},
      {"esc", ui::VKEY_ESCAPE},      {"return", ui::VKEY_RETURN},
      {"enter", ui::VKEY_RETURN},    {"space", ui::VKEY_SPACE},
      {"left", ui::VKEY_LEFT},       {"right", ui::VKEY_RIGHT},
      {"up", ui::VKEY_UP},           {"down", ui::VKEY_DOWN},
      {"delete", ui::VKEY_DELETE},   {"backspace", ui::VKEY_BACK},
      {"home", ui::VKEY_HOME},       {"end", ui::VKEY_END},
      {"pageup", ui::VKEY_PRIOR},    {"pagedown", ui::VKEY_NEXT},
  };
  for (const auto& named : kNamed) {
    if (named.name == token) {
      return named.code;
    }
  }
  if (token.size() >= 2 && token.size() <= 3 && token[0] == 'f') {
    int n = 0;
    for (char c : token.substr(1)) {
      if (c < '0' || c > '9') {
        return ui::VKEY_UNKNOWN;
      }
      n = n * 10 + (c - '0');
    }
    if (n >= 1 && n <= 24) {
      return static_cast<ui::KeyboardCode>(ui::VKEY_F1 + (n - 1));
    }
  }
  return ui::VKEY_UNKNOWN;
}

std::optional<ui::Accelerator> ToAccelerator(const KeyboardShortcut& shortcut) {
  const ui::KeyboardCode code =
      KeyCodeForToken(base::ToLowerASCII(shortcut.key));
  if (code == ui::VKEY_UNKNOWN) {
    return std::nullopt;
  }
  int flags = ui::EF_NONE;
  if (shortcut.modifiers & kModCtrl) {
    flags |= ui::EF_CONTROL_DOWN;
  }
  if (shortcut.modifiers & kModAlt) {
    flags |= ui::EF_ALT_DOWN;
  }
  if (shortcut.modifiers & kModShift) {
    flags |= ui::EF_SHIFT_DOWN;
  }
  if (shortcut.modifiers & kModMeta) {
    flags |= ui::EF_COMMAND_DOWN;
  }
  return ui::Accelerator(code, flags);
}

std::string HostWithoutWww(const GURL& url) {
  std::string host(url.host());
  if (base::StartsWith(host, "www.")) {
    host.erase(0, 4);
  }
  return host;
}

// Emoji icons are drawn as leading text; symbol icons have no text form.
std::u16string IconText(const std::optional<SpaceIcon>& icon) {
  return icon && icon->kind == SpaceIconKind::kEmoji
             ? base::UTF8ToUTF16(icon->value)
             : std::u16string();
}

std::u16string SpaceTitle(const Space& space) {
  return base::UTF8ToUTF16(space.title.value_or("Space"));
}

// One Command Bar query through Track 2's SuggestEngine (main window bar and
// Little Open's bar).
CommandBarResults QueryCommandBar(OpenBrowserService* s,
                                  const CommandBarQuery& query,
                                  const ProfileID& profile_id,
                                  const std::optional<SpaceID>& space_id,
                                  const std::optional<ItemID>& current_tab) {
  SuggestContext context;
  context.mode = ToSuggestMode(query.mode);
  context.scope = ToSuggestScope(query.scope, query.site_search_id);
  context.profile_id = profile_id;
  context.space_id = space_id;
  if (current_tab) {
    context.current_tab_id = *current_tab;
    if (const Tab* tab = s->model().FindTab(*current_tab)) {
      context.current_tab_url = tab->url;
    }
  }
  if (const Profile* profile = s->model().FindProfile(profile_id)) {
    context.search_engine_id = profile->settings.search_engine_id;
  }
  context.allows_inline_completion = query.allows_inline_completion;
  context.max_results = command_bar_metrics::kMaxRows;

  const SuggestionResult result =
      s->suggest().Query(base::UTF16ToUTF8(query.text), context);
  CommandBarResults results;
  for (const Suggestion& suggestion : result.suggestions) {
    if (suggestion.kind == SuggestionKind::kSiteSearchHint) {
      CommandBarScopeTarget hint;
      hint.scope = CommandBarScope::kSiteSearch;
      hint.site_search_id = suggestion.site_search_id.value_or(std::string());
      hint.title = base::UTF8ToUTF16(suggestion.title);
      results.site_search_hint = hint;
      continue;
    }
    CommandBarRow row;
    row.id = suggestion.id;
    row.kind = ToRowKind(suggestion.kind);
    row.title = base::UTF8ToUTF16(suggestion.title);
    row.subtitle = base::UTF8ToUTF16(suggestion.subtitle);
    row.url = suggestion.url.value_or(std::string());
    row.tab_id = suggestion.tab_id;
    row.space_id = suggestion.space_id;
    row.action_id = suggestion.action_id.value_or(std::string());
    if (suggestion.kind == SuggestionKind::kSwitchToTab) {
      if (suggestion.tab_location == TabLocation::kSplitPane) {
        row.kind = CommandBarRowKind::kSwitchToSplit;
        row.badge = u"Switch to Split View";
      } else {
        row.badge = suggestion.space_title
                        ? base::UTF8ToUTF16(*suggestion.space_title)
                        : u"Switch to Tab";
      }
    }
    if (!suggestion.shortcut_display.empty()) {
      row.keycaps.push_back(base::UTF8ToUTF16(suggestion.shortcut_display));
    }
    results.rows.push_back(std::move(row));
  }
  if (result.inline_completion) {
    results.inline_completion =
        base::UTF8ToUTF16(result.inline_completion->field_text);
  }
  return results;
}

std::optional<CommandBarScopeTarget> ResolveSiteSearchFor(
    OpenBrowserService* s,
    const ProfileID& profile_id,
    std::u16string_view text,
    bool exact_keyword_only) {
  const std::string typed = base::UTF16ToUTF8(text);
  std::optional<SiteSearchEntry> entry =
      s->suggest().TriggerSiteSearch(typed, profile_id);
  if (!entry) {
    return std::nullopt;
  }
  const std::string lower = base::ToLowerASCII(typed);
  const bool exact =
      base::ToLowerASCII(entry->name) == lower ||
      std::any_of(entry->keywords.begin(), entry->keywords.end(),
                  [&](const std::string& k) {
                    return base::ToLowerASCII(k) == lower;
                  });
  if (exact_keyword_only && !exact) {
    return std::nullopt;
  }
  CommandBarScopeTarget target;
  target.scope = CommandBarScope::kSiteSearch;
  target.site_search_id = entry->id;
  target.title = base::UTF8ToUTF16(entry->name);
  target.exact_keyword = exact;
  return target;
}

// The page a navigate/search/history row (or bare typed text) opens.
GURL UrlForCommandBarIntent(const CommandBarIntent& intent) {
  GURL url(intent.row.url);
  if (url.is_valid()) {
    return url;
  }
  // Typed text: a URL when it looks like one, else a search.
  const std::string typed = base::UTF16ToUTF8(intent.typed_text);
  if (std::optional<std::string> classified =
          SuggestEngine::ClassifyTypedUrl(typed)) {
    return GURL(*classified);
  }
  if (!typed.empty()) {
    return GURL(
        SuggestEngine::FillSearchUrlTemplate(kDefaultSearchTemplate, typed));
  }
  return GURL();
}

// Pages Open shows outside the tab strip (Peek, Little Open) get the full
// tab helper set through hook 0010 (TabHelpers::AttachTabHelpers(): find in
// page, JavaScript dialogs, permission prompts, autofill, ...), plus Open's
// ad-block counter. Sidebar tabs get the same set through TabStripModel.
void AttachOverlayPageHelpers(content::WebContents* contents) {
  hooks::AttachTabHelpers(contents);
  find_in_page::FindTabHelper::CreateForWebContents(contents);
  OpenAdBlockProfileService::EnsureTabHelper(contents);
}

base::ListValue RectToList(const gfx::Rect& r) {
  return base::ListValue()
      .Append(r.x())
      .Append(r.y())
      .Append(r.width())
      .Append(r.height());
}

}  // namespace

// ===========================================================================
// OpenWindowController
// ===========================================================================

OpenWindowController::OpenWindowController(OpenBrowserService* service)
    : service_(service) {}

OpenWindowController::~OpenWindowController() {
  Shutdown();
}

void OpenWindowController::Start() {
  if (started_) {
    return;
  }
  started_ = true;
  service_->model().AddObserver(this);
  service_->tab_bridge()->AddObserver(this);
  for (OpenExtensionBridge* extensions : service_->AllExtensionBridges()) {
    ObserveExtensionBridge(extensions);
  }
  // Chromium's startup Browser got its OpenBrowserView before the bridges
  // existed (hook 0002 runs between PreBrowserStart and PostBrowserStart).
  for (auto& [browser_view, ui] : windows_) {
    ui->UpdatePanel();
  }
  NotifyWindowStateChanged();
}

void OpenWindowController::Shutdown() {
  if (!started_) {
    return;
  }
  started_ = false;
  little_opens_.clear();
  windows_.clear();
  service_->model().RemoveObserver(this);
  if (OpenTabBridge* bridge = service_->tab_bridge()) {
    bridge->RemoveObserver(this);
  }
  extension_observations_.RemoveAllObservations();
}

void OpenWindowController::ObserveExtensionBridge(OpenExtensionBridge* bridge) {
  if (bridge && !extension_observations_.IsObservingSource(bridge)) {
    extension_observations_.AddObservation(bridge);
  }
}

void OpenWindowController::UnobserveExtensionBridge(
    OpenExtensionBridge* bridge) {
  if (bridge && extension_observations_.IsObservingSource(bridge)) {
    extension_observations_.RemoveObservation(bridge);
  }
}

void OpenWindowController::NotifyPeekChanged(const WindowID& window_id) {
  for (OpenViewObserver& observer : view_observers_) {
    observer.OnPeekChanged(window_id);
  }
}

void OpenWindowController::NotifyCommandBarStateChanged(
    const WindowID& window_id) {
  for (OpenViewObserver& observer : view_observers_) {
    observer.OnCommandBarStateChanged(window_id);
  }
}

void OpenWindowController::OnBrowserViewInstalled(BrowserView* browser_view) {
  OpenBrowserView* open_view = OpenBrowserView::FromBrowserView(browser_view);
  if (!open_view) {
    return;
  }
  windows_[browser_view] = std::make_unique<OpenWindowUi>(
      this, browser_view, open_view, open_view->window_id());
}

void OpenWindowController::OnBrowserViewDestroying(BrowserView* browser_view) {
  windows_.erase(browser_view);
}

OpenWindowUi* OpenWindowController::MainWindowUi() {
  const WindowID main = service_->MainWindowId();
  for (auto& [browser_view, ui] : windows_) {
    if (ui->window_id() == main && browser_view->GetWidget() &&
        browser_view->GetWidget()->IsVisible()) {
      return ui.get();
    }
  }
  return windows_.empty() ? nullptr : windows_.begin()->second.get();
}

OpenWindowUi* OpenWindowController::WindowUiFor(const WindowID& window_id) {
  return const_cast<OpenWindowUi*>(WindowUiForConst(window_id));
}

const OpenWindowUi* OpenWindowController::WindowUiForConst(
    const WindowID& window_id) const {
  // Several Browsers (one per Profile) can show one Open window; the
  // visible one is the window's current page.
  const OpenWindowUi* fallback = nullptr;
  for (const auto& [browser_view, ui] : windows_) {
    if (ui->window_id() != window_id) {
      continue;
    }
    if (browser_view->GetWidget() && browser_view->GetWidget()->IsVisible()) {
      return ui.get();
    }
    fallback = fallback ? fallback : ui.get();
  }
  return fallback;
}

OpenWindowUi* OpenWindowController::WindowUiForBrowserView(
    BrowserView* browser_view) {
  auto it = windows_.find(browser_view);
  return it == windows_.end() ? nullptr : it->second.get();
}

OpenLittleOpenController* OpenWindowController::OpenLittleOpen(
    const std::optional<GURL>& url,
    const ProfileID& profile_id,
    std::optional<SpaceID> target_space) {
  if (!started_) {
    return nullptr;
  }
  const ProfileID profile =
      profile_id.empty() ? service_->ActiveProfileId() : profile_id;
  if (profile.empty() || !service_->ChromeProfileFor(profile)) {
    return nullptr;
  }
  little_opens_.push_back(std::make_unique<OpenLittleOpenController>(
      this, profile, std::move(target_space)));
  OpenLittleOpenController* little_open = little_opens_.back().get();
  if (!little_open->Show(url)) {
    little_opens_.pop_back();
    return nullptr;
  }
  return little_open;
}

void OpenWindowController::RouteExternalUrl(
    const GURL& url,
    std::optional<std::string> source_app_id) {
  OpenTabBridge* bridge = service_->tab_bridge();
  if (!started_ || !bridge || !url.is_valid()) {
    return;
  }
  RoutingRequest request;
  request.url = url.spec();
  request.source_app_id = std::move(source_app_id);
  request.received_at = base::Time::Now().InSecondsFSinceUnixEpoch();
  // Settings > Links "Open external links in Little Open" (default on).
  const base::Value little_open_pref =
      webui::OpenPreferences::Get()->GetValue("links.externalLinksLittleOpen");
  const RoutingDecision decision = service_->routing().Evaluate(
      request, service_->model(),
      little_open_pref.is_bool() ? little_open_pref.GetBool() : true);
  if (decision.via == RoutingVia::kRejectedNonHttp) {
    return;
  }
  if (decision.resolved &&
      decision.resolved->kind == RoutingDestinationKind::kLittleOpen) {
    OpenLittleOpen(url, decision.resolved->profile_id.value_or(ProfileID()),
                   decision.resolved->space_id);
    return;
  }
  if (decision.resolved && decision.resolved->space_id) {
    bridge->FocusSpace(*decision.resolved->space_id);
  }
  bridge->OpenTab(url, /*background=*/false);
  if (OpenWindowUi* ui = MainWindowUi()) {
    ui->ActivateWindow();
  }
}

void OpenWindowController::OnLittleOpenClosed(
    OpenLittleOpenController* little_open) {
  std::erase_if(little_opens_,
                [little_open](const std::unique_ptr<OpenLittleOpenController>&
                                  entry) { return entry.get() == little_open; });
}

void OpenWindowController::ReloadShortcuts() {
  for (auto& [browser_view, ui] : windows_) {
    ui->RegisterAccelerators();
  }
}

void OpenWindowController::OnTabsArchivedByUser(
    std::vector<ArchivedTabRecord> records) {
  OpenWindowUi* ui = MainWindowUi();
  if (!ui || records.empty()) {
    return;
  }
  ui->ShowToast(ToastSpec::TabArchived(
      base::BindOnce(&OpenWindowController::RestoreArchived,
                     weak_factory_.GetWeakPtr(), std::move(records))));
}

void OpenWindowController::RestoreArchived(
    std::vector<ArchivedTabRecord> records) {
  for (const ArchivedTabRecord& record : records) {
    ProfileServices* services = service_->ProfileServicesFor(
        record.profile_id.value_or(service_->ActiveProfileId()));
    if (!services) {
      continue;
    }
    // Restore() removes the row; a row Library already restored is gone,
    // so the tab is not put back twice.
    RunOnStore(services->archive,
               base::BindOnce(
                   [](ItemID id, ArchiveStore* store) {
                     return store->Restore(id);
                   },
                   record.id),
               base::BindOnce(
                   [](base::WeakPtr<OpenWindowController> self,
                      std::optional<ArchivedTabRecord> stored) {
                     if (!self || !stored || !self->service_->tab_bridge()) {
                       return;
                     }
                     const ItemID restored =
                         self->service_->model().RestoreArchivedTab(*stored);
                     if (!restored.empty()) {
                       self->service_->tab_bridge()->SelectNode(restored);
                     }
                   },
                   weak_factory_.GetWeakPtr()));
  }
}

content::WebContents* OpenWindowController::ActiveWebContents() const {
  OpenTabBridge* bridge = service_->tab_bridge();
  return bridge ? bridge->ActiveWebContents() : nullptr;
}

content::WebContents* OpenWindowController::ActiveWebContentsFor(
    const WindowID& window_id) const {
  if (const OpenWindowUi* ui = WindowUiForConst(window_id)) {
    return ui->ActiveWebContents();
  }
  return ActiveWebContents();
}

// --- Reads ----------------------------------------------------------------

const BrowserWindowState* OpenWindowController::GetWindowState(
    const WindowID& window_id) const {
  return service_->model().FindWindow(window_id);
}

std::vector<SpaceID> OpenWindowController::GetWindowSpaceIds(
    const WindowID& window_id) const {
  // Every Space, in model order (Arc's switcher spans Profiles).
  std::vector<SpaceID> ids;
  for (const Space& space : service_->model().spaces()) {
    ids.push_back(space.id);
  }
  return ids;
}

const Space* OpenWindowController::GetSpace(const SpaceID& space_id) const {
  return service_->model().FindSpace(space_id);
}

const Profile* OpenWindowController::GetProfile(
    const ProfileID& profile_id) const {
  return service_->model().FindProfile(profile_id);
}

const SidebarNode* OpenWindowController::FindNode(
    const ItemID& node_id) const {
  return service_->model().FindNode(node_id);
}

const Tab* OpenWindowController::GetActiveTab(
    const WindowID& window_id) const {
  std::optional<ItemID> id =
      OpenTabBridge::TabIdForWebContents(ActiveWebContentsFor(window_id));
  return id ? service_->model().FindTab(*id) : nullptr;
}

bool OpenWindowController::IsSplitViewActive(const WindowID& window_id) const {
  const BrowserModel& model = service_->model();
  const BrowserWindowState* window = model.FindWindow(window_id);
  if (!window) {
    return false;
  }
  std::optional<ItemID> selected =
      model.SelectedNodeId(window->focused_space_id, window_id);
  return selected && model.FindSplit(*selected) != nullptr;
}

bool OpenWindowController::IsSystemDarkMode() const {
  return ui::NativeTheme::GetInstanceForNativeUi()->preferred_color_scheme() ==
         ui::NativeTheme::PreferredColorScheme::kDark;
}

WindowID OpenWindowController::WindowIdForBrowserView(
    BrowserView* browser_view) {
  OpenTabBridge* bridge = service_->tab_bridge();
  if (bridge && browser_view) {
    if (std::optional<WindowID> id =
            bridge->WindowIdForBrowser(browser_view->browser())) {
      return *id;
    }
  }
  return service_->MainWindowId();
}

bool OpenWindowController::IsIncognitoWindow(const WindowID& window_id) const {
  OpenTabBridge* bridge = service_->tab_bridge();
  BrowserWindowInterface* browser = bridge ? bridge->MainBrowser() : nullptr;
  return browser && browser->GetProfile()->IsOffTheRecord();
}

std::optional<ItemID> OpenWindowController::GetPeekSourceNode(
    const WindowID& window_id) const {
  for (const auto& [browser_view, ui] : windows_) {
    if (ui->window_id() == window_id && ui->peek_shown()) {
      return ui->peek_source();
    }
  }
  return std::nullopt;
}

bool OpenWindowController::IsNewTabCommandBarOpen(
    const WindowID& window_id) const {
  for (const auto& [browser_view, ui] : windows_) {
    if (ui->window_id() == window_id && ui->command_bar_shown()) {
      return true;
    }
  }
  return false;
}

std::vector<OpenToolbarActionInfo>
OpenWindowController::GetPinnedToolbarActions(
    const WindowID& window_id) const {
  std::vector<OpenToolbarActionInfo> actions;
  OpenExtensionBridge* extensions = service_->extension_bridge();
  if (!extensions) {
    return actions;
  }
  for (const ExtensionActionInfo& info : extensions->ListActions()) {
    if (!info.pinned) {
      continue;
    }
    OpenToolbarActionInfo action;
    action.id = info.id;
    action.tooltip = base::UTF8ToUTF16(info.title);
    action.has_badge = !info.badge_text.empty();
    actions.push_back(std::move(action));
  }
  return actions;
}

// --- Intents -----------------------------------------------------------------

void OpenWindowController::NavigateActive(const WindowID& window_id,
                                          int direction) {
  content::WebContents* contents = ActiveWebContentsFor(window_id);
  if (!contents) {
    return;
  }
  content::NavigationController& controller = contents->GetController();
  if (direction < 0 && controller.CanGoBack()) {
    controller.GoBack();
  } else if (direction > 0 && controller.CanGoForward()) {
    controller.GoForward();
  } else if (direction == 0) {
    controller.Reload(content::ReloadType::NORMAL, /*check_for_repost=*/true);
  }
}

void OpenWindowController::HandleIntent(const WindowID& window_id,
                                        const OpenIntent& intent) {
  BrowserModel& model = service_->model();
  OpenTabBridge* bridge = service_->tab_bridge();
  if (!bridge) {
    return;  // Before OpenBrowserService::Start(); views are read-only.
  }
  OpenWindowUi* ui = WindowUiFor(window_id);
  const BrowserWindowState* window = model.FindWindow(window_id);
  const SpaceID focused = window ? window->focused_space_id : SpaceID();

  switch (intent.kind) {
    // --- Window and toolbar ---
    case OpenIntentKind::kToggleSidebar:
      if (window) {
        model.SetSidebarMode(window_id,
                             window->sidebar_mode == SidebarMode::kHidden
                                 ? SidebarMode::kAnchored
                                 : SidebarMode::kHidden);
      }
      break;
    case OpenIntentKind::kSidebarHiddenByGesture:
      model.SetSidebarMode(window_id, SidebarMode::kHidden,
                           /*register_undo=*/false);
      break;
    case OpenIntentKind::kSetSidebarWidth:
      model.SetSidebarWidth(window_id, intent.value);
      break;
    case OpenIntentKind::kGoBack:
      NavigateActive(window_id, -1);
      break;
    case OpenIntentKind::kGoForward:
      NavigateActive(window_id, +1);
      break;
    case OpenIntentKind::kReload:
      NavigateActive(window_id, 0);
      break;
    case OpenIntentKind::kStopLoading:
      if (content::WebContents* contents = ActiveWebContentsFor(window_id)) {
        contents->Stop();
      }
      break;
    case OpenIntentKind::kShowToolbarMore:
      break;  // The view shows the menu from CreateMenuModel().
    case OpenIntentKind::kOpenCommandBar:
      if (ui) {
        const bool edit =
            intent.command_bar_source == CommandBarSource::kUrlField;
        const Tab* active = GetActiveTab(window_id);
        ui->ShowCommandBar(
            edit ? CommandBarMode::kEditCurrentUrl : CommandBarMode::kNewTab,
            edit && active ? base::UTF8ToUTF16(active->url) : std::u16string(),
            intent.anchor_in_screen);
      }
      break;
    case OpenIntentKind::kCopyCurrentUrl:
      if (content::WebContents* contents = ActiveWebContentsFor(window_id)) {
        ui::ScopedClipboardWriter(ui::ClipboardBuffer::kCopyPaste)
            .WriteText(
                base::UTF8ToUTF16(contents->GetLastCommittedURL().spec()));
        if (ui) {
          ui->ShowToast(ToastSpec::CopiedUrl());
        }
      }
      break;
    case OpenIntentKind::kShowSiteControls:
      if (ui) {
        ui->ShowSiteControls(nullptr);
      }
      break;
    case OpenIntentKind::kRunToolbarAction:
      if (OpenExtensionBridge* extensions = service_->extension_bridge()) {
        extensions->ExecuteAction(intent.text, nullptr, base::DoNothing());
      }
      break;

    // --- Spaces, Library, creation ---
    case OpenIntentKind::kSelectNode:
      bridge->SelectNode(intent.secondary_id.empty() ? intent.node_id
                                                     : intent.secondary_id);
      break;
    case OpenIntentKind::kSelectFavorite:
      bridge->SelectNode(intent.node_id);
      break;
    case OpenIntentKind::kSwitchSpace:
      bridge->FocusSpace(intent.space_id);
      break;
    case OpenIntentKind::kShowLibrary:
      bridge->OpenTab(GURL(webui::OpenWebUIURL(webui::kHostLibrary)),
                      /*background=*/false);
      break;
    case OpenIntentKind::kNewSpace: {
      const SpaceID space = model.CreateSpace(service_->ActiveProfileId());
      if (!space.empty()) {
        bridge->FocusSpace(space);
      }
      break;
    }
    case OpenIntentKind::kNewFolder:
      model.CreateFolder(intent.parent.owner_id.empty()
                             ? NodeParent{NodeParentKind::kSpaceToday, focused}
                             : intent.parent);
      break;
    case OpenIntentKind::kNewEasel:
      bridge->OpenTab(GURL(webui::OpenWebUIURL(webui::kHostEasel)),
                      /*background=*/false);
      break;
    case OpenIntentKind::kNewNote:
      bridge->OpenTab(GURL(webui::OpenWebUIURL(webui::kHostNote)),
                      /*background=*/false);
      break;
    case OpenIntentKind::kSetPinnedCollapsed:
      model.SetPinnedCollapsed(intent.space_id, intent.flag);
      break;
    case OpenIntentKind::kClearToday:
      model.ClearToday(intent.space_id);
      break;
    case OpenIntentKind::kRenameSpace:
      model.UpdateSpace(intent.space_id, intent.text);
      break;
    case OpenIntentKind::kEditSpaceTheme:
    case OpenIntentKind::kChangeSpaceIcon:
      // The Space editor lives in open://library (Spaces section).
      bridge->OpenTab(GURL(webui::OpenWebUIURL(webui::kHostLibrary,
                                               "spaces/" + intent.space_id)),
                      /*background=*/false);
      break;

    // --- Rows ---
    case OpenIntentKind::kClose:
      bridge->CloseNode(intent.node_id);
      break;
    case OpenIntentKind::kUnloadTab:
      bridge->UnloadTab(intent.node_id);
      break;
    case OpenIntentKind::kUnloadFolder:
      if (const Folder* folder = model.FindFolder(intent.node_id)) {
        std::vector<ItemID> tabs;
        for (const SidebarNode& child : folder->children) {
          if (const Tab* tab = child.as_tab()) {
            tabs.push_back(tab->id);
          }
        }
        for (const ItemID& id : tabs) {
          bridge->UnloadTab(id);
        }
      }
      break;
    case OpenIntentKind::kToggleMute:
      if (const Tab* tab = model.FindTab(intent.node_id)) {
        const bool muted = !tab->is_muted;
        model.SetMuted(intent.node_id, muted);
        if (content::WebContents* contents =
                bridge->WebContentsForTab(intent.node_id)) {
          contents->SetAudioMuted(muted);
        }
      }
      break;
    case OpenIntentKind::kResetToPinnedUrl:
      if (model.ResetPinnedTab(intent.node_id)) {
        if (const Tab* tab = model.FindTab(intent.node_id);
            tab && bridge->WebContentsForTab(intent.node_id)) {
          bridge->Navigate(intent.node_id, GURL(tab->url));
        }
      }
      break;
    case OpenIntentKind::kRename:
      model.RenameNode(intent.node_id, intent.text);
      break;
    case OpenIntentKind::kSetFolderExpanded:
      model.SetFolderExpanded(intent.node_id, intent.flag);
      break;
    case OpenIntentKind::kMove:
      model.MoveNode(intent.node_id, intent.parent, intent.index);
      break;
    case OpenIntentKind::kAddFavorite:
      model.AddFavorite(intent.node_id, service_->ActiveProfileId(),
                        intent.index);
      break;
    case OpenIntentKind::kMoveFavorite:
      model.MoveNode(intent.node_id,
                     NodeParent{NodeParentKind::kFavorites,
                                service_->ActiveProfileId()},
                     intent.index);
      break;
    case OpenIntentKind::kRemoveFavorite:
      model.RemoveFavorite(intent.node_id);
      break;
    case OpenIntentKind::kOpenUrl: {
      const GURL url(intent.text);
      if (!url.is_valid()) {
        break;
      }
      const ItemID id = bridge->OpenTab(url, /*background=*/false);
      // Dropped links land where they were dropped.
      if (!id.empty() && !intent.parent.owner_id.empty()) {
        model.MoveNode(id, intent.parent, intent.index);
      }
      break;
    }
  }
}

void OpenWindowController::AddViewObserver(OpenViewObserver* observer) {
  view_observers_.AddObserver(observer);
}

void OpenWindowController::RemoveViewObserver(OpenViewObserver* observer) {
  view_observers_.RemoveObserver(observer);
}

// --- Notifications -----------------------------------------------------------

void OpenWindowController::NotifyWindowStateChanged() {
  for (const BrowserWindowState& window : service_->model().windows()) {
    for (OpenViewObserver& observer : view_observers_) {
      observer.OnWindowStateChanged(window.id);
      observer.OnActiveTabChanged(window.id);
    }
  }
}

void OpenWindowController::OnTreeChanged(const TreeChange& change) {
  for (OpenViewObserver& observer : view_observers_) {
    observer.OnTreeChanged(change);
  }
  switch (change.kind) {
    case TreeChange::Kind::kUpdate:
      if (!change.node_id.empty()) {
        for (OpenViewObserver& observer : view_observers_) {
          observer.OnTabLiveStateChanged(change.node_id);
        }
      }
      if (change.parent.kind == NodeParentKind::kFavorites) {
        for (OpenViewObserver& observer : view_observers_) {
          observer.OnFavoritesChanged(change.parent.owner_id);
        }
      }
      break;
    case TreeChange::Kind::kReload:
    case TreeChange::Kind::kSpaceProfileChanged:
      for (const BrowserWindowState& window : service_->model().windows()) {
        for (OpenViewObserver& observer : view_observers_) {
          observer.OnSpacesChanged(window.id);
        }
      }
      for (const Space& space : service_->model().spaces()) {
        for (OpenViewObserver& observer : view_observers_) {
          observer.OnSpaceThemeChanged(space.id);
        }
      }
      NotifyWindowStateChanged();
      break;
    case TreeChange::Kind::kInsert:
    case TreeChange::Kind::kRemove:
    case TreeChange::Kind::kMove:
      if (change.parent.kind == NodeParentKind::kFavorites ||
          change.to_parent.kind == NodeParentKind::kFavorites) {
        for (OpenViewObserver& observer : view_observers_) {
          observer.OnFavoritesChanged(change.parent.owner_id);
        }
      }
      // Splits are created and dissolved through tree changes.
      for (auto& [browser_view, ui] : windows_) {
        ui->UpdatePanel();
      }
      break;
  }
  // Space switches (Space Switched toast).
  for (auto& [browser_view, ui] : windows_) {
    ui->OnModelChanged();
  }
}

void OpenWindowController::OnTabActivated(const ItemID& tab_id) {
  // MRU order and the find session belong to the tab's window.
  OpenWindowUi* target = nullptr;
  if (OpenTabBridge* bridge = service_->tab_bridge()) {
    if (std::optional<WindowID> window =
            bridge->WindowIdForBrowser(bridge->BrowserForTab(tab_id))) {
      target = WindowUiFor(*window);
    }
  }
  if (!target) {
    target = MainWindowUi();
  }
  if (target) {
    target->OnTabActivated(tab_id);
  }
  NotifyWindowStateChanged();
  // After Chromium's own BrowserView handled the activation (it attaches
  // the active page to its contents view), re-present Split View.
  base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce(
                     [](base::WeakPtr<OpenWindowController> self) {
                       if (!self) {
                         return;
                       }
                       for (auto& [browser_view, ui] : self->windows_) {
                         ui->UpdatePanel();
                       }
                       for (const BrowserWindowState& window :
                            self->service_->model().windows()) {
                         for (OpenViewObserver& observer :
                              self->view_observers_) {
                           observer.OnSplitViewChanged(window.id);
                         }
                       }
                     },
                     weak_factory_.GetWeakPtr()));
}

void OpenWindowController::OnTabContentsAttached(
    const ItemID& tab_id,
    content::WebContents* contents) {
  for (OpenViewObserver& observer : view_observers_) {
    observer.OnTabLiveStateChanged(tab_id);
  }
}

void OpenWindowController::OnExtensionActionsChanged() {
  for (const BrowserWindowState& window : service_->model().windows()) {
    for (OpenViewObserver& observer : view_observers_) {
      observer.OnToolbarActionsChanged(window.id);
    }
  }
}

// ===========================================================================
// OpenWindowUi
// ===========================================================================

OpenWindowUi::OpenWindowUi(OpenWindowController* controller,
                           BrowserView* browser_view,
                           OpenBrowserView* open_view,
                           WindowID window_id)
    : controller_(controller),
      browser_view_(browser_view),
      open_view_(open_view),
      window_id_(std::move(window_id)) {
  // Command Bar and Peek widgets are created on first use (EnsureCommandBar,
  // EnsurePeek).
  split_ = static_cast<OpenSplitContainerView*>(open_view_->SetSplitContainer(
      std::make_unique<OpenSplitContainerView>(this)));

  // An empty, event-transparent view that Track 4 lays out to the web
  // panel's bounds: the Find bar and Toast widgets follow it.
  auto tracker = std::make_unique<views::View>();
  tracker->SetCanProcessEventsWithinSubtree(false);
  panel_tracker_ = open_view_->SetOverlay(
      OpenBrowserView::OverlaySlot::kFindBarAndToasts, std::move(tracker));
  panel_observation_.Observe(panel_tracker_.get());

  last_focused_space_ = model_util::FocusedSpace(service()->model(), window_id_);
  if (const Tab* active = controller_->GetActiveTab(window_id_)) {
    mru_.push_back(active->id);
  }
  RegisterAccelerators();
  ApplyWindowEffects();
  UpdatePanel();
}

OpenWindowUi::~OpenWindowUi() {
  if (views::FocusManager* focus_manager = browser_view_->GetFocusManager()) {
    focus_manager->UnregisterAccelerators(this);
  }
  escape_registered_ = false;
  switcher_monitor_.reset();
  find_observation_.Reset();
  panel_observation_.Reset();
  // Every view that holds a raw_ptr to this object as its delegate goes
  // before this object does, also on an early shutdown (the browser window
  // still open): child widgets first, then the slots OpenBrowserView owns.
  find_bar_ = nullptr;
  find_host_.reset();
  toasts_ = nullptr;
  toast_host_.reset();
  switcher_ = nullptr;
  switcher_host_.reset();
  site_controls_.reset();
  if (peek_) {
    peek_->Hide();  // Detaches the page from the card's WebView.
  }
  peek_ = nullptr;
  peek_host_.reset();
  command_bar_ = nullptr;
  command_bar_host_.reset();
  if (open_view_) {
    open_view_->SetOverlay(OpenBrowserView::OverlaySlot::kCommandBar, nullptr);
    open_view_->SetOverlay(OpenBrowserView::OverlaySlot::kPeek, nullptr);
    open_view_->SetOverlay(OpenBrowserView::OverlaySlot::kFindBarAndToasts,
                           nullptr);
    split_ = nullptr;
    open_view_->SetSplitContainer(nullptr);
  }
  panel_tracker_ = nullptr;
  if (peek_contents_) {
    peek_contents_->SetDelegate(nullptr);
  }
  peek_contents_.reset();
}

content::WebContents* OpenWindowUi::ActiveWebContents() const {
  content::WebContents* contents =
      browser_view_ ? browser_view_->GetActiveWebContents() : nullptr;
  // The blank page that keeps an empty window alive is not an Open tab.
  return OpenTabBridge::TabIdForWebContents(contents) ? contents : nullptr;
}

std::optional<ItemID> OpenWindowUi::ActiveTabId() const {
  return OpenTabBridge::TabIdForWebContents(ActiveWebContents());
}

void OpenWindowUi::ApplyWindowEffects() {
  views::Widget* w = widget();
  if (OpenPlatform* platform = OpenPlatform::Get(); platform && w) {
    platform->ApplyWindowEffects(w, CurrentAppearance().dark);
  }
}

OpenBrowserService* OpenWindowUi::service() const {
  return controller_->service();
}

secondary::Appearance OpenWindowUi::CurrentAppearance() const {
  secondary::Appearance appearance;
  appearance.dark = controller_->IsSystemDarkMode();
  std::optional<SpaceID> space =
      model_util::FocusedSpace(service()->model(), window_id_);
  if (const Space* s = space ? service()->model().FindSpace(*space) : nullptr) {
    if (s->theme.accent) {
      appearance.accent = ToSkColor(*s->theme.accent);
      appearance.dark_accent = appearance.accent;
    } else if (s->theme.style) {
      appearance.accent = ToSkColor(s->theme.style->key_color);
    }
    if (s->theme.style) {
      appearance.focus_ring = ToSkColor(s->theme.style->key_color);
      if (s->theme.style->appearance == ThemeAppearance::kDark) {
        appearance.dark = true;
      } else if (s->theme.style->appearance == ThemeAppearance::kLight) {
        appearance.dark = false;
      }
    }
  }
  return appearance;
}

// --- Command Bar -------------------------------------------------------------

void OpenWindowUi::EnsureCommandBar() {
  if (command_bar_host_ || !widget()) {
    return;
  }
  auto view = std::make_unique<OpenCommandBarView>(this);
  view->SetVisible(false);
  command_bar_ = view.get();
  command_bar_host_ = std::make_unique<secondary::OverlayWidgetHost>(
      widget(), std::move(view), "OpenCommandBar");
  UpdateOverlayAnchors();
}

void OpenWindowUi::EnsurePeek() {
  if (peek_host_ || !widget()) {
    return;
  }
  auto view = std::make_unique<OpenPeekOverlayView>(this);
  view->SetVisible(false);
  peek_ = view.get();
  peek_host_ = std::make_unique<secondary::OverlayWidgetHost>(
      widget(), std::move(view), "OpenPeek");
  UpdateOverlayAnchors();
}

views::Widget* OpenWindowUi::command_bar_widget() const {
  return command_bar_host_ ? command_bar_host_->widget() : nullptr;
}

void OpenWindowUi::ShowCommandBar(CommandBarMode mode,
                                  const std::u16string& initial_text,
                                  std::optional<gfx::Rect> anchor_in_screen) {
  EnsureCommandBar();
  if (!command_bar_) {
    return;
  }
  command_bar_mode_ = mode;
  CommandBarRequest request;
  request.mode = mode;
  request.initial_text = initial_text;
  request.appearance = CurrentAppearance();
  if (anchor_in_screen && open_view_) {
    gfx::Rect local = *anchor_in_screen;
    gfx::Point origin = local.origin();
    views::View::ConvertPointFromScreen(open_view_, &origin);
    local.set_origin(origin);
    request.inline_anchor = local;
  }
  const bool was_shown = command_bar_shown();
  // The widget shows before Present() so the field can take focus.
  UpdateOverlayAnchors();
  command_bar_host_->Show();
  command_bar_->SetVisible(true);
  command_bar_->Present(request);
  UpdateEscapeRegistration();
  if (!was_shown) {
    controller_->NotifyCommandBarStateChanged(window_id_);
  }
}

void OpenWindowUi::HideCommandBar() {
  if (command_bar_ && command_bar_->is_presented()) {
    // OnCommandBarDismissed() hides the widget and notifies.
    command_bar_->Dismiss(CommandBarDismissReason::kProgrammatic);
  }
  if (command_bar_) {
    command_bar_->SetVisible(false);
  }
  if (command_bar_host_ && command_bar_host_->IsVisible()) {
    command_bar_host_->Hide();
  }
  UpdateEscapeRegistration();
}

bool OpenWindowUi::command_bar_shown() const {
  return command_bar_ && command_bar_->is_presented();
}

void OpenWindowUi::TypeInCommandBar(const std::u16string& text) {
  if (command_bar_shown()) {
    command_bar_->InsertText(text);
  }
}

void OpenWindowUi::CommitCommandBar() {
  if (!command_bar_shown()) {
    return;
  }
  const std::vector<CommandBarRow>& rows = command_bar_->rows();
  const size_t index = command_bar_->selected_index();
  CommandBarIntent intent;
  intent.typed_text = command_bar_->typed_text();
  intent.scope = command_bar_->scope();
  intent.disposition = command_bar_mode_ == CommandBarMode::kEditCurrentUrl
                           ? CommandBarDisposition::kCurrentTab
                           : CommandBarDisposition::kNewForegroundTab;
  if (index < rows.size()) {
    intent.row = rows[index];
  } else {
    intent.row.kind = CommandBarRowKind::kSearch;
  }
  OnCommandBarIntent(intent);
  HideCommandBar();
}

CommandBarResults OpenWindowUi::QuerySuggestions(const CommandBarQuery& query) {
  OpenBrowserService* s = service();
  return QueryCommandBar(s, query, s->ActiveProfileId(),
                         model_util::FocusedSpace(s->model(), window_id_),
                         ActiveTabId());
}

std::optional<CommandBarScopeTarget> OpenWindowUi::ResolveSiteSearch(
    std::u16string_view text,
    bool exact_keyword_only) {
  return ResolveSiteSearchFor(service(), service()->ActiveProfileId(), text,
                              exact_keyword_only);
}

void OpenWindowUi::OpenUrlWithDisposition(const GURL& url,
                                          CommandBarDisposition disposition) {
  if (!url.is_valid()) {
    return;
  }
  OpenTabBridge* bridge = service()->tab_bridge();
  switch (disposition) {
    case CommandBarDisposition::kCurrentTab:
      if (std::optional<ItemID> active = ActiveTabId()) {
        bridge->Navigate(*active, url);
        return;
      }
      bridge->OpenTab(url, /*background=*/false);
      return;
    case CommandBarDisposition::kNewForegroundTab:
      bridge->OpenTab(url, /*background=*/false);
      return;
    case CommandBarDisposition::kNewBackgroundTab:
      bridge->OpenTab(url, /*background=*/true);
      return;
    case CommandBarDisposition::kSplitView: {
      std::optional<ItemID> active = ActiveTabId();
      const ItemID opened = bridge->OpenTab(url, /*background=*/true);
      if (active && !opened.empty()) {
        service()->model().MakeSplit({*active, opened});
      }
      return;
    }
  }
}

void OpenWindowUi::RunAction(const std::string& action_id) {
  const CommandDefinition* command =
      service()->commands().FindByStringId(action_id);
  if (command) {
    RunCommandId(command->command_id);
  }
}

bool OpenWindowUi::RunCommandId(CommandId command) {
  OpenBrowserService* s = service();
  OpenTabBridge* bridge = s->tab_bridge();
  if (!bridge) {
    return false;
  }
  BrowserModel& model = s->model();
  std::optional<ItemID> active = ActiveTabId();
  auto open_page = [&](std::string_view host, std::string_view path) {
    bridge->OpenTab(GURL(webui::OpenWebUIURL(host, path)),
                    /*background=*/false);
  };
  auto intent = [&](OpenIntentKind kind) {
    controller_->HandleIntent(window_id_, OpenIntent::Of(kind));
  };
  if (const int index = GoToTabIndex(command); index >= 0) {
    // Arc: Cmd/Ctrl+1..8 go to that sidebar item, 9 to the last one.
    const std::optional<SpaceID> space =
        model_util::FocusedSpace(model, window_id_);
    const std::vector<ItemID> ids =
        space ? model_util::OrderedTabIds(model, *space)
              : std::vector<ItemID>();
    if (ids.empty()) {
      return true;
    }
    const size_t target = index == 8 ? ids.size() - 1
                                     : std::min(static_cast<size_t>(index),
                                                ids.size() - 1);
    bridge->SelectNode(ids[target]);
    return true;
  }
  if (const int index = GoToSpaceIndex(command); index >= 0) {
    const std::vector<SpaceID> spaces =
        controller_->GetWindowSpaceIds(window_id_);
    if (static_cast<size_t>(index) < spaces.size()) {
      bridge->FocusSpace(spaces[static_cast<size_t>(index)]);
    }
    return true;
  }
  switch (command) {
    case CommandId::kNewTab:
    case CommandId::kOpenCommandBar:
      if (command == CommandId::kOpenCommandBar && active) {
        // Cmd/Ctrl+L edits the current URL (Arc).
        const Tab* tab = model.FindTab(*active);
        ShowCommandBar(CommandBarMode::kEditCurrentUrl,
                       tab ? base::UTF8ToUTF16(tab->url) : std::u16string(),
                       std::nullopt);
      } else {
        ShowCommandBar(CommandBarMode::kNewTab, std::u16string(),
                       std::nullopt);
      }
      return true;
    case CommandId::kSettings:
      open_page(webui::kHostSettings, "");
      return true;
    case CommandId::kViewLibrary:
      open_page(webui::kHostLibrary, "");
      return true;
    case CommandId::kViewHistory:
      open_page(webui::kHostLibrary, "history");
      return true;
    case CommandId::kViewArchive:
      open_page(webui::kHostLibrary, "archive");
      return true;
    case CommandId::kViewDownloads:
      open_page(webui::kHostLibrary, "downloads");
      return true;
    case CommandId::kViewMedia:
      open_page(webui::kHostLibrary, "media");
      return true;
    case CommandId::kViewBoosts:
    case CommandId::kNewBoost:
      open_page(webui::kHostBoosts, "");
      return true;
    case CommandId::kNewEasel:
      open_page(webui::kHostEasel, "");
      return true;
    case CommandId::kNewNote:
      open_page(webui::kHostNote, "");
      return true;
    case CommandId::kToggleSidebar:
      intent(OpenIntentKind::kToggleSidebar);
      return true;
    case CommandId::kNewSpace:
      intent(OpenIntentKind::kNewSpace);
      return true;
    case CommandId::kNextSpace:
    case CommandId::kPreviousSpace: {
      const std::vector<SpaceID> spaces =
          controller_->GetWindowSpaceIds(window_id_);
      const std::optional<SpaceID> focused =
          model_util::FocusedSpace(model, window_id_);
      if (spaces.size() < 2 || !focused) {
        return true;
      }
      auto it = std::find(spaces.begin(), spaces.end(), *focused);
      const size_t current =
          it == spaces.end() ? 0 : static_cast<size_t>(it - spaces.begin());
      const size_t next =
          command == CommandId::kNextSpace
              ? (current + 1) % spaces.size()
              : (current + spaces.size() - 1) % spaces.size();
      bridge->FocusSpace(spaces[next]);
      return true;
    }
    case CommandId::kNextTab:
    case CommandId::kPreviousTab: {
      const std::optional<SpaceID> space =
          model_util::FocusedSpace(model, window_id_);
      const std::vector<ItemID> ids =
          space ? model_util::OrderedTabIds(model, *space)
                : std::vector<ItemID>();
      if (ids.empty()) {
        return true;
      }
      auto it = active ? std::find(ids.begin(), ids.end(), *active)
                       : ids.end();
      size_t next = 0;
      if (it != ids.end()) {
        const size_t current = static_cast<size_t>(it - ids.begin());
        next = command == CommandId::kNextTab
                   ? (current + 1) % ids.size()
                   : (current + ids.size() - 1) % ids.size();
      }
      bridge->SelectNode(ids[next]);
      return true;
    }
    case CommandId::kAddSplitView:
      if (active) {
        bridge->ToggleSplit(*active);
      }
      return true;
    case CommandId::kCloseSplitPane:
      if (active) {
        if (std::optional<NodeParent> parent = model.GetParent(*active);
            parent && parent->kind == NodeParentKind::kSplitPane) {
          model.RemovePane(parent->owner_id, *active, /*archive=*/true);
        }
      }
      return true;
    case CommandId::kPinUnpinTab:
      if (active) {
        bridge->TogglePin(*active);
      }
      return true;
    case CommandId::kArchiveTab:
      if (active) {
        bridge->CloseNode(*active);
      }
      return true;
    case CommandId::kReload:
      intent(OpenIntentKind::kReload);
      return true;
    case CommandId::kGoBack:
      intent(OpenIntentKind::kGoBack);
      return true;
    case CommandId::kGoForward:
      intent(OpenIntentKind::kGoForward);
      return true;
    case CommandId::kCopyUrl:
      if (content::WebContents* contents = ActiveWebContents()) {
        CopyUrl(contents->GetLastCommittedURL());
      }
      return true;
    case CommandId::kFind:
      ShowFindBar();
      return true;
    case CommandId::kFindNext:
      FindNext(/*forward=*/true);
      return true;
    case CommandId::kFindPrevious:
      FindNext(/*forward=*/false);
      return true;
    case CommandId::kNewLittleOpenWindow:
    case CommandId::kLittleOpenGlobal:
      controller_->OpenLittleOpen(std::nullopt);
      return true;
    default:
      // Other actions run through Chromium's own command handling where it
      // exists (Print, zoom).
      return false;
  }
}

void OpenWindowUi::OnCommandBarIntent(const CommandBarIntent& intent) {
  const CommandBarRow& row = intent.row;
  switch (row.kind) {
    case CommandBarRowKind::kSwitchToTab:
    case CommandBarRowKind::kSwitchToSplit:
      if (row.tab_id) {
        service()->tab_bridge()->SelectNode(*row.tab_id);
      }
      return;
    case CommandBarRowKind::kAction:
      RunAction(row.action_id);
      return;
    case CommandBarRowKind::kCalculator:
      ui::ScopedClipboardWriter(ui::ClipboardBuffer::kCopyPaste)
          .WriteText(row.title);
      return;
    default:
      break;
  }
  OpenUrlWithDisposition(UrlForCommandBarIntent(intent), intent.disposition);
}

void OpenWindowUi::OnCommandBarDismissed(
    CommandBarDismissReason reason,
    std::optional<gfx::Point> click_location) {
  if (command_bar_) {
    command_bar_->SetVisible(false);
  }
  if (command_bar_host_) {
    command_bar_host_->Hide();
  }
  UpdateEscapeRegistration();
  // Back to the page under the bar: Peek's when Peek shows, else the tab.
  if (peek_shown() && peek_contents_) {
    peek_contents_->Focus();
  } else if (content::WebContents* contents = ActiveWebContents()) {
    contents->Focus();
  }
  controller_->NotifyCommandBarStateChanged(window_id_);
}

// --- Peek --------------------------------------------------------------------

void OpenWindowUi::OpenPeek(const GURL& url,
                            const std::optional<ItemID>& source_node) {
  if (!url.is_valid()) {
    return;
  }
  EnsurePeek();
  if (!peek_) {
    return;
  }
  ClosePeek();
  BrowserWindowInterface* browser = browser_view_->browser();
  content::WebContents::CreateParams params(browser->GetProfile());
  peek_contents_ = content::WebContents::Create(params);
  AttachOverlayPageHelpers(peek_contents_.get());
  // Unhandled keys (Esc, Cmd/Ctrl+O) come back to the window; JavaScript
  // dialogs are tab-modal to this window.
  peek_contents_->SetDelegate(this);
  if (auto* modal = web_modal::WebContentsModalDialogManager::FromWebContents(
          peek_contents_.get())) {
    modal->SetDelegate(this);
  }
  peek_contents_->GetController().LoadURLWithParams(
      content::NavigationController::LoadURLParams(url));
  peek_source_ = source_node;
  peek_->SetAppearance(CurrentAppearance());
  UpdateOverlayAnchors();
  peek_host_->Show();
  // The Command Bar (when open) stays above Peek.
  if (command_bar_host_ && command_bar_host_->IsVisible()) {
    command_bar_host_->Show();
  }
  peek_->SetVisible(true);
  peek_->Show(peek_contents_.get(), open_view_->GetPanelBounds());
  UpdateEscapeRegistration();
  controller_->NotifyPeekChanged(window_id_);
}

void OpenWindowUi::ExpandPeek() {
  OnPeekExpandToTab();
}

void OpenWindowUi::ClosePeek() {
  const bool was_shown = peek_shown();
  if (peek_ && peek_->is_showing()) {
    peek_->Hide();
  }
  if (peek_) {
    peek_->SetVisible(false);
  }
  if (peek_host_ && peek_host_->IsVisible()) {
    peek_host_->Hide();
  }
  if (peek_contents_) {
    if (auto* modal = web_modal::WebContentsModalDialogManager::FromWebContents(
            peek_contents_.get())) {
      modal->SetDelegate(nullptr);
    }
    peek_contents_->SetDelegate(nullptr);
  }
  peek_contents_.reset();
  peek_source_.reset();
  UpdateEscapeRegistration();
  if (was_shown) {
    if (content::WebContents* contents = ActiveWebContents()) {
      contents->Focus();
    }
    controller_->NotifyPeekChanged(window_id_);
  }
}

bool OpenWindowUi::peek_shown() const {
  return peek_ && peek_->is_showing();
}

void OpenWindowUi::OnPeekDismissed(PeekDismissReason reason) {
  ClosePeek();
}

void OpenWindowUi::OnPeekExpandToTab() {
  if (!peek_contents_) {
    return;
  }
  // The page becomes a Today tab at its current URL (a fresh page keeps
  // the sidebar's single owner of every WebContents: OpenTabBridge).
  const GURL url = peek_contents_->GetLastCommittedURL().is_valid()
                       ? peek_contents_->GetLastCommittedURL()
                       : peek_contents_->GetVisibleURL();
  ClosePeek();
  service()->tab_bridge()->OpenTab(url, /*background=*/false);
}

void OpenWindowUi::OnPeekOpenInSplit() {
  if (!peek_contents_) {
    return;
  }
  const GURL url = peek_contents_->GetVisibleURL();
  ClosePeek();
  OpenUrlWithDisposition(url, CommandBarDisposition::kSplitView);
}

// --- Site Control ------------------------------------------------------------

open_unified::SiteControlState OpenWindowUi::BuildSiteControlState() const {
  open_unified::SiteControlState state;
  content::WebContents* contents = ActiveWebContents();
  if (!contents) {
    return state;
  }
  const GURL url = contents->GetLastCommittedURL();
  state.host = base::UTF8ToUTF16(url.host());
  state.secure = url.SchemeIsCryptographic();
  OpenBrowserService* s = service();
  if (std::optional<ItemID> tab = ActiveTabId()) {
    if (std::optional<ProfileID> profile =
            model_util::ProfileOfNode(s->model(), *tab)) {
      state.boost_active =
          !s->boost_controller()->MatchingBoosts(*profile, url).empty();
    }
  }
  if (OpenExtensionBridge* extensions = s->extension_bridge()) {
    for (const ExtensionActionInfo& info : extensions->ListActions()) {
      SiteControlExtensionItem item;
      item.id = info.id;
      item.name = base::UTF8ToUTF16(info.name);
      item.badge_text = base::UTF8ToUTF16(info.badge_text);
      item.enabled = info.enabled && info.visible;
      state.extensions.push_back(std::move(item));
    }
  }
  ::Profile* profile =
      ::Profile::FromBrowserContext(contents->GetBrowserContext());
  HostContentSettingsMap* settings =
      HostContentSettingsMapFactory::GetForProfile(profile);
  for (SitePermissionKind kind :
       {SitePermissionKind::kCamera, SitePermissionKind::kMicrophone,
        SitePermissionKind::kLocation, SitePermissionKind::kNotifications,
        SitePermissionKind::kPopups}) {
    SitePermissionRow row;
    row.kind = kind;
    row.setting = ToPermissionSetting(
        settings->GetContentSetting(url, url, ToContentSettingsType(kind)));
    state.permissions.push_back(row);
  }
  OpenAdBlockProfileService* adblock =
      OpenAdBlockProfileService::GetForBrowserContext(
          contents->GetBrowserContext());
  state.ad_block_available = adblock && adblock->service();
  state.ad_block_enabled =
      adblock && adblock->IsEnabled() && !adblock->IsHostExcluded(url.host());
  state.ad_block_blocked_count =
      OpenAdBlockProfileService::GetTotalStoppedCount(contents);
  state.split_available = !split_active_;
  return state;
}

void OpenWindowUi::ShowSiteControls(views::View* anchor) {
  if (!ActiveWebContents()) {
    return;
  }
  if (!site_controls_) {
    site_controls_ = std::make_unique<OpenSiteControlBubble>(this);
  }
  views::View* target =
      anchor ? anchor : open_view_->GetSiteControlAnchorView();
  if (!target) {
    target = open_view_->GetUrlPillView();
  }
  site_controls_->Show(target, BuildSiteControlState(), CurrentAppearance());
}

void OpenWindowUi::HideSiteControls() {
  if (site_controls_) {
    site_controls_->Close();
  }
}

bool OpenWindowUi::site_controls_shown() const {
  return site_controls_ && site_controls_->IsShowing();
}

void OpenWindowUi::CopyUrl(const GURL& url) {
  ui::ScopedClipboardWriter(ui::ClipboardBuffer::kCopyPaste)
      .WriteText(base::UTF8ToUTF16(url.spec()));
  ShowToast(ToastSpec::CopiedUrl());
}

void OpenWindowUi::OnSiteControlAction(SiteControlAction action) {
  content::WebContents* contents = ActiveWebContents();
  if (!contents) {
    return;
  }
  const GURL url = contents->GetLastCommittedURL();
  OpenTabBridge* bridge = service()->tab_bridge();
  switch (action) {
    case SiteControlAction::kCopyUrl:
      CopyUrl(url);
      break;
    case SiteControlAction::kNewBoost:
      bridge->OpenTab(GURL(webui::OpenWebUIURL(webui::kHostBoosts,
                                               "new?host=" + std::string(url.host()))),
                      /*background=*/false);
      break;
    case SiteControlAction::kSplit:
      if (std::optional<ItemID> active = ActiveTabId()) {
        bridge->ToggleSplit(*active);
      }
      break;
    case SiteControlAction::kCapture:
      break;  // Capture lives in Track 5's Toasts/Find surface.
    case SiteControlAction::kSiteSettings:
    case SiteControlAction::kClearSiteData:
      // Chromium's own per-site page (cookies, storage, permissions).
      bridge->OpenTab(GURL("chrome://settings/content/siteDetails?site=" +
                           url::Origin::Create(url).Serialize()),
                      /*background=*/false);
      break;
  }
  HideSiteControls();
}

void OpenWindowUi::OnSiteControlExtensionPressed(
    const std::string& extension_id,
    views::View* anchor) {
  if (OpenExtensionBridge* extensions = service()->extension_bridge()) {
    extensions->ExecuteAction(extension_id, anchor, base::DoNothing());
  }
}

void OpenWindowUi::OnSiteControlPermissionChanged(
    SitePermissionKind kind,
    SitePermissionSetting setting) {
  content::WebContents* contents = ActiveWebContents();
  if (!contents) {
    return;
  }
  const GURL url = contents->GetLastCommittedURL();
  ContentSetting value = CONTENT_SETTING_DEFAULT;
  if (setting == SitePermissionSetting::kAllow) {
    value = CONTENT_SETTING_ALLOW;
  } else if (setting == SitePermissionSetting::kBlock) {
    value = CONTENT_SETTING_BLOCK;
  }
  HostContentSettingsMapFactory::GetForProfile(
      ::Profile::FromBrowserContext(contents->GetBrowserContext()))
      ->SetContentSettingDefaultScope(url, url, ToContentSettingsType(kind),
                                      value);
  if (site_controls_) {
    site_controls_->UpdateState(BuildSiteControlState());
  }
}

void OpenWindowUi::OnSiteControlAdBlockToggled(bool enabled) {
  content::WebContents* contents = ActiveWebContents();
  if (!contents) {
    return;
  }
  OpenAdBlockProfileService* adblock =
      OpenAdBlockProfileService::GetForBrowserContext(
          contents->GetBrowserContext());
  if (!adblock) {
    return;
  }
  // Per-site switch: an excluded site loads ads (Arc's "Block ads" toggle).
  const std::string host(contents->GetLastCommittedURL().host());
  if (enabled) {
    adblock->RemoveExcludedDomain(host);
  } else {
    adblock->AddExcludedDomain(host);
  }
  contents->GetController().Reload(content::ReloadType::NORMAL, true);
  if (site_controls_) {
    site_controls_->SetAdBlockState(
        enabled, OpenAdBlockProfileService::GetTotalStoppedCount(contents));
  }
}

void OpenWindowUi::OnSiteControlClosed() {}

// --- Split View --------------------------------------------------------------

void OpenWindowUi::UpdatePanel() {
  if (!split_ || !open_view_) {
    return;
  }
  OpenBrowserService* s = service();
  if (!s->tab_bridge()) {
    return;
  }
  const BrowserModel& model = s->model();
  const BrowserWindowState* window = model.FindWindow(window_id_);
  std::optional<ItemID> selected =
      window ? model.SelectedNodeId(window->focused_space_id, window_id_)
             : std::nullopt;
  const Split* split = selected ? model.FindSplit(*selected) : nullptr;
  if (!split) {
    if (split_active_) {
      split_active_ = false;
      split_->SetPresentation(SplitPresentation());
      open_view_->SetSplitViewActive(false);
      // Chromium's contents view shows the active page again.
      if (content::WebContents* active = ActiveWebContents()) {
        if (views::WebView* web_view =
                browser_view_->GetActiveContentsWebView()) {
          web_view->SetWebContents(active);
        }
      }
    }
    return;
  }
  SplitPresentation presentation;
  presentation.split_id = split->id;
  presentation.orientation = split->orientation;
  presentation.fractions = split->fractions;
  presentation.focused_pane_id = split->focused_pane_id;
  presentation.focus_ring_color = CurrentAppearance().focus_ring;
  for (const Tab& pane : split->panes) {
    SplitPaneSpec spec;
    spec.tab_id = pane.id;
    spec.web_contents = s->tab_bridge()->EnsureLoaded(pane.id);
    if (pane.live_state.page_background_color) {
      spec.page_background = ToSkColor(*pane.live_state.page_background_color);
    }
    const GURL url(pane.url);
    if (url.SchemeIs(webui::kOpenScheme)) {
      spec.host_label = url.host() == webui::kHostNote    ? u"Note"
                        : url.host() == webui::kHostEasel ? u"Easel"
                                                          : u"Open";
      spec.hides_copy = url.host() == webui::kHostNote;
      spec.site_controls_available = false;
    }
    presentation.panes.push_back(spec);
  }
  // A page can be attached to one WebView only: Chromium's contents view
  // lets go of the active pane while the split container shows it.
  if (views::WebView* web_view = browser_view_->GetActiveContentsWebView()) {
    web_view->SetWebContents(nullptr);
  }
  split_->SetPresentation(presentation);
  open_view_->SetSplitViewActive(true);
  split_active_ = true;
}

void OpenWindowUi::OnSplitFractionsCommitted(
    const ItemID& split_id,
    const std::vector<double>& fractions) {
  service()->model().SetSplitFractions(split_id, fractions);
}

void OpenWindowUi::OnPaneFocusRequested(const std::optional<ItemID>& split_id,
                                        const ItemID& tab_id) {
  service()->tab_bridge()->SelectNode(tab_id);
  if (split_) {
    split_->SetFocusedPane(tab_id);
  }
}

bool OpenWindowUi::OnPaneCommand(const std::optional<ItemID>& split_id,
                                 const ItemID& tab_id,
                                 PaneCommand command,
                                 views::View* anchor) {
  OpenBrowserService* s = service();
  OpenTabBridge* bridge = s->tab_bridge();
  content::WebContents* contents = bridge->WebContentsForTab(tab_id);
  switch (command) {
    case PaneCommand::kBack:
      return bridge->GoBack(tab_id);
    case PaneCommand::kForward:
      if (contents && contents->GetController().CanGoForward()) {
        contents->GetController().GoForward();
        return true;
      }
      return false;
    case PaneCommand::kReload:
      if (contents) {
        contents->GetController().Reload(content::ReloadType::NORMAL, true);
      }
      return contents != nullptr;
    case PaneCommand::kStop:
      if (contents) {
        contents->Stop();
      }
      return contents != nullptr;
    case PaneCommand::kCopyUrl:
      if (contents) {
        CopyUrl(contents->GetLastCommittedURL());
      }
      return contents != nullptr;
    case PaneCommand::kSiteControl:
      bridge->SelectNode(tab_id);
      ShowSiteControls(anchor);
      return true;
    case PaneCommand::kAddSplit:
      if (split_id) {
        const ItemID opened = bridge->OpenTab(GURL("about:blank"), true);
        return !opened.empty() && s->model().AddPane(*split_id, opened);
      }
      return bridge->ToggleSplit(tab_id).has_value();
    case PaneCommand::kSwapPanes:
      if (split_id) {
        if (const Split* split = s->model().FindSplit(*split_id);
            split && split->panes.size() == 2) {
          return s->model().MoveNode(
              tab_id, NodeParent{NodeParentKind::kSplitPane, *split_id},
              split->panes.front().id == tab_id ? size_t{1} : size_t{0});
        }
      }
      return false;
    case PaneCommand::kToggleOrientation:
      if (split_id) {
        if (const Split* split = s->model().FindSplit(*split_id)) {
          return s->model().SetSplitOrientation(
              *split_id,
              split->orientation == SplitOrientation::kHorizontal
                  ? SplitOrientation::kVertical
                  : SplitOrientation::kHorizontal);
        }
      }
      return false;
    case PaneCommand::kSeparateTab:
      return split_id && s->model().RemovePane(*split_id, tab_id);
    case PaneCommand::kClosePane:
      return split_id &&
             s->model().RemovePane(*split_id, tab_id, /*archive=*/true);
  }
  return false;
}

// --- Overlay widgets (Find bar, Toasts, Tab switcher) ------------------------

views::Widget* OpenWindowUi::widget() const {
  return browser_view_ ? browser_view_->GetWidget() : nullptr;
}

void OpenWindowUi::ActivateWindow() {
  if (views::Widget* w = widget()) {
    w->Activate();
  }
}

void OpenWindowUi::FocusPage() {
  if (content::WebContents* contents = ActiveWebContents()) {
    contents->Focus();
  }
}

gfx::Rect OpenWindowUi::PanelRectInWidget() const {
  if (panel_tracker_) {
    return panel_tracker_->ConvertRectToWidget(
        panel_tracker_->GetLocalBounds());
  }
  return open_view_->ConvertRectToWidget(open_view_->GetPanelBounds());
}

gfx::Rect OpenWindowUi::WindowRectInWidget() const {
  return open_view_->ConvertRectToWidget(open_view_->GetLocalBounds());
}

void OpenWindowUi::EnsureFindBar() {
  if (find_host_ || !widget()) {
    return;
  }
  auto view = std::make_unique<OpenFindBarView>(this);
  find_bar_ = view.get();
  find_host_ = std::make_unique<secondary::OverlayWidgetHost>(
      widget(), std::move(view), "OpenFindBar");
  UpdateOverlayAnchors();
}

void OpenWindowUi::EnsureToasts() {
  if (toast_host_ || !widget()) {
    return;
  }
  auto view = std::make_unique<OpenToastStackView>();
  toasts_ = view.get();
  toast_host_ = std::make_unique<secondary::OverlayWidgetHost>(
      widget(), std::move(view), "OpenToasts");
  // The stack says when its first toast appears and its last one goes.
  toasts_->SetVisibilityCallback(base::BindRepeating(
      [](base::WeakPtr<OpenWindowUi> self, bool visible) {
        if (!self || !self->toast_host_) {
          return;
        }
        if (visible) {
          self->UpdateOverlayAnchors();
          self->toast_host_->Show();
        } else {
          self->toast_host_->Hide();
        }
      },
      weak_factory_.GetWeakPtr()));
  UpdateOverlayAnchors();
}

void OpenWindowUi::EnsureTabSwitcher() {
  if (switcher_host_ || !widget()) {
    return;
  }
  auto view = std::make_unique<OpenTabSwitcherView>(this);
  switcher_ = view.get();
  switcher_host_ = std::make_unique<secondary::OverlayWidgetHost>(
      widget(), std::move(view), "OpenTabSwitcher");
  UpdateOverlayAnchors();
}

void OpenWindowUi::UpdateOverlayAnchors() {
  using Alignment = secondary::OverlayWidgetHost::Alignment;
  const gfx::Rect panel = PanelRectInWidget();
  // Command Bar and Peek cover the client area: their views lay out in
  // OpenBrowserView's coordinates (the widget's origin is OpenBrowserView's).
  const gfx::Rect window = WindowRectInWidget();
  if (command_bar_host_) {
    command_bar_host_->SetAnchor(window, Alignment::kFill);
  }
  if (peek_host_) {
    peek_host_->SetAnchor(window, Alignment::kFill);
    if (peek_ && peek_->is_showing()) {
      peek_->SetContentRect(open_view_->GetPanelBounds());
    }
  }
  if (find_host_) {
    // Open's Views chrome has no content toolbar above the page.
    find_host_->SetAnchor(
        OpenFindBarView::ComputeAnchor(panel, /*has_content_toolbar=*/false),
        Alignment::kTopRight);
  }
  if (toast_host_) {
    toast_host_->SetAnchor(OpenToastStackView::ComputeAnchor(panel),
                           Alignment::kTopRight);
  }
  if (switcher_host_) {
    switcher_host_->SetAnchor(WindowRectInWidget(), Alignment::kCenter);
  }
}

void OpenWindowUi::OnViewBoundsChanged(views::View* observed_view) {
  UpdateOverlayAnchors();
}

void OpenWindowUi::OnViewIsDeleting(views::View* observed_view) {
  panel_observation_.Reset();
  panel_tracker_ = nullptr;
}

// --- Find in page --------------------------------------------------------------

find_in_page::FindTabHelper* OpenWindowUi::FindHelper() const {
  content::WebContents* contents = ActiveWebContents();
  return contents ? find_in_page::FindTabHelper::FromWebContents(contents)
                  : nullptr;
}

bool OpenWindowUi::find_bar_shown() const {
  return find_host_ && find_host_->IsVisible();
}

void OpenWindowUi::ShowFindBar(std::optional<std::u16string> query) {
  content::WebContents* contents = ActiveWebContents();
  find_in_page::FindTabHelper* helper =
      contents ? find_in_page::FindTabHelper::FromWebContents(contents)
               : nullptr;
  if (!helper) {
    return;  // No page (empty window) or a page without find support.
  }
  EnsureFindBar();
  if (!find_bar_) {
    return;
  }
  if (find_bar_shown() && find_observation_.IsObservingSource(helper) &&
      !query) {
    // Find again while the bar shows: select the whole query.
    find_bar_->Activate(std::u16string(find_bar_->query()));
    return;
  }
  // A new session (or another page after a tab switch).
  if (find_observation_.IsObserving()) {
    if (find_in_page::FindTabHelper* old = find_observation_.GetSource();
        old && old != helper) {
      old->StopFinding(find_in_page::SelectionAction::kKeep);
    }
    find_observation_.Reset();
  }
  find_observation_.Observe(helper);

  std::u16string seed;
  if (query) {
    seed = *query;
  } else if (content::RenderWidgetHostView* view =
                 contents->GetRenderWidgetHostView()) {
    seed = view->GetSelectedText();
  }
  base::ReplaceChars(seed, u"\r\n", u" ", &seed);
  if (seed.size() > kFindSeedMaxLength) {
    seed.resize(kFindSeedMaxLength);
  }
  if (seed.empty() && !query) {
    seed = helper->previous_find_text();
  }

  find_bar_->SetAppearance(CurrentAppearance());
  find_bar_->ClearResult();
  UpdateOverlayAnchors();
  find_host_->Show();
  // Activate() reports a changed seed through OnFindQueryChanged(); an
  // unchanged one (the bar's last query) restarts the search here.
  const bool reports_change = !seed.empty() && seed != find_bar_->query();
  find_bar_->Activate(seed);
  if (!reports_change && !find_bar_->query().empty()) {
    OnFindQueryChanged(std::u16string(find_bar_->query()));
  }
  UpdateEscapeRegistration();
}

void OpenWindowUi::FindNext(bool forward) {
  if (!find_bar_shown()) {
    // Cmd/Ctrl+G with the bar closed opens it with the previous query
    // (which already finds the first match), as Chromium does.
    ShowFindBar();
    return;
  }
  OnFindNext(forward);
}

void OpenWindowUi::CloseFindBar() {
  if (find_in_page::FindTabHelper* helper = find_observation_.GetSource()) {
    helper->StopFinding(find_in_page::SelectionAction::kKeep);
  }
  find_observation_.Reset();
  const bool was_shown = find_bar_shown();
  if (find_host_) {
    find_host_->Hide();
  }
  UpdateEscapeRegistration();
  if (was_shown) {
    FocusPage();
  }
}

void OpenWindowUi::OnFindQueryChanged(const std::u16string& query) {
  find_in_page::FindTabHelper* helper = find_observation_.GetSource();
  if (!helper) {
    return;
  }
  if (query.empty()) {
    helper->StopFinding(find_in_page::SelectionAction::kClear);
    if (find_bar_) {
      find_bar_->ClearResult();
    }
    return;
  }
  helper->StartFinding(query, /*forward_direction=*/true,
                       /*case_sensitive=*/false, /*find_match=*/true);
}

void OpenWindowUi::OnFindNext(bool forward) {
  find_in_page::FindTabHelper* helper = find_observation_.GetSource();
  if (!helper || !find_bar_ || find_bar_->query().empty()) {
    return;
  }
  // The same text with find_match continues the session (next/previous).
  helper->StartFinding(std::u16string(find_bar_->query()), forward,
                       /*case_sensitive=*/false, /*find_match=*/true);
}

void OpenWindowUi::OnFindClosed() {
  CloseFindBar();
}

void OpenWindowUi::OnFindResultAvailable(content::WebContents* web_contents) {
  find_in_page::FindTabHelper* helper = find_observation_.GetSource();
  if (!helper || !find_bar_) {
    return;
  }
  const find_in_page::FindNotificationDetails& result = helper->find_result();
  if (find_bar_->query().empty()) {
    find_bar_->ClearResult();
    return;
  }
  if (result.number_of_matches() < 0) {
    return;  // The renderer has not counted yet.
  }
  find_bar_->SetResult(std::max(0, result.active_match_ordinal()),
                       result.number_of_matches());
}

void OpenWindowUi::OnFindTabHelperDestroyed(
    find_in_page::FindTabHelper* helper) {
  find_observation_.Reset();
  if (find_host_) {
    find_host_->Hide();
  }
  UpdateEscapeRegistration();
}

// --- Toasts --------------------------------------------------------------------

void OpenWindowUi::ShowToast(ToastSpec spec) {
  EnsureToasts();
  if (!toasts_) {
    return;
  }
  toasts_->SetAppearance(CurrentAppearance());
  toasts_->Show(std::move(spec));
}

void OpenWindowUi::OnModelChanged() {
  const BrowserModel& model = service()->model();
  const std::optional<SpaceID> focused =
      model_util::FocusedSpace(model, window_id_);
  if (focused == last_focused_space_) {
    return;
  }
  const bool switched = last_focused_space_.has_value() && focused.has_value();
  last_focused_space_ = focused;
  // A Space with a light or dark theme switches the native window effects.
  ApplyWindowEffects();
  if (!switched) {
    return;
  }
  // Guess (no Arc capture of this toast yet): the toast stands in for the
  // sidebar's Space header, so it shows only while the sidebar is hidden.
  const BrowserWindowState* window = model.FindWindow(window_id_);
  if (!window || window->sidebar_mode != SidebarMode::kHidden) {
    return;
  }
  if (const Space* space = model.FindSpace(*focused)) {
    ShowToast(ToastSpec::SpaceSwitched(SpaceTitle(*space), IconText(space->icon)));
  }
}

// --- Ctrl+Tab switcher ---------------------------------------------------------

void OpenWindowUi::OnTabActivated(const ItemID& tab_id) {
  std::erase(mru_, tab_id);
  mru_.insert(mru_.begin(), tab_id);
  if (mru_.size() > kMruLimit) {
    mru_.resize(kMruLimit);
  }
  // A find session belongs to its page.
  if (find_bar_shown() && FindHelper() != find_observation_.GetSource()) {
    CloseFindBar();
  }
}

bool OpenWindowUi::tab_switcher_active() const {
  return switcher_ && switcher_->is_active();
}

std::vector<TabSwitcherItem> OpenWindowUi::BuildSwitcherItems() const {
  const BrowserModel& model = service()->model();
  OpenTabBridge* bridge = service()->tab_bridge();
  std::vector<ItemID> ids;
  auto add = [&](const ItemID& id) {
    if (ids.size() < kSwitcherItemLimit && model.FindTab(id) &&
        std::find(ids.begin(), ids.end(), id) == ids.end()) {
      ids.push_back(id);
    }
  };
  // Current tab first, then most recently used.
  if (bridge) {
    if (std::optional<ItemID> active = ActiveTabId()) {
      add(*active);
    }
  }
  for (const ItemID& id : mru_) {
    add(id);
  }
  // A fresh window has little history: fill from the focused Space.
  if (ids.size() < 2) {
    if (std::optional<SpaceID> space =
            model_util::FocusedSpace(model, window_id_)) {
      for (const ItemID& id : model_util::OrderedTabIds(model, *space)) {
        add(id);
      }
    }
  }
  std::vector<TabSwitcherItem> items;
  items.reserve(ids.size());
  for (const ItemID& id : ids) {
    const Tab* tab = model.FindTab(id);
    TabSwitcherItem item;
    item.tab_id = id;
    const std::string& title =
        tab->custom_title ? *tab->custom_title : tab->title;
    item.title = base::UTF8ToUTF16(title.empty() ? tab->url : title);
    item.host = base::UTF8ToUTF16(HostWithoutWww(GURL(tab->url)));
    content::WebContents* contents =
        bridge ? bridge->WebContentsForTab(id) : nullptr;
    if (favicon::ContentFaviconDriver* driver =
            contents ? favicon::ContentFaviconDriver::FromWebContents(contents)
                     : nullptr;
        driver && driver->FaviconIsValid()) {
      item.favicon = driver->GetFavicon().AsImageSkia();
    } else {
      item.favicon = controller_->GetFavicon(id);
    }
    items.push_back(std::move(item));
  }
  return items;
}

void OpenWindowUi::TabSwitcherStep(bool reverse) {
  EnsureTabSwitcher();
  if (!switcher_) {
    return;
  }
  if (switcher_->is_active()) {
    switcher_->Advance(reverse);
    return;
  }
  std::vector<TabSwitcherItem> items = BuildSwitcherItems();
  if (items.size() < 2) {
    return;
  }
  switcher_->SetAppearance(CurrentAppearance());
  UpdateOverlayAnchors();
  switcher_->Begin(std::move(items), reverse);
  if (!switcher_->is_active() || switcher_monitor_ || !widget()) {
    return;
  }
  // Before the HUD shows (100 ms) the page has focus and gets the Ctrl
  // release; the monitor sees it first and forwards it to the HUD.
  switcher_monitor_ = views::EventMonitor::CreateWindowMonitor(
      this, widget()->GetNativeWindow(),
      {ui::EventType::kKeyPressed, ui::EventType::kKeyReleased});
}

void OpenWindowUi::TabSwitcherCommit() {
  if (switcher_) {
    switcher_->Commit();
  }
}

void OpenWindowUi::TabSwitcherCancel() {
  if (switcher_) {
    switcher_->Cancel();
  }
}

void OpenWindowUi::OnEvent(const ui::Event& event) {
  if (!event.IsKeyEvent() || !tab_switcher_active()) {
    return;
  }
  const ui::KeyEvent& key = *event.AsKeyEvent();
  // Presses while Ctrl is held arrive as accelerators (TabSwitcherStep);
  // the shown HUD has focus and handles its own keys. Releases, and Esc
  // before the HUD shows, go to the HUD here (it ignores repeats).
  const bool release = key.type() == ui::EventType::kKeyReleased;
  const bool early_escape = key.type() == ui::EventType::kKeyPressed &&
                            key.key_code() == ui::VKEY_ESCAPE &&
                            !switcher_->is_shown();
  if (release || early_escape) {
    switcher_->HandleKeyEvent(key);
  }
}

void OpenWindowUi::StopSwitcherMonitor() {
  // Not inside the monitor's own callback: drop it on the next task.
  base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce(
                     [](base::WeakPtr<OpenWindowUi> self) {
                       if (self && !self->tab_switcher_active()) {
                         self->switcher_monitor_.reset();
                       }
                     },
                     weak_factory_.GetWeakPtr()));
}

void OpenWindowUi::OnTabSwitcherVisibilityChanged(bool visible) {
  if (!switcher_host_) {
    return;
  }
  if (visible) {
    UpdateOverlayAnchors();
    switcher_host_->Show();
  } else {
    switcher_host_->Hide();
  }
}

void OpenWindowUi::OnTabSwitcherCommit(const ItemID& tab_id) {
  StopSwitcherMonitor();
  if (OpenTabBridge* bridge = service()->tab_bridge()) {
    bridge->SelectNode(tab_id);
  }
  FocusPage();
}

void OpenWindowUi::OnTabSwitcherCancel() {
  StopSwitcherMonitor();
  FocusPage();
}

// --- Accelerators --------------------------------------------------------------

void OpenWindowUi::RegisterAccelerators() {
  views::FocusManager* focus_manager = browser_view_->GetFocusManager();
  if (!focus_manager) {
    return;
  }
  focus_manager->UnregisterAccelerators(this);
  accelerator_commands_.clear();
  escape_registered_ = false;
  const CommandRegistry& commands = service()->commands();
  for (CommandId command : kWindowAcceleratorCommands) {
    for (const KeyboardShortcut& shortcut :
         commands.EffectiveShortcuts(command)) {
      std::optional<ui::Accelerator> accelerator = ToAccelerator(shortcut);
      if (!accelerator || accelerator_commands_.contains(*accelerator) ||
          (accelerator->key_code() == ui::VKEY_ESCAPE &&
           accelerator->modifiers() == ui::EF_NONE)) {
        continue;
      }
      accelerator_commands_.emplace(*accelerator, command);
      // High priority: ahead of Chromium's accelerator table (IDC_FIND,
      // IDC_SELECT_NEXT_TAB, IDC_NEW_TAB, ...) and, through
      // BrowserView::PreHandleKeyboardEvent, ahead of the page.
      focus_manager->RegisterAccelerator(
          *accelerator, ui::AcceleratorManager::kHighPriority, this);
    }
  }
  UpdateEscapeRegistration();
}

void OpenWindowUi::SetEscapeRegistered(bool registered) {
  views::FocusManager* focus_manager = browser_view_->GetFocusManager();
  if (!focus_manager || registered == escape_registered_) {
    return;
  }
  const ui::Accelerator escape(ui::VKEY_ESCAPE, ui::EF_NONE);
  if (registered) {
    focus_manager->RegisterAccelerator(
        escape, ui::AcceleratorManager::kHighPriority, this);
  } else {
    focus_manager->UnregisterAccelerator(escape, this);
  }
  escape_registered_ = registered;
}

void OpenWindowUi::UpdateEscapeRegistration() {
  // Esc belongs to the page except while an Open overlay shows.
  SetEscapeRegistered(command_bar_shown() || peek_shown() ||
                      find_bar_shown());
}

bool OpenWindowUi::RunShortcut(CommandId command) {
  switch (command) {
    case CommandId::kFind:
      if (!FindHelper()) {
        return false;  // Let Chromium handle it (e.g. a DevTools window).
      }
      ShowFindBar();
      return true;
    case CommandId::kFindNext:
    case CommandId::kFindPrevious:
      if (!FindHelper()) {
        return false;
      }
      FindNext(command == CommandId::kFindNext);
      return true;
    case CommandId::kTabSwitcherForward:
      TabSwitcherStep(/*reverse=*/false);
      return true;
    case CommandId::kTabSwitcherBackward:
      TabSwitcherStep(/*reverse=*/true);
      return true;
    case CommandId::kCopyUrl:
    case CommandId::kArchiveTab:
    case CommandId::kPinUnpinTab:
    case CommandId::kAddSplitView:
      // Page commands need a page; an empty window lets Chromium decide.
      if (!ActiveWebContents()) {
        return false;
      }
      return RunCommandId(command);
    default:
      return RunCommandId(command);
  }
}

bool OpenWindowUi::HandleFindCommand(CommandId command) {
  return RunShortcut(command);
}

bool OpenWindowUi::AcceleratorPressed(const ui::Accelerator& accelerator) {
  if (accelerator.key_code() == ui::VKEY_ESCAPE &&
      accelerator.modifiers() == ui::EF_NONE && escape_registered_) {
    // The topmost Open overlay takes Esc: Command Bar, then Peek, then the
    // find bar.
    if (command_bar_shown()) {
      views::FocusManager* focus_manager = browser_view_->GetFocusManager();
      views::View* focused =
          focus_manager ? focus_manager->GetFocusedView() : nullptr;
      if (focused && command_bar_->Contains(focused)) {
        // The bar's field handles Esc itself (IME composition first).
        return false;
      }
      command_bar_->Dismiss(CommandBarDismissReason::kEscape);
      return true;
    }
    if (peek_shown()) {
      OnPeekDismissed(PeekDismissReason::kEscape);
      return true;
    }
    if (find_bar_shown()) {
      CloseFindBar();
      return true;
    }
    UpdateEscapeRegistration();
    return false;
  }
  auto it = accelerator_commands_.find(accelerator);
  return it != accelerator_commands_.end() && RunShortcut(it->second);
}

bool OpenWindowUi::CanHandleAccelerators() const {
  return browser_view_ && browser_view_->GetWidget();
}

// --- Peek page delegate ---------------------------------------------------------

bool OpenWindowUi::HandleKeyboardEvent(
    content::WebContents* source,
    const input::NativeWebKeyboardEvent& event) {
  // Keys Peek's page did not consume go to the window's FocusManager, where
  // Peek's Esc and Cmd/Ctrl+O and Open's shortcuts are registered.
  views::FocusManager* focus_manager =
      browser_view_ ? browser_view_->GetFocusManager() : nullptr;
  return focus_manager && unhandled_keyboard_event_handler_.HandleKeyboardEvent(
                              event, focus_manager);
}

content::JavaScriptDialogManager* OpenWindowUi::GetJavaScriptDialogManager(
    content::WebContents* source) {
  // Created by TabHelpers::AttachTabHelpers() (hook 0010).
  return javascript_dialogs::TabModalDialogManager::FromWebContents(source);
}

web_modal::WebContentsModalDialogHost*
OpenWindowUi::GetWebContentsModalDialogHost(
    content::WebContents* web_contents) {
  BrowserWindowInterface* browser =
      browser_view_ ? browser_view_->browser() : nullptr;
  return browser ? browser->GetWebContentsModalDialogHostForWindow() : nullptr;
}

bool OpenWindowUi::IsWebContentsVisible(content::WebContents* web_contents) {
  return peek_shown() && web_contents == peek_contents_.get();
}

// --- Automation readback -----------------------------------------------------

base::DictValue OpenWindowUi::CommandBarState() const {
  base::DictValue state;
  state.Set("shown", command_bar_shown());
  if (!command_bar_) {
    return state;
  }
  state.Set("mode", static_cast<int>(command_bar_->mode()));
  state.Set("text", base::UTF16ToUTF8(command_bar_->typed_text()));
  state.Set("completion", base::UTF16ToUTF8(command_bar_->completion()));
  state.Set("selected", static_cast<int>(command_bar_->selected_index()));
  base::ListValue rows;
  for (const CommandBarRow& row : command_bar_->rows()) {
    rows.Append(base::DictValue()
                    .Set("id", row.id)
                    .Set("kind", RowKindName(row.kind))
                    .Set("title", base::UTF16ToUTF8(row.title))
                    .Set("subtitle", base::UTF16ToUTF8(row.subtitle))
                    .Set("badge", base::UTF16ToUTF8(row.badge))
                    .Set("url", row.url)
                    .Set("tab", row.tab_id.value_or(std::string()))
                    .Set("action", row.action_id));
  }
  state.Set("rows", std::move(rows));
  const gfx::Rect card = command_bar_->card_bounds();
  state.Set("card", base::ListValue()
                        .Append(card.x())
                        .Append(card.y())
                        .Append(card.width())
                        .Append(card.height()));
  return state;
}

base::DictValue OpenWindowUi::PeekState() const {
  base::DictValue state;
  state.Set("shown", peek_shown());
  if (peek_contents_) {
    state.Set("url", peek_contents_->GetVisibleURL().spec());
    state.Set("loading", peek_contents_->IsLoading());
  }
  if (peek_source_) {
    state.Set("source", *peek_source_);
  }
  if (peek_) {
    const gfx::Rect card = peek_->card_bounds();
    state.Set("card", base::ListValue()
                          .Append(card.x())
                          .Append(card.y())
                          .Append(card.width())
                          .Append(card.height()));
  }
  return state;
}

base::DictValue OpenWindowUi::SiteControlState() const {
  base::DictValue state;
  state.Set("shown", site_controls_shown());
  const open_unified::SiteControlState current = BuildSiteControlState();
  state.Set("host", base::UTF16ToUTF8(current.host));
  state.Set("secure", current.secure);
  state.Set("boostActive", current.boost_active);
  state.Set("adBlockAvailable", current.ad_block_available);
  state.Set("adBlockEnabled", current.ad_block_enabled);
  state.Set("adBlockBlocked", current.ad_block_blocked_count);
  base::ListValue extensions;
  for (const SiteControlExtensionItem& item : current.extensions) {
    extensions.Append(base::DictValue()
                          .Set("id", item.id)
                          .Set("name", base::UTF16ToUTF8(item.name))
                          .Set("enabled", item.enabled));
  }
  state.Set("extensions", std::move(extensions));
  return state;
}

base::DictValue OpenWindowUi::FindBarState() const {
  base::DictValue state;
  state.Set("shown", find_bar_shown());
  if (find_bar_) {
    state.Set("query", base::UTF16ToUTF8(find_bar_->query()));
  }
  if (const find_in_page::FindTabHelper* helper =
          find_observation_.GetSource()) {
    const find_in_page::FindNotificationDetails& result =
        helper->find_result();
    state.Set("matches", result.number_of_matches());
    state.Set("active", result.active_match_ordinal());
  }
  if (find_host_ && find_host_->widget()) {
    state.Set("frame",
              RectToList(find_host_->widget()->GetWindowBoundsInScreen()));
  }
  return state;
}

base::DictValue OpenWindowUi::ToastState() const {
  base::DictValue state;
  state.Set("shown", toast_host_ && toast_host_->IsVisible());
  state.Set("count", toasts_ ? static_cast<int>(toasts_->toast_count()) : 0);
  if (toast_host_ && toast_host_->widget()) {
    state.Set("frame",
              RectToList(toast_host_->widget()->GetWindowBoundsInScreen()));
  }
  return state;
}

base::DictValue OpenWindowUi::TabSwitcherState() const {
  base::DictValue state;
  state.Set("active", tab_switcher_active());
  state.Set("shown", switcher_ && switcher_->is_shown());
  base::ListValue mru;
  for (const ItemID& id : mru_) {
    mru.Append(id);
  }
  state.Set("mru", std::move(mru));
  return state;
}

// ===========================================================================
// OpenLittleOpenController
// ===========================================================================

OpenLittleOpenController::OpenLittleOpenController(
    OpenWindowController* owner,
    ProfileID profile_id,
    std::optional<SpaceID> target_space)
    : owner_(owner),
      profile_id_(std::move(profile_id)),
      target_space_(std::move(target_space)) {}

OpenLittleOpenController::~OpenLittleOpenController() {
  Observe(nullptr);
  // Open web-modal dialogs close with their host.
  for (web_modal::ModalDialogHostObserver& observer : modal_observers_) {
    observer.OnHostDestroying();
  }
  if (contents_) {
    if (auto* modal = web_modal::WebContentsModalDialogManager::FromWebContents(
            contents_.get())) {
      modal->SetDelegate(nullptr);
    }
    contents_->SetDelegate(nullptr);
  }
  bar_ = nullptr;
  // The window (and its WebView) goes before the page it shows.
  window_.reset();
  contents_.reset();
}

OpenBrowserService* OpenLittleOpenController::service() const {
  return owner_->service();
}

gfx::Rect OpenLittleOpenController::WorkArea() const {
  display::Screen* screen = display::Screen::Get();
  if (!screen) {
    return gfx::Rect(0, 0, 1280, 800);
  }
  // The display under the pointer (the global shortcut has no window).
  return screen->GetDisplayNearestPoint(screen->GetCursorScreenPoint())
      .work_area();
}

bool OpenLittleOpenController::Show(const std::optional<GURL>& url) {
  const bool page = url && url->is_valid();
  const gfx::Rect work_area = WorkArea();
  const gfx::Rect bar_bounds = OpenLittleOpenView::DefaultBarBounds(work_area);
  window_ = OpenLittleOpenWindow::Create(
      this,
      page ? OpenLittleOpenView::PageBoundsFromBar(bar_bounds, work_area)
           : bar_bounds,
      page ? OpenLittleOpenView::Mode::kPage : OpenLittleOpenView::Mode::kBar);
  if (!window_ || !window_->view()) {
    window_.reset();
    return false;
  }
  auto bar = std::make_unique<OpenCommandBarView>(this);
  bar_ = bar.get();
  window_->view()->SetBarContents(std::move(bar));
  UpdateState();
  window_->Show();
  if (page) {
    Navigate(*url);
  } else {
    EnterBarMode(std::u16string());
  }
  return true;
}

bool OpenLittleOpenController::is_page() const {
  return window_ && window_->view() &&
         window_->view()->mode() == OpenLittleOpenView::Mode::kPage;
}

void OpenLittleOpenController::Navigate(const GURL& url) {
  if (!url.is_valid() || !window_ || closing_) {
    return;
  }
  if (!contents_) {
    ::Profile* profile = service()->ChromeProfileFor(profile_id_);
    if (!profile) {
      return;
    }
    contents_ =
        content::WebContents::Create(content::WebContents::CreateParams(profile));
    AttachOverlayPageHelpers(contents_.get());
    // Unhandled keys (Cmd/Ctrl+O) reach the Little Open window; JavaScript
    // dialogs show inside it.
    contents_->SetDelegate(this);
    if (auto* modal = web_modal::WebContentsModalDialogManager::FromWebContents(
            contents_.get())) {
      modal->SetDelegate(this);
    }
    Observe(contents_.get());
  }
  contents_->GetController().LoadURLWithParams(
      content::NavigationController::LoadURLParams(url));
  EnterPageMode();
}

void OpenLittleOpenController::EnterBarMode(
    const std::u16string& initial_text) {
  if (!window_ || !bar_ || closing_) {
    return;
  }
  OpenLittleOpenView* view = window_->view();
  views::Widget* widget = window_->widget();
  if (view->mode() == OpenLittleOpenView::Mode::kPage) {
    // Editing the URL: the bar takes the page window's top-right corner and
    // the page bounds come back after.
    const gfx::Rect page = widget->GetWindowBoundsInScreen();
    page_bounds_ = page;
    const gfx::Size bar = little_open_metrics::kBarSize;
    widget->SetBounds(
        gfx::Rect(page.right() - bar.width(), page.y(), bar.width(),
                  bar.height()));
  }
  view->SetMode(OpenLittleOpenView::Mode::kBar);
  CommandBarRequest request;
  request.mode = CommandBarMode::kLittleOpen;
  request.initial_text = initial_text;
  request.appearance.dark = owner_->IsSystemDarkMode();
  bar_->Present(request);
}

void OpenLittleOpenController::EnterPageMode() {
  if (!window_ || closing_) {
    return;
  }
  OpenLittleOpenView* view = window_->view();
  views::Widget* widget = window_->widget();
  if (view->mode() == OpenLittleOpenView::Mode::kBar) {
    widget->SetBounds(page_bounds_.value_or(OpenLittleOpenView::PageBoundsFromBar(
        widget->GetWindowBoundsInScreen(), WorkArea())));
    page_bounds_.reset();
  }
  view->SetMode(OpenLittleOpenView::Mode::kPage);
  view->SetWebContents(contents_.get());
  UpdateState();
  if (contents_) {
    contents_->Focus();
  }
  for (web_modal::ModalDialogHostObserver& observer : modal_observers_) {
    observer.OnPositionRequiresUpdate();
  }
}

void OpenLittleOpenController::Close() {
  if (closing_) {
    return;
  }
  closing_ = true;
  if (window_ && window_->widget()) {
    window_->widget()->Close();  // OnLittleOpenClosed() follows.
    return;
  }
  base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce(&OpenLittleOpenController::OnLittleOpenClosed,
                                weak_factory_.GetWeakPtr()));
}

std::optional<SpaceID> OpenLittleOpenController::DefaultTargetSpace() const {
  const BrowserModel& model = service()->model();
  if (target_space_ && model.FindSpace(*target_space_)) {
    return target_space_;
  }
  if (std::optional<SpaceID> focused =
          model_util::FocusedSpace(model, service()->MainWindowId())) {
    if (const Space* space = model.FindSpace(*focused);
        space && space->profile_id == profile_id_) {
      return focused;
    }
  }
  for (const Space& space : model.spaces()) {
    if (space.profile_id == profile_id_) {
      return space.id;
    }
  }
  return std::nullopt;
}

void OpenLittleOpenController::UpdateState() {
  if (!window_ || !window_->view() || closing_) {
    return;
  }
  const BrowserModel& model = service()->model();
  LittleOpenState state;
  if (contents_) {
    state.host = base::UTF8ToUTF16(HostWithoutWww(contents_->GetVisibleURL()));
  }
  if (const Profile* profile = model.FindProfile(profile_id_)) {
    state.profile_name = base::UTF8ToUTF16(profile->name);
    state.profile_icon = profile->icon;
  }
  state.show_profile = model.profiles().size() > 1;
  if (std::optional<SpaceID> target = DefaultTargetSpace()) {
    if (const Space* space = model.FindSpace(*target)) {
      state.space_title = SpaceTitle(*space);
    }
  }
  // Spaces of the page's Profile (its cookies and logins stay valid).
  for (const Space& space : model.spaces()) {
    if (space.profile_id != profile_id_) {
      continue;
    }
    LittleOpenSpaceChoice choice;
    choice.id = space.id;
    choice.title = SpaceTitle(space);
    choice.icon = space.icon;
    if (space.theme.accent) {
      choice.color = ToSkColor(*space.theme.accent);
    } else if (space.theme.style) {
      choice.color = ToSkColor(space.theme.style->key_color);
    }
    state.spaces.push_back(std::move(choice));
  }
  // Little Open pages have no extension actions yet.
  state.show_extensions = false;
  window_->view()->SetState(state);
}

base::DictValue OpenLittleOpenController::State() const {
  base::DictValue state;
  state.Set("mode", is_page() ? "page" : "bar");
  state.Set("profile_id", profile_id_);
  state.Set("closing", closing_);
  if (contents_) {
    state.Set("url", contents_->GetVisibleURL().spec());
    state.Set("loading", contents_->IsLoading());
  }
  if (std::optional<SpaceID> target = DefaultTargetSpace()) {
    state.Set("target_space_id", *target);
  }
  if (bar_) {
    state.Set("bar_text", base::UTF16ToUTF8(bar_->typed_text()));
    state.Set("bar_rows", static_cast<int>(bar_->rows().size()));
  }
  if (window_ && window_->widget() && !closing_) {
    state.Set("frame",
              RectToList(window_->widget()->GetWindowBoundsInScreen()));
  }
  return state;
}

// --- LittleOpenDelegate --------------------------------------------------------

void OpenLittleOpenController::OnLittleOpenOpenInSpace(
    std::optional<SpaceID> space_id) {
  const std::optional<SpaceID> target =
      space_id ? space_id : DefaultTargetSpace();
  GURL url;
  if (contents_) {
    url = contents_->GetLastCommittedURL().is_valid()
              ? contents_->GetLastCommittedURL()
              : contents_->GetVisibleURL();
  }
  OpenWindowController* owner = owner_;
  OpenTabBridge* bridge = service()->tab_bridge();
  Close();
  if (!url.is_valid() || !bridge) {
    return;
  }
  // A fresh Today tab at the page's URL (as Peek's expand): OpenTabBridge
  // stays the single owner of sidebar WebContents. Form state and scroll
  // position do not carry over yet.
  if (target) {
    bridge->FocusSpace(*target);
  }
  bridge->OpenTab(url, /*background=*/false);
  if (OpenWindowUi* ui = owner->MainWindowUi()) {
    ui->ActivateWindow();
  }
}

void OpenLittleOpenController::OnLittleOpenEditUrl() {
  EnterBarMode(contents_ ? base::UTF8ToUTF16(contents_->GetVisibleURL().spec())
                         : std::u16string());
}

void OpenLittleOpenController::OnLittleOpenCopyUrl() {
  if (contents_) {
    ui::ScopedClipboardWriter(ui::ClipboardBuffer::kCopyPaste)
        .WriteText(base::UTF8ToUTF16(contents_->GetVisibleURL().spec()));
  }
}

void OpenLittleOpenController::OnLittleOpenProfile(views::View* anchor) {
  // The page keeps the Profile it was opened in (Air Traffic Control or the
  // active one); a Profile switch reopens it elsewhere (not wired yet).
}

void OpenLittleOpenController::OnLittleOpenExtensions(views::View* anchor) {
  // Hidden: UpdateState() sets show_extensions = false.
}

void OpenLittleOpenController::OnLittleOpenClosed() {
  closing_ = true;
  owner_->OnLittleOpenClosed(this);  // Deletes this object.
}

// --- CommandBarDelegate (Little Open's bar) ------------------------------------

CommandBarResults OpenLittleOpenController::QuerySuggestions(
    const CommandBarQuery& query) {
  return QueryCommandBar(service(), query, profile_id_, DefaultTargetSpace(),
                         /*current_tab=*/std::nullopt);
}

std::optional<CommandBarScopeTarget>
OpenLittleOpenController::ResolveSiteSearch(std::u16string_view text,
                                            bool exact_keyword_only) {
  return ResolveSiteSearchFor(service(), profile_id_, text,
                              exact_keyword_only);
}

void OpenLittleOpenController::OnCommandBarIntent(
    const CommandBarIntent& intent) {
  const CommandBarRow& row = intent.row;
  switch (row.kind) {
    case CommandBarRowKind::kSwitchToTab:
    case CommandBarRowKind::kSwitchToSplit:
      // The tab lives in the main window: go there.
      if (row.tab_id) {
        if (OpenTabBridge* bridge = service()->tab_bridge()) {
          bridge->SelectNode(*row.tab_id);
        }
        if (OpenWindowUi* ui = owner_->MainWindowUi()) {
          ui->ActivateWindow();
        }
      }
      Close();
      return;
    case CommandBarRowKind::kAction:
      if (OpenWindowUi* ui = owner_->MainWindowUi()) {
        ui->ActivateWindow();
        ui->RunCommand(row.action_id);
      }
      Close();
      return;
    case CommandBarRowKind::kCalculator:
      ui::ScopedClipboardWriter(ui::ClipboardBuffer::kCopyPaste)
          .WriteText(row.title);
      return;
    default:
      break;
  }
  // Every disposition stays in Little Open: the page is the window.
  Navigate(UrlForCommandBarIntent(intent));
}

void OpenLittleOpenController::OnCommandBarDismissed(
    CommandBarDismissReason reason,
    std::optional<gfx::Point> click_location) {
  switch (reason) {
    case CommandBarDismissReason::kCommitted:
    case CommandBarDismissReason::kProgrammatic:
      return;
    case CommandBarDismissReason::kCloseButton:
      Close();
      return;
    case CommandBarDismissReason::kEscape:
    case CommandBarDismissReason::kClickOutside:
      // Esc while editing the URL goes back to the page; on the empty bar it
      // closes Little Open.
      if (contents_) {
        EnterPageMode();
      } else {
        Close();
      }
      return;
  }
}

// --- content::WebContentsObserver ----------------------------------------------

void OpenLittleOpenController::DidFinishNavigation(
    content::NavigationHandle* navigation_handle) {
  if (!navigation_handle->IsInPrimaryMainFrame() ||
      !navigation_handle->HasCommitted()) {
    return;
  }
  UpdateState();
  const GURL& url = navigation_handle->GetURL();
  if (navigation_handle->IsSameDocument() || navigation_handle->IsErrorPage() ||
      !url.SchemeIsHTTPOrHTTPS() ||
      contents_->GetBrowserContext()->IsOffTheRecord()) {
    return;
  }
  service()->RecordVisit(profile_id_, url.spec(),
                         base::UTF16ToUTF8(contents_->GetTitle()),
                         /*typed=*/false);
}

// --- Page delegate and web-modal host ------------------------------------------

bool OpenLittleOpenController::HandleKeyboardEvent(
    content::WebContents* source,
    const input::NativeWebKeyboardEvent& event) {
  views::Widget* widget = window_ ? window_->widget() : nullptr;
  views::FocusManager* focus_manager =
      widget ? widget->GetFocusManager() : nullptr;
  return focus_manager && unhandled_keyboard_event_handler_.HandleKeyboardEvent(
                              event, focus_manager);
}

content::JavaScriptDialogManager*
OpenLittleOpenController::GetJavaScriptDialogManager(
    content::WebContents* source) {
  return javascript_dialogs::TabModalDialogManager::FromWebContents(source);
}

web_modal::WebContentsModalDialogHost*
OpenLittleOpenController::GetWebContentsModalDialogHost(
    content::WebContents* web_contents) {
  return window_ && window_->widget() ? this : nullptr;
}

bool OpenLittleOpenController::IsWebContentsVisible(
    content::WebContents* web_contents) {
  return !closing_ && is_page() && window_->widget()->IsVisible();
}

gfx::NativeView OpenLittleOpenController::GetHostView() const {
  return window_ && window_->widget() ? window_->widget()->GetNativeView()
                                      : gfx::NativeView();
}

gfx::Point OpenLittleOpenController::GetDialogPosition(const gfx::Size& size) {
  // Centered at the top of the page, as Chromium's tab-modal dialogs.
  const gfx::Size max = GetMaximumDialogSize();
  return gfx::Point(std::max(0, (max.width() - size.width()) / 2), 0);
}

gfx::Size OpenLittleOpenController::GetMaximumDialogSize() {
  views::Widget* widget = window_ ? window_->widget() : nullptr;
  return widget ? widget->GetClientAreaBoundsInScreen().size() : gfx::Size();
}

void OpenLittleOpenController::AddObserver(
    web_modal::ModalDialogHostObserver* observer) {
  modal_observers_.AddObserver(observer);
}

void OpenLittleOpenController::RemoveObserver(
    web_modal::ModalDialogHostObserver* observer) {
  modal_observers_.RemoveObserver(observer);
}

}  // namespace open_unified
