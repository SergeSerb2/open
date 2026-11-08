// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "open/adblock/open_adblock_url_loader_factory.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <optional>
#include <string_view>
#include <utility>

#include "base/byte_size.h"
#include "base/functional/bind.h"
#include "base/memory/raw_ptr.h"
#include "base/logging.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/stringprintf.h"
#include "content/public/browser/browser_task_traits.h"
#include "content/public/browser/browser_thread.h"
#include "mojo/public/cpp/bindings/receiver.h"
#include "mojo/public/cpp/bindings/pending_receiver.h"
#include "mojo/public/cpp/system/data_pipe.h"
#include "net/base/data_url.h"
#include "net/base/net_errors.h"
#include "net/http/http_response_headers.h"
#include "net/http/http_status_code.h"
#include "net/http/http_util.h"
#include "net/url_request/redirect_info.h"
#include "open/adblock/open_adblock_tab_helper.h"
#include "services/network/public/cpp/resource_request.h"
#include "services/network/public/cpp/url_loader_completion_status.h"
#include "services/network/public/mojom/early_hints.mojom.h"
#include "services/network/public/mojom/fetch_api.mojom-shared.h"
#include "services/network/public/mojom/url_loader.mojom.h"
#include "services/network/public/mojom/url_response_head.mojom.h"
#include "url/gurl.h"

namespace open_engine {

namespace {

using FactoryType = content::ContentBrowserClient::URLLoaderFactoryType;
using open_adblock::OpenRequestType;
using network::mojom::RequestDestination;

// §7.4 rule 3: the largest stub body served from a $redirect resource.
constexpr size_t kMaxStubBytes = 1024 * 1024;

// The longest list CSP added to one response. Real $csp values are well
// under 1 KiB; the joined value of every matching rule is still far below
// this.
constexpr size_t kMaxListCspBytes = 8 * 1024;

// --- G-4 histogram (§7.8) ------------------------------------------------

// Bucket i holds latencies in [2^(i-1), 2^i) µs; bucket 0 is < 1 µs. 2^17 µs
// is about 131 ms, past the 100 ms the plan asks for.
constexpr size_t kLatencyBuckets = 18;
std::array<std::atomic<uint64_t>, kLatencyBuckets>& LatencyBuckets() {
  static std::array<std::atomic<uint64_t>, kLatencyBuckets> buckets{};
  return buckets;
}

// G-5 (§7.8): the matcher sequence's time in proxies and loaders, summed over
// the process: wall time, and (non-official builds) the thread's CPU time,
// which leaves out the time the thread waited for a core.
std::atomic<uint64_t>& BusyNanoseconds() {
  static std::atomic<uint64_t> nanoseconds{0};
  return nanoseconds;
}
std::atomic<uint64_t>& BusyCpuNanoseconds() {
  static std::atomic<uint64_t> nanoseconds{0};
  return nanoseconds;
}

enum class CpuPart { kRequest, kCallback, kRedirect, kSource, kCheck, kCount };
std::array<std::atomic<uint64_t>, static_cast<size_t>(CpuPart::kCount)>&
CpuParts() {
  static std::array<std::atomic<uint64_t>,
                    static_cast<size_t>(CpuPart::kCount)> parts{};
  return parts;
}

class CpuPartScope {
 public:
  explicit CpuPartScope(CpuPart part) : part_(part) {
#if !defined(OFFICIAL_BUILD)
    start_ = base::ThreadTicks::Now();
#endif
  }
  ~CpuPartScope() {
#if !defined(OFFICIAL_BUILD)
    CpuParts()[static_cast<size_t>(part_)].fetch_add(
        (base::ThreadTicks::Now() - start_).InNanoseconds(),
        std::memory_order_relaxed);
#endif
  }

 private:
  [[maybe_unused]] const CpuPart part_;
#if !defined(OFFICIAL_BUILD)
  base::ThreadTicks start_;
#endif
};

// Adds its own lifetime to the busy counters. Safe in methods that destroy
// their object: it touches only the stack.
class BusyScope {
 public:
  explicit BusyScope(CpuPart part = CpuPart::kCallback)
      : start_(base::TimeTicks::Now()), part_(part) {
#if !defined(OFFICIAL_BUILD)
    start_cpu_ = base::ThreadTicks::Now();
#endif
  }
  BusyScope(const BusyScope&) = delete;
  BusyScope& operator=(const BusyScope&) = delete;
  ~BusyScope() {
    BusyNanoseconds().fetch_add(
        static_cast<uint64_t>((base::TimeTicks::Now() - start_).InNanoseconds()),
        std::memory_order_relaxed);
#if !defined(OFFICIAL_BUILD)
    const uint64_t cpu_ns = static_cast<uint64_t>(
        (base::ThreadTicks::Now() - start_cpu_).InNanoseconds());
    BusyCpuNanoseconds().fetch_add(cpu_ns, std::memory_order_relaxed);
    CpuParts()[static_cast<size_t>(part_)].fetch_add(
        cpu_ns, std::memory_order_relaxed);
#endif
  }

 private:
  const base::TimeTicks start_;
  [[maybe_unused]] const CpuPart part_;
#if !defined(OFFICIAL_BUILD)
  base::ThreadTicks start_cpu_;
#endif
};

// --- Request mapping (§7.3) ----------------------------------------------

OpenRequestType RequestTypeOf(const network::ResourceRequest& request) {
  if (request.is_fetch_like_api) {
    return OpenRequestType::Xmlhttprequest;
  }
  if (request.keepalive && request.destination == RequestDestination::kEmpty) {
    return OpenRequestType::Ping;
  }
  switch (request.destination) {
    case RequestDestination::kIframe:
    case RequestDestination::kFrame:
    case RequestDestination::kFencedframe:
      return OpenRequestType::Subdocument;
    case RequestDestination::kScript:
    case RequestDestination::kJson:
    case RequestDestination::kWorker:
    case RequestDestination::kSharedWorker:
    case RequestDestination::kServiceWorker:
    case RequestDestination::kAudioWorklet:
    case RequestDestination::kPaintWorklet:
      return OpenRequestType::Script;
    case RequestDestination::kImage:
      return OpenRequestType::Image;
    case RequestDestination::kStyle:
    case RequestDestination::kXslt:
      return OpenRequestType::Stylesheet;
    case RequestDestination::kFont:
      return OpenRequestType::Font;
    case RequestDestination::kAudio:
    case RequestDestination::kVideo:
    case RequestDestination::kTrack:
      return OpenRequestType::Media;
    case RequestDestination::kEmbed:
    case RequestDestination::kObject:
      return OpenRequestType::Object;
    case RequestDestination::kReport:
      return OpenRequestType::CspReport;
    default:
      return OpenRequestType::Other;
  }
}

// The party source: the request's initiator when it has a usable one, else
// the factory's, else the URL itself (first party by construction).
const GURL& SourceOf(const network::ResourceRequest& request,
                     const AdBlockFactoryContext& context,
                     GURL& other_initiator_url) {
  if (request.request_initiator && !request.request_initiator->opaque()) {
    if (*request.request_initiator == context.initiator) {
      return context.initiator_url;
    }
    other_initiator_url = request.request_initiator->GetURL();
    return other_initiator_url;
  }
  if (!context.initiator.opaque()) {
    return context.initiator_url;
  }
  return request.url;
}

// The list's CSP directives for one subframe response (§7.4), or "" when
// there are none or they are unusable: longer than kMaxListCspBytes or not
// a valid header value. Dropped, never cut: a cut directive can mean
// something else.
std::string ListCspOf(const open_adblock::OpenBlockerResult& result) {
  const std::string_view csp(result.csp_directives.data(),
                             result.csp_directives.size());
  if (csp.size() > kMaxListCspBytes || !net::HttpUtil::IsValidHeaderValue(csp)) {
    VLOG(1) << "OpenAdBlock: dropped a list CSP of " << csp.size() << " bytes";
    return std::string();
  }
  return std::string(csp);
}

network::URLLoaderCompletionStatus BlockedStatus() {
  return network::URLLoaderCompletionStatus(net::ERR_BLOCKED_BY_CLIENT);
}

// §7.4 rule 3: serves a $redirect resource as the response. False when the
// data URL does not parse or is too large; then |client| is left untouched
// and the caller blocks.
bool ServeStub(const std::string& data_url,
               bool same_origin,
               mojo::PendingRemote<network::mojom::URLLoaderClient>& client) {
  std::string mime_type;
  std::string charset;
  std::string body;
  if (!net::DataURL::Parse(GURL(data_url), &mime_type, &charset, &body) ||
      body.size() > kMaxStubBytes) {
    return false;
  }
  mojo::ScopedDataPipeProducerHandle producer;
  mojo::ScopedDataPipeConsumerHandle consumer;
  if (mojo::CreateDataPipe(
          static_cast<uint32_t>(std::max<size_t>(body.size(), 1)), producer,
          consumer) != MOJO_RESULT_OK ||
      (!body.empty() &&
       producer->WriteAllData(base::as_byte_span(body)) != MOJO_RESULT_OK)) {
    return false;
  }
  producer.reset();

  auto head = network::mojom::URLResponseHead::New();
  head->headers = base::MakeRefCounted<net::HttpResponseHeaders>(
      net::HttpUtil::AssembleRawHeaders(base::StringPrintf(
          "HTTP/1.1 200 OK\nContent-Type: %s\nContent-Length: %zu\n\n",
          mime_type.c_str(), body.size())));
  head->mime_type = mime_type;
  head->charset = charset;
  head->content_length = static_cast<int64_t>(body.size());
  head->response_type = same_origin ? network::mojom::FetchResponseType::kBasic
                                    : network::mojom::FetchResponseType::kOpaque;

  mojo::Remote<network::mojom::URLLoaderClient> remote(std::move(client));
  remote->OnReceiveResponse(std::move(head), std::move(consumer), std::nullopt);
  network::URLLoaderCompletionStatus status(net::OK);
  status.decoded_body_length = base::ByteSize(body.size());
  status.encoded_body_length = base::ByteSize(body.size());
  remote->OnComplete(status);
  return true;
}

}  // namespace

void RecordAdBlockRequestLatency(base::TimeDelta latency) {
  const int64_t us = std::max<int64_t>(0, latency.InMicroseconds());
  size_t bucket = 0;
  while (bucket + 1 < kLatencyBuckets && (int64_t{1} << bucket) <= us) {
    ++bucket;
  }
  LatencyBuckets()[bucket].fetch_add(1, std::memory_order_relaxed);
}

uint64_t AdBlockMatcherBusyMicroseconds() {
  return BusyNanoseconds().load(std::memory_order_relaxed) / 1000;
}

uint64_t AdBlockMatcherBusyCpuMicroseconds() {
  return BusyCpuNanoseconds().load(std::memory_order_relaxed) / 1000;
}

std::string AdBlockLatencyHistogramText() {
  std::array<uint64_t, kLatencyBuckets> counts;
  uint64_t total = 0;
  for (size_t i = 0; i < kLatencyBuckets; ++i) {
    counts[i] = LatencyBuckets()[i].load(std::memory_order_relaxed);
    total += counts[i];
  }
  // The upper bound of the bucket that holds the given rank.
  auto percentile = [&](double fraction) -> int64_t {
    if (total == 0) {
      return 0;
    }
    const uint64_t rank = static_cast<uint64_t>(fraction * (total - 1)) + 1;
    uint64_t seen = 0;
    for (size_t i = 0; i < kLatencyBuckets; ++i) {
      seen += counts[i];
      if (seen >= rank) {
        return int64_t{1} << i;
      }
    }
    return int64_t{1} << (kLatencyBuckets - 1);
  };
  int64_t max_bucket = 0;
  std::string buckets;
  for (size_t i = 0; i < kLatencyBuckets; ++i) {
    if (counts[i]) {
      max_bucket = int64_t{1} << i;
      buckets += base::StringPrintf(" <%lld:%llu", static_cast<long long>(int64_t{1} << i),
                                    static_cast<unsigned long long>(counts[i]));
    }
  }
  return base::StringPrintf(
      "G-4 request latency (upper bucket bounds, us): n=%llu p50<=%lld "
      "p99<=%lld max<=%lld buckets:%s",
      static_cast<unsigned long long>(total),
      static_cast<long long>(percentile(0.50)),
      static_cast<long long>(percentile(0.99)),
      static_cast<long long>(max_bucket), buckets.c_str());
}

std::string AdBlockProxyProfileText() {
  std::string text = "proxy CPU (cumulative us; source/check subset request):";
  constexpr std::array<const char*, 5> names{
      "request", "callback", "redirect", "source", "check"};
  for (size_t i = 0; i < names.size(); ++i) {
    text += " " + std::string(names[i]) + "=" + std::to_string(
        CpuParts()[i].load(std::memory_order_relaxed) / 1000);
  }
  return text;
}

AdBlockFactoryContext::AdBlockFactoryContext() = default;
AdBlockFactoryContext::AdBlockFactoryContext(AdBlockFactoryContext&&) = default;
AdBlockFactoryContext& AdBlockFactoryContext::operator=(
    AdBlockFactoryContext&&) = default;
AdBlockFactoryContext::~AdBlockFactoryContext() = default;

// One allowed (or rewritten) request between the client and the target
// (§7.5). Matcher sequence. Owned by its factory.
class OpenAdBlockURLLoader : public network::mojom::URLLoader,
                             public network::mojom::URLLoaderClient {
 public:
  OpenAdBlockURLLoader(
      OpenAdBlockURLLoaderFactory* factory,
      mojo::PendingReceiver<network::mojom::URLLoader> receiver,
      int32_t request_id,
      uint32_t options,
      bool has_upload,
      mojo::PendingRemote<network::mojom::URLLoaderClient> client,
      const net::MutableNetworkTrafficAnnotationTag& annotation,
      OpenRequestType type,
      GURL source,
      std::string csp_directives)
      : factory_(factory),
        receiver_(this, std::move(receiver)),
        client_(std::move(client)),
        request_id_(request_id),
        options_(options),
        has_upload_(has_upload),
        annotation_(annotation),
        type_(type),
        source_(std::move(source)),
        csp_directives_(std::move(csp_directives)) {
    receiver_.set_disconnect_handler(base::BindOnce(
        &OpenAdBlockURLLoader::Finish, base::Unretained(this)));
    client_.set_disconnect_handler(base::BindOnce(
        &OpenAdBlockURLLoader::Finish, base::Unretained(this)));
  }

  OpenAdBlockURLLoader(const OpenAdBlockURLLoader&) = delete;
  OpenAdBlockURLLoader& operator=(const OpenAdBlockURLLoader&) = delete;
  ~OpenAdBlockURLLoader() override = default;

  // §7.4 rule 5: start the request on the target now.
  void StartTarget(const network::ResourceRequest& request) {
    target_client_receiver_.reset();
    target_loader_.reset();
    factory_->target()->CreateLoaderAndStart(
        target_loader_.BindNewPipeAndPassReceiver(), request_id_, options_,
        request, target_client_receiver_.BindNewPipeAndPassRemote(),
        annotation_);
    target_client_receiver_.set_disconnect_handler(base::BindOnce(
        &OpenAdBlockURLLoader::OnTargetDisconnect, base::Unretained(this)));
  }

  // §7.4 rule 4: a synthetic internal redirect to |new_url| (same origin,
  // GET or HEAD), as WebRequest makes one. The client's FollowRedirect
  // starts the request there.
  void StartWithRewrite(const network::ResourceRequest& request,
                         const GURL& new_url) {
    rewrite_pending_ = true;
    // Only a synthetic rewrite needs a mutable copy after this call.
    // Normal allowed requests are serialized directly from the input.
    rewrite_request_ = request;
    const net::RedirectInfo info = net::RedirectInfo::ComputeRedirectInfo(
        request.method, request.url, request.site_for_cookies,
        request.update_first_party_url_on_redirect
            ? net::RedirectInfo::FirstPartyURLPolicy::UPDATE_URL_ON_REDIRECT
            : net::RedirectInfo::FirstPartyURLPolicy::NEVER_CHANGE_URL,
        request.referrer_policy, request.referrer.spec(),
        request.request_initiator, net::HTTP_TEMPORARY_REDIRECT, new_url,
        /*referrer_policy_header=*/std::nullopt,
        /*insecure_scheme_was_upgraded=*/false, /*copy_fragment=*/false,
        /*is_signed_exchange_fallback_redirect=*/false);
    auto head = network::mojom::URLResponseHead::New();
    head->headers = base::MakeRefCounted<net::HttpResponseHeaders>(
        net::HttpUtil::AssembleRawHeaders(base::StringPrintf(
            "HTTP/1.1 %d Internal Redirect\nLocation: %s\n"
            "Non-Authoritative-Reason: Open ad blocker\n\n",
            net::HTTP_TEMPORARY_REDIRECT, new_url.spec().c_str())));
    head->encoded_data_length = 0;
    rewrite_url_ = new_url;
    client_->OnReceiveRedirect(info, std::move(head));
  }

  // network::mojom::URLLoader:
  void FollowRedirect(
      network::HttpRequestHeadersUpdateParams headers_update_params,
      const std::optional<GURL>& new_url) override {
    BusyScope busy(CpuPart::kRedirect);
    if (rewrite_pending_) {
      rewrite_pending_ = false;
      // The proxy's own redirect: its URL, never one the client names (a
      // subresource client passes none).
      network::ResourceRequest& request = *rewrite_request_;
      request.url = rewrite_url_;
      for (const std::string& name : headers_update_params.removed_headers) {
        request.headers.RemoveHeader(name);
        request.cors_exempt_headers.RemoveHeader(name);
      }
      request.headers.MergeFrom(headers_update_params.modified_headers);
      request.cors_exempt_headers.MergeFrom(
          headers_update_params.modified_cors_exempt_headers);
      StartTarget(request);
      rewrite_request_.reset();
      return;
    }
    if (target_loader_) {
      target_loader_->FollowRedirect(std::move(headers_update_params), new_url);
    }
  }
  void SetPriority(net::RequestPriority priority,
                   int32_t intra_priority_value) override {
    BusyScope busy;
    if (target_loader_) {
      target_loader_->SetPriority(priority, intra_priority_value);
    }
  }

  // network::mojom::URLLoaderClient:
  void OnReceiveEarlyHints(network::mojom::EarlyHintsPtr early_hints) override {
    BusyScope busy;
    client_->OnReceiveEarlyHints(std::move(early_hints));
  }
  void OnReceiveResponse(
      network::mojom::URLResponseHeadPtr head,
      mojo::ScopedDataPipeConsumerHandle body,
      std::optional<mojo_base::BigBuffer> cached_metadata) override {
    BusyScope busy;
    // §7.4 CSP, subframe navigations only: the list's directives as one more
    // header; clearing parsed_headers makes the navigation parse them again
    // (F-26).
    if (!csp_directives_.empty() && head->headers) {
      head->headers->AddHeader("Content-Security-Policy", csp_directives_);
      head->parsed_headers.reset();
    }
    client_->OnReceiveResponse(std::move(head), std::move(body),
                               std::move(cached_metadata));
    if (!has_upload_) {
      // Redirects are checked until the final response, and list CSP is
      // applied above. Nothing else needs interception now. Fuse both
      // endpoint pairs so completion, transfer and priority callbacks go
      // directly between the original client and the target.
      //
      // Uploads retain the proxy: an OnUploadProgress response callback
      // can still be alive, and Receiver::Unbind forbids that case.
      mojo::FusePipes(target_client_receiver_.Unbind(), client_.Unbind());
      mojo::FusePipes(receiver_.Unbind(), target_loader_.Unbind());
      Finish();
    }
  }
  void OnReceiveRedirect(const net::RedirectInfo& redirect_info,
                         network::mojom::URLResponseHeadPtr head) override {
    BusyScope busy(CpuPart::kRedirect);
    // §7.5: check the new URL before the client sees it. Covers server
    // redirects and an inner extension proxy's redirects (§7.9).
    const AdBlockFactoryContext& context = factory_->context();
    if (context.matcher->IsActiveFor(context.top_host) &&
        redirect_info.new_url.SchemeIsHTTPOrHTTPS()) {
      const open_adblock::OpenBlockerResult result = context.matcher->Check(
          redirect_info.new_url, source_, type_, kOpenAdBlockMatchCapBytes);
      if (result.matched) {
        factory_->AddStop(AdBlockStopKind::kBlocked);
        CompleteAndFinish(BlockedStatus());
        return;
      }
      if (context.subframe_navigation) {
        csp_directives_ = ListCspOf(result);
      }
    }
    client_->OnReceiveRedirect(redirect_info, std::move(head));
  }
  void OnUploadProgress(int64_t current_position,
                        int64_t total_size,
                        OnUploadProgressCallback callback) override {
    BusyScope busy;
    client_->OnUploadProgress(current_position, total_size,
                              std::move(callback));
  }
  void OnTransferSizeUpdated(int32_t transfer_size_diff) override {
    BusyScope busy;
    client_->OnTransferSizeUpdated(transfer_size_diff);
  }
  void OnComplete(const network::URLLoaderCompletionStatus& status) override {
    BusyScope busy;
    CompleteAndFinish(status);
  }

 private:
  void CompleteAndFinish(const network::URLLoaderCompletionStatus& status) {
    if (client_) {
      client_->OnComplete(status);
    }
    Finish();
  }

  // The target closed its client pipe: before OnComplete, that is an error.
  void OnTargetDisconnect() {
    BusyScope busy;
    CompleteAndFinish(network::URLLoaderCompletionStatus(net::ERR_ABORTED));
  }

  // Destroys this loader (the factory owns it). Nothing may follow.
  void Finish() { factory_->RemoveLoader(this); }

  const raw_ptr<OpenAdBlockURLLoaderFactory> factory_;
  mojo::Receiver<network::mojom::URLLoader> receiver_;
  mojo::Remote<network::mojom::URLLoaderClient> client_;
  mojo::Remote<network::mojom::URLLoader> target_loader_;
  mojo::Receiver<network::mojom::URLLoaderClient> target_client_receiver_{this};
  const int32_t request_id_;
  const uint32_t options_;
  const bool has_upload_;
  std::optional<network::ResourceRequest> rewrite_request_;
  const net::MutableNetworkTrafficAnnotationTag annotation_;
  const OpenRequestType type_;
  const GURL source_;
  std::string csp_directives_;
  bool rewrite_pending_ = false;
  GURL rewrite_url_;
};

// static
void OpenAdBlockURLLoaderFactory::Bind(
    mojo::PendingReceiver<network::mojom::URLLoaderFactory> receiver,
    mojo::PendingRemote<network::mojom::URLLoaderFactory> target,
    AdBlockFactoryContext context) {
  // Owns itself; see MaybeDeleteSelf().
  new OpenAdBlockURLLoaderFactory(std::move(receiver), std::move(target),
                                  std::move(context));
}

OpenAdBlockURLLoaderFactory::OpenAdBlockURLLoaderFactory(
    mojo::PendingReceiver<network::mojom::URLLoaderFactory> receiver,
    mojo::PendingRemote<network::mojom::URLLoaderFactory> target,
    AdBlockFactoryContext context)
    : target_(std::move(target)), context_(std::move(context)) {
  receivers_.Add(this, std::move(receiver));
  receivers_.set_disconnect_handler(
      base::BindRepeating(&OpenAdBlockURLLoaderFactory::OnReceiverDisconnect,
                          base::Unretained(this)));
  target_.set_disconnect_handler(
      base::BindOnce(&OpenAdBlockURLLoaderFactory::OnTargetDisconnect,
                     base::Unretained(this)));
}

OpenAdBlockURLLoaderFactory::~OpenAdBlockURLLoaderFactory() {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  FlushStops();
}

void OpenAdBlockURLLoaderFactory::CreateLoaderAndStart(
    mojo::PendingReceiver<network::mojom::URLLoader> receiver,
    int32_t request_id,
    uint32_t options,
    const network::ResourceRequest& request,
    mojo::PendingRemote<network::mojom::URLLoaderClient> client,
    const net::MutableNetworkTrafficAnnotationTag& annotation) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  BusyScope busy(CpuPart::kRequest);
  const base::TimeTicks arrival = base::TimeTicks::Now();
  auto pass_through = [&] {
    target_->CreateLoaderAndStart(std::move(receiver), request_id, options,
                                  request, std::move(client), annotation);
    RecordAdBlockRequestLatency(base::TimeTicks::Now() - arrival);
  };

  // §7.4 rule 1: off, excluded, not http(s), or a main-frame document
  // (defensive: main-frame navigation factories are not wrapped). Not
  // |is_outermost_main_frame|: that flag marks every request the main frame
  // makes, its subresources included.
  if (!context_.matcher->IsActiveFor(context_.top_host) ||
      !request.url.SchemeIsHTTPOrHTTPS() ||
      request.destination == RequestDestination::kDocument) {
    pass_through();
    return;
  }
  const OpenRequestType type = RequestTypeOf(request);
  GURL other_initiator_url;
  const GURL* source;
  {
    CpuPartScope cpu(CpuPart::kSource);
    source = &SourceOf(request, context_, other_initiator_url);
  }
  open_adblock::OpenBlockerResult result;
  {
    CpuPartScope cpu(CpuPart::kCheck);
    result = context_.matcher->Check(request.url, *source, type,
                                      kOpenAdBlockMatchCapBytes);
  }
  const bool navigation = context_.type == FactoryType::kNavigation;

  if (result.matched) {
    // §7.4 rule 3: a stub response for a $redirect match, outside
    // navigations and CORS-mode requests.
    const bool same_origin = url::IsSameOriginWith(request.url, *source);
    if (result.has_redirect && !result.redirect_data_url.empty() &&
        !navigation &&
        (request.mode == network::mojom::RequestMode::kNoCors || same_origin) &&
        ServeStub(std::string(result.redirect_data_url), same_origin, client)) {
      AddStop(AdBlockStopKind::kRedirected);
      RecordAdBlockRequestLatency(base::TimeTicks::Now() - arrival);
      return;
    }
    // §7.4 rule 2: block. The page, DevTools and CDP see
    // net::ERR_BLOCKED_BY_CLIENT.
    if (client) {
      mojo::Remote<network::mojom::URLLoaderClient>(std::move(client))
          ->OnComplete(BlockedStatus());
    }
    AddStop(AdBlockStopKind::kBlocked);
    RecordAdBlockRequestLatency(base::TimeTicks::Now() - arrival);
    return;
  }

  auto loader = std::make_unique<OpenAdBlockURLLoader>(
      this, std::move(receiver), request_id, options, !!request.request_body,
      std::move(client), annotation, type, *source,
      context_.subframe_navigation ? ListCspOf(result) : std::string());
  OpenAdBlockURLLoader* raw = loader.get();
  loaders_.insert(std::move(loader));

  // §7.4 rule 4: a $removeparam rewrite, same origin, GET or HEAD, not a
  // navigation, and not from a cut URL. At most one per request.
  const GURL rewritten(std::string(result.rewritten_url));
  if (!result.truncated && rewritten.is_valid() && !navigation &&
      (request.method == "GET" || request.method == "HEAD") &&
      url::IsSameOriginWith(rewritten, request.url) &&
      rewritten != request.url) {
    raw->StartWithRewrite(request, rewritten);
  } else {
    raw->StartTarget(request);
  }
  RecordAdBlockRequestLatency(base::TimeTicks::Now() - arrival);
}

void OpenAdBlockURLLoaderFactory::Clone(
    mojo::PendingReceiver<network::mojom::URLLoaderFactory> receiver) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  receivers_.Add(this, std::move(receiver));
}

void OpenAdBlockURLLoaderFactory::AddStop(AdBlockStopKind kind) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  // Frameless factories (shared and service workers) do not count (§7.5).
  if (!context_.has_document) {
    return;
  }
  if (kind == AdBlockStopKind::kBlocked) {
    ++pending_blocked_;
  } else {
    ++pending_redirected_;
  }
  // At most one flush per 100 ms per factory.
  if (!flush_timer_.IsRunning()) {
    flush_timer_.Start(FROM_HERE, base::Milliseconds(100),
                       base::BindOnce(&OpenAdBlockURLLoaderFactory::FlushStops,
                                      base::Unretained(this)));
  }
}

void OpenAdBlockURLLoaderFactory::FlushStops() {
  if (!pending_blocked_ && !pending_redirected_) {
    return;
  }
  // One task with the document and both deltas; the UI thread drops them
  // when the document is gone or not the primary page (§7.5).
  content::GetUIThreadTaskRunner({})->PostTask(
      FROM_HERE, base::BindOnce(&OpenAdBlockTabHelper::AddStopsForDocument,
                                context_.document, pending_blocked_,
                                pending_redirected_));
  pending_blocked_ = 0;
  pending_redirected_ = 0;
}

void OpenAdBlockURLLoaderFactory::RemoveLoader(OpenAdBlockURLLoader* loader) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  auto it = loaders_.find(loader);
  CHECK(it != loaders_.end());
  loaders_.erase(it);
  MaybeDeleteSelf();
}

void OpenAdBlockURLLoaderFactory::OnReceiverDisconnect() {
  MaybeDeleteSelf();
}

void OpenAdBlockURLLoaderFactory::OnTargetDisconnect() {
  // Nothing can be served any more; open loaders keep their own pipes.
  receivers_.Clear();
  MaybeDeleteSelf();
}

void OpenAdBlockURLLoaderFactory::MaybeDeleteSelf() {
  if (receivers_.empty() && loaders_.empty()) {
    delete this;
  }
}

}  // namespace open_engine
