// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// The only Open header that patched Chromium files include (always with
// `// nogncheck`: //chrome does not depend on //open_unified in GN; the
// symbols resolve at link time through //chrome:dependencies, hook 0001).
// Each function names the hook (Unified/patches/chromium/series) that calls
// it. Keep this header small and free of Open model types, so a Chromium
// rebuild after an Open change recompiles only the hooked files.

#ifndef OPEN_UNIFIED_BROWSER_OPEN_CHROMIUM_HOOKS_H_
#define OPEN_UNIFIED_BROWSER_OPEN_CHROMIUM_HOOKS_H_

#include <memory>
#include <optional>
#include <string>

#include "content/public/browser/content_browser_client.h"
#include "mojo/public/cpp/bindings/pending_remote.h"
#include "services/network/public/mojom/web_transport.mojom-forward.h"
#include "services/network/public/mojom/websocket.mojom-forward.h"
#include "services/service_manager/public/cpp/binder_registry.h"
#include "ui/views/widget/widget.h"

class BrowserView;
class ChromeBrowserMainParts;
class ChromeContentBrowserClient;
class GURL;

namespace content {
class BrowserContext;
class BrowserURLHandler;
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
namespace url {
class Origin;
}

namespace open_unified::hooks {

// --- 0002: Open browser chrome in BrowserView / BrowserWidget -------------

// End of BrowserView::AddedToWidget() (first time only). Installs
// OpenBrowserView for normal browser windows.
void OnBrowserViewAddedToWidget(BrowserView* browser_view);
// Start of BrowserView::~BrowserView().
void OnBrowserViewDestroying(BrowserView* browser_view);
// BrowserWidget::InitBrowserWidget(), after the delegate is set: Open's
// frameless, translucent, rounded window (when OpenBrowserView wants it).
void AdjustBrowserWidgetParams(BrowserView* browser_view,
                               views::Widget::InitParams* params);
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

}  // namespace open_unified::hooks

#endif  // OPEN_UNIFIED_BROWSER_OPEN_CHROMIUM_HOOKS_H_
