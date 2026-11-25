// Copyright 2026 The Open Authors. All rights reserved.
// Instant ranked Command Bar suggestion engine combining open/pinned/favorite
// tabs, FTS5 history, Open commands, site search engines, calculator, and
// inline host/URL completion (< 5ms ranking).

#ifndef OPEN_UNIFIED_CORE_SUGGEST_SUGGEST_ENGINE_H_
#define OPEN_UNIFIED_CORE_SUGGEST_SUGGEST_ENGINE_H_

#include <optional>
#include <string>
#include <string_view>
#include <vector>

#include "base/memory/raw_ptr.h"
#include "open_unified/core/commands/command_registry.h"
#include "open_unified/core/model/browser_model.h"
#include "open_unified/core/model/open_types.h"
#include "open_unified/core/store/sqlite_stores.h"

namespace open_unified {

enum class SuggestScopeKind {
  kAll,
  kTabs,
  kActions,
  kSiteSearch,
};

struct SuggestScope {
  SuggestScopeKind kind = SuggestScopeKind::kAll;
  std::string site_search_id;  // Used when kind == kSiteSearch

  static SuggestScope All() { return {SuggestScopeKind::kAll, {}}; }
  static SuggestScope Tabs() { return {SuggestScopeKind::kTabs, {}}; }
  static SuggestScope Actions() { return {SuggestScopeKind::kActions, {}}; }
  static SuggestScope SiteSearch(std::string id) {
    return {SuggestScopeKind::kSiteSearch, std::move(id)};
  }
};

enum class SuggestMode {
  kNewTab,
  kEditCurrentUrl,
  kSearchTabs,
  kSearchActions,
};

struct SuggestContext {
  SuggestMode mode = SuggestMode::kNewTab;
  SuggestScope scope = SuggestScope::All();
  std::optional<ProfileID> profile_id;
  std::optional<SpaceID> space_id;
  std::optional<ItemID> current_tab_id;
  std::optional<std::string> current_tab_url;
  std::optional<std::string> search_engine_id;
  bool allows_inline_completion = false;
  int max_results = 12;
};

enum class SuggestionKind {
  kNavigate,
  kSearch,
  kSwitchToTab,
  kHistory,
  kCalculator,
  kAction,
  kSiteSearch,
  kSiteSearchHint,
};

enum class TabLocation {
  kToday,
  kPinned,
  kFavorite,
  kSplitPane,
};

enum class TopHitRule {
  kNone,
  kSiteSearchScope,
  kBestTab,
  kBestAction,
  kInlineCompletion,
  kTypedUrl,
  kCalculator,
  kExactTab,
  kExactAction,
  kBestEligible,
  kTypedSearch,
};

struct InlineCompletion {
  std::string row_id;
  std::string field_text;
  size_t typed_length = 0;

  bool operator==(const InlineCompletion&) const = default;
};

struct SiteSearchEntry {
  std::string id;
  std::string name;
  std::string host;
  std::vector<std::string> keywords;
  std::string url_template;  // Contains "%s"
};

struct Suggestion {
  std::string id;
  SuggestionKind kind = SuggestionKind::kSearch;
  std::string title;
  std::string subtitle;
  std::optional<std::string> url;
  std::optional<std::string> action_id;
  std::optional<CommandId> command_id;
  std::string shortcut_display;
  std::optional<ItemID> tab_id;
  std::optional<TabLocation> tab_location;
  std::optional<SpaceID> space_id;
  std::optional<std::string> space_title;
  std::optional<std::string> site_search_id;
  double score = 0.0;
  double match_quality = 0.0;
  double frecency = 0.0;
  bool is_what_you_typed = false;
  bool can_be_top_hit = false;
  bool is_exact_tab_match = false;
};

struct SuggestionResult {
  std::string query;
  bool is_url_input = false;
  std::optional<std::string> typed_url;
  std::vector<Suggestion> suggestions;
  bool has_top_hit = false;
  TopHitRule top_hit_rule = TopHitRule::kNone;
  std::optional<InlineCompletion> inline_completion;
  double elapsed_ms = 0.0;
};

class SuggestEngine {
 public:
  SuggestEngine(const BrowserModel* model,
                HistoryStore* history_store = nullptr,
                const CommandRegistry* command_registry = nullptr);
  ~SuggestEngine();

  void SetModel(const BrowserModel* model) { model_ = model; }
  void SetHistoryStore(HistoryStore* store) { history_store_ = store; }
  void SetRecentHistory(std::vector<HistoryEntry> entries);
  void SetCommandRegistry(const CommandRegistry* registry) {
    command_registry_ = registry;
  }

  // Synchronous instant ranked suggestions (budget: < 5 ms).
  SuggestionResult Query(const std::string& raw_query,
                         const SuggestContext& context,
                         TimestampSec now = 0.0) const;

  // Resolves a Tab-key Site Search trigger ("yt" or "you" -> YouTube).
  std::optional<SiteSearchEntry> TriggerSiteSearch(
      const std::string& text,
      const std::optional<ProfileID>& profile_id = std::nullopt) const;

  static const std::vector<SiteSearchEntry>& BuiltInSiteSearches();
  static std::string FillSearchUrlTemplate(std::string_view url_template,
                                           std::string_view query);
  static std::optional<std::string> ClassifyTypedUrl(std::string_view text);
  static std::optional<double> EvaluateCalculator(std::string_view expr);
  static std::optional<InlineCompletion> ComputeInlineCompletion(
      std::string_view raw_typed,
      std::string_view url,
      const std::string& row_id);

 private:
  std::vector<SiteSearchEntry> EffectiveSiteSearches(
      const std::optional<ProfileID>& profile_id) const;
  SiteSearchEntry ResolveDefaultSearchEngine(
      const SuggestContext& context,
      const std::optional<ProfileID>& profile_id) const;

  raw_ptr<const BrowserModel> model_ = nullptr;
  raw_ptr<HistoryStore> history_store_ = nullptr;
  raw_ptr<const CommandRegistry> command_registry_ = nullptr;
  std::vector<HistoryEntry> recent_history_;
};

}  // namespace open_unified

#endif  // OPEN_UNIFIED_CORE_SUGGEST_SUGGEST_ENGINE_H_
