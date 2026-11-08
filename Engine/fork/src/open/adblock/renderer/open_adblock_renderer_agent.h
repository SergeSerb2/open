// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef OPEN_ADBLOCK_RENDERER_OPEN_ADBLOCK_RENDERER_AGENT_H_
#define OPEN_ADBLOCK_RENDERER_OPEN_ADBLOCK_RENDERER_AGENT_H_

#include <cstdint>
#include <string>
#include <vector>

#include "base/memory/weak_ptr.h"
#include "content/public/renderer/render_frame_observer.h"
#include "open/adblock/mojom/open_adblock.mojom.h"
#include "url/origin.h"
#include "v8/include/v8.h"

namespace gin {
class Arguments;
}

namespace open_engine {

// Self-owned by the RenderFrame. The only synchronous work outside Blink
// is one document query; generic queries never wait for the browser.
class OpenAdBlockRendererAgent final : public content::RenderFrameObserver {
 public:
  explicit OpenAdBlockRendererAgent(content::RenderFrame* frame);
  ~OpenAdBlockRendererAgent() override;

  void DidCreateNewDocument() override;
  void DidCreateDocumentElement() override;
  void DidCreateScriptContext(v8::Local<v8::Context> context,
                              int32_t world_id) override;
  void WillReleaseScriptContext(v8::Local<v8::Context> context,
                                int32_t world_id) override;
  void OnDestruct() override;

 private:
  void InstallBinding(v8::Local<v8::Context> context, const char* reason);
  void Exceptions(gin::Arguments* args);
  void Report(gin::Arguments* args);
  void OnGenericSelectors(uint64_t document_epoch,
                          const std::vector<std::string>& selectors);
  void InsertSelectors(const std::vector<std::string>& selectors, bool initial);

  mojom::AdBlockDocumentCosmeticsPtr cosmetics_;
  url::Origin top_origin_;
  uint64_t document_epoch_ = 0;
  uint32_t generic_sheets_ = 0;
  uint32_t generic_pending_ = 0;
  bool document_queried_ = false;
  bool observer_started_ = false;
  bool binding_installed_ = false;
  bool generic_limit_logged_ = false;
#if !defined(OFFICIAL_BUILD)
  uint64_t footprint_before_insert_ = 0;
#endif
  v8::Global<v8::Context> binding_context_;
  // Survives new documents if Blink retains the context. Callbacks always
  // read cosmetics_ lazily, and async replies carry document_epoch_.
  base::WeakPtrFactory<OpenAdBlockRendererAgent> weak_ptr_factory_{this};
};

}  // namespace open_engine

#endif  // OPEN_ADBLOCK_RENDERER_OPEN_ADBLOCK_RENDERER_AGENT_H_
