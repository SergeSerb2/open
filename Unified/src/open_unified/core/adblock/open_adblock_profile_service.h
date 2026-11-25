// Copyright 2026 The Open Authors. All rights reserved.
// Pure Chromium KeyedService wrapping //open/adblock (Rust adblock 0.8.11)
// directly — zero CEF headers.

#ifndef OPEN_UNIFIED_CORE_ADBLOCK_OPEN_ADBLOCK_PROFILE_SERVICE_H_
#define OPEN_UNIFIED_CORE_ADBLOCK_OPEN_ADBLOCK_PROFILE_SERVICE_H_

#include <memory>
#include <optional>
#include <set>
#include <string>
#include <string_view>
#include <vector>

#include "base/files/file_path.h"
#include "base/functional/callback.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/scoped_refptr.h"
#include "base/memory/weak_ptr.h"
#include "base/no_destructor.h"
#include "base/task/sequenced_task_runner.h"
#include "components/keyed_service/content/browser_context_keyed_service_factory.h"
#include "components/keyed_service/core/keyed_service.h"
#include "open/adblock/open_adblock_service.h"
#include "open/adblock/open_adblock_types.h"
#include "services/service_manager/public/cpp/binder_registry.h"

namespace content {
class BrowserContext;
class WebContents;
}  // namespace content

namespace open_unified {

// Metadata for one entry in the 46-list Open AdBlock catalog.
struct AdBlockListInfo {
  std::string id;
  std::string display_name;
  std::string category;  // "generic", "cookies", "privacy", "regional", "bcny"
  std::string info_url;
  std::vector<std::string> urls;
  bool bundled = false;
  bool default_enabled = false;
  std::optional<std::string> unavailable_reason;
};

struct AdBlockProfileSnapshot {
  bool enabled = true;
  bool is_off_the_record = false;
  open_engine::AdBlockStatus engine_status;
  std::vector<std::string> enabled_list_ids;
  std::vector<std::string> excluded_domains;
};

// Per-Profile KeyedService owning open_engine::OpenAdBlockService, managing
// the 46-list catalog, AdBlock/lists/current.json, AdBlock/exclusions.json,
// OTR sharing of parent immutable engine, StoragePartition URLLoaderFactory
// resets, and blocked count queries via OpenAdBlockTabHelper.
class OpenAdBlockProfileService : public KeyedService {
 public:
  using StatusObserver =
      base::RepeatingCallback<void(const AdBlockProfileSnapshot&)>;

  explicit OpenAdBlockProfileService(content::BrowserContext* browser_context);
  ~OpenAdBlockProfileService() override;

  OpenAdBlockProfileService(const OpenAdBlockProfileService&) = delete;
  OpenAdBlockProfileService& operator=(const OpenAdBlockProfileService&) =
      delete;

  // Convenience accessor through OpenAdBlockProfileServiceFactory.
  static OpenAdBlockProfileService* GetForBrowserContext(
      content::BrowserContext* context);

  // Returns the complete built-in 46-list AdBlock catalog.
  static const std::vector<AdBlockListInfo>& GetCatalog();
  static const AdBlockListInfo* FindCatalogList(std::string_view list_id);

  // KeyedService:
  void Shutdown() override;

  // Underlying //open/adblock service and matcher for Chromium hooks
  // (MaybeProxyURLLoaderFactoryForAdBlock, AdBlockCreateWebSocket,
  // AdBlockWillCreateWebTransport).
  open_engine::OpenAdBlockService* service() const { return service_.get(); }
  open_engine::OpenAdBlockService* engine_service() const {
    return service_.get();
  }
  scoped_refptr<open_engine::OpenAdBlockMatcher> matcher() const {
    return service_ ? service_->matcher() : nullptr;
  }

  // Shares a parent profile's immutable engine/lists directory for OTR contexts.
  void BindOffTheRecordParent(OpenAdBlockProfileService* parent);

  // Exposes Mojo cosmetic filtering interfaces to a renderer process.
  void ExposeInterfacesToRenderer(service_manager::BinderRegistry* registry);

  // Master switch for this profile. Persists on regular profiles and calls
  // ResetURLLoaderFactories() so active tabs update immediately.
  void SetEnabled(bool enabled);
  bool IsEnabled() const;

  // 46-list catalog selection management.
  std::vector<std::string> GetEnabledListIds() const;
  std::vector<std::string> EnabledLists() const { return GetEnabledListIds(); }
  bool SetListEnabled(std::string_view list_id, bool enabled);
  void SetEnabledListIds(std::vector<std::string> list_ids);

  // Per-host exclusion rules (persisted to AdBlock/exclusions.json on regular
  // profiles; ephemeral in-memory on OTR/Incognito profiles).
  std::vector<std::string> GetExcludedDomains() const;
  bool IsHostExcluded(std::string_view host) const;
  bool AddExcludedDomain(std::string_view domain);
  bool RemoveExcludedDomain(std::string_view domain);
  void SetExcludedDomains(std::vector<std::string> domains);

  // Reloads AdBlock/lists/current.json (and engine.dat when valid) into the
  // Rust engine. For OTR profiles, reloads from the parent profile's lists dir
  // so both share the exact same immutable EngineHolder via
  // OpenAdBlockEngineRegistry.
  void ReloadLists(
      base::OnceCallback<void(open_engine::AdBlockLoadResult)> done = {});

  // Publishes a new generation under AdBlock/lists/generations/<n>/ with
  // manifest.json and atomic AdBlock/lists/current.json on a blocking
  // ThreadPool sequence, then triggers reload on completion.
  bool PublishGeneration(
      const std::vector<std::pair<std::string, std::string>>& list_id_and_text,
      std::string_view resources_json = {},
      base::OnceCallback<void(bool)> done = {});

  // Resets all loaded StoragePartition URLLoaderFactories on this Profile so
  // network hooks immediately attach/detach the adblock proxy.
  void ResetURLLoaderFactories();

  // Per-tab blocked/redirected counters backed by OpenAdBlockTabHelper.
  static void EnsureTabHelper(content::WebContents* web_contents);
  static int GetBlockedCount(content::WebContents* web_contents);
  static int GetRedirectedCount(content::WebContents* web_contents);
  static int GetTotalStoppedCount(content::WebContents* web_contents);

  AdBlockProfileSnapshot GetSnapshot() const;
  void SetStatusObserver(StatusObserver observer);

  base::FilePath adblock_dir() const { return adblock_dir_; }
  base::FilePath lists_dir() const { return lists_dir_; }
  bool is_off_the_record() const { return is_off_the_record_; }

 private:
  struct DiskState {
    DiskState();
    DiskState(DiskState&&) noexcept;
    DiskState& operator=(DiskState&&) noexcept;
    ~DiskState();

    bool has_config = false;
    bool enabled = true;
    bool has_enabled_lists = false;
    std::set<std::string> enabled_list_ids;
    bool has_exclusions = false;
    std::set<std::string> excluded_domains;
  };

  void InitializeFromDisk();
  void OnDiskStateLoaded(DiskState state);
  static DiskState ReadDiskStateOnBlockingSequence(base::FilePath adblock_dir);
  void InitializeFromParent(OpenAdBlockProfileService* parent);
  void ApplyExclusionsToEngine();
  bool SaveExclusionsToDisk() const;
  bool SaveConfigToDisk() const;
  void OnEngineStatusChanged(const open_engine::AdBlockStatus& status);
  int ClearRendererCachesOnNavigation() const;
  static int ClearRendererCachesForService(
      base::WeakPtr<OpenAdBlockProfileService> self);
  static void OnGenerationPublishedReply(
      base::WeakPtr<OpenAdBlockProfileService> self,
      base::OnceCallback<void(bool)> done,
      bool ok);
  static void OnReloadListsReply(
      base::WeakPtr<OpenAdBlockProfileService> self,
      base::OnceCallback<void(open_engine::AdBlockLoadResult)> done,
      bool has_current);
  static std::optional<std::string> NormalizeHost(std::string_view raw);

  raw_ptr<content::BrowserContext> browser_context_;
  const bool is_off_the_record_;
  base::FilePath adblock_dir_;
  base::FilePath lists_dir_;
  scoped_refptr<base::SequencedTaskRunner> io_task_runner_;

  std::unique_ptr<open_engine::OpenAdBlockService> service_;
  bool enabled_ = true;
  bool config_mutated_ = false;
  bool exclusions_mutated_ = false;
  bool bound_to_parent_ = false;
  std::set<std::string> enabled_list_ids_;
  std::set<std::string> excluded_domains_;
  StatusObserver status_observer_;
  base::WeakPtrFactory<OpenAdBlockProfileService> weak_factory_{this};
};

// BrowserContextKeyedServiceFactory for OpenAdBlockProfileService.
// Gives OTR contexts their own instance (for ephemeral per-session exclusions)
// sharing the parent profile's immutable engine via OpenAdBlockEngineRegistry.
class OpenAdBlockProfileServiceFactory
    : public BrowserContextKeyedServiceFactory {
 public:
  static OpenAdBlockProfileService* GetForBrowserContext(
      content::BrowserContext* context);
  static OpenAdBlockProfileServiceFactory* GetInstance();

  OpenAdBlockProfileServiceFactory(const OpenAdBlockProfileServiceFactory&) =
      delete;
  OpenAdBlockProfileServiceFactory& operator=(
      const OpenAdBlockProfileServiceFactory&) = delete;

 private:
  friend base::NoDestructor<OpenAdBlockProfileServiceFactory>;

  OpenAdBlockProfileServiceFactory();
  ~OpenAdBlockProfileServiceFactory() override;

  // BrowserContextKeyedServiceFactory:
  content::BrowserContext* GetBrowserContextToUse(
      content::BrowserContext* context) const override;
  std::unique_ptr<KeyedService> BuildServiceInstanceForBrowserContext(
      content::BrowserContext* context) const override;
};

}  // namespace open_unified

#endif  // OPEN_UNIFIED_CORE_ADBLOCK_OPEN_ADBLOCK_PROFILE_SERVICE_H_
