// Copyright 2026 The Open Authors. All rights reserved.
// Instant ranked Command Bar suggestion engine combining open/pinned/favorite
// tabs, FTS5 history, Open commands, site search engines, calculator, and
// inline host/URL completion (< 5ms ranking).

#ifndef OPEN_UNIFIED_CORE_SUGGEST_SUGGEST_ENGINE_H_
#define OPEN_UNIFIED_CORE_SUGGEST_SUGGEST_ENGINE_H_

#include <cstdint>
#include <map>
#include <memory>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

#include "base/functional/callback.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/scoped_refptr.h"
#include "base/memory/weak_ptr.h"
#include "base/sequence_checker.h"
#include "base/time/time.h"
#include "open_unified/core/commands/command_registry.h"
#include "open_unified/core/model/browser_model.h"
#include "open_unified/core/model/open_types.h"
#include "open_unified/core/store/sqlite_stores.h"

namespace network {
class SharedURLLoaderFactory;
class SimpleURLLoader;
namespace mojom {
class URLLoaderFactory;
}  // namespace mojom
}  // namespace network

namespace open_unified {

enum class SuggestScopeKind {
  kAll,
  kTabs,
  kActions,
  kSiteSearch,
  // An extension's omnibox keyword scope (chrome.omnibox). Reached through a
  // Site Search id with the "extension:" prefix (see ExtensionScopeId()), so
  // callers that only know Site Search scopes enter it unchanged.
  kExtension,
};

// Site Search ids with this prefix name an extension keyword scope.
inline constexpr char kExtensionScopePrefix[] = "extension:";

struct SuggestScope {
  SuggestScopeKind kind = SuggestScopeKind::kAll;
  // kSiteSearch: the site id. kExtension: the extension id (no prefix).
  std::string site_search_id;

  static SuggestScope All() {
    return {SuggestScopeKind::kAll, {}};
  }
  static SuggestScope Tabs() {
    return {SuggestScopeKind::kTabs, {}};
  }
  static SuggestScope Actions() {
    return {SuggestScopeKind::kActions, {}};
  }
  static SuggestScope SiteSearch(std::string id) {
    return {SuggestScopeKind::kSiteSearch, std::move(id)};
  }
  static SuggestScope Extension(std::string extension_id) {
    return {SuggestScopeKind::kExtension, std::move(extension_id)};
  }
};

// "extension:<id>" for `extension_id`.
std::string ExtensionScopeId(std::string_view extension_id);
// The extension id of an "extension:<id>" Site Search id, else nullopt.
std::optional<std::string> ExtensionIdFromScopeId(std::string_view scope_id);

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
  // Privacy gate for search-engine suggestions: the caller sets this only
  // when the Profile allows them (ProfileSettings::search_suggest_enabled is
  // also checked) and the window is not private. Off: nothing is sent and no
  // cached remote row shows.
  bool allows_remote_suggestions = false;
  // Optional availability rule for registry commands (macOS ActionsProvider
  // filters with the current tab's state). Null: every command shows.
  base::RepeatingCallback<bool(const CommandDefinition&)> is_command_available;
};

// Why a row exists beyond its SuggestionKind. Kinds stay fixed (callers
// switch on them exhaustively); roles add the newer row families.
enum class SuggestionRole {
  kDefault,
  kRemoteQuery,          // kSearch: a search-engine query suggestion.
  kRemoteNavigation,     // kNavigate: a search-engine page suggestion.
  kExtensionAction,      // kAction: an extension's toolbar action.
  kExtensionKeyword,     // kSiteSearchHint: Tab enters the extension scope.
  kExtensionSuggestion,  // kSiteSearch: an extension omnibox row.
  kDocument,             // kNavigate: an Easel or Note.
  kNewDocument,          // kNavigate: "New Google Doc" and the like.
  kQuickCreate,          // kAction: New Easel / Note / Boost / Space.
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
  SuggestionRole role = SuggestionRole::kDefault;
  // The page whose favicon the row shows (tab, history, Favorite, pinned,
  // document rows); usually `url`. Empty for actions and searches.
  std::optional<std::string> favicon_page_url;
  std::optional<std::string> extension_id;
  // kExtensionSuggestion: the text sent to chrome.omnibox.onInputEntered.
  std::optional<std::string> extension_content;
  std::optional<std::string> document_id;
  bool is_deletable = false;
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
  // The search engine FetchRemoteSuggestions() would ask for this query and
  // context, or nullopt when nothing may leave the machine (privacy gate).
  std::optional<std::string> remote_engine_id;
};

// --- Search engines (OpenSuggest/SearchEngine.swift) -------------------------

enum class SuggestResponseFormat {
  kOpenSearch,    // ["q", ["s1", "s2"], ...]
  kGoogleChrome,  // OpenSearch + {"google:suggesttype": [...]} at index 4.
};

struct SearchEngineEntry {
  std::string id;  // "google", "duckduckgo", ..., or a custom engine id.
  std::string name;
  std::vector<std::string> keywords;
  std::string search_url_template;   // "%s" (or "{searchTerms}") = query.
  std::string suggest_url_template;  // Empty: no remote suggestions.
  SuggestResponseFormat suggest_format = SuggestResponseFormat::kOpenSearch;
  bool is_custom = false;
};

// One parsed suggest entry.
struct RemoteSuggestItem {
  enum class Type { kQuery, kNavigation };
  Type type = Type::kQuery;
  std::string text;   // kQuery: the query. kNavigation: the URL.
  std::string title;  // kNavigation only (may be empty).

  bool operator==(const RemoteSuggestItem&) const = default;
};

struct RemoteSuggestionResult {
  std::string query;
  std::string engine_id;
  uint64_t request_id = 0;
  // Rows score below the typed search row (100 × 0.45 − 0.5 × rank), so a
  // late answer never moves the top hit.
  std::vector<Suggestion> suggestions;
  bool from_cache = false;
  // Timeout, offline, HTTP error or bad body. `suggestions` then holds the
  // carry-over rows from the previous answer (may be empty).
  bool failed = false;
};

using RemoteSuggestionsCallback =
    base::OnceCallback<void(RemoteSuggestionResult result)>;

// --- Extension and document sources (fed by the browser layer) -------------

struct ExtensionActionEntry {
  std::string extension_id;
  std::string name;
  std::string shortcut_display;  // "⌘⇧Y"; empty without a command.
};

struct ExtensionKeywordEntry {
  std::string extension_id;
  std::string name;
  std::string keyword;  // chrome.omnibox manifest keyword.
};

struct ExtensionOmniboxEntry {
  std::string content;      // Text for onInputEntered.
  std::string description;  // Shown title (markup already stripped).
  bool deletable = false;
};

struct DocumentEntry {
  enum class Kind { kEasel, kNote };
  std::string id;
  Kind kind = Kind::kEasel;
  std::string title;
  std::string url;  // The document's own address (opens or selects it).
  TimestampSec modified_at = 0.0;
};

class SuggestEngine {
 public:
  // Remote suggestion request limits (RemoteSuggestions.swift).
  static constexpr base::TimeDelta kRemoteDebounce = base::Milliseconds(80);
  static constexpr base::TimeDelta kRemoteTimeout = base::Milliseconds(300);
  static constexpr size_t kRemoteMaxQueryLength = 200;
  static constexpr size_t kRemoteMaxRows = 5;
  static constexpr size_t kRemoteMaxBodyBytes = 64 * 1024;
  static constexpr size_t kRemoteCacheCapacity = 64;
  static constexpr base::TimeDelta kRemoteCacheLifetime = base::Seconds(300);
  // At most this many Easels and Notes are searched (EaselsProvider.swift).
  static constexpr size_t kMaxDocuments = 2000;

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
  // Replaces every "%s" and "{searchTerms}" with the percent-encoded query.
  static std::string FillSearchUrlTemplate(std::string_view url_template,
                                           std::string_view query);
  static std::optional<std::string> ClassifyTypedUrl(std::string_view text);
  static std::optional<double> EvaluateCalculator(std::string_view expr);
  static std::optional<InlineCompletion> ComputeInlineCompletion(
      std::string_view raw_typed,
      std::string_view url,
      const std::string& row_id);

  // --- Search engines ------------------------------------------------------

  // Google, DuckDuckGo, Bing, Brave, Ecosia, Kagi, Perplexity, Yahoo.
  static const std::vector<SearchEngineEntry>& BuiltInSearchEngines();
  // The engine for `engine_id` (built-in or a custom engine of the Profile);
  // with no id, the Profile's default; Google when nothing matches.
  SearchEngineEntry ResolveSearchEngine(
      const std::optional<std::string>& engine_id,
      const std::optional<ProfileID>& profile_id) const;
  // The page a typed search opens with the context's engine (the Profile's
  // default unless `context.search_engine_id` overrides it). Use this instead
  // of a hard-coded Google template for typed-text fallbacks.
  std::string SearchUrlFor(std::string_view text,
                           const SuggestContext& context) const;
  // A suggest endpoint for a custom engine (PreferencesStore / Settings);
  // custom engines without one get no remote suggestions unless their host
  // is a built-in engine's host.
  void SetCustomSuggestTemplate(
      const std::string& engine_id,
      std::string suggest_url_template,
      SuggestResponseFormat format = SuggestResponseFormat::kOpenSearch);
  static std::vector<RemoteSuggestItem> ParseSuggestResponse(
      std::string_view body,
      SuggestResponseFormat format);

  // --- Remote search suggestions ---------------------------------------------

  // The engine to ask for `query`, or nullopt when this input must not go to
  // the network: remote suggestions off (context or Profile), Tabs / Actions
  // / extension scope, a Site Search scope that is not a search engine,
  // URL-like or calculator input, empty input, or more than 200 characters.
  std::optional<SearchEngineEntry> RemoteSuggestEngineFor(
      std::string_view query,
      const SuggestContext& context) const;

  // Fetches `search_engine_id`'s suggestions for `query` now (no debounce,
  // no privacy gate: call RemoteSuggestEngineFor() first). `factory` must
  // outlive the request (or call CancelRemoteSuggestions()). The request
  // sends no cookies and no credentials, skips the HTTP cache and times out
  // after 300 ms. An exact cache hit answers synchronously. Returns the
  // request id (0 when answered from cache or refused).
  uint64_t FetchRemoteSuggestions(const std::string& query,
                                  const std::string& search_engine_id,
                                  network::mojom::URLLoaderFactory* factory,
                                  RemoteSuggestionsCallback callback);
  // Gated and debounced (80 ms) form for the Command Bar: resolves the
  // engine from `context`, answers nothing (no callback) when the privacy
  // gate refuses, and is cancelled by CancelRemoteSuggestions(request id).
  uint64_t FetchRemoteSuggestions(
      const std::string& query,
      const SuggestContext& context,
      scoped_refptr<network::SharedURLLoaderFactory> factory,
      RemoteSuggestionsCallback callback);
  // Drops a pending or running request; its callback never runs.
  void CancelRemoteSuggestions(uint64_t request_id);
  void CancelAllRemoteSuggestions();
  // Exact cache hit, else carry-over rows from the previous answer that still
  // start with `query` ("gith" -> "githu"). Rows as in the fetch result.
  std::vector<Suggestion> CachedRemoteSuggestions(
      std::string_view query,
      const SearchEngineEntry& engine,
      const std::optional<SiteSearchEntry>& site) const;

  // --- Extensions, documents -------------------------------------------------

  // Enabled extension toolbar actions of the Profile
  // (ExtensionActionsProvider).
  void SetExtensionActions(std::vector<ExtensionActionEntry> actions);
  // chrome.omnibox keywords of the Profile's enabled extensions.
  void SetExtensionKeywords(std::vector<ExtensionKeywordEntry> keywords);
  // Latest chrome.omnibox.onInputChanged answer for `text` in the extension
  // scope (at most 4 rows are used; the default row is built here).
  void SetExtensionOmniboxSuggestions(const std::string& extension_id,
                                      const std::string& text,
                                      std::vector<ExtensionOmniboxEntry> rows,
                                      std::string default_description = {});
  const std::vector<ExtensionKeywordEntry>& extension_keywords() const {
    return extension_keywords_;
  }
  // Easels and Notes by title (newest first, at most kMaxDocuments). List
  // them off the UI thread (DocumentStore reads disk) and pass the result.
  void SetDocuments(std::vector<DocumentEntry> documents);

  // Arc's new-document actions ("New Google Doc" -> https://doc.new).
  struct NewDocumentAction {
    std::string id;     // "new-document-google-doc"
    std::string title;  // "New Google Doc"
    std::string url;    // "https://doc.new"
  };
  static const std::vector<NewDocumentAction>& NewDocumentActions();

 private:
  struct RemoteCacheEntry {
    std::vector<RemoteSuggestItem> items;
    base::TimeTicks time;
  };
  struct RemoteRequest;

  std::vector<SiteSearchEntry> EffectiveSiteSearches(
      const std::optional<ProfileID>& profile_id) const;
  SiteSearchEntry ResolveDefaultSearchEngine(
      const SuggestContext& context,
      const std::optional<ProfileID>& profile_id) const;
  std::optional<ProfileID> EffectiveProfile(
      const SuggestContext& context) const;
  std::optional<SearchEngineEntry> SuggestEngineForTemplate(
      const SearchEngineEntry& engine) const;

  std::vector<Suggestion> RemoteRows(
      const std::vector<RemoteSuggestItem>& items,
      std::string_view query,
      const SearchEngineEntry& engine,
      const std::optional<SiteSearchEntry>& site) const;
  void StartRemoteRequest(uint64_t request_id,
                          network::mojom::URLLoaderFactory* factory);
  void OnRemoteDebounced(uint64_t request_id);
  void OnRemoteResponse(uint64_t request_id, std::optional<std::string> body);
  void StoreRemote(const std::string& engine_id,
                   const std::string& query,
                   std::vector<RemoteSuggestItem> items);

  raw_ptr<const BrowserModel> model_ = nullptr;
  raw_ptr<HistoryStore> history_store_ = nullptr;
  raw_ptr<const CommandRegistry> command_registry_ = nullptr;
  std::vector<HistoryEntry> recent_history_;

  std::vector<ExtensionActionEntry> extension_actions_;
  std::vector<ExtensionKeywordEntry> extension_keywords_;
  struct OmniboxAnswer {
    std::string text;
    std::vector<ExtensionOmniboxEntry> rows;
    std::string default_description;
  };
  std::map<std::string, OmniboxAnswer> extension_omnibox_;
  std::vector<DocumentEntry> documents_;
  std::vector<std::string> folded_document_titles_;

  struct CustomSuggest {
    std::string url_template;
    SuggestResponseFormat format = SuggestResponseFormat::kOpenSearch;
  };
  std::map<std::string, CustomSuggest> custom_suggest_templates_;

  // Remote cache: (engine, query) -> items, FIFO capacity 64, 300 s.
  std::map<std::string, RemoteCacheEntry> remote_cache_;
  std::vector<std::string> remote_cache_order_;
  struct LastRemote {
    std::string engine_id;
    std::string folded_query;
    std::vector<RemoteSuggestItem> items;
  };
  std::optional<LastRemote> last_remote_;

  uint64_t next_request_id_ = 1;
  std::map<uint64_t, std::unique_ptr<RemoteRequest>> remote_requests_;

  SEQUENCE_CHECKER(sequence_checker_);
  base::WeakPtrFactory<SuggestEngine> weak_factory_{this};
};

}  // namespace open_unified

#endif  // OPEN_UNIFIED_CORE_SUGGEST_SUGGEST_ENGINE_H_
