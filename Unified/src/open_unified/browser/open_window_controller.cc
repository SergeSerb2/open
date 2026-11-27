// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "open_unified/browser/open_window_controller.h"

#include <algorithm>
#include <cmath>
#include <set>
#include <utility>

#include "base/callback_list.h"
#include "base/command_line.h"
#include "base/environment.h"
#include "base/functional/bind.h"
#include "base/functional/callback_helpers.h"
#include "base/strings/escape.h"
#include "base/strings/strcat.h"
#include "base/strings/string_util.h"
#include "base/strings/utf_string_conversions.h"
#include "base/system/sys_info.h"
#include "base/task/bind_post_task.h"
#include "base/task/sequenced_task_runner.h"
#include "base/time/time.h"
#include "base/uuid.h"
#include "base/version_info/version_info.h"
#include "build/build_config.h"
#include "chrome/app/chrome_command_ids.h"
#include "chrome/browser/content_settings/host_content_settings_map_factory.h"
#include "chrome/browser/lifetime/application_lifetime.h"
#include "chrome/browser/platform_util.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/ui/browser_commands.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/simple_message_box.h"
#include "chrome/browser/ui/views/frame/browser_view.h"
#include "components/content_settings/core/browser/host_content_settings_map.h"
#include "components/content_settings/core/common/content_settings.h"
#include "components/content_settings/core/common/content_settings_types.h"
#include "components/favicon/content/content_favicon_driver.h"
#include "components/find_in_page/find_tab_helper.h"
#include "components/find_in_page/find_types.h"
#include "components/input/native_web_keyboard_event.h"
#include "components/javascript_dialogs/tab_modal_dialog_manager.h"
#include "components/viz/common/frame_sinks/copy_output_result.h"
#include "components/web_modal/web_contents_modal_dialog_manager.h"
#include "content/public/browser/browser_context.h"
#include "content/public/browser/context_menu_params.h"
#include "content/public/browser/navigation_controller.h"
#include "content/public/browser/navigation_handle.h"
#include "content/public/browser/page_navigator.h"
#include "content/public/browser/render_widget_host_view.h"
#include "content/public/browser/storage_partition.h"
#include "content/public/browser/web_contents.h"
#include "open_unified/browser/open_boost_controller.h"
#include "open_unified/browser/open_browser_service.h"
#include "open_unified/browser/open_capture_controller.h"
#include "open_unified/browser/open_chromium_hooks.h"
#include "open_unified/browser/open_download_bridge.h"
#include "open_unified/browser/open_json.h"
#include "open_unified/browser/open_media_bridge.h"
#include "open_unified/browser/open_model_util.h"
#include "open_unified/browser/open_switches.h"
#include "open_unified/browser/open_translate_controller.h"
#include "open_unified/browser/open_updater_service.h"
#include "open_unified/browser/platform/open_handoff.h"
#include "open_unified/browser/platform/open_platform.h"
#include "open_unified/core/adblock/open_adblock_profile_service.h"
#include "open_unified/core/commands/command_registry.h"
#include "open_unified/core/documents/document_store.h"
#include "open_unified/core/livedata/open_livedata_service.h"
#include "open_unified/core/routing/routing_evaluator.h"
#include "open_unified/core/store/sqlite_stores.h"
#include "open_unified/core/suggest/suggest_engine.h"
#include "open_unified/core/sync/sync_engine.h"
#include "open_unified/ui/design/open_metrics.h"
#include "open_unified/ui/views/open_sidebar_view.h"
#include "open_unified/ui/views/open_tab_tree_view.h"
#include "open_unified/ui/views/open_window_controls_view.h"
#include "open_unified/ui/webui/open_boosts_ui.h"
#include "open_unified/ui/webui/open_ipc_contract.h"
#include "open_unified/ui/webui/open_library_ui.h"
#include "open_unified/ui/webui/open_onboarding_ui.h"
#include "open_unified/ui/webui/open_settings_ui.h"
#include "open_unified/ui/webui/open_webui_config.h"
#include "services/network/public/cpp/shared_url_loader_factory.h"
#include "third_party/skia/include/core/SkColor.h"
#include "ui/base/accelerators/accelerator_manager.h"
#include "ui/base/clipboard/scoped_clipboard_writer.h"
#include "ui/base/hit_test.h"
#include "ui/base/metadata/metadata_header_macros.h"
#include "ui/base/metadata/metadata_impl_macros.h"
#include "ui/base/page_transition_types.h"
#include "ui/base/ui_base_types.h"
#include "ui/compositor/layer.h"
#include "ui/display/display.h"
#include "ui/display/screen.h"
#include "ui/events/event.h"
#include "ui/events/keycodes/keyboard_codes.h"
#include "ui/gfx/geometry/rect.h"
#include "ui/gfx/geometry/rounded_corners_f.h"
#include "ui/gfx/image/image_skia.h"
#include "ui/native_theme/native_theme.h"
#include "ui/views/controls/native/native_view_host.h"
#include "ui/views/controls/textfield/textfield.h"
#include "ui/views/controls/webview/webview.h"
#include "ui/views/event_monitor.h"
#include "ui/views/focus/focus_manager.h"
#include "ui/views/layout/fill_layout.h"
#include "ui/views/view_utils.h"
#include "ui/views/widget/widget.h"
#include "ui/views/widget/widget_delegate.h"
#include "ui/views/window/frame_view.h"
#include "url/gurl.h"
#include "url/origin.h"

namespace open_unified {

namespace {

constexpr gfx::Size kSettingsWindowDefaultSize{960, 660};
constexpr gfx::Size kSettingsWindowMinSize{800, 540};
constexpr gfx::Size kFirstRunWindowSize{860, 620};
constexpr int kLibraryDrawerExtraWidth = 417;

// Seeds longer than this are cut (docs/re/page-chrome.md §1).
constexpr size_t kFindSeedMaxLength = 40;
// MRU entries kept per window, and HUD items offered.
constexpr size_t kMruLimit = 64;
constexpr size_t kSwitcherItemLimit = 32;
constexpr base::TimeDelta kThumbnailCopyTimeout = base::Seconds(2);

constexpr char kEventLibraryCloseRequested[] = "open.libraryCloseRequested";
constexpr char kEventLibrarySetSpaceTheme[] = "library.setSpaceTheme";
constexpr char kChromeWebStoreUrl[] = "https://chromewebstore.google.com/";
constexpr char kExtensionActionPrefix[] = "extension-action:";

SkColor ToSkColor(const RGBAColor& c) {
  return SkColorSetARGB(static_cast<U8CPU>(c.a * 255.0 + 0.5),
                        static_cast<U8CPU>(c.r * 255.0 + 0.5),
                        static_cast<U8CPU>(c.g * 255.0 + 0.5),
                        static_cast<U8CPU>(c.b * 255.0 + 0.5));
}

theme::ContentAppearance ToContentAppearance(bool dark) {
  return dark ? theme::ContentAppearance::kDark
              : theme::ContentAppearance::kLight;
}

bool PrefBool(const std::string& key, bool default_value) {
  const base::Value v = webui::OpenPreferences::Get()->GetValue(key);
  return v.is_bool() ? v.GetBool() : default_value;
}

bool IsAutomationLaunch() {
  const base::CommandLine* cmd = base::CommandLine::ForCurrentProcess();
  if (cmd && (cmd->HasSwitch(switches::kAutomationSocket) ||
              cmd->HasSwitch(switches::kAutomationPort))) {
    return true;
  }
  auto env = base::Environment::Create();
  return env && env->HasVar(switches::kAutomationSocketEnv);
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
      if (auto ext = ExtensionIdFromScopeId(site)) {
        return SuggestScope::Extension(*ext);
      }
      return SuggestScope::SiteSearch(site);
    case CommandBarScope::kNone:
      return SuggestScope::All();
  }
  return SuggestScope::All();
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

// Index 0..8 of a Go to Tab / Go to Space / Focus Split Pane command, or -1.
int GoToTabIndex(CommandId command) {
  const int n =
      static_cast<int>(command) - static_cast<int>(CommandId::kGoToTab1);
  return n >= 0 && n < 9 ? n : -1;
}

int GoToSpaceIndex(CommandId command) {
  const int n =
      static_cast<int>(command) - static_cast<int>(CommandId::kGoToSpace1);
  return n >= 0 && n < 9 ? n : -1;
}

int FocusSplitPaneIndex(CommandId command) {
  const int n =
      static_cast<int>(command) - static_cast<int>(CommandId::kFocusSplitPane1);
  return n >= 0 && n < 4 ? n : -1;
}

std::optional<CommandId> MapMenuOrChromiumCommandToOpen(int command_id) {
  if (command_id >= hooks::kOpenMenuCommandIdBase &&
      command_id <= hooks::kOpenMenuCommandIdMax) {
    const int raw = command_id - hooks::kOpenMenuCommandIdBase;
    if (raw > static_cast<int>(CommandId::kUnknown) &&
        raw < static_cast<int>(CommandId::kCommandIdCount)) {
      return static_cast<CommandId>(raw);
    }
    return std::nullopt;
  }
  switch (command_id) {
    case IDC_NEW_TAB:
      return CommandId::kNewTab;
    case IDC_CLOSE_TAB:
      return CommandId::kArchiveTab;
    case IDC_NEW_WINDOW:
      return CommandId::kNewWindow;
    case IDC_NEW_INCOGNITO_WINDOW:
      return CommandId::kNewIncognitoWindow;
    case IDC_RESTORE_TAB:
      return CommandId::kRestoreLastClosedTab;
    case IDC_FOCUS_LOCATION:
      return CommandId::kOpenCommandBar;
    case IDC_SAVE_PAGE:
      return CommandId::kToggleSidebar;
    case IDC_BOOKMARK_THIS_TAB:
      return CommandId::kPinUnpinTab;
    case IDC_SHOW_HISTORY:
      return CommandId::kViewHistory;
    case IDC_SHOW_DOWNLOADS:
      return CommandId::kViewDownloads;
    case IDC_OPTIONS:
      return CommandId::kSettings;
    case IDC_FIND:
      return CommandId::kFind;
    case IDC_FIND_NEXT:
      return CommandId::kFindNext;
    case IDC_FIND_PREVIOUS:
      return CommandId::kFindPrevious;
    case IDC_SELECT_NEXT_TAB:
      return CommandId::kNextTab;
    case IDC_SELECT_PREVIOUS_TAB:
      return CommandId::kPreviousTab;
    case IDC_CYCLE_TO_NEXT_TAB:
      return CommandId::kTabSwitcherForward;
    case IDC_CYCLE_TO_PREV_TAB:
      return CommandId::kTabSwitcherBackward;
    case IDC_DUPLICATE_TAB:
      return CommandId::kDuplicateTab;
    case IDC_RELOAD:
      return CommandId::kReload;
    case IDC_RELOAD_BYPASSING_CACHE:
      return CommandId::kForceReload;
    case IDC_STOP:
      return CommandId::kStopLoading;
    case IDC_BACK:
      return CommandId::kGoBack;
    case IDC_FORWARD:
      return CommandId::kGoForward;
    case IDC_COPY_URL:
      return CommandId::kCopyUrl;
    case IDC_FULLSCREEN:
      return CommandId::kToggleFullScreen;
    case IDC_PRINT:
      return CommandId::kPrint;
    case IDC_ZOOM_PLUS:
      return CommandId::kZoomIn;
    case IDC_ZOOM_MINUS:
      return CommandId::kZoomOut;
    case IDC_ZOOM_NORMAL:
      return CommandId::kZoomActualSize;
    case IDC_DEV_TOOLS:
      return CommandId::kDeveloperTools;
    case IDC_DEV_TOOLS_CONSOLE:
      return CommandId::kJavaScriptConsole;
    case IDC_DEV_TOOLS_INSPECT:
      return CommandId::kInspectElements;
    case IDC_VIEW_SOURCE:
      return CommandId::kViewSource;
    case IDC_MANAGE_EXTENSIONS:
      return CommandId::kManageExtensions;
    case IDC_IMPORT_SETTINGS:
      return CommandId::kImportFromBrowser;
    case IDC_TASK_MANAGER:
    case IDC_TASK_MANAGER_MAIN_MENU:
      return CommandId::kTaskManager;
    case IDC_ROUTE_MEDIA:
      return CommandId::kCast;
    case IDC_TOGGLE_JAVASCRIPT_APPLE_EVENTS:
      return CommandId::kAllowJsAppleEvents;
    case IDC_SELECT_TAB_0:
      return CommandId::kGoToTab1;
    case IDC_SELECT_TAB_1:
      return CommandId::kGoToTab2;
    case IDC_SELECT_TAB_2:
      return CommandId::kGoToTab3;
    case IDC_SELECT_TAB_3:
      return CommandId::kGoToTab4;
    case IDC_SELECT_TAB_4:
      return CommandId::kGoToTab5;
    case IDC_SELECT_TAB_5:
      return CommandId::kGoToTab6;
    case IDC_SELECT_TAB_6:
      return CommandId::kGoToTab7;
    case IDC_SELECT_TAB_7:
      return CommandId::kGoToTab8;
    case IDC_SELECT_LAST_TAB:
      return CommandId::kGoToTab9;
    default:
      return std::nullopt;
  }
}

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
      case '+':
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
      {"tab", ui::VKEY_TAB},       {"escape", ui::VKEY_ESCAPE},
      {"esc", ui::VKEY_ESCAPE},    {"return", ui::VKEY_RETURN},
      {"enter", ui::VKEY_RETURN},  {"space", ui::VKEY_SPACE},
      {"left", ui::VKEY_LEFT},     {"right", ui::VKEY_RIGHT},
      {"up", ui::VKEY_UP},         {"down", ui::VKEY_DOWN},
      {"delete", ui::VKEY_DELETE}, {"backspace", ui::VKEY_BACK},
      {"home", ui::VKEY_HOME},     {"end", ui::VKEY_END},
      {"pageup", ui::VKEY_PRIOR},  {"pagedown", ui::VKEY_NEXT},
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

SkColor SpacePrimaryColor(const Space& space) {
  if (space.theme.accent) {
    return ToSkColor(*space.theme.accent);
  }
  if (space.theme.style) {
    return ToSkColor(space.theme.style->key_color);
  }
  return SkColorSetRGB(0x6F, 0x66, 0xD9);
}

bool SpacePrefersDark(const Space& space, bool system_dark) {
  if (space.theme.style) {
    if (space.theme.style->appearance == ThemeAppearance::kDark) {
      return true;
    }
    if (space.theme.style->appearance == ThemeAppearance::kLight) {
      return false;
    }
  }
  return system_dark;
}

std::string AppendSpaceThemeQuery(std::string base_url,
                                  const Space* space,
                                  bool system_dark,
                                  const std::string& extra_query) {
  std::vector<std::string> params;
  if (!extra_query.empty()) {
    params.push_back(extra_query);
  }
  if (space) {
    const bool dark = SpacePrefersDark(*space, system_dark);
    const base::DictValue palette =
        webui::OpenLibraryUI::SpaceThemePayload(*space, dark);
    for (const char* key : {"bg", "fg", "accent", "surface"}) {
      if (const std::string* val = palette.FindString(key);
          val && !val->empty()) {
        params.push_back(base::StrCat(
            {key, "=", base::EscapeQueryParamValue(*val, /*use_plus=*/false)}));
      }
    }
    if (const std::string* mode = palette.FindString("mode");
        mode && !mode->empty()) {
      params.push_back(base::StrCat({"theme_mode=", *mode}));
    }
  }
  if (params.empty()) {
    return base_url;
  }
  const char sep = base_url.find('?') == std::string::npos ? '?' : '&';
  return base::StrCat({base_url, std::string(1, sep),
                       base::JoinString(params, "&")});
}

bool ProfileAllowsRemoteSuggest(OpenBrowserService* s,
                                const ProfileID& profile_id,
                                bool is_incognito) {
  if (!s || is_incognito) {
    return false;
  }
  const Profile* profile = s->model().FindProfile(profile_id);
  return profile ? profile->settings.search_suggest_enabled : true;
}

SuggestContext BuildSuggestContext(OpenBrowserService* s,
                                   const CommandBarQuery& query,
                                   const ProfileID& profile_id,
                                   const std::optional<SpaceID>& space_id,
                                   const std::optional<ItemID>& current_tab,
                                   bool is_incognito) {
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
  context.allows_remote_suggestions =
      ProfileAllowsRemoteSuggest(s, profile_id, is_incognito);
  context.max_results = command_bar_metrics::kMaxRows;
  return context;
}

// One Command Bar query through Track 2's SuggestEngine (main window bar and
// Little Open's bar).
CommandBarResults QueryCommandBar(OpenBrowserService* s,
                                  const CommandBarQuery& query,
                                  const ProfileID& profile_id,
                                  const std::optional<SpaceID>& space_id,
                                  const std::optional<ItemID>& current_tab,
                                  bool is_incognito) {
  const SuggestContext context = BuildSuggestContext(
      s, query, profile_id, space_id, current_tab, is_incognito);
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
      break;
    }
  }
  results.rows = CommandBarRowsFromSuggestions(result.suggestions);
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

// The page a navigate/search/history row (or bare typed text) opens, honoring
// the Profile's configured search engine via SuggestEngine::SearchUrlFor().
GURL UrlForCommandBarIntent(OpenBrowserService* s,
                            const ProfileID& profile_id,
                            const CommandBarIntent& intent) {
  GURL url(intent.row.url);
  if (url.is_valid()) {
    return url;
  }
  const std::string typed = base::UTF16ToUTF8(intent.typed_text);
  if (std::optional<std::string> classified =
          SuggestEngine::ClassifyTypedUrl(typed)) {
    return GURL(*classified);
  }
  if (!typed.empty()) {
    SuggestContext ctx;
    ctx.profile_id = profile_id;
    ctx.scope = ToSuggestScope(intent.scope, intent.site_search_id);
    if (s) {
      if (const Profile* profile = s->model().FindProfile(profile_id)) {
        ctx.search_engine_id = profile->settings.search_engine_id;
      }
      return GURL(s->suggest().SearchUrlFor(typed, ctx));
    }
  }
  return GURL();
}

scoped_refptr<network::SharedURLLoaderFactory> URLLoaderFactoryForProfile(
    OpenBrowserService* s,
    const ProfileID& profile_id) {
  if (!s) {
    return nullptr;
  }
  ::Profile* chrome_profile = s->ChromeProfileFor(profile_id);
  if (!chrome_profile) {
    return nullptr;
  }
  content::StoragePartition* partition =
      chrome_profile->GetDefaultStoragePartition();
  return partition ? partition->GetURLLoaderFactoryForBrowserProcess()
                   : nullptr;
}

// Pages Open shows outside the tab strip (Peek, Little Open) get the full
// tab helper set through hook 0010 (TabHelpers::AttachTabHelpers(): find in
// page, JavaScript dialogs, permission prompts, autofill, ...), plus Open's
// ad-block counter. Sidebar tabs get the same set through TabStripModel.
void AttachOverlayPageHelpers(content::WebContents* contents) {
  if (!contents) {
    return;
  }
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

void CollectFolderIds(const std::vector<SidebarNode>& nodes,
                      std::vector<ItemID>* out) {
  for (const SidebarNode& node : nodes) {
    if (const Folder* folder = node.as_folder()) {
      out->push_back(folder->id);
      CollectFolderIds(folder->children, out);
    }
  }
}

void CollectTabUrls(const std::vector<SidebarNode>& nodes,
                    std::vector<std::pair<std::string, std::string>>* out) {
  for (const SidebarNode& node : nodes) {
    if (const Tab* tab = node.as_tab()) {
      out->emplace_back(tab->display_title(), tab->url);
    } else if (const Folder* folder = node.as_folder()) {
      CollectTabUrls(folder->children, out);
    } else if (const Split* split = node.as_split()) {
      for (const Tab& pane : split->panes) {
        out->emplace_back(pane.display_title(), pane.url);
      }
    }
  }
}

bool SpaceContainsLiveFolder(const Space& space) {
  auto has_live = [](const auto& self,
                     const std::vector<SidebarNode>& nodes) -> bool {
    for (const SidebarNode& node : nodes) {
      if (const Folder* folder = node.as_folder()) {
        if (folder->live.has_value()) {
          return true;
        }
        if (self(self, folder->children)) {
          return true;
        }
      }
    }
    return false;
  };
  return has_live(has_live, space.pinned) || has_live(has_live, space.today);
}

bool IsMailUrl(std::string_view raw_url) {
  const GURL url(raw_url);
  if (!url.is_valid() || !url.SchemeIsHTTPOrHTTPS()) {
    return false;
  }
  std::string host = base::ToLowerASCII(url.host());
  if (base::StartsWith(host, "www.")) {
    host.erase(0, 4);
  }
  return host == "mail.google.com" || host == "outlook.live.com" ||
         host == "outlook.office.com" || host == "outlook.office365.com" ||
         host == "mail.proton.me" || host == "app.fastmail.com" ||
         host == "mail.hey.com" || host == "mail.yahoo.com";
}

views::View* FindDescendantByScreenRect(views::View* root,
                                        const gfx::Rect& target) {
  if (!root || !root->GetVisible()) {
    return nullptr;
  }
  if (root->GetBoundsInScreen() == target) {
    return root;
  }
  for (views::View* child : root->children()) {
    if (views::View* found = FindDescendantByScreenRect(child, target)) {
      return found;
    }
  }
  return nullptr;
}

// Container view with explicit default and minimum size for standalone WebUI windows.
class MinSizeWebContainer : public views::View {
 public:
  MinSizeWebContainer(gfx::Size default_size,
                      gfx::Size min_size,
                      std::unique_ptr<views::WebView> web_view,
                      float corner_radius = 0.f,
                      int hit_test_top_inset = 0)
      : default_size_(default_size),
        min_size_(min_size),
        corner_radius_(corner_radius),
        hit_test_top_inset_(hit_test_top_inset) {
    SetLayoutManager(std::make_unique<views::FillLayout>());
    web_view_ = AddChildView(std::move(web_view));
  }
  ~MinSizeWebContainer() override = default;

  views::WebView* web_view() const { return web_view_; }

  gfx::Size CalculatePreferredSize(
      const views::SizeBounds& /*available_size*/) const override {
    return default_size_;
  }

  gfx::Size GetMinimumSize() const override { return min_size_; }

  void Layout(PassKey) override {
    LayoutSuperclass<views::View>(this);
    ApplyNativeViewEffects();
  }

  void ApplyNativeViewEffects() {
    if (!web_view_ || !web_view_->holder()) {
      return;
    }
    if (corner_radius_ > 0.f) {
      web_view_->holder()->SetNativeViewCornerRadii(
          gfx::RoundedCornersF(corner_radius_));
    }
    if (hit_test_top_inset_ > 0) {
      web_view_->holder()->SetHitTestTopInset(hit_test_top_inset_);
    }
  }

 private:
  gfx::Size default_size_;
  gfx::Size min_size_;
  float corner_radius_ = 0.f;
  int hit_test_top_inset_ = 0;
  raw_ptr<views::WebView> web_view_ = nullptr;
};

// Lightweight custom frame for frameless standalone WebUI windows (First Run /
// Onboarding): provides a 36 DIP draggable caption strip at the top and, on
// Windows/Linux, a quiet top-right Minimize + Close control cluster.
class FramelessWebFrameView : public views::FrameView {
  METADATA_HEADER(FramelessWebFrameView, views::FrameView)

 public:
  static constexpr int kDragStripHeight = 36;

  FramelessWebFrameView() {
#if !BUILDFLAG(IS_MAC)
#if BUILDFLAG(IS_WIN)
    const auto mode = OpenWindowControlsView::Mode::kWindowsFluent;
#else
    const auto mode = OpenWindowControlsView::Mode::kLinuxCsd;
#endif
    auto controls = std::make_unique<OpenWindowControlsView>(
        mode,
        std::vector<WindowControlButton>{WindowControlButton::kMinimize,
                                         WindowControlButton::kClose},
        /*allow_maximize=*/false);
    controls->SetPaintToLayer();
    controls->layer()->SetFillsBoundsOpaquely(false);
    controls->SetThemeState(/*dark_content=*/true, /*window_active=*/true,
                            /*increase_contrast=*/false);
    window_controls_ = AddChildView(std::move(controls));
#endif
  }
  FramelessWebFrameView(const FramelessWebFrameView&) = delete;
  FramelessWebFrameView& operator=(const FramelessWebFrameView&) = delete;
  ~FramelessWebFrameView() override = default;

  // views::FrameView:
  gfx::Rect GetBoundsForClientView() const override { return bounds(); }
  gfx::Rect GetWindowBoundsForClientBounds(
      const gfx::Rect& client_bounds) const override {
    return client_bounds;
  }

  void Layout(PassKey) override {
    LayoutSuperclass<views::FrameView>(this);
#if !BUILDFLAG(IS_MAC)
    if (window_controls_) {
      const gfx::Size pref = window_controls_->GetPreferredSize();
#if BUILDFLAG(IS_WIN)
      window_controls_->SetBounds(width() - pref.width(), 0, pref.width(),
                                  pref.height());
#else
      constexpr int kLinuxControlsInsetX = 8;
      constexpr int kLinuxControlsInsetY = 4;
      window_controls_->SetBounds(
          width() - pref.width() - kLinuxControlsInsetX, kLinuxControlsInsetY,
          pref.width(), pref.height());
#endif
    }
#endif
  }

  int NonClientHitTest(const gfx::Point& point) override {
    if (!bounds().Contains(point)) {
      return HTNOWHERE;
    }
#if !BUILDFLAG(IS_MAC)
    if (window_controls_ && window_controls_->GetVisible()) {
      gfx::Point local = point;
      views::View::ConvertPointToTarget(this, window_controls_, &local);
      const int hit = window_controls_->HitTestCode(local);
      if (hit != HTNOWHERE) {
        return hit;
      }
    }
#endif
    if (point.y() < kDragStripHeight) {
      return HTCAPTION;
    }
    return HTCLIENT;
  }

  void AddedToWidget() override {
    views::FrameView::AddedToWidget();
#if !BUILDFLAG(IS_MAC)
    if (views::Widget* widget = GetWidget()) {
      paint_as_active_subscription_ =
          widget->RegisterPaintAsActiveChangedCallback(base::BindRepeating(
              &FramelessWebFrameView::UpdateWindowControlsState,
              base::Unretained(this)));
      UpdateWindowControlsState();
    }
#endif
  }

  void RemovedFromWidget() override {
#if !BUILDFLAG(IS_MAC)
    paint_as_active_subscription_ = {};
#endif
    views::FrameView::RemovedFromWidget();
  }

 private:
#if !BUILDFLAG(IS_MAC)
  void UpdateWindowControlsState() {
    if (!window_controls_ || !GetWidget()) {
      return;
    }
    OpenPlatform* platform = OpenPlatform::Get();
    const bool high_contrast =
        platform && platform->IsIncreaseContrastEnabled();
    window_controls_->SetThemeState(/*dark_content=*/true,
                                    ShouldPaintAsActive(), high_contrast);
  }

  raw_ptr<OpenWindowControlsView> window_controls_ = nullptr;
  base::CallbackListSubscription paint_as_active_subscription_;
#endif
};

BEGIN_METADATA(FramelessWebFrameView)
END_METADATA

class StandaloneWidgetDelegate : public views::WidgetDelegate {
 public:
  explicit StandaloneWidgetDelegate(bool frameless) : frameless_(frameless) {}
  StandaloneWidgetDelegate(const StandaloneWidgetDelegate&) = delete;
  StandaloneWidgetDelegate& operator=(const StandaloneWidgetDelegate&) = delete;
  ~StandaloneWidgetDelegate() override = default;

  // views::WidgetDelegate:
  std::unique_ptr<views::FrameView> CreateFrameView(
      views::Widget* widget) override {
    if (!frameless_) {
      return views::WidgetDelegate::CreateFrameView(widget);
    }
    return std::make_unique<FramelessWebFrameView>();
  }

 private:
  bool frameless_ = false;
};

// WebView for the in-window Library Drawer that preserves views::WebView's own
// WebContentsDelegate wiring while forwarding unhandled keys (such as Esc) to
// the browser window's FocusManager or closing the drawer.
class LibraryDrawerWebView : public views::WebView {
 public:
  LibraryDrawerWebView(content::BrowserContext* browser_context,
                       views::FocusManager* browser_focus_manager,
                       base::RepeatingClosure on_escape)
      : views::WebView(browser_context),
        browser_focus_manager_(browser_focus_manager),
        on_escape_(std::move(on_escape)) {}
  ~LibraryDrawerWebView() override = default;

  void ClearBrowserFocusManager() {
    browser_focus_manager_ = nullptr;
    on_escape_.Reset();
  }

  bool HandleKeyboardEvent(
      content::WebContents* source,
      const input::NativeWebKeyboardEvent& event) override {
    if (event.GetType() == blink::WebInputEvent::Type::kRawKeyDown &&
        event.windows_key_code == ui::VKEY_ESCAPE &&
        (event.GetModifiers() & blink::WebInputEvent::kKeyModifiers) == 0 &&
        on_escape_) {
      on_escape_.Run();
      return true;
    }
    if (browser_focus_manager_ &&
        unhandled_keyboard_event_handler_.HandleKeyboardEvent(
            event, browser_focus_manager_)) {
      return true;
    }
    return views::WebView::HandleKeyboardEvent(source, event);
  }

 private:
  raw_ptr<views::FocusManager> browser_focus_manager_ = nullptr;
  base::RepeatingClosure on_escape_;
  views::UnhandledKeyboardEventHandler unhandled_keyboard_event_handler_;
};

}  // namespace

// ===========================================================================
// OpenWindowController::StandaloneWebWindow
// ===========================================================================
// Hosts standalone open:// WebUI windows (Settings 960x660 min 800x540 and
// First Run 860x620 frameless centered) using Chromium 156's CLIENT_OWNS_WIDGET
// pattern where the WidgetDelegate outlives its Widget.
class OpenWindowController::StandaloneWebWindow {
 public:
  StandaloneWebWindow(content::BrowserContext* browser_context,
                      const GURL& url,
                      const std::u16string& title,
                      gfx::Size default_size,
                      gfx::Size min_size,
                      bool frameless,
                      std::string name,
                      base::OnceClosure on_closed)
      : on_closed_(std::move(on_closed)) {
    delegate_ = std::make_unique<StandaloneWidgetDelegate>(frameless);
    delegate_->SetTitle(title);
    delegate_->SetShowTitle(!frameless);
    delegate_->SetShowCloseButton(!frameless);
    delegate_->SetCanResize(!frameless);
    delegate_->SetCanMaximize(!frameless);
    delegate_->SetCanMinimize(true);
    delegate_->RegisterWindowClosingCallback(base::BindOnce(
        &StandaloneWebWindow::OnWindowClosing, weak_factory_.GetWeakPtr()));

#if BUILDFLAG(IS_MAC)
    const float corner_radius = frameless ? 16.f : 0.f;
    const int hit_test_top_inset = 0;
#else
    const float corner_radius = frameless ? 12.f : 0.f;
    const int hit_test_top_inset =
        frameless ? FramelessWebFrameView::kDragStripHeight : 0;
#endif
    auto web_view = std::make_unique<views::WebView>(browser_context);
    auto container = std::make_unique<MinSizeWebContainer>(
        default_size, min_size, std::move(web_view), corner_radius,
        hit_test_top_inset);
    MinSizeWebContainer* container_ptr = container.get();
    web_view_ = container->web_view();
    delegate_->SetContentsView(std::move(container));
    delegate_->SetInitiallyFocusedView(web_view_);

    gfx::Rect work_area(0, 0, 1280, 800);
    if (display::Screen* screen = display::Screen::Get()) {
      work_area =
          screen->GetDisplayNearestPoint(screen->GetCursorScreenPoint())
              .work_area();
    }
    const int x =
        work_area.x() + std::max(0, (work_area.width() - default_size.width()) / 2);
    const int y =
        work_area.y() +
        std::max(0, (work_area.height() - default_size.height()) / 2);
    initial_bounds_ = gfx::Rect(x, y, default_size.width(), default_size.height());

    views::Widget::InitParams params(
        views::Widget::InitParams::CLIENT_OWNS_WIDGET,
        views::Widget::InitParams::TYPE_WINDOW);
    params.delegate = delegate_.get();
    params.bounds = initial_bounds_;
    params.name = std::move(name);
#if BUILDFLAG(IS_LINUX)
    params.wm_class_name = "open-browser";
    params.wm_class_class = "Open";
    params.wayland_app_id = "open-browser";
#endif
    if (frameless) {
      params.remove_standard_frame = true;
#if BUILDFLAG(IS_WIN)
      // Avoid legacy XP CS_DROPSHADOW + kTranslucent on Win11: use opaque
      // window with native DWMWCP_ROUND corners & crisp DWM shadow via
      // ApplyWindowEffects().
      params.opacity = views::Widget::InitParams::WindowOpacity::kOpaque;
      params.shadow_type = views::Widget::InitParams::ShadowType::kNone;
#else
      params.opacity = views::Widget::InitParams::WindowOpacity::kTranslucent;
      params.shadow_type = views::Widget::InitParams::ShadowType::kDrop;
#endif
      params.rounded_corners = gfx::RoundedCornersF(corner_radius);
    }

    widget_ = std::make_unique<views::Widget>();
    widget_->Init(std::move(params));
    widget_->SetBounds(initial_bounds_);
    if (OpenPlatform* platform = OpenPlatform::Get()) {
      platform->ApplyWindowEffects(widget_.get(), /*dark_mode=*/true);
    }
    web_view_->LoadInitialURL(url);
    container_ptr->ApplyNativeViewEffects();
  }

  ~StandaloneWebWindow() {
    on_closed_.Reset();
    web_view_ = nullptr;
    if (widget_) {
      widget_->CloseNow();
    }
    widget_.reset();
    delegate_.reset();
  }

  StandaloneWebWindow(const StandaloneWebWindow&) = delete;
  StandaloneWebWindow& operator=(const StandaloneWebWindow&) = delete;

  void ShowAndActivate() {
    if (!widget_) {
      return;
    }
    if (widget_->IsMinimized()) {
      widget_->Restore();
    }
    if (!shown_once_ && !initial_bounds_.IsEmpty()) {
      widget_->SetBounds(initial_bounds_);
    }
    widget_->Show();
    if (!shown_once_ && !initial_bounds_.IsEmpty()) {
      shown_once_ = true;
      widget_->SetBounds(initial_bounds_);
    }
    widget_->Activate();
    if (web_view_) {
      web_view_->RequestFocus();
    }
  }

  void Navigate(const GURL& url) {
    if (!web_view_ || !url.is_valid()) {
      return;
    }
    if (content::WebContents* wc = web_view_->GetWebContents()) {
      wc->GetController().LoadURLWithParams(
          content::NavigationController::LoadURLParams(url));
    } else {
      web_view_->LoadInitialURL(url);
    }
  }

  void Close() {
    if (widget_ && !closing_) {
      closing_ = true;
      widget_->Close();
    }
  }

  views::Widget* widget() const { return widget_.get(); }

 private:
  void OnWindowClosing() {
    closing_ = true;
    web_view_ = nullptr;
    if (on_closed_) {
      base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
          FROM_HERE, std::move(on_closed_));
    }
  }

  // Declared before widget_ so delegate_ outlives widget_.
  std::unique_ptr<StandaloneWidgetDelegate> delegate_;
  std::unique_ptr<views::Widget> widget_;
  raw_ptr<views::WebView> web_view_ = nullptr;
  base::OnceClosure on_closed_;
  gfx::Rect initial_bounds_;
  bool shown_once_ = false;
  bool closing_ = false;
  base::WeakPtrFactory<StandaloneWebWindow> weak_factory_{this};
};

// ===========================================================================
// OpenWindowController
// ===========================================================================

OpenWindowController::OpenWindowController(OpenBrowserService* service)
    : service_(service) {}

OpenWindowController::~OpenWindowController() {
  Shutdown();
}

void OpenWindowController::AttachServiceObservers() {
  if (!started_ || service_observers_attached_) {
    return;
  }
  service_observers_attached_ = true;
  if (OpenDownloadBridge* downloads = service_->download_bridge()) {
    downloads->AddObserver(this);
  }
  if (OpenMediaBridge* media = service_->media_bridge()) {
    media->AddObserver(this);
  }
  if (OpenLiveDataService* livedata = service_->livedata()) {
    livedata->AddObserver(this);
  }
  if (OpenCaptureController* capture = service_->capture_controller()) {
    capture->SetDelegate(this);
  }
}

void OpenWindowController::DetachServiceObservers() {
  if (!service_observers_attached_) {
    return;
  }
  service_observers_attached_ = false;
  // Null-check every service pointer because OpenBrowserService::Shutdown()
  // tears down livedata_, capture_controller_, and media_bridge_ before
  // calling window_controller_->Shutdown().
  if (OpenDownloadBridge* downloads = service_->download_bridge()) {
    downloads->RemoveObserver(this);
  }
  if (OpenMediaBridge* media = service_->media_bridge()) {
    media->RemoveObserver(this);
  }
  if (OpenLiveDataService* livedata = service_->livedata()) {
    livedata->RemoveObserver(this);
  }
  if (OpenCaptureController* capture = service_->capture_controller()) {
    capture->SetDelegate(nullptr);
  }
}

void OpenWindowController::Start() {
  if (started_) {
    return;
  }
  started_ = true;
  hooks::SetHookDelegate(this);
  service_->AddObserver(this);
  service_->model().AddObserver(this);
  if (OpenTabBridge* tabs = service_->tab_bridge()) {
    tabs->AddObserver(this);
  }
  for (OpenExtensionBridge* extensions : service_->AllExtensionBridges()) {
    ObserveExtensionBridge(extensions);
  }
  if (!windows_.empty()) {
    AttachServiceObservers();
  }
  // Chromium's startup Browser got its OpenBrowserView before the bridges
  // existed (hook 0002 runs between PreBrowserStart and PostBrowserStart).
  for (auto& [browser_view, ui] : windows_) {
    ui->AttachExtensionWindow();
    ui->UpdatePanel();
    ui->RefreshMediaSessions();
    ui->RefreshDownloadProgress();
  }
  RefreshSuggestExtensions();
  NotifyWindowStateChanged();
}

void OpenWindowController::Shutdown() {
  if (!started_) {
    return;
  }
  started_ = false;
  if (hooks::GetHookDelegate() == this) {
    hooks::SetHookDelegate(nullptr);
  }
  theme_preview_spaces_.clear();
  CloseSettingsWindow();
  CloseFirstRunWindow();
  little_opens_.clear();
  windows_.clear();
  DetachServiceObservers();
  service_->RemoveObserver(this);
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
  const bool was_empty = windows_.empty();
  auto ui = std::make_unique<OpenWindowUi>(this, browser_view, open_view,
                                           open_view->window_id());
  OpenWindowUi* ui_ptr = ui.get();
  windows_[browser_view] = std::move(ui);
  if (started_) {
    if (was_empty) {
      AttachServiceObservers();
    }
    ui_ptr->AttachExtensionWindow();
    ui_ptr->RefreshMediaSessions();
    ui_ptr->RefreshDownloadProgress();
  }
}

void OpenWindowController::OnBrowserViewDestroying(BrowserView* browser_view) {
  windows_.erase(browser_view);
  if (windows_.empty()) {
    // Detach observers as soon as the last browser window closes so
    // OpenBrowserService::Shutdown() never sees lingering observers on
    // media_bridge_ / livedata_ / capture_controller_.
    DetachServiceObservers();
    if (OpenHandoffController* handoff = service_->handoff()) {
      handoff->OnWindowClosed();
    }
#if !BUILDFLAG(IS_MAC)
    if (little_opens_.empty() && (settings_window_ || first_run_window_)) {
      base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
          FROM_HERE,
          base::BindOnce(
              [](base::WeakPtr<OpenWindowController> self) {
                if (!self || !self->windows_.empty() ||
                    !self->little_opens_.empty()) {
                  return;
                }
                self->CloseSettingsWindow();
                self->CloseFirstRunWindow();
              },
              weak_factory_.GetWeakPtr()));
    }
#endif
  }
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

OpenWindowUi* OpenWindowController::WindowUiForBrowser(
    BrowserWindowInterface* browser) {
  if (browser) {
    if (BrowserView* bv = BrowserView::GetBrowserViewForBrowser(browser)) {
      if (OpenWindowUi* ui = WindowUiForBrowserView(bv)) {
        return ui;
      }
    }
  }
  return MainWindowUi();
}

// --- Standalone Settings & First Run Windows ---------------------------------

void OpenWindowController::OpenSettingsWindow(std::string_view section) {
  if (!started_) {
    return;
  }
  ::Profile* chrome_profile =
      service_->ChromeProfileFor(service_->ActiveProfileId());
  if (!chrome_profile) {
    return;
  }
  const std::optional<SpaceID> focused =
      model_util::FocusedSpace(service_->model(), service_->ActiveWindowId());
  const Space* space = focused ? GetSpace(*focused) : nullptr;
  const GURL url(AppendSpaceThemeQuery(
      webui::OpenWebUIURL(webui::kHostSettings, section), space,
      IsSystemDarkMode(), /*extra_query=*/""));
  if (settings_window_) {
    if (!section.empty()) {
      settings_window_->Navigate(url);
    }
    settings_window_->ShowAndActivate();
    return;
  }
  settings_window_ = std::make_unique<StandaloneWebWindow>(
      chrome_profile, url, u"Open Settings", kSettingsWindowDefaultSize,
      kSettingsWindowMinSize, /*frameless=*/false, "OpenSettings",
      base::BindOnce(&OpenWindowController::OnSettingsWindowClosed,
                     weak_factory_.GetWeakPtr()));
  settings_window_->ShowAndActivate();
}

void OpenWindowController::CloseSettingsWindow() {
  settings_window_.reset();
}

bool OpenWindowController::settings_window_open() const {
  return settings_window_ != nullptr;
}

void OpenWindowController::OnSettingsWindowClosed() {
  settings_window_.reset();
}

void OpenWindowController::OpenFirstRunWindow() {
  if (!started_) {
    return;
  }
  if (first_run_window_) {
    first_run_window_->ShowAndActivate();
    return;
  }
  ::Profile* chrome_profile =
      service_->ChromeProfileFor(service_->ActiveProfileId());
  if (!chrome_profile) {
    return;
  }
  if (OpenWindowUi* main_ui = MainWindowUi()) {
    if (views::Widget* w = main_ui->widget(); w && w->IsVisible()) {
      w->Hide();
      hid_main_window_for_first_run_ = true;
    }
  }
  first_run_window_ = std::make_unique<StandaloneWebWindow>(
      chrome_profile, GURL(webui::OpenWebUIURL(webui::kHostOnboarding)),
      u"Welcome to Open", kFirstRunWindowSize, kFirstRunWindowSize,
      /*frameless=*/true, "OpenFirstRun",
      base::BindOnce(&OpenWindowController::OnFirstRunWindowClosed,
                     weak_factory_.GetWeakPtr()));
  first_run_window_->ShowAndActivate();
}

void OpenWindowController::CloseFirstRunWindow() {
  if (first_run_window_) {
    first_run_window_.reset();
  }
  if (hid_main_window_for_first_run_) {
    hid_main_window_for_first_run_ = false;
    if (OpenWindowUi* main_ui = MainWindowUi()) {
      if (views::Widget* w = main_ui->widget()) {
        w->Show();
        w->Activate();
      }
    }
  }
}

void OpenWindowController::OnOnboardingCompleted() {
  const bool had_first_run_window = first_run_window_ != nullptr;
  // Never synchronously destroy first_run_window_ here: OnOnboardingCompleted()
  // is invoked while OpenOnboardingUI::FinishComplete is still on the stack.
  // Hide the window immediately and post destruction to the next UI task.
  if (first_run_window_) {
    if (views::Widget* w = first_run_window_->widget()) {
      w->Hide();
    }
    base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE, base::BindOnce(&OpenWindowController::CloseFirstRunWindow,
                                  weak_factory_.GetWeakPtr()));
  }
  if (hid_main_window_for_first_run_) {
    hid_main_window_for_first_run_ = false;
    if (OpenWindowUi* main_ui = MainWindowUi()) {
      if (views::Widget* w = main_ui->widget()) {
        w->Show();
        w->Activate();
      }
    }
  }
  if (had_first_run_window) {
    if (OpenTabBridge* bridge = service_->tab_bridge()) {
      const BrowserModel& model = service_->model();
      const std::optional<SpaceID> focused =
          model_util::FocusedSpace(model, service_->MainWindowId());
      const GURL welcome_url(webui::OpenWebUIURL(webui::kHostWelcome));
      bool found_welcome = false;
      if (focused) {
        if (const Space* space = model.FindSpace(*focused)) {
          for (const SidebarNode& node : space->today) {
            if (const Tab* tab = node.as_tab()) {
              const GURL tab_url(tab->url);
              const std::string_view host = tab_url.host();
              if (host == webui::kHostWelcome ||
                  host == webui::InternalHost(webui::kHostWelcome)) {
                bridge->SelectNode(tab->id);
                found_welcome = true;
                break;
              }
            }
          }
        }
      }
      if (!found_welcome) {
        bridge->OpenTab(welcome_url, /*background=*/false);
      }
    }
  }
  for (auto& [browser_view, ui] : windows_) {
    ui->UpdateThemeForLiveSurfaces();
  }
  if (OpenWindowUi* main_ui = MainWindowUi()) {
    main_ui->ActivateWindow();
  }
}

bool OpenWindowController::first_run_window_open() const {
  return first_run_window_ != nullptr;
}

void OpenWindowController::OnFirstRunWindowClosed() {
  CloseFirstRunWindow();
}

// --- Little Open & External Routing ------------------------------------------

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
  const bool little_open_pref = PrefBool("links.externalLinksLittleOpen", true);
  const RoutingDecision decision =
      service_->routing().Evaluate(request, service_->model(), little_open_pref);
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
#if !BUILDFLAG(IS_MAC)
  if (windows_.empty() && little_opens_.empty() &&
      (settings_window_ || first_run_window_)) {
    base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE,
        base::BindOnce(
            [](base::WeakPtr<OpenWindowController> self) {
              if (!self || !self->windows_.empty() ||
                  !self->little_opens_.empty()) {
                return;
              }
              self->CloseSettingsWindow();
              self->CloseFirstRunWindow();
            },
            weak_factory_.GetWeakPtr()));
  }
#endif
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

void OpenWindowController::SetSpaceThemePreview(const SpaceID& space_id,
                                                const SpaceTheme& theme) {
  const Space* original = service_->model().FindSpace(space_id);
  if (!original) {
    return;
  }
  Space preview = *original;
  preview.theme = theme;
  theme_preview_spaces_[space_id] = std::move(preview);
  for (OpenViewObserver& observer : view_observers_) {
    observer.OnSpaceThemeChanged(space_id);
  }
  for (auto& [browser_view, ui] : windows_) {
    if (ui->open_view()) {
      ui->open_view()->CrossfadeTheme(space_id, /*animated=*/false);
    }
    ui->UpdateThemeForLiveSurfaces();
  }
}

void OpenWindowController::ClearSpaceThemePreview(const SpaceID& space_id) {
  if (theme_preview_spaces_.erase(space_id) == 0) {
    return;
  }
  for (OpenViewObserver& observer : view_observers_) {
    observer.OnSpaceThemeChanged(space_id);
  }
  for (auto& [browser_view, ui] : windows_) {
    if (ui->open_view()) {
      ui->open_view()->CrossfadeTheme(space_id, /*animated=*/false);
    }
    ui->UpdateThemeForLiveSurfaces();
  }
}

void OpenWindowController::RestoreArchived(
    std::vector<ArchivedTabRecord> records) {
  for (const ArchivedTabRecord& record : records) {
    ProfileServices* services = service_->ProfileServicesFor(
        record.profile_id.value_or(service_->ActiveProfileId()));
    if (!services) {
      continue;
    }
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

OpenExtensionBridge* OpenWindowController::ExtensionBridgeForWindow(
    const WindowID& window_id) const {
  const std::optional<SpaceID> space_id =
      model_util::FocusedSpace(service_->model(), window_id);
  if (const Space* space = space_id ? GetSpace(*space_id) : nullptr) {
    if (ProfileServices* ps = service_->ProfileServicesFor(space->profile_id);
        ps && ps->extensions) {
      return ps->extensions.get();
    }
  }
  return service_->extension_bridge();
}

gfx::ImageSkia OpenWindowController::GetFaviconForUrl(
    const GURL& page_url) const {
  if (!page_url.is_valid()) {
    return gfx::ImageSkia();
  }
  OpenTabBridge* bridge = service_->tab_bridge();
  if (!bridge) {
    return gfx::ImageSkia();
  }
  for (const auto& [tab_id, contents] : bridge->LoadedTabs()) {
    if (!contents) {
      continue;
    }
    const GURL& loaded_url = contents->GetLastCommittedURL();
    if (loaded_url == page_url ||
        (loaded_url.is_valid() && loaded_url.host() == page_url.host() &&
         loaded_url.path() == page_url.path())) {
      if (favicon::ContentFaviconDriver* driver =
              favicon::ContentFaviconDriver::FromWebContents(contents);
          driver && driver->FaviconIsValid()) {
        return driver->GetFavicon().AsImageSkia();
      }
    }
  }
  return gfx::ImageSkia();
}

void OpenWindowController::RefreshSuggestExtensions() {
  OpenExtensionBridge* extensions = service_->extension_bridge();
  if (!extensions) {
    return;
  }
  OpenWindowUi* ui = MainWindowUi();
  BrowserWindowInterface* browser =
      ui && ui->browser_view() ? ui->browser_view()->browser() : nullptr;
  std::vector<ExtensionActionInfo> infos =
      browser ? extensions->GetAllToolbarActions(browser, /*include_unpinned=*/true)
              : extensions->ListActions();
  std::vector<ExtensionActionEntry> entries;
  entries.reserve(infos.size());
  for (const ExtensionActionInfo& info : infos) {
    if (!info.enabled) {
      continue;
    }
    ExtensionActionEntry entry;
    entry.extension_id = info.id;
    entry.name = info.name.empty() ? info.title : info.name;
    entry.shortcut_display = base::UTF16ToUTF8(info.shortcut);
    entries.push_back(std::move(entry));
  }
  service_->suggest().SetExtensionActions(std::move(entries));
}

// --- Reads (OpenViewController) ----------------------------------------------

const BrowserWindowState* OpenWindowController::GetWindowState(
    const WindowID& window_id) const {
  return service_->model().FindWindow(window_id);
}

std::vector<SpaceID> OpenWindowController::GetWindowSpaceIds(
    const WindowID& window_id) const {
  if (IsIncognitoWindow(window_id)) {
    if (const BrowserWindowState* win = service_->model().FindWindow(window_id);
        win && !win->focused_space_id.empty()) {
      return {win->focused_space_id};
    }
  }
  std::vector<SpaceID> ids;
  for (const Space& space : service_->model().spaces()) {
    ids.push_back(space.id);
  }
  return ids;
}

const Space* OpenWindowController::GetSpace(const SpaceID& space_id) const {
  if (auto it = theme_preview_spaces_.find(space_id);
      it != theme_preview_spaces_.end()) {
    return &it->second;
  }
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

const Tab* OpenWindowController::GetActiveTab(const WindowID& window_id) const {
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
  if (bridge) {
    if (browser_view) {
      if (std::optional<WindowID> id =
              bridge->WindowIdForBrowser(browser_view->browser())) {
        return *id;
      }
    }
    if (std::optional<WindowID> pending = bridge->PendingWindowId()) {
      return *pending;
    }
  }
  return service_->MainWindowId();
}

bool OpenWindowController::IsIncreaseContrastEnabled() const {
  OpenPlatform* platform = OpenPlatform::Get();
  return platform && platform->IsIncreaseContrastEnabled();
}

bool OpenWindowController::IsIncognitoWindow(const WindowID& window_id) const {
  if (service_->IsIncognitoWindow(window_id)) {
    return true;
  }
  if (OpenTabBridge* bridge = service_->tab_bridge()) {
    return bridge->IsIncognitoWindow(window_id);
  }
  return false;
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
OpenWindowController::GetPinnedToolbarActions(const WindowID& window_id) const {
  std::vector<OpenToolbarActionInfo> actions;
  OpenExtensionBridge* extensions = ExtensionBridgeForWindow(window_id);
  if (!extensions) {
    return actions;
  }
  const OpenWindowUi* ui = WindowUiForConst(window_id);
  BrowserWindowInterface* browser =
      ui && ui->browser_view() ? ui->browser_view()->browser() : nullptr;
  const std::vector<ExtensionActionInfo> list =
      browser
          ? extensions->GetAllToolbarActions(browser, /*include_unpinned=*/false)
          : extensions->ListActions();
  for (const ExtensionActionInfo& info : list) {
    if (!info.pinned) {
      continue;
    }
    OpenToolbarActionInfo action;
    action.id = info.id;
    action.tooltip = !info.tooltip.empty() ? info.tooltip
                                           : base::UTF8ToUTF16(info.title);
    action.icon =
        !info.icon_with_badge.isNull() ? info.icon_with_badge : info.icon;
    action.has_badge = !info.badge_text.empty();
    actions.push_back(std::move(action));
  }
  return actions;
}

gfx::ImageSkia OpenWindowController::GetFavicon(const ItemID& tab_id) const {
  OpenTabBridge* bridge = service_->tab_bridge();
  if (!bridge) {
    return gfx::ImageSkia();
  }
  if (content::WebContents* contents = bridge->WebContentsForTab(tab_id)) {
    if (favicon::ContentFaviconDriver* driver =
            favicon::ContentFaviconDriver::FromWebContents(contents);
        driver && driver->FaviconIsValid()) {
      return driver->GetFavicon().AsImageSkia();
    }
  }
  return gfx::ImageSkia();
}

bool OpenWindowController::IsDeveloperModeEnabled() const {
  return PrefBool("advanced.developerMode", false);
}

// --- Intents & Sidebar Context Menus -----------------------------------------

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
    return;
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
      if (ui) {
        ui->ToggleToolbarMorePopover(intent.anchor_in_screen);
      }
      break;
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
          ui->ShowToast(ToastSpec::ForKind(OpenToastKind::kCopiedUrl));
        }
      }
      break;
    case OpenIntentKind::kShowSiteControls:
      if (ui) {
        ui->ShowSiteControls(nullptr);
      }
      break;
    case OpenIntentKind::kRunToolbarAction:
      if (OpenExtensionBridge* extensions = ExtensionBridgeForWindow(window_id)) {
        BrowserWindowInterface* browser =
            ui && ui->browser_view() ? ui->browser_view()->browser() : nullptr;
        if (browser) {
          extensions->ExecuteAction(browser, intent.text, nullptr,
                                    intent.anchor_in_screen, base::DoNothing());
        } else {
          extensions->ExecuteAction(intent.text, nullptr, base::DoNothing());
        }
      }
      break;

    // --- Spaces, Library, creation ---
    case OpenIntentKind::kSelectNode:
      bridge->SelectNode(
          intent.secondary_id.empty() ? intent.node_id : intent.secondary_id,
          window_id);
      break;
    case OpenIntentKind::kSelectFavorite:
      bridge->SelectNode(intent.node_id, window_id);
      break;
    case OpenIntentKind::kSwitchSpace:
      bridge->FocusSpace(intent.space_id, window_id);
      break;
    case OpenIntentKind::kShowLibrary:
      if (ui) {
        ui->ShowLibraryDrawer("");
      } else {
        bridge->OpenTab(GURL(webui::OpenWebUIURL(webui::kHostLibrary)),
                        /*background=*/false, window_id);
      }
      break;
    case OpenIntentKind::kNewSpace:
      if (ui) {
        ui->ShowSpaceCreation(nullptr);
      } else {
        const SpaceID space = model.CreateSpace(service_->ActiveProfileId());
        if (!space.empty()) {
          bridge->FocusSpace(space, window_id);
        }
      }
      break;
    case OpenIntentKind::kNewFolder:
      model.CreateFolder(intent.parent.owner_id.empty()
                             ? NodeParent{NodeParentKind::kSpaceToday, focused}
                             : intent.parent);
      break;
    case OpenIntentKind::kNewEasel:
      if (ui) {
        ui->HandleCommand(CommandId::kNewEasel);
      } else {
        bridge->OpenTab(GURL(webui::OpenWebUIURL(webui::kHostEasel)),
                        /*background=*/false, window_id);
      }
      break;
    case OpenIntentKind::kNewNote:
      if (ui) {
        ui->HandleCommand(CommandId::kNewNote);
      } else {
        bridge->OpenTab(GURL(webui::OpenWebUIURL(webui::kHostNote)),
                        /*background=*/false, window_id);
      }
      break;
    case OpenIntentKind::kSetPinnedCollapsed:
      model.SetPinnedCollapsed(intent.space_id, intent.flag);
      break;
    case OpenIntentKind::kClearToday:
      model.ClearToday(intent.space_id);
      if (ui) {
        ui->ShowToast(ToastSpec::ForKind(
            OpenToastKind::kClearedTabs, {},
            base::BindOnce(
                [](base::WeakPtr<OpenWindowController> self) {
                  if (self) {
                    self->service_->model().Undo();
                  }
                },
                weak_factory_.GetWeakPtr())));
      }
      break;
    case OpenIntentKind::kRenameSpace:
      model.UpdateSpace(intent.space_id, intent.text);
      break;
    case OpenIntentKind::kEditSpaceTheme:
      if (ui) {
        ui->ShowSpaceThemeEditor(
            intent.space_id.empty() ? focused : intent.space_id,
            /*open_identity_page=*/false);
      }
      break;
    case OpenIntentKind::kChangeSpaceIcon:
      if (ui) {
        ui->ShowSpaceThemeEditor(
            intent.space_id.empty() ? focused : intent.space_id,
            /*open_identity_page=*/true);
      }
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
      const ItemID id = bridge->OpenTab(url, /*background=*/false, window_id);
      if (!id.empty() && !intent.parent.owner_id.empty()) {
        model.MoveNode(id, intent.parent, intent.index);
      }
      break;
    }
  }
}

std::unique_ptr<ui::SimpleMenuModel>
OpenWindowController::BuildMenuModelForTarget(const WindowID& window_id,
                                              const OpenMenuTarget& target) {
  const BrowserModel& model = service_->model();
  OpenWindowUi* ui = WindowUiFor(window_id);
  const bool incognito = IsIncognitoWindow(window_id);

  SidebarMenuContext ctx;
  ctx.target = target;
  ctx.model = &model;
  ctx.window_id = window_id;
  ctx.is_incognito = incognito;
  ctx.developer_mode = IsDeveloperModeEnabled();
  ctx.shared_quotes_enabled = PrefBool("advanced.sharedQuotes", true);

  content::WebContents* active_wc =
      ui && ui->peek_shown() ? ui->PeekWebContents()
                             : ActiveWebContentsFor(window_id);
  ctx.current_tab_id = ui ? ui->ActiveTabId() : std::nullopt;
  ctx.has_page = active_wc != nullptr;
  ctx.page_is_loading = active_wc && active_wc->IsLoading();
  if (active_wc) {
    const GURL url = active_wc->GetLastCommittedURL().is_valid()
                         ? active_wc->GetLastCommittedURL()
                         : active_wc->GetVisibleURL();
    if (url.is_valid() && !(url.SchemeIs(webui::kOpenScheme) &&
                            url.host() == webui::kHostNote)) {
      ctx.current_page_url = url.spec();
    }
  }

  if (!incognito && service_->tab_bridge()) {
    for (const auto& [tab_id, wc] : service_->tab_bridge()->LoadedTabs()) {
      if (wc && wc->GetLastCommittedURL().SchemeIsHTTPOrHTTPS()) {
        ctx.customizable_tab_ids.insert(tab_id);
      }
    }
  }

  if (target.kind == OpenMenuTarget::Kind::kSpace ||
      target.kind == OpenMenuTarget::Kind::kSwitcherItem) {
    if (const Space* space = model.FindSpace(target.space_id)) {
      ctx.space_has_live_folder = SpaceContainsLiveFolder(*space);
      ctx.offers_space_header_toggle =
          model.spaces().size() == 1 &&
          (!space->title.has_value() || space->title->empty());
      ctx.space_header_shown = true;
    }
  }

  if (target.kind == OpenMenuTarget::Kind::kNode) {
    if (const Folder* folder = model.FindFolder(target.node_id);
        folder && folder->live.has_value()) {
      SidebarLiveFolderInfo info;
      if (OpenLiveDataService* ld = service_->livedata()) {
        if (auto state = ld->GetLiveFolderState(folder->id)) {
          info.last_fetch_failed = !state->last_error.empty();
          std::set<std::string> repos;
          for (const LiveFolderItem& item : state->items) {
            if (!item.subtitle.empty()) {
              repos.insert(item.subtitle);
            }
          }
          for (const std::string& r : repos) {
            info.repositories.push_back({r, /*hidden=*/false});
          }
        }
      }
      info.needs_sso = folder->live_sso_url.has_value();
      ctx.live_folder = std::move(info);
    }
  }

  if (target.kind == OpenMenuTarget::Kind::kFavorite) {
    if (const Tab* tab = model.FindTab(target.node_id)) {
      SidebarFavoriteTileInfo fav;
      fav.is_calendar = OpenLiveDataService::IsCalendarFavoriteUrl(tab->url);
      fav.live_calendar_enabled = PrefBool("previews.calendar", true);
      fav.shows_time_to_next_meeting = fav.live_calendar_enabled;
      if (fav.is_calendar && service_->livedata()) {
        if (auto meeting = service_->livedata()->NextUpcomingMeeting()) {
          if (!meeting->join_url.empty()) {
            fav.meeting_link = meeting->join_url;
          }
        }
      }
      fav.supports_unread_badge = IsMailUrl(tab->url);
      fav.shows_unread_badge = PrefBool("previews.gmail", true);
      ctx.favorite_tile = std::move(fav);
    }
  }

  if (target.kind == OpenMenuTarget::Kind::kToolbarAction) {
    if (OpenExtensionBridge* extensions = ExtensionBridgeForWindow(window_id)) {
      for (const ExtensionActionInfo& info : extensions->ListInstalled()) {
        if (info.id == target.text) {
          SidebarToolbarActionInfo act;
          act.id = info.id;
          act.name = base::UTF8ToUTF16(info.name);
          act.has_popup = info.has_popup;
          act.can_remove = !info.force_pinned;
          ctx.toolbar_action = std::move(act);
          break;
        }
      }
    }
  }

  return BuildSidebarMenuModel(
      ctx, base::BindRepeating(
               &OpenWindowController::DispatchSidebarMenuCommand,
               weak_factory_.GetWeakPtr(), window_id));
}

std::unique_ptr<ui::MenuModel> OpenWindowController::CreateMenuModel(
    const WindowID& window_id,
    const OpenMenuTarget& target) {
  return BuildMenuModelForTarget(window_id, target);
}

void OpenWindowController::DispatchSidebarMenuCommand(
    const WindowID& window_id,
    const SidebarMenuCommand& cmd) {
  BrowserModel& model = service_->model();
  OpenTabBridge* bridge = service_->tab_bridge();
  OpenWindowUi* ui = WindowUiFor(window_id);
  if (!bridge) {
    return;
  }
  const std::optional<SpaceID> focused =
      model_util::FocusedSpace(model, window_id);

  switch (cmd.action) {
    case SidebarMenuAction::kNone:
      return;

    case SidebarMenuAction::kCopyLink: {
      if (const Tab* tab = model.FindTab(cmd.node_id)) {
        const std::string text =
            cmd.flag ? base::StrCat({"[", tab->display_title(), "](", tab->url, ")"})
                     : tab->url;
        ui::ScopedClipboardWriter(ui::ClipboardBuffer::kCopyPaste)
            .WriteText(base::UTF8ToUTF16(text));
        if (ui) {
          ui->ShowToast(ToastSpec::ForKind(
              cmd.flag ? OpenToastKind::kCopiedMarkdown
                       : OpenToastKind::kCopiedUrl));
        }
      }
      return;
    }
    case SidebarMenuAction::kShareVia:
      if (const Tab* tab = model.FindTab(cmd.node_id)) {
        site_control_data::CopyCleanUrl(GURL(tab->url));
        if (ui) {
          ui->ShowToast(ToastSpec::ForKind(OpenToastKind::kCopiedCleanLink));
        }
      }
      return;
    case SidebarMenuAction::kChangeIcon:
      if (ui && focused) {
        ui->ShowSpaceThemeEditor(*focused, /*open_identity_page=*/true);
      }
      return;
    case SidebarMenuAction::kBeginRename:
      if (ui && ui->open_view() && ui->open_view()->sidebar()) {
        if (!cmd.node_id.empty()) {
          const std::optional<SpaceID> space =
              model_util::SpaceOfNode(model, cmd.node_id);
          if (space) {
            if (OpenTabTreeView* tree =
                    ui->open_view()->sidebar()->GetTreeForSpace(*space)) {
              tree->BeginRename(cmd.node_id);
            }
          }
        } else if (focused) {
          ui->ShowSpaceThemeEditor(*focused, /*open_identity_page=*/true);
        }
      }
      return;
    case SidebarMenuAction::kToggleMute:
      HandleIntent(window_id,
                   OpenIntent::ForNode(OpenIntentKind::kToggleMute, cmd.node_id));
      return;
    case SidebarMenuAction::kCustomizePage:
      if (ui) {
        bridge->SelectNode(cmd.node_id, window_id);
        ui->OpenBoostEditor(std::nullopt);
      }
      return;
    case SidebarMenuAction::kReplacePinnedUrl:
      if (const Tab* tab = model.FindTab(cmd.node_id);
          tab && model.IsPinned(cmd.node_id)) {
        const std::optional<NodeParent> parent = model.GetParent(cmd.node_id);
        const std::optional<NodeIndexEntry> entry =
            model.GetIndexEntry(cmd.node_id);
        model.UnpinTab(cmd.node_id);
        if (parent && entry) {
          model.MoveNode(cmd.node_id, *parent, entry->index);
        } else {
          model.PinTab(cmd.node_id);
        }
      }
      return;
    case SidebarMenuAction::kEditPinnedUrl:
      if (ui) {
        bridge->SelectNode(cmd.node_id, window_id);
        ui->HandleCommand(CommandId::kOpenCommandBar);
      }
      return;
    case SidebarMenuAction::kAddSplitView:
      bridge->ToggleSplit(cmd.node_id);
      return;
    case SidebarMenuAction::kOpenInSplitView:
      if (ui) {
        if (std::optional<ItemID> active = ui->ActiveTabId();
            active && *active != cmd.node_id) {
          model.MakeSplit({*active, cmd.node_id});
        } else {
          bridge->ToggleSplit(cmd.node_id);
        }
      }
      return;
    case SidebarMenuAction::kDuplicate: {
      const ItemID dup = model.DuplicateNode(cmd.node_id);
      if (!dup.empty()) {
        bridge->SelectNode(dup, window_id);
      }
      return;
    }
    case SidebarMenuAction::kMoveToSpace:
      if (!cmd.space_id.empty()) {
        model.MoveNode(cmd.node_id,
                       NodeParent{NodeParentKind::kSpaceToday, cmd.space_id},
                       size_t{0});
      }
      return;
    case SidebarMenuAction::kMoveToNewSpace: {
      const SpaceID new_space = model.CreateSpace(service_->ActiveProfileId());
      if (!new_space.empty()) {
        model.MoveNode(cmd.node_id,
                       NodeParent{NodeParentKind::kSpaceToday, new_space},
                       size_t{0});
        bridge->FocusSpace(new_space, window_id);
      }
      return;
    }
    case SidebarMenuAction::kMove:
      model.MoveNode(cmd.node_id, cmd.parent, cmd.index);
      return;
    case SidebarMenuAction::kNewFolderWithSelection:
      if (focused) {
        model.CreateFolder(NodeParent{NodeParentKind::kSpacePinned, *focused},
                           "Folder", std::nullopt, cmd.selected_node_ids);
      }
      return;
    case SidebarMenuAction::kClose:
      bridge->CloseNode(cmd.node_id);
      return;
    case SidebarMenuAction::kArchiveOtherTabs: {
      const SpaceID target_space =
          cmd.space_id.empty() ? focused.value_or(SpaceID()) : cmd.space_id;
      if (!target_space.empty()) {
        std::set<ItemID> keep(cmd.selected_node_ids.begin(),
                              cmd.selected_node_ids.end());
        model.ClearToday(target_space, keep);
      }
      return;
    }
    case SidebarMenuAction::kArchiveNodes:
      for (const ItemID& id : cmd.selected_node_ids) {
        bridge->CloseNode(id);
      }
      return;
    case SidebarMenuAction::kUnpin:
      model.UnpinTab(cmd.node_id);
      return;
    case SidebarMenuAction::kRemoveFavorite:
      model.RemoveFavorite(cmd.node_id);
      return;
    case SidebarMenuAction::kExportEasel:
    case SidebarMenuAction::kExportNote:
      bridge->SelectNode(cmd.node_id, window_id);
      return;
    case SidebarMenuAction::kDeleteEasel:
    case SidebarMenuAction::kDeleteNote:
      bridge->CloseNode(cmd.node_id);
      return;

    // --- Favorite tiles ---
    case SidebarMenuAction::kSetShowsUnreadBadge: {
      std::string err;
      webui::OpenPreferences::Get()->Set("previews.gmail", base::Value(cmd.flag),
                                         service_->ActiveProfileId(), true, &err);
      return;
    }
    case SidebarMenuAction::kSetShowsTimeToNextMeeting:
    case SidebarMenuAction::kSetLiveCalendarEnabled: {
      std::string err;
      webui::OpenPreferences::Get()->Set("previews.calendar",
                                         base::Value(cmd.flag),
                                         service_->ActiveProfileId(), true, &err);
      return;
    }
    case SidebarMenuAction::kCopyMeetingLink:
      if (!cmd.text.empty()) {
        ui::ScopedClipboardWriter(ui::ClipboardBuffer::kCopyPaste)
            .WriteText(base::UTF8ToUTF16(cmd.text));
        if (ui) {
          ui->ShowToast(ToastSpec::ForKind(OpenToastKind::kCopiedUrl));
        }
      }
      return;
    case SidebarMenuAction::kDismissMeeting:
      if (ui && ui->open_view() && ui->open_view()->sidebar()) {
        ui->open_view()->sidebar()->SetFavoriteSubtitle(cmd.node_id, u"");
      }
      return;
    case SidebarMenuAction::kSetMeetingReminder:
      return;

    // --- Split View rows ---
    case SidebarMenuAction::kShareSplit:
      if (const Split* split = model.FindSplit(cmd.node_id)) {
        std::vector<std::string> urls;
        for (const Tab& pane : split->panes) {
          urls.push_back(pane.url);
        }
        ui::ScopedClipboardWriter(ui::ClipboardBuffer::kCopyPaste)
            .WriteText(base::UTF8ToUTF16(base::JoinString(urls, "\n")));
        if (ui) {
          ui->ShowToast(ToastSpec::ForKind(OpenToastKind::kCopied));
        }
      }
      return;
    case SidebarMenuAction::kSeparateSplit:
      model.Unsplit(cmd.node_id);
      return;
    case SidebarMenuAction::kAddTabToSplit: {
      const ItemID blank = bridge->OpenTab(GURL("about:blank"), true, window_id);
      if (!blank.empty()) {
        model.AddPane(cmd.node_id, blank);
      }
      return;
    }
    case SidebarMenuAction::kSetSplitOrientation:
      model.SetSplitOrientation(cmd.node_id, cmd.flag
                                                 ? SplitOrientation::kVertical
                                                 : SplitOrientation::kHorizontal);
      return;
    case SidebarMenuAction::kSeparatePane:
      model.RemovePane(cmd.node_id, cmd.secondary_id, /*archive=*/false);
      return;
    case SidebarMenuAction::kResetSplitCustomization:
      if (const Split* split = model.FindSplit(cmd.node_id);
          split && !split->panes.empty()) {
        model.SetSplitFractions(
            cmd.node_id, std::vector<double>(split->panes.size(),
                                             1.0 / split->panes.size()));
      }
      return;

    // --- Folders ---
    case SidebarMenuAction::kShareFolder:
    case SidebarMenuAction::kCopyAllLinks:
      if (const Folder* folder = model.FindFolder(cmd.node_id)) {
        std::vector<std::pair<std::string, std::string>> items;
        CollectTabUrls(folder->children, &items);
        std::vector<std::string> lines;
        for (const auto& [title, url] : items) {
          lines.push_back(
              cmd.flag ? base::StrCat({"- [", title, "](", url, ")"}) : url);
        }
        ui::ScopedClipboardWriter(ui::ClipboardBuffer::kCopyPaste)
            .WriteText(base::UTF8ToUTF16(base::JoinString(lines, "\n")));
        if (ui) {
          ui->ShowToast(ToastSpec::ForKind(
              cmd.flag ? OpenToastKind::kCopiedMarkdown
                       : OpenToastKind::kCopied));
        }
      }
      return;
    case SidebarMenuAction::kNewNestedFolder:
      model.CreateFolder(NodeParent{NodeParentKind::kFolder, cmd.node_id});
      model.SetFolderExpanded(cmd.node_id, true);
      return;
    case SidebarMenuAction::kTurnFolderIntoSpace:
      if (const Folder* folder = model.FindFolder(cmd.node_id)) {
        const std::string title = folder->title;
        std::vector<ItemID> child_ids;
        for (const SidebarNode& child : folder->children) {
          child_ids.push_back(child.id());
        }
        const SpaceID new_space =
            model.CreateSpace(service_->ActiveProfileId(), title);
        if (!new_space.empty()) {
          for (const ItemID& cid : child_ids) {
            model.MoveNode(cid,
                           NodeParent{NodeParentKind::kSpacePinned, new_space});
          }
          bridge->CloseNode(cmd.node_id);
          bridge->FocusSpace(new_space, window_id);
        }
      }
      return;
    case SidebarMenuAction::kDeleteFolder:
    case SidebarMenuAction::kDeleteLiveFolder:
      bridge->CloseNode(cmd.node_id);
      if (ui) {
        ui->ShowToast(ToastSpec::ForKind(
            OpenToastKind::kFolderDeleted, {},
            base::BindOnce(
                [](base::WeakPtr<OpenWindowController> self) {
                  if (self) {
                    self->service_->model().Undo();
                  }
                },
                weak_factory_.GetWeakPtr())));
      }
      return;
    case SidebarMenuAction::kRefreshLiveFolder:
      if (OpenLiveDataService* ld = service_->livedata()) {
        ld->RefreshLiveFolder(cmd.node_id, /*force=*/true);
      }
      return;
    case SidebarMenuAction::kOpenLiveFolderSso:
      if (const Folder* folder = model.FindFolder(cmd.node_id);
          folder && folder->live_sso_url) {
        bridge->OpenTab(GURL(*folder->live_sso_url), false, window_id);
      }
      return;
    case SidebarMenuAction::kSetLiveRepository:
      return;

    // --- Multi-selection ---
    case SidebarMenuAction::kCopyLinks:
    case SidebarMenuAction::kShareNodes: {
      std::vector<std::string> lines;
      for (const ItemID& id : cmd.selected_node_ids) {
        if (const Tab* tab = model.FindTab(id)) {
          lines.push_back(
              cmd.flag
                  ? base::StrCat({"- [", tab->display_title(), "](", tab->url, ")"})
                  : tab->url);
        }
      }
      ui::ScopedClipboardWriter(ui::ClipboardBuffer::kCopyPaste)
          .WriteText(base::UTF8ToUTF16(base::JoinString(lines, "\n")));
      if (ui) {
        ui->ShowToast(ToastSpec::ForKind(OpenToastKind::kCopied));
      }
      return;
    }
    case SidebarMenuAction::kSetMuted:
      for (const ItemID& id : cmd.selected_node_ids) {
        model.SetMuted(id, cmd.flag);
        if (content::WebContents* wc = bridge->WebContentsForTab(id)) {
          wc->SetAudioMuted(cmd.flag);
        }
      }
      return;
    case SidebarMenuAction::kSplitNodes:
      if (cmd.selected_node_ids.size() >= 2) {
        model.MakeSplit(cmd.selected_node_ids);
      }
      return;
    case SidebarMenuAction::kDuplicateNodes:
      for (const ItemID& id : cmd.selected_node_ids) {
        model.DuplicateNode(id);
      }
      return;
    case SidebarMenuAction::kSetPinned:
      for (const ItemID& id : cmd.selected_node_ids) {
        if (cmd.flag) {
          model.PinTab(id);
        } else {
          model.UnpinTab(id);
        }
      }
      return;
    case SidebarMenuAction::kMoveNodesToSpace:
      if (!cmd.space_id.empty()) {
        for (const ItemID& id : cmd.selected_node_ids) {
          model.MoveNode(id,
                         NodeParent{NodeParentKind::kSpaceToday, cmd.space_id});
        }
      }
      return;
    case SidebarMenuAction::kMoveNodesToNewSpace: {
      const SpaceID new_space = model.CreateSpace(service_->ActiveProfileId());
      if (!new_space.empty()) {
        for (const ItemID& id : cmd.selected_node_ids) {
          model.MoveNode(id,
                         NodeParent{NodeParentKind::kSpaceToday, new_space});
        }
        bridge->FocusSpace(new_space, window_id);
      }
      return;
    }
    case SidebarMenuAction::kMoveNodes:
      for (const ItemID& id : cmd.selected_node_ids) {
        model.MoveNode(id, cmd.parent, cmd.index);
      }
      return;
    case SidebarMenuAction::kDeleteFolders:
      for (const ItemID& id : cmd.selected_node_ids) {
        bridge->CloseNode(id);
      }
      return;

    // --- Spaces ---
    case SidebarMenuAction::kChangeSpaceIcon:
      if (ui) {
        ui->ShowSpaceThemeEditor(
            cmd.space_id.empty() ? focused.value_or(SpaceID()) : cmd.space_id,
            /*open_identity_page=*/true);
      }
      return;
    case SidebarMenuAction::kEditSpaceTheme:
      if (ui) {
        ui->ShowSpaceThemeEditor(
            cmd.space_id.empty() ? focused.value_or(SpaceID()) : cmd.space_id,
            /*open_identity_page=*/false);
      }
      return;
    case SidebarMenuAction::kSetSpaceProfile:
      if (!cmd.space_id.empty() && !cmd.profile_id.empty()) {
        model.MoveSpaceToProfile(cmd.space_id, cmd.profile_id);
      }
      return;
    case SidebarMenuAction::kNewProfile:
      OpenSettingsWindow("profiles");
      return;
    case SidebarMenuAction::kSetSpaceHeaderShown:
      return;
    case SidebarMenuAction::kNewFolder: {
      const SpaceID sid =
          cmd.space_id.empty() ? focused.value_or(SpaceID()) : cmd.space_id;
      if (!sid.empty()) {
        model.CreateFolder(cmd.parent.owner_id.empty()
                               ? NodeParent{NodeParentKind::kSpacePinned, sid}
                               : cmd.parent);
      }
      return;
    }
    case SidebarMenuAction::kToggleLiveFolder:
      if (!cmd.space_id.empty()) {
        const ItemID fid = model.CreateFolder(
            NodeParent{NodeParentKind::kSpacePinned, cmd.space_id},
            "GitHub PRs");
        if (Folder* folder = model.FindFolder(fid)) {
          LiveFolderConfig cfg;
          cfg.provider = "github_prs";
          cfg.query = "is:open is:pr";
          folder->live = cfg;
          if (OpenLiveDataService* ld = service_->livedata()) {
            ld->RegisterLiveFolder(fid, cfg);
            ld->RefreshLiveFolder(fid, /*force=*/true);
          }
          service_->ScheduleSave();
        }
      }
      return;
    case SidebarMenuAction::kShareSpace:
      if (const Space* space = model.FindSpace(cmd.space_id)) {
        std::vector<std::pair<std::string, std::string>> items;
        CollectTabUrls(space->pinned, &items);
        CollectTabUrls(space->today, &items);
        std::vector<std::string> lines;
        for (const auto& [title, url] : items) {
          lines.push_back(base::StrCat({"- [", title, "](", url, ")"}));
        }
        ui::ScopedClipboardWriter(ui::ClipboardBuffer::kCopyPaste)
            .WriteText(base::UTF8ToUTF16(base::JoinString(lines, "\n")));
        if (ui) {
          ui->ShowToast(ToastSpec::ForKind(OpenToastKind::kCopied));
        }
      }
      return;
    case SidebarMenuAction::kExportSpaceIntoFolder:
      if (const Space* src = model.FindSpace(cmd.space_id);
          src && !cmd.secondary_id.empty()) {
        std::vector<ItemID> ids;
        for (const SidebarNode& n : src->pinned) {
          ids.push_back(n.id());
        }
        model.CreateFolder(
            NodeParent{NodeParentKind::kSpacePinned, cmd.secondary_id},
            src->title.value_or("Space"), std::nullopt, ids);
      }
      return;
    case SidebarMenuAction::kManageSpaces:
      if (ui) {
        ui->ShowLibraryDrawer("spaces");
      }
      return;
    case SidebarMenuAction::kDeleteSpace:
      if (!cmd.space_id.empty()) {
        model.DeleteSpace(cmd.space_id, /*archive_tabs=*/true);
        if (ui) {
          ui->ShowToast(ToastSpec::ForKind(
              OpenToastKind::kSpaceDeleted, {},
              base::BindOnce(
                  [](base::WeakPtr<OpenWindowController> self) {
                    if (self) {
                      self->service_->model().Undo();
                    }
                  },
                  weak_factory_.GetWeakPtr())));
        }
      }
      return;

    // --- "+" ---
    case SidebarMenuAction::kNewSpace:
      if (ui) {
        ui->ShowSpaceCreation(nullptr);
      }
      return;
    case SidebarMenuAction::kNewEasel:
      if (ui) {
        ui->HandleCommand(CommandId::kNewEasel);
      }
      return;
    case SidebarMenuAction::kNewNote:
      if (ui) {
        ui->HandleCommand(CommandId::kNewNote);
      }
      return;
    case SidebarMenuAction::kNewBoost:
      if (ui) {
        ui->OpenBoostEditor(std::nullopt);
      }
      return;
    case SidebarMenuAction::kNewSplit:
      if (ui) {
        ui->HandleCommand(CommandId::kAddSplitView);
      }
      return;
    case SidebarMenuAction::kNewTab:
      if (ui) {
        ui->HandleCommand(CommandId::kNewTab);
      }
      return;

    // --- URL field ---
    case SidebarMenuAction::kCopyCurrentUrl:
      HandleIntent(window_id, OpenIntent::Of(OpenIntentKind::kCopyCurrentUrl));
      return;
    case SidebarMenuAction::kSharePageVia:
      if (content::WebContents* wc = ActiveWebContentsFor(window_id)) {
        site_control_data::CopyCleanUrl(wc->GetLastCommittedURL());
        if (ui) {
          ui->ShowToast(ToastSpec::ForKind(OpenToastKind::kCopiedCleanLink));
        }
      }
      return;
    case SidebarMenuAction::kCapture:
      if (ui) {
        ui->HandleCommand(CommandId::kCapturePage);
      }
      return;
    case SidebarMenuAction::kCaptureFullPage:
      if (ui) {
        ui->HandleCommand(CommandId::kCaptureFullPage);
      }
      return;
    case SidebarMenuAction::kCapturePortrait:
      if (ui) {
        ui->HandleCommand(CommandId::kCapturePortrait);
      }
      return;
    case SidebarMenuAction::kSetToolbarShown:
      if (ui) {
        ui->HandleCommand(CommandId::kToggleToolbar);
      }
      return;
    case SidebarMenuAction::kSetSharedQuotes: {
      std::string err;
      webui::OpenPreferences::Get()->Set("advanced.sharedQuotes",
                                         base::Value(cmd.flag),
                                         service_->ActiveProfileId(), true, &err);
      return;
    }

    // --- Toolbar "More options" ---
    case SidebarMenuAction::kReload:
      NavigateActive(window_id, 0);
      return;
    case SidebarMenuAction::kStopLoading:
      HandleIntent(window_id, OpenIntent::Of(OpenIntentKind::kStopLoading));
      return;
    case SidebarMenuAction::kToggleSidebar:
      HandleIntent(window_id, OpenIntent::Of(OpenIntentKind::kToggleSidebar));
      return;

    // --- Pinned extension action ---
    case SidebarMenuAction::kRunToolbarAction:
      if (OpenExtensionBridge* extensions = ExtensionBridgeForWindow(window_id)) {
        BrowserWindowInterface* browser =
            ui && ui->browser_view() ? ui->browser_view()->browser() : nullptr;
        if (browser) {
          extensions->ExecuteAction(browser, cmd.text, nullptr, std::nullopt,
                                    base::DoNothing());
        } else {
          extensions->ExecuteAction(cmd.text, nullptr, base::DoNothing());
        }
      }
      return;
    case SidebarMenuAction::kUnpinToolbarAction:
      if (OpenExtensionBridge* extensions = ExtensionBridgeForWindow(window_id)) {
        extensions->SetActionPinned(cmd.text, false);
      }
      return;
    case SidebarMenuAction::kManageExtension:
    case SidebarMenuAction::kExtensionOptions:
    case SidebarMenuAction::kRemoveExtension:
    case SidebarMenuAction::kInspectExtensionPopup:
      bridge->OpenTab(
          GURL(base::StrCat({"chrome://extensions/?id=", cmd.text})),
          /*background=*/false, window_id);
      return;

    // --- Library button ---
    case SidebarMenuAction::kToggleLibraryMediaSource:
      if (ui) {
        ui->ShowLibraryDrawer("media");
      }
      return;
  }
}

void OpenWindowController::AddViewObserver(OpenViewObserver* observer) {
  view_observers_.AddObserver(observer);
}

void OpenWindowController::RemoveViewObserver(OpenViewObserver* observer) {
  view_observers_.RemoveObserver(observer);
}

// --- Observer Notifications --------------------------------------------------

void OpenWindowController::NotifyWindowStateChanged() {
  for (const BrowserWindowState& window : service_->model().windows()) {
    for (OpenViewObserver& observer : view_observers_) {
      observer.OnWindowStateChanged(window.id);
      observer.OnActiveTabChanged(window.id);
    }
  }
  for (const BrowserWindowState& window :
       service_->model().incognito_windows()) {
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
      if (!change.space_id.empty()) {
        for (OpenViewObserver& observer : view_observers_) {
          observer.OnSpaceThemeChanged(change.space_id);
        }
        for (const BrowserWindowState& window : service_->model().windows()) {
          for (OpenViewObserver& observer : view_observers_) {
            observer.OnSpacesChanged(window.id);
          }
        }
        for (const BrowserWindowState& window :
             service_->model().incognito_windows()) {
          for (OpenViewObserver& observer : view_observers_) {
            observer.OnSpacesChanged(window.id);
          }
        }
        for (auto& [browser_view, ui] : windows_) {
          ui->UpdateThemeForLiveSurfaces();
        }
        NotifyWindowStateChanged();
      } else if (change.node_id.empty()) {
        NotifyWindowStateChanged();
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
      for (auto& [browser_view, ui] : windows_) {
        ui->UpdateThemeForLiveSurfaces();
      }
      break;
    case TreeChange::Kind::kInsert:
    case TreeChange::Kind::kRemove:
    case TreeChange::Kind::kMove: {
      const bool from_fav = change.parent.kind == NodeParentKind::kFavorites;
      const bool to_fav = change.to_parent.kind == NodeParentKind::kFavorites;
      if (from_fav) {
        for (OpenViewObserver& observer : view_observers_) {
          observer.OnFavoritesChanged(change.parent.owner_id);
        }
      }
      if (to_fav &&
          (!from_fav || change.to_parent.owner_id != change.parent.owner_id)) {
        for (OpenViewObserver& observer : view_observers_) {
          observer.OnFavoritesChanged(change.to_parent.owner_id);
        }
      }
      for (auto& [browser_view, ui] : windows_) {
        ui->UpdatePanel();
      }
      break;
    }
  }
  for (auto& [browser_view, ui] : windows_) {
    ui->OnModelChanged();
  }
}

void OpenWindowController::OnTabActivated(const ItemID& tab_id) {
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
  base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE,
      base::BindOnce(
          [](base::WeakPtr<OpenWindowController> self) {
            if (!self) {
              return;
            }
            for (auto& [browser_view, ui] : self->windows_) {
              ui->UpdatePanel();
            }
            for (const BrowserWindowState& window :
                 self->service_->model().windows()) {
              for (OpenViewObserver& observer : self->view_observers_) {
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

void OpenWindowController::OnBrowserWindowBound(BrowserWindowInterface* browser,
                                                const WindowID& window_id) {
  if (!browser || window_id.empty()) {
    return;
  }
  BrowserView* bv = BrowserView::GetBrowserViewForBrowser(browser);
  if (!bv) {
    return;
  }
  bool rebound = false;
  if (OpenBrowserView* open_view = OpenBrowserView::FromBrowserView(bv);
      open_view && open_view->window_id() != window_id) {
    open_view->RebindWindowId(window_id);
    rebound = true;
  }
  OpenWindowUi* ui = WindowUiForBrowserView(bv);
  if (ui && ui->window_id() != window_id) {
    ui->RebindWindowId(window_id);
    rebound = true;
  } else if (rebound && ui) {
    ui->UpdateThemeForLiveSurfaces();
    ui->UpdatePanel();
  }
  if (rebound) {
    for (OpenViewObserver& observer : view_observers_) {
      observer.OnSpacesChanged(window_id);
      observer.OnWindowStateChanged(window_id);
      observer.OnActiveTabChanged(window_id);
    }
  }
}

void OpenWindowController::OnExtensionActionsChanged() {
  RefreshSuggestExtensions();
  for (const BrowserWindowState& window : service_->model().windows()) {
    for (OpenViewObserver& observer : view_observers_) {
      observer.OnToolbarActionsChanged(window.id);
    }
  }
  for (const auto& lo : little_opens_) {
    lo->RefreshState();
  }
}

void OpenWindowController::OnOpenEvent(const std::string& event_name,
                                       const base::Value& payload) {
  if (event_name == kEventLibraryCloseRequested) {
    WindowID target_id;
    if (const base::DictValue* dict = payload.GetIfDict()) {
      target_id = json::GetString(*dict, "window_id");
    }
    if (OpenWindowUi* ui =
            !target_id.empty() ? WindowUiFor(target_id) : MainWindowUi()) {
      ui->HideLibraryDrawer();
    }
    return;
  }
  if (event_name == webui::onboarding_rpc::kEventOnboardingCompleted) {
    OnOnboardingCompleted();
    return;
  }
  if (event_name == webui::boosts_rpc::kEventEditRequested) {
    if (const base::DictValue* dict = payload.GetIfDict()) {
      const std::string boost_id = json::GetString(*dict, "boost_id");
      const std::string wid = json::GetString(*dict, "window_id");
      const bool zap = json::GetBool(*dict, "zap", false);
      OpenWindowUi* ui = !wid.empty() ? WindowUiFor(wid) : MainWindowUi();
      if (ui) {
        ui->OpenBoostEditor(boost_id.empty()
                                ? std::nullopt
                                : std::optional<std::string>(boost_id),
                            zap);
      }
    }
    return;
  }
}

void OpenWindowController::OnDownloadUpdatedForProfile(
    const ProfileID& profile_id,
    const DownloadRecord& record) {
  for (auto& [browser_view, ui] : windows_) {
    ui->RefreshDownloadProgress();
    ui->RefreshDownloadsPopover();
  }
  for (const auto& lo : little_opens_) {
    if (lo->profile_id() == profile_id) {
      lo->RefreshState();
    }
  }
}

void OpenWindowController::OnDownloadRemoved(const std::string& id) {
  for (auto& [browser_view, ui] : windows_) {
    ui->RefreshDownloadProgress();
    ui->RefreshDownloadsPopover();
  }
  for (const auto& lo : little_opens_) {
    lo->RefreshState();
  }
}

void OpenWindowController::OnMediaSessionsChanged() {
  for (auto& [browser_view, ui] : windows_) {
    ui->RefreshMediaSessions();
  }
}

void OpenWindowController::OnFavoriteSubtitleChanged(
    const ItemID& tab_id,
    const std::string& subtitle) {
  const std::u16string text = base::UTF8ToUTF16(subtitle);
  for (auto& [browser_view, ui] : windows_) {
    if (ui->open_view() && ui->open_view()->sidebar()) {
      ui->open_view()->sidebar()->SetFavoriteSubtitle(tab_id, text);
    }
  }
}

void OpenWindowController::OnFavoriteBadgeChanged(
    const ItemID& tab_id,
    const std::string& badge_text) {
  const std::u16string text = base::UTF8ToUTF16(badge_text);
  for (auto& [browser_view, ui] : windows_) {
    if (ui->open_view() && ui->open_view()->sidebar()) {
      ui->open_view()->sidebar()->SetFavoriteBadge(tab_id, text);
    }
  }
}

void OpenWindowController::OnLiveFolderUpdated(
    const ItemID& folder_id,
    const std::vector<LiveFolderItem>& items,
    int unread_count) {
  TreeChange change;
  change.kind = TreeChange::Kind::kUpdate;
  change.node_id = folder_id;
  for (OpenViewObserver& observer : view_observers_) {
    observer.OnTreeChanged(change);
  }
}

// --- OpenCaptureController::Delegate -----------------------------------------

void OpenWindowController::OnCaptureCompleted(const CaptureResult& result) {
  OpenWindowUi* ui = MainWindowUi();
  if (!ui) {
    return;
  }
  ui->ShowToast(ToastSpec::ForKind(
      OpenToastKind::kCaptureSaved, {},
      base::BindOnce(
          [](base::WeakPtr<OpenWindowController> self) {
            if (self) {
              if (OpenWindowUi* main_ui = self->MainWindowUi()) {
                main_ui->ShowLibraryDrawer("media");
              }
            }
          },
          weak_factory_.GetWeakPtr())));
}

void OpenWindowController::OnCaptureFailed(const std::string& error_message) {
  if (OpenWindowUi* ui = MainWindowUi()) {
    ui->ShowToast(
        ToastSpec::Error(u"Capture Failed", base::UTF8ToUTF16(error_message)));
  }
}

void OpenWindowController::OnCaptureOpenInLibrary(const CaptureResult& result) {
  if (OpenWindowUi* ui = MainWindowUi()) {
    ui->ShowLibraryDrawer("media");
  }
}

void OpenWindowController::OnCaptureAddToEasel(const CaptureResult& result) {
  ProfileServices* ps =
      service_->ProfileServicesFor(service_->ActiveProfileId());
  if (!ps) {
    return;
  }
  std::vector<uint8_t> png = result.png_bytes;
  const int w = result.pixel_width > 0 ? std::min(result.pixel_width, 800) : 480;
  const int h =
      result.pixel_height > 0 ? std::min(result.pixel_height, 600) : 320;
  const std::string title =
      result.title.empty() ? "Capture Easel" : result.title;
  RunOnStore(
      ps->documents,
      base::BindOnce(
          [](std::vector<uint8_t> png_bytes, int width, int height,
             std::string doc_title, DocumentStore* store) -> std::string {
            EaselDocument doc = store->CreateEasel();
            doc.title = std::move(doc_title);
            if (!png_bytes.empty()) {
              if (auto filename =
                      store->SaveEaselImage(doc.id, png_bytes, "png")) {
                EaselElement img;
                img.id = base::Uuid::GenerateRandomV4().AsLowercaseString();
                img.type = "image";
                img.x = 60.0;
                img.y = 60.0;
                img.width = static_cast<double>(width);
                img.height = static_cast<double>(height);
                img.content = *filename;
                doc.elements.push_back(std::move(img));
              }
            }
            store->SaveEasel(doc);
            return doc.id;
          },
          std::move(png), w, h, title),
      base::BindOnce(
          [](base::WeakPtr<OpenWindowController> self, std::string easel_id) {
            if (!self || easel_id.empty() || !self->service_->tab_bridge()) {
              return;
            }
            self->service_->tab_bridge()->OpenTab(
                GURL(webui::OpenWebUIURL(webui::kHostEasel, easel_id)),
                /*background=*/false);
            if (OpenWindowUi* ui = self->MainWindowUi()) {
              ui->ActivateWindow();
            }
          },
          weak_factory_.GetWeakPtr()));
}

// --- hooks::OpenHookDelegate -------------------------------------------------

bool OpenWindowController::ShouldTerminateApp() {
  if (!started_ || IsAutomationLaunch()) {
    return true;
  }
  const bool warn_pref = PrefBool("general.warnBeforeQuitting", false);
#if BUILDFLAG(IS_MAC)
  const bool active_downloads =
      service_->download_bridge() &&
      service_->download_bridge()->HasActiveDownloads();
#else
  // On Windows/Linux, BrowserCloseManager::TryToCloseBrowsers() already runs
  // CheckForDownloadsInProgress(); only prompt for warnBeforeQuitting here so
  // users never see two download confirmation dialogs back to back.
  const bool active_downloads = false;
#endif
  if (!warn_pref && !active_downloads) {
    return true;
  }
  gfx::NativeWindow parent = gfx::NativeWindow();
  if (OpenWindowUi* ui = MainWindowUi(); ui && ui->widget()) {
    parent = ui->widget()->GetNativeWindow();
  }
  const std::u16string message =
      active_downloads
          ? u"Downloads are currently in progress. Are you sure you want to "
            u"quit Open?"
          : u"Are you sure you want to quit Open?";
  return chrome::ShowQuestionMessageBoxSync(parent, u"Quit Open?", message) ==
         chrome::MESSAGE_BOX_RESULT_YES;
}

bool OpenWindowController::HandleAppReopen(bool has_visible_windows) {
  if (!started_) {
    return false;
  }
  if (has_visible_windows) {
    if (OpenWindowUi* ui = MainWindowUi()) {
      ui->ActivateWindow();
      return true;
    }
    return false;
  }
  // Un-minimize or reveal an existing hidden window first.
  for (auto& [browser_view, ui] : windows_) {
    if (views::Widget* w = ui->widget()) {
      if (w->IsMinimized()) {
        w->Restore();
      }
      w->Show();
      w->Activate();
      return true;
    }
  }
  if (service_->model().last_closed_window().has_value()) {
    const WindowID restored = service_->ReopenLastClosedWindow();
    if (!restored.empty()) {
      return true;
    }
  }
  if (OpenTabBridge* bridge = service_->tab_bridge()) {
    bridge->OpenNewWindow();
    return true;
  }
  return false;
}

std::optional<bool> OpenWindowController::IsBrowserCommandEnabled(
    BrowserWindowInterface* browser,
    int command_id) {
  std::optional<CommandId> cid = MapMenuOrChromiumCommandToOpen(command_id);
  if (!cid.has_value()) {
    return std::nullopt;
  }
  const CommandDefinition* def = service_->commands().FindById(*cid);
  if (!def || def->is_reserved) {
    return false;
  }
  OpenWindowUi* ui = WindowUiForBrowser(browser);
  const BrowserModel& model = service_->model();
  content::WebContents* wc = ui ? ui->ActiveWebContents() : nullptr;
  std::optional<ItemID> active_id = ui ? ui->ActiveTabId() : std::nullopt;
  const Tab* active_tab = active_id ? model.FindTab(*active_id) : nullptr;

  switch (def->availability_predicate) {
    case AvailabilityPredicate::kAlways:
    case AvailabilityPredicate::kHasHistory:
    case AvailabilityPredicate::kNotTracing:
    case AvailabilityPredicate::kTextFieldFocused:
      return true;
    case AvailabilityPredicate::kIsTracing:
      return false;
    case AvailabilityPredicate::kHasCurrentTab:
      return active_id.has_value();
    case AvailabilityPredicate::kHasWebPage:
      return wc != nullptr;
    case AvailabilityPredicate::kCanGoBack:
      return wc && wc->GetController().CanGoBack();
    case AvailabilityPredicate::kCanGoForward:
      return wc && wc->GetController().CanGoForward();
    case AvailabilityPredicate::kCurrentTabPinned:
      return active_id && model.IsPinned(*active_id);
    case AvailabilityPredicate::kCurrentTabInToday:
      return active_id && model_util::SectionOfNode(model, *active_id) ==
                              NodeParentKind::kSpaceToday;
    case AvailabilityPredicate::kCurrentTabHasPinnedUrl:
      return active_tab && active_tab->pinned_url.has_value() &&
             !active_tab->pinned_url->empty();
    case AvailabilityPredicate::kCurrentTabIsFavorite:
      return active_id && model.IsFavorite(*active_id);
    case AvailabilityPredicate::kCurrentTabNotFavorite:
      return active_id && !model.IsFavorite(*active_id);
    case AvailabilityPredicate::kCurrentTabInSplit:
      return ui && ui->split_active();
    case AvailabilityPredicate::kHasMultipleSpaces:
      return ui && GetWindowSpaceIds(ui->window_id()).size() > 1;
  }
  return true;
}

bool OpenWindowController::HandleBrowserCommand(
    BrowserWindowInterface* browser,
    int command_id) {
  std::optional<CommandId> cid = MapMenuOrChromiumCommandToOpen(command_id);
  if (!cid.has_value()) {
    return false;
  }
  OpenWindowUi* ui = WindowUiForBrowser(browser);
  return ui && ui->HandleCommand(*cid);
}

bool OpenWindowController::MaybeInterceptLinkOpen(
    BrowserWindowInterface* browser,
    content::WebContents* source,
    const content::OpenURLParams& params) {
  if (!started_ || !browser || !params.url.is_valid() ||
      !params.url.SchemeIsHTTPOrHTTPS() || params.started_from_context_menu) {
    return false;
  }
  if (PeekPolicy::IsAuthenticationFlow(params.url.spec())) {
    return false;
  }
  OpenWindowUi* ui = WindowUiForBrowser(browser);
  if (!ui) {
    return false;
  }
  // Honor Split View disposition directly.
  if (params.disposition == WindowOpenDisposition::NEW_SPLIT_VIEW) {
    ui->OpenLinkInSplitView(params.url);
    return true;
  }
  if (!params.is_renderer_initiated || !params.user_gesture) {
    return false;
  }

  const std::optional<ItemID> source_tab_id =
      OpenTabBridge::TabIdForWebContents(source);
  const BrowserModel& model = service_->model();
  const Tab* source_tab =
      source_tab_id ? model.FindTab(*source_tab_id) : nullptr;
  const bool source_is_pinned_or_fav =
      source_tab_id &&
      (model.IsPinned(*source_tab_id) || model.IsFavorite(*source_tab_id));

  // Shift+Click on a link arrives as WindowOpenDisposition::NEW_WINDOW.
  const bool shift_click =
      params.disposition == WindowOpenDisposition::NEW_WINDOW;
  const bool is_link_click =
      ui::PageTransitionCoreTypeIs(params.transition, ui::PAGE_TRANSITION_LINK);
  const bool eligible_disposition =
      shift_click ||
      (is_link_click &&
       (params.disposition == WindowOpenDisposition::CURRENT_TAB ||
        params.disposition == WindowOpenDisposition::NEW_FOREGROUND_TAB ||
        params.disposition == WindowOpenDisposition::NEW_BACKGROUND_TAB));
  if (!eligible_disposition) {
    return false;
  }

  const bool peek_shift = PrefBool("links.peekShiftClick", true);
  const bool peek_other_sites = PrefBool("links.peekOtherSites", true);
  if (PeekPolicy::ShouldOpenInPeek(params.url.spec(), source_tab,
                                   source_is_pinned_or_fav, shift_click,
                                   peek_other_sites, peek_shift)) {
    ui->OpenPeek(params.url, source_tab_id);
    return true;
  }
  return false;
}

bool OpenWindowController::MaybeInterceptAddNewContents(
    BrowserWindowInterface* browser,
    content::WebContents* source,
    std::unique_ptr<content::WebContents>& new_contents,
    const GURL& target_url,
    WindowOpenDisposition disposition,
    bool user_gesture) {
  if (!started_ || !browser || !new_contents || !user_gesture) {
    return false;
  }
  if (disposition == WindowOpenDisposition::NEW_POPUP ||
      disposition == WindowOpenDisposition::NEW_PICTURE_IN_PICTURE) {
    return false;
  }
  const GURL url =
      target_url.is_valid() ? target_url : new_contents->GetVisibleURL();
  if (!url.is_valid() || !url.SchemeIsHTTPOrHTTPS() ||
      PeekPolicy::IsAuthenticationFlow(url.spec())) {
    return false;
  }
  OpenWindowUi* ui = WindowUiForBrowser(browser);
  if (!ui) {
    return false;
  }

  if (disposition == WindowOpenDisposition::NEW_SPLIT_VIEW) {
    OpenTabBridge* bridge = service_->tab_bridge();
    const std::optional<SpaceID> focused =
        model_util::FocusedSpace(service_->model(), ui->window_id());
    if (bridge && focused) {
      const std::optional<ItemID> active = ui->ActiveTabId();
      const ItemID adopted = bridge->AdoptLiveWebContentsAsTab(
          std::move(new_contents), *focused, /*background=*/true,
          ui->window_id());
      if (active && !adopted.empty()) {
        service_->model().MakeSplit({*active, adopted});
      }
      return true;
    }
    return false;
  }

  const std::optional<ItemID> source_tab_id =
      OpenTabBridge::TabIdForWebContents(source);
  const BrowserModel& model = service_->model();
  const Tab* source_tab =
      source_tab_id ? model.FindTab(*source_tab_id) : nullptr;
  const bool source_is_pinned_or_fav =
      source_tab_id &&
      (model.IsPinned(*source_tab_id) || model.IsFavorite(*source_tab_id));
  const bool shift_click = disposition == WindowOpenDisposition::NEW_WINDOW;
  const bool peek_shift = PrefBool("links.peekShiftClick", true);
  const bool peek_other_sites = PrefBool("links.peekOtherSites", true);

  if ((shift_click ||
       disposition == WindowOpenDisposition::NEW_FOREGROUND_TAB ||
       disposition == WindowOpenDisposition::NEW_BACKGROUND_TAB) &&
      PeekPolicy::ShouldOpenInPeek(url.spec(), source_tab,
                                   source_is_pinned_or_fav, shift_click,
                                   peek_other_sites, peek_shift)) {
    ui->OpenPeekWithContents(std::move(new_contents), source_tab_id);
    return true;
  }
  return false;
}

void OpenWindowController::OnUpdateTargetURL(BrowserWindowInterface* browser,
                                             content::WebContents* source,
                                             const GURL& url) {
  if (OpenWindowUi* ui = WindowUiForBrowser(browser)) {
    ui->UpdateLinkStatusUrl(url);
  }
}

void OpenWindowController::OnFullscreenStateChanged(BrowserView* browser_view,
                                                    bool is_fullscreen) {
  if (OpenWindowUi* ui = WindowUiForBrowserView(browser_view)) {
    ui->OnFullscreenStateChanged(is_fullscreen);
  }
}

bool OpenWindowController::ExecuteWebContextMenuCommand(
    BrowserWindowInterface* browser,
    content::WebContents* source,
    const content::ContextMenuParams& params,
    int command_id,
    int event_flags) {
  OpenWindowUi* ui = WindowUiForBrowser(browser);
  switch (command_id) {
    case hooks::kOpenContextOpenLinkInPeek:
      if (ui && params.link_url.is_valid()) {
        ui->OpenPeek(params.link_url, ui->ActiveTabId());
        return true;
      }
      return false;
    case hooks::kOpenContextOpenLinkInSplitView:
      if (ui && params.link_url.is_valid()) {
        ui->OpenLinkInSplitView(params.link_url);
        return true;
      }
      return false;
    case hooks::kOpenContextOpenLinkInLittleOpen:
      if (params.link_url.is_valid()) {
        OpenLittleOpen(params.link_url);
        return true;
      }
      return false;
    case hooks::kOpenContextCopyCleanLink:
      if (params.link_url.is_valid()) {
        site_control_data::CopyCleanUrl(params.link_url);
        if (ui) {
          ui->ShowToast(ToastSpec::ForKind(OpenToastKind::kCopiedUrl));
        }
        return true;
      }
      return false;
    case hooks::kOpenContextCapturePage:
      return ui && ui->HandleCommand(CommandId::kCapturePage);
    case hooks::kOpenContextCaptureFullPage:
      return ui && ui->HandleCommand(CommandId::kCaptureFullPage);
    case hooks::kOpenContextNewBoostForSite:
      if (ui) {
        ui->OpenBoostEditor(std::nullopt);
        return true;
      }
      return false;
    case hooks::kOpenContextTranslateSelection:
      if (OpenTranslateController* tc = service_->translate_controller();
          tc && source && !params.selection_text.empty() && ui && ui->widget()) {
        const gfx::Rect container = source->GetContainerBounds();
        const gfx::Rect anchor(container.x() + params.x,
                               container.y() + params.y, 1, 1);
        tc->ShowSelectionPopover(source,
                                 base::UTF16ToUTF8(params.selection_text),
                                 ui->widget(), anchor, ui->CurrentAppearance());
        return true;
      }
      return false;
    default:
      return false;
  }
}

views::View* OpenWindowController::GetBubbleAnchorView(
    BrowserWindowInterface* browser) {
  OpenWindowUi* ui = WindowUiForBrowser(browser);
  OpenBrowserView* open_view = ui ? ui->open_view() : nullptr;
  if (!open_view || !open_view->IsDrawn()) {
    return nullptr;
  }
  if (!open_view->sidebar_hidden()) {
    if (views::View* sc = open_view->GetSiteControlAnchorView();
        sc && sc->IsDrawn()) {
      return sc;
    }
    if (views::View* pill = open_view->GetUrlPillView();
        pill && pill->IsDrawn()) {
      return pill;
    }
  }
  if (views::View* panel = open_view->web_contents_host();
      panel && panel->IsDrawn()) {
    return panel;
  }
  return open_view;
}

std::optional<gfx::Rect> OpenWindowController::GetBubbleAnchorRect(
    BrowserWindowInterface* browser) {
  OpenWindowUi* ui = WindowUiForBrowser(browser);
  OpenBrowserView* open_view = ui ? ui->open_view() : nullptr;
  if (!open_view || !open_view->IsDrawn()) {
    return std::nullopt;
  }
  if (!open_view->sidebar_hidden()) {
    if (views::View* sc = open_view->GetSiteControlAnchorView();
        sc && sc->IsDrawn()) {
      return sc->GetBoundsInScreen();
    }
    if (views::View* pill = open_view->GetUrlPillView();
        pill && pill->IsDrawn()) {
      return pill->GetBoundsInScreen();
    }
  }
  gfx::Rect panel = open_view->GetPanelBounds();
  gfx::Point origin = panel.origin();
  views::View::ConvertPointToScreen(open_view, &origin);
  return gfx::Rect(origin.x() + 16, origin.y() + 8, 1, 1);
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
  split_ = static_cast<OpenSplitContainerView*>(open_view_->SetSplitContainer(
      std::make_unique<OpenSplitContainerView>(this)));

  // An empty, event-transparent view that Track 4 lays out to the web
  // panel's bounds: the Find bar, Toast widgets, and Link Status Bubble follow
  // it.
  auto tracker = std::make_unique<views::View>();
  tracker->SetCanProcessEventsWithinSubtree(false);
  panel_tracker_ = open_view_->SetOverlay(
      OpenBrowserView::OverlaySlot::kFindBarAndToasts, std::move(tracker));
  panel_observation_.Observe(panel_tracker_.get());

  if (views::Widget* w = widget()) {
    widget_observation_.Observe(w);
  }

  // Traffic lights placement callback (subtracting kTrafficLightFrames[0]
  // origin so OpenPlatform::PlaceWindowButtons receives the live offset delta).
  open_view_->SetTrafficLightsCallback(base::BindRepeating(
      [](base::WeakPtr<OpenWindowUi> self, const gfx::Point& origin,
         bool visible) {
        if (!self) {
          return;
        }
        views::Widget* w = self->widget();
        if (OpenPlatform* platform = OpenPlatform::Get(); platform && w) {
          const gfx::Point delta(
              origin.x() -
                  static_cast<int>(metrics::chrome::kTrafficLightFrames[0].x),
              origin.y() -
                  static_cast<int>(metrics::chrome::kTrafficLightFrames[0].y));
          platform->PlaceWindowButtons(w, delta, visible, /*dimmed=*/true);
        }
      },
      weak_factory_.GetWeakPtr()));

  MountMediaPlayerStack();
  MountLinkStatusBubble();

  last_focused_space_ = model_util::FocusedSpace(service()->model(), window_id_);
  if (const Tab* active = controller_->GetActiveTab(window_id_)) {
    mru_.push_back(active->id);
  }
  RegisterAccelerators();
  ApplyWindowEffects();
  UpdatePanel();
}

OpenWindowUi::~OpenWindowUi() {
  if (remote_suggest_request_id_ != 0) {
    service()->suggest().CancelRemoteSuggestions(remote_suggest_request_id_);
    remote_suggest_request_id_ = 0;
  }
  DetachExtensionWindow();
  if (views::FocusManager* focus_manager = browser_view_->GetFocusManager()) {
    focus_manager->UnregisterAccelerators(this);
  }
  escape_priority_ = EscapePriority::kNone;
  switcher_monitor_.reset();
  widget_observation_.Reset();
  panel_observation_.Reset();

  // Close all popovers, editors, and child overlay widgets BEFORE tearing down
  // OpenBrowserView slots so no view retains a dangling delegate pointer.
  plus_popover_.Close();
  more_popover_.Close();
  downloads_popover_.reset();
  space_editor_popover_.Close();
  if (boost_editor_) {
    boost_editor_->Close();
    boost_editor_.reset();
  }
  site_controls_.reset();

  if (find_bar_) {
    find_bar_->StopFinding();
    find_bar_->SetTarget(nullptr);
  }
  find_bar_ = nullptr;
  find_host_.reset();

  toasts_ = nullptr;
  toast_host_.reset();

  switcher_ = nullptr;
  switcher_host_.reset();

  if (library_web_view_) {
    static_cast<LibraryDrawerWebView*>(library_web_view_.get())
        ->ClearBrowserFocusManager();
    library_web_view_ = nullptr;
  }
  library_host_.reset();

  if (peek_) {
    peek_->Hide();
  }
  peek_ = nullptr;
  peek_host_.reset();

  command_bar_ = nullptr;
  command_bar_host_.reset();

  link_status_ = nullptr;
  media_stack_ = nullptr;

  if (open_view_) {
    open_view_->SetTrafficLightsCallback(base::NullCallback());
    if (open_view_->sidebar()) {
      open_view_->sidebar()->SetMediaPlayerStack(nullptr);
    }
    open_view_->SetOverlay(OpenBrowserView::OverlaySlot::kCommandBar, nullptr);
    open_view_->SetOverlay(OpenBrowserView::OverlaySlot::kPeek, nullptr);
    open_view_->SetOverlay(OpenBrowserView::OverlaySlot::kFindBarAndToasts,
                           nullptr);
    split_ = nullptr;
    open_view_->SetSplitContainer(nullptr);
  }
  panel_tracker_ = nullptr;
}

void OpenWindowUi::RebindWindowId(const WindowID& window_id) {
  if (window_id.empty() || window_id_ == window_id) {
    return;
  }
  window_id_ = window_id;
  last_focused_space_ =
      model_util::FocusedSpace(service()->model(), window_id_);
  UpdateThemeForLiveSurfaces();
  UpdatePanel();
}

void OpenWindowUi::MountMediaPlayerStack() {
  if (!open_view_ || !open_view_->sidebar()) {
    return;
  }
  OpenMediaPlayerStackView::Callbacks cb;
  cb.on_focus_tab = base::BindRepeating(
      [](base::WeakPtr<OpenWindowUi> self, const ItemID& tab_id) {
        if (self && self->service()->tab_bridge()) {
          self->service()->tab_bridge()->SelectNode(tab_id, self->window_id_);
        }
      },
      weak_factory_.GetWeakPtr());
  cb.on_toggle_play_pause = base::BindRepeating(
      [](base::WeakPtr<OpenWindowUi> self, const ItemID& tab_id) {
        if (self && self->service()->media_bridge()) {
          self->service()->media_bridge()->TogglePlayPause(tab_id);
        }
      },
      weak_factory_.GetWeakPtr());
  cb.on_previous = base::BindRepeating(
      [](base::WeakPtr<OpenWindowUi> self, const ItemID& tab_id) {
        if (self && self->service()->media_bridge()) {
          self->service()->media_bridge()->PreviousTrack(tab_id);
        }
      },
      weak_factory_.GetWeakPtr());
  cb.on_next = base::BindRepeating(
      [](base::WeakPtr<OpenWindowUi> self, const ItemID& tab_id) {
        if (self && self->service()->media_bridge()) {
          self->service()->media_bridge()->NextTrack(tab_id);
        }
      },
      weak_factory_.GetWeakPtr());
  cb.on_toggle_mute = base::BindRepeating(
      [](base::WeakPtr<OpenWindowUi> self, const ItemID& tab_id) {
        if (self && self->service()->media_bridge()) {
          self->service()->media_bridge()->ToggleMute(tab_id);
        }
      },
      weak_factory_.GetWeakPtr());
  cb.on_set_volume = base::BindRepeating(
      [](base::WeakPtr<OpenWindowUi> self, const ItemID& tab_id, float vol) {
        if (self && self->service()->media_bridge()) {
          self->service()->media_bridge()->SetVolume(tab_id, vol);
        }
      },
      weak_factory_.GetWeakPtr());
  cb.on_toggle_pip = base::BindRepeating(
      [](base::WeakPtr<OpenWindowUi> self, const ItemID& tab_id) {
        if (self && self->service()->media_bridge()) {
          self->service()->media_bridge()->TogglePictureInPicture(tab_id);
        }
      },
      weak_factory_.GetWeakPtr());
  cb.on_dismiss = base::BindRepeating(
      [](base::WeakPtr<OpenWindowUi> self, const ItemID& tab_id) {
        if (self && self->service()->media_bridge()) {
          self->service()->media_bridge()->DismissCard(tab_id);
        }
      },
      weak_factory_.GetWeakPtr());
  cb.favicon_for = base::BindRepeating(
      [](base::WeakPtr<OpenWindowUi> self, const ItemID& tab_id) {
        return self ? self->controller_->GetFavicon(tab_id) : gfx::ImageSkia();
      },
      weak_factory_.GetWeakPtr());

  auto stack = std::make_unique<OpenMediaPlayerStackView>(std::move(cb));
  media_stack_ = static_cast<OpenMediaPlayerStackView*>(
      open_view_->sidebar()->SetMediaPlayerStack(std::move(stack)));
}

void OpenWindowUi::MountLinkStatusBubble() {
  if (!panel_tracker_) {
    return;
  }
  link_status_ = panel_tracker_->AddChildView(
      std::make_unique<OpenLinkStatusBubbleView>());
  link_status_->SetPageArea(panel_tracker_->GetLocalBounds());
}

void OpenWindowUi::RefreshMediaSessions() {
  if (!media_stack_ || !open_view_) {
    return;
  }
  OpenMediaBridge* media = service()->media_bridge();
  std::vector<OpenMediaSessionState> sessions =
      media ? media->GetActiveSessions() : std::vector<OpenMediaSessionState>();
  media_stack_->UpdateSessions(std::move(sessions),
                               open_view_->FocusedThemeState());
}

void OpenWindowUi::RefreshDownloadProgress() {
  if (!open_view_ || !open_view_->sidebar()) {
    return;
  }
  OpenDownloadBridge* downloads = service()->download_bridge();
  if (!downloads) {
    open_view_->sidebar()->SetLibraryDownloadProgress(std::nullopt);
    return;
  }
  const DownloadProgressSummary summary = downloads->GetAggregateProgress();
  if (summary.active_count <= 0) {
    open_view_->sidebar()->SetLibraryDownloadProgress(std::nullopt);
  } else {
    open_view_->sidebar()->SetLibraryDownloadProgress(
        summary.indeterminate ? 0.5 : std::clamp(summary.progress, 0.0, 1.0));
  }
}

void OpenWindowUi::RefreshDownloadsPopover() {
  if (!downloads_popover_ || !downloads_popover_->IsShowing()) {
    return;
  }
  OpenDownloadBridge* downloads = service()->download_bridge();
  if (!downloads) {
    return;
  }
  downloads_popover_->UpdateDownloads(downloads->GetRecentDownloads(
      service()->ActiveProfileId(), popover_metrics::kDownloadsMaxRows));
}

void OpenWindowUi::UpdateThemeForLiveSurfaces() {
  ApplyWindowEffects();
  if (media_stack_ && open_view_) {
    media_stack_->SetTheme(open_view_->FocusedThemeState());
  }
  if (library_drawer_shown()) {
    const std::optional<SpaceID> focused =
        model_util::FocusedSpace(service()->model(), window_id_);
    if (const Space* space = focused ? controller_->GetSpace(*focused) : nullptr) {
      const bool dark = SpacePrefersDark(*space, controller_->IsSystemDarkMode());
      service()->BroadcastEvent(
          kEventLibrarySetSpaceTheme,
          base::Value(webui::OpenLibraryUI::SpaceThemePayload(*space, dark)));
    }
  }
}

OpenExtensionBridge* OpenWindowUi::ExtensionBridge() const {
  if (browser_view_ && browser_view_->browser()) {
    if (ProfileServices* ps = service()->ProfileServicesForBrowserContext(
            browser_view_->browser()->GetProfile());
        ps && ps->extensions) {
      return ps->extensions.get();
    }
  }
  return service()->extension_bridge();
}

ExtensionHostWindow OpenWindowUi::MakeExtensionHostWindow() const {
  ExtensionHostWindow host;
  host.browser = browser_view_ ? browser_view_->browser() : nullptr;
  host.widget = widget();
  host.active_contents = base::BindRepeating(
      [](base::WeakPtr<const OpenWindowUi> self) -> content::WebContents* {
        return self ? self->ActiveWebContents() : nullptr;
      },
      weak_factory_.GetWeakPtr());
  return host;
}

void OpenWindowUi::AttachExtensionWindow() {
  if (extension_window_attached_) {
    return;
  }
  OpenExtensionBridge* extensions = ExtensionBridge();
  if (!extensions || !browser_view_ || !browser_view_->browser()) {
    return;
  }
  extensions->AttachWindow(MakeExtensionHostWindow());
  extension_window_attached_ = true;
}

void OpenWindowUi::DetachExtensionWindow() {
  if (!extension_window_attached_) {
    return;
  }
  extension_window_attached_ = false;
  if (OpenExtensionBridge* extensions = ExtensionBridge()) {
    if (views::Widget* w = widget()) {
      extensions->DetachWindow(w);
    } else if (browser_view_ && browser_view_->browser()) {
      extensions->DetachBrowser(browser_view_->browser());
    }
  }
}

content::WebContents* OpenWindowUi::ActiveWebContents() const {
  content::WebContents* contents =
      browser_view_ ? browser_view_->GetActiveWebContents() : nullptr;
  return OpenTabBridge::TabIdForWebContents(contents) ? contents : nullptr;
}

std::optional<ItemID> OpenWindowUi::ActiveTabId() const {
  return OpenTabBridge::TabIdForWebContents(ActiveWebContents());
}

void OpenWindowUi::ApplyWindowEffects() {
  views::Widget* w = widget();
  if (OpenPlatform* platform = OpenPlatform::Get(); platform && w) {
    const secondary::Appearance appearance = CurrentAppearance();
    platform->ApplyWindowEffects(w, appearance.dark);
    platform->SetWindowButtonsTone(w, appearance.dark, w->ShouldPaintAsActive());
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
  if (const Space* s = space ? controller_->GetSpace(*space) : nullptr) {
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
  view->SetFaviconLookup(base::BindRepeating(
      [](base::WeakPtr<OpenWindowUi> self, const GURL& url) {
        return self ? self->controller_->GetFaviconForUrl(url)
                    : gfx::ImageSkia();
      },
      weak_factory_.GetWeakPtr()));
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

void OpenWindowUi::EnsureLibraryDrawer() {
  if (library_host_ || !widget() || !browser_view_ ||
      !browser_view_->browser()) {
    return;
  }
  auto web_view = std::make_unique<LibraryDrawerWebView>(
      browser_view_->browser()->GetProfile(), browser_view_->GetFocusManager(),
      base::BindRepeating(&OpenWindowUi::HideLibraryDrawer,
                          weak_factory_.GetWeakPtr()));
  auto container = std::make_unique<MinSizeWebContainer>(
      gfx::Size(529, 600), gfx::Size(320, 400), std::move(web_view));
  library_web_view_ = container->web_view();
  library_host_ = std::make_unique<secondary::OverlayWidgetHost>(
      widget(), std::move(container), "OpenLibraryDrawer",
      /*activatable=*/true);
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
  controller_->RefreshSuggestExtensions();
  command_bar_mode_ = mode;
  CommandBarRequest request;
  request.mode = mode;
  request.initial_text = initial_text;
  request.appearance = CurrentAppearance();
  request.allows_remote_suggestions = ProfileAllowsRemoteSuggest(
      service(), service()->ActiveProfileId(),
      controller_->IsIncognitoWindow(window_id_));

  if (mode == CommandBarMode::kEditCurrentUrl) {
    if (std::optional<ItemID> active = ActiveTabId()) {
      request.current_favicon = controller_->GetFavicon(*active);
    }
    if (!anchor_in_screen && open_view_ && !open_view_->sidebar_hidden()) {
      if (views::View* pill = open_view_->GetUrlPillView();
          pill && pill->IsDrawn()) {
        anchor_in_screen = pill->GetBoundsInScreen();
      }
    }
  }
  if (anchor_in_screen) {
    request.anchor_in_screen = anchor_in_screen;
  }

  const bool was_shown = command_bar_shown();
  UpdateOverlayAnchors();
  command_bar_host_->Show();
  command_bar_->SetVisible(true);
  command_bar_->Present(request);
  RestackVisibleOverlays();
  UpdateEscapeRegistration();
  if (!was_shown) {
    controller_->NotifyCommandBarStateChanged(window_id_);
  }
}

void OpenWindowUi::HideCommandBar() {
  if (remote_suggest_request_id_ != 0) {
    service()->suggest().CancelRemoteSuggestions(remote_suggest_request_id_);
    remote_suggest_request_id_ = 0;
  }
  if (command_bar_ && command_bar_->is_presented()) {
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
                         ActiveTabId(),
                         controller_->IsIncognitoWindow(window_id_));
}

void OpenWindowUi::OnCommandBarRemoteQuery(const CommandBarQuery& query) {
  OpenBrowserService* s = service();
  if (remote_suggest_request_id_ != 0) {
    s->suggest().CancelRemoteSuggestions(remote_suggest_request_id_);
    remote_suggest_request_id_ = 0;
  }
  const ProfileID profile_id = s->ActiveProfileId();
  const SuggestContext context = BuildSuggestContext(
      s, query, profile_id, model_util::FocusedSpace(s->model(), window_id_),
      ActiveTabId(), controller_->IsIncognitoWindow(window_id_));
  scoped_refptr<network::SharedURLLoaderFactory> factory =
      URLLoaderFactoryForProfile(s, profile_id);
  if (!factory) {
    return;
  }
  const uint64_t generation = query.generation;
  remote_suggest_request_id_ = s->suggest().FetchRemoteSuggestions(
      base::UTF16ToUTF8(query.text), context, std::move(factory),
      base::BindOnce(
          [](base::WeakPtr<OpenWindowUi> self, uint64_t gen,
             RemoteSuggestionResult result) {
            if (!self || !self->command_bar_ || !self->command_bar_shown()) {
              return;
            }
            self->remote_suggest_request_id_ = 0;
            self->command_bar_->UpdateRemoteRows(
                gen, CommandBarRowsFromSuggestions(result.suggestions));
          },
          weak_factory_.GetWeakPtr(), generation));
}

void OpenWindowUi::OnCommandBarOpenSearchSettings() {
  controller_->OpenSettingsWindow("search");
}

void OpenWindowUi::OnCommandBarDismissPrivacyNotice() {
  std::string err;
  webui::OpenPreferences::Get()->Set("general.searchSuggestNoticeDismissed",
                                     base::Value(true),
                                     service()->ActiveProfileId(), true, &err);
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
      bridge->OpenTab(url, /*background=*/false, window_id_);
      return;
    case CommandBarDisposition::kNewForegroundTab:
      bridge->OpenTab(url, /*background=*/false, window_id_);
      return;
    case CommandBarDisposition::kNewBackgroundTab:
      bridge->OpenTab(url, /*background=*/true, window_id_);
      return;
    case CommandBarDisposition::kSplitView:
      OpenLinkInSplitView(url);
      return;
  }
}

void OpenWindowUi::OpenLinkInSplitView(const GURL& url) {
  if (!url.is_valid()) {
    return;
  }
  OpenTabBridge* bridge = service()->tab_bridge();
  if (!bridge) {
    return;
  }
  const std::optional<ItemID> active = ActiveTabId();
  const ItemID opened = bridge->OpenTab(url, /*background=*/true, window_id_);
  if (active && !opened.empty()) {
    service()->model().MakeSplit({*active, opened});
  }
}

// --- Library Drawer ----------------------------------------------------------

void OpenWindowUi::ShowLibraryDrawer(std::string_view section) {
  if (controller_->IsIncognitoWindow(window_id_)) {
    return;
  }
  // Clicking the Library button while the default Library drawer is already
  // open toggles it closed.
  if (library_drawer_shown() && section.empty() && library_section_.empty()) {
    HideLibraryDrawer();
    return;
  }
  EnsureLibraryDrawer();
  if (!library_host_ || !library_web_view_) {
    return;
  }
  library_section_ = std::string(section);
  const std::optional<SpaceID> focused =
      model_util::FocusedSpace(service()->model(), window_id_);
  const Space* space = focused ? controller_->GetSpace(*focused) : nullptr;
  const std::string extra = base::StrCat(
      {"mode=drawer&window_id=",
       base::EscapeQueryParamValue(window_id_, /*use_plus=*/false)});
  const GURL url(AppendSpaceThemeQuery(
      webui::OpenWebUIURL(webui::kHostLibrary, section), space,
      controller_->IsSystemDarkMode(), extra));

  if (content::WebContents* wc = library_web_view_->GetWebContents()) {
    wc->GetController().LoadURLWithParams(
        content::NavigationController::LoadURLParams(url));
  } else {
    library_web_view_->LoadInitialURL(url);
  }
  UpdateOverlayAnchors();
  library_host_->Show();
  RestackVisibleOverlays();
  library_web_view_->RequestFocus();
  UpdateEscapeRegistration();
}

void OpenWindowUi::HideLibraryDrawer() {
  if (library_host_ && library_host_->IsVisible()) {
    library_host_->Hide();
    UpdateEscapeRegistration();
    FocusPage();
  }
}

bool OpenWindowUi::library_drawer_shown() const {
  return library_host_ && library_host_->IsVisible();
}

// --- Boost Editor, Space Editor & Popovers -----------------------------------

void OpenWindowUi::OpenBoostEditor(const std::optional<std::string>& boost_id,
                                   bool arm_zap) {
  if (controller_->IsIncognitoWindow(window_id_)) {
    return;
  }
  content::WebContents* contents = ActiveWebContents();
  std::optional<ItemID> tab_id = ActiveTabId();
  OpenBoostController* boosts = service()->boost_controller();
  if (!contents || !tab_id || !boosts || !widget()) {
    return;
  }
  const GURL url = contents->GetLastCommittedURL();
  if (!url.is_valid() || !url.SchemeIsHTTPOrHTTPS()) {
    ShowToast(ToastSpec::Info(u"Boosts work on web pages."));
    return;
  }
  const ProfileID profile =
      model_util::ProfileOfNode(service()->model(), *tab_id)
          .value_or(service()->ActiveProfileId());

  Boost target;
  bool found = false;
  if (boost_id && !boost_id->empty()) {
    if (auto existing = boosts->FindBoost(profile, *boost_id)) {
      target = *existing;
      found = true;
    }
  }
  if (!found) {
    const std::vector<Boost> matches = boosts->MatchingBoosts(profile, url);
    if (!matches.empty()) {
      target = matches.front();
      found = true;
    }
  }
  if (!found) {
    target.profile_id = profile;
    target.host_pattern = HostWithoutWww(url);
    target.name = target.host_pattern;
    target.enabled = true;
  }

  CloseBoostEditor();
  boost_editor_ =
      std::make_unique<OpenBoostEditorSession>(boosts, profile, *tab_id);
  boost_editor_->set_on_share(base::BindRepeating(
      [](base::WeakPtr<OpenWindowUi> self, const Boost& b) {
        if (!self) {
          return;
        }
        ui::ScopedClipboardWriter(ui::ClipboardBuffer::kCopyPaste)
            .WriteText(base::UTF8ToUTF16(b.name + " (" + b.host_pattern + ")"));
        self->ShowToast(ToastSpec::ForKind(OpenToastKind::kCopied));
      },
      weak_factory_.GetWeakPtr()));
  boost_editor_->set_on_show_all(base::BindRepeating(
      [](base::WeakPtr<OpenWindowUi> self) {
        if (self) {
          self->ShowLibraryDrawer("boosts");
        }
      },
      weak_factory_.GetWeakPtr()));
  boost_editor_->set_on_closed(base::BindOnce(
      [](base::WeakPtr<OpenWindowUi> self) {
        if (self) {
          self->UpdateEscapeRegistration();
        }
      },
      weak_factory_.GetWeakPtr()));
  boost_editor_->Show(widget(), PanelRectInScreen(), target,
                      CurrentAppearance().dark);
  RestackVisibleOverlays();
  if (arm_zap && !target.id.empty()) {
    std::string msg;
    boosts->StartZapForTab(*tab_id, target.id, &msg);
  }
  UpdateEscapeRegistration();
}

void OpenWindowUi::CloseBoostEditor() {
  if (boost_editor_) {
    boost_editor_->Close();
    boost_editor_.reset();
    UpdateEscapeRegistration();
  }
}

bool OpenWindowUi::boost_editor_shown() const {
  return boost_editor_ && boost_editor_->IsVisible();
}

void OpenWindowUi::ShowSpaceThemeEditor(const SpaceID& space_id,
                                        bool open_identity_page,
                                        views::View* anchor) {
  const BrowserModel& model = service()->model();
  const Space* space = model.FindSpace(space_id);
  if (!space || !open_view_ || !widget()) {
    return;
  }
  OpenSpaceThemeEditorParams params;
  params.space_id = space->id;
  params.theme = space->theme;
  params.title = space->title;
  params.icon = space->icon;
  params.profile_id = space->profile_id;
  params.profiles = SpaceProfileChoicesFrom(model.profiles());
  params.system_appearance =
      ToContentAppearance(controller_->IsSystemDarkMode());
  params.show_identity = true;
  params.open_identity_page = open_identity_page;

  OpenSpaceThemeEditorView::Callbacks cb;
  cb.on_live_theme_change = base::BindRepeating(
      [](base::WeakPtr<OpenWindowUi> self, const SpaceID& sid,
         const SpaceTheme& theme) {
        if (self) {
          self->controller_->SetSpaceThemePreview(sid, theme);
        }
      },
      weak_factory_.GetWeakPtr());
  cb.on_commit_theme = base::BindRepeating(
      [](base::WeakPtr<OpenWindowUi> self, const SpaceID& sid,
         const SpaceTheme& theme) {
        if (!self) {
          return;
        }
        self->controller_->ClearSpaceThemePreview(sid);
        self->service()->model().UpdateSpace(sid, std::nullopt, std::nullopt,
                                             theme);
        if (self->open_view_) {
          self->open_view_->CrossfadeTheme(sid, /*animated=*/true);
        }
        self->UpdateThemeForLiveSurfaces();
      },
      weak_factory_.GetWeakPtr());
  cb.on_rename_space = base::BindRepeating(
      [](base::WeakPtr<OpenWindowUi> self, const SpaceID& sid,
         const std::string& title) {
        if (self) {
          self->service()->model().UpdateSpace(sid, title);
        }
      },
      weak_factory_.GetWeakPtr());
  cb.on_change_icon = base::BindRepeating(
      [](base::WeakPtr<OpenWindowUi> self, const SpaceID& sid,
         const std::optional<SpaceIcon>& icon) {
        if (self) {
          self->service()->model().UpdateSpace(sid, std::nullopt, icon);
        }
      },
      weak_factory_.GetWeakPtr());
  cb.on_change_profile = base::BindRepeating(
      [](base::WeakPtr<OpenWindowUi> self, const SpaceID& sid,
         const ProfileID& pid) {
        if (self) {
          self->service()->model().MoveSpaceToProfile(sid, pid);
        }
      },
      weak_factory_.GetWeakPtr());
  cb.on_close = base::BindOnce(
      [](base::WeakPtr<OpenWindowUi> self, SpaceID sid) {
        if (self) {
          self->controller_->ClearSpaceThemePreview(sid);
        }
      },
      weak_factory_.GetWeakPtr(), space->id);

  SpaceEditorAnchor ed_anchor;
  if (anchor) {
    ed_anchor.view = anchor;
  } else {
    gfx::Rect sb = open_view_->GetSidebarBounds();
    gfx::Point pt(sb.right(), sb.y() + 35);
    views::View::ConvertPointToScreen(open_view_, &pt);
    ed_anchor.screen_rect = gfx::Rect(pt, gfx::Size(1, 1));
    ed_anchor.parent = widget()->GetNativeView();
  }
  ed_anchor.arrow = views::BubbleBorder::LEFT_TOP;
  space_editor_popover_.ShowThemeEditor(ed_anchor, std::move(params),
                                        std::move(cb));
}

void OpenWindowUi::ShowSpaceCreation(views::View* anchor) {
  const BrowserModel& model = service()->model();
  if (!open_view_ || !widget()) {
    return;
  }
  OpenSpaceCreationParams params;
  params.profiles = SpaceProfileChoicesFrom(model.profiles());
  params.selected_profile_id = service()->ActiveProfileId();
  params.allow_new_profile = true;
  params.system_appearance =
      ToContentAppearance(controller_->IsSystemDarkMode());

  OpenSpaceCreationView::Callbacks cb;
  cb.on_create = base::BindOnce(
      [](base::WeakPtr<OpenWindowUi> self, const CreateSpaceRequest& req) {
        if (!self) {
          return;
        }
        auto create_in_profile = [](base::WeakPtr<OpenWindowUi> ui_weak,
                                    CreateSpaceRequest request,
                                    ProfileID pid) {
          if (!ui_weak || pid.empty()) {
            return;
          }
          const SpaceID created = ui_weak->service()->model().CreateSpace(
              pid, request.title, request.icon, request.theme);
          if (!created.empty() && ui_weak->service()->tab_bridge()) {
            ui_weak->service()->tab_bridge()->FocusSpace(created,
                                                         ui_weak->window_id_);
            ui_weak->ShowToast(ToastSpec::ForKind(OpenToastKind::kSpaceCreated));
          }
        };
        if (req.new_profile_name && !req.new_profile_name->empty()) {
          self->service()->CreateProfile(
              *req.new_profile_name, std::nullopt,
              base::BindOnce(create_in_profile, self, req));
        } else {
          const ProfileID pid = req.profile_id.empty()
                                    ? self->service()->ActiveProfileId()
                                    : req.profile_id;
          create_in_profile(self, req, pid);
        }
      },
      weak_factory_.GetWeakPtr());

  SpaceEditorAnchor ed_anchor;
  if (anchor) {
    ed_anchor.view = anchor;
    ed_anchor.arrow = views::BubbleBorder::BOTTOM_RIGHT;
  } else {
    gfx::Rect sb = open_view_->GetSidebarBounds();
    gfx::Point pt(sb.right() - 8, sb.bottom() - 48);
    views::View::ConvertPointToScreen(open_view_, &pt);
    ed_anchor.screen_rect = gfx::Rect(pt, gfx::Size(1, 1));
    ed_anchor.parent = widget()->GetNativeView();
    ed_anchor.arrow = views::BubbleBorder::BOTTOM_LEFT;
  }
  space_editor_popover_.ShowCreation(ed_anchor, std::move(params),
                                     std::move(cb));
}

views::View* OpenWindowUi::FindViewMatchingScreenRect(
    const gfx::Rect& rect) const {
  return FindDescendantByScreenRect(open_view_, rect);
}

void OpenWindowUi::TogglePlusPopover(views::View* anchor) {
  if (!open_view_ || !open_view_->sidebar()) {
    return;
  }
  views::View* target = anchor ? anchor : open_view_->sidebar();
  OpenMenuTarget menu_target;
  menu_target.kind = OpenMenuTarget::Kind::kPlusButton;
  menu_target.space_id =
      model_util::FocusedSpace(service()->model(), window_id_)
          .value_or(SpaceID());
  auto model = controller_->BuildMenuModelForTarget(window_id_, menu_target);
  if (!model) {
    return;
  }
  const OpenPopoverColors colors = OpenPopoverColors::ForThemeState(
      open_view_->FocusedThemeState(),
      ToContentAppearance(controller_->IsSystemDarkMode()));
  plus_popover_.Toggle(target, std::move(model), colors);
}

void OpenWindowUi::ToggleToolbarMorePopover(
    std::optional<gfx::Rect> anchor_in_screen) {
  if (!open_view_ || !open_view_->sidebar()) {
    return;
  }
  views::View* anchor =
      anchor_in_screen ? FindViewMatchingScreenRect(*anchor_in_screen)
                       : nullptr;
  if (!anchor) {
    anchor = open_view_->GetUrlPillView();
  }
  if (!anchor) {
    anchor = open_view_->sidebar();
  }
  OpenMenuTarget menu_target;
  menu_target.kind = OpenMenuTarget::Kind::kToolbarMore;
  auto model = controller_->BuildMenuModelForTarget(window_id_, menu_target);
  if (!model) {
    return;
  }
  more_popover_.Toggle(anchor, std::move(model),
                       OpenPopoverColors::ToolbarMore(CurrentAppearance().dark));
}

void OpenWindowUi::ToggleDownloadsPopover(views::View* anchor) {
  if (!open_view_ || !open_view_->sidebar()) {
    return;
  }
  if (!downloads_popover_) {
    downloads_popover_ = std::make_unique<OpenDownloadsPopover>(
        base::BindRepeating(&OpenWindowUi::HandleDownloadPopoverAction,
                            weak_factory_.GetWeakPtr()));
  }
  if (downloads_popover_->IsShowing()) {
    downloads_popover_->Close();
    return;
  }
  OpenDownloadBridge* downloads = service()->download_bridge();
  if (downloads) {
    downloads->SyncLiveDownloadsFromManagers();
  }
  std::vector<RecentDownloadEntry> entries =
      downloads ? downloads->GetRecentDownloads(
                      service()->ActiveProfileId(),
                      popover_metrics::kDownloadsMaxRows)
                : std::vector<RecentDownloadEntry>();
  const OpenPopoverColors colors = OpenPopoverColors::ForThemeState(
      open_view_->FocusedThemeState(),
      ToContentAppearance(controller_->IsSystemDarkMode()));
  views::View* target = anchor ? anchor : open_view_->sidebar();
  downloads_popover_->Show(target, std::move(entries), colors);
}

void OpenWindowUi::HandleDownloadPopoverAction(DownloadPopoverAction action,
                                               const std::string& download_id) {
  OpenDownloadBridge* downloads = service()->download_bridge();
  switch (action) {
    case DownloadPopoverAction::kOpen:
      if (downloads) {
        downloads->OpenFile(download_id);
      }
      return;
    case DownloadPopoverAction::kReveal:
      if (downloads) {
        downloads->RevealInFolder(download_id);
      }
      return;
    case DownloadPopoverAction::kPause:
      if (downloads) {
        downloads->Pause(download_id);
      }
      return;
    case DownloadPopoverAction::kResume:
      if (downloads) {
        downloads->Resume(download_id);
      }
      return;
    case DownloadPopoverAction::kCancel:
      if (downloads) {
        downloads->Cancel(download_id);
      }
      return;
    case DownloadPopoverAction::kRetry:
      if (downloads) {
        downloads->Retry(download_id);
      }
      return;
    case DownloadPopoverAction::kCopyLink:
      if (downloads) {
        for (const RecentDownloadEntry& e : downloads->GetRecentDownloads(
                 service()->ActiveProfileId(), 50)) {
          if (e.record.id == download_id && !e.record.url.empty()) {
            CopyUrl(GURL(e.record.url));
            break;
          }
        }
      }
      return;
    case DownloadPopoverAction::kRemove:
      if (downloads) {
        downloads->RemoveFromHistory(download_id);
      }
      return;
    case DownloadPopoverAction::kViewAllDownloads:
      ShowLibraryDrawer("downloads");
      return;
    case DownloadPopoverAction::kClearCompleted:
      if (downloads) {
        downloads->ClearHistory(service()->ActiveProfileId());
      }
      return;
  }
}

void OpenWindowUi::ShowTranslatePagePopover(views::View* anchor) {
  OpenTranslateController* tc = service()->translate_controller();
  content::WebContents* wc = ActiveWebContents();
  if (!tc || !wc) {
    return;
  }
  views::View* target = anchor ? anchor : open_view_->GetSiteControlAnchorView();
  if (!target) {
    target = open_view_->GetUrlPillView();
  }
  if (!target) {
    target = open_view_;
  }
  tc->ShowPagePopover(wc, target, CurrentAppearance());
}

void OpenWindowUi::CreateAndOpenDocument(bool is_easel, bool in_split) {
  ProfileServices* ps =
      service()->ProfileServicesFor(service()->ActiveProfileId());
  OpenTabBridge* bridge = service()->tab_bridge();
  if (!bridge) {
    return;
  }
  if (!ps) {
    const GURL fallback(webui::OpenWebUIURL(
        is_easel ? webui::kHostEasel : webui::kHostNote));
    if (in_split) {
      OpenLinkInSplitView(fallback);
    } else {
      bridge->OpenTab(fallback, /*background=*/false, window_id_);
    }
    return;
  }
  RunOnStore(
      ps->documents,
      base::BindOnce(
          [](bool easel, DocumentStore* store) -> std::string {
            if (easel) {
              return store->CreateEasel().id;
            }
            return store->CreateNote().id;
          },
          is_easel),
      base::BindOnce(
          [](base::WeakPtr<OpenWindowUi> self, bool easel, bool split,
             std::string doc_id) {
            if (!self || !self->service()->tab_bridge()) {
              return;
            }
            const GURL url(webui::OpenWebUIURL(
                easel ? webui::kHostEasel : webui::kHostNote, doc_id));
            if (split) {
              self->OpenLinkInSplitView(url);
            } else {
              self->service()->tab_bridge()->OpenTab(url, /*background=*/false,
                                                     self->window_id_);
            }
          },
          weak_factory_.GetWeakPtr(), is_easel, in_split));
}

// --- Command Dispatch --------------------------------------------------------

void OpenWindowUi::RunAction(const std::string& action_id) {
  if (base::StartsWith(action_id, kExtensionActionPrefix)) {
    const std::string ext_id = action_id.substr(
        std::string_view(kExtensionActionPrefix).size());
    if (OpenExtensionBridge* extensions = ExtensionBridge();
        extensions && !ext_id.empty()) {
      views::View* anchor = open_view_ ? open_view_->GetUrlPillView() : nullptr;
      if (browser_view_ && browser_view_->browser()) {
        extensions->ExecuteAction(browser_view_->browser(), ext_id, anchor,
                                  std::nullopt, base::DoNothing());
      } else {
        extensions->ExecuteAction(ext_id, anchor, base::DoNothing());
      }
    }
    return;
  }
  if (action_id == "translate-page") {
    ShowTranslatePagePopover();
    return;
  }
  if (action_id == "restore-last-closed-window") {
    service()->ReopenLastClosedWindow();
    return;
  }
  if (action_id == "mute-unmute-tab") {
    if (std::optional<ItemID> active = ActiveTabId()) {
      controller_->HandleIntent(
          window_id_, OpenIntent::ForNode(OpenIntentKind::kToggleMute, *active));
    }
    return;
  }
  if (action_id == "unload-tab") {
    if (std::optional<ItemID> active = ActiveTabId();
        active && service()->tab_bridge()) {
      service()->tab_bridge()->UnloadTab(*active);
    }
    return;
  }
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
  const std::optional<ItemID> active = ActiveTabId();
  const std::optional<SpaceID> focused =
      model_util::FocusedSpace(model, window_id_);
  const ProfileID active_profile = s->ActiveProfileId();

  auto intent = [&](OpenIntentKind kind) {
    controller_->HandleIntent(window_id_, OpenIntent::Of(kind));
  };

  if (const int index = GoToTabIndex(command); index >= 0) {
    const std::vector<ItemID> ids =
        focused ? model_util::OrderedTabIds(model, *focused)
                : std::vector<ItemID>();
    if (ids.empty()) {
      return true;
    }
    const bool ninth_is_last = PrefBool("tabs.ninthTabGoesToLast", true);
    const size_t target =
        (index == 8 && ninth_is_last)
            ? ids.size() - 1
            : std::min(static_cast<size_t>(index), ids.size() - 1);
    bridge->SelectNode(ids[target], window_id_);
    return true;
  }
  if (command == CommandId::kGoToLastTab) {
    const std::vector<ItemID> ids =
        focused ? model_util::OrderedTabIds(model, *focused)
                : std::vector<ItemID>();
    if (!ids.empty()) {
      bridge->SelectNode(ids.back(), window_id_);
    }
    return true;
  }
  if (const int index = GoToSpaceIndex(command); index >= 0) {
    const std::vector<SpaceID> spaces =
        controller_->GetWindowSpaceIds(window_id_);
    if (static_cast<size_t>(index) < spaces.size()) {
      bridge->FocusSpace(spaces[static_cast<size_t>(index)], window_id_);
    }
    return true;
  }
  if (const int pane_idx = FocusSplitPaneIndex(command); pane_idx >= 0) {
    if (focused) {
      if (std::optional<ItemID> sel =
              model.SelectedNodeId(*focused, window_id_)) {
        if (const Split* split = model.FindSplit(*sel);
            split && static_cast<size_t>(pane_idx) < split->panes.size()) {
          bridge->SelectNode(split->panes[static_cast<size_t>(pane_idx)].id,
                             window_id_);
        }
      }
    }
    return true;
  }

  switch (command) {
    // --- App & Settings ---
    case CommandId::kAboutOpen:
      controller_->OpenSettingsWindow("about");
      return true;
    case CommandId::kQuitOpen:
      chrome::AttemptUserExit();
      return true;
    case CommandId::kSettings:
      controller_->OpenSettingsWindow();
      return true;
    case CommandId::kSetDefaultBrowser:
      if (OpenPlatform* platform = OpenPlatform::Get()) {
        platform->SetDefaultBrowser();
      }
      return true;
    case CommandId::kImportFromBrowser:
      controller_->OpenSettingsWindow("import");
      return true;
    case CommandId::kCheckForUpdates:
      if (OpenUpdaterService* updater = s->updater()) {
        ShowToast(ToastSpec::Info(u"Checking for updates…"));
        updater->CheckForUpdates(
            /*user_initiated=*/true,
            base::BindOnce(
                [](base::WeakPtr<OpenWindowUi> self,
                   const UpdateCheckStatus& status) {
                  if (!self) {
                    return;
                  }
                  if (status.state == UpdateState::kUpdateAvailable &&
                      status.available_release) {
                    const GURL url =
                        status.available_release->html_url.is_valid()
                            ? status.available_release->html_url
                            : status.available_release->download_url;
                    ToastSpec spec = ToastSpec::Info(
                        u"Update available: v" +
                        base::UTF8ToUTF16(status.available_release->version));
                    if (url.is_valid()) {
                      spec.button_label = u"Download";
                      spec.button_action = base::BindOnce(
                          [](base::WeakPtr<OpenWindowUi> ui_weak, GURL u) {
                            if (ui_weak && ui_weak->service()->tab_bridge()) {
                              ui_weak->service()->tab_bridge()->OpenTab(
                                  u, /*background=*/false, ui_weak->window_id_);
                            }
                          },
                          self, url);
                    }
                    self->ShowToast(std::move(spec));
                  } else if (status.state == UpdateState::kUpToDate) {
                    self->ShowToast(ToastSpec::Info(
                        u"Open is up to date",
                        u"Version " +
                            base::UTF8ToUTF16(status.current_version)));
                  } else {
                    self->ShowToast(ToastSpec::Warning(
                        u"Could not check for updates",
                        base::UTF8ToUTF16(status.error_message)));
                  }
                },
                weak_factory_.GetWeakPtr()));
      }
      return true;

    // --- Command Bar & Navigation ---
    case CommandId::kNewTab:
    case CommandId::kOpenCommandBar:
      if (command == CommandId::kOpenCommandBar && active) {
        const Tab* tab = model.FindTab(*active);
        std::optional<gfx::Rect> anchor;
        if (open_view_ && !open_view_->sidebar_hidden()) {
          if (views::View* pill = open_view_->GetUrlPillView();
              pill && pill->IsDrawn()) {
            anchor = pill->GetBoundsInScreen();
          }
        }
        ShowCommandBar(CommandBarMode::kEditCurrentUrl,
                       tab ? base::UTF8ToUTF16(tab->url) : std::u16string(),
                       anchor);
      } else {
        ShowCommandBar(CommandBarMode::kNewTab, std::u16string(), std::nullopt);
      }
      return true;
    case CommandId::kSearchActions:
      ShowCommandBar(CommandBarMode::kSearchActions, std::u16string(),
                     std::nullopt);
      return true;
    case CommandId::kSearchTabs:
      ShowCommandBar(CommandBarMode::kSearchTabs, std::u16string(),
                     std::nullopt);
      return true;
    case CommandId::kReload:
      intent(OpenIntentKind::kReload);
      return true;
    case CommandId::kForceReload:
      if (content::WebContents* wc = ActiveWebContents()) {
        wc->GetController().Reload(content::ReloadType::BYPASSING_CACHE, true);
      }
      return true;
    case CommandId::kStopLoading:
      intent(OpenIntentKind::kStopLoading);
      return true;
    case CommandId::kGoBack:
      intent(OpenIntentKind::kGoBack);
      return true;
    case CommandId::kGoForward:
      intent(OpenIntentKind::kGoForward);
      return true;

    // --- Windows & Standalone Surfaces ---
    case CommandId::kNewWindow:
      bridge->OpenNewWindow(focused);
      return true;
    case CommandId::kBlankWindow:
      bridge->OpenNewWindow(std::nullopt);
      return true;
    case CommandId::kNewIncognitoWindow:
      bridge->OpenNewIncognitoWindow(active_profile);
      return true;
    case CommandId::kNewLittleOpenWindow:
    case CommandId::kLittleOpenGlobal:
      controller_->OpenLittleOpen(std::nullopt);
      return true;
    case CommandId::kShowLittleOpenWindows:
      for (const auto& lo : controller_->little_opens()) {
        if (views::Widget* w = lo->widget()) {
          w->Show();
          w->Activate();
        }
      }
      return true;
    case CommandId::kCloseLittleOpenWindows: {
      std::vector<OpenLittleOpenController*> raw;
      for (const auto& lo : controller_->little_opens()) {
        raw.push_back(lo.get());
      }
      for (OpenLittleOpenController* lo : raw) {
        lo->Close();
      }
      return true;
    }
    case CommandId::kCloseWindow:
      if (views::Widget* w = widget()) {
        w->Close();
        return true;
      }
      return false;
    case CommandId::kMinimizeWindow:
      if (views::Widget* w = widget()) {
        w->Minimize();
        return true;
      }
      return false;
    case CommandId::kZoomWindow:
      if (views::Widget* w = widget()) {
        if (w->IsMaximized()) {
          w->Restore();
        } else {
          w->Maximize();
        }
        return true;
      }
      return false;
    case CommandId::kStayOnTop:
      if (views::Widget* w = widget()) {
        stay_on_top_ = !stay_on_top_;
        w->SetZOrderLevel(stay_on_top_ ? ui::ZOrderLevel::kFloatingWindow
                                       : ui::ZOrderLevel::kNormal);
        ShowToast(ToastSpec::Info(stay_on_top_ ? u"Window pinned on top"
                                               : u"Window unpinned"));
        return true;
      }
      return false;
    case CommandId::kToggleFullScreen:
      if (browser_view_ && browser_view_->browser()) {
        chrome::ToggleFullscreenMode(browser_view_->browser(),
                                     /*user_initiated=*/true);
        return true;
      }
      if (views::Widget* w = widget()) {
        w->SetFullscreen(!w->IsFullscreen());
        return true;
      }
      return false;

    // --- Library Drawer ---
    case CommandId::kViewLibrary:
      ShowLibraryDrawer("");
      return true;
    case CommandId::kViewDownloads:
      ShowLibraryDrawer("downloads");
      return true;
    case CommandId::kViewArchive:
      ShowLibraryDrawer("archive");
      return true;
    case CommandId::kViewHistory:
      ShowLibraryDrawer("history");
      return true;
    case CommandId::kViewMedia:
      ShowLibraryDrawer("media");
      return true;
    case CommandId::kViewBoosts:
      ShowLibraryDrawer("boosts");
      return true;
    case CommandId::kViewEaselsNotes:
      ShowLibraryDrawer("easels");
      return true;
    case CommandId::kManageSpaces:
      ShowLibraryDrawer("spaces");
      return true;
    case CommandId::kClearArchive:
      if (ProfileServices* ps = s->ProfileServicesFor(active_profile)) {
        RunOnStore(ps->archive, base::BindOnce([](ArchiveStore* store) {
                     store->DeleteAll();
                   }));
        ShowToast(ToastSpec::ForKind(OpenToastKind::kArchiveCleared));
      }
      return true;

    // --- Spaces & Themes ---
    case CommandId::kNewSpace:
      ShowSpaceCreation(nullptr);
      return true;
    case CommandId::kEditTheme:
      if (focused) {
        ShowSpaceThemeEditor(*focused, /*open_identity_page=*/false);
      }
      return true;
    case CommandId::kChangeSpaceIcon:
    case CommandId::kRenameSpace:
    case CommandId::kChangeProfile:
      if (focused) {
        ShowSpaceThemeEditor(*focused, /*open_identity_page=*/true);
      }
      return true;
    case CommandId::kNextSpace:
    case CommandId::kPreviousSpace: {
      const std::vector<SpaceID> spaces =
          controller_->GetWindowSpaceIds(window_id_);
      if (spaces.size() < 2 || !focused) {
        return true;
      }
      auto it = std::find(spaces.begin(), spaces.end(), *focused);
      const size_t current =
          it == spaces.end() ? 0 : static_cast<size_t>(it - spaces.begin());
      const size_t next = command == CommandId::kNextSpace
                              ? (current + 1) % spaces.size()
                              : (current + spaces.size() - 1) % spaces.size();
      bridge->FocusSpace(spaces[next], window_id_);
      return true;
    }

    // --- Tabs, Folders, Favorites ---
    case CommandId::kArchiveTab:
      if (active) {
        bridge->CloseNode(*active);
      }
      return true;
    case CommandId::kRestoreLastClosedTab:
      if (ProfileServices* ps = s->ProfileServicesFor(active_profile)) {
        RunOnStore(
            ps->archive,
            base::BindOnce([](ArchiveStore* store) {
              auto list = store->List(/*limit=*/1);
              return list.empty() ? std::optional<ArchivedTabRecord>()
                                  : std::optional<ArchivedTabRecord>(list[0]);
            }),
            base::BindOnce(
                [](base::WeakPtr<OpenWindowUi> self,
                   std::optional<ArchivedTabRecord> rec) {
                  if (!self || !rec) {
                    return;
                  }
                  self->controller_->RestoreArchived({*rec});
                  self->ShowToast(
                      ToastSpec::ForKind(OpenToastKind::kTabRestored));
                },
                weak_factory_.GetWeakPtr()));
      }
      return true;
    case CommandId::kDuplicateTab:
      if (active) {
        const ItemID dup = model.DuplicateNode(*active);
        if (!dup.empty()) {
          bridge->SelectNode(dup, window_id_);
        }
      }
      return true;
    case CommandId::kPinUnpinTab:
      if (active) {
        const bool was_pinned = model.IsPinned(*active);
        bridge->TogglePin(*active);
        ShowToast(ToastSpec::ForKind(was_pinned ? OpenToastKind::kTabUnpinned
                                                : OpenToastKind::kTabPinned));
      }
      return true;
    case CommandId::kAddToFavorites:
      if (active && model.AddFavorite(*active, active_profile)) {
        ShowToast(ToastSpec::ForKind(OpenToastKind::kAddedToFavorites));
      }
      return true;
    case CommandId::kRemoveFromFavorites:
      if (active && model.RemoveFavorite(*active)) {
        ShowToast(ToastSpec::ForKind(OpenToastKind::kRemovedFromFavorites));
      }
      return true;
    case CommandId::kReplacePinnedUrl:
      if (active && model.IsPinned(*active)) {
        const std::optional<NodeParent> parent = model.GetParent(*active);
        const std::optional<NodeIndexEntry> entry = model.GetIndexEntry(*active);
        model.UnpinTab(*active);
        if (parent && entry) {
          model.MoveNode(*active, *parent, entry->index);
        } else {
          model.PinTab(*active);
        }
      }
      return true;
    case CommandId::kRenameTab:
      if (active && focused && open_view_ && open_view_->sidebar()) {
        if (OpenTabTreeView* tree =
                open_view_->sidebar()->GetTreeForSpace(*focused)) {
          tree->BeginRename(*active);
        }
      }
      return true;
    case CommandId::kResetTab:
      if (active && model.ResetPinnedTab(*active)) {
        if (const Tab* tab = model.FindTab(*active)) {
          bridge->Navigate(*active, GURL(tab->url));
        }
        ShowToast(ToastSpec::ForKind(OpenToastKind::kTabReset));
      }
      return true;
    case CommandId::kResetAllTabsInSpace:
      if (focused) {
        const std::vector<ItemID> reset = model.ResetPinnedTabs(*focused);
        for (const ItemID& id : reset) {
          if (const Tab* tab = model.FindTab(id);
              tab && bridge->WebContentsForTab(id)) {
            bridge->Navigate(id, GURL(tab->url));
          }
        }
        if (!reset.empty()) {
          ShowToast(ToastSpec::ForKind(OpenToastKind::kTabReset));
        }
      }
      return true;
    case CommandId::kClearUnpinnedTabs:
      if (focused) {
        controller_->HandleIntent(
            window_id_,
            OpenIntent::ForSpace(OpenIntentKind::kClearToday, *focused));
      }
      return true;
    case CommandId::kNewFolder:
      if (focused) {
        model.CreateFolder(NodeParent{NodeParentKind::kSpacePinned, *focused});
      }
      return true;
    case CommandId::kExpandAllFolders:
    case CommandId::kCollapseAllFolders:
      if (focused) {
        if (const Space* space = model.FindSpace(*focused)) {
          std::vector<ItemID> folders;
          CollectFolderIds(space->pinned, &folders);
          CollectFolderIds(space->today, &folders);
          const bool expand = command == CommandId::kExpandAllFolders;
          for (const ItemID& fid : folders) {
            model.SetFolderExpanded(fid, expand);
          }
        }
      }
      return true;
    case CommandId::kNextTab:
    case CommandId::kPreviousTab:
    case CommandId::kCycleTabForward:
    case CommandId::kCycleTabBackward: {
      const std::vector<ItemID> ids =
          focused ? model_util::OrderedTabIds(model, *focused)
                  : std::vector<ItemID>();
      if (ids.empty()) {
        return true;
      }
      const bool forward = command == CommandId::kNextTab ||
                           command == CommandId::kCycleTabForward;
      auto it =
          active ? std::find(ids.begin(), ids.end(), *active) : ids.end();
      size_t next = 0;
      if (it != ids.end()) {
        const size_t current = static_cast<size_t>(it - ids.begin());
        next = forward ? (current + 1) % ids.size()
                       : (current + ids.size() - 1) % ids.size();
      }
      bridge->SelectNode(ids[next], window_id_);
      return true;
    }
    case CommandId::kRevealCurrentTab:
    case CommandId::kRevealTabInSidebar:
      if (active && focused && open_view_) {
        if (open_view_->sidebar_hidden()) {
          model.SetSidebarMode(window_id_, SidebarMode::kAnchored);
        }
        if (open_view_->sidebar()) {
          if (OpenTabTreeView* tree =
                  open_view_->sidebar()->GetTreeForSpace(*focused)) {
            tree->ScrollToNode(*active);
          }
        }
      }
      return true;
    case CommandId::kMuteAllTabs:
    case CommandId::kUnmuteAllTabs: {
      const bool mute = command == CommandId::kMuteAllTabs;
      for (const auto& [tid, wc] : bridge->LoadedTabs()) {
        model.SetMuted(tid, mute);
        if (wc) {
          wc->SetAudioMuted(mute);
        }
      }
      return true;
    }

    // --- Sidebar & Chrome ---
    case CommandId::kToggleSidebar:
      intent(OpenIntentKind::kToggleSidebar);
      return true;
    case CommandId::kToggleToolbar:
      single_pane_toolbar_visible_ = !single_pane_toolbar_visible_;
      if (split_) {
        split_->SetSinglePaneToolbarVisible(single_pane_toolbar_visible_);
      }
      return true;
    case CommandId::kCollapsePinnedSection:
      if (focused) {
        model.SetPinnedCollapsed(*focused, true);
      }
      return true;
    case CommandId::kExpandPinnedSection:
      if (focused) {
        model.SetPinnedCollapsed(*focused, false);
      }
      return true;
    case CommandId::kAppearanceAutomatic:
    case CommandId::kAppearanceLight:
    case CommandId::kAppearanceDark: {
      const char* val = command == CommandId::kAppearanceLight ? "light"
                        : command == CommandId::kAppearanceDark ? "dark"
                                                                : "automatic";
      std::string err;
      webui::OpenPreferences::Get()->Set("appearance.websiteAppearance",
                                         base::Value(val), active_profile, true,
                                         &err);
      s->ApplyPreferencesNow();
      return true;
    }

    // --- Split View ---
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
    case CommandId::kSeparateFromSplitView:
      if (active) {
        if (std::optional<NodeParent> parent = model.GetParent(*active);
            parent && parent->kind == NodeParentKind::kSplitPane) {
          model.RemovePane(parent->owner_id, *active, /*archive=*/false);
        }
      }
      return true;
    case CommandId::kExpandCurrentSplit:
      if (focused) {
        if (std::optional<ItemID> sel =
                model.SelectedNodeId(*focused, window_id_)) {
          if (const Split* split = model.FindSplit(*sel);
              split && !split->panes.empty()) {
            model.SetSplitFractions(
                split->id, std::vector<double>(split->panes.size(),
                                               1.0 / split->panes.size()));
          }
        }
      }
      return true;
    case CommandId::kNextSplitPane:
    case CommandId::kPreviousSplitPane:
      if (focused && active) {
        if (std::optional<ItemID> sel =
                model.SelectedNodeId(*focused, window_id_)) {
          if (const Split* split = model.FindSplit(*sel);
              split && split->panes.size() >= 2) {
            size_t cur = 0;
            for (size_t i = 0; i < split->panes.size(); ++i) {
              if (split->panes[i].id == *active) {
                cur = i;
                break;
              }
            }
            const size_t next =
                command == CommandId::kNextSplitPane
                    ? (cur + 1) % split->panes.size()
                    : (cur + split->panes.size() - 1) % split->panes.size();
            bridge->SelectNode(split->panes[next].id, window_id_);
          }
        }
      }
      return true;

    // --- Peek, Email & Meetings ---
    case CommandId::kOpenInCurrentSpace:
      if (peek_shown()) {
        ExpandPeek();
      }
      return true;
    case CommandId::kPeekEmail: {
      if (const Profile* prof = model.FindProfile(active_profile)) {
        for (const Tab& fav : prof->favorites) {
          if (IsMailUrl(fav.url)) {
            OpenPeek(GURL(fav.url), fav.id);
            return true;
          }
        }
      }
      if (focused) {
        if (const Space* space = model.FindSpace(*focused)) {
          for (const SidebarNode& n : space->pinned) {
            if (const Tab* tab = n.as_tab(); tab && IsMailUrl(tab->url)) {
              OpenPeek(GURL(tab->url), tab->id);
              return true;
            }
          }
        }
      }
      ShowToast(ToastSpec::Info(u"No pinned email tab found."));
      return true;
    }
    case CommandId::kJoinMeeting:
      if (OpenLiveDataService* ld = s->livedata()) {
        if (auto meeting = ld->NextUpcomingMeeting();
            meeting && !meeting->join_url.empty()) {
          const GURL join(meeting->join_url);
          if (join.is_valid()) {
            bridge->OpenTab(join, /*background=*/false, window_id_);
            return true;
          }
        }
      }
      ShowToast(ToastSpec::Info(u"No upcoming meeting with a join link."));
      return true;

    // --- Boosts, Capture, Copy, Site Data ---
    case CommandId::kNewBoost:
      OpenBoostEditor(std::nullopt);
      return true;
    case CommandId::kEditBoost:
      OpenBoostEditor(std::nullopt);
      return true;
    case CommandId::kNewLegacyBoost:
    case CommandId::kBoostGallery:
      bridge->OpenTab(GURL(webui::OpenWebUIURL(webui::kHostBoosts)),
                      /*background=*/false, window_id_);
      return true;
    case CommandId::kCapturePage:
      if (OpenCaptureController* cap = s->capture_controller();
          cap && ActiveWebContents() && widget()) {
        cap->CaptureRegion(ActiveWebContents(), widget(), PanelRectInWidget(),
                           CurrentAppearance());
        RestackVisibleOverlays();
      }
      return true;
    case CommandId::kCaptureFullPage:
      if (OpenCaptureController* cap = s->capture_controller();
          cap && ActiveWebContents() && widget()) {
        cap->CaptureFullPage(ActiveWebContents(), widget(), PanelRectInWidget(),
                             CurrentAppearance());
        RestackVisibleOverlays();
      }
      return true;
    case CommandId::kCapturePortrait:
      if (OpenCaptureController* cap = s->capture_controller();
          cap && ActiveWebContents() && widget()) {
        PortraitCaptureOptions opts;
        if (open_view_) {
          opts.space_theme = open_view_->FocusedThemeState().style;
        }
        cap->CapturePortrait(ActiveWebContents(), widget(), PanelRectInWidget(),
                             CurrentAppearance(), opts);
        RestackVisibleOverlays();
      }
      return true;
    case CommandId::kSharePage:
      if (content::WebContents* wc = ActiveWebContents()) {
        CopyCleanUrl(wc->GetLastCommittedURL());
      }
      return true;
    case CommandId::kCopyUrl:
      if (content::WebContents* contents = ActiveWebContents()) {
        CopyUrl(contents->GetLastCommittedURL());
      }
      return true;
    case CommandId::kCopyUrlMarkdown:
      if (content::WebContents* contents = ActiveWebContents()) {
        const std::string title = base::UTF16ToUTF8(contents->GetTitle());
        const std::string url = contents->GetLastCommittedURL().spec();
        ui::ScopedClipboardWriter(ui::ClipboardBuffer::kCopyPaste)
            .WriteText(base::UTF8ToUTF16(
                base::StrCat({"[", title.empty() ? url : title, "](", url, ")"})));
        ShowToast(ToastSpec::ForKind(OpenToastKind::kCopiedMarkdown));
      }
      return true;
    case CommandId::kCopyUrlQuote:
      if (content::WebContents* contents = ActiveWebContents()) {
        std::u16string sel;
        if (content::RenderWidgetHostView* rwhv =
                contents->GetRenderWidgetHostView()) {
          sel = rwhv->GetSelectedText();
        }
        const std::string url = contents->GetLastCommittedURL().spec();
        const std::string quote =
            sel.empty()
                ? url
                : base::StrCat(
                      {"> ", base::UTF16ToUTF8(sel), "\n\n", url});
        ui::ScopedClipboardWriter(ui::ClipboardBuffer::kCopyPaste)
            .WriteText(base::UTF8ToUTF16(quote));
        ShowToast(ToastSpec::ForKind(OpenToastKind::kCopiedQuoteLink));
      }
      return true;
    case CommandId::kClearCacheAndRefresh:
      if (content::WebContents* wc = ActiveWebContents()) {
        site_control_data::ClearSiteDataAndReload(wc, SiteDataKind::kCache);
      }
      return true;
    case CommandId::kClearCookiesAndRefresh:
      if (content::WebContents* wc = ActiveWebContents()) {
        site_control_data::ClearSiteDataAndReload(wc, SiteDataKind::kCookies);
      }
      return true;

    // --- Find & Modal Dismiss ---
    case CommandId::kFind:
      ShowFindBar();
      return true;
    case CommandId::kFindNext:
      FindNext(/*forward=*/true);
      return true;
    case CommandId::kFindPrevious:
      FindNext(/*forward=*/false);
      return true;
    case CommandId::kUseSelectionToFind:
      ShowFindBar();
      return true;
    case CommandId::kExitModal:
      if (command_bar_shown()) {
        HideCommandBar();
      } else if (peek_shown()) {
        ClosePeek();
      } else if (library_drawer_shown()) {
        HideLibraryDrawer();
      } else if (boost_editor_shown()) {
        CloseBoostEditor();
      } else if (site_controls_shown()) {
        HideSiteControls();
      } else if (find_bar_shown()) {
        CloseFindBar();
      }
      return true;

    // --- Extensions ---
    case CommandId::kOpenExtensionsPicker:
      if (OpenExtensionBridge* extensions = ExtensionBridge()) {
        views::View* anchor = open_view_ ? open_view_->GetUrlPillView() : nullptr;
        OpenExtensionBridge::PickerCallbacks cb;
        cb.dark = CurrentAppearance().dark;
        cb.on_manage_extensions = base::BindRepeating(
            [](base::WeakPtr<OpenWindowUi> self) {
              if (self) {
                self->RunCommandId(CommandId::kManageExtensions);
              }
            },
            weak_factory_.GetWeakPtr());
        cb.on_add_extension = base::BindRepeating(
            [](base::WeakPtr<OpenWindowUi> self) {
              if (self) {
                self->RunCommandId(CommandId::kAddExtension);
              }
            },
            weak_factory_.GetWeakPtr());
        extensions->ShowExtensionsPicker(MakeExtensionHostWindow(), anchor, cb);
      }
      return true;
    case CommandId::kAddExtension:
      bridge->OpenTab(GURL(kChromeWebStoreUrl), /*background=*/false,
                      window_id_);
      return true;
    case CommandId::kManageExtensions:
      bridge->OpenTab(GURL("chrome://extensions/"), /*background=*/false,
                      window_id_);
      return true;
    case CommandId::kExtensionShortcuts:
      bridge->OpenTab(GURL("chrome://extensions/shortcuts"),
                      /*background=*/false, window_id_);
      return true;

    // --- Easels & Notes ---
    case CommandId::kNewEasel:
      CreateAndOpenDocument(/*is_easel=*/true, /*in_split=*/false);
      return true;
    case CommandId::kNewNote:
      CreateAndOpenDocument(/*is_easel=*/false, /*in_split=*/false);
      return true;
    case CommandId::kNewNoteInSplit:
      CreateAndOpenDocument(/*is_easel=*/false, /*in_split=*/true);
      return true;

    // --- Help, Diagnostics & Settings Deep Links ---
    case CommandId::kGettingStarted:
      bridge->OpenTab(GURL(webui::OpenWebUIURL(webui::kHostWelcome)),
                      /*background=*/false, window_id_);
      return true;
    case CommandId::kKeyboardShortcutsEdu:
    case CommandId::kShowShortcutsOverlay:
      bridge->OpenTab(
          GURL(webui::OpenWebUIURL(webui::kHostWelcome, "#shortcuts")),
          /*background=*/false, window_id_);
      return true;
    case CommandId::kRevealOpenData:
      if (::Profile* prof = s->ChromeProfileFor(active_profile)) {
        platform_util::ShowItemInFolder(prof, s->user_data_dir());
      }
      return true;
    case CommandId::kCopyOpenInfo: {
      const std::string info = base::StrCat(
          {"Open ", webui::OpenSettingsUI::OpenVersion(), "\nChromium ",
           std::string(version_info::GetVersionNumber()), "\n",
           base::SysInfo::OperatingSystemName(), " ",
           base::SysInfo::OperatingSystemVersion(), " (",
           base::SysInfo::OperatingSystemArchitecture(), ")"});
      ui::ScopedClipboardWriter(ui::ClipboardBuffer::kCopyPaste)
          .WriteText(base::UTF8ToUTF16(info));
      ShowToast(ToastSpec::ForKind(OpenToastKind::kCopiedOpenInfo));
      return true;
    }
    case CommandId::kToggleDeveloperMode: {
      const bool next = !PrefBool("advanced.developerMode", false);
      std::string err;
      webui::OpenPreferences::Get()->Set("advanced.developerMode",
                                         base::Value(next), active_profile,
                                         true, &err);
      ShowToast(ToastSpec::ForKind(next ? OpenToastKind::kDeveloperModeOn
                                        : OpenToastKind::kDeveloperModeOff));
      return true;
    }
    case CommandId::kNewProfile:
      controller_->OpenSettingsWindow("profiles");
      return true;
    case CommandId::kAirTrafficControl:
      controller_->OpenSettingsWindow("links");
      return true;
    case CommandId::kSearchSettings:
      controller_->OpenSettingsWindow("search");
      return true;
    case CommandId::kAccountSync:
      controller_->OpenSettingsWindow("sync");
      return true;
    case CommandId::kSyncNow:
      if (SyncEngine* sync = s->sync(); sync && sync->is_signed_in()) {
        sync->SyncNow();
        ShowToast(ToastSpec::ForKind(OpenToastKind::kSyncCompleted));
      } else {
        controller_->OpenSettingsWindow("sync");
      }
      return true;
    case CommandId::kManagePasswords:
      bridge->OpenTab(GURL("chrome://password-manager/passwords"),
                      /*background=*/false, window_id_);
      return true;
    case CommandId::kHelpCenter:
    case CommandId::kReleaseNotes:
    case CommandId::kContactTeam:
      controller_->OpenSettingsWindow("about");
      return true;

    default:
      // Pure Chromium native commands (Print, SavePageAs, Zoom, DevTools,
      // ViewSource, TaskManager, Cast, etc.) fall through to
      // FallbackChromiumCommandForOpen.
      return false;
  }
}

void OpenWindowUi::OnCommandBarIntent(const CommandBarIntent& intent) {
  const CommandBarRow& row = intent.row;
  switch (row.kind) {
    case CommandBarRowKind::kSwitchToTab:
    case CommandBarRowKind::kSwitchToSplit:
      if (row.tab_id) {
        service()->tab_bridge()->SelectNode(*row.tab_id, window_id_);
      }
      return;
    case CommandBarRowKind::kAction:
      RunAction(row.action_id);
      return;
    case CommandBarRowKind::kCalculator:
      ui::ScopedClipboardWriter(ui::ClipboardBuffer::kCopyPaste)
          .WriteText(row.title);
      ShowToast(ToastSpec::ForKind(OpenToastKind::kCopied));
      return;
    default:
      break;
  }
  OpenUrlWithDisposition(
      UrlForCommandBarIntent(service(), service()->ActiveProfileId(), intent),
      intent.disposition);
}

void OpenWindowUi::OnCommandBarDismissed(
    CommandBarDismissReason reason,
    std::optional<gfx::Point> click_location) {
  if (remote_suggest_request_id_ != 0) {
    service()->suggest().CancelRemoteSuggestions(remote_suggest_request_id_);
    remote_suggest_request_id_ = 0;
  }
  if (command_bar_) {
    command_bar_->SetVisible(false);
  }
  if (command_bar_host_) {
    command_bar_host_->Hide();
  }
  UpdateEscapeRegistration();
  if (peek_shown()) {
    if (content::WebContents* pwc = PeekWebContents()) {
      pwc->Focus();
    }
  } else if (content::WebContents* contents = ActiveWebContents()) {
    contents->Focus();
  }
  controller_->NotifyCommandBarStateChanged(window_id_);
}

// --- Peek (Zero-Reload Adoption & Transfer) ----------------------------------

void OpenWindowUi::PopulatePeekSpaceChoices() {
  if (!peek_) {
    return;
  }
  const ProfileID profile = service()->ActiveProfileId();
  std::vector<PeekSpaceChoice> choices;
  for (const Space& space : service()->model().spaces()) {
    if (space.profile_id != profile) {
      continue;
    }
    PeekSpaceChoice choice;
    choice.id = space.id;
    choice.title = SpaceTitle(space);
    choice.icon = space.icon;
    choice.color = SpacePrimaryColor(space);
    choices.push_back(std::move(choice));
  }
  peek_->SetSpaceChoices(std::move(choices));
}

void OpenWindowUi::OpenPeek(const GURL& url,
                            const std::optional<ItemID>& source_node) {
  if (!url.is_valid() || !browser_view_ || !browser_view_->browser()) {
    return;
  }
  content::WebContents::CreateParams params(
      browser_view_->browser()->GetProfile());
  std::unique_ptr<content::WebContents> wc =
      content::WebContents::Create(params);
  AttachOverlayPageHelpers(wc.get());
  if (auto* modal =
          web_modal::WebContentsModalDialogManager::FromWebContents(wc.get())) {
    modal->SetDelegate(this);
  }
  wc->GetController().LoadURLWithParams(
      content::NavigationController::LoadURLParams(url));
  OpenPeekWithContents(std::move(wc), source_node);
}

void OpenWindowUi::OpenPeekWithContents(
    std::unique_ptr<content::WebContents> wc,
    const std::optional<ItemID>& source_node) {
  if (!wc) {
    return;
  }
  EnsurePeek();
  if (!peek_) {
    return;
  }
  AttachOverlayPageHelpers(wc.get());
  if (auto* modal =
          web_modal::WebContentsModalDialogManager::FromWebContents(wc.get())) {
    modal->SetDelegate(this);
  }
  if (!peek_->is_showing()) {
    peek_source_ = source_node;
  }
  PopulatePeekSpaceChoices();
  peek_->SetAppearance(CurrentAppearance());
  UpdateOverlayAnchors();
  peek_host_->Show();
  peek_->SetVisible(true);
  if (peek_->is_showing()) {
    peek_->PushWebContents(std::move(wc));
  } else {
    peek_->AdoptWebContents(std::move(wc), open_view_->GetPanelBounds());
  }
  RestackVisibleOverlays();
  UpdateEscapeRegistration();
  controller_->NotifyPeekChanged(window_id_);
}

content::WebContents* OpenWindowUi::PeekWebContents() const {
  return peek_ ? peek_->active_web_contents() : nullptr;
}

void OpenWindowUi::ExpandPeek() {
  OnPeekExpandToTab();
}

void OpenWindowUi::ClosePeek() {
  const bool was_shown = peek_shown();
  if (content::WebContents* wc = PeekWebContents()) {
    if (auto* modal =
            web_modal::WebContentsModalDialogManager::FromWebContents(wc)) {
      modal->SetDelegate(nullptr);
    }
  }
  if (peek_ && peek_->is_showing()) {
    peek_->Hide();
  }
  if (peek_) {
    peek_->SetVisible(false);
  }
  if (peek_host_ && peek_host_->IsVisible()) {
    peek_host_->Hide();
  }
  peek_source_.reset();
  UpdateEscapeRegistration();
  if (was_shown) {
    FocusPage();
    controller_->NotifyPeekChanged(window_id_);
  }
}

bool OpenWindowUi::peek_shown() const {
  return peek_ && peek_->is_showing();
}

void OpenWindowUi::OnPeekDismissed(PeekDismissReason reason) {
  ClosePeek();
}

void OpenWindowUi::OnPeekDismissedWithUndo(PeekDismissReason reason,
                                           const GURL& last_dismissed_url) {
  if (reason == PeekDismissReason::kProgrammatic ||
      !last_dismissed_url.is_valid()) {
    return;
  }
  const std::optional<ItemID> src = peek_source_;
  ShowToast(ToastSpec::ForKind(
      OpenToastKind::kPeekClosed, {},
      base::BindOnce(&OpenWindowUi::OpenPeek, weak_factory_.GetWeakPtr(),
                     last_dismissed_url, src)));
}

bool OpenWindowUi::OnPeekCopyUrl(const GURL& url) {
  if (!url.is_valid()) {
    return false;
  }
  CopyUrl(url);
  return true;
}

void OpenWindowUi::OnPeekExpandToTab() {
  if (!peek_ || !peek_->is_showing()) {
    return;
  }
  std::unique_ptr<content::WebContents> wc = peek_->ReleaseWebContents();
  if (!peek_->is_showing()) {
    if (peek_host_ && peek_host_->IsVisible()) {
      peek_host_->Hide();
    }
    peek_->SetVisible(false);
    peek_source_.reset();
    UpdateEscapeRegistration();
    controller_->NotifyPeekChanged(window_id_);
  }
  if (!wc) {
    return;
  }
  if (auto* modal =
          web_modal::WebContentsModalDialogManager::FromWebContents(wc.get())) {
    modal->SetDelegate(nullptr);
  }
  wc->SetDelegate(nullptr);
  const BrowserModel& model = service()->model();
  std::optional<SpaceID> focused = model_util::FocusedSpace(model, window_id_);
  if (!focused) {
    if (const WindowID main_id = service()->MainWindowId(); !main_id.empty()) {
      focused = model_util::FocusedSpace(model, main_id);
    }
  }
  if (!focused && !model.spaces().empty()) {
    focused = model.spaces().front().id;
  }
  if (focused && service()->tab_bridge()) {
    service()->tab_bridge()->AdoptLiveWebContentsAsTab(
        std::move(wc), *focused, /*background=*/false, window_id_);
    ShowToast(ToastSpec::ForKind(OpenToastKind::kPeekPromoted));
  }
}

void OpenWindowUi::OnPeekOpenInSplit() {
  if (!peek_ || !peek_->is_showing()) {
    return;
  }
  const std::optional<ItemID> active = ActiveTabId();
  std::unique_ptr<content::WebContents> wc = peek_->ReleaseWebContents();
  if (!peek_->is_showing()) {
    if (peek_host_ && peek_host_->IsVisible()) {
      peek_host_->Hide();
    }
    peek_->SetVisible(false);
    peek_source_.reset();
    UpdateEscapeRegistration();
    controller_->NotifyPeekChanged(window_id_);
  }
  if (!wc) {
    return;
  }
  if (auto* modal =
          web_modal::WebContentsModalDialogManager::FromWebContents(wc.get())) {
    modal->SetDelegate(nullptr);
  }
  wc->SetDelegate(nullptr);
  const BrowserModel& model = service()->model();
  std::optional<SpaceID> focused = model_util::FocusedSpace(model, window_id_);
  if (!focused) {
    if (const WindowID main_id = service()->MainWindowId(); !main_id.empty()) {
      focused = model_util::FocusedSpace(model, main_id);
    }
  }
  if (!focused && !model.spaces().empty()) {
    focused = model.spaces().front().id;
  }
  if (focused && service()->tab_bridge()) {
    const ItemID adopted = service()->tab_bridge()->AdoptLiveWebContentsAsTab(
        std::move(wc), *focused, /*background=*/true, window_id_);
    if (active && !adopted.empty()) {
      service()->model().MakeSplit({*active, adopted});
      ShowToast(ToastSpec::ForKind(OpenToastKind::kSplitViewAdded));
    }
  }
}

void OpenWindowUi::OnPeekOpenInFavorite() {
  if (!peek_ || !peek_->is_showing()) {
    return;
  }
  std::unique_ptr<content::WebContents> wc = peek_->ReleaseWebContents();
  if (!peek_->is_showing()) {
    if (peek_host_ && peek_host_->IsVisible()) {
      peek_host_->Hide();
    }
    peek_->SetVisible(false);
    peek_source_.reset();
    UpdateEscapeRegistration();
    controller_->NotifyPeekChanged(window_id_);
  }
  if (!wc) {
    return;
  }
  if (auto* modal =
          web_modal::WebContentsModalDialogManager::FromWebContents(wc.get())) {
    modal->SetDelegate(nullptr);
  }
  wc->SetDelegate(nullptr);
  const BrowserModel& model = service()->model();
  std::optional<SpaceID> focused = model_util::FocusedSpace(model, window_id_);
  if (!focused) {
    if (const WindowID main_id = service()->MainWindowId(); !main_id.empty()) {
      focused = model_util::FocusedSpace(model, main_id);
    }
  }
  if (!focused && !model.spaces().empty()) {
    focused = model.spaces().front().id;
  }
  if (focused && service()->tab_bridge()) {
    const ItemID adopted = service()->tab_bridge()->AdoptLiveWebContentsAsTab(
        std::move(wc), *focused, /*background=*/false, window_id_);
    if (!adopted.empty()) {
      service()->model().AddFavorite(adopted, service()->ActiveProfileId());
      ShowToast(ToastSpec::ForKind(OpenToastKind::kAddedToFavorites));
    }
  }
}

void OpenWindowUi::OnPeekOpenInSpace(const SpaceID& space_id) {
  if (!peek_ || !peek_->is_showing() || space_id.empty()) {
    return;
  }
  std::unique_ptr<content::WebContents> wc = peek_->ReleaseWebContents();
  if (!peek_->is_showing()) {
    if (peek_host_ && peek_host_->IsVisible()) {
      peek_host_->Hide();
    }
    peek_->SetVisible(false);
    peek_source_.reset();
    UpdateEscapeRegistration();
    controller_->NotifyPeekChanged(window_id_);
  }
  if (!wc || !service()->tab_bridge()) {
    return;
  }
  if (auto* modal =
          web_modal::WebContentsModalDialogManager::FromWebContents(wc.get())) {
    modal->SetDelegate(nullptr);
  }
  wc->SetDelegate(nullptr);
  service()->tab_bridge()->FocusSpace(space_id, window_id_);
  service()->tab_bridge()->AdoptLiveWebContentsAsTab(
      std::move(wc), space_id, /*background=*/false, window_id_);
  ShowToast(ToastSpec::ForKind(OpenToastKind::kPeekPromoted));
}

// --- Site Control ------------------------------------------------------------

open_unified::SiteControlState OpenWindowUi::BuildSiteControlState() const {
  open_unified::SiteControlState state;
  content::WebContents* contents = ActiveWebContents();
  if (!contents) {
    return state;
  }
  const GURL url = contents->GetLastCommittedURL();
  state.url = url;
  state.host = base::UTF8ToUTF16(url.host());
  state.secure = url.SchemeIsCryptographic();
  state.is_website = url.SchemeIsHTTPOrHTTPS() && !url.host().empty();
  state.incognito = controller_->IsIncognitoWindow(window_id_);
  state.can_create_boost = state.is_website && !state.incognito;
  state.boosts_globally_enabled = OpenBoostController::BoostsGloballyEnabled();

  OpenBrowserService* s = service();
  if (std::optional<ItemID> tab = ActiveTabId()) {
    if (std::optional<ProfileID> profile =
            model_util::ProfileOfNode(s->model(), *tab)) {
      const std::vector<Boost> matches =
          s->boost_controller()->MatchingBoosts(*profile, url);
      state.boost_active = !matches.empty();
      for (const Boost& b : matches) {
        state.boosts.push_back(site_control_data::BoostItemFor(b));
      }
    }
  }
  if (OpenExtensionBridge* extensions = ExtensionBridge()) {
    BrowserWindowInterface* browser =
        browser_view_ ? browser_view_->browser() : nullptr;
    const std::vector<ExtensionActionInfo> actions =
        browser
            ? extensions->GetAllToolbarActions(browser,
                                               /*include_unpinned=*/true)
            : extensions->ListActions();
    for (const ExtensionActionInfo& info : actions) {
      SiteControlExtensionItem item;
      item.id = info.id;
      item.name = base::UTF8ToUTF16(info.name);
      item.icon = info.icon;
      item.badge_text = base::UTF8ToUTF16(info.badge_text);
      if (info.badge_background_color != SK_ColorTRANSPARENT) {
        item.badge_color = info.badge_background_color;
      }
      item.badge_text_color = info.badge_text_color;
      item.tooltip = info.tooltip;
      item.enabled = info.enabled && info.visible && info.runnable;
      item.pinned = info.pinned;
      item.force_pinned = info.force_pinned;
      item.has_popup = info.has_popup;
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
  state.ad_block_excluded = adblock && adblock->IsHostExcluded(url.host());
  state.ad_block_blocked_count =
      OpenAdBlockProfileService::GetTotalStoppedCount(contents);
  state.split_available = !split_active_;
  return state;
}

SiteControlCallbacks OpenWindowUi::BuildSiteControlCallbacks() {
  SiteControlCallbacks cb;
  cb.on_share = base::BindRepeating(
      [](base::WeakPtr<OpenWindowUi> self, const gfx::Rect&) {
        if (self) {
          if (content::WebContents* wc = self->ActiveWebContents()) {
            self->CopyCleanUrl(wc->GetLastCommittedURL());
          }
          self->HideSiteControls();
        }
      },
      weak_factory_.GetWeakPtr());
  cb.on_open_boost_editor = base::BindRepeating(
      [](base::WeakPtr<OpenWindowUi> self,
         const std::optional<std::string>& boost_id) {
        if (self) {
          self->HideSiteControls();
          self->OpenBoostEditor(boost_id);
        }
      },
      weak_factory_.GetWeakPtr());
  cb.on_capture_region = base::BindRepeating(
      [](base::WeakPtr<OpenWindowUi> self) {
        if (self) {
          self->HideSiteControls();
          self->RunCommandId(CommandId::kCapturePage);
        }
      },
      weak_factory_.GetWeakPtr());
  cb.on_capture_full_page = base::BindRepeating(
      [](base::WeakPtr<OpenWindowUi> self) {
        if (self) {
          self->HideSiteControls();
          self->RunCommandId(CommandId::kCaptureFullPage);
        }
      },
      weak_factory_.GetWeakPtr());
  cb.on_clear_cache_and_reload = base::BindRepeating(
      [](base::WeakPtr<OpenWindowUi> self) {
        if (self) {
          self->RunCommandId(CommandId::kClearCacheAndRefresh);
          self->HideSiteControls();
        }
      },
      weak_factory_.GetWeakPtr());
  cb.on_clear_cookies_and_reload = base::BindRepeating(
      [](base::WeakPtr<OpenWindowUi> self) {
        if (self) {
          self->RunCommandId(CommandId::kClearCookiesAndRefresh);
          self->HideSiteControls();
        }
      },
      weak_factory_.GetWeakPtr());
  cb.on_copy_clean_url = base::BindRepeating(
      [](base::WeakPtr<OpenWindowUi> self) {
        if (self) {
          if (content::WebContents* wc = self->ActiveWebContents()) {
            self->CopyCleanUrl(wc->GetLastCommittedURL());
          }
          self->HideSiteControls();
        }
      },
      weak_factory_.GetWeakPtr());
  cb.on_open_site_settings = base::BindRepeating(
      [](base::WeakPtr<OpenWindowUi> self) {
        if (self) {
          if (content::WebContents* wc = self->ActiveWebContents()) {
            self->service()->tab_bridge()->OpenTab(
                GURL("chrome://settings/content/siteDetails?site=" +
                     url::Origin::Create(wc->GetLastCommittedURL()).Serialize()),
                /*background=*/false, self->window_id_);
          }
          self->HideSiteControls();
        }
      },
      weak_factory_.GetWeakPtr());
  cb.on_manage_boosts = base::BindRepeating(
      [](base::WeakPtr<OpenWindowUi> self) {
        if (self) {
          self->HideSiteControls();
          self->ShowLibraryDrawer("boosts");
        }
      },
      weak_factory_.GetWeakPtr());
  cb.on_manage_extensions = base::BindRepeating(
      [](base::WeakPtr<OpenWindowUi> self) {
        if (self) {
          self->HideSiteControls();
          self->RunCommandId(CommandId::kManageExtensions);
        }
      },
      weak_factory_.GetWeakPtr());
  cb.on_add_extension = base::BindRepeating(
      [](base::WeakPtr<OpenWindowUi> self) {
        if (self) {
          self->HideSiteControls();
          self->RunCommandId(CommandId::kAddExtension);
        }
      },
      weak_factory_.GetWeakPtr());
  cb.on_toggle_extension_pin = base::BindRepeating(
      [](base::WeakPtr<OpenWindowUi> self, const std::string& id, bool pinned) {
        if (self) {
          if (OpenExtensionBridge* ext = self->ExtensionBridge()) {
            ext->SetActionPinned(id, pinned);
          }
        }
      },
      weak_factory_.GetWeakPtr());
  cb.on_run_extension_action = base::BindRepeating(
      [](base::WeakPtr<OpenWindowUi> self, const std::string& id,
         views::View* anchor) {
        if (self) {
          self->OnSiteControlExtensionPressed(id, anchor);
        }
      },
      weak_factory_.GetWeakPtr());
  cb.on_extension_context_menu = base::BindRepeating(
      [](base::WeakPtr<OpenWindowUi> self, const std::string& id,
         views::View* anchor, const gfx::Point& pt,
         ui::mojom::MenuSourceType source) {
        if (self) {
          if (OpenExtensionBridge* ext = self->ExtensionBridge()) {
            ext->ShowContextMenu(self->MakeExtensionHostWindow(), id, anchor,
                                 pt, source);
          }
        }
      },
      weak_factory_.GetWeakPtr());
  cb.on_boost_enabled_changed = base::BindRepeating(
      [](base::WeakPtr<OpenWindowUi> self, const std::string& boost_id,
         bool enabled) {
        if (!self || !self->service()->boost_controller()) {
          return;
        }
        const ProfileID profile = self->service()->ActiveProfileId();
        if (auto b =
                self->service()->boost_controller()->FindBoost(profile, boost_id)) {
          b->enabled = enabled;
          self->service()->boost_controller()->SaveBoost(profile, *b);
        }
      },
      weak_factory_.GetWeakPtr());
  cb.on_open_ad_block_settings = base::BindRepeating(
      [](base::WeakPtr<OpenWindowUi> self) {
        if (self) {
          self->HideSiteControls();
          self->controller_->OpenSettingsWindow("adblock");
        }
      },
      weak_factory_.GetWeakPtr());
  cb.refresh_state = base::BindRepeating(
      [](base::WeakPtr<OpenWindowUi> self)
          -> std::optional<open_unified::SiteControlState> {
        if (!self || !self->ActiveWebContents()) {
          return std::nullopt;
        }
        return self->BuildSiteControlState();
      },
      weak_factory_.GetWeakPtr());
  return cb;
}

void OpenWindowUi::ShowSiteControls(views::View* anchor) {
  content::WebContents* contents = ActiveWebContents();
  if (!contents) {
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
  site_controls_->Show(target, BuildSiteControlState(), CurrentAppearance(),
                       contents, BuildSiteControlCallbacks());
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
  ShowToast(ToastSpec::ForKind(OpenToastKind::kCopiedUrl));
}

void OpenWindowUi::CopyCleanUrl(const GURL& url) {
  site_control_data::CopyCleanUrl(url);
  ShowToast(ToastSpec::ForKind(OpenToastKind::kCopiedCleanLink));
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
      HideSiteControls();
      OpenBoostEditor(std::nullopt);
      return;
    case SiteControlAction::kSplit:
      if (std::optional<ItemID> active = ActiveTabId()) {
        bridge->ToggleSplit(*active);
      }
      break;
    case SiteControlAction::kCapture:
      HideSiteControls();
      RunCommandId(CommandId::kCapturePage);
      return;
    case SiteControlAction::kSiteSettings:
    case SiteControlAction::kClearSiteData:
      bridge->OpenTab(GURL("chrome://settings/content/siteDetails?site=" +
                           url::Origin::Create(url).Serialize()),
                      /*background=*/false, window_id_);
      break;
  }
  HideSiteControls();
}

void OpenWindowUi::OnSiteControlExtensionPressed(
    const std::string& extension_id,
    views::View* anchor) {
  if (OpenExtensionBridge* extensions = ExtensionBridge()) {
    if (browser_view_ && browser_view_->browser()) {
      extensions->ExecuteAction(browser_view_->browser(), extension_id, anchor,
                                std::nullopt, base::DoNothing());
    } else {
      extensions->ExecuteAction(extension_id, anchor, base::DoNothing());
    }
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
      if (content::WebContents* active = ActiveWebContents()) {
        if (views::WebView* web_view =
                browser_view_->GetActiveContentsWebView()) {
          web_view->SetWebContents(active);
        }
      }
    }
    split_->SetSinglePaneToolbarVisible(single_pane_toolbar_visible_);
    return;
  }
  SplitPresentation presentation;
  presentation.split_id = split->id;
  presentation.orientation = split->orientation;
  presentation.fractions = split->fractions;
  presentation.focused_pane_id = split->focused_pane_id;
  presentation.show_single_pane_toolbar = single_pane_toolbar_visible_;
  presentation.focus_ring_color = CurrentAppearance().focus_ring;
  for (const Tab& pane : split->panes) {
    SplitPaneSpec spec;
    spec.tab_id = pane.id;
    spec.web_contents = s->tab_bridge()->EnsureLoaded(pane.id, window_id_);
    spec.is_empty_placeholder = pane.url == "about:blank" || pane.url.empty();
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
  service()->tab_bridge()->SelectNode(tab_id, window_id_);
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
      bridge->SelectNode(tab_id, window_id_);
      ShowSiteControls(anchor);
      return true;
    case PaneCommand::kAddSplit:
      if (split_id) {
        const ItemID opened =
            bridge->OpenTab(GURL("about:blank"), true, window_id_);
        return !opened.empty() && s->model().AddPane(*split_id, opened);
      }
      return bridge->ToggleSplit(tab_id).has_value();
    case PaneCommand::kSwapPanes:
      if (split_id) {
        if (const Split* split = s->model().FindSplit(*split_id);
            split && split->panes.size() >= 2 && split_) {
          return split_->SwapPanes(0, 1);
        }
      }
      return false;
    case PaneCommand::kToggleOrientation:
      if (split_id) {
        if (const Split* split = s->model().FindSplit(*split_id)) {
          return s->model().SetSplitOrientation(
              *split_id, split->orientation == SplitOrientation::kHorizontal
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

void OpenWindowUi::OnEmptyPaneOpenCommandBar(
    const std::optional<ItemID>& split_id,
    const ItemID& tab_id) {
  if (OpenTabBridge* bridge = service()->tab_bridge()) {
    bridge->SelectNode(tab_id, window_id_);
  }
  ShowCommandBar(CommandBarMode::kEditCurrentUrl, std::u16string(),
                 std::nullopt);
}

void OpenWindowUi::OnPanesSwapped(const ItemID& split_id,
                                  size_t index_a,
                                  size_t index_b) {
  BrowserModel& model = service()->model();
  const Split* split = model.FindSplit(split_id);
  if (!split || index_a == index_b || index_a >= split->panes.size() ||
      index_b >= split->panes.size()) {
    return;
  }
  const size_t lo = std::min(index_a, index_b);
  const size_t hi = std::max(index_a, index_b);
  const ItemID id_lo = split->panes[lo].id;
  const ItemID id_hi = split->panes[hi].id;
  const NodeParent parent{NodeParentKind::kSplitPane, split_id};
  model.MoveNode(id_hi, parent, lo);
  model.MoveNode(id_lo, parent, hi);
}

bool OpenWindowUi::CanDropInSplit(const std::optional<ItemID>& dragged_tab_id,
                                  const GURL& dragged_url,
                                  SplitDropZone zone,
                                  std::optional<size_t> target_pane_index) {
  if (dragged_tab_id && !dragged_tab_id->empty()) {
    return service()->model().FindTab(*dragged_tab_id) != nullptr;
  }
  return dragged_url.is_valid();
}

bool OpenWindowUi::OnDropInSplit(const std::optional<ItemID>& dragged_tab_id,
                                 const GURL& dragged_url,
                                 SplitDropZone zone,
                                 std::optional<size_t> target_pane_index) {
  BrowserModel& model = service()->model();
  OpenTabBridge* bridge = service()->tab_bridge();
  if (!bridge) {
    return false;
  }
  ItemID incoming;
  if (dragged_tab_id && model.FindTab(*dragged_tab_id)) {
    incoming = *dragged_tab_id;
  } else if (dragged_url.is_valid()) {
    incoming = bridge->OpenTab(dragged_url, /*background=*/true, window_id_);
  }
  if (incoming.empty()) {
    return false;
  }

  const SplitOrientation orientation =
      (zone == SplitDropZone::kTop || zone == SplitDropZone::kBottom)
          ? SplitOrientation::kVertical
          : SplitOrientation::kHorizontal;
  const bool insert_before =
      zone == SplitDropZone::kLeft || zone == SplitDropZone::kTop;

  const std::optional<SpaceID> focused =
      model_util::FocusedSpace(model, window_id_);
  const std::optional<ItemID> selected =
      focused ? model.SelectedNodeId(*focused, window_id_) : std::nullopt;
  if (const Split* split = selected ? model.FindSplit(*selected) : nullptr) {
    if (zone == SplitDropZone::kReplacePane && target_pane_index &&
        *target_pane_index < split->panes.size()) {
      const ItemID old_pane = split->panes[*target_pane_index].id;
      if (old_pane == incoming) {
        return true;
      }
      model.AddPane(split->id, incoming, *target_pane_index);
      model.RemovePane(split->id, old_pane, /*archive=*/false);
      return true;
    }
    const std::optional<size_t> pos =
        insert_before ? std::optional<size_t>(0) : std::nullopt;
    return model.AddPane(split->id, incoming, pos);
  }

  const std::optional<ItemID> active = ActiveTabId();
  if (!active || *active == incoming) {
    return false;
  }
  std::vector<ItemID> panes =
      insert_before ? std::vector<ItemID>{incoming, *active}
                    : std::vector<ItemID>{*active, incoming};
  return !model.MakeSplit(panes, orientation).empty();
}

// --- Link Status Bubble & Fullscreen -----------------------------------------

void OpenWindowUi::UpdateLinkStatusUrl(const GURL& url) {
  if (!link_status_ || !open_view_) {
    return;
  }
  if (open_view_->IsTabFullscreen()) {
    link_status_->Hide(/*animated=*/false);
    return;
  }
  link_status_->SetTargetUrl(url, open_view_->FocusedThemeState());
}

void OpenWindowUi::OnFullscreenStateChanged(bool is_fullscreen) {
  if (open_view_) {
    open_view_->SetTabFullscreen(is_fullscreen);
  }
  if (link_status_ && is_fullscreen) {
    link_status_->Hide(/*animated=*/false);
  }
}

// --- Overlay widgets & WidgetObserver ----------------------------------------

views::Widget* OpenWindowUi::widget() const {
  return browser_view_ ? browser_view_->GetWidget() : nullptr;
}

void OpenWindowUi::ActivateWindow() {
  if (views::Widget* w = widget()) {
    if (w->IsMinimized()) {
      w->Restore();
    }
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

gfx::Rect OpenWindowUi::PanelRectInScreen() const {
  if (panel_tracker_) {
    return panel_tracker_->GetBoundsInScreen();
  }
  gfx::Rect panel = open_view_->GetPanelBounds();
  gfx::Point origin = panel.origin();
  views::View::ConvertPointToScreen(open_view_, &origin);
  panel.set_origin(origin);
  return panel;
}

gfx::Rect OpenWindowUi::WindowRectInWidget() const {
  return open_view_->ConvertRectToWidget(open_view_->GetLocalBounds());
}

gfx::Rect OpenWindowUi::LibraryDrawerRectInWidget() const {
  const gfx::Rect win = WindowRectInWidget();
  const int sb_w = open_view_
                       ? static_cast<int>(std::lround(open_view_->sidebar_width()))
                       : 228;
  const int drawer_w =
      std::min(std::max(320, win.width() - 40), sb_w + kLibraryDrawerExtraWidth);
  return gfx::Rect(win.x(), win.y(), drawer_w, win.height());
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
  toasts_->SetVisibilityCallback(base::BindRepeating(
      [](base::WeakPtr<OpenWindowUi> self, bool visible) {
        if (!self || !self->toast_host_) {
          return;
        }
        if (visible) {
          self->UpdateOverlayAnchors();
          self->toast_host_->Show();
          self->RestackVisibleOverlays();
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
  const gfx::Rect window = WindowRectInWidget();
  if (command_bar_host_) {
    command_bar_host_->SetAnchor(window, Alignment::kFill);
    if (command_bar_shown() && open_view_) {
      const gfx::Rect pill_rect = open_view_->UrlPillScreenBounds();
      if (!pill_rect.IsEmpty()) {
        command_bar_->UpdateScreenAnchor(pill_rect);
      }
    }
  }
  if (peek_host_) {
    peek_host_->SetAnchor(window, Alignment::kFill);
    if (peek_ && peek_->is_showing()) {
      peek_->SetContentRect(open_view_->GetPanelBounds());
    }
  }
  if (library_host_) {
    library_host_->SetAnchor(LibraryDrawerRectInWidget(), Alignment::kFill);
  }
  if (find_host_) {
    find_host_->SetAnchor(
        OpenFindBarView::ComputeAnchor(panel, single_pane_toolbar_visible_),
        Alignment::kTopRight);
  }
  if (toast_host_) {
    std::optional<int> find_bar_bottom;
    if (find_bar_shown()) {
      find_bar_bottom = OpenFindBarView::ComputeBottom(
          panel, single_pane_toolbar_visible_);
    }
    toast_host_->SetAnchor(
        OpenToastStackView::ComputeAnchor(panel, find_bar_bottom),
        Alignment::kTopRight);
  }
  if (switcher_host_) {
    switcher_host_->SetAnchor(window, Alignment::kCenter);
  }
  if (boost_editor_ && boost_editor_->IsVisible()) {
    boost_editor_->UpdatePageBounds(PanelRectInScreen());
  }
  if (link_status_ && panel_tracker_) {
    link_status_->SetPageArea(panel_tracker_->GetLocalBounds());
  }
  if (OpenCaptureController* cap = service()->capture_controller();
      cap && (cap->IsOverlayVisible() || cap->IsResultCardVisible())) {
    cap->UpdateContentRect(panel);
  }
}

void OpenWindowUi::RestackVisibleOverlays() {
  // Deterministic bottom-to-top Z-order across all visible child overlays:
  // FindBar < Toasts < BoostEditor < LibraryDrawer < Peek < TabSwitcher
  // < CaptureOverlay < CommandBar.
  std::vector<views::Widget*> ordered;
  ordered.reserve(9);
  auto push_if_visible = [&ordered](views::Widget* w) {
    if (w && w->IsVisible()) {
      ordered.push_back(w);
    }
  };
  if (find_host_ && find_host_->IsVisible()) {
    push_if_visible(find_host_->widget());
  }
  if (toast_host_ && toast_host_->IsVisible()) {
    push_if_visible(toast_host_->widget());
  }
  if (boost_editor_ && boost_editor_->IsVisible() && boost_editor_->view()) {
    push_if_visible(boost_editor_->view()->GetWidget());
  }
  if (library_host_ && library_host_->IsVisible()) {
    push_if_visible(library_host_->widget());
  }
  if (peek_host_ && peek_host_->IsVisible()) {
    push_if_visible(peek_host_->widget());
  }
  if (switcher_host_ && switcher_host_->IsVisible()) {
    push_if_visible(switcher_host_->widget());
  }
  if (OpenCaptureController* cap = service()->capture_controller();
      cap && (cap->IsOverlayVisible() || cap->IsResultCardVisible())) {
    if (views::Widget* parent = widget()) {
      views::Widget* capture_overlay = nullptr;
      views::Widget* capture_card = nullptr;
      views::Widget::ForEachOwnedWidget(
          parent->GetNativeView(), [&](views::Widget* owned) {
            if (!owned || !owned->IsVisible()) {
              return;
            }
            const std::string name = owned->GetName();
            if (name == "OpenCaptureOverlay") {
              capture_overlay = owned;
            } else if (name == "OpenCaptureResultCard") {
              capture_card = owned;
            }
          });
      push_if_visible(capture_card);
      push_if_visible(capture_overlay);
    }
  }
  if (command_bar_host_ && command_bar_host_->IsVisible()) {
    push_if_visible(command_bar_host_->widget());
  }
  for (views::Widget* w : ordered) {
    w->StackAtTop();
  }
}

void OpenWindowUi::OnViewBoundsChanged(views::View* observed_view) {
  UpdateOverlayAnchors();
}

void OpenWindowUi::OnViewIsDeleting(views::View* observed_view) {
  panel_observation_.Reset();
  panel_tracker_ = nullptr;
  link_status_ = nullptr;
}

void OpenWindowUi::OnWidgetActivationChanged(views::Widget* widget,
                                             bool active) {
  if (active) {
    if (OpenHandoffController* handoff = service()->handoff()) {
      handoff->OnWindowActivated();
    }
  }
  ApplyWindowEffects();
}

void OpenWindowUi::OnWidgetDestroying(views::Widget* widget) {
  widget_observation_.Reset();
}

// --- Find in page (Wave E1 target-driven OpenFindBarView) --------------------

content::WebContents* OpenWindowUi::FindTargetContents() const {
  if (peek_shown()) {
    if (content::WebContents* pwc = PeekWebContents()) {
      return pwc;
    }
  }
  return ActiveWebContents();
}

find_in_page::FindTabHelper* OpenWindowUi::FindHelper() const {
  content::WebContents* contents = FindTargetContents();
  return contents ? find_in_page::FindTabHelper::FromWebContents(contents)
                  : nullptr;
}

bool OpenWindowUi::find_bar_shown() const {
  return find_host_ && find_host_->IsVisible();
}

void OpenWindowUi::ShowFindBar(std::optional<std::u16string> query) {
  content::WebContents* contents = FindTargetContents();
  find_in_page::FindTabHelper* helper =
      contents ? find_in_page::FindTabHelper::FromWebContents(contents)
               : nullptr;
  if (!helper) {
    return;
  }
  EnsureFindBar();
  if (!find_bar_) {
    return;
  }
  if (find_bar_shown() && find_bar_->target() == contents && !query) {
    find_bar_->Activate(std::u16string(find_bar_->query()));
    return;
  }

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
  find_bar_->SetTarget(contents);
  UpdateOverlayAnchors();
  find_host_->Show();
  UpdateOverlayAnchors();
  RestackVisibleOverlays();
  find_bar_->Activate(seed);
  if (!find_bar_->query().empty() && seed == find_bar_->query()) {
    helper->StartFinding(std::u16string(find_bar_->query()),
                         /*forward_direction=*/true,
                         find_bar_->case_sensitive(), /*find_match=*/true);
  }
  UpdateEscapeRegistration();
}

void OpenWindowUi::FindNext(bool forward) {
  if (!find_bar_shown()) {
    ShowFindBar();
    return;
  }
  if (find_bar_ && !find_bar_->query().empty()) {
    if (find_in_page::FindTabHelper* helper = FindHelper()) {
      helper->StartFinding(std::u16string(find_bar_->query()), forward,
                           find_bar_->case_sensitive(), /*find_match=*/true);
    }
  }
}

void OpenWindowUi::CloseFindBar() {
  const bool was_shown = find_bar_shown();
  if (find_bar_) {
    find_bar_->StopFinding();
    find_bar_->SetTarget(nullptr);
  }
  if (find_host_) {
    find_host_->Hide();
  }
  UpdateOverlayAnchors();
  UpdateEscapeRegistration();
  if (was_shown) {
    FocusPage();
  }
}

void OpenWindowUi::OnFindQueryChanged(const std::u16string& query) {
  // OpenFindBarView drives FindTabHelper directly when SetTarget() is active.
  if (find_bar_ && find_bar_->target()) {
    return;
  }
  if (find_in_page::FindTabHelper* helper = FindHelper()) {
    if (query.empty()) {
      helper->StopFinding(find_in_page::SelectionAction::kClear);
    } else {
      helper->StartFinding(query, /*forward_direction=*/true,
                           /*case_sensitive=*/false, /*find_match=*/true);
    }
  }
}

void OpenWindowUi::OnFindNext(bool forward) {
  if (find_bar_ && find_bar_->target()) {
    return;
  }
  FindNext(forward);
}

void OpenWindowUi::OnFindClosed() {
  CloseFindBar();
}

void OpenWindowUi::OnFindTargetDestroyed() {
  CloseFindBar();
}

// --- Toasts & Space Changes --------------------------------------------------

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
  UpdateThemeForLiveSurfaces();
  UpdatePanel();
  if (!switched) {
    return;
  }
  const BrowserWindowState* window = model.FindWindow(window_id_);
  if (!window || window->sidebar_mode != SidebarMode::kHidden) {
    return;
  }
  if (const Space* space = model.FindSpace(*focused)) {
    ShowToast(
        ToastSpec::SpaceSwitched(SpaceTitle(*space), IconText(space->icon)));
  }
}

// --- Ctrl+Tab Switcher (Wave E1 Live Thumbnails) -----------------------------

void OpenWindowUi::OnTabActivated(const ItemID& tab_id) {
  std::erase(mru_, tab_id);
  mru_.insert(mru_.begin(), tab_id);
  if (mru_.size() > kMruLimit) {
    mru_.resize(kMruLimit);
  }
  if (link_status_) {
    link_status_->Hide(/*animated=*/false);
  }
  if (find_bar_shown() && find_bar_ &&
      find_bar_->target() != FindTargetContents()) {
    CloseFindBar();
  }
}

bool OpenWindowUi::tab_switcher_active() const {
  return switcher_ && switcher_->is_active();
}

std::vector<TabSwitcherItem> OpenWindowUi::BuildSwitcherItems() const {
  const BrowserModel& model = service()->model();
  OpenTabBridge* bridge = service()->tab_bridge();
  const std::optional<SpaceID> focused_space =
      model_util::FocusedSpace(model, window_id_);
  std::vector<ItemID> ids;
  auto add = [&](const ItemID& id) {
    if (ids.size() < kSwitcherItemLimit && model.FindTab(id) &&
        std::find(ids.begin(), ids.end(), id) == ids.end()) {
      ids.push_back(id);
    }
  };
  if (bridge) {
    if (std::optional<ItemID> active = ActiveTabId()) {
      add(*active);
    }
  }
  for (const ItemID& id : mru_) {
    add(id);
  }
  if (ids.size() < 2 && focused_space) {
    for (const ItemID& id : model_util::OrderedTabIds(model, *focused_space)) {
      add(id);
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
    item.is_sleeping = (contents == nullptr);
    if (std::optional<SpaceID> tab_space = model_util::SpaceOfNode(model, id);
        tab_space && focused_space && *tab_space != *focused_space) {
      if (const Space* sp = model.FindSpace(*tab_space)) {
        item.subtitle = item.host + u" · " + SpaceTitle(*sp);
      }
    }
    item.favicon = controller_->GetFavicon(id);
    items.push_back(std::move(item));
  }
  return items;
}

void OpenWindowUi::OnTabSwitcherNeedsThumbnails(
    const std::vector<ItemID>& tab_ids) {
  OpenTabBridge* bridge = service()->tab_bridge();
  if (!bridge || !switcher_) {
    return;
  }
  const gfx::Size thumb_size = OpenTabSwitcherView::ThumbnailSize();
  for (const ItemID& id : tab_ids) {
    content::WebContents* wc = bridge->WebContentsForTab(id);
    if (!wc) {
      continue;  // Never wake sleeping tabs just for a thumbnail.
    }
    content::RenderWidgetHostView* rwhv = wc->GetRenderWidgetHostView();
    if (!rwhv || !rwhv->IsSurfaceAvailableForCopy()) {
      continue;
    }
    rwhv->CopyFromSurface(
        gfx::Rect(), thumb_size, kThumbnailCopyTimeout,
        base::BindPostTaskToCurrentDefault(base::BindOnce(
            &OpenWindowUi::OnTabThumbnailCaptured, weak_factory_.GetWeakPtr(),
            id)));
  }
}

void OpenWindowUi::OnTabThumbnailCaptured(
    ItemID tab_id,
    const content::CopyFromSurfaceResult& result) {
  if (!switcher_ || !switcher_->is_active() || !result.has_value() ||
      result->bitmap.drawsNothing()) {
    return;
  }
  switcher_->UpdateThumbnail(
      tab_id, gfx::ImageSkia::CreateFrom1xBitmap(result->bitmap));
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
  const bool release = key.type() == ui::EventType::kKeyReleased;
  const bool early_escape = key.type() == ui::EventType::kKeyPressed &&
                            key.key_code() == ui::VKEY_ESCAPE &&
                            !switcher_->is_shown();
  if (release || early_escape) {
    switcher_->HandleKeyEvent(key);
  }
}

void OpenWindowUi::StopSwitcherMonitor() {
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
    RestackVisibleOverlays();
  } else {
    switcher_host_->Hide();
  }
}

void OpenWindowUi::OnTabSwitcherCommit(const ItemID& tab_id) {
  StopSwitcherMonitor();
  if (OpenTabBridge* bridge = service()->tab_bridge()) {
    bridge->SelectNode(tab_id, window_id_);
  }
  FocusPage();
}

void OpenWindowUi::OnTabSwitcherCancel() {
  StopSwitcherMonitor();
  FocusPage();
}

// --- Dynamic Window Accelerators ---------------------------------------------

void OpenWindowUi::RegisterAccelerators() {
  views::FocusManager* focus_manager = browser_view_->GetFocusManager();
  if (!focus_manager) {
    return;
  }
  focus_manager->UnregisterAccelerators(this);
  accelerator_commands_.clear();
  escape_priority_ = EscapePriority::kNone;
  const CommandRegistry& commands = service()->commands();
  for (const CommandDefinition* def : commands.WindowAcceleratorCommands()) {
    if (!def || def->is_reserved) {
      continue;
    }
    for (const KeyboardShortcut& shortcut :
         commands.EffectiveShortcuts(def->command_id)) {
      std::optional<ui::Accelerator> accelerator = ToAccelerator(shortcut);
      if (!accelerator || accelerator_commands_.contains(*accelerator) ||
          (accelerator->key_code() == ui::VKEY_ESCAPE &&
           accelerator->modifiers() == ui::EF_NONE)) {
        continue;
      }
      accelerator_commands_.emplace(*accelerator, def->command_id);
      focus_manager->RegisterAccelerator(
          *accelerator, ui::AcceleratorManager::kHighPriority, this);
    }
  }
  UpdateEscapeRegistration();
}

void OpenWindowUi::SetEscapePriority(EscapePriority priority) {
  views::FocusManager* focus_manager = browser_view_->GetFocusManager();
  if (!focus_manager || priority == escape_priority_) {
    return;
  }
  const ui::Accelerator escape(ui::VKEY_ESCAPE, ui::EF_NONE);
  if (escape_priority_ != EscapePriority::kNone) {
    focus_manager->UnregisterAccelerator(escape, this);
  }
  if (priority == EscapePriority::kHigh) {
    focus_manager->RegisterAccelerator(
        escape, ui::AcceleratorManager::kHighPriority, this);
  } else if (priority == EscapePriority::kNormal) {
    focus_manager->RegisterAccelerator(
        escape, ui::AcceleratorManager::kNormalPriority, this);
  }
  escape_priority_ = priority;
}

void OpenWindowUi::UpdateEscapeRegistration() {
  if (command_bar_shown() || peek_shown() || boost_editor_shown() ||
      find_bar_shown()) {
    SetEscapePriority(EscapePriority::kHigh);
  } else if (library_drawer_shown()) {
    // Normal priority lets the Library WebUI consume Escape first for layered
    // menus/dialogs/search, while unhandled Escape or Escape sent to the main
    // window dismisses the drawer cleanly.
    SetEscapePriority(EscapePriority::kNormal);
  } else {
    SetEscapePriority(EscapePriority::kNone);
  }
}

bool OpenWindowUi::RunShortcut(CommandId command) {
  switch (command) {
    case CommandId::kFind:
      if (!FindHelper()) {
        return false;
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
    case CommandId::kArchiveTab:
      if (command_bar_shown()) {
        HideCommandBar();
        return true;
      }
      if (peek_shown()) {
        ClosePeek();
        return true;
      }
      // On an empty Space, consume Ctrl/Cmd+W as a no-op instead of falling
      // through to Chromium's IDC_CLOSE_TAB (which would close the window).
      if (!ActiveWebContents()) {
        return true;
      }
      return RunCommandId(command);
    case CommandId::kCopyUrl:
    case CommandId::kCopyUrlMarkdown:
    case CommandId::kCopyUrlQuote:
    case CommandId::kPinUnpinTab:
    case CommandId::kAddSplitView:
    case CommandId::kClearCacheAndRefresh:
    case CommandId::kClearCookiesAndRefresh:
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
  // Never stomp active IME composition in overlays or inline sidebar rename
  // fields (both Escape and single-chord accelerators).
  if (find_bar_shown() && find_bar_ && find_bar_->HasCompositionText()) {
    return false;
  }
  if (command_bar_shown() && command_bar_->HasCompositionText()) {
    return false;
  }
  if (views::FocusManager* focus_manager =
          browser_view_ ? browser_view_->GetFocusManager() : nullptr) {
    if (auto* textfield =
            views::AsViewClass<views::Textfield>(focus_manager->GetFocusedView());
        textfield && textfield->HasCompositionText()) {
      return false;
    }
  }

  if (accelerator.key_code() == ui::VKEY_ESCAPE &&
      accelerator.modifiers() == ui::EF_NONE &&
      escape_priority_ != EscapePriority::kNone) {
    if (command_bar_shown()) {
      if (command_bar_->HandleEscape()) {
        return true;
      }
      command_bar_->Dismiss(CommandBarDismissReason::kEscape);
      return true;
    }
    if (peek_shown()) {
      OnPeekDismissed(PeekDismissReason::kEscape);
      return true;
    }
    if (library_drawer_shown()) {
      HideLibraryDrawer();
      return true;
    }
    if (boost_editor_shown()) {
      CloseBoostEditor();
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

// --- Overlay page delegate (Peek & Library drawer) ---------------------------

bool OpenWindowUi::HandleKeyboardEvent(
    content::WebContents* source,
    const input::NativeWebKeyboardEvent& event) {
  views::FocusManager* focus_manager =
      browser_view_ ? browser_view_->GetFocusManager() : nullptr;
  return focus_manager && unhandled_keyboard_event_handler_.HandleKeyboardEvent(
                              event, focus_manager);
}

content::JavaScriptDialogManager* OpenWindowUi::GetJavaScriptDialogManager(
    content::WebContents* source) {
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
  return peek_shown() && web_contents == PeekWebContents();
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
  state.Set("card", RectToList(card));
  return state;
}

base::DictValue OpenWindowUi::PeekState() const {
  base::DictValue state;
  state.Set("shown", peek_shown());
  if (content::WebContents* wc = PeekWebContents()) {
    state.Set("url", wc->GetVisibleURL().spec());
    state.Set("loading", wc->IsLoading());
  }
  if (peek_source_) {
    state.Set("source", *peek_source_);
  }
  if (peek_) {
    state.Set("stack_depth", static_cast<int>(peek_->stack_depth()));
    state.Set("card", RectToList(peek_->card_bounds()));
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
    state.Set("matches", find_bar_->has_result() ? find_bar_->total() : -1);
    state.Set("active", find_bar_->active_ordinal());
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
  if (remote_suggest_request_id_ != 0) {
    service()->suggest().CancelRemoteSuggestions(remote_suggest_request_id_);
    remote_suggest_request_id_ = 0;
  }
  DetachExtensionWindow();
  downloads_popover_.reset();
  Observe(nullptr);
  for (web_modal::ModalDialogHostObserver& observer : modal_observers_) {
    observer.OnHostDestroying();
  }
  if (contents_) {
    if (auto* modal =
            web_modal::WebContentsModalDialogManager::FromWebContents(
                contents_)) {
      modal->SetDelegate(nullptr);
    }
    contents_->SetDelegate(nullptr);
    contents_ = nullptr;
  }
  bar_ = nullptr;
  // OpenLittleOpenView owns the WebContents; resetting window_ destroys both
  // the widget/WebView and any remaining owned WebContents in safe order.
  window_.reset();
}

OpenBrowserService* OpenLittleOpenController::service() const {
  return owner_->service();
}

OpenExtensionBridge* OpenLittleOpenController::ExtensionBridge() const {
  if (ProfileServices* ps = service()->ProfileServicesFor(profile_id_);
      ps && ps->extensions) {
    return ps->extensions.get();
  }
  return service()->extension_bridge();
}

ExtensionHostWindow OpenLittleOpenController::MakeExtensionHostWindow() const {
  ExtensionHostWindow host;
  if (OpenTabBridge* tabs = service()->tab_bridge()) {
    host.browser = tabs->MainBrowser();
  }
  host.widget = window_ ? window_->widget() : nullptr;
  host.active_contents = base::BindRepeating(
      [](base::WeakPtr<const OpenLittleOpenController> self)
          -> content::WebContents* {
        return self ? self->contents_.get() : nullptr;
      },
      weak_factory_.GetWeakPtr());
  return host;
}

void OpenLittleOpenController::AttachExtensionWindow() {
  if (extension_window_attached_ || !window_ || !window_->widget()) {
    return;
  }
  OpenExtensionBridge* ext = ExtensionBridge();
  ExtensionHostWindow host = MakeExtensionHostWindow();
  if (!ext || !host.browser) {
    return;
  }
  ext->AttachWindow(host);
  extension_window_attached_ = true;
}

void OpenLittleOpenController::DetachExtensionWindow() {
  if (!extension_window_attached_) {
    return;
  }
  extension_window_attached_ = false;
  if (OpenExtensionBridge* ext = ExtensionBridge();
      ext && window_ && window_->widget()) {
    ext->DetachWindow(window_->widget());
  }
}

gfx::Rect OpenLittleOpenController::WorkArea() const {
  display::Screen* screen = display::Screen::Get();
  if (!screen) {
    return gfx::Rect(0, 0, 1280, 800);
  }
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
  bar->SetFaviconLookup(base::BindRepeating(
      [](base::WeakPtr<OpenLittleOpenController> self, const GURL& u) {
        return self ? self->owner_->GetFaviconForUrl(u) : gfx::ImageSkia();
      },
      weak_factory_.GetWeakPtr()));
  bar_ = bar.get();
  window_->view()->SetBarContents(std::move(bar));
  AttachExtensionWindow();
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
  if (!url.is_valid() || !window_ || !window_->view() || closing_) {
    return;
  }
  if (!contents_) {
    ::Profile* profile = service()->ChromeProfileFor(profile_id_);
    if (!profile) {
      return;
    }
    std::unique_ptr<content::WebContents> wc = content::WebContents::Create(
        content::WebContents::CreateParams(profile));
    AttachOverlayPageHelpers(wc.get());
    wc->SetDelegate(this);
    if (auto* modal = web_modal::WebContentsModalDialogManager::FromWebContents(
            wc.get())) {
      modal->SetDelegate(this);
    }
    Observe(wc.get());
    contents_ = wc.get();
    window_->view()->SetOwnedWebContents(std::move(wc));
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
    const gfx::Rect page = widget->GetWindowBoundsInScreen();
    page_bounds_ = page;
    const gfx::Size bar = little_open_metrics::kBarSize;
    widget->SetBounds(gfx::Rect(page.right() - bar.width(), page.y(),
                                bar.width(), bar.height()));
  }
  view->SetMode(OpenLittleOpenView::Mode::kBar);
  CommandBarRequest request;
  request.mode = CommandBarMode::kLittleOpen;
  request.initial_text = initial_text;
  request.appearance.dark = owner_->IsSystemDarkMode();
  request.allows_remote_suggestions = ProfileAllowsRemoteSuggest(
      service(), profile_id_, /*is_incognito=*/false);
  bar_->Present(request);
}

void OpenLittleOpenController::EnterPageMode() {
  if (!window_ || closing_) {
    return;
  }
  OpenLittleOpenView* view = window_->view();
  views::Widget* widget = window_->widget();
  if (view->mode() == OpenLittleOpenView::Mode::kBar) {
    widget->SetBounds(
        page_bounds_.value_or(OpenLittleOpenView::PageBoundsFromBar(
            widget->GetWindowBoundsInScreen(), WorkArea())));
    page_bounds_.reset();
  }
  view->SetMode(OpenLittleOpenView::Mode::kPage);
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
  DetachExtensionWindow();
  downloads_popover_.reset();
  if (window_ && window_->widget()) {
    window_->widget()->Close();
    return;
  }
  base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce(&OpenLittleOpenController::OnLittleOpenClosed,
                                weak_factory_.GetWeakPtr()));
}

void OpenLittleOpenController::RefreshState() {
  UpdateState();
  if (downloads_popover_ && downloads_popover_->IsShowing()) {
    if (OpenDownloadBridge* downloads = service()->download_bridge()) {
      downloads_popover_->UpdateDownloads(downloads->GetRecentDownloads(
          profile_id_, popover_metrics::kDownloadsMaxRows));
    }
  }
}

std::optional<SpaceID> OpenLittleOpenController::DefaultTargetSpace() const {
  const BrowserModel& model = service()->model();
  if (target_space_) {
    if (const Space* sp = model.FindSpace(*target_space_);
        sp && sp->profile_id == profile_id_) {
      return target_space_;
    }
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
  state.active_profile_id = profile_id_;
  if (contents_) {
    state.host = base::UTF8ToUTF16(HostWithoutWww(contents_->GetVisibleURL()));
  }
  if (const Profile* profile = model.FindProfile(profile_id_)) {
    state.profile_name = base::UTF8ToUTF16(profile->name);
    state.profile_icon = profile->icon;
  }
  state.show_profile = model.profiles().size() > 1;
  for (const Profile& p : model.profiles()) {
    LittleOpenProfileChoice pc;
    pc.id = p.id;
    pc.name = base::UTF8ToUTF16(p.name);
    pc.icon = p.icon;
    pc.active = (p.id == profile_id_);
    state.profiles.push_back(std::move(pc));
  }

  const std::optional<SpaceID> target = DefaultTargetSpace();
  state.target_space_id = target;
  if (target) {
    if (const Space* space = model.FindSpace(*target)) {
      state.space_title = SpaceTitle(*space);
      state.target_space_color = SpacePrimaryColor(*space);
      state.target_space_icon = space->icon;
    }
  }
  for (const Space& space : model.spaces()) {
    if (space.profile_id != profile_id_) {
      continue;
    }
    LittleOpenSpaceChoice choice;
    choice.id = space.id;
    choice.title = SpaceTitle(space);
    choice.icon = space.icon;
    choice.color = SpacePrimaryColor(space);
    choice.profile_id = space.profile_id;
    choice.is_target = (target && *target == space.id);
    state.spaces.push_back(std::move(choice));
  }

  if (OpenDownloadBridge* downloads = service()->download_bridge()) {
    const DownloadProgressSummary summary =
        downloads->GetAggregateProgress(profile_id_);
    state.active_download_count = summary.active_count;
    state.downloads_running = summary.active_count > 0;
    state.show_downloads =
        state.downloads_running ||
        !downloads->GetRecentDownloads(profile_id_, 1).empty();
    if (summary.active_count > 0 && !summary.indeterminate) {
      state.download_progress = std::clamp(summary.progress, 0.0, 1.0);
    }
  }

  if (OpenExtensionBridge* ext = ExtensionBridge()) {
    const ExtensionHostWindow host = MakeExtensionHostWindow();
    const std::vector<ExtensionActionInfo> all =
        host.browser ? ext->GetAllToolbarActions(host, /*include_unpinned=*/true)
                     : ext->ListActions();
    state.show_extensions = !all.empty();
    for (const ExtensionActionInfo& info : all) {
      if (!info.pinned) {
        continue;
      }
      LittleOpenExtensionAction act;
      act.id = info.id;
      act.name = base::UTF8ToUTF16(info.name);
      act.icon =
          !info.icon_with_badge.isNull() ? info.icon_with_badge : info.icon;
      act.badge_text = base::UTF8ToUTF16(info.badge_text);
      act.enabled = info.enabled && info.runnable;
      state.extension_actions.push_back(std::move(act));
    }
  }
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

// --- LittleOpenDelegate (Zero-Reload Transfer & Wave E4) ---------------------

void OpenLittleOpenController::OnLittleOpenOpenInSpace(
    std::optional<SpaceID> space_id) {
  const std::optional<SpaceID> target =
      space_id ? space_id : DefaultTargetSpace();
  OpenWindowController* owner = owner_;
  OpenTabBridge* bridge = service()->tab_bridge();
  std::unique_ptr<content::WebContents> wc;
  if (window_ && window_->view()) {
    wc = window_->view()->ReleaseWebContents();
  }
  Observe(nullptr);
  contents_ = nullptr;
  if (wc) {
    if (auto* modal =
            web_modal::WebContentsModalDialogManager::FromWebContents(
                wc.get())) {
      modal->SetDelegate(nullptr);
    }
    wc->SetDelegate(nullptr);
  }
  Close();
  if (!wc || !bridge) {
    return;
  }
  if (target) {
    bridge->FocusSpace(*target);
    bridge->AdoptLiveWebContentsAsTab(std::move(wc), *target,
                                      /*background=*/false);
  } else if (std::optional<SpaceID> focused = model_util::FocusedSpace(
                 owner->service()->model(), owner->service()->MainWindowId())) {
    bridge->AdoptLiveWebContentsAsTab(std::move(wc), *focused,
                                      /*background=*/false);
  }
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
  // Handled by OpenLittleOpenView's built-in ProfilePickerView ->
  // OnLittleOpenProfileSelected.
}

void OpenLittleOpenController::OnLittleOpenProfileSelected(
    const ProfileID& new_profile_id) {
  if (new_profile_id.empty() || new_profile_id == profile_id_ || closing_) {
    return;
  }
  std::optional<GURL> current_url;
  if (contents_) {
    const GURL u = contents_->GetLastCommittedURL().is_valid()
                       ? contents_->GetLastCommittedURL()
                       : contents_->GetVisibleURL();
    if (u.is_valid()) {
      current_url = u;
    }
  }
  if (window_ && window_->view()) {
    // Switching profiles reopens the page; do not archive as a dismissed page.
    window_->view()->MarkPromoted();
  }
  OpenWindowController* owner = owner_;
  Close();
  owner->OpenLittleOpen(current_url, new_profile_id);
}

void OpenLittleOpenController::OnLittleOpenTargetSpaceChanged(
    const SpaceID& space_id) {
  if (space_id.empty()) {
    return;
  }
  target_space_ = space_id;
  UpdateState();
}

void OpenLittleOpenController::OnLittleOpenDownloads(views::View* anchor) {
  if (!anchor || closing_) {
    return;
  }
  if (!downloads_popover_) {
    downloads_popover_ = std::make_unique<OpenDownloadsPopover>(
        base::BindRepeating(&OpenLittleOpenController::HandleDownloadPopoverAction,
                            weak_factory_.GetWeakPtr()));
  }
  if (downloads_popover_->IsShowing()) {
    downloads_popover_->Close();
    return;
  }
  OpenDownloadBridge* downloads = service()->download_bridge();
  if (downloads) {
    downloads->SyncLiveDownloadsFromManagers();
  }
  std::vector<RecentDownloadEntry> entries =
      downloads
          ? downloads->GetRecentDownloads(profile_id_,
                                          popover_metrics::kDownloadsMaxRows)
          : std::vector<RecentDownloadEntry>();
  downloads_popover_->Show(anchor, std::move(entries),
                           OpenPopoverColors::ToolbarMore(/*dark=*/true));
}

void OpenLittleOpenController::HandleDownloadPopoverAction(
    DownloadPopoverAction action,
    const std::string& download_id) {
  OpenDownloadBridge* downloads = service()->download_bridge();
  switch (action) {
    case DownloadPopoverAction::kOpen:
      if (downloads) {
        downloads->OpenFile(download_id);
      }
      return;
    case DownloadPopoverAction::kReveal:
      if (downloads) {
        downloads->RevealInFolder(download_id);
      }
      return;
    case DownloadPopoverAction::kPause:
      if (downloads) {
        downloads->Pause(download_id);
      }
      return;
    case DownloadPopoverAction::kResume:
      if (downloads) {
        downloads->Resume(download_id);
      }
      return;
    case DownloadPopoverAction::kCancel:
      if (downloads) {
        downloads->Cancel(download_id);
      }
      return;
    case DownloadPopoverAction::kRetry:
      if (downloads) {
        downloads->Retry(download_id);
      }
      return;
    case DownloadPopoverAction::kCopyLink:
      if (downloads) {
        for (const RecentDownloadEntry& e :
             downloads->GetRecentDownloads(profile_id_, 50)) {
          if (e.record.id == download_id && !e.record.url.empty()) {
            ui::ScopedClipboardWriter(ui::ClipboardBuffer::kCopyPaste)
                .WriteText(base::UTF8ToUTF16(e.record.url));
            break;
          }
        }
      }
      return;
    case DownloadPopoverAction::kRemove:
      if (downloads) {
        downloads->RemoveFromHistory(download_id);
      }
      return;
    case DownloadPopoverAction::kViewAllDownloads:
      if (OpenWindowUi* ui = owner_->MainWindowUi()) {
        ui->ActivateWindow();
        ui->ShowLibraryDrawer("downloads");
      }
      return;
    case DownloadPopoverAction::kClearCompleted:
      if (downloads) {
        downloads->ClearHistory(profile_id_);
      }
      return;
  }
}

void OpenLittleOpenController::OnLittleOpenExtensionAction(
    const std::string& extension_id,
    views::View* anchor) {
  if (OpenExtensionBridge* ext = ExtensionBridge()) {
    const ExtensionHostWindow host = MakeExtensionHostWindow();
    if (host.browser) {
      ext->ExecuteAction(host, extension_id, anchor, std::nullopt,
                         base::DoNothing());
    }
  }
}

void OpenLittleOpenController::OnLittleOpenExtensions(views::View* anchor) {
  OpenExtensionBridge* ext = ExtensionBridge();
  const ExtensionHostWindow host = MakeExtensionHostWindow();
  if (!ext || !host.browser) {
    return;
  }
  OpenExtensionBridge::PickerCallbacks cb;
  cb.dark = true;
  cb.on_manage_extensions = base::BindRepeating(
      [](base::WeakPtr<OpenLittleOpenController> self) {
        if (self) {
          if (OpenWindowUi* ui = self->owner_->MainWindowUi()) {
            ui->ActivateWindow();
            ui->HandleCommand(CommandId::kManageExtensions);
          }
        }
      },
      weak_factory_.GetWeakPtr());
  cb.on_add_extension = base::BindRepeating(
      [](base::WeakPtr<OpenLittleOpenController> self) {
        if (self) {
          if (OpenWindowUi* ui = self->owner_->MainWindowUi()) {
            ui->ActivateWindow();
            ui->HandleCommand(CommandId::kAddExtension);
          }
        }
      },
      weak_factory_.GetWeakPtr());
  ext->ShowExtensionsPicker(host, anchor, cb);
}

void OpenLittleOpenController::OnLittleOpenArchiveOnClose(
    const GURL& url,
    const std::u16string& title,
    const ProfileID& profile_id) {
  if (!url.is_valid() || !url.SchemeIsHTTPOrHTTPS()) {
    return;
  }
  const ProfileID pid = profile_id.empty() ? profile_id_ : profile_id;
  ProfileServices* ps = service()->ProfileServicesFor(pid);
  if (!ps) {
    return;
  }
  ArchivedTabRecord record;
  record.id = base::Uuid::GenerateRandomV4().AsLowercaseString();
  record.url = url.spec();
  record.title = title.empty() ? url.spec() : base::UTF16ToUTF8(title);
  record.space_id = DefaultTargetSpace();
  record.profile_id = pid;
  record.archived_at = base::Time::Now().InSecondsFSinceUnixEpoch();
  record.reason = "closed";
  record.original_location = "little-open";
  record.kind = "tab";
  RunOnStore(ps->archive,
             base::BindOnce(
                 [](ArchivedTabRecord rec, ArchiveStore* store) {
                   store->Archive(rec);
                 },
                 std::move(record)));
}

void OpenLittleOpenController::OnLittleOpenClosed() {
  closing_ = true;
  owner_->OnLittleOpenClosed(this);  // Deletes this object.
}

// --- CommandBarDelegate (Little Open's bar) ----------------------------------

CommandBarResults OpenLittleOpenController::QuerySuggestions(
    const CommandBarQuery& query) {
  return QueryCommandBar(service(), query, profile_id_, DefaultTargetSpace(),
                         /*current_tab=*/std::nullopt, /*is_incognito=*/false);
}

void OpenLittleOpenController::OnCommandBarRemoteQuery(
    const CommandBarQuery& query) {
  OpenBrowserService* s = service();
  if (remote_suggest_request_id_ != 0) {
    s->suggest().CancelRemoteSuggestions(remote_suggest_request_id_);
    remote_suggest_request_id_ = 0;
  }
  const SuggestContext context = BuildSuggestContext(
      s, query, profile_id_, DefaultTargetSpace(),
      /*current_tab=*/std::nullopt, /*is_incognito=*/false);
  scoped_refptr<network::SharedURLLoaderFactory> factory =
      URLLoaderFactoryForProfile(s, profile_id_);
  if (!factory) {
    return;
  }
  const uint64_t generation = query.generation;
  remote_suggest_request_id_ = s->suggest().FetchRemoteSuggestions(
      base::UTF16ToUTF8(query.text), context, std::move(factory),
      base::BindOnce(
          [](base::WeakPtr<OpenLittleOpenController> self, uint64_t gen,
             RemoteSuggestionResult result) {
            if (!self || !self->bar_ || self->closing_) {
              return;
            }
            self->remote_suggest_request_id_ = 0;
            self->bar_->UpdateRemoteRows(
                gen, CommandBarRowsFromSuggestions(result.suggestions));
          },
          weak_factory_.GetWeakPtr(), generation));
}

void OpenLittleOpenController::OnCommandBarOpenSearchSettings() {
  owner_->OpenSettingsWindow("search");
}

std::optional<CommandBarScopeTarget>
OpenLittleOpenController::ResolveSiteSearch(std::u16string_view text,
                                            bool exact_keyword_only) {
  return ResolveSiteSearchFor(service(), profile_id_, text, exact_keyword_only);
}

void OpenLittleOpenController::OnCommandBarIntent(
    const CommandBarIntent& intent) {
  const CommandBarRow& row = intent.row;
  switch (row.kind) {
    case CommandBarRowKind::kSwitchToTab:
    case CommandBarRowKind::kSwitchToSplit:
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
  Navigate(UrlForCommandBarIntent(service(), profile_id_, intent));
}

void OpenLittleOpenController::OnCommandBarDismissed(
    CommandBarDismissReason reason,
    std::optional<gfx::Point> click_location) {
  if (remote_suggest_request_id_ != 0) {
    service()->suggest().CancelRemoteSuggestions(remote_suggest_request_id_);
    remote_suggest_request_id_ = 0;
  }
  switch (reason) {
    case CommandBarDismissReason::kCommitted:
    case CommandBarDismissReason::kProgrammatic:
      return;
    case CommandBarDismissReason::kCloseButton:
      Close();
      return;
    case CommandBarDismissReason::kEscape:
    case CommandBarDismissReason::kClickOutside:
      if (contents_) {
        EnterPageMode();
      } else {
        Close();
      }
      return;
  }
}

// --- content::WebContentsObserver --------------------------------------------

void OpenLittleOpenController::DidFinishNavigation(
    content::NavigationHandle* navigation_handle) {
  if (!navigation_handle->IsInPrimaryMainFrame() ||
      !navigation_handle->HasCommitted()) {
    return;
  }
  UpdateState();
  const GURL& url = navigation_handle->GetURL();
  if (navigation_handle->IsSameDocument() || navigation_handle->IsErrorPage() ||
      !url.SchemeIsHTTPOrHTTPS() || !contents_ ||
      contents_->GetBrowserContext()->IsOffTheRecord()) {
    return;
  }
  service()->RecordVisit(profile_id_, url.spec(),
                         base::UTF16ToUTF8(contents_->GetTitle()),
                         /*typed=*/false);
}

void OpenLittleOpenController::WebContentsDestroyed() {
  contents_ = nullptr;
}

// --- Page delegate and web-modal host ----------------------------------------

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
