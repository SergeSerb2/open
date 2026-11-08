// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "open/adblock/open_adblock_cosmetics_host.h"

#include <algorithm>
#include <cstddef>
#include <memory>
#include <string>
#include <utility>
#include <vector>

#include "base/command_line.h"
#include "base/functional/bind.h"
#include "base/logging.h"
#include "base/memory/scoped_refptr.h"
#include "base/task/sequenced_task_runner.h"
#include "content/public/browser/browser_thread.h"
#include "mojo/public/cpp/bindings/self_owned_receiver.h"
#include "open/adblock/mojom/open_adblock.mojom.h"
#include "open/adblock/open_adblock_matcher.h"
#include "open/adblock/open_adblock_service.h"
#include "services/service_manager/public/cpp/binder_registry.h"
#include "url/gurl.h"
#include "url/origin.h"

namespace open_engine {
namespace {

constexpr size_t kMaxTokens = 500;
constexpr size_t kMaxTokenBytes = 2048;
constexpr size_t kMaxGenericInputBytes = 256 * 1024;
// Cosmetic matching keeps the URL whole or skips hiding. Use the same
// 16 KiB work bound as network matching, without changing URL semantics.
constexpr size_t kMaxDocumentUrlBytes = 16 * 1024;

class OpenAdBlockCosmeticsHost final : public mojom::AdBlockCosmetics {
 public:
  explicit OpenAdBlockCosmeticsHost(scoped_refptr<OpenAdBlockMatcher> matcher)
      : matcher_(std::move(matcher)) {}

  void GetDocumentCosmetics(const GURL& document_url,
                            const url::Origin& top_origin,
                            GetDocumentCosmeticsCallback callback) override {
    DCHECK(AdBlockCosmeticsTaskRunner()->RunsTasksInCurrentSequence());
    if (document_url.possibly_invalid_spec().size() > kMaxDocumentUrlBytes) {
      VLOG(1) << "OpenAdBlock: document cosmetics null over URL limit bytes="
              << document_url.possibly_invalid_spec().size();
      std::move(callback).Run(nullptr);
      return;
    }
    if (!document_url.SchemeIsHTTPOrHTTPS() || !ActiveFor(top_origin)) {
      VLOG(1) << "OpenAdBlock: document cosmetics null";
      std::move(callback).Run(nullptr);
      return;
    }
    auto resources = matcher_->Cosmetic(document_url);
    auto reply = mojom::AdBlockDocumentCosmetics::New();
    reply->hide_selectors.reserve(resources.hide_selectors.size());
    for (const auto& selector : resources.hide_selectors) {
      reply->hide_selectors.emplace_back(selector);
    }
    reply->exceptions.reserve(resources.exceptions.size());
    for (const auto& exception : resources.exceptions) {
      reply->exceptions.emplace_back(exception);
    }
    reply->generichide = resources.generichide;
    VLOG(1) << "OpenAdBlock: document cosmetics selectors="
            << reply->hide_selectors.size()
            << " dropped_procedural=" << resources.dropped_procedural
            << " dropped_unsafe=" << resources.dropped_unsafe
            << " dropped_style=" << resources.dropped_style
            << " dropped_remove=" << resources.dropped_remove
            << " dropped_scriptlet=" << resources.dropped_scriptlet
            << " dropped_over_cap=" << resources.dropped_over_cap;
    std::move(callback).Run(std::move(reply));
  }

  void GetGenericSelectors(const url::Origin& top_origin,
                           const std::vector<std::string>& classes,
                           const std::vector<std::string>& ids,
                           const std::vector<std::string>& exceptions,
                           GetGenericSelectorsCallback callback) override {
    DCHECK(AdBlockCosmeticsTaskRunner()->RunsTasksInCurrentSequence());
    if (!ActiveFor(top_origin)) {
      std::move(callback).Run({});
      return;
    }
    // Bound the work even for calls not made by our observer. Count both
    // arrays together, including invalid tokens, before copying strings.
    const size_t class_count = std::min(classes.size(), kMaxTokens);
    const size_t id_count = std::min(ids.size(), kMaxTokens - class_count);
    const size_t exception_count = std::min(exceptions.size(), kMaxTokens);
    size_t remaining_bytes = kMaxGenericInputBytes;
    bool budget_exhausted = false;
    bool truncated = class_count < classes.size() || id_count < ids.size() ||
                     exception_count < exceptions.size();
    auto copy_tokens = [&remaining_bytes, &budget_exhausted, &truncated](
                           const auto& input, size_t count) {
      std::vector<std::string> out;
      if (budget_exhausted) {
        truncated |= count != 0;
        return out;
      }
      for (size_t i = 0; i < count; ++i) {
        if (input[i].empty()) {
          continue;
        }
        if (input[i].size() > kMaxTokenBytes) {
          truncated = true;
          continue;
        }
        if (input[i].size() > remaining_bytes) {
          budget_exhausted = true;
          truncated = true;
          break;
        }
        remaining_bytes -= input[i].size();
        out.push_back(input[i]);
      }
      return out;
    };
    // Sequence these copies explicitly: they share one byte budget.
    auto bounded_classes = copy_tokens(classes, class_count);
    auto bounded_ids = copy_tokens(ids, id_count);
    auto bounded_exceptions = copy_tokens(exceptions, exception_count);
    if (truncated) {
      VLOG(1) << "OpenAdBlock: generic input truncated classes="
              << bounded_classes.size() << " ids=" << bounded_ids.size()
              << " exceptions=" << bounded_exceptions.size()
              << " bytes=" << kMaxGenericInputBytes - remaining_bytes;
    }
    VLOG(1) << "OpenAdBlock: GetGenericSelectors tokens="
            << class_count + id_count;
    auto selectors = matcher_->HiddenSelectors(bounded_classes, bounded_ids,
                                               bounded_exceptions);
    // A token can match several compound selectors. Bound output by rules
    // as well as input by tokens (adblock-fork §8.3).
    if (selectors.size() > kMaxTokens) {
      selectors.resize(kMaxTokens);
    }
    std::move(callback).Run(std::move(selectors));
  }

 private:
  bool ActiveFor(const url::Origin& origin) const {
    // This is a process pipe, not a RenderFrameHost receiver (plan §8.2).
    // RenderThread::BindHostReceiver supplies no frame identity, and one
    // process can serve several top sites. Treat the renderer origin as
    // untrusted: a lying renderer can change hiding only in its own process
    // and probe this Profile's exclusion state; selectors are public lists.
    // Do not add a UI-thread origin lookup to either request path.
    return matcher_ && !origin.opaque() &&
           origin.GetURL().SchemeIsHTTPOrHTTPS() &&
           matcher_->IsActiveFor(origin.host());
  }

  const scoped_refptr<OpenAdBlockMatcher> matcher_;
};

void BindCosmetics(scoped_refptr<OpenAdBlockMatcher> matcher,
                   mojo::PendingReceiver<mojom::AdBlockCosmetics> receiver) {
  DCHECK(AdBlockCosmeticsTaskRunner()->RunsTasksInCurrentSequence());
#if !defined(OFFICIAL_BUILD)
  if (base::CommandLine::ForCurrentProcess()->HasSwitch(
          "open-adblock-drop-cosmetics-receiver")) {
    VLOG(1) << "OpenAdBlock: dropping cosmetics receiver";
    return;
  }
#endif
  mojo::MakeSelfOwnedReceiver(
      std::make_unique<OpenAdBlockCosmeticsHost>(std::move(matcher)),
      std::move(receiver));
}

}  // namespace

void ExposeAdBlockInterfacesToRenderer(
    service_manager::BinderRegistry* registry,
    OpenAdBlockService* service) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  registry->AddInterface<mojom::AdBlockCosmetics>(
      base::BindRepeating(&BindCosmetics,
                          service ? service->matcher() : nullptr),
      AdBlockCosmeticsTaskRunner());
}

}  // namespace open_engine
