// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "open/adblock/open_adblock_hooks.h"

#include <string>
#include <utility>
#include <vector>

#include "base/functional/bind.h"
#include "base/logging.h"
#include "base/task/bind_post_task.h"
#include "base/task/task_runner.h"
#include "content/public/browser/browser_thread.h"
#include "content/public/browser/global_routing_id.h"
#include "content/public/browser/page.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/web_contents.h"
#include "mojo/public/cpp/bindings/remote.h"
#include "net/base/isolation_info.h"
#include "net/base/net_errors.h"
#include "net/cookies/site_for_cookies.h"
#include "net/http/http_request_headers.h"
#include "open/adblock/open_adblock_matcher.h"
#include "open/adblock/open_adblock_service.h"
#include "open/adblock/open_adblock_tab_helper.h"
#include "open/adblock/open_adblock_url_loader_factory.h"
#include "services/network/public/cpp/url_loader_factory_builder.h"
#include "services/network/public/mojom/websocket.mojom.h"
#include "url/origin.h"

namespace open_engine {

namespace {

using FactoryType = content::ContentBrowserClient::URLLoaderFactoryType;

constexpr char kBlockedMessage[] = "Blocked by Open's ad blocker";

std::string HostOf(const url::Origin& origin) {
  return origin.opaque() ? std::string() : std::string(origin.host());
}

// The top frame's host of a frame-bearing hook.
std::string TopHostOf(content::RenderFrameHost* frame) {
  return HostOf(frame->GetOutermostMainFrame()->GetLastCommittedOrigin());
}

// |service| when it blocks ads on |frame|'s top site, else null.
OpenAdBlockService* ActiveServiceFor(OpenAdBlockService* service,
                                     content::RenderFrameHost* frame) {
  if (!frame || !service || !service->IsEnabled() ||
      service->IsExcludedOnUi(TopHostOf(frame))) {
    return nullptr;
  }
  return service;
}

// Matcher sequence, including the bounded first-load wait. The reply retains
// the existing UI/frame-liveness path; holding adds no UI work per request.
void CheckSocket(scoped_refptr<OpenAdBlockMatcher> matcher,
                 GURL url,
                 GURL source,
                 std::string top_host,
                 open_adblock::OpenRequestType type,
                 base::TimeTicks request_start,
                 base::OnceCallback<void(bool)> reply) {
  auto check = base::BindOnce(
      [](scoped_refptr<OpenAdBlockMatcher> matcher, GURL url, GURL source,
         std::string top_host, open_adblock::OpenRequestType type,
         base::OnceCallback<void(bool)> reply, bool fail_open) {
        const bool blocked = !fail_open && matcher->IsActiveFor(top_host) &&
            matcher->Check(url, source, type, kOpenAdBlockMatchCapBytes).matched;
        std::move(reply).Run(blocked);
      },
      matcher, std::move(url), std::move(source), top_host, type,
      std::move(reply));
  if (matcher->NeedsFirstEngineHold(top_host)) {
    matcher->HoldForFirstEngine(std::move(top_host), request_start,
                                std::move(check));
  } else {
    std::move(check).Run(false);
  }
}

void CountSocketBlock(content::RenderFrameHost* frame, const char* kind) {
  VLOG(1) << "OpenAdBlock: blocked a " << kind;
  if (frame->GetPage().IsPrimary()) {
    if (auto* web_contents = content::WebContents::FromRenderFrameHost(frame)) {
      OpenAdBlockTabHelper::GetOrCreate(web_contents)->AddStops(1, 0);
    }
  }
}

// What content does when no embedder intercepts the socket
// (websocket_connector_impl.cc): only a User-Agent header, no
// authentication handler, and the header client of |options|.
void RunContentWebSocket(
    content::ContentBrowserClient::WebSocketFactory factory,
    const GURL& url,
    const std::optional<std::string>& user_agent,
    mojo::PendingRemote<network::mojom::WebSocketHandshakeClient>
        handshake_client,
    content::ContentBrowserClient::WebSocketOptions options) {
  std::vector<network::mojom::HttpHeaderPtr> additional_headers;
  if (user_agent) {
    additional_headers.push_back(network::mojom::HttpHeader::New(
        net::HttpRequestHeaders::kUserAgent, *user_agent));
  }
  std::move(factory).Run(url, std::move(additional_headers),
                         std::move(handshake_client), mojo::NullRemote(),
                         std::move(options.header_client));
}

void OnWebSocketChecked(
    content::GlobalRenderFrameHostId frame_id,
    bool chrome_intercepts,
    content::ContentBrowserClient::WebSocketFactory factory,
    GURL url,
    net::SiteForCookies site_for_cookies,
    std::optional<std::string> user_agent,
    mojo::PendingRemote<network::mojom::WebSocketHandshakeClient>
        handshake_client,
    content::ContentBrowserClient::WebSocketOptions options,
    AdBlockChromeWebSocket chrome,
    bool blocked) {
  content::RenderFrameHost* frame = content::RenderFrameHost::FromID(frame_id);
  if (!frame) {
    // The frame that asked is gone: no socket may start for it.
    return;
  }
  if (blocked) {
    mojo::Remote<network::mojom::WebSocketHandshakeClient> client(
        std::move(handshake_client));
    client->OnFailure(kBlockedMessage, net::ERR_BLOCKED_BY_CLIENT, 0);
    CountSocketBlock(frame, "WebSocket");
    return;
  }
  if (chrome_intercepts) {
    std::move(chrome).Run(frame, std::move(factory), url, site_for_cookies,
                          user_agent, std::move(handshake_client),
                          std::move(options));
    return;
  }
  RunContentWebSocket(std::move(factory), url, user_agent,
                      std::move(handshake_client), std::move(options));
}

void OnWebTransportChecked(
    int process_id,
    int frame_routing_id,
    GURL url,
    url::Origin initiator_origin,
    mojo::PendingRemote<network::mojom::WebTransportHandshakeClient>
        handshake_client,
    content::ContentBrowserClient::WillCreateWebTransportCallback callback,
    AdBlockChromeWebTransport chrome,
    bool blocked) {
  content::RenderFrameHost* frame =
      content::RenderFrameHost::FromID(process_id, frame_routing_id);
  if (!frame) {
    return;
  }
  if (blocked) {
    CountSocketBlock(frame, "WebTransport");
    std::move(callback).Run(
        std::move(handshake_client),
        network::mojom::WebTransportError::New(net::ERR_BLOCKED_BY_CLIENT, 0,
                                               kBlockedMessage, false));
    return;
  }
  std::move(chrome).Run(process_id, frame_routing_id, url, initiator_origin,
                        std::move(handshake_client), std::move(callback));
}

}  // namespace

void MaybeProxyURLLoaderFactoryForAdBlock(
    OpenAdBlockService* service,
    content::RenderFrameHost* frame,
    int render_process_id,
    content::ContentBrowserClient::URLLoaderFactoryType type,
    const url::Origin& request_initiator,
    const net::IsolationInfo& isolation_info,
    network::URLLoaderFactoryBuilder& factory_builder) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (!service) {
    return;
  }
  // Track documents even while disabled or on a zero-list generation. Those
  // pages may populate MemoryCache before blocking is turned back on.
  if (type == FactoryType::kDocumentSubResource) {
    service->OnDocumentFactoryCreated();
  }
  // §7.2 rule 1 and 2: a Profile with a service that blocks ads.
  if (!service->IsEnabled()) {
    return;
  }
  // The tab's counts exist before its first stop, so a page with none (or
  // on an excluded site) still reports 0 and resets on navigation (§7.5).
  if (frame) {
    if (auto* web_contents = content::WebContents::FromRenderFrameHost(frame)) {
      OpenAdBlockTabHelper::GetOrCreate(web_contents);
    }
  }
  // §7.2 rule 3: the factory types that are proxied.
  bool subframe_navigation = false;
  bool main_frame_navigation = false;
  switch (type) {
    case FactoryType::kDocumentSubResource:
    case FactoryType::kWorkerSubResource:
    case FactoryType::kServiceWorkerSubResource:
    case FactoryType::kWorkerMainResource:
    case FactoryType::kServiceWorkerScript:
      break;
    case FactoryType::kNavigation:
      // Main frames are never blocked; their factory only applies
      // $removeparam (§7.4 rule 4) and passes every other request on.
      if (!frame || !frame->GetParentOrOuterDocument()) {
        main_frame_navigation = true;
      } else {
        subframe_navigation = true;
      }
      break;
    default:
      return;
  }
  // §7.2 rule 4: an extension's, WebUI's or DevTools' own traffic.
  if (!request_initiator.opaque() &&
      !request_initiator.GetURL().SchemeIsHTTPOrHTTPS()) {
    return;
  }
  // §7.2: the top site, from the first source that exists.
  std::string top_host;
  if (isolation_info.top_frame_origin() &&
      !isolation_info.top_frame_origin()->opaque()) {
    top_host = HostOf(*isolation_info.top_frame_origin());
  } else if (frame) {
    top_host = TopHostOf(frame);
  } else {
    top_host = HostOf(request_initiator);
  }
  // A main-frame navigation's site is its URL, which can change on redirect;
  // the factory checks each request's host instead.
  if (!main_frame_navigation && service->IsExcludedOnUi(top_host)) {
    return;
  }

  AdBlockFactoryContext context;
  context.matcher = service->matcher();
  context.type = type;
  context.initiator = request_initiator;
  if (!request_initiator.opaque()) {
    context.initiator_url = request_initiator.GetURL();
  }
  context.top_host = std::move(top_host);
  context.subframe_navigation = subframe_navigation;
  context.main_frame_navigation = main_frame_navigation;
  // Rewrites are not counted, so a main-frame factory has no document.
  if (frame && !main_frame_navigation) {
    // A subframe navigation counts for the page that holds the frame.
    content::RenderFrameHost* counting =
        subframe_navigation ? frame->GetParentOrOuterDocument() : frame;
    context.document = counting->GetWeakDocumentPtr();
    context.has_document = true;
  }
  auto [receiver, remote] = factory_builder.Append();
  // Requests sent before the bind wait in the pipe.
  AdBlockMatcherTaskRunner()->PostTask(
      FROM_HERE, base::BindOnce(&OpenAdBlockURLLoaderFactory::Bind,
                                std::move(receiver), std::move(remote),
                                std::move(context)));
}

bool AdBlockWantsWebSocket(OpenAdBlockService* service,
                           content::RenderFrameHost* frame) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  return ActiveServiceFor(service, frame) != nullptr;
}

void AdBlockCreateWebSocket(
    OpenAdBlockService* active_service,
    content::RenderFrameHost* frame,
    bool chrome_intercepts,
    content::ContentBrowserClient::WebSocketFactory factory,
    const GURL& url,
    const net::SiteForCookies& site_for_cookies,
    const std::optional<std::string>& user_agent,
    mojo::PendingRemote<network::mojom::WebSocketHandshakeClient>
        handshake_client,
    content::ContentBrowserClient::WebSocketOptions options,
    AdBlockChromeWebSocket chrome) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  const auto request_start = base::TimeTicks::Now();
  OpenAdBlockService* service = ActiveServiceFor(active_service, frame);
  if (!service) {
    if (chrome_intercepts) {
      std::move(chrome).Run(frame, std::move(factory), url, site_for_cookies,
                            user_agent, std::move(handshake_client),
                            std::move(options));
    } else {
      RunContentWebSocket(std::move(factory), url, user_agent,
                          std::move(handshake_client), std::move(options));
    }
    return;
  }
  auto reply = base::BindPostTask(
      content::GetUIThreadTaskRunner({}),
      base::BindOnce(&OnWebSocketChecked, frame->GetGlobalId(), chrome_intercepts,
                     std::move(factory), url, site_for_cookies, user_agent,
                     std::move(handshake_client), std::move(options),
                     std::move(chrome)));
  AdBlockMatcherTaskRunner()->PostTask(
      FROM_HERE,
      base::BindOnce(&CheckSocket, service->matcher(), url,
                     frame->GetLastCommittedOrigin().GetURL(), TopHostOf(frame),
                     open_adblock::OpenRequestType::Websocket, request_start,
                     std::move(reply)));
}

void AdBlockWillCreateWebTransport(
    OpenAdBlockService* active_service,
    int process_id,
    int frame_routing_id,
    const GURL& url,
    const url::Origin& initiator_origin,
    mojo::PendingRemote<network::mojom::WebTransportHandshakeClient>
        handshake_client,
    content::ContentBrowserClient::WillCreateWebTransportCallback callback,
    AdBlockChromeWebTransport chrome) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  const auto request_start = base::TimeTicks::Now();
  content::RenderFrameHost* frame =
      content::RenderFrameHost::FromID(process_id, frame_routing_id);
  OpenAdBlockService* service = ActiveServiceFor(active_service, frame);
  if (!service) {
    std::move(chrome).Run(process_id, frame_routing_id, url, initiator_origin,
                          std::move(handshake_client), std::move(callback));
    return;
  }
  auto reply = base::BindPostTask(
      content::GetUIThreadTaskRunner({}),
      base::BindOnce(&OnWebTransportChecked, process_id, frame_routing_id, url,
                     initiator_origin, std::move(handshake_client),
                     std::move(callback), std::move(chrome)));
  AdBlockMatcherTaskRunner()->PostTask(
      FROM_HERE,
      base::BindOnce(&CheckSocket, service->matcher(), url,
                     initiator_origin.GetURL(), TopHostOf(frame),
                     open_adblock::OpenRequestType::Other, request_start,
                     std::move(reply)));
}

}  // namespace open_engine
