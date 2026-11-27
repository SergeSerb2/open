// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// The only Open header that patched Chromium files include, always as
//
//   #include "open_unified/buildflags.h"
//   #if BUILDFLAG(OPEN_UNIFIED_BROWSER)
//   #include "open_unified/browser/open_chromium_hooks.h"  // nogncheck
//   #endif
//
// with every call site under the same BUILDFLAG, so a checkout with the
// hooks applied also builds stock Chromium (open_unified_browser = false,
// component builds). //chrome targets depend on //open_unified:buildflags
// only (hook 0001); the hook symbols resolve at link time through
// //chrome:dependencies.
// Each function names the hook (Unified/patches/chromium/series) that calls
// it. Keep this header small and free of Open model types, so a Chromium
// rebuild after an Open change recompiles only the hooked files.

#ifndef OPEN_UNIFIED_BROWSER_OPEN_CHROMIUM_HOOKS_H_
#define OPEN_UNIFIED_BROWSER_OPEN_CHROMIUM_HOOKS_H_

#include <cstdint>
#include <memory>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

#include "content/public/browser/content_browser_client.h"
#include "mojo/public/cpp/bindings/pending_remote.h"
#include "services/network/public/mojom/web_transport.mojom-forward.h"
#include "services/network/public/mojom/websocket.mojom-forward.h"
#include "services/service_manager/public/cpp/binder_registry.h"
#include "ui/base/window_open_disposition.h"
#include "ui/gfx/geometry/rect.h"
#include "ui/views/widget/widget.h"

class BrowserView;
class BrowserWindowInterface;
class ChromeBrowserMainParts;
class ChromeContentBrowserClient;
class GURL;
class Profile;

namespace gfx {
class Point;
}
namespace content {
class BrowserContext;
class BrowserURLHandler;
struct ContextMenuParams;
struct OpenURLParams;
class RenderFrameHost;
class RenderProcessHost;
class WebContents;
}  // namespace content
namespace net {
class IsolationInfo;
class SiteForCookies;
}  // namespace net
namespace network {
class URLLoaderFactoryBuilder;
}
namespace ui {
class SimpleMenuModel;
}
namespace url {
class Origin;
}
namespace views {
class View;
}

namespace open_unified::hooks {

// Stable command tag ranges owned by Open Unified (above Chromium's highest
// IDC_* value 57343, never colliding with Chrome or extension ranges).
inline constexpr int kOpenMenuCommandIdBase = 59000;
inline constexpr int kOpenMenuCommandIdMax = 59999;

inline constexpr int kOpenContextMenuCommandIdBase = 60000;
inline constexpr int kOpenContextMenuCommandIdMax = 60099;

inline constexpr int kOpenContextOpenLinkInPeek = 60001;
inline constexpr int kOpenContextOpenLinkInSplitView = 60002;
inline constexpr int kOpenContextOpenLinkInLittleOpen = 60003;
inline constexpr int kOpenContextCopyCleanLink = 60004;
inline constexpr int kOpenContextCapturePage = 60005;
inline constexpr int kOpenContextCaptureFullPage = 60006;
inline constexpr int kOpenContextNewBoostForSite = 60007;
inline constexpr int kOpenContextTranslateSelection = 60008;

// Modifier flags used in OpenMenuItemSpec (mapped to NSEventModifierFlags in
// main_menu_builder.mm).
enum OpenMenuModifierFlags : uint32_t {
  kOpenMenuModNone = 0,
  kOpenMenuModShift = 1u << 0,
  kOpenMenuModControl = 1u << 1,
  kOpenMenuModOption = 1u << 2,
  kOpenMenuModCommand = 1u << 3,
};

// Platform-neutral description of one macOS main-menu entry built from
// CommandRegistry and MenuBuilder.swift's exact Arc menu structure.
struct OpenMenuItemSpec {
  enum class Kind {
    kItem,
    kSeparator,
    kSubmenu,
    kSectionHeader,
    kServicesSubmenu,
  };

  OpenMenuItemSpec();
  OpenMenuItemSpec(const OpenMenuItemSpec&);
  OpenMenuItemSpec(OpenMenuItemSpec&&) noexcept;
  OpenMenuItemSpec& operator=(const OpenMenuItemSpec&);
  OpenMenuItemSpec& operator=(OpenMenuItemSpec&&) noexcept;
  ~OpenMenuItemSpec();

  Kind kind = Kind::kItem;
  std::string title;
  std::string command_id;       // Stable CommandRegistry kebab-case id
  int command_tag = 0;          // IDC_* or kOpenMenuCommandIdBase + enum
  std::string key_equivalent;   // UTF-8 macOS keyEquivalent (e.g. "t", "\t")
  uint32_t modifier_mask = kOpenMenuModNone;
  std::string native_selector;  // Non-empty for AppKit responder selectors
  int native_tag = 0;           // Tag for native selector (e.g. Find panel)
  bool hidden = false;
  bool alternate = false;
  bool target_app_delegate = false;
  bool target_nsapp = false;
  bool is_windows_menu = false;
  bool is_help_menu = false;
  std::vector<OpenMenuItemSpec> submenu;
};

// Optional UI-layer delegate installed by OpenWindowController / Wave B so
// hooks 0011..0015 can invoke UI behaviors (Warn Before Quitting, Dock Reopen,
// Peek/Little Open link interception, Link Hover pill, Fullscreen collapse,
// Web Context Menu extensions, and URL-pill bubble anchoring) without coupling
// Chromium compilation units to Open UI headers.
class OpenHookDelegate {
 public:
  virtual ~OpenHookDelegate() = default;

  // Hook 0011: Return false to cancel termination (Warn Before Quitting,
  // active downloads prompt, or async flush).
  virtual bool ShouldTerminateApp() { return true; }

  // Hook 0011: Return true when Open handled macOS Dock icon reopen.
  virtual bool HandleAppReopen(bool has_visible_windows) { return false; }

  // Hook 0012: Override command dispatch/availability for a browser window.
  virtual std::optional<bool> IsBrowserCommandEnabled(
      BrowserWindowInterface* browser,
      int command_id) {
    return std::nullopt;
  }
  virtual bool HandleBrowserCommand(BrowserWindowInterface* browser,
                                    int command_id) {
    return false;
  }

  // Hook 0014: Link interception (Shift+Click / Opt+Cmd+Click / cross-domain
  // from Pinned or Favorite tabs -> Peek or Little Open), hover URL pill, and
  // fullscreen layout notifications.
  virtual bool MaybeInterceptLinkOpen(BrowserWindowInterface* browser,
                                      content::WebContents* source,
                                      const content::OpenURLParams& params) {
    return false;
  }
  virtual bool MaybeInterceptAddNewContents(
      BrowserWindowInterface* browser,
      content::WebContents* source,
      std::unique_ptr<content::WebContents>& new_contents,
      const GURL& target_url,
      WindowOpenDisposition disposition,
      bool user_gesture) {
    return false;
  }
  virtual void OnUpdateTargetURL(BrowserWindowInterface* browser,
                                 content::WebContents* source,
                                 const GURL& url) {}
  virtual void OnFullscreenStateChanged(BrowserView* browser_view,
                                        bool is_fullscreen) {}

  // Hook 0015: Web context menu command execution & bubble anchoring.
  virtual bool ExecuteWebContextMenuCommand(
      BrowserWindowInterface* browser,
      content::WebContents* source,
      const content::ContextMenuParams& params,
      int command_id,
      int event_flags) {
    return false;
  }
  virtual views::View* GetBubbleAnchorView(BrowserWindowInterface* browser) {
    return nullptr;
  }
  virtual std::optional<gfx::Rect> GetBubbleAnchorRect(
      BrowserWindowInterface* browser) {
    return std::nullopt;
  }
};

// Registers or clears the active OpenHookDelegate (UI thread only).
void SetHookDelegate(OpenHookDelegate* delegate);
OpenHookDelegate* GetHookDelegate();

// --- 0002: Open browser chrome in BrowserView / BrowserWidget -------------

// End of BrowserView::AddedToWidget() (first time only). Installs
// OpenBrowserView for normal browser windows.
void OnBrowserViewAddedToWidget(BrowserView* browser_view);
// Start of BrowserView::~BrowserView().
void OnBrowserViewDestroying(BrowserView* browser_view);
// True when OpenBrowserView is installed in |browser_view|.
bool HasOpenBrowserView(BrowserView* browser_view);
// BrowserWidget::InitBrowserWidget(), after the delegate is set. Per OS:
// Linux gets Open's frameless, translucent, drop-shadow window; macOS keeps
// the titled full-size-content-view frame (native traffic lights); Windows
// keeps the standard DWM frame (Aero Snap, resize borders, Mica through
// OpenPlatform::ApplyWindowEffects()).
void AdjustBrowserWidgetParams(BrowserView* browser_view,
                               views::Widget::InitParams* params);
// Start of BrowserView::NonClientHitTest() (|point| in the frame view's
// coordinates, as Chromium passes it): OpenBrowserView's code (HTCAPTION
// over its draggable frame inset and toolbar backgrounds, custom resize
// edges on Windows/Linux, HTCLIENT elsewhere), or nullopt when Open's view
// is not installed or the point is outside it. Every platform frame view
// (BrowserFrameViewWin, OpaqueBrowserFrameView, BrowserFrameViewLinux,
// BrowserFrameViewMac) asks the client view for these points.
std::optional<int> NonClientHitTest(BrowserView* browser_view,
                                    const gfx::Point& point);
// Start of BrowserViewLayoutImpl::Layout(): true when OpenBrowserView
// covers |host| (a BrowserView); Open then lays out the whole client area
// and Chromium's top container and contents container stay out of it.
bool LayoutOpenBrowserView(views::View* host);

// --- 0003: //open/adblock network, socket and renderer hooks ---------------

// Start of ChromeContentBrowserClient::WillCreateURLLoaderFactory(): Open's
// proxy is the outermost interceptor (docs/plans/adblock-fork.md §7.1).
void MaybeProxyURLLoaderFactoryForAdBlock(
    content::BrowserContext* browser_context,
    content::RenderFrameHost* frame,
    int render_process_id,
    content::ContentBrowserClient::URLLoaderFactoryType type,
    const url::Origin& request_initiator,
    const net::IsolationInfo& isolation_info,
    network::URLLoaderFactoryBuilder& factory_builder);

// Start of ChromeContentBrowserClient::WillInterceptWebSocket(): true when
// the frame's Profile blocks ads (Chrome's own answer is OR-ed by the
// caller's original body).
bool WillInterceptWebSocket(content::RenderFrameHost* frame);

// Start of ChromeContentBrowserClient::CreateWebSocket(). Returns true when
// Open took the request (the arguments were moved; the caller returns at
// once). Allowed sockets come back through |client|->CreateWebSocket() with
// Open's check suspended for that nested call, or straight to |factory|.
bool InterceptCreateWebSocket(
    ChromeContentBrowserClient* client,
    content::RenderFrameHost* frame,
    content::ContentBrowserClient::WebSocketFactory& factory,
    const GURL& url,
    const net::SiteForCookies& site_for_cookies,
    const std::optional<std::string>& user_agent,
    mojo::PendingRemote<network::mojom::WebSocketHandshakeClient>&
        handshake_client,
    content::ContentBrowserClient::WebSocketOptions& options);

// Start of ChromeContentBrowserClient::WillCreateWebTransport(); same
// contract as InterceptCreateWebSocket().
bool InterceptWillCreateWebTransport(
    ChromeContentBrowserClient* client,
    int process_id,
    int frame_routing_id,
    const GURL& url,
    const url::Origin& initiator_origin,
    mojo::PendingRemote<network::mojom::WebTransportHandshakeClient>&
        handshake_client,
    content::ContentBrowserClient::WillCreateWebTransportCallback& callback);

// Start of ChromeContentBrowserClient::ExposeInterfacesToRenderer(): the
// cosmetics host (open_adblock.mojom) for the process's Profile.
void ExposeInterfacesToRenderer(
    service_manager::BinderRegistry* registry,
    content::RenderProcessHost* render_process_host);

// --- 0005: open:// WebUI ---------------------------------------------------

// RegisterChromeWebUIConfigs(): the seven open:// hosts.
void RegisterOpenWebUIConfigs();
// ChromeContentBrowserClient::BrowserURLHandlerCreated(): open://<host>
// <-> chrome://open-<host> rewrite (shown as open://, served as WebUI).
void AddOpenURLHandlers(content::BrowserURLHandler* handler);

// --- 0006: tab lifecycle ---------------------------------------------------

// TabLifecycleUnit::Discard(): false keeps Chromium (Memory Saver, memory
// pressure, chrome.tabs.discard) from discarding a tab that Open's own
// sleep policy keeps alive (keep-alive sites, Sleep mode Off, media,
// unsaved form input). Open's discards call WebContents::Discard() directly.
bool MayChromeDiscardTab(content::WebContents* web_contents);

// --- 0009: startup -----------------------------------------------------------

// End of ChromeBrowserMainParts::Create(): adds OpenBrowserMainExtraParts.
void AddBrowserMainExtraParts(ChromeBrowserMainParts* main_parts);

// --- 0010: tab helpers -------------------------------------------------------

// TabHelpers::AttachTabHelpers() for pages Open shows outside the tab strip
// (Peek, Little Open): JavaScript dialogs, permission prompts, autofill,
// find in page. tab_helpers.h declares this function a friend.
void AttachTabHelpers(content::WebContents* web_contents);

// --- 0011: external URLs, quit warning, dock reopen --------------------------

// StartupBrowserCreatorImpl::DetermineURLsAndLaunch() (command-line URLs,
// a second launch) and macOS -[AppController application:openURLs:]
// (|profile| null, |source_app_id| optional sender bundle id). True when Open
// took the URLs: Air Traffic Control places them (queued until
// OpenBrowserService::Start()); false for incognito/guest launches and before
// Open exists (Chromium opens them).
bool RouteExternalUrls(::Profile* profile,
                       const std::vector<GURL>& urls,
                       std::optional<std::string> source_app_id = std::nullopt);

// Start of -[AppController tryToTerminateApplication]: returns false to block
// termination (Warn Before Quitting confirmation or active Downloads guard).
bool ShouldTerminateApp();

// -[AppController applicationShouldHandleReopen:hasVisibleWindows:]: returns
// true when Open handled the Dock click (activating existing Open window or
// restoring saved window state).
bool HandleAppReopen(bool has_visible_windows);

// --- 0012: browser commands & reserved shortcuts -----------------------------

// True when |command_id| is in Open's custom menu command tag range
// [kOpenMenuCommandIdBase, kOpenMenuCommandIdMax].
bool IsOpenMenuCommand(int command_id);

// Availability check for custom Open menu commands in BrowserCommandController
// and AppController.
bool IsOpenMenuCommandEnabled(BrowserWindowInterface* browser, int command_id);

// True when |command_id| should be reserved ahead of web page keyboard
// handling in BrowserCommandController::IsReservedCommandOrKey().
bool IsReservedBrowserCommand(int command_id);

// Maps a CommandRegistry kebab-case id (e.g. "toggle-sidebar", "go-to-tab-1")
// to its stable menu command tag (kOpenMenuCommandIdBase + enum value), or 0
// if unknown. Used by global_keyboard_shortcuts_mac.mm and main_menu_builder.
int OpenCommandIdForMenuTag(std::string_view command_id);

// BrowserCommandController::ExecuteCommandWithDispositionAndContext() /
// HandleCommandWithDisposition() and AppController -commandDispatch:: true
// when Open handled |command_id| for |browser|'s window (shadowed IDC_*
// commands and Open custom menu tags).
bool HandleBrowserCommand(BrowserWindowInterface* browser, int command_id);

// --- 0013: macOS main menu bar -----------------------------------------------

// True when Open owns the macOS main menu bar and non-menu shortcut table
// (avoids unconditional early returns in patched Chromium functions).
bool UseOpenMacMenusAndShortcuts();

// BuildMainMenu() in chrome/browser/ui/cocoa/main_menu_builder.mm: returns the
// full Arc/Open top-level menu tree (Open, File, Edit, View, Spaces, Tabs,
// Archive, Extensions, Window, Help) with effective shortcuts from
// CommandRegistry.
std::vector<OpenMenuItemSpec> BuildOpenMainMenuSpec(
    const std::u16string& product_name);

// --- 0014: link interception, hover target URL & fullscreen ------------------

// Start of BrowserWebContentsDelegate::OpenURLFromTab(): true when Open
// intercepted the navigation (e.g. Shift+Click -> Peek, Opt+Cmd+Click ->
// Little Open, or cross-domain click from a Pinned/Favorite tab -> Peek).
bool MaybeInterceptLinkOpen(BrowserWindowInterface* browser,
                            content::WebContents* source,
                            const content::OpenURLParams& params);

// Start of BrowserWebContentsDelegate::AddNewContents(): true when Open
// adopted |new_contents| (moving it out of |new_contents|) into Peek, Little
// Open, or a Space tab.
bool MaybeInterceptAddNewContents(
    BrowserWindowInterface* browser,
    content::WebContents* source,
    std::unique_ptr<content::WebContents>& new_contents,
    const GURL& target_url,
    WindowOpenDisposition disposition,
    bool user_gesture);

// Start of BrowserWebContentsDelegate::UpdateTargetURL(): notifies Open to
// update its Link Hover URL pill (LinkStatusBubble).
void OnUpdateTargetURL(BrowserWindowInterface* browser,
                       content::WebContents* source,
                       const GURL& url);

// End of BrowserView::FullscreenStateChanged(): notifies Open so HTML5/tab
// fullscreen collapses the sidebar and bezel full-bleed.
void OnFullscreenStateChanged(BrowserView* browser_view);

// --- 0015: web context menu & bubble anchoring -------------------------------

// End of RenderViewContextMenu::InitMenu() (before AppendReadWriteCardItems):
// inserts Open's link, selection, and page context menu items into |menu_model|.
void AppendWebContextMenuItems(BrowserWindowInterface* browser,
                               content::WebContents* source,
                               const content::ContextMenuParams& params,
                               ui::SimpleMenuModel* menu_model);

// Start of RenderViewContextMenu::IsCommandIdEnabled(): returns enabled state
// for Open context menu command IDs, or std::nullopt for non-Open commands.
std::optional<bool> IsWebContextMenuCommandEnabled(
    BrowserWindowInterface* browser,
    content::WebContents* source,
    const content::ContextMenuParams& params,
    int command_id);

// Start of RenderViewContextMenu::ExecuteCommand(): returns true when Open
// executed an Open context menu command ID.
bool ExecuteWebContextMenuCommand(BrowserWindowInterface* browser,
                                  content::WebContents* source,
                                  const content::ContextMenuParams& params,
                                  int command_id,
                                  int event_flags);

// Start of bubble_anchor_util::GetPageInfoAnchorConfiguration() and
// ToolbarView::GetBubbleAnchor(): returns an on-screen anchor view inside
// OpenBrowserView so Chromium permission prompts, password save prompts, and
// extension dialogs anchor cleanly inside Open's window instead of top-left.
views::View* GetBubbleAnchorView(BrowserWindowInterface* browser);

// Start of bubble_anchor_util::GetPageInfoAnchorRect(): returns a screen-space
// fallback anchor rect inside OpenBrowserView when no View anchor is used.
std::optional<gfx::Rect> GetBubbleAnchorRect(BrowserWindowInterface* browser);

}  // namespace open_unified::hooks

#endif  // OPEN_UNIFIED_BROWSER_OPEN_CHROMIUM_HOOKS_H_
