// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef OPEN_UNIFIED_UI_WEBUI_OPEN_WEBUI_CONFIG_H_
#define OPEN_UNIFIED_UI_WEBUI_OPEN_WEBUI_CONFIG_H_

#include <algorithm>
#include <map>
#include <memory>
#include <optional>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include "base/barrier_callback.h"
#include "base/functional/bind.h"
#include "base/functional/callback.h"
#include "base/memory/raw_ptr.h"
#include "base/task/sequenced_task_runner.h"
#include "base/memory/weak_ptr.h"
#include "base/types/expected.h"
#include "base/values.h"
#include "content/public/browser/web_ui_controller.h"
#include "content/public/browser/web_ui_message_handler.h"
#include "content/public/browser/webui_config.h"
#include "open_unified/browser/open_browser_service.h"
#include "open_unified/core/model/open_types.h"
#include "open_unified/ui/webui/open_ipc_contract.h"

class GURL;
class Profile;

namespace content {
class BrowserContext;
class BrowserURLHandler;
class WebUI;
}  // namespace content

namespace open_unified::webui {

// --- URLs --------------------------------------------------------------------
//
// Open's pages are shown as open://<host>/ and served as Chromium WebUI from
// chrome://open-<host>/ (content serves WebUI only from chrome:// and
// chrome-untrusted://, webui_config_map.cc). Hook 0005 registers "open" as
// a standard, secure scheme and installs the rewrite pair below in
// BrowserURLHandler, so the address bar, history and the model keep
// open:// URLs while the page gets WebUI bindings, process isolation and the
// chrome:// security model.

// "open://settings/" (+ |path| without a leading slash).
std::string OpenWebUIURL(std::string_view host, std::string_view path = "");
// "open-settings" for "settings"; empty for an unknown host.
std::string InternalHost(std::string_view host);
// The seven hosts of open_ipc_contract.h.
const std::vector<std::string_view>& OpenHosts();

// open://easel/asset/<doc_id>/<asset_id> and open://note/asset/<doc_id>/
// <asset_id>: a document's image, from the Profile's DocumentStore
// (Easels/<id>/images/, Notes/<id>.assets/) or <profile_dir>/documents/
// assets/<doc_id>/<asset_id>. Ids are validated (no separators, no "..");
// only png, jpeg, webp, gif and svg are served.
bool IsDocumentAssetPath(std::string_view path);
// "image/png" etc. for an asset filename; empty for any other type.
std::string_view DocumentAssetMimeType(std::string_view filename);

// Hook 0005 entry points.
void RegisterOpenWebUIConfigs();
void AddOpenURLHandlers(content::BrowserURLHandler* handler);

class OpenWebUIMessageHandler;

// --- All Profiles ------------------------------------------------------------
//
// Library pages send profile_id "all" for the merged view of every Profile
// (History, Archive, Downloads, Media, Boosts, Easels and Notes). Each row a
// domain returns then carries its own "profile_id", and row actions send that
// id back.
inline constexpr char kAllProfilesId[] = "all";

// Runs |task| against the |member| store of every Profile in |profiles| (on
// each store's sequence) and |done| on the calling sequence with one
// (ProfileID, Result) pair per Profile that has services, in |profiles|
// order. |done| always runs, also for an empty list.
template <typename Store, typename Result>
void RunOnProfileStores(
    const std::vector<ProfileID>& profiles,
    base::SequenceBound<Store> ProfileServices::* member,
    base::RepeatingCallback<Result(Store*)> task,
    base::OnceCallback<void(std::vector<std::pair<ProfileID, Result>>)> done) {
  using Pair = std::pair<ProfileID, Result>;
  OpenBrowserService* service = OpenBrowserService::Get();
  std::vector<ProfileServices*> targets;
  for (const ProfileID& id : profiles) {
    if (ProfileServices* ps = service ? service->ProfileServicesFor(id)
                                      : nullptr) {
      targets.push_back(ps);
    }
  }
  // Completion order is arbitrary; restore |profiles| order for stable merges.
  auto ordered = base::BindOnce(
      [](std::vector<ProfileID> order,
         base::OnceCallback<void(std::vector<Pair>)> done,
         std::vector<Pair> results) {
        std::stable_sort(results.begin(), results.end(),
                         [&order](const Pair& a, const Pair& b) {
                           return std::find(order.begin(), order.end(),
                                            a.first) <
                                  std::find(order.begin(), order.end(),
                                            b.first);
                         });
        std::move(done).Run(std::move(results));
      },
      profiles, std::move(done));
  if (targets.empty()) {
    base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE, base::BindOnce(std::move(ordered), std::vector<Pair>()));
    return;
  }
  auto barrier = base::BarrierCallback<Pair>(targets.size(), std::move(ordered));
  for (ProfileServices* ps : targets) {
    RunOnStore(ps->*member,
               base::BindOnce(
                   [](base::RepeatingCallback<Result(Store*)> task,
                      Store* store) { return task.Run(store); },
                   task),
               base::BindOnce(
                   [](ProfileID id, base::RepeatingCallback<void(Pair)> barrier,
                      Result result) {
                     barrier.Run(Pair(std::move(id), std::move(result)));
                   },
                   ps->id, barrier));
  }
}

// --- RPC domains -------------------------------------------------------------
//
// A group of open.rpc methods (settings.*, library.*, ...). One page has one
// OpenWebUIMessageHandler (the only "open.rpc" message callback) and the
// domains its host needs.
class OpenRpcDomain {
 public:
  using Reply =
      base::OnceCallback<void(base::expected<base::Value, std::string>)>;
  using Method =
      base::RepeatingCallback<void(const base::DictValue& payload, Reply)>;

  explicit OpenRpcDomain(OpenWebUIMessageHandler* handler);
  virtual ~OpenRpcDomain();

  OpenRpcDomain(const OpenRpcDomain&) = delete;
  OpenRpcDomain& operator=(const OpenRpcDomain&) = delete;

  virtual void RegisterMethods() = 0;
  // Called when the page allows/disallows JavaScript (reload, navigation).
  virtual void OnJavascriptAllowed() {}
  virtual void OnJavascriptDisallowed() {}

 protected:
  void Register(std::string_view method, Method method_handler);
  void Emit(std::string_view event_name, base::Value payload);

  OpenBrowserService* service() const;
  ::Profile* profile() const;
  // The Open Profile of this page's Chromium Profile.
  ProfileID profile_id() const;
  // |payload|'s "profile_id" when present and known, else profile_id().
  // "all" also maps to profile_id(); domains that can merge Profiles check
  // WantsAllProfiles() / ProfilesFromPayload() first.
  ProfileID ProfileFromPayload(const base::DictValue& payload) const;
  // True when |payload|'s "profile_id" is kAllProfilesId.
  bool WantsAllProfiles(const base::DictValue& payload) const;
  // Every Open Profile (model order) for "all", else the one Profile of
  // ProfileFromPayload(). Never empty while the service runs.
  std::vector<ProfileID> ProfilesFromPayload(
      const base::DictValue& payload) const;
  content::WebUI* web_ui() const;

  static void ReplyOk(Reply reply, base::Value value);
  static void ReplyOk(Reply reply, base::DictValue value);
  static void ReplyError(Reply reply, std::string message);

 private:
  raw_ptr<OpenWebUIMessageHandler> handler_;
};

// --- open.rpc ----------------------------------------------------------------
//
// chrome.send("open.rpc", [requestId, method, payload]) ->
//   window.__openRpcResolve(requestId, ok, resultOrError)
// Push events: window.__openRpcEvent(eventName, payload).
//
// Payloads come from the renderer and are untrusted: every domain validates
// its fields (open_json.h *FromValue). A request id is echoed only as a
// number; unknown methods and malformed calls resolve with ok = false.
class OpenWebUIMessageHandler : public content::WebUIMessageHandler,
                                public OpenBrowserService::Observer {
 public:
  explicit OpenWebUIMessageHandler(std::string host);
  ~OpenWebUIMessageHandler() override;

  OpenWebUIMessageHandler(const OpenWebUIMessageHandler&) = delete;
  OpenWebUIMessageHandler& operator=(const OpenWebUIMessageHandler&) = delete;

  void AddDomain(std::unique_ptr<OpenRpcDomain> domain);
  void AddMethod(std::string_view method, OpenRpcDomain::Method handler);
  void EmitEvent(std::string_view event_name, base::Value payload);

  const std::string& host() const { return host_; }
  content::WebUI* page_web_ui() { return web_ui(); }

  // content::WebUIMessageHandler:
  void RegisterMessages() override;
  void OnJavascriptAllowed() override;
  void OnJavascriptDisallowed() override;

  // OpenBrowserService::Observer:
  void OnOpenEvent(const std::string& event_name,
                   const base::Value& payload) override;

 private:
  void HandleRpc(const base::ListValue& args);
  void Resolve(double request_id,
               base::expected<base::Value, std::string> result);

  const std::string host_;
  std::vector<std::unique_ptr<OpenRpcDomain>> domains_;
  std::map<std::string, OpenRpcDomain::Method, std::less<>> methods_;
  bool observing_service_ = false;
  base::WeakPtrFactory<OpenWebUIMessageHandler> weak_factory_{this};
};

// --- Controller and config ---------------------------------------------------

class OpenWebUIController : public content::WebUIController {
 public:
  OpenWebUIController(content::WebUI* web_ui, std::string_view host);
  ~OpenWebUIController() override;

  OpenWebUIController(const OpenWebUIController&) = delete;
  OpenWebUIController& operator=(const OpenWebUIController&) = delete;
};

class OpenWebUIConfig : public content::WebUIConfig {
 public:
  explicit OpenWebUIConfig(std::string_view host);
  ~OpenWebUIConfig() override;

  // content::WebUIConfig:
  bool IsWebUIEnabled(content::BrowserContext* browser_context) override;
  std::unique_ptr<content::WebUIController> CreateWebUIController(
      content::WebUI* web_ui,
      const GURL& url) override;

 private:
  const std::string open_host_;
};

}  // namespace open_unified::webui

#endif  // OPEN_UNIFIED_UI_WEBUI_OPEN_WEBUI_CONFIG_H_
