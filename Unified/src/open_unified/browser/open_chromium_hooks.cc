// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "open_unified/browser/open_chromium_hooks.h"

#include <utility>

#include "base/auto_reset.h"
#include "base/functional/bind.h"
#include "base/functional/callback_helpers.h"
#include "build/build_config.h"
#include "chrome/app/chrome_command_ids.h"
#include "chrome/browser/chrome_browser_main.h"
#include "chrome/browser/chrome_content_browser_client.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/tab_helpers.h"
#include "chrome/browser/ui/views/frame/browser_view.h"
#include "content/public/browser/browser_thread.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/render_process_host.h"
#include "content/public/browser/web_contents.h"
#include "ui/base/hit_test.h"
#include "ui/gfx/geometry/point.h"
#include "ui/views/view_utils.h"
#include "url/gurl.h"
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

namespace open_unified::hooks {

namespace {

// UI thread only. Set while Open re-enters Chrome's own socket path, so the
// nested call takes Chrome's original branch.
bool g_socket_passthrough = false;

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

}  // namespace

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

bool RouteExternalUrls(::Profile* profile, const std::vector<GURL>& urls) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  OpenBrowserService* service = OpenBrowserService::Get();
  if (!service || urls.empty()) {
    return false;
  }
  // Incognito and guest launches keep Chromium's own windows.
  if (profile && (profile->IsOffTheRecord() || profile->IsGuestSession())) {
    return false;
  }
  service->RouteExternalUrls(urls);
  return true;
}

// --- 0012 -------------------------------------------------------------------

bool HandleBrowserCommand(BrowserWindowInterface* browser, int command_id) {
  CommandId command;
  switch (command_id) {
    case IDC_FIND:
      command = CommandId::kFind;
      break;
    case IDC_FIND_NEXT:
      command = CommandId::kFindNext;
      break;
    case IDC_FIND_PREVIOUS:
      command = CommandId::kFindPrevious;
      break;
    default:
      return false;
  }
  OpenBrowserService* service = OpenBrowserService::Get();
  OpenWindowController* windows =
      service ? service->window_controller() : nullptr;
  BrowserView* browser_view =
      browser ? BrowserView::GetBrowserViewForBrowser(browser) : nullptr;
  OpenWindowUi* ui =
      windows && browser_view ? windows->WindowUiForBrowserView(browser_view)
                              : nullptr;
  return ui && ui->HandleFindCommand(command);
}

}  // namespace open_unified::hooks
