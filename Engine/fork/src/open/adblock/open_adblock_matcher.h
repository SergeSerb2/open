// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef OPEN_ADBLOCK_OPEN_ADBLOCK_MATCHER_H_
#define OPEN_ADBLOCK_OPEN_ADBLOCK_MATCHER_H_

#include <atomic>
#include <cstdint>
#include <memory>
#include <string>
#include <string_view>
#include <vector>

#include "base/containers/flat_set.h"
#include "base/memory/ref_counted.h"
#include "base/memory/scoped_refptr.h"
#include "base/sequence_checker.h"
#include "base/task/sequenced_task_runner.h"
#include "open/adblock/rust/src/lib.rs.h"

class GURL;

namespace open_engine {

// adblock-fork §7.7: a check matches at most this much of a URL (16 KiB).
// Step 4 measures its gates at 8 and 16 KiB; the cap becomes 8 KiB only if a
// gate fails at 16 KiB.
inline constexpr uint32_t kOpenAdBlockMatchCapBytes = 16 * 1024;

// Process-wide sequences (adblock-fork §7.6, D-12). Each is created on first
// use; creating one starts no thread.
//
// The matcher sequence (USER_BLOCKING, SKIP_ON_SHUTDOWN) runs every engine
// call: proxies, loaders, checks, cosmetic queries and matcher state updates.
// The two accessors return that one runner until the priority lane exists
// (§7.6 lane rule 2): the cosmetics host and the service's state updates use
// AdBlockCosmeticsTaskRunner(); proxies, sockets and benches use
// AdBlockMatcherTaskRunner().
scoped_refptr<base::SequencedTaskRunner> AdBlockMatcherTaskRunner();
scoped_refptr<base::SequencedTaskRunner> AdBlockCosmeticsTaskRunner();
// The build runner (MayBlock, USER_VISIBLE, CONTINUE_ON_SHUTDOWN): input
// verification, builds, DAT reads and writes, and engine destruction (§6.6).
// One for all Profiles, so at most one build runs at a time.
scoped_refptr<base::SequencedTaskRunner> AdBlockBuildTaskRunner();

// The engine of one load; immutable once published. Made only through
// MakeEngineHolder(), whose deleter frees it on the build runner wherever
// the last reference drops (§6.6: a free takes 15 to 18 ms).
struct EngineHolder {
  explicit EngineHolder(rust::Box<open_adblock::OpenAdblockEngine> engine);
  ~EngineHolder();
  EngineHolder(const EngineHolder&) = delete;
  EngineHolder& operator=(const EngineHolder&) = delete;
  rust::Box<open_adblock::OpenAdblockEngine> engine;
};
std::shared_ptr<const EngineHolder> MakeEngineHolder(
    rust::Box<open_adblock::OpenAdblockEngine> engine);

// The exclusion rule of adblock-fork §6.7 (review 100-4, Swift's
// SiteRules): an entry covers its domain and every subdomain at a label
// boundary. |host| is lowercase without a trailing dot; IPv6 hosts are
// bracketed. Shared by the UI mirror and the matcher.
bool HostIsExcluded(const base::flat_set<std::string>& exclusions,
                    std::string_view host);

// Counters any thread may read (relaxed). Written on the matcher sequence.
struct AdBlockMatcherCounters {
  std::atomic<uint64_t> checks{0};
  std::atomic<uint64_t> checks_truncated{0};
  // G-6 (§7.8): checks over 1 ms, and the slowest check.
  std::atomic<uint64_t> checks_over_1ms{0};
  std::atomic<uint64_t> max_check_us{0};
  std::atomic<uint64_t> cosmetic_dropped_procedural{0};
  std::atomic<uint64_t> cosmetic_dropped_unsafe{0};
  std::atomic<uint64_t> cosmetic_dropped_style{0};
  std::atomic<uint64_t> cosmetic_dropped_remove{0};
  std::atomic<uint64_t> cosmetic_dropped_scriptlet{0};
  std::atomic<uint64_t> cosmetic_dropped_over_cap{0};
};

// One Profile's matching state (adblock-fork §6.3, §6.7). Construction and
// the reference count are thread-safe; everything else runs on the matcher
// sequence. Proxies, loaders and the cosmetics host keep a reference, so
// nothing off the UI thread holds a UI-bound pointer (review 100-8).
class OpenAdBlockMatcher
    : public base::RefCountedThreadSafe<OpenAdBlockMatcher> {
 public:
  OpenAdBlockMatcher();
  OpenAdBlockMatcher(const OpenAdBlockMatcher&) = delete;
  OpenAdBlockMatcher& operator=(const OpenAdBlockMatcher&) = delete;

  // State updates, posted by the UI-thread service. The old engine
  // reference drops here; its deleter frees it on the build runner.
  void SetEngine(std::shared_ptr<const EngineHolder> engine);
  void SetEnabled(bool enabled);
  void SetExclusions(base::flat_set<std::string> normalized_domains);

  // enabled, an engine loaded, and |top_host| not excluded.
  bool IsActiveFor(std::string_view top_host) const;
  bool IsEnabled() const;
  bool HasEngine() const;

  // One network check (G-1: never on the UI or IO thread). A null engine
  // or an invalid URL allows.
  open_adblock::OpenBlockerResult Check(const GURL& url,
                                        const GURL& source_url,
                                        open_adblock::OpenRequestType type,
                                        uint32_t max_input_bytes) const;
  open_adblock::OpenCosmeticResources Cosmetic(const GURL& document_url) const;
  std::vector<std::string> HiddenSelectors(
      const std::vector<std::string>& classes,
      const std::vector<std::string>& ids,
      const std::vector<std::string>& exceptions) const;

  // Any thread.
  const AdBlockMatcherCounters& counters() const { return counters_; }

 private:
  friend class base::RefCountedThreadSafe<OpenAdBlockMatcher>;
  ~OpenAdBlockMatcher();

  SEQUENCE_CHECKER(sequence_checker_);
  std::shared_ptr<const EngineHolder> engine_;
  bool enabled_ = false;
  base::flat_set<std::string> exclusions_;
  mutable AdBlockMatcherCounters counters_;
};

}  // namespace open_engine

#endif  // OPEN_ADBLOCK_OPEN_ADBLOCK_MATCHER_H_
