// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef OPEN_ADBLOCK_OPEN_ADBLOCK_HOOKS_H_
#define OPEN_ADBLOCK_OPEN_ADBLOCK_HOOKS_H_

#include "content/public/browser/content_browser_client.h"
#include "open/adblock/open_adblock_socket_hooks.h"

namespace content {
class RenderFrameHost;
}
namespace net {
class IsolationInfo;
}
namespace network {
class URLLoaderFactoryBuilder;
}
namespace url {
class Origin;
}

namespace open_engine {

class OpenAdBlockService;

// adblock-fork §7.1 hunk 1 (patch P-3): called on the UI thread from
// WillCreateURLLoaderFactory, before Chrome's own interceptors, so Open's
// proxy is the outermost one. |service| is the Profile's (null when it has
// none; the hunk finds it, because //open/adblock does not depend on //cef).
// Appends a proxy to |factory_builder| for the factories of §7.2 when the
// Profile blocks ads and the top site is not excluded; else does nothing
// (no cost for that factory).
void MaybeProxyURLLoaderFactoryForAdBlock(
    OpenAdBlockService* service,
    content::RenderFrameHost* frame,
    int render_process_id,
    content::ContentBrowserClient::URLLoaderFactoryType type,
    const url::Origin& request_initiator,
    const net::IsolationInfo& isolation_info,
    network::URLLoaderFactoryBuilder& factory_builder);

}  // namespace open_engine

#endif  // OPEN_ADBLOCK_OPEN_ADBLOCK_HOOKS_H_
