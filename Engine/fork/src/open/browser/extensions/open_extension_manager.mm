// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license in LICENSE.
// P3: the profile registry and consent bridge. Chromium owns all state.
#import <AppKit/AppKit.h>
#include "cef/include/cef_extension_manager.h"
#include "open/browser/extensions/open_extension_hooks.h"
#include "base/command_line.h"
#include "base/one_shot_event.h"
#include "ui/strings/grit/ui_strings.h"
#include "base/functional/bind.h"
#include "base/memory/weak_ptr.h"
#include "base/no_destructor.h"
#include "base/strings/sys_string_conversions.h"
#include "base/strings/utf_string_conversions.h"
#include "base/task/single_thread_task_runner.h"
#include "cef/libcef/browser/browser_host_base.h"
#include "cef/libcef/browser/browser_info.h"
#include "cef/libcef/browser/browser_info_manager.h"
#include "cef/libcef/browser/request_context_impl.h"
#include "cef/libcef/browser/thread_util.h"
#include "chrome/browser/extensions/commands/command_service.h"
#include "chrome/browser/extensions/extension_commands_global_registry.h"
#include "chrome/browser/extensions/extension_tab_util.h"
#include "chrome/browser/extensions/webstore_install_with_prompt.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/common/extensions/api/omnibox/omnibox_handler.h"
#include "chrome/grit/generated_resources.h"
#include "components/crx_file/id_util.h"
#include "components/download/public/common/download_item.h"
#include "components/download/public/common/download_source.h"
#include "content/public/browser/download_item_utils.h"
#include "content/public/browser/web_contents.h"
#include "extensions/browser/crx_installer.h"
#include "extensions/browser/event_router.h"
#include "extensions/browser/extension_prefs.h"
#include "extensions/browser/extension_registrar.h"
#include "extensions/browser/extension_system.h"
#include "extensions/browser/load_error_reporter.h"
#include "extensions/browser/permissions/active_tab_permission_granter.h"
#include "extensions/browser/ui_util.h"
#include "extensions/common/mojom/context_type.mojom.h"
#include "extensions/common/api/extension_action/action_info.h"
#include "extensions/common/manifest_handlers/icons_handler.h"
#include "extensions/common/manifest_handlers/manifest_url_handlers.h"
#include "extensions/common/manifest_handlers/options_page_info.h"
#include "extensions/common/manifest_handlers/permissions_parser.h"
#include "extensions/common/permissions/permission_set.h"
#include "ui/base/accelerators/platform_accelerator_cocoa.h"
#include "ui/base/l10n/l10n_util.h"
#include "ui/gfx/image/image.h"
#include <map>

namespace open_engine {
namespace {
using extensions::Extension;
using extensions::InstallPromptData;
using extensions::ExtensionInstallPromptClient;
class Manager;
// Non-owning, UI-thread only. Profile observations remove entries at shutdown.
auto& Managers() {
  static base::NoDestructor<std::map<Profile*, Manager*>> managers;
  return *managers;
}
constexpr size_t kMaxExtensions = 1024;
constexpr size_t kMaxItems = 1024;
constexpr size_t kMaxText = 65536;
// guess (child): bound concurrent management requests and their dummy pages.
constexpr size_t kMaxPendingInstalls = 32;
// Bridges never decode arbitrary manifests. Chromium validates and localizes
// them first. Refuse oversized UI payloads; at most 1024 x 64 Ki UTF-16 per
// list (128 MiB plus bounded dictionaries), below the allocator ceiling.
void Text(CefRefPtr<CefDictionaryValue> d, const char* key,
          const std::string& value) {
  d->SetString(key, value.size() <= kMaxText ? value : std::string());
}
CefRefPtr<CefListValue> Strings(const std::vector<std::string>& values) {
  auto list = CefListValue::Create();
  if (values.size() > kMaxItems) return list;
  for (const auto& s : values) {
    if (s.size() > kMaxText) return CefListValue::Create();
    list->SetString(list->GetSize(), s);
  }
  return list;
}
CefRefPtr<CefImage> Image(const gfx::Image& image) {
  if (image.IsEmpty()) return nullptr;
  auto bytes = image.As1xPNGBytes();
  auto out = CefImage::CreateImage();
  if (bytes && bytes->size() <= 4 * 1024 * 1024 &&
      out->AddPNG(1, bytes->data(), bytes->size())) return out;
  return nullptr;
}

class Prompt : public CefExtensionPrompt {
 public:
  Prompt(CefRefPtr<CefDictionaryValue> data, CefRefPtr<CefImage> icon,
         content::WebContents* contents, gfx::NativeWindow window,
         base::OnceCallback<void(bool)> done)
      : data_(data), icon_(icon), done_(std::move(done)),
        contents_(contents ? contents->GetWeakPtr() : nullptr), window_(window) {
    data_->SetBool("hasRequestingPage", contents != nullptr);
  }
  CefRefPtr<CefDictionaryValue> GetData() override { return data_->Copy(false); }
  CefRefPtr<CefImage> GetIcon() override { return icon_; }
  CefRefPtr<CefBrowser> GetBrowser() override;
  void SetOwner(base::WeakPtr<Manager> owner) { owner_ = owner; }
  base::WeakPtr<Prompt> GetWeakPtr() { return weak_.GetWeakPtr(); }
  void Answer(bool accept) override {
    CEF_REQUIRE_UIT();
    if (done_) {
      // The continuation may delete its source dialog, registrar or window.
      // Never run it inside an embedder callback or Chromium notification.
      base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
          FROM_HERE, base::BindOnce(std::move(done_), accept));
    }
  }
 private:
  ~Prompt() override {
    if (done_) {
      // Ref-counted API wrappers may release on a non-UI thread.
      CEF_POST_TASK(CEF_UIT, base::BindOnce(std::move(done_), false));
    }
  }
  CefRefPtr<CefDictionaryValue> data_;
  CefRefPtr<CefImage> icon_;
  base::OnceCallback<void(bool)> done_;
  base::WeakPtr<content::WebContents> contents_;
  gfx::NativeWindow window_;
  base::WeakPtr<Manager> owner_;
  base::WeakPtrFactory<Prompt> weak_{this};
  IMPLEMENT_REFCOUNTING(Prompt);
};

CefRefPtr<CefDictionaryValue> PromptData(const Extension* extension, int type) {
  auto data = CefDictionaryValue::Create();
  data->SetInt("type", type);
  Text(data, "id", extension ? extension->id() : "");
  Text(data, "name", extension ? extension->name() : "");
  data->SetList("permissions", CefListValue::Create());
  // Chromium 156 removed retained-files/devices from InstallPromptData.
  // Keep the public contract; this build has no such fields to forward.
  data->SetList("retainedFiles", CefListValue::Create());
  data->SetList("retainedDevices", CefListValue::Create());
  return data;
}

class ManagedWebstoreInstaller : public extensions::WebstoreInstallWithPrompt {
 public:
  using WebstoreInstallWithPrompt::WebstoreInstallWithPrompt;
  content::WebContents* Requestor() const { return GetWebContents(); }
};

class Manager : public CefExtensionManager,
                public extensions::ExtensionRegistryObserver,
                public extensions::CommandService::Observer,
                public extensions::LoadErrorReporter::Observer,
                public ProfileObserver,
                public extensions::ExtensionUninstallDialog::Delegate {
 public:
  Manager(CefRefPtr<CefRequestContext> context,
          CefRefPtr<CefExtensionManagerHandler> handler)
      : context_(context), handler_(handler) {}
  void Start() {
    static_cast<CefRequestContextImpl*>(context_.get())
        ->ExecuteWhenBrowserContextInitialized(base::BindOnce(
            &Manager::Initialize, weak_.GetWeakPtr()));
  }
  void Close() override {
    CEF_REQUIRE_UIT();
    weak_.InvalidateWeakPtrs();
    ready_ = false;
    handler_ = nullptr;
    for (auto& prompt : prompts_) if (prompt) prompt->Answer(false);
    prompts_.clear();
    webstore_requestors_.clear();
    uninstall_.reset();
    errors_.Reset();
    commands_.Reset();
    registry_.Reset();
    if (profile_) Managers().erase(profile_);
    profile_observation_.Reset();
    profile_ = nullptr;
    context_ = nullptr;
  }
  bool IsReady() override { CEF_REQUIRE_UIT_RETURN(false); return ready_; }
  CefRefPtr<CefListValue> GetInstalled() override {
    CEF_REQUIRE_UIT_RETURN(nullptr);
    auto out = CefListValue::Create();
    if (!profile_) return out;
    auto all = registry_.GetSource()->GenerateInstalledExtensionsSet();
    if (all.size() > kMaxExtensions) return out;
    for (const auto& extension : all) {
      if (!extensions::Manifest::IsComponentLocation(extension->location()))
        out->SetDictionary(out->GetSize(), Snapshot(extension.get()));
    }
    return out;
  }
  CefRefPtr<CefListValue> GetCommands() override {
    CEF_REQUIRE_UIT_RETURN(nullptr);
    auto out = CefListValue::Create();
    if (!ready_ || !commands_.IsObserving()) return out;
    for (const auto& extension : registry_.GetSource()->enabled_extensions()) {
      if (extensions::Manifest::IsComponentLocation(extension->location())) continue;
      ui::CommandMap named;
      commands_.GetSource()->GetNamedCommands(extension->id(),
          extensions::CommandService::ACTIVE, extensions::CommandService::ANY_SCOPE, &named);
      if (const auto* action = extensions::ActionInfo::GetExtensionActionInfo(extension.get())) {
        extensions::Command command;
        if (commands_.GetSource()->GetExtensionActionCommand(extension->id(), action->type,
              extensions::CommandService::ACTIVE, &command, nullptr))
          AppendCommand(out, extension->id(), command, true);
      }
      for (const auto& [name, command] : named)
        AppendCommand(out, extension->id(), command, false);
      if (out->GetSize() > kMaxItems) return CefListValue::Create();
    }
    return out;
  }
  void SetEnabled(const CefString& id, bool enabled) override {
    CEF_REQUIRE_UIT();
    auto* extension = Find(id);
    if (!extension) return;
    auto* registrar = extensions::ExtensionRegistrar::Get(profile_);
    if (!enabled) {
      registrar->DisableExtension(extension->id(),
          {extensions::disable_reason::DISABLE_USER_ACTION});
    } else if (extensions::ExtensionPrefs::Get(profile_)->GetDisableReasons(extension->id())
                   .contains(extensions::disable_reason::DISABLE_PERMISSIONS_INCREASE)) {
      // Do not bypass an update's new permissions by calling EnableExtension.
      auto prompt = std::make_unique<ExtensionInstallPrompt>(profile_, gfx::NativeWindow(),
          std::make_unique<InstallPromptData>(InstallPromptData::UNSET_PROMPT_TYPE));
      auto* raw = prompt.get();
      raw->ConfirmReEnable(base::BindOnce(
          [](base::WeakPtr<Manager> manager, std::string id,
             std::unique_ptr<ExtensionInstallPrompt> keep,
             ExtensionInstallPromptClient::DoneCallbackPayload payload) {
            if (manager && manager->profile_ &&
                (payload.result == ExtensionInstallPromptClient::Result::ACCEPTED ||
                 payload.result == ExtensionInstallPromptClient::Result::ACCEPTED_WITH_WITHHELD_PERMISSIONS)) {
              if (auto* e = manager->Find(id))
                extensions::ExtensionRegistrar::Get(manager->profile_)
                    ->GrantPermissionsAndEnableExtension(*e);
            }
          }, weak_.GetWeakPtr(), extension->id(), std::move(prompt)), extension, profile_);
    } else {
      registrar->EnableExtension(extension->id());
    }
  }
  void Reload(const CefString& id) override {
    CEF_REQUIRE_UIT();
    if (auto* e = Find(id)) extensions::ExtensionRegistrar::Get(profile_)->ReloadExtension(e->id());
  }
  void Uninstall(const CefString& id, CefWindowHandle window) override {
    CEF_REQUIRE_UIT();
    if (!Find(id) || uninstall_) return;
    uninstall_ = extensions::ExtensionUninstallDialog::Create(
        profile_, gfx::NativeWindow((__bridge NSWindow*)window), this);
    uninstall_->ConfirmUninstall(Find(id), extensions::UNINSTALL_REASON_USER_INITIATED,
                                 extensions::UNINSTALL_SOURCE_TOOLBAR_CONTEXT_MENU);
  }
  void InstallFromWebStore(const CefString& id, CefWindowHandle window,
      CefRefPtr<CefExtensionInstallCallback> callback) override {
    CEF_REQUIRE_UIT();
    if (!ready_ || !crx_file::id_util::IdIsValid(id.ToString())) {
      callback->OnComplete(false, "Extension system is not ready or id is invalid");
      return;
    }
    // CrxInstaller requires a persistent profile; preserve Chrome's refusal
    // instead of entering its CHECK for an off-the-record context.
    if (profile_->IsOffTheRecord()) {
      callback->OnComplete(false, "Extensions cannot be installed in an ephemeral profile");
      return;
    }
    const std::string item_id = id;
    if (webstore_requestors_.size() >= kMaxPendingInstalls || webstore_requestors_.contains(item_id)) {
      callback->OnComplete(false, "A Web Store install is already pending or the 32-install limit was reached");
      return;
    }
    auto installer = base::MakeRefCounted<ManagedWebstoreInstaller>(
        id, profile_, gfx::NativeWindow((__bridge NSWindow*)window), base::BindOnce(
            [](base::WeakPtr<Manager> owner, std::string id,
                CefRefPtr<CefExtensionInstallCallback> callback, bool success,
                const std::string& error, extensions::webstore_install::Result) {
              if (owner) owner->webstore_requestors_.erase(id);
              callback->OnComplete(success, error);
            }, weak_.GetWeakPtr(), item_id, callback));
    webstore_requestors_.emplace(item_id, installer->Requestor());
    installer->BeginInstall();
  }
  bool ExecuteCommand(const CefString& id, const CefString& name,
      CefRefPtr<CefBrowser> active_browser) override {
    CEF_REQUIRE_UIT_RETURN(false);
    auto* extension = Find(id);
    auto host = CefBrowserHostBase::FromBrowser(active_browser);
    auto* contents = host ? host->GetWebContents() : nullptr;
    if (!extension || !ready_ || !contents || contents->GetBrowserContext() != profile_ ||
        !registry_.GetSource()->enabled_extensions().Contains(extension->id())) return false;
    ui::CommandMap named;
    commands_.GetSource()->GetNamedCommands(id, extensions::CommandService::ACTIVE,
        extensions::CommandService::ANY_SCOPE, &named);
    auto command = named.find(name);
    if (command == named.end()) return false;
    auto* granter = extensions::ActiveTabPermissionGranter::FromWebContents(contents);
    if (granter && !command->second.accelerator().IsMediaKey()) granter->GrantIfRequested(extension);
    constexpr auto context_type = extensions::mojom::ContextType::kPrivilegedExtension;
    auto scrub = extensions::ExtensionTabUtil::GetScrubTabBehavior(extension, context_type, contents);
    base::ListValue args;
    args.Append(name.ToString());
    args.Append(extensions::ExtensionTabUtil::CreateTabObject(contents, scrub, extension).ToValue());
    auto event = std::make_unique<extensions::Event>(extensions::events::COMMANDS_ON_COMMAND,
        "commands.onCommand", std::move(args), profile_);
    event->user_gesture = extensions::EventRouter::UserGestureState::kEnabled;
    extensions::EventRouter::Get(profile_)->DispatchEventToExtension(id, std::move(event));
    return true;
  }
  bool InstallLocalCrx(const CefString& path, CefRefPtr<CefBrowser> browser) override {
    CEF_REQUIRE_UIT_RETURN(false);
    if (!ready_ || profile_->IsOffTheRecord() ||
        !base::CommandLine::ForCurrentProcess()->HasSwitch("open-automation") ||
        path.length() > 4096) return false;
    auto host = CefBrowserHostBase::FromBrowser(browser);
    auto* contents = host ? host->GetWebContents() : nullptr;
    if (!contents || contents->GetBrowserContext() != profile_) return false;
    auto client = std::make_unique<ExtensionInstallPrompt>(contents,
        std::make_unique<InstallPromptData>(InstallPromptData::UNSET_PROMPT_TYPE));
    client->SetSkipPostInstallUI(true);
    auto installer = extensions::CrxInstaller::Create(profile_, std::move(client));
    installer->set_allow_silent_install(false);
    installer->set_off_store_install_allow_reason(extensions::CrxInstaller::OffStoreInstallAllowedInTest);
    installer->InstallCrx(base::FilePath(path.ToString()));
    return true;
  }
  bool CanPrompt() { return handler_ && handler_->CanShowPrompt(); }
  Profile* profile() const { return profile_; }
  void Deliver(CefRefPtr<CefExtensionPrompt> prompt) {
    static_cast<Prompt*>(prompt.get())->SetOwner(weak_.GetWeakPtr());
    std::erase_if(prompts_, [](const auto& item) { return !item; });
    prompts_.push_back(static_cast<Prompt*>(prompt.get())->GetWeakPtr());
    Post(base::BindOnce([](base::WeakPtr<Manager> self, CefRefPtr<CefExtensionPrompt> prompt) {
      if (!self) return;
      CefRefPtr<Manager> keep = self.get();
      auto handler = keep->handler_;
      if (handler && handler->CanShowPrompt()) handler->OnPrompt(prompt);
    }, weak_.GetWeakPtr(), prompt));
  }
  CefRefPtr<CefDictionaryValue> Snapshot(const Extension* e) {
    auto d = CefDictionaryValue::Create();
    Text(d, "id", e->id()); Text(d, "name", e->name());
    Text(d, "version", e->version().GetString()); Text(d, "summary", e->manifest()->FindStringPath("description") ? *e->manifest()->FindStringPath("description") : "");
    Text(d, "path", e->path().value());
    Text(d, "options", extensions::OptionsPageInfo::GetOptionsPage(e).spec());
    Text(d, "homepage", extensions::ManifestURL::GetHomepageURL(e).spec());
    Text(d, "omniboxKeyword", extensions::OmniboxInfo::GetKeyword(e));
    auto icon = extensions::IconsInfo::GetIconResource(e, 128, ExtensionIconSet::Match::kBigger);
    Text(d, "iconPath", icon.GetFilePath().value());
    d->SetInt("manifestVersion", e->manifest_version());
    d->SetBool("enabled", registry_.GetSource()->enabled_extensions().Contains(e->id()));
    d->SetBool("unpacked", extensions::Manifest::IsUnpackedLocation(e->location()));
    d->SetBool("fromWebStore", e->from_webstore());
    const auto* action = extensions::ActionInfo::GetExtensionActionInfo(e);
    d->SetBool("hasAction", action != nullptr);
    if (action) { Text(d, "actionTitle", action->default_title); Text(d, "actionPopup", action->default_popup_url.spec()); }
    int reasons = 0;
    for (auto reason : extensions::ExtensionPrefs::Get(profile_)->GetDisableReasons(e->id())) reasons |= reason;
    d->SetInt("disableReasons", reasons);
    std::vector<std::string> permissions, hosts;
    if (const auto* p = &extensions::PermissionsParser::GetRequiredPermissions(e)) {
      for (const auto* api : p->apis()) permissions.push_back(api->name());
      for (const auto& host : p->explicit_hosts()) hosts.push_back(host.GetAsString());
    }
    d->SetList("permissions", Strings(permissions)); d->SetList("hostPermissions", Strings(hosts));
    return d;
  }
 private:
  ~Manager() override { DCHECK(!profile_); }
  const Extension* Find(const CefString& id) {
    return profile_ && crx_file::id_util::IdIsValid(id.ToString())
        ? registry_.GetSource()->GetInstalledExtension(id) : nullptr;
  }
  void Initialize() {
    if (!context_) return;
    profile_ = CefRequestContextImpl::GetProfile(context_);
    if (!profile_ || Managers().contains(profile_)) { profile_ = nullptr; return; }
    Managers()[profile_] = this;
    profile_observation_.Observe(profile_);
    registry_.Observe(extensions::ExtensionRegistry::Get(profile_));
    commands_.Observe(extensions::CommandService::Get(profile_));
    if (auto* reporter = extensions::LoadErrorReporter::GetInstance()) errors_.Observe(reporter);
    auto& hooks = GetExtensionHooks();
    hooks.show_install = &ShowInstall;
    hooks.create_uninstall = &CreateUninstall;
    hooks.allow_download_without_browser = &AllowWebstoreDownload;
    extensions::ExtensionSystem::Get(profile_)->ready().Post(FROM_HERE,
        base::BindOnce(&Manager::Ready, weak_.GetWeakPtr()));
  }
  void Ready() {
    ready_ = true;
    // BrowserWindowFeatures skips the window registry without a focus manager.
    // The profile global registry has no such dependency and registers OS keys.
    extensions::ExtensionCommandsGlobalRegistry::Get(profile_);
    CefRefPtr<Manager> keep = this;
    auto handler = handler_;
    if (handler) handler->OnReady();
  }
  static void Post(base::OnceClosure task) {
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(FROM_HERE, std::move(task));
  }
  void Changed() {
    Post(base::BindOnce([](base::WeakPtr<Manager> s) {
      if (!s) return;
      CefRefPtr<Manager> keep = s.get();
      auto handler = keep->handler_;
      if (handler) handler->OnChanged(false);
    }, weak_.GetWeakPtr()));
  }
  void CommandsChanged() {
    Post(base::BindOnce([](base::WeakPtr<Manager> s) {
      if (!s) return;
      CefRefPtr<Manager> keep = s.get();
      auto handler = keep->handler_;
      if (handler) handler->OnChanged(true);
    }, weak_.GetWeakPtr()));
  }
  static void AppendCommand(CefRefPtr<CefListValue> out, const std::string& id,
                            const ui::Command& command, bool action) {
    if (out->GetSize() > kMaxItems) return;
    auto d = CefDictionaryValue::Create();
    Text(d, "id", id); Text(d, "name", command.command_name());
    Text(d, "summary", base::UTF16ToUTF8(command.description()));
    auto* key = ui::GetKeyEquivalentAndModifierMaskFromAccelerator(command.accelerator());
    Text(d, "keyEquivalent", base::SysNSStringToUTF8(key.keyEquivalent));
    d->SetInt("modifierFlags", static_cast<int>(key.modifierMask));
    d->SetBool("global", command.global()); d->SetBool("actionCommand", action);
    out->SetDictionary(out->GetSize(), d);
  }
  void OnExtensionLoaded(content::BrowserContext*, const Extension*) override { Changed(); CommandsChanged(); }
  void OnExtensionUnloaded(content::BrowserContext*, const Extension*, extensions::UnloadedExtensionReason) override { Changed(); CommandsChanged(); }
  void OnExtensionInstalled(content::BrowserContext*, const Extension* e, bool is_update) override {
    Changed();
    if (extensions::Manifest::IsComponentLocation(e->location())) return;
    auto snapshot = Snapshot(e);
    // guess (child): the registry observer has no user-gesture argument.
    // A fresh non-policy install is user-originated; startup loads never arrive here.
    bool by_user = !is_update && !extensions::Manifest::IsPolicyLocation(e->location()) &&
                   e->location() != extensions::mojom::ManifestLocation::kCommandLine;
    Post(base::BindOnce([](base::WeakPtr<Manager> s, CefRefPtr<CefDictionaryValue> d, bool user) {
      if (!s) return;
      CefRefPtr<Manager> keep = s.get();
      auto handler = keep->handler_;
      if (handler) handler->OnInstalled(d, user);
    }, weak_.GetWeakPtr(), snapshot, by_user));
  }
  void OnExtensionUninstalled(content::BrowserContext*, const Extension*, extensions::UninstallReason) override { Changed(); CommandsChanged(); }
  void OnExtensionCommandAdded(const extensions::ExtensionId&, const std::string&) override { CommandsChanged(); }
  void OnExtensionCommandRemoved(const extensions::ExtensionId&, const std::string&) override { CommandsChanged(); }
  void OnCommandServiceDestroying() override { commands_.Reset(); }
  void OnShutdown(extensions::ExtensionRegistry*) override { registry_.Reset(); }
  void OnProfileWillBeDestroyed(Profile*) override { Close(); }
  void OnLoadFailure(content::BrowserContext* context, const base::FilePath& path,
                     const std::u16string& error) override {
    if (context != profile_ || path.value().size() > 4096 || error.size() > kMaxText) return;
    Post(base::BindOnce([](base::WeakPtr<Manager> s, std::string path, std::u16string error) {
      if (!s) return;
      CefRefPtr<Manager> keep = s.get();
      auto handler = keep->handler_;
      if (handler) handler->OnLoadFailed(path, error);
    }, weak_.GetWeakPtr(), path.value(), error));
  }
  void OnExtensionUninstallDialogClosed(bool, const std::u16string&) override {
    Post(base::BindOnce([](base::WeakPtr<Manager> s) { if (s) s->uninstall_.reset(); }, weak_.GetWeakPtr()));
  }
 public:
  static bool ShowInstall(std::unique_ptr<ExtensionInstallPromptShowParams>& params,
      ExtensionInstallPrompt::DoneCallback& done, std::unique_ptr<InstallPromptData>& data);
  static std::unique_ptr<extensions::ExtensionUninstallDialog> CreateUninstall(
      Profile*, gfx::NativeWindow, extensions::ExtensionUninstallDialog::Delegate*);
  static bool AllowWebstoreDownload(download::DownloadItem* item) {
    if (!item || item->GetDownloadSource() != download::DownloadSource::EXTENSION_INSTALLER) return false;
    auto* contents = content::DownloadItemUtils::GetWebContents(item);
    if (!contents) return false;
    auto found = Managers().find(Profile::FromBrowserContext(contents->GetBrowserContext()));
    if (found == Managers().end()) return false;
    for (const auto& [id, requestor] : found->second->webstore_requestors_)
      if (requestor == contents) return true;
    return false;
  }
 private:
  CefRefPtr<CefRequestContext> context_;
  CefRefPtr<CefExtensionManagerHandler> handler_;
  raw_ptr<Profile> profile_ = nullptr;
  bool ready_ = false;
  std::vector<base::WeakPtr<Prompt>> prompts_;
  // Installer-owned, UI-thread only; erased before its completion callback.
  // No real browsing page is used as a referrer for a management install.
  std::map<std::string, content::WebContents*> webstore_requestors_;
  std::unique_ptr<extensions::ExtensionUninstallDialog> uninstall_;
  base::ScopedObservation<Profile, ProfileObserver> profile_observation_{this};
  base::ScopedObservation<extensions::ExtensionRegistry, extensions::ExtensionRegistryObserver> registry_{this};
  base::ScopedObservation<extensions::CommandService, extensions::CommandService::Observer> commands_{this};
  base::ScopedObservation<extensions::LoadErrorReporter, extensions::LoadErrorReporter::Observer> errors_{this};
  base::WeakPtrFactory<Manager> weak_{this};
  IMPLEMENT_REFCOUNTING(Manager);
};

CefRefPtr<CefBrowser> Prompt::GetBrowser() {
  CEF_REQUIRE_UIT_RETURN(nullptr);
  if (!owner_ || !owner_->profile()) return nullptr;
  auto* contents = contents_.get();
  if (data_->GetBool("hasRequestingPage")) {
    // A destroyed requesting page must not become another page of its window.
    return contents && contents->GetBrowserContext() == owner_->profile()
        ? CefBrowserHostBase::GetBrowserForContents(contents) : nullptr;
  }
  if (!window_) return nullptr;
  // Chromium supplies only a native window for permissions.request/uninstall.
  // A shell window can contain several profiles. Resolve its browser only
  // through a page of this manager's profile, never another profile's page.
  for (const auto& info : CefBrowserInfoManager::GetInstance()->GetBrowserInfoList()) {
    auto browser = info->browser();
    auto* page = browser ? browser->GetWebContents() : nullptr;
    if (page && page->GetBrowserContext() == owner_->profile() &&
        browser->GetTopLevelNativeWindow() == window_) return browser;
  }
  return nullptr;
}

bool Manager::ShowInstall(std::unique_ptr<ExtensionInstallPromptShowParams>& params,
    ExtensionInstallPrompt::DoneCallback& done, std::unique_ptr<InstallPromptData>& source) {
  auto found = Managers().find(params->profile());
  if (found == Managers().end() || !found->second->CanPrompt()) return false;
  switch (source->type()) {
    case InstallPromptData::INSTALL_PROMPT:
    case InstallPromptData::RE_ENABLE_PROMPT:
    case InstallPromptData::PERMISSIONS_PROMPT:
    case InstallPromptData::EXTERNAL_INSTALL_PROMPT:
    case InstallPromptData::REMOTE_INSTALL_PROMPT:
    case InstallPromptData::REPAIR_PROMPT: break;
    default: return false;  // Preserve enterprise/parent-approval platform UI.
  }
  auto data = PromptData(source->extension(), source->type());
  Text(data, "title", base::UTF16ToUTF8(source->GetDialogTitle()));
  Text(data, "acceptLabel", base::UTF16ToUTF8(source->GetAcceptButtonLabel()));
  Text(data, "cancelLabel", base::UTF16ToUTF8(source->GetAbortButtonLabel()));
  auto permissions = source->GetPermissions();
  if (permissions.permissions.size() > kMaxItems || permissions.details.size() > kMaxItems) return false;
  auto list = CefListValue::Create();
  for (size_t i = 0; i < permissions.permissions.size(); ++i) {
    if (permissions.permissions[i].size() > kMaxText ||
        (i < permissions.details.size() && permissions.details[i].size() > kMaxText)) {
      LOG(WARNING) << "Open extension prompt exceeds the 64 KiB permission text limit";
      return false;
    }
    auto line = CefDictionaryValue::Create();
    Text(line, "message", base::UTF16ToUTF8(permissions.permissions[i]));
    // Chromium formats details as newline-separated messages for each permission.
    auto details = CefListValue::Create();
    if (i < permissions.details.size() && !permissions.details[i].empty())
      details->SetString(0, permissions.details[i]);
    line->SetList("details", details); list->SetDictionary(i, line);
  }
  data->SetList("permissions", list);
  auto icon = Image(source->icon());
  auto* contents = params->GetParentWebContents();
  auto window = params->GetParentWindow();
  source->OnDialogOpened();
  auto callback = base::BindOnce([](std::unique_ptr<ExtensionInstallPromptShowParams> params,
      std::unique_ptr<InstallPromptData> source, ExtensionInstallPrompt::DoneCallback done, bool accept) {
    using Result = ExtensionInstallPromptClient::Result;
    if (params->WasParentDestroyed()) {
      std::move(done).Run(ExtensionInstallPromptClient::DoneCallbackPayload(Result::ABORTED));
      return;
    }
    if (accept) source->OnDialogAccepted(); else source->OnDialogCanceled();
    auto result = accept ? (source->ShouldWithheldPermissionsOnDialogAccept()
        ? Result::ACCEPTED_WITH_WITHHELD_PERMISSIONS : Result::ACCEPTED) : Result::USER_CANCELED;
    std::move(done).Run(ExtensionInstallPromptClient::DoneCallbackPayload(result));
  }, std::move(params), std::move(source), std::move(done));
  found->second->Deliver(new Prompt(data, icon, contents, window, std::move(callback)));
  return true;
}

class UninstallDialog : public extensions::ExtensionUninstallDialog {
 public:
  UninstallDialog(Profile* profile, gfx::NativeWindow parent, Delegate* delegate)
      : ExtensionUninstallDialog(profile, parent, delegate), profile_(profile) {}
 private:
  void Show() override {
    auto data = PromptData(extension(), 100);
    Text(data, "title", base::UTF16ToUTF8(l10n_util::GetStringFUTF16(
        IDS_EXTENSION_PROMPT_UNINSTALL_TITLE,
        extensions::ui_util::GetFixupExtensionNameForUIDisplay(extension()->name()))));
    Text(data, "acceptLabel", base::UTF16ToUTF8(l10n_util::GetStringUTF16(IDS_EXTENSION_PROMPT_UNINSTALL_BUTTON)));
    Text(data, "cancelLabel", base::UTF16ToUTF8(l10n_util::GetStringUTF16(IDS_APP_CANCEL)));
    if (triggering_extension()) Text(data, "triggeringExtensionName", triggering_extension()->name());
    auto weak = AsWeakPtr();
    auto prompt = CefRefPtr<Prompt>(new Prompt(data, Image(gfx::Image(icon())), nullptr, parent(),
        base::BindOnce([](base::WeakPtr<ExtensionUninstallDialog> dialog, bool accept) {
          if (dialog) dialog->OnDialogClosed(accept ? CLOSE_ACTION_UNINSTALL : CLOSE_ACTION_CANCELED);
        }, weak)));
    prompt_ = prompt->GetWeakPtr();
    auto found = Managers().find(profile_);
    if (found != Managers().end() && found->second->CanPrompt()) found->second->Deliver(prompt);
    else prompt->Answer(false);
  }
  void Close() override {
    if (auto prompt = prompt_.get()) prompt->Answer(false);
    prompt_.reset();
  }
  raw_ptr<Profile> profile_;
  // Weak ownership: releasing the shell's prompt cancels, even while the
  // dialog object remains owned by its Chromium caller.
  base::WeakPtr<Prompt> prompt_;
};
std::unique_ptr<extensions::ExtensionUninstallDialog> Manager::CreateUninstall(
    Profile* profile, gfx::NativeWindow parent, extensions::ExtensionUninstallDialog::Delegate* delegate) {
  auto found = Managers().find(profile);
  if (found == Managers().end() || !found->second->CanPrompt()) return nullptr;
  return std::make_unique<UninstallDialog>(profile, parent, delegate);
}
}  // namespace
}  // namespace open_engine

CefRefPtr<CefExtensionManager> CefExtensionManager::Create(
    CefRefPtr<CefRequestContext> context, CefRefPtr<CefExtensionManagerHandler> handler) {
  CEF_REQUIRE_UIT_RETURN(nullptr);
  if (!context || !handler) return nullptr;
  CefRefPtr<open_engine::Manager> manager = new open_engine::Manager(context, handler);
  manager->Start();
  return manager;
}
