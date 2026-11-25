// Copyright 2026 The Open Authors. All rights reserved.
// Per-Profile Boosts & Zap store, SiteMatch, CSS/injection planner, isolated
// world 6 JS runtime helpers, and strict Zap message validator.

#ifndef OPEN_UNIFIED_CORE_BOOSTS_BOOST_STORE_H_
#define OPEN_UNIFIED_CORE_BOOSTS_BOOST_STORE_H_

#include <cstddef>
#include <cstdint>
#include <filesystem>
#include <map>
#include <mutex>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

#include "base/files/file_path.h"
#include "base/memory/raw_ptr.h"
#include "base/values.h"
#include "open_unified/core/model/open_types.h"

namespace open_unified {

// Blink isolated world ID dedicated to Open Boosts & Zap (docs/boosts.md).
inline constexpr int kIsolatedWorldIdOpen = 6;

// Hard validation caps for Zap IPC (docs/boosts.md).
inline constexpr size_t kZapMaxMessageBytes = 64 * 1024;    // 64 KiB
inline constexpr size_t kZapMaxSelectorBytes = 4096;        // 4,096 UTF-8 bytes
inline constexpr size_t kZapMaxLabelBytes = 1024;           // 1,024 UTF-8 bytes
inline constexpr size_t kZapMaxEntriesPerBoost = 1024;      // 1,024 Zaps

// Host suffix or exact IP literal matcher with optional slash-boundary path prefix.
struct SiteMatch {
  std::string domain;
  std::optional<std::string> path_prefix;

  static SiteMatch Normalized(std::string_view raw_domain,
                              std::optional<std::string_view> path_prefix =
                                  std::nullopt);
  static bool IsIpAddress(std::string_view host);

  bool Matches(std::string_view host, std::string_view encoded_path) const;
  bool MatchesUrl(std::string_view url) const;
};

// Resolved Boost plan ready for isolated world 6 injection.
struct BoostInjectionPlan {
  std::string plan_id;  // FNV-1a content hash ("<count>-<16hex>" or "empty")
  std::string url;
  ProfileID profile_id;
  std::vector<Boost> matched_boosts;
  std::string generated_css;
  std::string combined_js;  // Executed in main world via separate user script
  bool contains_js = false;
  int bridge_version = 1;

  bool is_empty() const { return matched_boosts.empty(); }
  // Encodes the wire JSON payload for `boost:apply` (v=1).
  std::string ToWirePayloadJson() const;
};

// Per-Profile JSON store persisted atomically at `<profile_dir>/Boosts/boosts.json`.
class BoostStore {
 public:
  BoostStore(ProfileID profile_id, base::FilePath profile_dir);
  explicit BoostStore(std::filesystem::path json_path);
  ~BoostStore();

  BoostStore(const BoostStore&) = delete;
  BoostStore& operator=(const BoostStore&) = delete;

  // Loads Boosts/boosts.json. Moves corrupt files aside to
  // boosts.json.corrupt-<timestamp>. Safe to call on a fresh profile (one
  // PathExists check).
  std::vector<Boost> Load();

  std::vector<Boost> AllBoosts() const;
  std::vector<Boost> List() { return Load(); }
  std::optional<Boost> GetBoost(const std::string& boost_id) const;

  // Normalizes, updates modified_at, and saves atomically.
  Boost Upsert(Boost boost);
  Boost Save(Boost boost) { return Upsert(std::move(boost)); }
  bool Delete(const std::string& boost_id);
  bool SetEnabled(const std::string& boost_id, bool enabled);
  bool AppendZap(const std::string& boost_id, ZappedElement zap);
  bool RemoveZap(const std::string& boost_id, std::string_view selector);

  // Flushes current state atomically to Boosts/boosts.json.
  bool SaveNow();

  // Retires the store permanently before Profile deletion.
  void Retire();

  // Returns enabled (or all, when include_disabled=true) Boosts matching |url|,
  // ordered general-to-specific, then created_at, then id.
  std::vector<Boost> MatchUrl(std::string_view url,
                              bool include_disabled = false) const;

  // Builds a complete injection plan + CSS for |url|.
  BoostInjectionPlan BuildInjectionPlan(std::string_view url,
                                        bool boosts_globally_enabled) const;

  // Generates CSS from a single Boost or an ordered list of Boosts.
  static std::string GenerateCssForBoost(const Boost& boost);
  static std::string GenerateCssForBoosts(const std::vector<Boost>& boosts);

  // Loads boost-applier.js / zap-picker.js from |resource_dir| (if non-empty
  // and present), falling back to built-in isolated-world v1 runtime helpers.
  static std::string LoadBoostApplierJs(
      const base::FilePath& resource_dir = base::FilePath());
  static std::string LoadZapPickerJs(
      const base::FilePath& resource_dir = base::FilePath());

  // Wraps an outbound command as a JS evaluation snippet for isolated world 6:
  // `window.__open && window.__open.receive({v:1,type:...,payload:...});`
  static std::string BuildReceiveScript(std::string_view type,
                                        std::string_view payload_json);

  const ProfileID& profile_id() const { return profile_id_; }
  base::FilePath file_path() const { return file_path_; }

 private:
  static Boost NormalizeBoost(Boost boost, const ProfileID& profile_id);
  bool WriteLocked() const;

  ProfileID profile_id_;
  base::FilePath file_path_;
  mutable std::mutex mutex_;
  std::map<std::string, Boost> boosts_;
  int loaded_schema_version_ = 1;
  bool retired_ = false;
};

// --- Zap Picker Session & Strict Message Validator ---

enum class ZapPickerMode {
  kZap,
  kSelect,
};

struct ZapPickerSession {
  std::string page_id;
  std::string boost_id;
  std::string session_nonce;
  ZapPickerMode mode = ZapPickerMode::kZap;
};

struct ZapListEntry {
  std::string selector;
  std::string label;
  int match_count = 0;
  bool truncated = false;
};

struct ZapMessageValidationResult {
  bool accepted = false;
  bool store_mutated = false;
  std::string event_type;  // "committed", "removed", "exited", "selected", "listResult", etc.
  std::string selected_selector;
  int selected_matches = 0;
  std::vector<ZapListEntry> list_entries;
  std::string reject_reason;
};

// Manages native-issued Zap picker sessions keyed by engine document/frame ID
// and enforces all docs/boosts.md security & size invariants.
class BoostPickerCoordinator {
 public:
  explicit BoostPickerCoordinator(BoostStore* store);
  ~BoostPickerCoordinator();

  // Checks stored-Zap caps before allowing Zap entry.
  bool CanEnterZap(const std::string& boost_id) const;

  // Arms a native session for |page_id| and returns (type, payload_json) for
  // `zap:enter`, or std::nullopt if refused.
  std::optional<std::pair<std::string, std::string>> EnterZap(
      const std::string& boost_id,
      const std::string& page_id,
      ZapPickerMode mode = ZapPickerMode::kZap);

  // Builds bounded (< 64 KiB) `zap:list` messages for the active session.
  std::vector<std::pair<std::string, std::string>> BuildListZapMessages(
      const std::string& page_id) const;

  std::optional<std::pair<std::string, std::string>> BuildUndoMessage(
      const std::string& page_id) const;
  std::optional<std::pair<std::string, std::string>> BuildRemoveZapMessage(
      const std::string& page_id,
      std::string_view selector) const;
  std::optional<std::pair<std::string, std::string>> BuildOcclusionMessage(
      const std::string& page_id,
      double right_fraction,
      double top_fraction,
      double bottom_fraction) const;

  // Expires native capability before sending `zap:exit`.
  std::optional<std::pair<std::string, std::string>> ExitZap(
      const std::string& page_id);

  // Invalidates session on navigation, reload, frame close, or tab discard.
  void InvalidatePage(const std::string& page_id);

  bool HasActiveSession(const std::string& page_id) const;

  // Validates raw JSON envelope `{v: 1, type: "...", payload: {...}}` arriving
  // from Blink isolated world 6 for |page_id| (derived from RenderFrameHost,
  // never from JSON). Enforces 64 KiB cap, 4096 B selector cap, 1024 B label
  // cap, exact field allowlists, and session nonce matching.
  ZapMessageValidationResult HandleRawMessage(const std::string& page_id,
                                              std::string_view raw_json);

 private:
  raw_ptr<BoostStore> store_;
  std::map<std::string, ZapPickerSession> sessions_;
};

}  // namespace open_unified

#endif  // OPEN_UNIFIED_CORE_BOOSTS_BOOST_STORE_H_
