// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "open_unified/browser/open_chromium_hooks.h"

#include <algorithm>
#include <array>
#include <unordered_map>
#include <utility>

#include "base/auto_reset.h"
#include "base/functional/bind.h"
#include "base/functional/callback_helpers.h"
#include "base/strings/string_split.h"
#include "base/strings/string_util.h"
#include "base/strings/utf_string_conversions.h"
#include "build/build_config.h"
#include "chrome/app/chrome_command_ids.h"
#include "chrome/browser/chrome_browser_main.h"
#include "chrome/browser/chrome_content_browser_client.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/ui/browser_commands.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/tab_helpers.h"
#include "chrome/browser/ui/views/frame/browser_view.h"
#include "content/public/browser/browser_thread.h"
#include "content/public/browser/context_menu_params.h"
#include "content/public/browser/page_navigator.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/render_process_host.h"
#include "content/public/browser/web_contents.h"
#include "open/adblock/open_adblock_hooks.h"
#include "open/adblock/open_adblock_socket_hooks.h"
#include "open_unified/browser/open_browser_main_extra_parts.h"
#include "open_unified/browser/open_browser_service.h"
#include "open_unified/browser/open_sleep_controller.h"
#include "open_unified/browser/open_window_controller.h"
#include "open_unified/core/adblock/open_adblock_profile_service.h"
#include "open_unified/core/commands/command_registry.h"
#include "open_unified/ui/views/open_browser_view.h"
#include "open_unified/ui/webui/open_webui_config.h"
#include "third_party/blink/public/mojom/context_menu/context_menu.mojom.h"
#include "ui/base/clipboard/scoped_clipboard_writer.h"
#include "ui/base/hit_test.h"
#include "ui/gfx/geometry/point.h"
#include "ui/menus/simple_menu_model.h"
#include "ui/views/view_utils.h"
#include "url/gurl.h"

namespace open_unified::hooks {

OpenMenuItemSpec::OpenMenuItemSpec() = default;
OpenMenuItemSpec::OpenMenuItemSpec(const OpenMenuItemSpec&) = default;
OpenMenuItemSpec::OpenMenuItemSpec(OpenMenuItemSpec&&) noexcept = default;
OpenMenuItemSpec& OpenMenuItemSpec::operator=(const OpenMenuItemSpec&) =
    default;
OpenMenuItemSpec& OpenMenuItemSpec::operator=(OpenMenuItemSpec&&) noexcept =
    default;
OpenMenuItemSpec::~OpenMenuItemSpec() = default;

namespace {

// UI thread only. Set while Open re-enters Chrome's own socket path, so the
// nested call takes Chrome's original branch.
bool g_socket_passthrough = false;

// UI thread only. Set while Open delegates an Open menu command (such as Save
// Page As…) back into Chromium's native IDC_* execution path.
bool g_command_passthrough = false;

// Optional UI-layer delegate registered by Wave B.
OpenHookDelegate* g_hook_delegate = nullptr;

open_engine::OpenAdBlockService* AdBlockServiceFor(
    content::BrowserContext* context) {
  if (!context || context->ShutdownStarted()) {
    return nullptr;
  }
  auto* profile_service =
      OpenAdBlockProfileService::GetForBrowserContext(context);
  return profile_service ? profile_service->service() : nullptr;
}

open_engine::OpenAdBlockService* AdBlockServiceFor(
    content::RenderFrameHost* frame) {
  return frame ? AdBlockServiceFor(frame->GetBrowserContext()) : nullptr;
}

bool IsOpenBrowserWindow(BrowserView* browser_view) {
  return browser_view && browser_view->browser() &&
         browser_view->browser()->GetType() ==
             BrowserWindowInterface::Type::TYPE_NORMAL;
}

OpenWindowUi* WindowUiForBrowser(BrowserWindowInterface* browser) {
  OpenBrowserService* service = OpenBrowserService::Get();
  OpenWindowController* windows =
      service ? service->window_controller() : nullptr;
  if (!windows) {
    return nullptr;
  }
  if (browser) {
    if (BrowserView* browser_view =
            BrowserView::GetBrowserViewForBrowser(browser)) {
      if (OpenWindowUi* ui = windows->WindowUiForBrowserView(browser_view)) {
        return ui;
      }
    }
  }
  return windows->MainWindowUi();
}

int MenuTagForCommandId(CommandId cid) {
  if (cid == CommandId::kUnknown || cid >= CommandId::kCommandIdCount) {
    return 0;
  }
  return kOpenMenuCommandIdBase + static_cast<int>(cid);
}

std::optional<CommandId> CommandIdFromMenuTag(int command_id) {
  if (!IsOpenMenuCommand(command_id)) {
    return std::nullopt;
  }
  const int raw = command_id - kOpenMenuCommandIdBase;
  if (raw <= static_cast<int>(CommandId::kUnknown) ||
      raw >= static_cast<int>(CommandId::kCommandIdCount)) {
    return std::nullopt;
  }
  return static_cast<CommandId>(raw);
}

// Maps Chromium IDC_* commands that Open shadows into Open CommandId values.
std::optional<CommandId> MapChromiumCommandToOpen(int command_id) {
  if (auto open_cmd = CommandIdFromMenuTag(command_id)) {
    return open_cmd;
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
      // Cmd+S toggles Open's sidebar; Save Page As… uses Open's kSavePageAs
      // tag (Cmd+Shift+S).
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
    case IDC_DEV_TOOLS_TOGGLE:
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

// Native AppKit responder selectors matching SystemCommandActions in
// MenuBuilder.swift.
struct NativeMenuAction {
  const char* selector;
  int tag = 0;
  bool target_app_delegate = false;
  bool target_nsapp = false;
};

std::optional<NativeMenuAction> NativeActionForCommand(std::string_view id) {
  static const std::unordered_map<std::string_view, NativeMenuAction> kMap = {
      {"about-open",
       {"orderFrontStandardAboutPanel:", IDC_ABOUT, true, false}},
      {"quit-open", {"terminate:", IDC_EXIT, false, true}},
      {"hide-open", {"hide:", IDC_HIDE_APP, false, false}},
      {"hide-others", {"hideOtherApplications:", 0, false, false}},
      {"show-all", {"unhideAllApplications:", 0, false, false}},
      {"close-window", {"performClose:", IDC_CLOSE_WINDOW, false, false}},
      {"minimize-window",
       {"performMiniaturize:", IDC_MINIMIZE_WINDOW, false, false}},
      {"zoom-window", {"performZoom:", IDC_MAXIMIZE_WINDOW, false, false}},
      {"bring-all-to-front",
       {"arrangeInFront:", IDC_ALL_WINDOWS_FRONT, false, false}},
      {"toggle-full-screen", {"toggleFullScreen:", IDC_FULLSCREEN, false, false}},
      {"cut", {"cut:", IDC_CONTENT_CONTEXT_CUT, false, false}},
      {"copy", {"copy:", IDC_CONTENT_CONTEXT_COPY, false, false}},
      {"paste", {"paste:", IDC_CONTENT_CONTEXT_PASTE, false, false}},
      {"paste-and-match-style",
       {"pasteAndMatchStyle:", IDC_CONTENT_CONTEXT_PASTE_AND_MATCH_STYLE, false,
        false}},
      {"delete", {"delete:", IDC_CONTENT_CONTEXT_DELETE, false, false}},
      {"select-all", {"selectAll:", IDC_CONTENT_CONTEXT_SELECTALL, false, false}},
      {"undo", {"undo:", IDC_CONTENT_CONTEXT_UNDO, false, false}},
      {"redo", {"redo:", IDC_CONTENT_CONTEXT_REDO, false, false}},
      {"use-selection-to-find", {"copyToFindPboard:", 7, false, false}},
      {"jump-to-selection", {"centerSelectionInVisibleArea:", 0, false, false}},
      {"show-spelling", {"showGuessPanel:", 0, false, false}},
      {"check-spelling", {"checkSpelling:", 0, false, false}},
      {"check-spelling-while-typing",
       {"toggleContinuousSpellChecking:", 0, false, false}},
      {"check-grammar", {"toggleGrammarChecking:", 0, false, false}},
      {"correct-spelling-automatically",
       {"toggleAutomaticSpellingCorrection:", 0, false, false}},
      {"show-substitutions",
       {"orderFrontSubstitutionsPanel:", 0, false, false}},
      {"smart-copy-paste", {"toggleSmartInsertDelete:", 0, false, false}},
      {"smart-quotes", {"toggleAutomaticQuoteSubstitution:", 0, false, false}},
      {"smart-dashes", {"toggleAutomaticDashSubstitution:", 0, false, false}},
      {"smart-links", {"toggleAutomaticLinkDetection:", 0, false, false}},
      {"text-replacement",
       {"toggleAutomaticTextReplacement:", 0, false, false}},
      {"data-detectors", {"toggleAutomaticDataDetection:", 0, false, false}},
      {"make-upper-case", {"uppercaseWord:", 0, false, false}},
      {"make-lower-case", {"lowercaseWord:", 0, false, false}},
      {"capitalize", {"capitalizeWord:", 0, false, false}},
      {"start-speaking", {"startSpeaking:", 0, false, false}},
      {"stop-speaking", {"stopSpeaking:", 0, false, false}},
      {"show-fonts", {"orderFrontFontPanel:", 0, false, false}},
      {"font-bold", {"addFontTrait:", 2, false, false}},
      {"font-italic", {"addFontTrait:", 1, false, false}},
      {"font-underline", {"underline:", 0, false, false}},
      {"emoji-and-symbols", {"orderFrontCharacterPalette:", 0, false, false}},
  };
  auto it = kMap.find(id);
  if (it == kMap.end()) {
    return std::nullopt;
  }
  return it->second;
}

// Converts a CommandRegistry key token into an AppKit keyEquivalent UTF-8
// string.
std::string MacKeyEquivalentForToken(std::string_view key, bool shift_down) {
  if (key == "space") return " ";
  if (key == "tab") return "\t";
  if (key == "return" || key == "enter") return "\r";
  if (key == "escape" || key == "esc") return "\x1B";
  // AppKit NSF*FunctionKey UTF-8 encodings (U+F700..U+F703, U+F70F).
  if (key == "up") return "\xEF\x9C\x80";
  if (key == "down") return "\xEF\x9C\x81";
  if (key == "left") return "\xEF\x9C\x82";
  if (key == "right") return "\xEF\x9C\x83";
  if (key == "f12") return "\xEF\x9C\x8F";
  if (key.size() == 1) {
    char c = key[0];
    if (shift_down && c >= 'a' && c <= 'z') {
      c = static_cast<char>(c - 'a' + 'A');
    }
    return std::string(1, c);
  }
  return std::string(key);
}

uint32_t MacModifierMaskForShortcut(const KeyboardShortcut& sc) {
  uint32_t mask = kOpenMenuModNone;
  if (sc.modifiers & kModMeta) mask |= kOpenMenuModCommand;
  if (sc.modifiers & kModCtrl) mask |= kOpenMenuModControl;
  if (sc.modifiers & kModAlt) mask |= kOpenMenuModOption;
  if (sc.modifiers & kModShift) mask |= kOpenMenuModShift;
  return mask;
}

// Strips common tracking query parameters for "Copy Clean Link".
GURL CleanLinkUrl(const GURL& url) {
  if (!url.is_valid() || !url.has_query()) {
    return url;
  }
  static constexpr std::array<std::string_view, 20> kTrackingParams = {
      "utm_source",   "utm_medium",   "utm_campaign", "utm_term",
      "utm_content",  "utm_id",       "fbclid",       "gclid",
      "dclid",        "gbraid",       "wbraid",       "msclkid",
      "mc_cid",       "mc_eid",       "igshid",       "si",
      "ref_src",      "ref_url",      "yclid",        "_hsenc",
  };
  std::string_view query = url.query();
  std::vector<std::string> kept;
  bool changed = false;
  for (std::string_view part : base::SplitStringPiece(
           query, "&", base::KEEP_WHITESPACE, base::SPLIT_WANT_NONEMPTY)) {
    size_t eq = part.find('=');
    std::string key =
        base::ToLowerASCII(eq == std::string_view::npos ? part
                                                        : part.substr(0, eq));
    bool is_tracker =
        base::StartsWith(key, "utm_") ||
        std::find(kTrackingParams.begin(), kTrackingParams.end(), key) !=
            kTrackingParams.end();
    if (is_tracker) {
      changed = true;
    } else {
      kept.emplace_back(part);
    }
  }
  if (!changed) {
    return url;
  }
  GURL::Replacements replacements;
  std::string new_query = base::JoinString(kept, "&");
  if (new_query.empty()) {
    replacements.ClearQuery();
  } else {
    replacements.SetQueryStr(new_query);
  }
  return url.ReplaceComponents(replacements);
}

OpenMenuItemSpec MakeSeparator() {
  OpenMenuItemSpec spec;
  spec.kind = OpenMenuItemSpec::Kind::kSeparator;
  return spec;
}

OpenMenuItemSpec MakeSectionHeader(std::string title) {
  OpenMenuItemSpec spec;
  spec.kind = OpenMenuItemSpec::Kind::kSectionHeader;
  spec.title = std::move(title);
  return spec;
}

OpenMenuItemSpec MakeSubmenu(std::string title,
                             std::vector<OpenMenuItemSpec> items,
                             int tag = 0) {
  OpenMenuItemSpec spec;
  spec.kind = OpenMenuItemSpec::Kind::kSubmenu;
  spec.title = std::move(title);
  spec.command_tag = tag;
  spec.submenu = std::move(items);
  return spec;
}

void AppendCommandWithCarriers(const CommandRegistry& registry,
                               std::string_view cmd_id,
                               std::vector<OpenMenuItemSpec>& out,
                               std::optional<std::string> title_override =
                                   std::nullopt) {
  const CommandDefinition* def = registry.FindByStringId(cmd_id);
  if (!def || def->is_reserved) {
    return;
  }
  std::vector<KeyboardShortcut> shortcuts =
      registry.EffectiveShortcuts(def->id);
  std::optional<NativeMenuAction> native = NativeActionForCommand(def->id);

  auto make_entry = [&](const KeyboardShortcut* sc,
                        bool force_hidden) -> OpenMenuItemSpec {
    OpenMenuItemSpec item;
    item.kind = OpenMenuItemSpec::Kind::kItem;
    item.title = title_override.has_value()
                     ? *title_override
                     : (def->menu_title.empty() ? def->title : def->menu_title);
    item.command_id = def->id;
    item.hidden = force_hidden || def->hidden_in_menu;
    if (native.has_value()) {
      item.native_selector = native->selector;
      item.native_tag = native->tag;
      item.command_tag = native->tag;
      item.target_app_delegate = native->target_app_delegate;
      item.target_nsapp = native->target_nsapp;
    } else {
      item.command_tag = MenuTagForCommandId(def->command_id);
    }
    if (sc != nullptr) {
      const bool has_shift = (sc->modifiers & kModShift) != 0;
      item.key_equivalent = MacKeyEquivalentForToken(sc->key, has_shift);
      item.modifier_mask = MacModifierMaskForShortcut(*sc);
    }
    return item;
  };

  out.push_back(make_entry(shortcuts.empty() ? nullptr : &shortcuts[0], false));
  for (size_t i = 1; i < shortcuts.size(); ++i) {
    out.push_back(make_entry(&shortcuts[i], /*force_hidden=*/true));
  }
}

void AppendCommands(const CommandRegistry& registry,
                    std::initializer_list<std::string_view> ids,
                    std::vector<OpenMenuItemSpec>& out) {
  for (std::string_view id : ids) {
    AppendCommandWithCarriers(registry, id, out);
  }
}

}  // namespace

void SetHookDelegate(OpenHookDelegate* delegate) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  g_hook_delegate = delegate;
}

OpenHookDelegate* GetHookDelegate() {
  return g_hook_delegate;
}

// --- 0002 -------------------------------------------------------------------

void OnBrowserViewAddedToWidget(BrowserView* browser_view) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  OpenBrowserService* service = OpenBrowserService::Get();
  if (!service || !IsOpenBrowserWindow(browser_view)) {
    return;
  }
  OpenBrowserView::Install(browser_view, service->view_controller());
  if (OpenWindowController* windows = service->window_controller()) {
    windows->OnBrowserViewInstalled(browser_view);
  }
}

void OnBrowserViewDestroying(BrowserView* browser_view) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (!OpenBrowserView::FromBrowserView(browser_view)) {
    return;
  }
  if (OpenBrowserService* service = OpenBrowserService::Get()) {
    if (OpenWindowController* windows = service->window_controller()) {
      windows->OnBrowserViewDestroying(browser_view);
    }
  }
  OpenBrowserView::Uninstall(browser_view);
}

bool HasOpenBrowserView(BrowserView* browser_view) {
  return browser_view &&
         OpenBrowserView::FromBrowserView(browser_view) != nullptr;
}

bool LayoutOpenBrowserView(views::View* host) {
  auto* browser_view = views::AsViewClass<BrowserView>(host);
  OpenBrowserView* open_view =
      browser_view ? OpenBrowserView::FromBrowserView(browser_view) : nullptr;
  if (!open_view) {
    return false;
  }
  open_view->SetBoundsRect(host->GetLocalBounds());
  return true;
}

void AdjustBrowserWidgetParams(BrowserView* browser_view,
                               views::Widget::InitParams* params) {
  if (!OpenBrowserService::Get() || !IsOpenBrowserWindow(browser_view) ||
      !OpenBrowserView::WantsFramelessWindow()) {
    return;
  }
#if BUILDFLAG(IS_MAC)
  // macOS: keep the titled, full-size-content-view NSWindow Chromium makes,
  // so the native traffic lights (placed by OpenBrowserView through
  // OpenPlatform) and the system shadow, corners and window snapping stay.
  params->remove_standard_frame = false;
#elif BUILDFLAG(IS_WIN)
  // Windows: keep the standard DWM frame. Removing it loses Aero Snap, the
  // native resize borders and Mica (OpenPlatform::ApplyWindowEffects()).
  // Open's chrome covers the client area; OpenBrowserView answers
  // NonClientHitTest() for its draggable regions.
  params->remove_standard_frame = false;
#else
  // Linux: Open draws its own 10 pt themed frame inset and rounded corners
  // (OpenBrowserView) in a frameless translucent window with a drop shadow.
  params->remove_standard_frame = true;
  params->opacity = views::Widget::InitParams::WindowOpacity::kTranslucent;
  params->shadow_type = views::Widget::InitParams::ShadowType::kDrop;
#if BUILDFLAG(IS_LINUX)
  params->wm_class_name = "open-browser";
  params->wm_class_class = "Open";
  params->wayland_app_id = "open-browser";
#endif
#endif
}

std::optional<int> NonClientHitTest(BrowserView* browser_view,
                                    const gfx::Point& point) {
  OpenBrowserView* open_view =
      browser_view ? OpenBrowserView::FromBrowserView(browser_view) : nullptr;
  if (!open_view || !browser_view->parent()) {
    return std::nullopt;
  }
  gfx::Point local(point);
  views::View::ConvertPointToTarget(browser_view->parent(), open_view, &local);
  const int hit = open_view->NonClientHitTest(local);
  if (hit == HTNOWHERE) {
    return std::nullopt;
  }
  return hit;
}

// --- 0003 -------------------------------------------------------------------

void MaybeProxyURLLoaderFactoryForAdBlock(
    content::BrowserContext* browser_context,
    content::RenderFrameHost* frame,
    int render_process_id,
    content::ContentBrowserClient::URLLoaderFactoryType type,
    const url::Origin& request_initiator,
    const net::IsolationInfo& isolation_info,
    network::URLLoaderFactoryBuilder& factory_builder) {
  open_engine::MaybeProxyURLLoaderFactoryForAdBlock(
      AdBlockServiceFor(browser_context), frame, render_process_id, type,
      request_initiator, isolation_info, factory_builder);
}

bool WillInterceptWebSocket(content::RenderFrameHost* frame) {
  if (g_socket_passthrough) {
    return false;
  }
  return open_engine::AdBlockWantsWebSocket(AdBlockServiceFor(frame), frame);
}

bool InterceptCreateWebSocket(
    ChromeContentBrowserClient* client,
    content::RenderFrameHost* frame,
    content::ContentBrowserClient::WebSocketFactory& factory,
    const GURL& url,
    const net::SiteForCookies& site_for_cookies,
    const std::optional<std::string>& user_agent,
    mojo::PendingRemote<network::mojom::WebSocketHandshakeClient>&
        handshake_client,
    content::ContentBrowserClient::WebSocketOptions& options) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (g_socket_passthrough) {
    return false;
  }
  open_engine::OpenAdBlockService* service = AdBlockServiceFor(frame);
  if (!open_engine::AdBlockWantsWebSocket(service, frame)) {
    return false;
  }
  bool chrome_intercepts;
  {
    base::AutoReset<bool> passthrough(&g_socket_passthrough, true);
    chrome_intercepts = client->WillInterceptWebSocket(frame);
  }
  open_engine::AdBlockCreateWebSocket(
      service, frame, chrome_intercepts, std::move(factory), url,
      site_for_cookies, user_agent, std::move(handshake_client),
      std::move(options),
      base::BindOnce(
          [](ChromeContentBrowserClient* client,
             content::RenderFrameHost* frame,
             content::ContentBrowserClient::WebSocketFactory factory,
             const GURL& url, const net::SiteForCookies& site_for_cookies,
             const std::optional<std::string>& user_agent,
             mojo::PendingRemote<network::mojom::WebSocketHandshakeClient>
                 handshake_client,
             content::ContentBrowserClient::WebSocketOptions options) {
            base::AutoReset<bool> passthrough(&g_socket_passthrough, true);
            client->CreateWebSocket(frame, std::move(factory), url,
                                    site_for_cookies, user_agent,
                                    std::move(handshake_client),
                                    std::move(options));
          },
          // The content client lives for the whole browser process.
          base::Unretained(client)));
  return true;
}

bool InterceptWillCreateWebTransport(
    ChromeContentBrowserClient* client,
    int process_id,
    int frame_routing_id,
    const GURL& url,
    const url::Origin& initiator_origin,
    mojo::PendingRemote<network::mojom::WebTransportHandshakeClient>&
        handshake_client,
    content::ContentBrowserClient::WillCreateWebTransportCallback& callback) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (g_socket_passthrough) {
    return false;
  }
  content::RenderFrameHost* frame =
      content::RenderFrameHost::FromID(process_id, frame_routing_id);
  open_engine::OpenAdBlockService* service = AdBlockServiceFor(frame);
  if (!service || !service->IsEnabled()) {
    return false;
  }
  open_engine::AdBlockWillCreateWebTransport(
      service, process_id, frame_routing_id, url, initiator_origin,
      std::move(handshake_client), std::move(callback),
      base::BindOnce(
          [](ChromeContentBrowserClient* client, int process_id,
             int frame_routing_id, const GURL& url,
             const url::Origin& initiator_origin,
             mojo::PendingRemote<network::mojom::WebTransportHandshakeClient>
                 handshake_client,
             content::ContentBrowserClient::WillCreateWebTransportCallback
                 callback) {
            base::AutoReset<bool> passthrough(&g_socket_passthrough, true);
            client->WillCreateWebTransport(
                process_id, frame_routing_id, url, initiator_origin,
                std::move(handshake_client), std::move(callback));
          },
          base::Unretained(client)));
  return true;
}

void ExposeInterfacesToRenderer(
    service_manager::BinderRegistry* registry,
    content::RenderProcessHost* render_process_host) {
  // Track 3's KeyedService binds the cosmetics host (open_adblock.mojom)
  // with its matcher; incognito shares the parent's lists.
  content::BrowserContext* context = render_process_host->GetBrowserContext();
  if (!context || context->ShutdownStarted()) {
    return;
  }
  if (auto* adblock =
          OpenAdBlockProfileService::GetForBrowserContext(context)) {
    adblock->ExposeInterfacesToRenderer(registry);
  }
}

// --- 0005 -------------------------------------------------------------------

void RegisterOpenWebUIConfigs() {
  webui::RegisterOpenWebUIConfigs();
}

void AddOpenURLHandlers(content::BrowserURLHandler* handler) {
  webui::AddOpenURLHandlers(handler);
}

// --- 0006 -------------------------------------------------------------------

bool MayChromeDiscardTab(content::WebContents* web_contents) {
  OpenBrowserService* service = OpenBrowserService::Get();
  if (!service || !service->sleep_controller()) {
    return true;
  }
  return service->sleep_controller()->MayChromeDiscard(web_contents);
}

// --- 0009 -------------------------------------------------------------------

void AddBrowserMainExtraParts(ChromeBrowserMainParts* main_parts) {
  main_parts->AddParts(std::make_unique<OpenBrowserMainExtraParts>());
}

// --- 0010 -------------------------------------------------------------------

void AttachTabHelpers(content::WebContents* web_contents) {
  if (web_contents) {
    TabHelpers::AttachTabHelpers(web_contents);
  }
}

// --- 0011 -------------------------------------------------------------------

bool RouteExternalUrls(::Profile* profile,
                       const std::vector<GURL>& urls,
                       std::optional<std::string> source_app_id) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  OpenBrowserService* service = OpenBrowserService::Get();
  if (!service || urls.empty()) {
    return false;
  }
  // Incognito and guest launches keep Chromium's own windows.
  if (profile && (profile->IsOffTheRecord() || profile->IsGuestSession())) {
    return false;
  }
  // Always go through OpenBrowserService so open:// deep links, mailto: and
  // the pre-start queue are handled even when a source app id is present.
  service->RouteExternalUrls(urls, std::move(source_app_id));
  return true;
}

bool ShouldTerminateApp() {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (g_hook_delegate) {
    return g_hook_delegate->ShouldTerminateApp();
  }
  return true;
}

bool HandleAppReopen(bool has_visible_windows) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (g_hook_delegate && g_hook_delegate->HandleAppReopen(has_visible_windows)) {
    return true;
  }
  if (has_visible_windows) {
    if (OpenWindowUi* ui = WindowUiForBrowser(nullptr)) {
      ui->ActivateWindow();
      return true;
    }
  }
  return false;
}

// --- 0012 -------------------------------------------------------------------

bool IsOpenMenuCommand(int command_id) {
  return command_id >= kOpenMenuCommandIdBase &&
         command_id <= kOpenMenuCommandIdMax;
}

bool IsOpenMenuCommandEnabled(BrowserWindowInterface* browser, int command_id) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (!IsOpenMenuCommand(command_id)) {
    return false;
  }
  if (g_hook_delegate) {
    if (std::optional<bool> override_enabled =
            g_hook_delegate->IsBrowserCommandEnabled(browser, command_id)) {
      return *override_enabled;
    }
  }
  std::optional<CommandId> cid = CommandIdFromMenuTag(command_id);
  if (!cid.has_value()) {
    return false;
  }
  OpenBrowserService* service = OpenBrowserService::Get();
  if (!service) {
    return true;
  }
  const CommandDefinition* def = service->commands().FindById(*cid);
  if (!def || def->is_reserved) {
    return false;
  }
  OpenWindowUi* ui = WindowUiForBrowser(browser);
  switch (def->availability_predicate) {
    case AvailabilityPredicate::kAlways:
    case AvailabilityPredicate::kHasHistory:
    case AvailabilityPredicate::kNotTracing:
      return true;
    case AvailabilityPredicate::kIsTracing:
      return false;
    case AvailabilityPredicate::kHasCurrentTab:
    case AvailabilityPredicate::kHasWebPage:
    case AvailabilityPredicate::kCanGoBack:
    case AvailabilityPredicate::kCanGoForward:
    case AvailabilityPredicate::kCurrentTabPinned:
    case AvailabilityPredicate::kCurrentTabInToday:
    case AvailabilityPredicate::kCurrentTabHasPinnedUrl:
    case AvailabilityPredicate::kCurrentTabIsFavorite:
    case AvailabilityPredicate::kCurrentTabNotFavorite:
      return ui && ui->ActiveWebContents() != nullptr;
    case AvailabilityPredicate::kCurrentTabInSplit:
      return ui && ui->split_active();
    case AvailabilityPredicate::kHasMultipleSpaces: {
      OpenWindowController* windows = service->window_controller();
      if (!windows || !ui) {
        return false;
      }
      return windows->GetWindowSpaceIds(ui->window_id()).size() > 1;
    }
    case AvailabilityPredicate::kTextFieldFocused:
      return true;
  }
  return true;
}

bool IsReservedBrowserCommand(int command_id) {
  if (IsOpenMenuCommand(command_id)) {
    return true;
  }
  switch (command_id) {
    case IDC_NEW_TAB:
    case IDC_CLOSE_TAB:
    case IDC_CLOSE_WINDOW:
    case IDC_NEW_WINDOW:
    case IDC_NEW_INCOGNITO_WINDOW:
    case IDC_RESTORE_TAB:
    case IDC_FOCUS_LOCATION:
    case IDC_SAVE_PAGE:
    case IDC_BOOKMARK_THIS_TAB:
    case IDC_SELECT_NEXT_TAB:
    case IDC_SELECT_PREVIOUS_TAB:
    case IDC_CYCLE_TO_NEXT_TAB:
    case IDC_CYCLE_TO_PREV_TAB:
    case IDC_SELECT_TAB_0:
    case IDC_SELECT_TAB_1:
    case IDC_SELECT_TAB_2:
    case IDC_SELECT_TAB_3:
    case IDC_SELECT_TAB_4:
    case IDC_SELECT_TAB_5:
    case IDC_SELECT_TAB_6:
    case IDC_SELECT_TAB_7:
    case IDC_SELECT_LAST_TAB:
    case IDC_TOGGLE_VERTICAL_TABS_COLLAPSE:
    case IDC_EXIT:
      return true;
    default:
      return false;
  }
}

int OpenCommandIdForMenuTag(std::string_view command_id) {
  if (OpenBrowserService* service = OpenBrowserService::Get()) {
    if (const CommandDefinition* def =
            service->commands().FindByStringId(command_id)) {
      return MenuTagForCommandId(def->command_id);
    }
  }
  static const CommandRegistry kDefaultRegistry;
  const CommandDefinition* def = kDefaultRegistry.FindByStringId(command_id);
  return def ? MenuTagForCommandId(def->command_id) : 0;
}

int FallbackChromiumCommandForOpen(CommandId cid) {
  switch (cid) {
    case CommandId::kNewWindow:
      return IDC_NEW_WINDOW;
    case CommandId::kNewIncognitoWindow:
      return IDC_NEW_INCOGNITO_WINDOW;
    case CommandId::kRestoreLastClosedTab:
      return IDC_RESTORE_TAB;
    case CommandId::kPrint:
      return IDC_PRINT;
    case CommandId::kSavePageAs:
      return IDC_SAVE_PAGE;
    case CommandId::kReload:
      return IDC_RELOAD;
    case CommandId::kForceReload:
      return IDC_RELOAD_BYPASSING_CACHE;
    case CommandId::kStopLoading:
      return IDC_STOP;
    case CommandId::kZoomIn:
      return IDC_ZOOM_PLUS;
    case CommandId::kZoomOut:
      return IDC_ZOOM_MINUS;
    case CommandId::kZoomActualSize:
      return IDC_ZOOM_NORMAL;
    case CommandId::kCast:
      return IDC_ROUTE_MEDIA;
    case CommandId::kDeveloperTools:
      return IDC_DEV_TOOLS;
    case CommandId::kJavaScriptConsole:
      return IDC_DEV_TOOLS_CONSOLE;
    case CommandId::kViewSource:
      return IDC_VIEW_SOURCE;
    case CommandId::kInspectElements:
    case CommandId::kNetworkInspector:
      return IDC_DEV_TOOLS_INSPECT;
    case CommandId::kAllowJsAppleEvents:
      return IDC_TOGGLE_JAVASCRIPT_APPLE_EVENTS;
    case CommandId::kTaskManager:
      return IDC_TASK_MANAGER_MAIN_MENU;
    case CommandId::kManageExtensions:
      return IDC_MANAGE_EXTENSIONS;
    case CommandId::kImportFromBrowser:
      return IDC_IMPORT_SETTINGS;
    case CommandId::kDuplicateTab:
      return IDC_DUPLICATE_TAB;
    case CommandId::kGoBack:
      return IDC_BACK;
    case CommandId::kGoForward:
      return IDC_FORWARD;
    default:
      return 0;
  }
}

bool ExecuteFallbackChromiumCommand(BrowserWindowInterface* browser,
                                    CommandId id) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (!browser) {
    return false;
  }
  const int idc = FallbackChromiumCommandForOpen(id);
  if (idc == 0) {
    return false;
  }
  base::AutoReset<bool> passthrough(&g_command_passthrough, true);
  if (!chrome::IsCommandEnabled(browser, idc)) {
    return false;
  }
  chrome::ExecuteCommand(browser, idc);
  return true;
}

bool HandleBrowserCommand(BrowserWindowInterface* browser, int command_id) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (g_command_passthrough) {
    return false;
  }
  if (g_hook_delegate &&
      g_hook_delegate->HandleBrowserCommand(browser, command_id)) {
    return true;
  }
  std::optional<CommandId> open_command = MapChromiumCommandToOpen(command_id);
  if (!open_command.has_value()) {
    return false;
  }
  if (OpenWindowUi* ui = WindowUiForBrowser(browser)) {
    // OpenWindowUi::HandleFindCommand forwards any CommandId through
    // RunShortcut() -> RunCommandId().
    if (ui->HandleFindCommand(*open_command)) {
      return true;
    }
  }
  // If an Open custom menu tag (59000+) wasn't handled by OpenWindowUi yet,
  // delegate to its native Chromium IDC_* twin when one exists (e.g. Save Page
  // As…, Print, Zoom, DevTools, View Source).
  if (IsOpenMenuCommand(command_id) && browser) {
    return ExecuteFallbackChromiumCommand(browser, *open_command);
  }
  return false;
}

// --- 0013 -------------------------------------------------------------------

bool UseOpenMacMenusAndShortcuts() {
  return true;
}

std::vector<OpenMenuItemSpec> BuildOpenMainMenuSpec(
    const std::u16string& product_name) {
  static const CommandRegistry kDefaultRegistry;
  const CommandRegistry& registry =
      OpenBrowserService::Get() ? OpenBrowserService::Get()->commands()
                                : kDefaultRegistry;
  const std::string app_name =
      product_name.empty() ? "Open" : base::UTF16ToUTF8(product_name);

  std::vector<OpenMenuItemSpec> main_bar;

  // 1. Open (app) menu
  {
    std::vector<OpenMenuItemSpec> items;
    AppendCommandWithCarriers(registry, "about-open", items,
                              "About " + app_name);
    items.push_back(MakeSeparator());
    AppendCommands(registry, {"settings", "set-default-browser"}, items);
    items.push_back(MakeSeparator());
    AppendCommands(registry, {"import-from-browser", "check-for-updates"},
                   items);
    items.push_back(MakeSeparator());
    OpenMenuItemSpec services;
    services.kind = OpenMenuItemSpec::Kind::kServicesSubmenu;
    services.title = "Services";
    items.push_back(std::move(services));
    items.push_back(MakeSeparator());
    AppendCommandWithCarriers(registry, "hide-open", items, "Hide " + app_name);
    AppendCommands(registry, {"hide-others", "show-all"}, items);
    items.push_back(MakeSeparator());
    AppendCommandWithCarriers(registry, "quit-open", items, "Quit " + app_name);
    main_bar.push_back(MakeSubmenu(app_name, std::move(items), IDC_CHROME_MENU));
  }

  // 2. File menu
  {
    std::vector<OpenMenuItemSpec> items;
    AppendCommands(registry,
                   {"new-tab", "new-window", "blank-window",
                    "new-incognito-window", "new-little-open-window",
                    "restore-last-closed-tab"},
                   items);
    items.push_back(MakeSeparator());
    AppendCommands(registry, {"open-command-bar"}, items);
    items.push_back(MakeSeparator());
    AppendCommands(registry,
                   {"new-profile", "new-note", "new-note-in-split", "new-easel"},
                   items);
    items.push_back(MakeSeparator());
    AppendCommands(registry, {"close-window", "archive-tab"}, items);
    items.push_back(MakeSeparator());
    AppendCommands(registry,
                   {"share-page", "capture-page", "capture-full-page",
                    "capture-portrait", "save-page-as", "print"},
                   items);
    AppendCommands(
        registry,
        {"new-boost", "edit-boost", "new-legacy-boost", "boost-gallery"},
        items);
    main_bar.push_back(MakeSubmenu("File", std::move(items), IDC_FILE_MENU));
  }

  // 3. Edit menu
  {
    std::vector<OpenMenuItemSpec> items;
    AppendCommands(registry, {"undo", "redo"}, items);
    items.push_back(MakeSeparator());
    AppendCommands(registry,
                   {"cut", "copy", "copy-url", "copy-url-markdown",
                    "copy-url-quote", "paste", "paste-and-match-style",
                    "delete", "select-all"},
                   items);
    items.push_back(MakeSeparator());

    std::vector<OpenMenuItemSpec> find_items;
    AppendCommands(registry,
                   {"find", "find-and-replace", "find-next", "find-previous",
                    "use-selection-to-find", "jump-to-selection"},
                   find_items);
    items.push_back(
        MakeSubmenu("Find", std::move(find_items), IDC_FIND_MENU));

    std::vector<OpenMenuItemSpec> spelling_items;
    AppendCommands(registry,
                   {"show-spelling", "check-spelling",
                    "check-spelling-while-typing", "check-grammar",
                    "correct-spelling-automatically"},
                   spelling_items);
    items.push_back(MakeSubmenu("Spelling and Grammar",
                                std::move(spelling_items), IDC_SPELLCHECK_MENU));

    std::vector<OpenMenuItemSpec> substitutions_items;
    AppendCommands(registry,
                   {"show-substitutions", "smart-copy-paste", "smart-quotes",
                    "smart-dashes", "smart-links", "text-replacement",
                    "data-detectors"},
                   substitutions_items);
    items.push_back(
        MakeSubmenu("Substitutions", std::move(substitutions_items)));

    std::vector<OpenMenuItemSpec> transform_items;
    AppendCommands(registry,
                   {"make-upper-case", "make-lower-case", "capitalize"},
                   transform_items);
    items.push_back(
        MakeSubmenu("Transformations", std::move(transform_items)));

    std::vector<OpenMenuItemSpec> speech_items;
    AppendCommands(registry, {"start-speaking", "stop-speaking"}, speech_items);
    items.push_back(MakeSubmenu("Speech", std::move(speech_items)));

    std::vector<OpenMenuItemSpec> font_items;
    AppendCommands(registry,
                   {"show-fonts", "font-bold", "font-italic", "font-underline"},
                   font_items);
    std::vector<OpenMenuItemSpec> format_items;
    format_items.push_back(MakeSubmenu("Font", std::move(font_items)));
    items.push_back(MakeSubmenu("Format", std::move(format_items)));

    items.push_back(MakeSeparator());
    AppendCommands(registry, {"emoji-and-symbols"}, items);
    main_bar.push_back(MakeSubmenu("Edit", std::move(items), IDC_EDIT_MENU));
  }

  // 4. View menu
  {
    std::vector<OpenMenuItemSpec> items;
    std::vector<OpenMenuItemSpec> appearance_items;
    appearance_items.push_back(
        MakeSectionHeader("Websites, Easels, and Notes will use:"));
    AppendCommands(
        registry,
        {"appearance-automatic", "appearance-light", "appearance-dark"},
        appearance_items);
    items.push_back(MakeSubmenu("Appearance", std::move(appearance_items)));
    items.push_back(MakeSeparator());
    AppendCommands(registry,
                   {"toggle-sidebar", "toggle-toolbar",
                    "collapse-pinned-section", "expand-pinned-section",
                    "reveal-current-tab", "exit-modal"},
                   items);
    items.push_back(MakeSeparator());
    AppendCommands(registry,
                   {"stop-loading", "reload", "force-reload",
                    "clear-cookies-and-refresh", "clear-cache-and-refresh"},
                   items);
    items.push_back(MakeSeparator());
    AppendCommands(registry,
                   {"add-split-view", "close-split-pane",
                    "separate-from-split-view", "expand-current-split"},
                   items);
    items.push_back(MakeSeparator());
    AppendCommands(registry, {"zoom-actual-size", "zoom-in", "zoom-out"},
                   items);
    items.push_back(MakeSeparator());
    AppendCommands(registry, {"cast"}, items);
    items.push_back(MakeSeparator());
    std::vector<OpenMenuItemSpec> dev_items;
    AppendCommands(registry,
                   {"view-source", "developer-tools", "inspect-elements",
                    "javascript-console", "network-inspector",
                    "allow-js-apple-events", "toggle-developer-mode"},
                   dev_items);
    items.push_back(
        MakeSubmenu("Developer", std::move(dev_items), IDC_DEVELOPER_MENU));
    items.push_back(MakeSeparator());
    AppendCommands(registry, {"toggle-full-screen"}, items);
    main_bar.push_back(MakeSubmenu("View", std::move(items), IDC_VIEW_MENU));
  }

  // 5. Spaces menu
  {
    std::vector<OpenMenuItemSpec> items;
    AppendCommands(
        registry,
        {"new-space", "edit-theme", "rename-space", "change-profile"}, items);
    items.push_back(MakeSeparator());
    AppendCommands(registry, {"next-space", "previous-space"}, items);
    items.push_back(MakeSeparator());
    AppendCommands(registry, {"manage-spaces"}, items);
    main_bar.push_back(MakeSubmenu("Spaces", std::move(items)));
  }

  // 6. Tabs menu
  {
    std::vector<OpenMenuItemSpec> items;
    AppendCommands(registry, {"new-tab", "pin-unpin-tab", "new-folder"}, items);
    items.push_back(MakeSeparator());
    AppendCommands(registry,
                   {"next-tab", "previous-tab", "reveal-tab-in-sidebar"},
                   items);
    items.push_back(MakeSeparator());
    AppendCommands(registry, {"clear-unpinned-tabs", "reset-all-tabs-in-space"},
                   items);
    AppendCommands(
        registry,
        {"duplicate-tab", "rename-tab", "reset-tab", "cycle-tab-forward",
         "cycle-tab-backward", "tab-switcher-forward", "tab-switcher-backward",
         "expand-all-folders", "collapse-all-folders", "peek-email",
         "join-meeting", "open-in-current-space"},
        items);
    main_bar.push_back(MakeSubmenu("Tabs", std::move(items)));
  }

  // 7. Archive menu
  {
    std::vector<OpenMenuItemSpec> items;
    AppendCommands(registry, {"go-back", "go-forward"}, items);
    items.push_back(MakeSeparator());
    AppendCommands(registry, {"view-history", "view-archive", "clear-archive"},
                   items);
    main_bar.push_back(MakeSubmenu("Archive", std::move(items)));
  }

  // 8. Extensions menu
  {
    std::vector<OpenMenuItemSpec> items;
    AppendCommands(registry,
                   {"open-extensions-picker", "add-extension",
                    "manage-extensions"},
                   items);
    main_bar.push_back(MakeSubmenu("Extensions", std::move(items)));
  }

  // 9. Window menu
  {
    std::vector<OpenMenuItemSpec> items;
    AppendCommands(registry, {"stay-on-top", "minimize-window", "zoom-window"},
                   items);
    items.push_back(MakeSeparator());
    AppendCommands(registry,
                   {"view-library", "view-downloads", "view-easels-notes",
                    "view-media", "view-boosts"},
                   items);
    items.push_back(MakeSeparator());
    AppendCommands(registry, {"bring-all-to-front"}, items);
    OpenMenuItemSpec win_menu =
        MakeSubmenu("Window", std::move(items), IDC_WINDOW_MENU);
    win_menu.is_windows_menu = true;
    main_bar.push_back(std::move(win_menu));
  }

  // 10. Help menu
  {
    std::vector<OpenMenuItemSpec> items;
    AppendCommands(registry,
                   {"getting-started", "keyboard-shortcuts-edu", "contact-team",
                    "help-center", "release-notes", "export-notes"},
                   items);
    items.push_back(MakeSeparator());
    std::vector<OpenMenuItemSpec> troubleshooting_items;
    AppendCommands(registry, {"record-trace", "cancel-trace", "task-manager"},
                   troubleshooting_items);
    troubleshooting_items.push_back(MakeSeparator());
    AppendCommands(registry, {"reveal-open-data", "copy-open-info"},
                   troubleshooting_items);
    items.push_back(
        MakeSubmenu("Troubleshooting", std::move(troubleshooting_items)));
    OpenMenuItemSpec help_menu =
        MakeSubmenu("Help", std::move(items), IDC_HELP_MENU);
    help_menu.is_help_menu = true;
    main_bar.push_back(std::move(help_menu));
  }

  return main_bar;
}

// --- 0014 -------------------------------------------------------------------

bool MaybeInterceptLinkOpen(BrowserWindowInterface* browser,
                            content::WebContents* source,
                            const content::OpenURLParams& params) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (!browser || !params.url.is_valid()) {
    return false;
  }
  if (g_hook_delegate &&
      g_hook_delegate->MaybeInterceptLinkOpen(browser, source, params)) {
    return true;
  }
  return false;
}

bool MaybeInterceptAddNewContents(
    BrowserWindowInterface* browser,
    content::WebContents* source,
    std::unique_ptr<content::WebContents>& new_contents,
    const GURL& target_url,
    WindowOpenDisposition disposition,
    bool user_gesture) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (!browser || !new_contents) {
    return false;
  }
  if (g_hook_delegate &&
      g_hook_delegate->MaybeInterceptAddNewContents(
          browser, source, new_contents, target_url, disposition,
          user_gesture)) {
    return true;
  }
  return false;
}

void OnUpdateTargetURL(BrowserWindowInterface* browser,
                       content::WebContents* source,
                       const GURL& url) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (g_hook_delegate) {
    g_hook_delegate->OnUpdateTargetURL(browser, source, url);
  }
}

void OnFullscreenStateChanged(BrowserView* browser_view) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (!browser_view) {
    return;
  }
  if (g_hook_delegate) {
    g_hook_delegate->OnFullscreenStateChanged(browser_view,
                                              browser_view->IsFullscreen());
  }
}

// --- 0015 -------------------------------------------------------------------

void AppendWebContextMenuItems(BrowserWindowInterface* browser,
                               content::WebContents* source,
                               const content::ContextMenuParams& params,
                               ui::SimpleMenuModel* menu_model) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (!menu_model) {
    return;
  }

  // Link items: insert right after Chromium's link-open block (or at top).
  if (params.link_url.is_valid()) {
    size_t insert_at = 0;
    if (auto idx =
            menu_model->GetIndexOfCommandId(IDC_CONTENT_CONTEXT_OPENLINKNEWTAB)) {
      insert_at = *idx + 1;
    }
    menu_model->InsertItemAt(insert_at++, kOpenContextOpenLinkInPeek,
                             u"Open Link in Peek");
    menu_model->InsertItemAt(insert_at++, kOpenContextOpenLinkInSplitView,
                             u"Open Link in Split View");
    menu_model->InsertItemAt(insert_at++, kOpenContextOpenLinkInLittleOpen,
                             u"Open Link in Little Open");
    menu_model->InsertItemAt(insert_at++, kOpenContextCopyCleanLink,
                             u"Copy Clean Link");
    menu_model->InsertSeparatorAt(insert_at, ui::NORMAL_SEPARATOR);
  }

  // Selection items: insert Translate Selection after Copy (or at end).
  if (!params.is_editable && !params.selection_text.empty()) {
    if (auto idx = menu_model->GetIndexOfCommandId(IDC_CONTENT_CONTEXT_COPY)) {
      menu_model->InsertItemAt(*idx + 1, kOpenContextTranslateSelection,
                               u"Translate Selection");
    } else {
      menu_model->AddItem(kOpenContextTranslateSelection,
                          u"Translate Selection");
    }
  }

  // Page items (non-link, non-media, non-editable, empty selection):
  // insert Capture Page, Capture Full Page, New Boost for This Site before
  // View Page Source / Inspect.
  if (params.link_url.is_empty() && !params.is_editable &&
      params.selection_text.empty() &&
      params.media_type == blink::mojom::ContextMenuDataMediaType::kNone) {
    size_t insert_at = menu_model->GetItemCount();
    if (auto src_idx = menu_model->GetIndexOfCommandId(IDC_VIEW_SOURCE)) {
      insert_at = *src_idx;
    } else if (auto insp_idx = menu_model->GetIndexOfCommandId(
                   IDC_CONTENT_CONTEXT_INSPECTELEMENT)) {
      insert_at = *insp_idx;
    }
    if (insert_at > 0 &&
        menu_model->GetTypeAt(insert_at - 1) != ui::MenuModel::TYPE_SEPARATOR) {
      menu_model->InsertSeparatorAt(insert_at++, ui::NORMAL_SEPARATOR);
    }
    menu_model->InsertItemAt(insert_at++, kOpenContextCapturePage,
                             u"Capture Page");
    menu_model->InsertItemAt(insert_at++, kOpenContextCaptureFullPage,
                             u"Capture Full Page");
    menu_model->InsertItemAt(insert_at++, kOpenContextNewBoostForSite,
                             u"New Boost for This Site");
    if (insert_at < menu_model->GetItemCount() &&
        menu_model->GetTypeAt(insert_at) != ui::MenuModel::TYPE_SEPARATOR) {
      menu_model->InsertSeparatorAt(insert_at, ui::NORMAL_SEPARATOR);
    }
  }
}

std::optional<bool> IsWebContextMenuCommandEnabled(
    BrowserWindowInterface* browser,
    content::WebContents* source,
    const content::ContextMenuParams& params,
    int command_id) {
  if (command_id < kOpenContextMenuCommandIdBase ||
      command_id > kOpenContextMenuCommandIdMax) {
    return std::nullopt;
  }
  switch (command_id) {
    case kOpenContextOpenLinkInPeek:
    case kOpenContextOpenLinkInSplitView:
    case kOpenContextOpenLinkInLittleOpen:
    case kOpenContextCopyCleanLink:
      return params.link_url.is_valid();
    case kOpenContextCapturePage:
    case kOpenContextCaptureFullPage:
    case kOpenContextNewBoostForSite:
      return source != nullptr;
    case kOpenContextTranslateSelection:
      return !params.selection_text.empty();
    default:
      return false;
  }
}

bool ExecuteWebContextMenuCommand(BrowserWindowInterface* browser,
                                  content::WebContents* source,
                                  const content::ContextMenuParams& params,
                                  int command_id,
                                  int event_flags) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (command_id < kOpenContextMenuCommandIdBase ||
      command_id > kOpenContextMenuCommandIdMax) {
    return false;
  }
  if (g_hook_delegate &&
      g_hook_delegate->ExecuteWebContextMenuCommand(
          browser, source, params, command_id, event_flags)) {
    return true;
  }

  OpenBrowserService* service = OpenBrowserService::Get();
  OpenWindowController* windows =
      service ? service->window_controller() : nullptr;
  OpenWindowUi* ui = WindowUiForBrowser(browser);

  switch (command_id) {
    case kOpenContextOpenLinkInPeek:
      if (ui && params.link_url.is_valid()) {
        ui->OpenPeek(params.link_url, ui->ActiveTabId());
        return true;
      }
      return false;
    case kOpenContextOpenLinkInLittleOpen:
      if (windows && params.link_url.is_valid()) {
        windows->OpenLittleOpen(params.link_url);
        return true;
      }
      return false;
    case kOpenContextCopyCleanLink:
      if (params.link_url.is_valid()) {
        GURL cleaned = CleanLinkUrl(params.link_url);
        ui::ScopedClipboardWriter writer(ui::ClipboardBuffer::kCopyPaste);
        writer.WriteText(base::UTF8ToUTF16(cleaned.spec()));
        return true;
      }
      return false;
    case kOpenContextCapturePage:
      if (ui) {
        ui->RunCommand("capture-page");
        return true;
      }
      return false;
    case kOpenContextCaptureFullPage:
      if (ui) {
        ui->RunCommand("capture-full-page");
        return true;
      }
      return false;
    case kOpenContextNewBoostForSite:
      if (ui) {
        ui->RunCommand("new-boost");
        return true;
      }
      return false;
    case kOpenContextOpenLinkInSplitView:
    case kOpenContextTranslateSelection:
      // Handled by Wave B's OpenHookDelegate once Split/Translate UI is wired.
      return true;
    default:
      return false;
  }
}

views::View* GetBubbleAnchorView(BrowserWindowInterface* browser) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (!browser) {
    return nullptr;
  }
  if (g_hook_delegate) {
    views::View* anchor = g_hook_delegate->GetBubbleAnchorView(browser);
    return (anchor && anchor->IsDrawn()) ? anchor : nullptr;
  }
  BrowserView* browser_view = BrowserView::GetBrowserViewForBrowser(browser);
  OpenBrowserView* open_view =
      browser_view ? OpenBrowserView::FromBrowserView(browser_view) : nullptr;
  if (!open_view || !open_view->IsDrawn()) {
    return nullptr;
  }
  if (open_view->sidebar_hidden()) {
    if (open_view->single_pane_toolbar_visible()) {
      if (views::View* sc = open_view->GetSinglePaneSiteControlAnchor();
          sc && sc->IsDrawn()) {
        return sc;
      }
    }
    return nullptr;
  }
  if (views::View* sc = open_view->GetSiteControlAnchorView();
      sc && sc->IsDrawn()) {
    return sc;
  }
  if (views::View* pill = open_view->GetUrlPillView();
      pill && pill->IsDrawn()) {
    return pill;
  }
  return nullptr;
}

std::optional<gfx::Rect> GetBubbleAnchorRect(BrowserWindowInterface* browser) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (!browser) {
    return std::nullopt;
  }
  if (g_hook_delegate) {
    if (std::optional<gfx::Rect> rect =
            g_hook_delegate->GetBubbleAnchorRect(browser)) {
      return rect;
    }
  }
  BrowserView* browser_view = BrowserView::GetBrowserViewForBrowser(browser);
  OpenBrowserView* open_view =
      browser_view ? OpenBrowserView::FromBrowserView(browser_view) : nullptr;
  if (!open_view || !open_view->IsDrawn()) {
    return std::nullopt;
  }
  views::View* host = open_view->web_contents_host();
  gfx::Rect bounds = (host && host->IsDrawn()) ? host->GetBoundsInScreen()
                                               : open_view->GetBoundsInScreen();
  // Position a 1x1 anchor near the top-left of the web panel with clean inset.
  return gfx::Rect(bounds.x() + 16, bounds.y() + 8, 1, 1);
}

}  // namespace open_unified::hooks
