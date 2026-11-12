// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef OPEN_ADBLOCK_OPEN_ADBLOCK_URL_LOADER_FACTORY_H_
#define OPEN_ADBLOCK_OPEN_ADBLOCK_URL_LOADER_FACTORY_H_

#include <memory>
#include <set>
#include <string>

#include "base/containers/unique_ptr_adapters.h"
#include "base/memory/scoped_refptr.h"
#include "base/memory/weak_ptr.h"
#include "base/sequence_checker.h"
#include "base/time/time.h"
#include "base/timer/timer.h"
#include "content/public/browser/content_browser_client.h"
#include "content/public/browser/weak_document_ptr.h"
#include "mojo/public/cpp/bindings/pending_receiver.h"
#include "mojo/public/cpp/bindings/pending_remote.h"
#include "mojo/public/cpp/bindings/receiver_set.h"
#include "mojo/public/cpp/bindings/remote.h"
#include "open/adblock/open_adblock_matcher.h"
#include "open/adblock/open_adblock_types.h"
#include "services/network/public/mojom/url_loader_factory.mojom.h"
#include "url/origin.h"
#include "url/gurl.h"

namespace open_engine {

class OpenAdBlockURLLoader;

// Context of one wrapped factory, captured on the UI thread (adblock-fork
// §7.2) and immutable afterwards.
struct AdBlockFactoryContext {
  AdBlockFactoryContext();
  AdBlockFactoryContext(AdBlockFactoryContext&&);
  AdBlockFactoryContext& operator=(AdBlockFactoryContext&&);
  ~AdBlockFactoryContext();

  scoped_refptr<OpenAdBlockMatcher> matcher;
  content::ContentBrowserClient::URLLoaderFactoryType type =
      content::ContentBrowserClient::URLLoaderFactoryType::kDocumentSubResource;
  url::Origin initiator;
  // Parsed once per factory, rather than rebuilding the same source URL
  // for every subresource. Requests with another initiator still use it.
  GURL initiator_url;
  // The top frame's host (§7.2's top site). The full host, not only its
  // registrable domain, so an exclusion of a subdomain matches (§6.7).
  std::string top_host;
  bool subframe_navigation = false;
  // A main-frame navigation: only $removeparam applies (§7.4 rule 4); main
  // frames are never blocked. Exclusions use each request's own host.
  bool main_frame_navigation = false;
  // The document that counts this factory's stops. Frameless factories
  // (shared and service workers) have none and do not count (§7.5).
  content::WeakDocumentPtr document;
  bool has_document = false;
};

// G-4 (§7.8): one process-wide histogram of the time from a request's
// arrival in a proxy to its forward. Log-scale buckets from 1 µs to 100 ms,
// relaxed atomic counters, no locks. Any thread.
void RecordAdBlockRequestLatency(base::TimeDelta latency);
// "G-4 request latency (upper bucket bounds, us): n=… p50<=… p99<=… max<=…
// buckets: …", for logs.
std::string AdBlockLatencyHistogramText();
// G-5 (§7.8): the time the matcher sequence spent in proxies and loaders
// (checks included) since the process started. Any thread.
uint64_t AdBlockMatcherBusyMicroseconds();
// The same as thread CPU time; 0 in official builds.
uint64_t AdBlockMatcherBusyCpuMicroseconds();
// Non-official in-process CPU breakdown; source/check are request subsets.
std::string AdBlockProxyProfileText();

// The proxy of one URLLoaderFactory (§7.4, §7.5). Lives on the matcher
// sequence, owns its loaders, and deletes itself when its receivers are gone
// (or the target is) and no loader is left.
class OpenAdBlockURLLoaderFactory : public network::mojom::URLLoaderFactory {
 public:
  // Matcher sequence.
  static void Bind(
      mojo::PendingReceiver<network::mojom::URLLoaderFactory> receiver,
      mojo::PendingRemote<network::mojom::URLLoaderFactory> target,
      AdBlockFactoryContext context);

  OpenAdBlockURLLoaderFactory(const OpenAdBlockURLLoaderFactory&) = delete;
  OpenAdBlockURLLoaderFactory& operator=(const OpenAdBlockURLLoaderFactory&) =
      delete;

  // network::mojom::URLLoaderFactory:
  void CreateLoaderAndStart(
      mojo::PendingReceiver<network::mojom::URLLoader> receiver,
      int32_t request_id,
      uint32_t options,
      const network::ResourceRequest& request,
      mojo::PendingRemote<network::mojom::URLLoaderClient> client,
      const net::MutableNetworkTrafficAnnotationTag& annotation) override;
  void Clone(mojo::PendingReceiver<network::mojom::URLLoaderFactory> receiver)
      override;

  // For its loaders.
  const AdBlockFactoryContext& context() const { return context_; }
  network::mojom::URLLoaderFactory* target() { return target_.get(); }
  void AddStop(AdBlockStopKind kind);
  // Destroys |loader|; it must not be used afterwards.
  void RemoveLoader(OpenAdBlockURLLoader* loader);

 private:
  OpenAdBlockURLLoaderFactory(
      mojo::PendingReceiver<network::mojom::URLLoaderFactory> receiver,
      mojo::PendingRemote<network::mojom::URLLoaderFactory> target,
      AdBlockFactoryContext context);
  ~OpenAdBlockURLLoaderFactory() override;

  void OnReceiverDisconnect();
  void OnTargetDisconnect();
  void MaybeDeleteSelf();
  void FlushStops();
  struct ColdRequest;
  void ResumeColdRequest(std::unique_ptr<ColdRequest> request, bool fail_open);
  void StartRequest(
      mojo::PendingReceiver<network::mojom::URLLoader> receiver,
      int32_t request_id,
      uint32_t options,
      const network::ResourceRequest& request,
      mojo::PendingRemote<network::mojom::URLLoaderClient> client,
      const net::MutableNetworkTrafficAnnotationTag& annotation,
      base::TimeTicks arrival,
      bool fail_open);
  // A main-frame navigation request: a $removeparam rewrite or a direct
  // pass-through (no loader, no extra hop for the response).
  void StartMainFrameRequest(
      mojo::PendingReceiver<network::mojom::URLLoader> receiver,
      int32_t request_id,
      uint32_t options,
      const network::ResourceRequest& request,
      mojo::PendingRemote<network::mojom::URLLoaderClient> client,
      const net::MutableNetworkTrafficAnnotationTag& annotation,
      base::TimeTicks arrival,
      bool fail_open);

  SEQUENCE_CHECKER(sequence_checker_);
  mojo::ReceiverSet<network::mojom::URLLoaderFactory> receivers_;
  mojo::Remote<network::mojom::URLLoaderFactory> target_;
  const AdBlockFactoryContext context_;
  std::set<std::unique_ptr<OpenAdBlockURLLoader>, base::UniquePtrComparator>
      loaders_;
  int pending_blocked_ = 0;
  int pending_redirected_ = 0;
  // Runs only while counts wait (no timer while idle).
  base::OneShotTimer flush_timer_;
  size_t cold_pending_ = 0;
  base::WeakPtrFactory<OpenAdBlockURLLoaderFactory> weak_ptr_factory_{this};
};

}  // namespace open_engine

#endif  // OPEN_ADBLOCK_OPEN_ADBLOCK_URL_LOADER_FACTORY_H_
