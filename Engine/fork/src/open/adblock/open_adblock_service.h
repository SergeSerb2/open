// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef OPEN_ADBLOCK_OPEN_ADBLOCK_SERVICE_H_
#define OPEN_ADBLOCK_OPEN_ADBLOCK_SERVICE_H_

#include <atomic>
#include <memory>
#include <mutex>
#include <set>
#include <shared_mutex>
#include <string>
#include <vector>

#include "base/files/file_path.h"
#include "base/functional/callback.h"
#include "base/memory/scoped_refptr.h"
#include "base/memory/weak_ptr.h"
#include "base/task/sequenced_task_runner.h"
#include "open/adblock/open_adblock_types.h"
#include "open/adblock/rust/src/lib.rs.h"

class GURL;

namespace open_engine {

// One per CefBrowserContext (one Open Profile): the current adblock engine,
// the master switch, and the excluded sites (docs/plans/adblock-fork.md §6).
//
// Threading: public methods run on the UI thread, except Check(),
// CosmeticResources(), HiddenSelectors(), IsEnabled() and IsExcluded(),
// which network throttles may call from any thread.
class OpenAdBlockService {
 public:
  // |profile_dir| is the context's cache path.
  explicit OpenAdBlockService(base::FilePath profile_dir);
  ~OpenAdBlockService();

  OpenAdBlockService(const OpenAdBlockService&) = delete;
  OpenAdBlockService& operator=(const OpenAdBlockService&) = delete;

  // Drops pending builds and the engine. From then on every check allows.
  void Shutdown();

  void SetEnabled(bool enabled);
  bool IsEnabled() const;

  // Normalized and checked here; the callers' input is not trusted.
  void SetExcludedDomains(std::vector<std::string> registrable_domains);
  // Is the page's host, or a parent domain of it down to its registrable
  // domain, excluded? The Swift rule (OpenAdBlock SiteRules): an entry
  // covers that domain and its subdomains, at a label boundary. Any thread.
  bool IsExcluded(const GURL& top_level_url) const;

  // Loads the adblock root (adblock-fork §9.2): current.json selects a
  // generation, whose manifest lists the inputs. Every input is verified
  // before use, also before a DAT load. Asynchronous: the new engine
  // replaces the old one when it is ready; on failure the old one stays.
  // |done| (optional) runs on the UI thread after that.
  void LoadFromDirectory(base::FilePath adblock_root,
                         bool prefer_dat,
                         base::OnceClosure done = {});
  // Loads the root of the last LoadFromDirectory() again.
  void ReloadLists();

  // One network check. Any thread. A null engine, or an invalid URL, allows.
  open_adblock::OpenBlockerResult Check(
      const GURL& url,
      const GURL& source_url,
      open_adblock::OpenRequestType request_type) const;
  // The cosmetic filters for one frame URL. Any thread.
  open_adblock::OpenCosmeticResources CosmeticResources(const GURL& url) const;
  std::vector<std::string> HiddenSelectors(
      const std::vector<std::string>& classes,
      const std::vector<std::string>& ids,
      const std::vector<std::string>& exceptions) const;

  AdBlockStatus GetStatus() const;
  // Runs on the UI thread after every load and setting change.
  void SetStatusCallback(
      base::RepeatingCallback<void(const AdBlockStatus&)> callback);

  base::WeakPtr<OpenAdBlockService> GetWeakPtr();

  // The engine of one load; immutable once published.
  struct EngineHolder {
    explicit EngineHolder(rust::Box<open_adblock::OpenAdblockEngine> engine);
    ~EngineHolder();
    rust::Box<open_adblock::OpenAdblockEngine> engine;
  };

  // The result of one background load.
  struct BuildResult {
    BuildResult();
    BuildResult(BuildResult&&);
    BuildResult& operator=(BuildResult&&);
    ~BuildResult();

    std::unique_ptr<EngineHolder> engine;
    bool from_dat = false;
    // The build could be cached: a DAT restores the same engine (no
    // $removeparam or :remove*() rules, which a v0 DAT drops).
    bool lossless = true;
    int64_t generation = 0;
    uint32_t list_count = 0;
    uint64_t dat_size_bytes = 0;
    int64_t build_ms = -1;
    // A failure, or a cache problem next to a good engine.
    std::string error;
  };

 private:
  std::shared_ptr<const EngineHolder> CurrentEngine() const;
  void OnBuilt(uint64_t load_id, base::OnceClosure done, BuildResult result);
  // Destroys |engine| on the build runner: freeing an engine takes 15 to
  // 18 ms, too long for the UI thread (review 100-2).
  void ReleaseOnBuildRunner(std::shared_ptr<const EngineHolder> engine);
  void NotifyStatus();

  const base::FilePath profile_dir_;
  base::FilePath adblock_root_;
  std::atomic<bool> enabled_{false};
  std::atomic<bool> shut_down_{false};

  mutable std::shared_mutex engine_mutex_;
  std::shared_ptr<const EngineHolder> engine_;  // Guarded by engine_mutex_.

  mutable std::mutex exclusions_mutex_;
  std::set<std::string> excluded_domains_;  // Guarded by exclusions_mutex_.

  scoped_refptr<base::SequencedTaskRunner> build_runner_;
  // UI thread: a result from an older load is dropped.
  uint64_t load_id_ = 0;

  mutable std::mutex status_mutex_;
  AdBlockStatus status_;  // Guarded by status_mutex_.
  base::RepeatingCallback<void(const AdBlockStatus&)> status_callback_;

  base::WeakPtrFactory<OpenAdBlockService> weak_ptr_factory_{this};
};

}  // namespace open_engine

#endif  // OPEN_ADBLOCK_OPEN_ADBLOCK_SERVICE_H_
