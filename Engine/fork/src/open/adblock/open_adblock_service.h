// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef OPEN_ADBLOCK_OPEN_ADBLOCK_SERVICE_H_
#define OPEN_ADBLOCK_OPEN_ADBLOCK_SERVICE_H_

#include <atomic>
#include <memory>
#include <string>
#include <string_view>
#include <vector>

#include "base/containers/flat_set.h"
#include "base/files/file_path.h"
#include "base/functional/callback.h"
#include "base/memory/scoped_refptr.h"
#include "base/memory/weak_ptr.h"
#include "open/adblock/open_adblock_matcher.h"
#include "open/adblock/open_adblock_types.h"

namespace open_engine {

// One per CefBrowserContext (one Open Profile): the master switch, the
// excluded sites, the list loads, and the Profile's matcher
// (docs/plans/adblock-fork.md §6.3, §6.7).
//
// Threading: UI thread only. Every engine call runs on the matcher sequence
// through matcher(); this class only posts state to it (SetEngine,
// SetEnabled, SetExclusions on AdBlockCosmeticsTaskRunner(), lead decision
// 2026-10-26) and keeps UI mirrors of the switch and the exclusions for the
// hooks' factory-time decisions (§7.2).
class OpenAdBlockService {
 public:
  // |profile_dir| is the context's cache path. Makes the matcher at once
  // (disabled, no engine), so the hooks always have one.
  explicit OpenAdBlockService(base::FilePath profile_dir);
  ~OpenAdBlockService();

  OpenAdBlockService(const OpenAdBlockService&) = delete;
  OpenAdBlockService& operator=(const OpenAdBlockService&) = delete;

  // Drops the engine reference and stops loads. Afterwards the matcher
  // answers "off" and the context returns no service (§6.7). The first
  // Shutdown() in the process prints the G-4 latency histogram at --v=1
  // (§7.8).
  void Shutdown();

  void SetEnabled(bool enabled);
  // UI mirror of the switch (and not shut down).
  bool IsEnabled() const;

  // Normalized and checked here; the callers' input is not trusted.
  void SetExcludedDomains(std::vector<std::string> registrable_domains);
  // UI mirror: is |host| (lowercase, no trailing dot) or a parent domain of
  // it down to its registrable domain excluded (§6.7)?
  bool IsExcludedOnUi(std::string_view host) const;

  // Loads the adblock root (adblock-fork §9.2): current.json selects a
  // generation, whose manifest lists the inputs. Every input is verified
  // before use, also before a DAT load. Asynchronous: the new engine
  // replaces the old one when it is ready; on failure the old one stays.
  // |done| (optional) runs on the UI thread after that, once, with the
  // result: also for a load that a newer one replaced (kStale), and after
  // Shutdown() or the service's destruction (kCancelled; at once when the
  // load is asked for after Shutdown()).
  void LoadFromDirectory(
      base::FilePath adblock_root,
      bool prefer_dat,
      base::OnceCallback<void(AdBlockLoadResult)> done = {});
  // Production control path: same directory is a no-op; empty unloads and
  // invalidates pending loads without changing enabled/exclusions.
  void SetListDirectory(base::FilePath adblock_root);
  // Loads the root of the last LoadFromDirectory() again, with no |done|.
  void ReloadLists();

  // The Profile's matcher; any thread may hold it, only the matcher
  // sequence may call it.
  scoped_refptr<OpenAdBlockMatcher> matcher() const { return matcher_; }

  AdBlockStatus GetStatus() const;
  // Runs on the UI thread after every load and setting change.
  void SetStatusCallback(
      base::RepeatingCallback<void(const AdBlockStatus&)> callback);

  // The CEF owner installs a weak context-scoped callback at creation,
  // before configuring this service. It arms renderer MemoryCache clearing at next navigation;
  // the renderer coalesces repeated requests until that navigation.
  void SetRendererCacheInvalidator(base::RepeatingCallback<int()> callback);

  base::WeakPtr<OpenAdBlockService> GetWeakPtr();

  // The result of one background load.
  struct BuildResult {
    BuildResult();
    BuildResult(BuildResult&&);
    BuildResult& operator=(BuildResult&&);
    ~BuildResult();

    std::shared_ptr<const EngineHolder> engine;
    // current.json has not been published yet (not a corrupt generation).
    bool awaiting_generation = false;
    // Verified generation with no enabled lists. Success without creating an
    // engine, loading resources, or entering the engine registry.
    bool empty_generation = false;
    bool from_dat = false;
    // Found in the process-wide registry (another Profile's engine).
    bool shared = false;
    // A newer load started before this one finished; nothing was published.
    bool stale = false;
    // The build could be cached: a DAT restores the same engine (no
    // $removeparam or :remove*() rules, which a v0 DAT drops).
    bool lossless = true;
    std::vector<std::string> lossy_kinds;
    uint32_t resources_loaded = 0;
    std::string resources_version;
    int64_t generation = 0;
    uint32_t list_count = 0;
    uint64_t dat_size_bytes = 0;
    int64_t build_ms = -1;
    // A failure, or a cache problem next to a good engine.
    std::string error;
  };

 private:
  // The reply of a load: runs |done| even when |service| is gone.
  static void OnBuiltReply(base::WeakPtr<OpenAdBlockService> service,
                           uint64_t load_id,
                           base::OnceCallback<void(AdBlockLoadResult)> done,
                           BuildResult result);
  void OnBuilt(uint64_t load_id,
               base::OnceCallback<void(AdBlockLoadResult)> done,
               BuildResult result);
  void PostToMatcher(base::OnceCallback<void(OpenAdBlockMatcher*)> update);
  void NotifyStatus();
  void InvalidateRendererCaches(const char* reason);

  const base::FilePath profile_dir_;
  const scoped_refptr<OpenAdBlockMatcher> matcher_;
  base::FilePath adblock_root_;
  bool enabled_ = false;
  bool initial_load_pending_ = false;
  bool shut_down_ = false;
  base::flat_set<std::string> excluded_domains_;

  // The latest load id, shared with the build tasks so a stale build stops
  // before it parses and before it writes the cache (§6.6, review 100-7).
  const std::shared_ptr<std::atomic<uint64_t>> latest_load_id_;

  AdBlockStatus status_;
  base::RepeatingCallback<void(const AdBlockStatus&)> status_callback_;
  base::RepeatingCallback<int()> renderer_cache_invalidator_;

  base::WeakPtrFactory<OpenAdBlockService> weak_ptr_factory_{this};
};

}  // namespace open_engine

#endif  // OPEN_ADBLOCK_OPEN_ADBLOCK_SERVICE_H_
