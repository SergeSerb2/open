// Renderer-side transport. No page-world binding and no IPC for dropped data.
#import "OEOpenWorld.h"
#include "include/cef_open_world.h"
#include "include/cef_parser.h"
#include <chrono>
#include <deque>
#include <map>
#include <memory>

namespace {
constexpr size_t kMessageBytes = 64 * 1024;
constexpr size_t kResultBytes = 1024 * 1024;
struct PageState {
  std::deque<std::chrono::steady_clock::time_point> recent;
  uint64_t accepted = 0, oversized = 0, rateLimited = 0, invalid = 0;
};
std::map<int, std::shared_ptr<PageState>> pages;

void Reply(CefRefPtr<CefFrame> frame, int request, const std::string& json,
           const std::string& error) {
  auto msg = CefProcessMessage::Create("oe.open.reply");
  auto args = msg->GetArgumentList();
  args->SetInt(0, request);
  args->SetString(1, json);
  args->SetString(2, error);
  frame->SendProcessMessage(PID_BROWSER, msg);
}

class NativeHandler : public CefV8Handler {
 public:
  NativeHandler(CefRefPtr<CefFrame> frame, CefString document,
                std::shared_ptr<PageState> state)
      : frame_(frame), document_(document), state_(std::move(state)) {}
  bool Execute(const CefString& name, CefRefPtr<CefV8Value> object,
               const CefV8ValueList& args, CefRefPtr<CefV8Value>& retval,
               CefString& exception) override {
    auto current = CefV8Context::GetCurrentContext();
    if (!CefIsOpenScriptContext(current) || !frame_->IsValid() ||
        CefGetScriptDocumentIdentifier(current) != document_) return true;
    if (name == "completeEvaluation") {
      if (args.size() != 3 || !args[0]->IsInt() || !args[1]->IsString() ||
          !args[2]->IsString()) return true;
      auto value = args[1]->GetStringValue();
      auto error = args[2]->GetStringValue();
      // At most 1 MiB UTF-16 units are converted: worst temporary UTF-8
      // allocation is 3 MiB, far below PartitionAlloc's allocation ceiling.
      if (value.length() > kResultBytes || error.length() > kMessageBytes) {
        Reply(frame_, args[0]->GetIntValue(), "", "Open-world result too large");
      } else {
        auto json = value.ToString();
        Reply(frame_, args[0]->GetIntValue(),
              json.size() <= kResultBytes ? json : "",
              json.size() <= kResultBytes ? error.ToString() :
                  "Open-world result too large");
      }
      return true;
    }
    if (args.size() != 2 || !args[0]->IsString() || !args[1]->IsString()) {
      ++state_->invalid;
      return true;
    }
    auto type = args[0]->GetStringValue();
    auto payload = args[1]->GetStringValue();
    if (type.length() > kMessageBytes || payload.length() > kMessageBytes) {
      ++state_->oversized;
      return true;
    }
    auto t = type.ToString(), p = payload.ToString();
    if (t.size() + p.size() > kMessageBytes) {
      ++state_->oversized;
      return true;
    }
    auto now = std::chrono::steady_clock::now();
    while (!state_->recent.empty() && now - state_->recent.front() >=
           std::chrono::seconds(1)) state_->recent.pop_front();
    if (state_->recent.size() >= 200) {
      ++state_->rateLimited;
      return true;
    }
    state_->recent.push_back(now);
    ++state_->accepted;
    auto message = CefProcessMessage::Create("oe.open.message");
    auto out = message->GetArgumentList();
    out->SetString(0, t);
    out->SetString(1, p);
    out->SetString(2, document_);
    frame_->SendProcessMessage(PID_BROWSER, message);
    return true;
  }
 private:
  CefRefPtr<CefFrame> frame_;
  CefString document_;
  std::shared_ptr<PageState> state_;
  IMPLEMENT_REFCOUNTING(NativeHandler);
};

}  // namespace

CefRefPtr<CefV8Context> OEOpenWorldContext(CefRefPtr<CefBrowser> browser,
                                         CefRefPtr<CefFrame> frame) {
  if (!frame || !frame->IsMain()) return nullptr;
  auto context = CefGetOpenScriptContext(frame->GetV8Context());
  if (!context || !context->Enter()) return nullptr;
  auto global = context->GetGlobal();
  auto existing = global->GetValue("__openNative");
  auto post = existing && existing->IsObject() ? existing->GetValue("postMessage") : nullptr;
  // A page can create a named DOM element/window called __openNative. Only
  // our native function proves installation; named properties do not.
  if (!post || !post->IsFunction() || !post->GetFunctionHandler()) {
    auto& state = pages[browser->GetIdentifier()];
    if (!state) state = std::make_shared<PageState>();
    CefRefPtr<CefV8Handler> handler = new NativeHandler(frame,
        CefGetScriptDocumentIdentifier(context), state);
    auto bridge = CefV8Value::CreateObject(nullptr, nullptr);
    const auto immutable = static_cast<cef_v8_propertyattribute_t>(
        V8_PROPERTY_ATTRIBUTE_READONLY | V8_PROPERTY_ATTRIBUTE_DONTDELETE);
    bridge->SetValue("postMessage",
        CefV8Value::CreateFunction("postMessage", handler), immutable);
    bridge->SetValue("completeEvaluation",
        CefV8Value::CreateFunction("completeEvaluation", handler), immutable);
    global->SetValue("__openNative", bridge, immutable);
  }
  context->Exit();
  return context;
}

bool OEOpenWorldRendererMessage(CefRefPtr<CefBrowser> browser,
                                CefRefPtr<CefFrame> frame,
                                CefRefPtr<CefProcessMessage> message) {
  const auto name = message->GetName();
  if (name != "oe.open.eval" && name != "oe.open.stats") return false;
  if (!frame->IsMain()) return true;
  auto args = message->GetArgumentList();
  const int request = args->GetInt(0);
  if (name == "oe.open.stats") {
    auto& state = pages[browser->GetIdentifier()];
    if (!state) state = std::make_shared<PageState>();
    auto d = CefDictionaryValue::Create();
    d->SetDouble("accepted", state->accepted);
    d->SetDouble("oversized", state->oversized);
    d->SetDouble("rateLimited", state->rateLimited);
    d->SetDouble("invalid", state->invalid);
    auto v = CefValue::Create(); v->SetDictionary(d);
    Reply(frame, request, CefWriteJSON(v, JSON_WRITER_DEFAULT).ToString(), "");
    return true;
  }
  auto context = OEOpenWorldContext(browser, frame);
  if (!context) {
    Reply(frame, request, "", "No current main-frame document");
    return true;
  }
  const auto source = args->GetString(1);
  CefRefPtr<CefV8Value> result, settle;
  CefRefPtr<CefV8Exception> error;
  if (!context->Enter()) {
    Reply(frame, request, "", "Open context was released");
    return true;
  }
  // Direct internal script execution also works on pages whose CSP forbids
  // eval. Do not turn the caller's source into a page eval() operation.
  if (!context->Eval(source.empty() ? CefString("void 0") : source,
                     "openengine://open-eval", 1, result, error)) {
    Reply(frame, request, "", error ? error->GetMessage().ToString() :
                                      "Open-world evaluation failed");
  } else if (context->Eval(
      "(function(value,id){Promise.resolve(value).then(v=>{"
      "const json=JSON.stringify(v===undefined?null:v);"
      "__openNative.completeEvaluation(id,json,'')"
      "}).catch(e=>__openNative.completeEvaluation(id,'',String(e)))})",
      "openengine://open-eval-result", 1, settle, error)) {
    CefV8ValueList values{result ? result : CefV8Value::CreateUndefined(),
                          CefV8Value::CreateInt(request)};
    settle->ExecuteFunctionWithContext(context, nullptr, values);
  } else {
    Reply(frame, request, "", "Open-world result conversion failed");
  }
  context->Exit();
  return true;
}

void OEOpenWorldBrowserDestroyed(int browserID) { pages.erase(browserID); }
