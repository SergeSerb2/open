// Copyright 2026 The Open Authors. All rights reserved.
// Tab Sleep policy engine & scheduler matching Packages/OpenKit/Sources/OpenSleep.

#ifndef OPEN_UNIFIED_CORE_SLEEP_SLEEP_SCHEDULER_H_
#define OPEN_UNIFIED_CORE_SLEEP_SLEEP_SCHEDULER_H_

#include <optional>
#include <set>
#include <string>
#include <string_view>
#include <unordered_map>
#include <vector>

#include "base/functional/callback.h"
#include "open_unified/core/model/browser_model.h"
#include "open_unified/core/model/open_types.h"

namespace open_unified {

// Compiled host-suffix / wildcard-TLD + optional path-prefix matcher.
// Includes Open's 22 built-in keep-alive rules plus per-Profile user sites.
class KeepAliveMatcher {
 public:
  struct Rule {
    std::vector<std::string> labels;
    std::optional<std::string> path_prefix;
    bool any_tld = false;
  };

  KeepAliveMatcher();
  explicit KeepAliveMatcher(const std::vector<std::string>& user_sites);
  ~KeepAliveMatcher();

  static const std::vector<Rule>& BuiltInRules();
  static std::optional<Rule> ParseRule(std::string_view host,
                                       std::optional<std::string_view> path);

  bool MatchesUrl(std::string_view url) const;

 private:
  std::vector<Rule> rules_;
};

enum class SleepPolicyGate {
  kNone,
  kOff,
  kVisible,
  kKeepAlive,
  kNotifications,
  kAudible,
  kLoading,
  kCapturing,
  kDevTools,
  kDownloading,
  kUnloadHandlers,
  kFormInteraction,
};

enum class SleepAction {
  kNone,
  kFreeze,
  kDiscard,
  kDestroy,
};

struct SleepTabTracking {
  std::optional<TimestampSec> hidden_at;
  std::optional<TimestampSec> slept_at;
  std::optional<TimestampSec> last_audible_at;
  std::optional<TimestampSec> last_commit_at;
  bool is_downloading = false;
  bool has_unload_handlers = false;
};

struct SleepCallbacks {
  // Returns true if the renderer was frozen.
  base::RepeatingCallback<bool(const ItemID& tab_id)> on_freeze;
  // Captures OPNH history and discards the renderer; returns true on success.
  base::RepeatingCallback<bool(const ItemID& tab_id)> on_discard;
  // Destroys a long-sleeping WebContents (>24h).
  base::RepeatingCallback<void(const ItemID& tab_id)> on_destroy;
  // Restores a placeholder/sleeping tab from OPNH history or URL.
  base::RepeatingCallback<bool(const ItemID& tab_id)> on_restore;
};

class SleepScheduler {
 public:
  static constexpr double kFreezeDelaySec = 30.0;
  static constexpr double kDestroyDelaySec = 24.0 * 3600.0;
  static constexpr double kAudioProtectionSec = 60.0;
  static constexpr double kLoadProtectionSec = 10.0;
  static constexpr double kFormProtectionSec = 300.0;

  static std::optional<double> DiscardDelaySeconds(SleepMode mode);

  explicit SleepScheduler(SleepCallbacks callbacks = {});
  ~SleepScheduler();

  SleepScheduler(const SleepScheduler&) = delete;
  SleepScheduler& operator=(const SleepScheduler&) = delete;

  void SetCallbacks(SleepCallbacks callbacks);

  // Event notifications from the browser/engine bridge.
  void OnTabShown(const ItemID& tab_id, TimestampSec now);
  void OnTabHidden(const ItemID& tab_id, TimestampSec now);
  void OnTabCommitted(const ItemID& tab_id, TimestampSec now);
  void OnTabAudioChanged(const ItemID& tab_id, bool is_audible, TimestampSec now);
  void OnTabDownloadStateChanged(const ItemID& tab_id, bool is_downloading);
  void OnTabUnloadHandlersChanged(const ItemID& tab_id, bool has_handlers);
  void OnTabClosed(const ItemID& tab_id);

  const SleepTabTracking* GetTracking(const ItemID& tab_id) const;

  // Pure policy decisions.
  static SleepPolicyGate EvaluateBlockingGate(
      const Tab& tab,
      SleepMode mode,
      const KeepAliveMatcher& matcher,
      const std::set<ItemID>& visible_tab_ids,
      const SleepTabTracking& tracking,
      TimestampSec now,
      bool for_discard,
      bool critical_pressure = false);

  static SleepAction EvaluateTimedAction(SleepPhase phase,
                                         SleepMode mode,
                                         TimestampSec hidden_at,
                                         std::optional<TimestampSec> slept_at,
                                         TimestampSec now);

  static SleepAction EvaluateAction(const Tab& tab,
                                    SleepMode mode,
                                    const KeepAliveMatcher& matcher,
                                    const std::set<ItemID>& visible_tab_ids,
                                    const SleepTabTracking& tracking,
                                    TimestampSec now);

  // Runs one periodic sweep across all tabs in |model|, invoking freeze,
  // discard, and destroy callbacks and updating TabLiveState::sleep_phase.
  // Returns the number of tabs transitioned.
  size_t Tick(BrowserModel& model,
              const std::set<ItemID>& visible_tab_ids,
              TimestampSec now);

  // Immediately restores a sleeping/placeholder tab via on_restore callback.
  bool RequestRestore(BrowserModel& model,
                      const ItemID& tab_id,
                      TimestampSec now);

  // Under critical memory pressure, discards eligible background tabs
  // immediately (including notification-permitted tabs, still respecting
  // active, keep-alive, audible, capturing, devtools, download, unload, form).
  size_t HandleCriticalMemoryPressure(BrowserModel& model,
                                      const std::set<ItemID>& visible_tab_ids,
                                      TimestampSec now);

 private:
  SleepCallbacks callbacks_;
  std::unordered_map<ItemID, SleepTabTracking> tracking_;
};

}  // namespace open_unified

#endif  // OPEN_UNIFIED_CORE_SLEEP_SLEEP_SCHEDULER_H_
