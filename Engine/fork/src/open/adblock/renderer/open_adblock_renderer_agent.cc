// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "open/adblock/renderer/open_adblock_renderer_agent.h"

#if !defined(OFFICIAL_BUILD)
#include <mach/mach.h>
#endif

#include <algorithm>
#include <utility>

#include "base/functional/bind.h"
#include "base/location.h"
#include "base/logging.h"
#include "base/no_destructor.h"
#include "base/task/single_thread_task_runner.h"
#include "base/timer/elapsed_timer.h"
#include "content/public/renderer/render_frame.h"
#include "content/public/renderer/render_thread.h"
#include "gin/arguments.h"
#include "gin/converter.h"
#include "gin/function_template.h"
#include "mojo/public/cpp/bindings/remote.h"
#include "open/adblock/renderer/open_adblock_isolated_world.h"
#include "open/adblock/renderer/open_adblock_page_script.h"
#include "third_party/blink/public/platform/scheduler/web_agent_group_scheduler.h"
#include "third_party/blink/public/platform/web_security_origin.h"
#include "third_party/blink/public/platform/web_string.h"
#include "third_party/blink/public/web/web_document.h"
#include "third_party/blink/public/web/web_frame.h"
#include "third_party/blink/public/web/web_local_frame.h"
#include "third_party/blink/public/web/web_script_source.h"
#include "url/gurl.h"

namespace open_engine {
namespace {

constexpr uint32_t kMaxGenericSheets = 64;
constexpr uint32_t kMaxTokens = 500;

#if !defined(OFFICIAL_BUILD)
uint64_t RendererFootprintBytes() {
  task_vm_info_data_t info = {};
  mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
  return task_info(mach_task_self(), TASK_VM_INFO,
                   reinterpret_cast<task_info_t>(&info), &count) == KERN_SUCCESS
             ? info.phys_footprint
             : 0;
}
#endif

// Render-thread only. Never reconnect after a failed host: subsequent loads
// fail open without another wait. The process pipe outlives frame brokers.
struct CosmeticsPipe {
  CosmeticsPipe() {
    content::RenderThread::Get()->BindHostReceiver(
        remote.BindNewPipeAndPassReceiver());
  }
  mojo::Remote<mojom::AdBlockCosmetics> remote;
  bool first_query = true;
  bool failed = false;
};

CosmeticsPipe& Pipe() {
  static base::NoDestructor<CosmeticsPipe> pipe;
  return *pipe;
}

// Avoid converting an unbounded JavaScript array before applying the cap.
std::vector<std::string> ReadTokens(v8::Isolate* isolate,
                                    v8::Local<v8::Context> context,
                                    v8::Local<v8::Array> array,
                                    uint32_t count) {
  std::vector<std::string> tokens;
  for (uint32_t i = 0; i < count; ++i) {
    v8::Local<v8::Value> value;
    if (!array->Get(context, i).ToLocal(&value) || !value->IsString() ||
        value.As<v8::String>()->Length() > 2048) {
      continue;
    }
    std::string token;
    if (gin::ConvertFromV8(isolate, value, &token) &&
        !token.empty() && token.size() <= 2048) {
      tokens.push_back(std::move(token));
    }
  }
  return tokens;
}

}  // namespace

OpenAdBlockRendererAgent::OpenAdBlockRendererAgent(content::RenderFrame* frame)
    : content::RenderFrameObserver(frame) {
  // Bind before navigation; no synchronous call or query at frame creation.
  Pipe();
}

OpenAdBlockRendererAgent::~OpenAdBlockRendererAgent() = default;

void OpenAdBlockRendererAgent::OnDestruct() {
  delete this;
}

void OpenAdBlockRendererAgent::DidCreateNewDocument() {
  ++document_epoch_;
  cosmetics_.reset();
  top_origin_ = url::Origin();
  generic_sheets_ = 0;
  generic_pending_ = 0;
  generic_limit_logged_ = false;
  document_queried_ = false;
  observer_started_ = false;
#if !defined(OFFICIAL_BUILD)
  footprint_before_insert_ = 0;
#endif
  // Do not reset binding_context_: it follows WillReleaseScriptContext.
}

void OpenAdBlockRendererAgent::DidCreateDocumentElement() {
  if (document_queried_) {
    return;
  }
  document_queried_ = true;
  auto* frame = render_frame()->GetWebFrame();
  const GURL document_url = frame->GetDocument().Url();
  if (!document_url.SchemeIsHTTPOrHTTPS()) {
    return;
  }
  top_origin_ = frame->Top()->GetSecurityOrigin();
  auto& pipe = Pipe();
  const bool first = std::exchange(pipe.first_query, false);
  const base::ElapsedTimer query_timer;
  const bool ok =
      !pipe.failed && pipe.remote.is_connected() &&
      pipe.remote->GetDocumentCosmetics(document_url, top_origin_, &cosmetics_);
  const auto query_time = query_timer.Elapsed();
  VLOG(1) << "OpenAdBlock: cosmetics query document=" << document_epoch_
          << " frame=" << frame->GetLocalFrameToken().ToString()
          << " first=" << first
          << " us=" << query_time.InMicrosecondsF() << " ok=" << ok
          << " null=" << !cosmetics_;
  if (!ok) {
    pipe.failed = true;
    cosmetics_.reset();
    return;
  }
  if (!cosmetics_) {
    return;
  }
  InsertSelectors(cosmetics_->hide_selectors, /*initial=*/true);
  if (cosmetics_->generichide) {
    return;
  }
  // Blink calls DidCreateDocumentElement inside ScriptForbiddenScope.
  // Keep the query/style insertion here, but start the class/ID observer
  // in this frame's next task, after that scope unwinds. WeakPtr and the
  // epoch reject detached frames and a newer document before touching V8.
  frame->GetAgentGroupScheduler()->DefaultTaskRunner()->PostTask(
      FROM_HERE,
      base::BindOnce(&OpenAdBlockRendererAgent::StartObserver,
                     weak_ptr_factory_.GetWeakPtr(), document_epoch_));
}

void OpenAdBlockRendererAgent::StartObserver(uint64_t document_epoch) {
  if (document_epoch != document_epoch_ || observer_started_ || !cosmetics_ ||
      cosmetics_->generichide) {
    return;
  }
  auto* frame = render_frame()->GetWebFrame();
  auto* isolate = frame->GetAgentGroupScheduler()->Isolate();
  v8::Isolate::Scope isolate_scope(isolate);
  v8::HandleScope scope(isolate);
  const auto alive = weak_ptr_factory_.GetWeakPtr();
  auto context = frame->GetScriptContextFromWorldId(
      isolate, kOpenAdBlockIsolatedWorldId);
  if (context.IsEmpty()) {
    // The Blink getter can return an empty context. Enter the normal world
    // creation path; our context callback installs the binding synchronously.
    frame->ExecuteScriptInIsolatedWorld(
        kOpenAdBlockIsolatedWorldId,
        blink::WebScriptSource(blink::WebString::FromUtf8("void 0")),
        blink::BackForwardCacheAware::kAllow);
    if (!alive || document_epoch != document_epoch_) {
      return;
    }
    context = frame->GetScriptContextFromWorldId(
        isolate, kOpenAdBlockIsolatedWorldId);
  }
  if (context.IsEmpty()) {
    return;
  }
  InstallBinding(context, "existing");
  if (!binding_installed_) {
    return;
  }
  observer_started_ = true;
  VLOG(1) << "OpenAdBlock: observer started document=" << document_epoch_
          << " frame=" << frame->GetLocalFrameToken().ToString()
          << " world=" << frame->GetScriptContextWorldId(context);
  frame->ExecuteScriptInIsolatedWorld(
      kOpenAdBlockIsolatedWorldId,
      blink::WebScriptSource(
          blink::WebString::FromUtf8(AdBlockClassIdObserverScript())),
      blink::BackForwardCacheAware::kAllow);
}

void OpenAdBlockRendererAgent::DidCreateScriptContext(
    v8::Local<v8::Context> context,
    int32_t world_id) {
#if !defined(OFFICIAL_BUILD)
  VLOG(1) << "OpenScriptWorld: context-created world=" << world_id
          << " frame="
          << render_frame()->GetWebFrame()->GetLocalFrameToken().ToString();
#endif
  if (world_id == kOpenAdBlockIsolatedWorldId) {
    InstallBinding(context, "callback");
  }
}

void OpenAdBlockRendererAgent::WillReleaseScriptContext(
    v8::Local<v8::Context> context,
    int32_t world_id) {
  if (world_id == kOpenAdBlockIsolatedWorldId && binding_installed_ &&
      binding_context_.Get(v8::Isolate::GetCurrent()) == context) {
    binding_context_.Reset();
    binding_installed_ = false;
  }
}

void OpenAdBlockRendererAgent::InstallBinding(v8::Local<v8::Context> context,
                                              const char* reason) {
  if (binding_installed_ || context.IsEmpty()) {
    return;
  }
  auto* isolate = v8::Isolate::GetCurrent();
  v8::Context::Scope scope(context);
  auto binding = v8::Object::New(isolate);
  v8::Local<v8::Function> exceptions;
  v8::Local<v8::Function> report;
  if (!gin::CreateFunctionTemplate(
           isolate, base::BindRepeating(
                        [](base::WeakPtr<OpenAdBlockRendererAgent> agent,
                           gin::Arguments* args) {
                          if (agent) {
                            agent->Exceptions(args);
                          } else {
                            args->Return(std::vector<std::string>());
                          }
                        },
                        weak_ptr_factory_.GetWeakPtr()))
           ->GetFunction(context)
           .ToLocal(&exceptions) ||
      !gin::CreateFunctionTemplate(
           isolate, base::BindRepeating(
                        [](base::WeakPtr<OpenAdBlockRendererAgent> agent,
                           gin::Arguments* args) {
                          if (agent) {
                            agent->Report(args);
                          } else {
                            args->Return(-1);
                          }
                        },
                        weak_ptr_factory_.GetWeakPtr()))
           ->GetFunction(context)
           .ToLocal(&report) ||
      !binding
           ->CreateDataProperty(context, gin::StringToV8(isolate, "exceptions"),
                                exceptions)
           .FromMaybe(false) ||
      !binding
           ->CreateDataProperty(context, gin::StringToV8(isolate, "report"),
                                report)
           .FromMaybe(false) ||
      !context->Global()
           ->CreateDataProperty(
               context, gin::StringToV8(isolate, "__openAdBlock"), binding)
           .FromMaybe(false)) {
    return;
  }
  if (VLOG_IS_ON(1)) {
    v8::Local<v8::Function> trace;
    if (gin::CreateFunctionTemplate(
            isolate,
            base::BindRepeating(
                [](base::WeakPtr<OpenAdBlockRendererAgent> agent, int stage,
                   uint32_t count) {
                  if (agent) {
                    agent->TraceObserver(stage, count);
                  }
                },
                weak_ptr_factory_.GetWeakPtr()))
            ->GetFunction(context)
            .ToLocal(&trace)) {
      if (!binding
               ->CreateDataProperty(context, gin::StringToV8(isolate, "trace"),
                                    trace)
               .FromMaybe(false)) {
        VLOG(1) << "OpenAdBlock: observer trace binding unavailable";
      }
    }
  }
  binding_context_.Reset(isolate, context);
  binding_installed_ = true;
  VLOG(1) << "OpenAdBlock: binding installed (" << reason
          << ") document=" << document_epoch_
          << " frame="
          << render_frame()->GetWebFrame()->GetLocalFrameToken().ToString()
          << " world="
          << render_frame()->GetWebFrame()->GetScriptContextWorldId(context);
}

void OpenAdBlockRendererAgent::TraceObserver(int stage, uint32_t count) {
  VLOG(1) << "OpenAdBlock: observer trace stage=" << stage << " count=" << count
          << " document=" << document_epoch_ << " world="
          << render_frame()->GetWebFrame()->GetScriptContextWorldId(
                 v8::Isolate::GetCurrent()->GetCurrentContext())
          << " bound=" << Pipe().remote.is_bound()
          << " connected=" << Pipe().remote.is_connected()
          << " failed=" << Pipe().failed;
}

void OpenAdBlockRendererAgent::Exceptions(gin::Arguments* args) {
  if (!cosmetics_) {
    args->Return(std::vector<std::string>());
    return;
  }
  args->Return(cosmetics_->exceptions);
}

void OpenAdBlockRendererAgent::Report(gin::Arguments* args) {
  VLOG(1) << "OpenAdBlock: report entry document=" << document_epoch_
          << " payload=" << static_cast<bool>(cosmetics_)
          << " generichide=" << (cosmetics_ && cosmetics_->generichide)
          << " observer=" << observer_started_
          << " bound=" << Pipe().remote.is_bound()
          << " connected=" << Pipe().remote.is_connected()
          << " failed=" << Pipe().failed;
  if (!cosmetics_ || cosmetics_->generichide || !observer_started_ ||
      Pipe().failed || !Pipe().remote.is_connected()) {
    args->Return(-1);
    return;
  }
  if (generic_sheets_ >= kMaxGenericSheets) {
    if (!std::exchange(generic_limit_logged_, true)) {
      VLOG(1) << "OpenAdBlock: generic sheet limit document="
              << document_epoch_;
    }
    args->Return(-1);
    return;
  }
  if (generic_sheets_ + generic_pending_ >= kMaxGenericSheets) {
    // Reserve one possible sheet per in-flight call. Retry these unsent
    // tokens after replies arrive; empty replies consume no sheet budget.
    args->Return(0);
    return;
  }
  v8::Local<v8::Value> class_value;
  v8::Local<v8::Value> id_value;
  if (!args->GetNext(&class_value) || !class_value->IsArray() ||
      !args->GetNext(&id_value) || !id_value->IsArray()) {
    args->Return(-1);
    return;
  }
  const auto class_array = class_value.As<v8::Array>();
  const auto id_array = id_value.As<v8::Array>();
  auto context = args->isolate()->GetCurrentContext();
  const uint32_t class_count = std::min(class_array->Length(), kMaxTokens);
  const uint32_t id_count =
      std::min(id_array->Length(), kMaxTokens - class_count);
  // Array getters can execute script and detach the frame. Do not read
  // another member after either conversion unless this document survived.
  const auto alive = weak_ptr_factory_.GetWeakPtr();
  const auto epoch = document_epoch_;
  auto classes = ReadTokens(args->isolate(), context, class_array, class_count);
  if (!alive || epoch != document_epoch_) {
    args->Return(-1);
    return;
  }
  auto ids = ReadTokens(args->isolate(), context, id_array, id_count);
  if (!alive || epoch != document_epoch_) {
    args->Return(-1);
    return;
  }
  if (classes.empty() && ids.empty()) {
    VLOG(1) << "OpenAdBlock: report empty after token filter classes="
            << class_count << " ids=" << id_count;
    args->Return(1);
    return;
  }
  // A getter can also report recursively and reserve the remaining slots.
  if (generic_sheets_ + generic_pending_ >= kMaxGenericSheets) {
    args->Return(generic_sheets_ >= kMaxGenericSheets ? -1 : 0);
    return;
  }
  ++generic_pending_;
  VLOG(1) << "OpenAdBlock: report send document=" << document_epoch_
          << " classes=" << classes.size() << " ids=" << ids.size()
          << " pending=" << generic_pending_;
  Pipe().remote->GetGenericSelectors(
      top_origin_, classes, ids, cosmetics_->exceptions,
      base::BindOnce(&OpenAdBlockRendererAgent::OnGenericSelectors,
                     weak_ptr_factory_.GetWeakPtr(), document_epoch_));
  args->Return(1);
}

void OpenAdBlockRendererAgent::OnGenericSelectors(
    uint64_t document_epoch,
    const std::vector<std::string>& selectors) {
  if (document_epoch == document_epoch_ && cosmetics_ &&
      !cosmetics_->generichide) {
    --generic_pending_;
    if (!selectors.empty()) {
      ++generic_sheets_;
      if (generic_sheets_ == kMaxGenericSheets) {
        generic_limit_logged_ = true;
        VLOG(1) << "OpenAdBlock: generic sheet limit document="
                << document_epoch_;
      }
    }
    InsertSelectors(selectors, /*initial=*/false);
  }
}

void OpenAdBlockRendererAgent::InsertSelectors(
    const std::vector<std::string>& selectors,
    bool initial) {
  if (selectors.empty()) {
    return;
  }
#if !defined(OFFICIAL_BUILD)
  if (VLOG_IS_ON(1) && !footprint_before_insert_) {
    footprint_before_insert_ = RendererFootprintBytes();
  }
#endif
  constexpr char kHideDeclaration[] = "{display:none!important}\n";
  // The shim rejects empty selectors. Its 256 KiB selector-byte cap
  // therefore bounds initial CSS by 256 KiB * 26 = 6,815,744 bytes.
  // A generic sheet is at most 500 * (2048 + 25) = 1,036,500 bytes.
  // Reserve exactly once; both bounds are far below PA's allocation limit.
  size_t css_bytes = 0;
  for (const auto& selector : selectors) {
    css_bytes += selector.size() + sizeof(kHideDeclaration) - 1;
  }
  std::string css;
  css.reserve(css_bytes);
  for (const auto& selector : selectors) {
    css.append(selector);
    css.append(kHideDeclaration);
  }
  const base::ElapsedTimer timer;
  render_frame()->GetWebFrame()->GetDocument().InsertStyleSheet(
      blink::WebString::FromUtf8(css), nullptr, blink::WebCssOrigin::kUser,
      blink::BackForwardCacheAware::kAllow);
  const auto insertion_time = timer.Elapsed();
  VLOG(1) << "OpenAdBlock: InsertStyleSheet document=" << document_epoch_
          << " frame="
          << render_frame()->GetWebFrame()->GetLocalFrameToken().ToString()
          << " initial=" << initial << " selectors=" << selectors.size()
          << " bytes=" << css.size()
          << " us=" << insertion_time.InMicrosecondsF();
#if !defined(OFFICIAL_BUILD)
  if (VLOG_IS_ON(1)) {
    VLOG(1) << "OpenAdBlock: renderer footprint document=" << document_epoch_
            << " frame="
            << render_frame()->GetWebFrame()->GetLocalFrameToken().ToString()
            << " initial=" << initial << " generic_sheets=" << generic_sheets_
            << " before_bytes=" << footprint_before_insert_
            << " current_bytes=" << RendererFootprintBytes();
  }
#endif
}

}  // namespace open_engine
