// Copyright 2026 The Open Authors. All rights reserved.
// Pure Chromium KeyedService wrapping //open/adblock (Rust adblock 0.8.11)
// directly — zero CEF headers.

#ifndef OPEN_UNIFIED_CORE_ADBLOCK_OPEN_ADBLOCK_PROFILE_SERVICE_H_
#define OPEN_UNIFIED_CORE_ADBLOCK_OPEN_ADBLOCK_PROFILE_SERVICE_H_

#include <cstdint>
#include <map>
#include <memory>
#include <optional>
#include <set>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include "base/files/file_path.h"
#include "base/functional/callback.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/scoped_refptr.h"
#include "base/memory/weak_ptr.h"
#include "base/no_destructor.h"
#include "base/observer_list.h"
#include "base/observer_list_types.h"
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

namespace network {
class SharedURLLoaderFactory;
class SimpleURLLoader;
}  // namespace network

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

// Per-list receipt metadata tracking bundled/downloaded state and errors.
struct AdBlockListReceipt {
  AdBlockListReceipt();
  AdBlockListReceipt(const AdBlockListReceipt&);
  AdBlockListReceipt(AdBlockListReceipt&&) noexcept;
  AdBlockListReceipt& operator=(const AdBlockListReceipt&);
  AdBlockListReceipt& operator=(AdBlockListReceipt&&) noexcept;
  ~AdBlockListReceipt();

  std::string list_id;
  std::string source;  // "bundled" or "downloaded"
  int64_t last_updated_ms = 0;
  int rule_count = 0;
  int64_t bytes = 0;
  std::string sha256;
  std::string etag;
  std::string last_modified;
  std::string last_error;
};

struct AdBlockProfileSnapshot {
  AdBlockProfileSnapshot();
  AdBlockProfileSnapshot(const AdBlockProfileSnapshot&);
  AdBlockProfileSnapshot(AdBlockProfileSnapshot&&) noexcept;
  AdBlockProfileSnapshot& operator=(const AdBlockProfileSnapshot&);
  AdBlockProfileSnapshot& operator=(AdBlockProfileSnapshot&&) noexcept;
  ~AdBlockProfileSnapshot();

  bool enabled = true;
  bool is_off_the_record = false;
  bool is_updating = false;
  open_engine::AdBlockStatus engine_status;
  std::vector<std::string> enabled_list_ids;
  std::vector<std::string> excluded_domains;
  std::map<std::string, AdBlockListReceipt> list_receipts;
  std::string last_error;
};

// Per-Profile KeyedService owning open_engine::OpenAdBlockService, managing
// the 46-list catalog, bundled startup seeding, live list downloads/updates,
// AdBlock/lists/current.json, AdBlock/exclusions.json, OTR sharing of parent
// immutable engine, StoragePartition URLLoaderFactory resets, and live
// blocked count notifications via OpenAdBlockTabHelper.
class OpenAdBlockProfileService : public KeyedService {
 public:
  class Observer : public base::CheckedObserver {
   public:
    virtual void OnAdBlockStateChanged(const std::string& profile_id) {}
    virtual void OnAdBlockBlockedCountChanged(
        content::WebContents* web_contents,
        int count) {}

   protected:
    ~Observer() override = default;
  };

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

  // Resolves the bundled AdBlock resources directory (easylist.txt,
  // easyprivacy.txt, resources.json) relative to the running executable /
  // macOS app bundle (or OPEN_ADBLOCK_BUNDLED_DIR).
  static base::FilePath ResolveBundledResourcesDir();
  static void SetBundledResourcesDirForTesting(base::FilePath dir);

  // Public Suffix List (PSL) registrable-domain / IP validation and
  // normalization matching Open's exclusion contract.
  static bool IsPlausibleHost(std::string_view raw);
  static std::optional<std::string> NormalizeExclusionDomain(
      std::string_view raw);

  // KeyedService:
  void Shutdown() override;

  // Profile identifier reported in Observer::OnAdBlockStateChanged().
  void SetProfileId(std::string profile_id);
  const std::string& profile_id() const { return profile_id_; }

  // Observers for Settings and Site Control Center live updates.
  void AddObserver(Observer* observer);
  void RemoveObserver(Observer* observer);
  void NotifyBlockedCountChanged(content::WebContents* web_contents, int count);
  static void NotifyTabBlockedCountChanged(content::WebContents* web_contents,
                                           int count);

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

  // 46-list catalog selection management. Toggling any list immediately
  // recompiles enabled lists + custom rules + resources.json off-thread and
  // calls PublishGeneration() + NotifyUpdated().
  std::vector<std::string> GetEnabledListIds() const;
  std::vector<std::string> EnabledLists() const { return GetEnabledListIds(); }
  bool SetListEnabled(std::string_view list_id, bool enabled);
  void SetEnabledListIds(std::vector<std::string> list_ids);

  // Per-list receipts (bundled/downloaded source, timestamps, rule counts).
  std::optional<AdBlockListReceipt> GetListReceipt(
      std::string_view list_id) const;
  const std::map<std::string, AdBlockListReceipt>& GetListReceipts() const {
    return list_receipts_;
  }

  // Optional user custom filter rules compiled alongside enabled lists.
  std::string GetCustomRules() const { return custom_rules_; }
  void SetCustomRules(std::string rules,
                      base::OnceCallback<void(bool)> done = {});

  // Downloads fresh filter list texts for all enabled lists (or downloads
  // missing non-bundled enabled lists), updates cache + receipts, recompiles
  // off-thread, and publishes a new generation. If |url_loader_factory| is
  // null, falls back to the profile's default StoragePartition loader factory.
  void UpdateListsNow(
      scoped_refptr<network::SharedURLLoaderFactory> url_loader_factory,
      base::OnceCallback<void(bool)> done = {});

  // Resets enabled lists to catalog defaults (EasyList + EasyPrivacy), wipes
  // downloaded list caches, re-seeds from bundled filter lists, and publishes
  // a fresh generation.
  void ResetLists(base::OnceCallback<void(bool)> done = {});

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
  base::FilePath cache_dir() const { return cache_dir_; }
  bool is_off_the_record() const { return is_off_the_record_; }
  bool is_updating() const { return is_updating_; }

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
    std::map<std::string, AdBlockListReceipt> list_receipts;
    std::string custom_rules;
    bool has_exclusions = false;
    std::set<std::string> excluded_domains;
    bool has_current_generation = false;
  };

  struct CompileInputs {
    CompileInputs();
    CompileInputs(CompileInputs&&) noexcept;
    CompileInputs& operator=(CompileInputs&&) noexcept;
    ~CompileInputs();

    std::vector<std::pair<std::string, std::string>> list_id_and_text;
    std::string resources_json;
    std::map<std::string, AdBlockListReceipt> updated_receipts;
    std::vector<std::string> missing_list_ids;
  };

  struct ListDownloadBatch;
  struct PendingListDownload;

  void InitializeFromDisk();
  void OnDiskStateLoaded(DiskState state);
  static DiskState ReadDiskStateOnBlockingSequence(base::FilePath adblock_dir,
                                                   base::FilePath lists_dir);
  static CompileInputs PrepareCompileInputsOnBlockingSequence(
      base::FilePath cache_dir,
      base::FilePath bundled_dir,
      std::vector<std::string> enabled_list_ids,
      std::map<std::string, AdBlockListReceipt> existing_receipts,
      std::string custom_rules,
      bool force_reseed_bundled,
      bool wipe_cache_first);

  void RecompileEnabledLists(bool force_reseed_bundled = false,
                             bool wipe_cache_first = false,
                             bool auto_download_missing = false,
                             base::OnceCallback<void(bool)> done = {});
  void OnCompileInputsPrepared(uint64_t compile_seq,
                               bool auto_download_missing,
                               base::OnceCallback<void(bool)> done,
                               CompileInputs inputs);

  scoped_refptr<network::SharedURLLoaderFactory> GetDefaultURLLoaderFactory()
      const;
  void DownloadSpecificLists(
      std::vector<std::string> list_ids,
      scoped_refptr<network::SharedURLLoaderFactory> url_loader_factory,
      base::OnceCallback<void(bool)> done);
  void StartNextUrlInBatch(uint64_t batch_id);
  void OnSingleUrlDownloaded(uint64_t batch_id,
                             std::string list_id,
                             size_t url_index,
                             base::FilePath temp_file);
  void OnDownloadedPartProcessed(uint64_t batch_id,
                                 std::string list_id,
                                 size_t url_index,
                                 std::optional<std::string> body,
                                 std::string etag,
                                 std::string last_modified,
                                 bool not_modified,
                                 std::string error);
  void FinalizeListDownloadInBatch(uint64_t batch_id,
                                   const std::string& list_id);
  void OnListCacheWritten(uint64_t batch_id,
                          std::string list_id,
                          AdBlockListReceipt receipt,
                          bool ok);
  void FinishDownloadBatch(uint64_t batch_id);

  void InitializeFromParent(OpenAdBlockProfileService* parent);
  void AddOffTheRecordChild(OpenAdBlockProfileService* child);
  void RemoveOffTheRecordChild(OpenAdBlockProfileService* child);
  void OnParentShutdown();
  void OnParentEnabledChanged(bool enabled);
  void OnParentEnabledListsChanged(const std::set<std::string>& enabled_lists);
  void OnParentExcludedDomainAdded(const std::string& domain);
  void OnParentExcludedDomainRemoved(const std::string& domain);
  void OnParentExcludedDomainsReplaced(const std::set<std::string>& domains);
  void OnParentGenerationPublished();
  void ApplyExclusionsToEngine();
  bool SaveExclusionsToDisk() const;
  bool SaveConfigToDisk() const;
  void NotifyUpdated();
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
  std::string profile_id_;
  base::FilePath adblock_dir_;
  base::FilePath lists_dir_;
  base::FilePath cache_dir_;
  scoped_refptr<base::SequencedTaskRunner> io_task_runner_;

  std::unique_ptr<open_engine::OpenAdBlockService> service_;
  bool enabled_ = true;
  bool config_mutated_ = false;
  bool exclusions_mutated_ = false;
  bool bound_to_parent_ = false;
  bool is_updating_ = false;
  uint64_t compile_seq_ = 0;
  uint64_t active_batch_id_ = 0;
  std::string last_error_;
  std::string custom_rules_;

  raw_ptr<OpenAdBlockProfileService> parent_service_ = nullptr;
  std::vector<raw_ptr<OpenAdBlockProfileService>> otr_children_;
  std::set<std::string> enabled_list_ids_;
  std::set<std::string> excluded_domains_;
  std::map<std::string, AdBlockListReceipt> list_receipts_;
  std::unique_ptr<ListDownloadBatch> active_batch_;

  StatusObserver status_observer_;
  base::ObserverList<Observer> observers_;
  base::WeakPtrFactory<OpenAdBlockProfileService> weak_factory_{this};
};

// BrowserContextKeyedServiceFactory for OpenAdBlockProfileService.
// Gives OTR contexts their own instance (for ephemeral per-session exclusions)
// sharing the parent profile's immutable engine via OpenAdBlockEngineRegistry.
class OpenAdBlockProfileServiceFactory
    : public BrowserContextKeyedServiceFactory {
 public:
  using OriginalContextResolver =
      base::RepeatingCallback<content::BrowserContext*(
          content::BrowserContext*)>;

  static OpenAdBlockProfileService* GetForBrowserContext(
      content::BrowserContext* context);
  static OpenAdBlockProfileServiceFactory* GetInstance();

  // Optional hook allowing the browser/Profile layer to resolve an OTR
  // BrowserContext to its original regular BrowserContext directly.
  static void SetOriginalContextResolver(OriginalContextResolver resolver);

  void UnregisterService(OpenAdBlockProfileService* service);

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

  OriginalContextResolver original_context_resolver_;
  mutable std::map<base::FilePath, raw_ptr<OpenAdBlockProfileService>>
      regular_services_by_path_;
  mutable std::map<base::FilePath,
                   std::vector<raw_ptr<OpenAdBlockProfileService>>>
      unbound_otr_by_path_;
};

}  // namespace open_unified

#endif  // OPEN_UNIFIED_CORE_ADBLOCK_OPEN_ADBLOCK_PROFILE_SERVICE_H_
