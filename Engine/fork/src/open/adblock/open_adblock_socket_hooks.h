// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef OPEN_ADBLOCK_OPEN_ADBLOCK_SOCKET_HOOKS_H_
#define OPEN_ADBLOCK_OPEN_ADBLOCK_SOCKET_HOOKS_H_

#include <optional>
#include <string>

#include "base/functional/callback.h"
#include "content/public/browser/content_browser_client.h"
#include "mojo/public/cpp/bindings/pending_remote.h"
#include "services/network/public/mojom/web_transport.mojom.h"
#include "services/network/public/mojom/websocket.mojom.h"
#include "url/gurl.h"
#include "url/origin.h"

namespace content {
class RenderFrameHost;
}
namespace net {
class SiteForCookies;
}

namespace open_engine {

class OpenAdBlockService;

// Sockets of frames (adblock-fork §7.1 hunk 3; workers' sockets have no
// frame and are a known gap). Called on the UI thread from patch P-3. Each
// check runs on the matcher sequence and replies to the UI thread; the
// frame is looked up again there by its id, and a frame that is gone starts
// no socket.

// |service| is the Profile's of |frame| (null when it has none). True when
// it blocks ads and the frame's top site is not excluded.
bool AdBlockWantsWebSocket(OpenAdBlockService* service,
                           content::RenderFrameHost* frame);

// Runs Chrome's own CreateWebSocket with the same arguments.
using AdBlockChromeWebSocket = base::OnceCallback<void(
    content::RenderFrameHost*,
    content::ContentBrowserClient::WebSocketFactory,
    const GURL&,
    const net::SiteForCookies&,
    const std::optional<std::string>&,
    mojo::PendingRemote<network::mojom::WebSocketHandshakeClient>,
    content::ContentBrowserClient::WebSocketOptions)>;

// Blocked: the handshake client gets OnFailure(net::ERR_BLOCKED_BY_CLIENT)
// and |factory| is dropped. Allowed: Chrome's CreateWebSocket when
// |chrome_intercepts|, else |factory| runs as content's own path does.
void AdBlockCreateWebSocket(
    OpenAdBlockService* service,
    content::RenderFrameHost* frame,
    bool chrome_intercepts,
    content::ContentBrowserClient::WebSocketFactory factory,
    const GURL& url,
    const net::SiteForCookies& site_for_cookies,
    const std::optional<std::string>& user_agent,
    mojo::PendingRemote<network::mojom::WebSocketHandshakeClient>
        handshake_client,
    content::ContentBrowserClient::WebSocketOptions options,
    AdBlockChromeWebSocket chrome);

// Runs Chrome's own WillCreateWebTransport with the same arguments.
using AdBlockChromeWebTransport = base::OnceCallback<void(
    int,
    int,
    const GURL&,
    const url::Origin&,
    mojo::PendingRemote<network::mojom::WebTransportHandshakeClient>,
    content::ContentBrowserClient::WillCreateWebTransportCallback)>;

// Blocked: |callback| gets net::ERR_BLOCKED_BY_CLIENT. Allowed: Chrome's.
void AdBlockWillCreateWebTransport(
    OpenAdBlockService* service,
    int process_id,
    int frame_routing_id,
    const GURL& url,
    const url::Origin& initiator_origin,
    mojo::PendingRemote<network::mojom::WebTransportHandshakeClient>
        handshake_client,
    content::ContentBrowserClient::WillCreateWebTransportCallback callback,
    AdBlockChromeWebTransport chrome);

}  // namespace open_engine

#endif  // OPEN_ADBLOCK_OPEN_ADBLOCK_SOCKET_HOOKS_H_
