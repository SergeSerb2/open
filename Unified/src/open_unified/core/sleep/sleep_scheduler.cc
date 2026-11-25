// Copyright 2026 The Open Authors. All rights reserved.

#include "open_unified/core/sleep/sleep_scheduler.h"

#include <algorithm>
#include <cctype>
#include <functional>
#include <iterator>
#include <utility>

#include "base/strings/string_util.h"

namespace open_unified {

namespace {

bool SplitHttpHostAndPath(std::string_view url,
                          std::vector<std::string>* host_labels,
                          std::string* path_out) {
  size_t sep = url.find("://");
  if (sep == std::string_view::npos) {
    return false;
  }
  std::string scheme = base::ToLowerASCII(url.substr(0, sep));
  if (scheme != "http" && scheme != "https") {
    return false;
  }
  std::string_view rest = url.substr(sep + 3);
  size_t path_pos = rest.find_first_of("/?#");
  std::string_view authority =
      path_pos == std::string_view::npos ? rest : rest.substr(0, path_pos);
  size_t at = authority.rfind('@');
  if (at != std::string_view::npos) {
    authority = authority.substr(at + 1);
  }
  if (authority.empty()) {
    return false;
  }
  std::string_view host = authority;
  if (host.front() != '[') {
    size_t colon = host.rfind(':');
    if (colon != std::string_view::npos) {
      host = host.substr(0, colon);
    }
  }
  std::string lower_host = base::ToLowerASCII(host);
  while (!lower_host.empty() && lower_host.back() == '.') {
    lower_host.pop_back();
  }
  if (lower_host.empty()) {
    return false;
  }

  host_labels->clear();
  size_t start = 0;
  while (start <= lower_host.size()) {
    size_t dot = lower_host.find('.', start);
    if (dot == std::string::npos) {
      host_labels->push_back(lower_host.substr(start));
      break;
    }
    host_labels->push_back(lower_host.substr(start, dot - start));
    start = dot + 1;
  }

  if (path_pos != std::string_view::npos && rest[path_pos] == '/') {
    std::string_view p = rest.substr(path_pos);
    size_t q = p.find_first_of("?#");
    if (q != std::string_view::npos) {
      p = p.substr(0, q);
    }
    *path_out = std::string(p);
  } else {
    *path_out = "/";
  }
  return true;
}

bool MatchesRule(const KeepAliveMatcher::Rule& rule,
                 const std::vector<std::string>& host_labels,
                 std::string_view path) {
  if (rule.path_prefix.has_value()) {
    if (!base::StartsWith(path, *rule.path_prefix,
                          base::CompareCase::SENSITIVE)) {
      return false;
    }
  }
  const size_t n = rule.labels.size();
  const size_t m = host_labels.size();
  if (!rule.any_tld) {
    if (m < n) return false;
    for (size_t i = 0; i < n; ++i) {
      if (host_labels[m - n + i] != rule.labels[i]) {
        return false;
      }
    }
    return true;
  }
  // Trailing '*' consumes one or more TLD labels (e.g., .com or .co.uk).
  if (m <= n) return false;
  for (size_t start = 0; start < m - n; ++start) {
    bool match = true;
    for (size_t i = 0; i < n; ++i) {
      if (host_labels[start + i] != rule.labels[i]) {
        match = false;
        break;
      }
    }
    if (match) return true;
  }
  return false;
}

bool IsRecent(std::optional<TimestampSec> event_time,
              TimestampSec now,
              double window_sec) {
  return event_time.has_value() && (now - *event_time) < window_sec;
}

void CollectAllTabIds(const BrowserModel& model,
                      std::vector<std::pair<ItemID, ProfileID>>* out) {
  for (const Profile& profile : model.profiles()) {
    for (const Tab& fav : profile.favorites) {
      out->emplace_back(fav.id, profile.id);
    }
  }
  std::function<void(const SidebarNode&, const ProfileID&)> walk =
      [&](const SidebarNode& node, const ProfileID& profile_id) {
        if (const Tab* tab = node.as_tab()) {
          out->emplace_back(tab->id, profile_id);
        } else if (const Folder* folder = node.as_folder()) {
          for (const SidebarNode& child : folder->children) {
            walk(child, profile_id);
          }
        } else if (const Split* split = node.as_split()) {
          for (const Tab& pane : split->panes) {
            out->emplace_back(pane.id, profile_id);
          }
        }
      };
  for (const Space& space : model.spaces()) {
    for (const SidebarNode& n : space.pinned) {
      walk(n, space.profile_id);
    }
    for (const SidebarNode& n : space.today) {
      walk(n, space.profile_id);
    }
  }
}

}  // namespace

// ============================================================================
// KeepAliveMatcher
// ============================================================================

std::optional<KeepAliveMatcher::Rule> KeepAliveMatcher::ParseRule(
    std::string_view host,
    std::optional<std::string_view> path) {
  std::string lower = base::ToLowerASCII(host);
  if (lower.empty()) {
    return std::nullopt;
  }
  std::vector<std::string> labels;
  size_t start = 0;
  while (start <= lower.size()) {
    size_t dot = lower.find('.', start);
    if (dot == std::string::npos) {
      labels.push_back(lower.substr(start));
      break;
    }
    labels.push_back(lower.substr(start, dot - start));
    start = dot + 1;
  }
  bool any_tld = (!labels.empty() && labels.back() == "*");
  if (any_tld) {
    labels.pop_back();
  }
  if (labels.size() < (any_tld ? 1u : 2u)) {
    return std::nullopt;
  }
  for (const std::string& label : labels) {
    if (label.empty() || label.front() == '-' || label.back() == '-') {
      return std::nullopt;
    }
    for (unsigned char c : label) {
      if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-')) {
        return std::nullopt;
      }
    }
  }
  Rule rule;
  rule.labels = std::move(labels);
  rule.any_tld = any_tld;
  if (path.has_value()) {
    if (path->empty() || path->front() != '/' ||
        path->find('?') != std::string_view::npos ||
        path->find('#') != std::string_view::npos) {
      return std::nullopt;
    }
    rule.path_prefix = std::string(*path);
  }
  return rule;
}

const std::vector<KeepAliveMatcher::Rule>& KeepAliveMatcher::BuiltInRules() {
  static const std::vector<Rule> kBuiltIn = []() {
    struct RawRule {
      const char* host;
      const char* path;
    };
    // Exact 22 built-in rules from OpenSleep/Resources/keep-alive-sites.json.
    static constexpr RawRule kRaw[] = {
        {"twitter.*", nullptr},
        {"x.com", nullptr},
        {"app.slack.*", "/client"},
        {"mail.google.*", "/mail"},
        {"calendar.google.*", "/calendar"},
        {"notion.so", nullptr},
        {"app.notion.com", nullptr},
        {"dropbox.*", nullptr},
        {"aws.amazon.*", nullptr},
        {"open.spotify.*", nullptr},
        {"linear.app", nullptr},
        {"instagram.*", nullptr},
        {"messenger.*", nullptr},
        {"facebook.*", nullptr},
        {"web.whatsapp.*", nullptr},
        {"sentry.io", nullptr},
        {"figma.*", "/file/"},
        {"docs.google.*", "/document"},
        {"docs.google.*", "/presentation"},
        {"docs.google.*", "/spreadsheets"},
        {"outlook.live.*", "/mail"},
        {"outlook.live.*", "/calendar"},
    };
    std::vector<Rule> out;
    out.reserve(std::size(kRaw));
    for (const auto& r : kRaw) {
      std::optional<std::string_view> p =
          r.path ? std::optional<std::string_view>(r.path) : std::nullopt;
      if (auto parsed = ParseRule(r.host, p)) {
        out.push_back(std::move(*parsed));
      }
    }
    return out;
  }();
  return kBuiltIn;
}

KeepAliveMatcher::KeepAliveMatcher() : rules_(BuiltInRules()) {}

KeepAliveMatcher::KeepAliveMatcher(const std::vector<std::string>& user_sites)
    : rules_(BuiltInRules()) {
  for (const std::string& site : user_sites) {
    std::string trimmed;
    base::TrimWhitespaceASCII(site, base::TRIM_ALL, &trimmed);
    if (trimmed.empty()) continue;
    size_t slash = trimmed.find('/');
    std::string_view host_part =
        slash == std::string::npos ? std::string_view(trimmed)
                                   : std::string_view(trimmed).substr(0, slash);
    std::optional<std::string_view> path_part =
        slash == std::string::npos
            ? std::nullopt
            : std::optional<std::string_view>(
                  std::string_view(trimmed).substr(slash));
    if (auto rule = ParseRule(host_part, path_part)) {
      rules_.push_back(std::move(*rule));
    }
  }
}

KeepAliveMatcher::~KeepAliveMatcher() = default;

bool KeepAliveMatcher::MatchesUrl(std::string_view url) const {
  std::vector<std::string> labels;
  std::string path;
  if (!SplitHttpHostAndPath(url, &labels, &path)) {
    return false;
  }
  for (const Rule& rule : rules_) {
    if (MatchesRule(rule, labels, path)) {
      return true;
    }
  }
  return false;
}

// ============================================================================
// SleepScheduler
// ============================================================================

std::optional<double> SleepScheduler::DiscardDelaySeconds(SleepMode mode) {
  switch (mode) {
    case SleepMode::kOff:
      return std::nullopt;
    case SleepMode::kConservative:
      return 900.0;
    case SleepMode::kBalanced:
      return 300.0;
    case SleepMode::kAggressive:
      return 120.0;
  }
  return 300.0;
}

SleepScheduler::SleepScheduler(SleepCallbacks callbacks)
    : callbacks_(std::move(callbacks)) {}

SleepScheduler::~SleepScheduler() = default;

void SleepScheduler::SetCallbacks(SleepCallbacks callbacks) {
  callbacks_ = std::move(callbacks);
}

void SleepScheduler::OnTabShown(const ItemID& tab_id, TimestampSec /*now*/) {
  auto& info = tracking_[tab_id];
  info.hidden_at.reset();
  info.slept_at.reset();
}

void SleepScheduler::OnTabHidden(const ItemID& tab_id, TimestampSec now) {
  auto& info = tracking_[tab_id];
  if (!info.hidden_at.has_value()) {
    info.hidden_at = now;
  }
}

void SleepScheduler::OnTabCommitted(const ItemID& tab_id, TimestampSec now) {
  tracking_[tab_id].last_commit_at = now;
}

void SleepScheduler::OnTabAudioChanged(const ItemID& tab_id,
                                       bool is_audible,
                                       TimestampSec now) {
  if (!is_audible) {
    tracking_[tab_id].last_audible_at = now;
  } else {
    tracking_[tab_id].last_audible_at = now;
  }
}

void SleepScheduler::OnTabDownloadStateChanged(const ItemID& tab_id,
                                               bool is_downloading) {
  tracking_[tab_id].is_downloading = is_downloading;
}

void SleepScheduler::OnTabUnloadHandlersChanged(const ItemID& tab_id,
                                                bool has_handlers) {
  tracking_[tab_id].has_unload_handlers = has_handlers;
}

void SleepScheduler::OnTabClosed(const ItemID& tab_id) {
  tracking_.erase(tab_id);
}

const SleepTabTracking* SleepScheduler::GetTracking(
    const ItemID& tab_id) const {
  auto it = tracking_.find(tab_id);
  return it == tracking_.end() ? nullptr : &it->second;
}

SleepPolicyGate SleepScheduler::EvaluateBlockingGate(
    const Tab& tab,
    SleepMode mode,
    const KeepAliveMatcher& matcher,
    const std::set<ItemID>& visible_tab_ids,
    const SleepTabTracking& tracking,
    TimestampSec now,
    bool for_discard,
    bool critical_pressure) {
  if (mode == SleepMode::kOff) {
    return SleepPolicyGate::kOff;
  }
  if (visible_tab_ids.count(tab.id) > 0) {
    return SleepPolicyGate::kVisible;
  }
  if (matcher.MatchesUrl(tab.url)) {
    return SleepPolicyGate::kKeepAlive;
  }
  if (tab.live_state.notifications_allowed && !critical_pressure) {
    return SleepPolicyGate::kNotifications;
  }
  if (tab.live_state.is_audible ||
      IsRecent(tracking.last_audible_at, now, kAudioProtectionSec)) {
    return SleepPolicyGate::kAudible;
  }
  if (tab.live_state.is_loading ||
      IsRecent(tracking.last_commit_at, now, kLoadProtectionSec)) {
    return SleepPolicyGate::kLoading;
  }
  if (tab.live_state.is_capturing_media) {
    return SleepPolicyGate::kCapturing;
  }
  if (tab.live_state.devtools_open) {
    return SleepPolicyGate::kDevTools;
  }
  if (tracking.is_downloading) {
    return SleepPolicyGate::kDownloading;
  }
  if (for_discard && tracking.has_unload_handlers) {
    return SleepPolicyGate::kUnloadHandlers;
  }
  if (for_discard &&
      IsRecent(tab.live_state.last_form_interaction_at, now,
               kFormProtectionSec)) {
    return SleepPolicyGate::kFormInteraction;
  }
  return SleepPolicyGate::kNone;
}

SleepAction SleepScheduler::EvaluateTimedAction(
    SleepPhase phase,
    SleepMode mode,
    TimestampSec hidden_at,
    std::optional<TimestampSec> slept_at,
    TimestampSec now) {
  if (mode == SleepMode::kOff) {
    return SleepAction::kNone;
  }
  switch (phase) {
    case SleepPhase::kPlaceholder:
      return SleepAction::kNone;
    case SleepPhase::kLive:
      return (now - hidden_at) >= kFreezeDelaySec ? SleepAction::kFreeze
                                                  : SleepAction::kNone;
    case SleepPhase::kFrozen: {
      auto delay = DiscardDelaySeconds(mode);
      if (!delay.has_value()) {
        return SleepAction::kNone;
      }
      double threshold = std::max(kFreezeDelaySec, *delay);
      return (now - hidden_at) >= threshold ? SleepAction::kDiscard
                                            : SleepAction::kNone;
    }
    case SleepPhase::kSleeping:
      return (slept_at.has_value() && (now - *slept_at) >= kDestroyDelaySec)
                 ? SleepAction::kDestroy
                 : SleepAction::kNone;
  }
  return SleepAction::kNone;
}

SleepAction SleepScheduler::EvaluateAction(
    const Tab& tab,
    SleepMode mode,
    const KeepAliveMatcher& matcher,
    const std::set<ItemID>& visible_tab_ids,
    const SleepTabTracking& tracking,
    TimestampSec now) {
  TimestampSec hidden_at = tracking.hidden_at.value_or(tab.last_active_at);
  SleepAction action = EvaluateTimedAction(tab.live_state.sleep_phase, mode,
                                           hidden_at, tracking.slept_at, now);
  if (action == SleepAction::kNone) {
    return SleepAction::kNone;
  }
  SleepPolicyGate gate = EvaluateBlockingGate(
      tab, mode, matcher, visible_tab_ids, tracking, now,
      /*for_discard=*/action == SleepAction::kDiscard,
      /*critical_pressure=*/false);
  return gate == SleepPolicyGate::kNone ? action : SleepAction::kNone;
}

size_t SleepScheduler::Tick(BrowserModel& model,
                            const std::set<ItemID>& visible_tab_ids,
                            TimestampSec now) {
  std::unordered_map<ProfileID, KeepAliveMatcher> matchers;
  std::unordered_map<ProfileID, SleepMode> modes;
  for (const Profile& profile : model.profiles()) {
    matchers.emplace(profile.id,
                     KeepAliveMatcher(profile.settings.keep_alive_sites));
    modes.emplace(profile.id, profile.settings.sleep_mode);
  }

  std::vector<std::pair<ItemID, ProfileID>> tabs;
  CollectAllTabIds(model, &tabs);

  size_t transitioned = 0;
  for (const auto& [tab_id, profile_id] : tabs) {
    const Tab* tab = model.FindTab(tab_id);
    if (!tab) continue;

    // Maintain hidden_at clocks automatically for non-visible live tabs.
    auto& track = tracking_[tab_id];
    if (visible_tab_ids.count(tab_id) > 0) {
      track.hidden_at.reset();
      continue;
    }
    if (!track.hidden_at.has_value() &&
        tab->live_state.sleep_phase != SleepPhase::kPlaceholder) {
      track.hidden_at = tab->last_active_at > 0.0 ? tab->last_active_at : now;
    }

    auto mode_it = modes.find(profile_id);
    auto matcher_it = matchers.find(profile_id);
    if (mode_it == modes.end() || matcher_it == matchers.end()) {
      continue;
    }
    SleepAction action = EvaluateAction(*tab, mode_it->second,
                                        matcher_it->second, visible_tab_ids,
                                        track, now);
    if (action == SleepAction::kNone) {
      continue;
    }

    TabLiveState next_state = tab->live_state;
    if (action == SleepAction::kFreeze) {
      if (callbacks_.on_freeze && callbacks_.on_freeze.Run(tab_id)) {
        next_state.sleep_phase = SleepPhase::kFrozen;
        model.UpdateTabLiveState(tab_id, next_state);
        ++transitioned;
      }
    } else if (action == SleepAction::kDiscard) {
      if (callbacks_.on_discard && callbacks_.on_discard.Run(tab_id)) {
        next_state.sleep_phase = SleepPhase::kSleeping;
        next_state.has_web_content = false;
        track.slept_at = now;
        model.UpdateTabLiveState(tab_id, next_state);
        ++transitioned;
      }
    } else if (action == SleepAction::kDestroy) {
      if (callbacks_.on_destroy) {
        callbacks_.on_destroy.Run(tab_id);
      }
      next_state.sleep_phase = SleepPhase::kPlaceholder;
      next_state.has_web_content = false;
      track.slept_at.reset();
      model.UpdateTabLiveState(tab_id, next_state);
      ++transitioned;
    }
  }
  return transitioned;
}

bool SleepScheduler::RequestRestore(BrowserModel& model,
                                    const ItemID& tab_id,
                                    TimestampSec now) {
  const Tab* tab = model.FindTab(tab_id);
  if (!tab) {
    return false;
  }
  if (tab->live_state.sleep_phase == SleepPhase::kLive &&
      tab->live_state.has_web_content) {
    OnTabShown(tab_id, now);
    return true;
  }
  if (callbacks_.on_restore && !callbacks_.on_restore.Run(tab_id)) {
    return false;
  }
  OnTabShown(tab_id, now);
  TabLiveState state = tab->live_state;
  state.sleep_phase = SleepPhase::kLive;
  state.has_web_content = true;
  model.UpdateTabLiveState(tab_id, state);
  return true;
}

size_t SleepScheduler::HandleCriticalMemoryPressure(
    BrowserModel& model,
    const std::set<ItemID>& visible_tab_ids,
    TimestampSec now) {
  std::unordered_map<ProfileID, KeepAliveMatcher> matchers;
  std::unordered_map<ProfileID, SleepMode> modes;
  for (const Profile& profile : model.profiles()) {
    matchers.emplace(profile.id,
                     KeepAliveMatcher(profile.settings.keep_alive_sites));
    modes.emplace(profile.id, profile.settings.sleep_mode);
  }

  std::vector<std::pair<ItemID, ProfileID>> tabs;
  CollectAllTabIds(model, &tabs);

  size_t discarded = 0;
  for (const auto& [tab_id, profile_id] : tabs) {
    const Tab* tab = model.FindTab(tab_id);
    if (!tab) continue;
    if (tab->live_state.sleep_phase != SleepPhase::kLive &&
        tab->live_state.sleep_phase != SleepPhase::kFrozen) {
      continue;
    }
    auto mode_it = modes.find(profile_id);
    auto matcher_it = matchers.find(profile_id);
    if (mode_it == modes.end() || matcher_it == matchers.end()) {
      continue;
    }
    auto& track = tracking_[tab_id];
    SleepPolicyGate gate = EvaluateBlockingGate(
        *tab, mode_it->second, matcher_it->second, visible_tab_ids, track, now,
        /*for_discard=*/true, /*critical_pressure=*/true);
    if (gate != SleepPolicyGate::kNone) {
      continue;
    }
    if (callbacks_.on_discard && callbacks_.on_discard.Run(tab_id)) {
      TabLiveState state = tab->live_state;
      state.sleep_phase = SleepPhase::kSleeping;
      state.has_web_content = false;
      track.slept_at = now;
      model.UpdateTabLiveState(tab_id, state);
      ++discarded;
    }
  }
  return discarded;
}

}  // namespace open_unified
