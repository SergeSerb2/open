// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "open_unified/ui/webui/open_webui_config.h"

#include <algorithm>
#include <utility>

#include "base/check.h"
#include "base/functional/bind.h"
#include "base/no_destructor.h"
#include "base/strings/strcat.h"
#include "base/strings/string_util.h"
#include "chrome/browser/profiles/profile.h"
#include "content/public/browser/browser_context.h"
#include "content/public/browser/browser_url_handler.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_ui.h"
#include "content/public/browser/web_ui_data_source.h"
#include "content/public/browser/webui_config_map.h"
#include "content/public/common/url_constants.h"
#include "open_unified/grit/open_webui_resources.h"
#include "open_unified/grit/open_webui_resources_map.h"
#include "open_unified/ui/webui/open_boosts_ui.h"
#include "open_unified/ui/webui/open_documents_ui.h"
#include "open_unified/ui/webui/open_library_ui.h"
#include "open_unified/ui/webui/open_onboarding_ui.h"
#include "open_unified/ui/webui/open_settings_ui.h"
#include "services/network/public/mojom/content_security_policy.mojom.h"
#include "ui/base/webui/resource_path.h"
#include "url/gurl.h"
#include "url/url_constants.h"

namespace open_unified::webui {

namespace {

constexpr char kInternalHostPrefix[] = "open-";

bool IsOpenHost(std::string_view host) {
  const auto& hosts = OpenHosts();
  return std::find(hosts.begin(), hosts.end(), host) != hosts.end();
}

// open://<host>/<path> -> chrome://open-<host>/<path> (forward, for loading).
bool RewriteOpenToChrome(GURL* url, content::BrowserContext* browser_context) {
  if (!url->SchemeIs(kOpenScheme) || !IsOpenHost(url->host())) {
    return false;
  }
  GURL::Replacements replacements;
  const std::string host = InternalHost(url->host());
  replacements.SetSchemeStr(content::kChromeUIScheme);
  replacements.SetHostStr(host);
  *url = url->ReplaceComponents(replacements);
  return true;
}

// chrome://open-<host>/<path> -> open://<host>/<path> (reverse, for display).
bool RewriteChromeToOpen(GURL* url, content::BrowserContext* browser_context) {
  if (!url->SchemeIs(content::kChromeUIScheme) ||
      !base::StartsWith(url->host(), kInternalHostPrefix)) {
    return false;
  }
  const std::string open_host(
      url->host().substr(sizeof(kInternalHostPrefix) - 1));
  if (!IsOpenHost(open_host)) {
    return false;
  }
  GURL::Replacements replacements;
  replacements.SetSchemeStr(kOpenScheme);
  replacements.SetHostStr(open_host);
  *url = url->ReplaceComponents(replacements);
  return true;
}

// The pak entry "<host>.html" (Vite input name; Unified/webui/vite.config.ts).
std::optional<int> PageResourceId(std::string_view host) {
  const std::string page = base::StrCat({host, ".html"});
  for (const ::webui::ResourcePath& resource : kOpenWebuiResources) {
    if (page == resource.path) {
      return resource.id;
    }
  }
  return std::nullopt;
}

void CreateDataSource(content::WebUI* web_ui, std::string_view host) {
  content::WebUIDataSource* source = content::WebUIDataSource::CreateAndAdd(
      web_ui->GetWebContents()->GetBrowserContext(), InternalHost(host));
  source->AddResourcePaths(kOpenWebuiResources);
  // Client-side routes (open://settings/extensions) fall back to the page.
  if (std::optional<int> page = PageResourceId(host)) {
    source->AddResourcePath("", *page);
    source->SetDefaultResource(*page);
  }

  // Strict CSP: only the bundled module scripts run; no remote content.
  using Directive = network::mojom::CSPDirectiveName;
  source->OverrideContentSecurityPolicy(Directive::DefaultSrc,
                                        "default-src 'self';");
  source->OverrideContentSecurityPolicy(Directive::ScriptSrc,
                                        "script-src 'self';");
  // Preact style={...} props write style attributes.
  source->OverrideContentSecurityPolicy(
      Directive::StyleSrc, "style-src 'self' 'unsafe-inline';");
  source->OverrideContentSecurityPolicy(
      Directive::ImgSrc, "img-src 'self' data: blob: chrome://favicon2;");
  source->OverrideContentSecurityPolicy(Directive::FontSrc,
                                        "font-src 'self' data:;");
  source->OverrideContentSecurityPolicy(Directive::ConnectSrc,
                                        "connect-src 'self';");
  source->OverrideContentSecurityPolicy(Directive::ObjectSrc,
                                        "object-src 'none';");
  source->OverrideContentSecurityPolicy(Directive::FrameAncestors,
                                        "frame-ancestors 'none';");
  source->OverrideContentSecurityPolicy(Directive::BaseURI,
                                        "base-uri 'self';");
  source->OverrideContentSecurityPolicy(Directive::FormAction,
                                        "form-action 'none';");
  // Vite's module preload helper creates <link> elements; Trusted Types
  // would need a policy for that and adds nothing for a bundle without
  // HTML sinks.
  source->DisableTrustedTypesCSP();
}

}  // namespace

// --- URLs -------------------------------------------------------------------

std::string OpenWebUIURL(std::string_view host, std::string_view path) {
  return base::StrCat({kOpenScheme, url::kStandardSchemeSeparator, host, "/",
                       path});
}

std::string InternalHost(std::string_view host) {
  return IsOpenHost(host) ? base::StrCat({kInternalHostPrefix, host})
                          : std::string();
}

const std::vector<std::string_view>& OpenHosts() {
  static const base::NoDestructor<std::vector<std::string_view>> hosts(
      std::vector<std::string_view>{kHostSettings, kHostLibrary, kHostBoosts,
                                    kHostEasel, kHostNote, kHostOnboarding,
                                    kHostWelcome});
  return *hosts;
}

void RegisterOpenWebUIConfigs() {
  auto& map = content::WebUIConfigMap::GetInstance();
  for (std::string_view host : OpenHosts()) {
    map.AddWebUIConfig(std::make_unique<OpenWebUIConfig>(host));
  }
}

void AddOpenURLHandlers(content::BrowserURLHandler* handler) {
  handler->AddHandlerPair(&RewriteOpenToChrome, &RewriteChromeToOpen);
}

// --- OpenRpcDomain -----------------------------------------------------------

OpenRpcDomain::OpenRpcDomain(OpenWebUIMessageHandler* handler)
    : handler_(handler) {}

OpenRpcDomain::~OpenRpcDomain() = default;

void OpenRpcDomain::Register(std::string_view method, Method method_handler) {
  handler_->AddMethod(method, std::move(method_handler));
}

void OpenRpcDomain::Emit(std::string_view event_name, base::Value payload) {
  handler_->EmitEvent(event_name, std::move(payload));
}

OpenBrowserService* OpenRpcDomain::service() const {
  return OpenBrowserService::Get();
}

::Profile* OpenRpcDomain::profile() const {
  return ::Profile::FromWebUI(handler_->page_web_ui());
}

ProfileID OpenRpcDomain::profile_id() const {
  OpenBrowserService* s = service();
  if (!s) {
    return ProfileID();
  }
  return s->OpenProfileIdFor(profile()).value_or(s->ActiveProfileId());
}

ProfileID OpenRpcDomain::ProfileFromPayload(
    const base::DictValue& payload) const {
  const std::string* id = payload.FindString("profile_id");
  if (id && service() && service()->model().FindProfile(*id)) {
    return *id;
  }
  return profile_id();
}

content::WebUI* OpenRpcDomain::web_ui() const {
  return handler_->page_web_ui();
}

// static
void OpenRpcDomain::ReplyOk(Reply reply, base::Value value) {
  std::move(reply).Run(std::move(value));
}

// static
void OpenRpcDomain::ReplyOk(Reply reply, base::DictValue value) {
  std::move(reply).Run(base::Value(std::move(value)));
}

// static
void OpenRpcDomain::ReplyError(Reply reply, std::string message) {
  std::move(reply).Run(base::unexpected(std::move(message)));
}

// --- OpenWebUIMessageHandler -------------------------------------------------

OpenWebUIMessageHandler::OpenWebUIMessageHandler(std::string host)
    : host_(std::move(host)) {}

OpenWebUIMessageHandler::~OpenWebUIMessageHandler() {
  if (observing_service_ && OpenBrowserService::Get()) {
    OpenBrowserService::Get()->RemoveObserver(this);
  }
}

void OpenWebUIMessageHandler::AddDomain(std::unique_ptr<OpenRpcDomain> domain) {
  domain->RegisterMethods();
  domains_.push_back(std::move(domain));
}

void OpenWebUIMessageHandler::AddMethod(std::string_view method,
                                        OpenRpcDomain::Method handler) {
  // One owner per method: a duplicate is a programming error.
  CHECK(methods_.emplace(std::string(method), std::move(handler)).second)
      << method;
}

void OpenWebUIMessageHandler::RegisterMessages() {
  web_ui()->RegisterMessageCallback(
      kRpcMessageName,
      base::BindRepeating(&OpenWebUIMessageHandler::HandleRpc,
                          base::Unretained(this)));
}

void OpenWebUIMessageHandler::OnJavascriptAllowed() {
  if (!observing_service_ && OpenBrowserService::Get()) {
    OpenBrowserService::Get()->AddObserver(this);
    observing_service_ = true;
  }
  for (auto& domain : domains_) {
    domain->OnJavascriptAllowed();
  }
}

void OpenWebUIMessageHandler::OnJavascriptDisallowed() {
  // Replies to requests of the old document are dropped.
  weak_factory_.InvalidateWeakPtrs();
  if (observing_service_ && OpenBrowserService::Get()) {
    OpenBrowserService::Get()->RemoveObserver(this);
  }
  observing_service_ = false;
  for (auto& domain : domains_) {
    domain->OnJavascriptDisallowed();
  }
}

void OpenWebUIMessageHandler::HandleRpc(const base::ListValue& args) {
  AllowJavascript();
  if (args.empty() || !(args[0].is_int() || args[0].is_double())) {
    return;  // No id to answer to.
  }
  const double request_id = args[0].GetDouble();
  if (args.size() < 2 || !args[1].is_string()) {
    Resolve(request_id, base::unexpected("malformed request"));
    return;
  }
  const std::string& method = args[1].GetString();
  auto it = methods_.find(method);
  if (it == methods_.end()) {
    Resolve(request_id, base::unexpected("unknown method " + method));
    return;
  }
  if (!OpenBrowserService::Get()) {
    Resolve(request_id, base::unexpected("browser is shutting down"));
    return;
  }
  base::DictValue payload;
  if (args.size() >= 3 && args[2].is_dict()) {
    payload = args[2].GetDict().Clone();
  }
  it->second.Run(payload,
                 base::BindOnce(&OpenWebUIMessageHandler::Resolve,
                                weak_factory_.GetWeakPtr(), request_id));
}

void OpenWebUIMessageHandler::Resolve(
    double request_id,
    base::expected<base::Value, std::string> result) {
  if (!IsJavascriptAllowed()) {
    return;
  }
  const bool ok = result.has_value();
  base::Value value = ok ? std::move(result).value()
                         : base::Value(std::move(result).error());
  CallJavascriptFunction("__openRpcResolve", base::Value(request_id),
                         base::Value(ok), value);
}

void OpenWebUIMessageHandler::EmitEvent(std::string_view event_name,
                                        base::Value payload) {
  if (!IsJavascriptAllowed()) {
    return;
  }
  // The page installs __openRpcEvent with its first subscription; before
  // that an event has no listener and is dropped without a page error.
  CallJavascriptFunction("(window.__openRpcEvent || (() => {}))",
                         base::Value(event_name), payload);
}

void OpenWebUIMessageHandler::OnOpenEvent(const std::string& event_name,
                                          const base::Value& payload) {
  EmitEvent(event_name, payload.Clone());
}

// --- Controller --------------------------------------------------------------

OpenWebUIController::OpenWebUIController(content::WebUI* web_ui,
                                         std::string_view host)
    : content::WebUIController(web_ui) {
  CreateDataSource(web_ui, host);
  auto handler = std::make_unique<OpenWebUIMessageHandler>(std::string(host));
  OpenWebUIMessageHandler* raw = handler.get();
  if (host == kHostSettings) {
    raw->AddDomain(std::make_unique<OpenSettingsUI>(raw));
  } else if (host == kHostLibrary) {
    raw->AddDomain(std::make_unique<OpenLibraryUI>(raw));
  } else if (host == kHostBoosts) {
    raw->AddDomain(std::make_unique<OpenBoostsUI>(raw));
  } else if (host == kHostEasel || host == kHostNote) {
    raw->AddDomain(std::make_unique<OpenDocumentsUI>(raw));
  } else if (host == kHostOnboarding || host == kHostWelcome) {
    raw->AddDomain(std::make_unique<OpenOnboardingUI>(raw));
  }
  web_ui->AddMessageHandler(std::move(handler));
}

OpenWebUIController::~OpenWebUIController() = default;

// --- Config ------------------------------------------------------------------

OpenWebUIConfig::OpenWebUIConfig(std::string_view host)
    : content::WebUIConfig(content::kChromeUIScheme, InternalHost(host)),
      open_host_(host) {}

OpenWebUIConfig::~OpenWebUIConfig() = default;

bool OpenWebUIConfig::IsWebUIEnabled(content::BrowserContext* browser_context) {
  // Open's pages read and change Profile data (history, archive, Boosts,
  // documents, settings): never in an off-the-record context, so an
  // incognito window cannot reach or write the original Profile's stores.
  return OpenBrowserService::Get() != nullptr && browser_context &&
         !browser_context->IsOffTheRecord();
}

std::unique_ptr<content::WebUIController>
OpenWebUIConfig::CreateWebUIController(content::WebUI* web_ui,
                                       const GURL& url) {
  return std::make_unique<OpenWebUIController>(web_ui, open_host_);
}

}  // namespace open_unified::webui
