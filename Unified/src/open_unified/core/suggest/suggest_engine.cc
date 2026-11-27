// Copyright 2026 The Open Authors. All rights reserved.

#include "open_unified/core/suggest/suggest_engine.h"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstring>
#include <functional>
#include <iomanip>
#include <iterator>
#include <set>
#include <sstream>
#include <unordered_map>
#include <utility>

#include "base/functional/bind.h"
#include "base/json/json_reader.h"
#include "base/location.h"
#include "base/memory/stack_allocated.h"
#include "base/no_destructor.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/string_util.h"
#include "base/task/sequenced_task_runner.h"
#include "base/time/time.h"
#include "base/values.h"
#include "net/base/load_flags.h"
#include "net/http/http_request_headers.h"
#include "net/traffic_annotation/network_traffic_annotation.h"
#include "services/network/public/cpp/resource_request.h"
#include "services/network/public/cpp/shared_url_loader_factory.h"
#include "services/network/public/cpp/simple_url_loader.h"
#include "services/network/public/mojom/url_loader_factory.mojom.h"
#include "url/gurl.h"

namespace open_unified {

std::string ExtensionScopeId(std::string_view extension_id) {
  return std::string(kExtensionScopePrefix) + std::string(extension_id);
}

std::optional<std::string> ExtensionIdFromScopeId(std::string_view scope_id) {
  if (!base::StartsWith(scope_id, kExtensionScopePrefix,
                        base::CompareCase::SENSITIVE)) {
    return std::nullopt;
  }
  std::string id(scope_id.substr(std::strlen(kExtensionScopePrefix)));
  if (id.empty()) {
    return std::nullopt;
  }
  return id;
}

namespace {

constexpr net::NetworkTrafficAnnotationTag kRemoteSuggestTrafficAnnotation =
    net::DefineNetworkTrafficAnnotation("open_command_bar_search_suggest", R"(
        semantics {
          sender: "Open Command Bar"
          description:
            "Asks the user's chosen search engine for query suggestions "
            "while the user types in the Command Bar."
          trigger:
            "Typing search text (not a URL, not arithmetic, at most 200 "
            "characters) in the Command Bar, after an 80 ms pause."
          data:
            "The typed text, sent to the selected search engine's suggest "
            "endpoint. No cookies, credentials or browsing history."
          destination: OTHER
          destination_other: "The Profile's selected search engine."
        }
        policy {
          cookies_allowed: NO
          setting:
            "Settings > Profiles > Search suggestions, and the Command "
            "Bar's privacy notice (Dismiss / Search Settings)."
          policy_exception_justification:
            "Optional, per-Profile setting; off in private windows."
        })");

// Match quality levels matching
// Packages/OpenKit/Sources/OpenSuggest/TextMatching.swift.
constexpr double kQualityExact = 100.0;
constexpr double kQualityPrefix = 80.0;
constexpr double kQualityWordPrefix = 60.0;
constexpr double kQualityAllWordsPrefix = 50.0;
constexpr double kQualityInitials = 50.0;
constexpr double kQualitySubstring = 40.0;
constexpr double kQualityAllWordsSubstring = 30.0;
constexpr size_t kMinSubstringLen = 3;

constexpr double kCurrentSpaceBoost = 3.0;
constexpr double kAbsorbedFrecencyShare = 0.5;
constexpr size_t kMaxInlineFieldLen = 2048;

inline bool IsWordByte(unsigned char b) {
  return b >= 128 || (b >= 'a' && b <= 'z') || (b >= '0' && b <= '9') ||
         (b >= 'A' && b <= 'Z');
}

std::string FoldAsciiLower(std::string_view s) {
  std::string out;
  out.reserve(s.size());
  for (unsigned char c : s) {
    out.push_back((c >= 'A' && c <= 'Z') ? static_cast<char>(c + 32)
                                         : static_cast<char>(c));
  }
  return out;
}

uint64_t ComputeByteMask(std::string_view folded) {
  uint64_t mask = 0;
  for (unsigned char b : folded) {
    if (b != ' ') {
      mask |= (uint64_t{1} << (b & 63u));
    }
  }
  return mask;
}

std::vector<std::string> SplitWords(std::string_view folded) {
  std::vector<std::string> tokens;
  size_t i = 0;
  while (i < folded.size()) {
    while (i < folded.size() && folded[i] == ' ') {
      ++i;
    }
    size_t start = i;
    while (i < folded.size() && folded[i] != ' ') {
      ++i;
    }
    if (i > start) {
      tokens.emplace_back(folded.substr(start, i - start));
    }
  }
  return tokens;
}

std::string ComputeInitials(std::string_view folded) {
  std::string out;
  bool prev_word = false;
  for (unsigned char b : folded) {
    bool w = IsWordByte(b);
    if (w && !prev_word) {
      out.push_back(static_cast<char>(b));
    }
    prev_word = w;
  }
  return out;
}

double SingleFieldQuality(std::string_view q, std::string_view f) {
  if (q.empty() || q.size() > f.size()) {
    return 0.0;
  }
  if (std::memcmp(f.data(), q.data(), q.size()) == 0) {
    return q.size() == f.size() ? kQualityExact : kQualityPrefix;
  }
  char first = q[0];
  bool q_starts_word = IsWordByte(static_cast<unsigned char>(first));
  bool saw_substring = false;
  size_t last = f.size() - q.size();
  for (size_t i = 1; i <= last; ++i) {
    if (f[i] == first && std::memcmp(f.data() + i, q.data(), q.size()) == 0) {
      if (!q_starts_word || !IsWordByte(static_cast<unsigned char>(f[i - 1]))) {
        return kQualityWordPrefix;
      }
      saw_substring = true;
    }
  }
  return (saw_substring && q.size() >= kMinSubstringLen) ? kQualitySubstring
                                                         : 0.0;
}

double MultiFieldQuality(
    const std::string& folded_query,
    const std::vector<std::string>& tokens,
    const std::vector<std::string>& titles,
    const std::vector<std::pair<std::string, double>>& urls) {
  bool multi = tokens.size() > 1;
  double best = 0.0;
  for (const std::string& title : titles) {
    double q = SingleFieldQuality(folded_query, title);
    if (!multi || q >= kQualityWordPrefix) {
      best = std::max(best, q);
    }
  }
  for (const auto& [field, factor] : urls) {
    best = std::max(best, SingleFieldQuality(folded_query, field) * factor);
  }
  if (!multi || best >= kQualityAllWordsPrefix) {
    return best;
  }
  bool all_matched = true;
  bool all_word_prefix = true;
  for (const std::string& tok : tokens) {
    double tok_best = 0.0;
    for (const std::string& title : titles) {
      tok_best = std::max(tok_best, SingleFieldQuality(tok, title));
    }
    for (const auto& entry : urls) {
      tok_best = std::max(tok_best, SingleFieldQuality(tok, entry.first));
    }
    if (tok_best <= 0.0) {
      all_matched = false;
      break;
    }
    if (tok_best < kQualityWordPrefix) {
      all_word_prefix = false;
    }
  }
  if (!all_matched) {
    return best;
  }
  return std::max(best, all_word_prefix ? kQualityAllWordsPrefix
                                        : kQualityAllWordsSubstring);
}

std::string DisplayHost(std::string_view url) {
  std::string_view rest = url;
  if (size_t sep = rest.find("://"); sep != std::string_view::npos) {
    rest = rest.substr(sep + 3);
  }
  size_t end = rest.find_first_of("/?#");
  std::string_view authority =
      end == std::string_view::npos ? rest : rest.substr(0, end);
  if (size_t at = authority.rfind('@'); at != std::string_view::npos) {
    authority = authority.substr(at + 1);
  }
  if (!authority.empty() && authority.front() != '[') {
    if (size_t colon = authority.rfind(':'); colon != std::string_view::npos) {
      authority = authority.substr(0, colon);
    }
  }
  std::string host = FoldAsciiLower(authority);
  if (base::StartsWith(host, "www.", base::CompareCase::SENSITIVE)) {
    host.erase(0, 4);
  }
  return host;
}

std::string MatchableUrl(std::string_view url) {
  std::string_view s = url;
  if (size_t sep = s.find("://"); sep != std::string_view::npos) {
    s = s.substr(sep + 3);
  }
  if (size_t hash = s.find('#'); hash != std::string_view::npos) {
    s = s.substr(0, hash);
  }
  std::string out(s);
  if (base::StartsWith(out, "www.", base::CompareCase::INSENSITIVE_ASCII)) {
    out.erase(0, 4);
  }
  return out;
}

std::string UrlDedupeKey(std::string_view url) {
  size_t sep = url.find("://");
  std::string scheme =
      sep != std::string_view::npos ? FoldAsciiLower(url.substr(0, sep)) : "";
  std::string key;
  if (scheme != "http" && scheme != "https" && !scheme.empty()) {
    key = scheme + ":";
  }
  std::string_view rest =
      sep != std::string_view::npos ? url.substr(sep + 3) : url;
  if (size_t hash = rest.find('#'); hash != std::string_view::npos) {
    rest = rest.substr(0, hash);
  }
  size_t qpos = rest.find('?');
  std::string_view query =
      qpos != std::string_view::npos ? rest.substr(qpos + 1) : "";
  std::string_view before_q =
      qpos != std::string_view::npos ? rest.substr(0, qpos) : rest;
  size_t slash = before_q.find('/');
  std::string_view authority =
      slash != std::string_view::npos ? before_q.substr(0, slash) : before_q;
  std::string path = slash != std::string_view::npos
                         ? std::string(before_q.substr(slash))
                         : "";

  std::string host = FoldAsciiLower(authority);
  if (base::StartsWith(host, "www.", base::CompareCase::SENSITIVE)) {
    host.erase(0, 4);
  }
  if (scheme == "http" &&
      base::EndsWith(host, ":80", base::CompareCase::SENSITIVE)) {
    host.erase(host.size() - 3);
  } else if (scheme == "https" &&
             base::EndsWith(host, ":443", base::CompareCase::SENSITIVE)) {
    host.erase(host.size() - 4);
  }
  while (path.size() > 1 && path.back() == '/') {
    path.pop_back();
  }
  if (path == "/") {
    path.clear();
  }
  key += host;
  key += path;
  if (!query.empty()) {
    key.push_back('?');
    key.append(query);
  }
  return key;
}

double KindWeight(SuggestionKind kind) {
  switch (kind) {
    case SuggestionKind::kSwitchToTab:
    case SuggestionKind::kNavigate:
    case SuggestionKind::kCalculator:
      return 1.0;
    case SuggestionKind::kHistory:
      return 0.9;
    case SuggestionKind::kAction:
      return 0.85;
    case SuggestionKind::kSiteSearch:
      return 0.8;
    case SuggestionKind::kSiteSearchHint:
      return 0.6;
    case SuggestionKind::kSearch:
      return 0.5;
  }
  return 0.5;
}

int KindPriority(SuggestionKind kind) {
  switch (kind) {
    case SuggestionKind::kSwitchToTab:
      return 8;
    case SuggestionKind::kNavigate:
      return 7;
    case SuggestionKind::kCalculator:
      return 6;
    case SuggestionKind::kHistory:
      return 5;
    case SuggestionKind::kAction:
      return 4;
    case SuggestionKind::kSiteSearch:
      return 3;
    case SuggestionKind::kSiteSearchHint:
      return 2;
    case SuggestionKind::kSearch:
      return 1;
  }
  return 0;
}

int KindCap(SuggestionKind kind, SuggestScopeKind scope) {
  switch (kind) {
    case SuggestionKind::kSwitchToTab:
      return scope == SuggestScopeKind::kTabs ? 100 : 6;
    case SuggestionKind::kAction:
      return scope == SuggestScopeKind::kActions ? 100 : 3;
    case SuggestionKind::kHistory:
      return 6;
    case SuggestionKind::kNavigate:
      return 3;
    case SuggestionKind::kSiteSearch:
      return 2;
    case SuggestionKind::kSiteSearchHint:
    case SuggestionKind::kCalculator:
    case SuggestionKind::kSearch:
      return 1;
  }
  return 3;
}

double LocationBoost(TabLocation loc) {
  switch (loc) {
    case TabLocation::kToday:
    case TabLocation::kSplitPane:
      return 12.0;
    case TabLocation::kPinned:
    case TabLocation::kFavorite:
      return 10.0;
  }
  return 10.0;
}

double HistoryFrecency(int visits,
                       int typed,
                       TimestampSec last_visit,
                       TimestampSec now) {
  double base_count =
      static_cast<double>(std::max(0, visits) + 3 * std::max(0, typed));
  if (base_count <= 0.0) {
    return 0.0;
  }
  double age_days = std::max(0.0, now - last_visit) / 86400.0;
  return std::min(30.0, 8.0 * std::log1p(base_count / (1.0 + 0.15 * age_days)));
}

double TabRecency(TimestampSec last_active, TimestampSec now) {
  double age_hours = std::max(0.0, now - last_active) / 3600.0;
  return std::max(0.0, 6.0 - std::log1p(age_hours));
}

int MergePrecedence(const Suggestion& s) {
  if (s.kind == SuggestionKind::kSwitchToTab) {
    return 5;
  }
  if (s.is_what_you_typed) {
    return 4;
  }
  if (s.kind == SuggestionKind::kHistory) {
    return 3;
  }
  if (s.kind == SuggestionKind::kNavigate ||
      s.kind == SuggestionKind::kSiteSearch) {
    return 2;
  }
  return 1;
}

bool SuggestionOrder(const Suggestion& a, const Suggestion& b) {
  if (a.score != b.score) {
    return a.score > b.score;
  }
  int pa = KindPriority(a.kind);
  int pb = KindPriority(b.kind);
  if (pa != pb) {
    return pa > pb;
  }
  if (a.title != b.title) {
    return a.title < b.title;
  }
  return a.id < b.id;
}

// Percent-encodes RFC 3986 unreserved characters only.
std::string PercentEncodeQuery(std::string_view text) {
  static constexpr char kHex[] = "0123456789ABCDEF";
  std::string out;
  out.reserve(text.size() * 2);
  for (unsigned char c : text) {
    bool unreserved = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
                      (c >= '0' && c <= '9') || c == '-' || c == '.' ||
                      c == '_' || c == '~';
    if (unreserved) {
      out.push_back(static_cast<char>(c));
    } else {
      out.push_back('%');
      out.push_back(kHex[(c >> 4) & 0x0Fu]);
      out.push_back(kHex[c & 0x0Fu]);
    }
  }
  return out;
}

// Recursive descent parser for simple arithmetic expressions (+, -, *, /, ^,
// ()).
class CalcParser {
 public:
  explicit CalcParser(std::string_view input) : s_(input) {}

  std::optional<double> Parse() {
    auto val = ParseExpr();
    SkipWs();
    if (!val.has_value() || pos_ != s_.size() || !saw_operator_ ||
        !std::isfinite(*val)) {
      return std::nullopt;
    }
    return val;
  }

 private:
  static constexpr int kMaxDepth = 64;

  struct ScopedDepth {
    STACK_ALLOCATED();

   public:
    explicit ScopedDepth(int& depth) : depth_(depth) { ++depth_; }
    ~ScopedDepth() { --depth_; }
    bool ok() const { return depth_ <= kMaxDepth; }

   private:
    int& depth_;
  };

  void SkipWs() {
    while (pos_ < s_.size() &&
           std::isspace(static_cast<unsigned char>(s_[pos_]))) {
      ++pos_;
    }
  }

  std::optional<double> ParseExpr() {
    auto lhs = ParseTerm();
    if (!lhs.has_value()) {
      return std::nullopt;
    }
    while (true) {
      SkipWs();
      if (pos_ >= s_.size()) {
        break;
      }
      char op = s_[pos_];
      if (op != '+' && op != '-') {
        break;
      }
      ++pos_;
      saw_operator_ = true;
      auto rhs = ParseTerm();
      if (!rhs.has_value()) {
        return std::nullopt;
      }
      *lhs = (op == '+') ? (*lhs + *rhs) : (*lhs - *rhs);
    }
    return lhs;
  }

  std::optional<double> ParseTerm() {
    auto lhs = ParsePower();
    if (!lhs.has_value()) {
      return std::nullopt;
    }
    while (true) {
      SkipWs();
      if (pos_ >= s_.size()) {
        break;
      }
      char op = s_[pos_];
      if (op != '*' && op != '/') {
        break;
      }
      ++pos_;
      saw_operator_ = true;
      auto rhs = ParsePower();
      if (!rhs.has_value()) {
        return std::nullopt;
      }
      if (op == '/') {
        if (*rhs == 0.0) {
          return std::nullopt;
        }
        *lhs /= *rhs;
      } else {
        *lhs *= *rhs;
      }
    }
    return lhs;
  }

  std::optional<double> ParsePower() {
    auto base = ParseUnary();
    if (!base.has_value()) {
      return std::nullopt;
    }
    SkipWs();
    if (pos_ < s_.size() && s_[pos_] == '^') {
      ScopedDepth guard(depth_);
      if (!guard.ok()) {
        return std::nullopt;
      }
      ++pos_;
      saw_operator_ = true;
      auto exp = ParsePower();
      if (!exp.has_value()) {
        return std::nullopt;
      }
      return std::pow(*base, *exp);
    }
    return base;
  }

  std::optional<double> ParseUnary() {
    SkipWs();
    if (pos_ < s_.size() && (s_[pos_] == '+' || s_[pos_] == '-')) {
      ScopedDepth guard(depth_);
      if (!guard.ok()) {
        return std::nullopt;
      }
      char op = s_[pos_++];
      auto val = ParseUnary();
      if (!val.has_value()) {
        return std::nullopt;
      }
      return op == '-' ? -(*val) : *val;
    }
    return ParsePrimary();
  }

  std::optional<double> ParsePrimary() {
    SkipWs();
    if (pos_ >= s_.size()) {
      return std::nullopt;
    }
    if (s_[pos_] == '(') {
      ScopedDepth guard(depth_);
      if (!guard.ok()) {
        return std::nullopt;
      }
      ++pos_;
      auto val = ParseExpr();
      SkipWs();
      if (!val.has_value() || pos_ >= s_.size() || s_[pos_] != ')') {
        return std::nullopt;
      }
      ++pos_;
      return val;
    }
    size_t start = pos_;
    bool saw_digit = false;
    bool saw_dot = false;
    while (pos_ < s_.size()) {
      unsigned char c = static_cast<unsigned char>(s_[pos_]);
      if (std::isdigit(c)) {
        saw_digit = true;
        ++pos_;
      } else if (c == '.' && !saw_dot) {
        saw_dot = true;
        ++pos_;
      } else {
        break;
      }
    }
    if (!saw_digit) {
      return std::nullopt;
    }
    double value = 0.0;
    if (!base::StringToDouble(s_.substr(start, pos_ - start), &value)) {
      return std::nullopt;
    }
    return value;
  }

  std::string_view s_;
  size_t pos_ = 0;
  int depth_ = 0;
  bool saw_operator_ = false;
};

std::string FormatCalcValue(double v) {
  if (std::floor(v) == v && std::abs(v) < 1e15) {
    return std::to_string(static_cast<int64_t>(v));
  }
  std::ostringstream oss;
  oss << std::setprecision(10) << v;
  return oss.str();
}

bool IsCommonPublicSuffix(std::string_view tld) {
  static const std::set<std::string_view> kTlds = {
      "com",       "org",  "net",      "io",    "dev",  "app",   "ai",
      "co",        "gov",  "edu",      "me",    "tv",   "gg",    "xyz",
      "uk",        "ca",   "de",       "fr",    "jp",   "au",    "nl",
      "se",        "ch",   "it",       "es",    "br",   "in",    "kr",
      "cn",        "ru",   "info",     "biz",   "so",   "us",    "eu",
      "sh",        "to",   "fm",       "ly",    "page", "cloud", "tech",
      "design",    "news", "blog",     "store", "shop", "live",  "local",
      "localhost", "test", "internal",
  };
  return kTlds.count(tld) > 0;
}

bool IsIPv4(std::string_view host) {
  int parts = 0;
  size_t pos = 0;
  while (pos <= host.size()) {
    size_t dot = host.find('.', pos);
    std::string_view part = dot == std::string_view::npos
                                ? host.substr(pos)
                                : host.substr(pos, dot - pos);
    if (part.empty() || part.size() > 3) {
      return false;
    }
    if (part.size() > 1 && part[0] == '0') {
      return false;
    }
    int val = 0;
    for (char c : part) {
      if (!std::isdigit(static_cast<unsigned char>(c))) {
        return false;
      }
      val = val * 10 + (c - '0');
    }
    if (val > 255) {
      return false;
    }
    ++parts;
    if (dot == std::string_view::npos) {
      break;
    }
    pos = dot + 1;
  }
  return parts == 4;
}

// Per-row caps keyed by kind and role (Providers.swift maxRows).
int RowCap(const Suggestion& s, SuggestScopeKind scope) {
  switch (s.role) {
    case SuggestionRole::kRemoteQuery:
      return static_cast<int>(SuggestEngine::kRemoteMaxRows);
    case SuggestionRole::kRemoteNavigation:
      return 2;
    case SuggestionRole::kExtensionAction:
    case SuggestionRole::kDocument:
      return 3;
    case SuggestionRole::kExtensionSuggestion:
      return 5;
    case SuggestionRole::kNewDocument:
      return scope == SuggestScopeKind::kActions ? 100 : 2;
    case SuggestionRole::kExtensionKeyword:
      return 1;
    case SuggestionRole::kQuickCreate:
    case SuggestionRole::kDefault:
      break;
  }
  return KindCap(s.kind, scope);
}

int RowCapKey(const Suggestion& s) {
  return static_cast<int>(s.kind) * 32 + static_cast<int>(s.role);
}

// Commands that create something new (Arc's "New …" quick-create rows).
bool IsQuickCreateCommand(std::string_view id) {
  return id == "new-easel" || id == "new-note" || id == "new-boost" ||
         id == "new-space";
}

// Strips the ")]}'" XSSI guard some engines prepend.
std::string_view StripXssiPrefix(std::string_view body) {
  constexpr std::string_view kGuard = ")]}'";
  if (base::StartsWith(body, kGuard, base::CompareCase::SENSITIVE)) {
    body.remove_prefix(kGuard.size());
    while (!body.empty() && (body.front() == '\n' || body.front() == '\r')) {
      body.remove_prefix(1);
    }
  }
  return body;
}

bool SiteContainsHost(const SiteSearchEntry& site,
                      std::string_view page_host,
                      std::string_view matchable_url) {
  if (site.host.empty()) {
    return true;
  }
  if (size_t slash = site.host.find('/'); slash != std::string::npos) {
    return page_host == std::string_view(site.host).substr(0, slash) &&
           base::StartsWith(matchable_url, site.host,
                            base::CompareCase::INSENSITIVE_ASCII);
  }
  return page_host == site.host ||
         base::EndsWith(page_host, "." + site.host,
                        base::CompareCase::INSENSITIVE_ASCII);
}

}  // namespace

// ============================================================================
// SuggestEngine
// ============================================================================

struct SuggestEngine::RemoteRequest {
  std::string query;
  std::string folded_query;
  SearchEngineEntry engine;
  std::optional<SiteSearchEntry> site;
  GURL url;
  RemoteSuggestionsCallback callback;
  // Debounced requests keep their factory alive until they start.
  scoped_refptr<network::SharedURLLoaderFactory> shared_factory;
  std::unique_ptr<network::SimpleURLLoader> loader;
};

SuggestEngine::SuggestEngine(const BrowserModel* model,
                             HistoryStore* history_store,
                             const CommandRegistry* command_registry)
    : model_(model),
      history_store_(history_store),
      command_registry_(command_registry) {
  // Built on one sequence, used on the UI sequence.
  DETACH_FROM_SEQUENCE(sequence_checker_);
}

SuggestEngine::~SuggestEngine() = default;

void SuggestEngine::SetRecentHistory(std::vector<HistoryEntry> entries) {
  recent_history_ = std::move(entries);
}

const std::vector<SiteSearchEntry>& SuggestEngine::BuiltInSiteSearches() {
  static const std::vector<SiteSearchEntry> kBuiltIn = {
      {"youtube",
       "YouTube",
       "youtube.com",
       {"yt"},
       "https://www.youtube.com/results?search_query=%s"},
      {"github",
       "GitHub",
       "github.com",
       {"gh"},
       "https://github.com/search?q=%s&type=repositories"},
      {"wikipedia",
       "Wikipedia",
       "wikipedia.org",
       {"wiki"},
       "https://en.wikipedia.org/w/index.php?search=%s"},
      {"amazon",
       "Amazon",
       "amazon.com",
       {"amz"},
       "https://www.amazon.com/s?k=%s"},
      {"reddit",
       "Reddit",
       "reddit.com",
       {},
       "https://www.reddit.com/search/?q=%s"},
      {"x", "X", "x.com", {"twitter"}, "https://x.com/search?q=%s"},
      {"google-maps",
       "Google Maps",
       "google.com/maps",
       {"maps", "gmaps"},
       "https://www.google.com/maps/search/%s"},
      {"google-images",
       "Google Images",
       "google.com",
       {"images"},
       "https://www.google.com/search?tbm=isch&q=%s"},
      {"google-news",
       "Google News",
       "news.google.com",
       {},
       "https://news.google.com/search?q=%s"},
      {"google-drive",
       "Google Drive",
       "drive.google.com",
       {"drive", "gdrive"},
       "https://drive.google.com/drive/search?q=%s"},
      {"gmail",
       "Gmail",
       "mail.google.com",
       {},
       "https://mail.google.com/mail/u/0/#search/%s"},
      {"google-translate",
       "Google Translate",
       "translate.google.com",
       {"translate"},
       "https://translate.google.com/?sl=auto&text=%s"},
      {"stackoverflow",
       "Stack Overflow",
       "stackoverflow.com",
       {},
       "https://stackoverflow.com/search?q=%s"},
      {"mdn",
       "MDN",
       "developer.mozilla.org",
       {},
       "https://developer.mozilla.org/en-US/search?q=%s"},
      {"apple-developer",
       "Apple Developer",
       "developer.apple.com",
       {},
       "https://developer.apple.com/search/?q=%s"},
      {"npm", "npm", "npmjs.com", {}, "https://www.npmjs.com/search?q=%s"},
      {"hacker-news",
       "Hacker News",
       "news.ycombinator.com",
       {"hn"},
       "https://hn.algolia.com/?q=%s"},
      {"imdb", "IMDb", "imdb.com", {}, "https://www.imdb.com/find/?q=%s"},
      {"spotify",
       "Spotify",
       "open.spotify.com",
       {},
       "https://open.spotify.com/search/%s"},
      {"linkedin",
       "LinkedIn",
       "linkedin.com",
       {},
       "https://www.linkedin.com/search/results/all/?keywords=%s"},
      {"pinterest",
       "Pinterest",
       "pinterest.com",
       {},
       "https://www.pinterest.com/search/pins/?q=%s"},
      {"twitch",
       "Twitch",
       "twitch.tv",
       {},
       "https://www.twitch.tv/search?term=%s"},
      {"ebay",
       "eBay",
       "ebay.com",
       {},
       "https://www.ebay.com/sch/i.html?_nkw=%s"},
      // Built-in search engines as site search targets
      {"engine-google",
       "Google",
       "google.com",
       {"google", "g"},
       "https://www.google.com/search?q=%s"},
      {"engine-duckduckgo",
       "DuckDuckGo",
       "duckduckgo.com",
       {"duckduckgo", "ddg"},
       "https://duckduckgo.com/?q=%s"},
      {"engine-bing",
       "Bing",
       "bing.com",
       {"bing"},
       "https://www.bing.com/search?q=%s"},
      {"engine-brave",
       "Brave Search",
       "search.brave.com",
       {"brave"},
       "https://search.brave.com/search?q=%s"},
      {"engine-ecosia",
       "Ecosia",
       "ecosia.org",
       {"ecosia"},
       "https://www.ecosia.org/search?q=%s"},
      {"engine-kagi",
       "Kagi",
       "kagi.com",
       {"kagi"},
       "https://kagi.com/search?q=%s"},
      {"engine-perplexity",
       "Perplexity",
       "perplexity.ai",
       {"perplexity", "pplx"},
       "https://www.perplexity.ai/search/new?q=%s"},
      {"engine-yahoo",
       "Yahoo",
       "search.yahoo.com",
       {"yahoo"},
       "https://search.yahoo.com/search?p=%s"},
  };
  return kBuiltIn;
}

std::string SuggestEngine::FillSearchUrlTemplate(std::string_view url_template,
                                                 std::string_view query) {
  const std::string encoded = PercentEncodeQuery(query);
  std::string out(url_template);
  for (std::string_view token :
       {std::string_view("%s"), std::string_view("{searchTerms}")}) {
    size_t pos = 0;
    while ((pos = out.find(token, pos)) != std::string::npos) {
      out.replace(pos, token.size(), encoded);
      pos += encoded.size();
    }
  }
  return out;
}

// static
const std::vector<SearchEngineEntry>& SuggestEngine::BuiltInSearchEngines() {
  // Endpoints and formats: OpenSuggest/SearchEngine.swift (checked by hand
  // on 2026-10-24, docs/suggest.md). Perplexity has no suggest endpoint.
  using F = SuggestResponseFormat;
  static const base::NoDestructor<std::vector<SearchEngineEntry>> kEngines({
      {"google",
       "Google",
       {"google", "g"},
       "https://www.google.com/search?q=%s",
       "https://www.google.com/complete/search?client=chrome&ie=UTF-8&oe=UTF-"
       "8&q=%s",
       F::kGoogleChrome,
       false},
      {"duckduckgo",
       "DuckDuckGo",
       {"duckduckgo", "ddg"},
       "https://duckduckgo.com/?q=%s",
       "https://duckduckgo.com/ac/?q=%s&type=list",
       F::kOpenSearch,
       false},
      {"bing",
       "Bing",
       {"bing"},
       "https://www.bing.com/search?q=%s",
       "https://www.bing.com/osjson.aspx?query=%s",
       F::kOpenSearch,
       false},
      {"brave",
       "Brave Search",
       {"brave"},
       "https://search.brave.com/search?q=%s",
       "https://search.brave.com/api/suggest?q=%s",
       F::kOpenSearch,
       false},
      {"ecosia",
       "Ecosia",
       {"ecosia"},
       "https://www.ecosia.org/search?q=%s",
       "https://ac.ecosia.org/autocomplete?q=%s&type=list",
       F::kOpenSearch,
       false},
      {"kagi",
       "Kagi",
       {"kagi"},
       "https://kagi.com/search?q=%s",
       "https://kagi.com/api/autosuggest?q=%s",
       F::kOpenSearch,
       false},
      {"perplexity",
       "Perplexity",
       {"perplexity", "pplx"},
       "https://www.perplexity.ai/search/new?q=%s",
       "",
       F::kOpenSearch,
       false},
      {"yahoo",
       "Yahoo",
       {"yahoo"},
       "https://search.yahoo.com/search?p=%s",
       "https://search.yahoo.com/sugg/ff?output=fxjson&appid=ffd&command=%s",
       F::kOpenSearch,
       false},
  });
  return *kEngines;
}

std::optional<ProfileID> SuggestEngine::EffectiveProfile(
    const SuggestContext& context) const {
  if (context.profile_id.has_value()) {
    return context.profile_id;
  }
  if (model_ && context.space_id.has_value()) {
    if (const Space* sp = model_->FindSpace(*context.space_id)) {
      return sp->profile_id;
    }
  }
  return std::nullopt;
}

SearchEngineEntry SuggestEngine::ResolveSearchEngine(
    const std::optional<std::string>& engine_id,
    const std::optional<ProfileID>& profile_id) const {
  const Profile* profile =
      model_ && profile_id ? model_->FindProfile(*profile_id) : nullptr;
  std::string id = engine_id.value_or(std::string());
  if (id.empty() && profile) {
    id = profile->settings.search_engine_id;
  }
  // "engine-google" (a Site Search id) names the same engine as "google".
  if (base::StartsWith(id, "engine-", base::CompareCase::SENSITIVE)) {
    id.erase(0, 7);
  }
  for (const SearchEngineEntry& engine : BuiltInSearchEngines()) {
    if (engine.id == id) {
      return engine;
    }
  }
  std::string custom_id = id;
  if (base::StartsWith(custom_id, "custom-", base::CompareCase::SENSITIVE)) {
    custom_id.erase(0, 7);
  }
  // Custom engines of the Profile; with no Profile, of any Profile (custom
  // engine ids are UUIDs).
  std::vector<const Profile*> profiles;
  if (profile) {
    profiles.push_back(profile);
  } else if (model_ && !custom_id.empty()) {
    for (const Profile& p : model_->profiles()) {
      profiles.push_back(&p);
    }
  }
  for (const Profile* candidate : profiles) {
    for (const CustomSearchEngine& ce :
         candidate->settings.custom_search_engines) {
      if (ce.id != custom_id) {
        continue;
      }
      SearchEngineEntry entry;
      entry.id = ce.id;
      entry.name = ce.name;
      if (!ce.keyword.empty()) {
        entry.keywords.push_back(ce.keyword);
      }
      entry.search_url_template = ce.url_template;
      entry.is_custom = true;
      if (auto it = custom_suggest_templates_.find(ce.id);
          it != custom_suggest_templates_.end()) {
        entry.suggest_url_template = it->second.url_template;
        entry.suggest_format = it->second.format;
      }
      return entry;
    }
  }
  return BuiltInSearchEngines().front();
}

std::string SuggestEngine::SearchUrlFor(std::string_view text,
                                        const SuggestContext& context) const {
  const SearchEngineEntry engine =
      ResolveSearchEngine(context.search_engine_id, EffectiveProfile(context));
  return FillSearchUrlTemplate(engine.search_url_template, text);
}

void SuggestEngine::SetCustomSuggestTemplate(const std::string& engine_id,
                                             std::string suggest_url_template,
                                             SuggestResponseFormat format) {
  if (suggest_url_template.empty()) {
    custom_suggest_templates_.erase(engine_id);
    return;
  }
  custom_suggest_templates_[engine_id] = {std::move(suggest_url_template),
                                          format};
}

std::optional<SearchEngineEntry> SuggestEngine::SuggestEngineForTemplate(
    const SearchEngineEntry& engine) const {
  if (!engine.suggest_url_template.empty()) {
    return engine;
  }
  if (!engine.is_custom) {
    return std::nullopt;
  }
  // A custom engine on a built-in engine's host (e.g. a Google template with
  // extra parameters) uses that engine's suggest endpoint.
  const std::string host = DisplayHost(engine.search_url_template);
  for (const SearchEngineEntry& built_in : BuiltInSearchEngines()) {
    if (!built_in.suggest_url_template.empty() &&
        DisplayHost(built_in.search_url_template) == host) {
      SearchEngineEntry out = engine;
      out.suggest_url_template = built_in.suggest_url_template;
      out.suggest_format = built_in.suggest_format;
      return out;
    }
  }
  return std::nullopt;
}

// static
std::vector<RemoteSuggestItem> SuggestEngine::ParseSuggestResponse(
    std::string_view body,
    SuggestResponseFormat format) {
  std::vector<RemoteSuggestItem> items;
  std::optional<base::Value> root =
      base::JSONReader::Read(StripXssiPrefix(body), base::JSON_PARSE_RFC);
  const base::ListValue* list = root ? root->GetIfList() : nullptr;
  if (!list || list->size() < 2) {
    return items;
  }
  const base::ListValue* texts = (*list)[1].GetIfList();
  if (!texts) {
    return items;
  }
  const base::ListValue* descriptions =
      list->size() > 2 ? (*list)[2].GetIfList() : nullptr;
  const base::ListValue* types = nullptr;
  if (format == SuggestResponseFormat::kGoogleChrome && list->size() > 4) {
    if (const base::DictValue* extras = (*list)[4].GetIfDict()) {
      types = extras->FindList("google:suggesttype");
    }
  }
  for (size_t i = 0; i < texts->size(); ++i) {
    const std::string* text = (*texts)[i].GetIfString();
    if (!text || text->empty()) {
      continue;
    }
    const std::string* type =
        types && i < types->size() ? (*types)[i].GetIfString() : nullptr;
    if (type && *type == "NAVIGATION") {
      // A page row from the network is a web page only: never file:,
      // chrome:, or another scheme.
      const GURL url(*text);
      if (!url.is_valid() || !url.SchemeIsHTTPOrHTTPS() || url.host().empty()) {
        continue;
      }
      RemoteSuggestItem item;
      item.type = RemoteSuggestItem::Type::kNavigation;
      item.text = url.spec();
      if (descriptions && i < descriptions->size()) {
        if (const std::string* title = (*descriptions)[i].GetIfString()) {
          item.title = *title;
        }
      }
      items.push_back(std::move(item));
    } else if (!type || *type != "CALCULATOR") {
      // The local calculator answers arithmetic.
      items.push_back({RemoteSuggestItem::Type::kQuery, *text, {}});
    }
  }
  return items;
}

// --- Remote suggestions
// --------------------------------------------------------

std::optional<SearchEngineEntry> SuggestEngine::RemoteSuggestEngineFor(
    std::string_view query,
    const SuggestContext& context) const {
  if (!context.allows_remote_suggestions) {
    return std::nullopt;
  }
  const std::optional<ProfileID> profile_id = EffectiveProfile(context);
  if (model_ && profile_id) {
    if (const Profile* profile = model_->FindProfile(*profile_id);
        profile && !profile->settings.search_suggest_enabled) {
      return std::nullopt;
    }
  }
  // The Tabs and Actions scopes list only tabs or actions
  // (commandbar-completion §4.3.3); an extension scope talks to its
  // extension only.
  if (context.mode == SuggestMode::kSearchTabs ||
      context.mode == SuggestMode::kSearchActions) {
    return std::nullopt;
  }
  switch (context.scope.kind) {
    case SuggestScopeKind::kTabs:
    case SuggestScopeKind::kActions:
    case SuggestScopeKind::kExtension:
      return std::nullopt;
    case SuggestScopeKind::kAll:
    case SuggestScopeKind::kSiteSearch:
      break;
  }
  std::string trimmed;
  base::TrimWhitespaceASCII(query, base::TRIM_ALL, &trimmed);
  // The typed URL never leaves the machine; nor does arithmetic.
  if (trimmed.empty() || trimmed.size() > kRemoteMaxQueryLength ||
      ClassifyTypedUrl(trimmed).has_value() ||
      EvaluateCalculator(trimmed).has_value()) {
    return std::nullopt;
  }
  SearchEngineEntry engine;
  if (context.scope.kind == SuggestScopeKind::kSiteSearch) {
    const std::string& site_id = context.scope.site_search_id;
    if (ExtensionIdFromScopeId(site_id)) {
      return std::nullopt;
    }
    // Only a Site Search that is a search engine asks that engine.
    if (base::StartsWith(site_id, "engine-", base::CompareCase::SENSITIVE)) {
      engine = ResolveSearchEngine(site_id.substr(7), profile_id);
    } else if (base::StartsWith(site_id, "custom-",
                                base::CompareCase::SENSITIVE)) {
      engine = ResolveSearchEngine(site_id.substr(7), profile_id);
      if (!engine.is_custom) {
        return std::nullopt;
      }
    } else {
      return std::nullopt;
    }
  } else {
    engine = ResolveSearchEngine(context.search_engine_id, profile_id);
  }
  return SuggestEngineForTemplate(engine);
}

std::vector<Suggestion> SuggestEngine::RemoteRows(
    const std::vector<RemoteSuggestItem>& items,
    std::string_view query,
    const SearchEngineEntry& engine,
    const std::optional<SiteSearchEntry>& site) const {
  std::vector<Suggestion> rows;
  std::string trimmed;
  base::TrimWhitespaceASCII(query, base::TRIM_ALL, &trimmed);
  const std::string folded_query = FoldAsciiLower(trimmed);
  const std::string site_name = site ? site->name : engine.name;
  for (const RemoteSuggestItem& item : items) {
    if (rows.size() >= kRemoteMaxRows) {
      break;
    }
    const double rank = static_cast<double>(rows.size());
    Suggestion s;
    s.match_quality = kQualityExact;
    // Below the typed search row (50): 100 × 0.45 − 0.5 × rank.
    s.score = kQualityExact * 0.45 - 0.5 * rank;
    if (item.type == RemoteSuggestItem::Type::kQuery) {
      if (FoldAsciiLower(item.text) == folded_query) {
        continue;  // Same as the typed search row.
      }
      s.id = "remote:" + item.text;
      s.kind = SuggestionKind::kSearch;
      s.role = SuggestionRole::kRemoteQuery;
      s.title = item.text;
      s.subtitle = "Search " + site_name;
      s.url = FillSearchUrlTemplate(
          site ? site->url_template : engine.search_url_template, item.text);
      if (site) {
        s.site_search_id = site->id;
      }
    } else {
      if (site) {
        continue;  // A Site Search scope shows that site's queries only.
      }
      s.id = "remote-nav:" + UrlDedupeKey(item.text);
      s.kind = SuggestionKind::kNavigate;
      s.role = SuggestionRole::kRemoteNavigation;
      s.title = item.title.empty() ? MatchableUrl(item.text) : item.title;
      s.subtitle = MatchableUrl(item.text);
      s.url = item.text;
      s.favicon_page_url = item.text;
    }
    rows.push_back(std::move(s));
  }
  return rows;
}

std::vector<Suggestion> SuggestEngine::CachedRemoteSuggestions(
    std::string_view query,
    const SearchEngineEntry& engine,
    const std::optional<SiteSearchEntry>& site) const {
  std::string trimmed;
  base::TrimWhitespaceASCII(query, base::TRIM_ALL, &trimmed);
  const std::string key = engine.id + '\x01' + trimmed;
  if (auto it = remote_cache_.find(key);
      it != remote_cache_.end() &&
      base::TimeTicks::Now() - it->second.time < kRemoteCacheLifetime) {
    return RemoteRows(it->second.items, trimmed, engine, site);
  }
  // Carry-over: the previous answer's queries that still start with the new
  // text keep their rows until the new answer arrives.
  const std::string folded = FoldAsciiLower(trimmed);
  if (!last_remote_ || last_remote_->engine_id != engine.id ||
      folded.size() <= last_remote_->folded_query.size() ||
      !base::StartsWith(folded, last_remote_->folded_query,
                        base::CompareCase::SENSITIVE)) {
    return {};
  }
  std::vector<RemoteSuggestItem> kept;
  for (const RemoteSuggestItem& item : last_remote_->items) {
    if (item.type == RemoteSuggestItem::Type::kQuery &&
        base::StartsWith(FoldAsciiLower(item.text), folded,
                         base::CompareCase::SENSITIVE)) {
      kept.push_back(item);
    }
  }
  return RemoteRows(kept, trimmed, engine, site);
}

void SuggestEngine::StoreRemote(const std::string& engine_id,
                                const std::string& query,
                                std::vector<RemoteSuggestItem> items) {
  const std::string key = engine_id + '\x01' + query;
  if (remote_cache_.find(key) == remote_cache_.end()) {
    remote_cache_order_.push_back(key);
  }
  remote_cache_[key] = {items, base::TimeTicks::Now()};
  while (remote_cache_order_.size() > kRemoteCacheCapacity) {
    remote_cache_.erase(remote_cache_order_.front());
    remote_cache_order_.erase(remote_cache_order_.begin());
  }
  last_remote_ = LastRemote{engine_id, FoldAsciiLower(query), std::move(items)};
}

uint64_t SuggestEngine::FetchRemoteSuggestions(
    const std::string& query,
    const std::string& search_engine_id,
    network::mojom::URLLoaderFactory* factory,
    RemoteSuggestionsCallback callback) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  std::string trimmed;
  base::TrimWhitespaceASCII(query, base::TRIM_ALL, &trimmed);
  const SearchEngineEntry resolved =
      ResolveSearchEngine(search_engine_id, std::nullopt);
  std::string wanted = search_engine_id;
  for (std::string_view prefix : {"engine-", "custom-"}) {
    if (base::StartsWith(wanted, prefix, base::CompareCase::SENSITIVE)) {
      wanted.erase(0, prefix.size());
    }
  }
  // An unknown id must not silently ask Google.
  std::optional<SearchEngineEntry> engine;
  if (wanted.empty() || resolved.id == wanted) {
    engine = SuggestEngineForTemplate(resolved);
  }
  if (!engine || trimmed.empty() || trimmed.size() > kRemoteMaxQueryLength) {
    RemoteSuggestionResult refused;
    refused.query = trimmed;
    refused.engine_id = search_engine_id;
    refused.failed = true;
    std::move(callback).Run(std::move(refused));
    return 0;
  }
  const std::string key = engine->id + '\x01' + trimmed;
  if (auto it = remote_cache_.find(key);
      it != remote_cache_.end() &&
      base::TimeTicks::Now() - it->second.time < kRemoteCacheLifetime) {
    RemoteSuggestionResult cached;
    cached.query = trimmed;
    cached.engine_id = engine->id;
    cached.suggestions =
        RemoteRows(it->second.items, trimmed, *engine, std::nullopt);
    cached.from_cache = true;
    std::move(callback).Run(std::move(cached));
    return 0;
  }
  const uint64_t id = next_request_id_++;
  auto request = std::make_unique<RemoteRequest>();
  request->query = trimmed;
  request->folded_query = FoldAsciiLower(trimmed);
  request->url =
      GURL(FillSearchUrlTemplate(engine->suggest_url_template, trimmed));
  request->engine = std::move(*engine);
  request->callback = std::move(callback);
  remote_requests_[id] = std::move(request);
  StartRemoteRequest(id, factory);
  return id;
}

uint64_t SuggestEngine::FetchRemoteSuggestions(
    const std::string& query,
    const SuggestContext& context,
    scoped_refptr<network::SharedURLLoaderFactory> factory,
    RemoteSuggestionsCallback callback) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  std::optional<SearchEngineEntry> engine =
      RemoteSuggestEngineFor(query, context);
  if (!engine || !factory) {
    return 0;  // Privacy gate: nothing leaves the machine.
  }
  std::string trimmed;
  base::TrimWhitespaceASCII(query, base::TRIM_ALL, &trimmed);
  std::optional<SiteSearchEntry> site;
  if (context.scope.kind == SuggestScopeKind::kSiteSearch) {
    for (const SiteSearchEntry& s :
         EffectiveSiteSearches(EffectiveProfile(context))) {
      if (s.id == context.scope.site_search_id) {
        site = s;
        break;
      }
    }
  }
  const std::string key = engine->id + '\x01' + trimmed;
  if (auto it = remote_cache_.find(key);
      it != remote_cache_.end() &&
      base::TimeTicks::Now() - it->second.time < kRemoteCacheLifetime) {
    RemoteSuggestionResult cached;
    cached.query = trimmed;
    cached.engine_id = engine->id;
    cached.suggestions = RemoteRows(it->second.items, trimmed, *engine, site);
    cached.from_cache = true;
    std::move(callback).Run(std::move(cached));
    return 0;
  }
  const uint64_t id = next_request_id_++;
  auto request = std::make_unique<RemoteRequest>();
  request->query = trimmed;
  request->folded_query = FoldAsciiLower(trimmed);
  request->url =
      GURL(FillSearchUrlTemplate(engine->suggest_url_template, trimmed));
  request->engine = std::move(*engine);
  request->site = std::move(site);
  request->callback = std::move(callback);
  request->shared_factory = std::move(factory);
  remote_requests_[id] = std::move(request);
  // Debounce: the next keystroke cancels this request while it waits, so no
  // request goes out.
  base::SequencedTaskRunner::GetCurrentDefault()->PostDelayedTask(
      FROM_HERE,
      base::BindOnce(&SuggestEngine::OnRemoteDebounced,
                     weak_factory_.GetWeakPtr(), id),
      kRemoteDebounce);
  return id;
}

void SuggestEngine::OnRemoteDebounced(uint64_t request_id) {
  auto it = remote_requests_.find(request_id);
  if (it == remote_requests_.end()) {
    return;  // Cancelled while it waited.
  }
  scoped_refptr<network::SharedURLLoaderFactory> factory =
      std::move(it->second->shared_factory);
  StartRemoteRequest(request_id, factory.get());
}

void SuggestEngine::StartRemoteRequest(
    uint64_t request_id,
    network::mojom::URLLoaderFactory* factory) {
  auto it = remote_requests_.find(request_id);
  if (it == remote_requests_.end()) {
    return;
  }
  RemoteRequest& request = *it->second;
  if (!factory || !request.url.is_valid() ||
      !request.url.SchemeIsHTTPOrHTTPS()) {
    OnRemoteResponse(request_id, std::nullopt);
    return;
  }
  auto resource_request = std::make_unique<network::ResourceRequest>();
  resource_request->url = request.url;
  resource_request->method = net::HttpRequestHeaders::kGetMethod;
  // Ephemeral: no cookies, no credentials, no HTTP cache.
  resource_request->credentials_mode = network::mojom::CredentialsMode::kOmit;
  resource_request->load_flags = net::LOAD_DISABLE_CACHE;
  resource_request->headers.SetHeader(net::HttpRequestHeaders::kAccept,
                                      "application/json");
  request.loader = network::SimpleURLLoader::Create(
      std::move(resource_request), kRemoteSuggestTrafficAnnotation);
  request.loader->SetTimeoutDuration(kRemoteTimeout);
  request.loader->DownloadToString(
      factory,
      base::BindOnce(&SuggestEngine::OnRemoteResponse,
                     weak_factory_.GetWeakPtr(), request_id),
      kRemoteMaxBodyBytes);
}

void SuggestEngine::OnRemoteResponse(uint64_t request_id,
                                     std::optional<std::string> body) {
  auto it = remote_requests_.find(request_id);
  if (it == remote_requests_.end()) {
    return;
  }
  std::unique_ptr<RemoteRequest> request = std::move(it->second);
  remote_requests_.erase(it);

  RemoteSuggestionResult result;
  result.query = request->query;
  result.engine_id = request->engine.id;
  result.request_id = request_id;
  if (!body) {
    // Timeout, offline or an HTTP error: not an empty answer. Nothing is
    // cached and the carry-over rows stay.
    result.failed = true;
    result.suggestions =
        CachedRemoteSuggestions(request->query, request->engine, request->site);
  } else {
    std::vector<RemoteSuggestItem> items =
        ParseSuggestResponse(*body, request->engine.suggest_format);
    result.suggestions =
        RemoteRows(items, request->query, request->engine, request->site);
    StoreRemote(request->engine.id, request->query, std::move(items));
  }
  if (request->callback) {
    std::move(request->callback).Run(std::move(result));
  }
}

void SuggestEngine::CancelRemoteSuggestions(uint64_t request_id) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  remote_requests_.erase(request_id);  // Deleting the loader cancels it.
}

void SuggestEngine::CancelAllRemoteSuggestions() {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  remote_requests_.clear();
}

// --- Extensions and documents
// ---------------------------------------------------

void SuggestEngine::SetExtensionActions(
    std::vector<ExtensionActionEntry> actions) {
  constexpr size_t kMaxEntries = 4096;
  if (actions.size() > kMaxEntries) {
    actions.resize(kMaxEntries);
  }
  extension_actions_ = std::move(actions);
}

void SuggestEngine::SetExtensionKeywords(
    std::vector<ExtensionKeywordEntry> keywords) {
  constexpr size_t kMaxEntries = 4096;
  if (keywords.size() > kMaxEntries) {
    keywords.resize(kMaxEntries);
  }
  extension_keywords_ = std::move(keywords);
  // Drop answers of extensions that lost their keyword.
  for (auto it = extension_omnibox_.begin(); it != extension_omnibox_.end();) {
    const bool kept =
        std::any_of(extension_keywords_.begin(), extension_keywords_.end(),
                    [&](const ExtensionKeywordEntry& k) {
                      return k.extension_id == it->first;
                    });
    it = kept ? std::next(it) : extension_omnibox_.erase(it);
  }
}

void SuggestEngine::SetExtensionOmniboxSuggestions(
    const std::string& extension_id,
    const std::string& text,
    std::vector<ExtensionOmniboxEntry> rows,
    std::string default_description) {
  // Bounds at the engine-free boundary (ExtensionProviderLimits): over-limit
  // rows are refused, never truncated into executable content.
  constexpr size_t kMaxText = 16384;
  std::vector<ExtensionOmniboxEntry> accepted;
  for (ExtensionOmniboxEntry& row : rows) {
    if (accepted.size() >= 4) {
      break;
    }
    if (row.content.size() <= kMaxText && row.description.size() <= kMaxText) {
      accepted.push_back(std::move(row));
    }
  }
  if (default_description.size() > kMaxText) {
    default_description.clear();
  }
  extension_omnibox_[extension_id] = {text, std::move(accepted),
                                      std::move(default_description)};
}

void SuggestEngine::SetDocuments(std::vector<DocumentEntry> documents) {
  std::sort(documents.begin(), documents.end(),
            [](const DocumentEntry& a, const DocumentEntry& b) {
              return a.modified_at > b.modified_at;
            });
  if (documents.size() > kMaxDocuments) {
    documents.resize(kMaxDocuments);
  }
  documents_ = std::move(documents);
  folded_document_titles_.clear();
  folded_document_titles_.reserve(documents_.size());
  for (const DocumentEntry& doc : documents_) {
    folded_document_titles_.push_back(
        FoldAsciiLower(std::string_view(doc.title).substr(
            0, std::min<size_t>(doc.title.size(), 512))));
  }
}

// static
const std::vector<SuggestEngine::NewDocumentAction>&
SuggestEngine::NewDocumentActions() {
  // Arc's new-document table (NewDocumentActions.swift, capture PB1-h):
  // exactly these eight; titles match on the title only.
  static const base::NoDestructor<std::vector<NewDocumentAction>> kActions({
      {"new-document-google-doc", "New Google Doc", "https://doc.new"},
      {"new-document-google-sheet", "New Google Sheet", "https://sheet.new"},
      {"new-document-google-slide", "New Google Slide", "https://slide.new"},
      {"new-document-google-meet", "New Google Meet", "https://meet.new"},
      {"new-document-figma-document", "New Figma Document",
       "https://figma.new"},
      {"new-document-figjam", "New FigJam", "https://figjam.new"},
      {"new-document-notion-page", "New Notion Page",
       "https://app.notion.com/new"},
      {"new-document-linear-issue", "New Linear Issue",
       "https://linear.app/new"},
  });
  return *kActions;
}

std::optional<std::string> SuggestEngine::ClassifyTypedUrl(
    std::string_view raw) {
  std::string s;
  base::TrimWhitespaceASCII(raw, base::TRIM_ALL, &s);
  if (s.empty()) {
    return std::nullopt;
  }
  std::string lower = FoldAsciiLower(s);
  if (base::StartsWith(lower, "javascript:", base::CompareCase::SENSITIVE)) {
    return std::nullopt;
  }

  auto normalize_windows_path = [](std::string_view path) {
    std::string out;
    out.reserve(path.size());
    for (char c : path) {
      if (c == '\\') {
        out.push_back('/');
      } else if (c == ' ') {
        out.append("%20");
      } else {
        out.push_back(c);
      }
    }
    return out;
  };

  // Windows absolute drive path (e.g. C:\Users\name\file.html or C:/path).
  if (s.size() >= 3 && std::isalpha(static_cast<unsigned char>(s[0])) &&
      s[1] == ':' && (s[2] == '\\' || s[2] == '/')) {
    return "file:///" + normalize_windows_path(s);
  }

  // Windows UNC path (e.g. \\server\share\file.html).
  if (s.size() >= 3 && s[0] == '\\' && s[1] == '\\' && s[2] != '\\' &&
      s[2] != '/' && !std::isspace(static_cast<unsigned char>(s[2]))) {
    return "file:" + normalize_windows_path(s);
  }

  // Explicit schemes.
  static const std::set<std::string_view> kKnownSchemes = {
      "http",        "https",  "file",   "ftp",
      "about",       "open",   "chrome", "chrome-extension",
      "view-source", "mailto",
  };
  if (size_t colon = lower.find(':'); colon != std::string::npos && colon > 0) {
    std::string_view scheme = std::string_view(lower).substr(0, colon);
    bool valid_scheme =
        std::isalpha(static_cast<unsigned char>(scheme[0])) != 0;
    for (char c : scheme) {
      if (!std::isalnum(static_cast<unsigned char>(c)) && c != '+' &&
          c != '-' && c != '.') {
        valid_scheme = false;
        break;
      }
    }
    if (valid_scheme) {
      std::string_view after = std::string_view(s).substr(colon + 1);
      if (kKnownSchemes.count(scheme) > 0 ||
          base::StartsWith(after, "//", base::CompareCase::SENSITIVE)) {
        if ((scheme == "http" || scheme == "https")) {
          std::string_view rest = after;
          while (base::StartsWith(rest, "/", base::CompareCase::SENSITIVE)) {
            rest.remove_prefix(1);
          }
          size_t end = rest.find_first_of("/?#");
          std::string_view host =
              end == std::string_view::npos ? rest : rest.substr(0, end);
          if (host.empty() || host.find(' ') != std::string_view::npos) {
            return std::nullopt;
          }
        }
        return s;
      }
    }
  }

  // File path.
  if (s.front() == '/' && (s.size() == 1 || s[1] != '/')) {
    return "file://" + s;
  }

  size_t end = s.find_first_of("/?#");
  std::string_view authority = end == std::string_view::npos
                                   ? std::string_view(s)
                                   : std::string_view(s).substr(0, end);
  std::string_view rest = end == std::string_view::npos
                              ? std::string_view()
                              : std::string_view(s).substr(end);
  if (authority.empty() || authority.find(' ') != std::string_view::npos ||
      authority.find('@') != std::string_view::npos) {
    return std::nullopt;
  }

  // Split host & optional port.
  std::string_view host_part = authority;
  bool has_port = false;
  if (authority.front() == '[') {
    size_t close = authority.find(']');
    if (close == std::string_view::npos) {
      return std::nullopt;
    }
    host_part = authority.substr(0, close + 1);
    if (close + 1 < authority.size()) {
      if (authority[close + 1] != ':') {
        return std::nullopt;
      }
      has_port = true;
    }
  } else if (size_t colon = authority.rfind(':');
             colon != std::string_view::npos) {
    std::string_view port_str = authority.substr(colon + 1);
    if (port_str.empty() || port_str.size() > 5 ||
        !std::all_of(port_str.begin(), port_str.end(),
                     [](unsigned char c) { return std::isdigit(c) != 0; })) {
      return std::nullopt;
    }
    int port = std::stoi(std::string(port_str));
    if (port < 0 || port > 65535) {
      return std::nullopt;
    }
    host_part = authority.substr(0, colon);
    has_port = true;
  }

  std::string host = FoldAsciiLower(host_part);
  if (host.empty()) {
    return std::nullopt;
  }

  if (host == "localhost" ||
      base::EndsWith(host, ".localhost", base::CompareCase::SENSITIVE) ||
      IsIPv4(host) || (host.front() == '[' && host.back() == ']')) {
    return "http://" + s;
  }

  // Host with dot & known TLD or explicit port or trailing slash.
  size_t dot = host.rfind('.');
  if (dot == std::string::npos) {
    if (has_port || (!rest.empty() && rest.front() == '/')) {
      return "http://" + s;
    }
    return std::nullopt;
  }
  std::string_view tld = std::string_view(host).substr(dot + 1);
  if (tld.empty()) {
    return std::nullopt;
  }
  if (tld == "local" || tld == "test" || tld == "internal") {
    return "http://" + s;
  }
  if (IsCommonPublicSuffix(tld)) {
    return "https://" + s;
  }
  if (has_port) {
    return "http://" + s;
  }
  return std::nullopt;
}

std::optional<double> SuggestEngine::EvaluateCalculator(std::string_view expr) {
  std::string trimmed;
  base::TrimWhitespaceASCII(expr, base::TRIM_ALL, &trimmed);
  if (trimmed.size() < 3 || trimmed.size() > 128) {
    return std::nullopt;
  }
  CalcParser parser(trimmed);
  return parser.Parse();
}

std::optional<InlineCompletion> SuggestEngine::ComputeInlineCompletion(
    std::string_view raw_typed,
    std::string_view url,
    const std::string& row_id) {
  if (raw_typed.empty()) {
    return std::nullopt;
  }
  for (unsigned char c : raw_typed) {
    if (std::isspace(c)) {
      return std::nullopt;
    }
  }
  std::string lower_url = FoldAsciiLower(url);
  if (!base::StartsWith(lower_url, "http://", base::CompareCase::SENSITIVE) &&
      !base::StartsWith(lower_url, "https://", base::CompareCase::SENSITIVE)) {
    return std::nullopt;
  }

  std::string_view rest = raw_typed;
  std::string lead;
  if (base::StartsWith(rest, "https://",
                       base::CompareCase::INSENSITIVE_ASCII)) {
    lead.append(rest.substr(0, 8));
    rest.remove_prefix(8);
  } else if (base::StartsWith(rest, "http://",
                              base::CompareCase::INSENSITIVE_ASCII)) {
    lead.append(rest.substr(0, 7));
    rest.remove_prefix(7);
  }
  if (base::StartsWith(rest, "www.", base::CompareCase::INSENSITIVE_ASCII)) {
    lead.append(rest.substr(0, 4));
    rest.remove_prefix(4);
  }
  if (rest.empty()) {
    return std::nullopt;
  }

  std::string candidate;
  if (rest.find_first_of("/?#") != std::string_view::npos) {
    candidate = MatchableUrl(url);
    if (!candidate.empty() && candidate.back() == '/' &&
        candidate.find('/') == candidate.size() - 1) {
      candidate.pop_back();
    }
  } else {
    candidate = DisplayHost(url);
  }

  if (candidate.size() <= rest.size() ||
      lead.size() + candidate.size() > kMaxInlineFieldLen) {
    return std::nullopt;
  }
  std::string folded_body = FoldAsciiLower(rest);
  std::string folded_cand_prefix =
      FoldAsciiLower(std::string_view(candidate).substr(0, rest.size()));
  if (folded_body != folded_cand_prefix) {
    return std::nullopt;
  }
  return InlineCompletion{row_id, lead + candidate, lead.size() + rest.size()};
}

std::vector<SiteSearchEntry> SuggestEngine::EffectiveSiteSearches(
    const std::optional<ProfileID>& profile_id) const {
  std::vector<SiteSearchEntry> sites = BuiltInSiteSearches();
  if (model_ && profile_id.has_value()) {
    if (const Profile* profile = model_->FindProfile(*profile_id)) {
      for (const CustomSearchEngine& ce :
           profile->settings.custom_search_engines) {
        SiteSearchEntry entry;
        entry.id = "custom-" + ce.id;
        entry.name = ce.name;
        entry.host = DisplayHost(ce.url_template);
        if (!ce.keyword.empty()) {
          entry.keywords.push_back(ce.keyword);
        }
        entry.url_template = ce.url_template;
        sites.push_back(std::move(entry));
      }
    }
  }
  return sites;
}

SiteSearchEntry SuggestEngine::ResolveDefaultSearchEngine(
    const SuggestContext& context,
    const std::optional<ProfileID>& profile_id) const {
  std::string engine_id = "google";
  if (context.search_engine_id.has_value() &&
      !context.search_engine_id->empty()) {
    engine_id = *context.search_engine_id;
  } else if (model_ && profile_id.has_value()) {
    if (const Profile* p = model_->FindProfile(*profile_id)) {
      if (!p->settings.search_engine_id.empty()) {
        engine_id = p->settings.search_engine_id;
      }
    }
  }
  auto sites = EffectiveSiteSearches(profile_id);
  for (const SiteSearchEntry& s : sites) {
    if (s.id == "engine-" + engine_id || s.id == "custom-" + engine_id ||
        s.id == engine_id) {
      return s;
    }
  }
  return {"engine-google",
          "Google",
          "google.com",
          {"google", "g"},
          "https://www.google.com/search?q=%s"};
}

std::optional<SiteSearchEntry> SuggestEngine::TriggerSiteSearch(
    const std::string& text,
    const std::optional<ProfileID>& profile_id) const {
  std::string trimmed;
  base::TrimWhitespaceASCII(text, base::TRIM_ALL, &trimmed);
  std::string folded = FoldAsciiLower(trimmed);
  if (folded.size() < 2 || folded.find(' ') != std::string::npos) {
    return std::nullopt;
  }
  auto sites = EffectiveSiteSearches(profile_id);
  // Exact match on name (without spaces), host, or keyword first.
  for (const SiteSearchEntry& site : sites) {
    std::string compact_name;
    for (char c : FoldAsciiLower(site.name)) {
      if (c != ' ') {
        compact_name.push_back(c);
      }
    }
    if (compact_name == folded || FoldAsciiLower(site.host) == folded) {
      return site;
    }
    for (const std::string& kw : site.keywords) {
      if (FoldAsciiLower(kw) == folded) {
        return site;
      }
    }
  }
  // An extension's omnibox keyword (exact only), unless a site owns the word
  // (ExtensionActionsProvider.conflicts). Its id is "extension:<id>".
  for (const ExtensionKeywordEntry& keyword : extension_keywords_) {
    if (FoldAsciiLower(keyword.keyword) == folded) {
      SiteSearchEntry entry;
      entry.id = ExtensionScopeId(keyword.extension_id);
      entry.name = keyword.name;
      entry.keywords.push_back(keyword.keyword);
      return entry;
    }
  }
  // Shortest prefix match on name or host.
  std::optional<SiteSearchEntry> best;
  size_t best_len = 0;
  for (const SiteSearchEntry& site : sites) {
    std::string compact_name;
    for (char c : FoldAsciiLower(site.name)) {
      if (c != ' ') {
        compact_name.push_back(c);
      }
    }
    std::string folded_host = FoldAsciiLower(site.host);
    for (const std::string& candidate : {compact_name, folded_host}) {
      if (candidate.size() > folded.size() &&
          base::StartsWith(candidate, folded, base::CompareCase::SENSITIVE)) {
        if (!best.has_value() || candidate.size() < best_len) {
          best = site;
          best_len = candidate.size();
        }
      }
    }
  }
  return best;
}

SuggestionResult SuggestEngine::Query(const std::string& raw_query,
                                      const SuggestContext& context,
                                      TimestampSec now) const {
  const base::TimeTicks t0 = base::TimeTicks::Now();
  if (now <= 0.0) {
    now = base::Time::Now().InSecondsFSinceUnixEpoch();
  }

  SuggestionResult result;
  result.query = raw_query;

  std::string trimmed;
  base::TrimWhitespaceASCII(raw_query, base::TRIM_ALL, &trimmed);
  std::string folded = FoldAsciiLower(trimmed);
  std::vector<std::string> tokens = SplitWords(folded);
  uint64_t query_mask = ComputeByteMask(folded);

  // Resolve effective scope & profile.
  SuggestScope scope = context.scope;
  if (scope.kind == SuggestScopeKind::kAll) {
    if (context.mode == SuggestMode::kSearchTabs) {
      scope = SuggestScope::Tabs();
    } else if (context.mode == SuggestMode::kSearchActions) {
      scope = SuggestScope::Actions();
    }
  }

  // "extension:<id>" Site Search ids are extension keyword scopes.
  if (scope.kind == SuggestScopeKind::kSiteSearch) {
    if (std::optional<std::string> extension_id =
            ExtensionIdFromScopeId(scope.site_search_id)) {
      scope = SuggestScope::Extension(std::move(*extension_id));
    }
  }

  std::optional<ProfileID> profile_id = EffectiveProfile(context);

  // Extension omnibox scope: the typed row plus the extension's own answer
  // (ExtensionOmniboxProvider). Nothing else is searched.
  if (scope.kind == SuggestScopeKind::kExtension) {
    const std::string& extension_id = scope.site_search_id;
    std::string name;
    for (const ExtensionKeywordEntry& keyword : extension_keywords_) {
      if (keyword.extension_id == extension_id) {
        name = keyword.name;
        break;
      }
    }
    if (!raw_query.empty()) {
      const auto answer_it = extension_omnibox_.find(extension_id);
      const OmniboxAnswer* answer = answer_it != extension_omnibox_.end() &&
                                            answer_it->second.text == raw_query
                                        ? &answer_it->second
                                        : nullptr;
      Suggestion first;
      first.id = "extension-suggestion:" + extension_id + ":0:" + raw_query;
      first.kind = SuggestionKind::kSiteSearch;
      first.role = SuggestionRole::kExtensionSuggestion;
      std::string title = answer ? answer->default_description : std::string();
      if (title.empty()) {
        title = raw_query;
      } else {
        base::ReplaceSubstringsAfterOffset(&title, 0, "%s", raw_query);
      }
      first.title = std::move(title);
      first.subtitle = name;
      first.extension_id = extension_id;
      first.extension_content = raw_query;
      first.site_search_id = ExtensionScopeId(extension_id);
      first.match_quality = kQualityExact;
      first.score = kQualityExact;
      first.is_what_you_typed = true;
      first.can_be_top_hit = true;
      result.suggestions.push_back(std::move(first));
      if (answer) {
        for (size_t i = 0; i < answer->rows.size(); ++i) {
          const ExtensionOmniboxEntry& entry = answer->rows[i];
          Suggestion row;
          row.id = "extension-suggestion:" + extension_id + ":" +
                   base::NumberToString(i + 1) + ":" + entry.content;
          row.kind = SuggestionKind::kSiteSearch;
          row.role = SuggestionRole::kExtensionSuggestion;
          row.title =
              entry.description.empty() ? entry.content : entry.description;
          row.subtitle =
              entry.content == row.title ? std::string() : entry.content;
          row.extension_id = extension_id;
          row.extension_content = entry.content;
          row.site_search_id = ExtensionScopeId(extension_id);
          row.is_deletable = entry.deletable;
          row.match_quality = kQualityExact;
          row.score = kQualityExact - 1.0 - static_cast<double>(i);
          result.suggestions.push_back(std::move(row));
        }
      }
    }
    result.has_top_hit = !result.suggestions.empty();
    result.top_hit_rule =
        result.has_top_hit ? TopHitRule::kSiteSearchScope : TopHitRule::kNone;
    result.elapsed_ms = (base::TimeTicks::Now() - t0).InMillisecondsF();
    return result;
  }

  auto sites = EffectiveSiteSearches(profile_id);
  std::optional<SiteSearchEntry> active_site_search;
  if (scope.kind == SuggestScopeKind::kSiteSearch) {
    for (const SiteSearchEntry& s : sites) {
      if (s.id == scope.site_search_id) {
        active_site_search = s;
        break;
      }
    }
  }

  SiteSearchEntry default_engine =
      ResolveDefaultSearchEngine(context, profile_id);
  auto typed_url = ClassifyTypedUrl(trimmed);
  result.is_url_input = typed_url.has_value();
  result.typed_url = typed_url;

  std::vector<Suggestion> candidates;
  candidates.reserve(64);

  // 1. What-you-typed & Site Search scope row.
  if (scope.kind == SuggestScopeKind::kSiteSearch &&
      active_site_search.has_value()) {
    if (!trimmed.empty()) {
      Suggestion s;
      s.id = "site-search|" + active_site_search->id + "|" + trimmed;
      s.kind = SuggestionKind::kSiteSearch;
      s.title = trimmed;
      s.subtitle = "Search " + active_site_search->name;
      s.url = FillSearchUrlTemplate(active_site_search->url_template, trimmed);
      s.site_search_id = active_site_search->id;
      s.match_quality = kQualityExact;
      s.score = kQualityExact * KindWeight(s.kind);
      s.is_what_you_typed = true;
      s.can_be_top_hit = true;
      candidates.push_back(std::move(s));
    }
  } else if (scope.kind == SuggestScopeKind::kAll && !trimmed.empty()) {
    if (typed_url.has_value()) {
      Suggestion s;
      s.id = "typed-url|" + *typed_url;
      s.kind = SuggestionKind::kNavigate;
      s.title = trimmed;
      s.subtitle = *typed_url;
      s.url = *typed_url;
      s.match_quality = kQualityExact;
      s.score = kQualityExact * KindWeight(s.kind);
      s.is_what_you_typed = true;
      s.can_be_top_hit = true;
      candidates.push_back(std::move(s));
    } else {
      Suggestion s;
      s.id = "typed-search|" + trimmed;
      s.kind = SuggestionKind::kSearch;
      s.title = trimmed;
      s.subtitle = "Search " + default_engine.name;
      s.url = FillSearchUrlTemplate(default_engine.url_template, trimmed);
      s.match_quality = kQualityExact;
      s.score = kQualityExact * KindWeight(s.kind);
      s.is_what_you_typed = true;
      s.can_be_top_hit = true;
      candidates.push_back(std::move(s));
    }

    // Space-triggered Site Search ("yt cats").
    if (size_t sp = trimmed.find(' '); sp != std::string::npos) {
      std::string head = FoldAsciiLower(trimmed.substr(0, sp));
      std::string rest;
      base::TrimWhitespaceASCII(trimmed.substr(sp + 1), base::TRIM_ALL, &rest);
      if (head.size() >= 2 && !rest.empty()) {
        for (const SiteSearchEntry& site : sites) {
          std::string compact_name;
          for (char c : FoldAsciiLower(site.name)) {
            if (c != ' ') {
              compact_name.push_back(c);
            }
          }
          bool match =
              (compact_name == head || FoldAsciiLower(site.host) == head);
          if (!match) {
            for (const std::string& kw : site.keywords) {
              if (FoldAsciiLower(kw) == head) {
                match = true;
                break;
              }
            }
          }
          if (match) {
            Suggestion s;
            s.id = "site-space|" + site.id + "|" + rest;
            s.kind = SuggestionKind::kSiteSearch;
            s.title = rest;
            s.subtitle = "Search " + site.name;
            s.url = FillSearchUrlTemplate(site.url_template, rest);
            s.site_search_id = site.id;
            s.match_quality = kQualityPrefix;
            s.score = kQualityPrefix * KindWeight(s.kind) + 10.0;
            s.can_be_top_hit = true;
            candidates.push_back(std::move(s));
            break;
          }
        }
      }
    } else if (auto trigger = TriggerSiteSearch(trimmed, profile_id)) {
      // Tab-trigger hint row ("Press Tab to search YouTube").
      Suggestion hint;
      hint.id = "site-hint|" + trigger->id;
      hint.kind = SuggestionKind::kSiteSearchHint;
      // The site's own name: the bar draws "Search <name>" and puts the
      // name in the scope chip ("Wikipedia", commandbar.md CC-41).
      hint.title = trigger->name;
      hint.subtitle = "Press Tab to search " + trigger->name;
      hint.site_search_id = trigger->id;
      hint.match_quality = kQualityPrefix;
      hint.score = kQualityPrefix * KindWeight(hint.kind);
      if (const std::optional<std::string> extension_id =
              ExtensionIdFromScopeId(trigger->id)) {
        // An extension keyword (exact by construction) beats a prefix site.
        hint.role = SuggestionRole::kExtensionKeyword;
        hint.extension_id = *extension_id;
        hint.subtitle = "Press Tab to use " + trigger->name;
        hint.match_quality = kQualityExact;
        hint.score = kQualityExact * KindWeight(hint.kind);
      }
      candidates.push_back(std::move(hint));
    }

    // Instant calculator row.
    if (auto calc = EvaluateCalculator(trimmed)) {
      Suggestion c;
      c.id = "calc|" + trimmed;
      c.kind = SuggestionKind::kCalculator;
      c.title = "= " + FormatCalcValue(*calc);
      c.subtitle = trimmed;
      c.match_quality = kQualityExact;
      c.score = kQualityExact * KindWeight(c.kind) + 5.0;
      c.can_be_top_hit = true;
      candidates.push_back(std::move(c));
    }
  }

  // 2. Open / Pinned / Favorite tabs from BrowserModel.
  if (model_ && scope.kind != SuggestScopeKind::kActions) {
    auto consider_tab = [&](const Tab& tab, TabLocation loc,
                            const std::optional<SpaceID>& sid,
                            const std::optional<std::string>& stitle) {
      if (context.mode == SuggestMode::kEditCurrentUrl &&
          context.current_tab_id == tab.id) {
        return;
      }
      std::string host = DisplayHost(tab.url);
      std::string matchable = MatchableUrl(tab.url);
      if (active_site_search.has_value() &&
          !SiteContainsHost(*active_site_search, host, matchable)) {
        return;
      }

      std::string display = tab.display_title();
      std::string f_title = FoldAsciiLower(display);
      std::string f_host = FoldAsciiLower(host);
      std::string f_url = FoldAsciiLower(matchable);

      double quality = 0.0;
      bool exact_tab = false;
      if (folded.empty()) {
        quality = 50.0;
      } else {
        uint64_t row_mask = ComputeByteMask(f_title) | ComputeByteMask(f_host) |
                            ComputeByteMask(f_url);
        if ((row_mask & query_mask) != query_mask) {
          return;
        }
        quality = MultiFieldQuality(folded, tokens, {f_title},
                                    {{f_host, 1.0}, {f_url, 0.9}});
        if (quality <= 0.0) {
          return;
        }
        exact_tab = (f_title == folded || f_host == folded);
      }

      double frecency = TabRecency(tab.last_active_at, now);
      double boost = LocationBoost(loc);
      if (sid.has_value() && context.space_id == *sid) {
        boost += kCurrentSpaceBoost;
      }

      Suggestion s;
      s.id = "tab|" + tab.id;
      s.kind = SuggestionKind::kSwitchToTab;
      s.title = display;
      s.subtitle = host.empty() ? tab.url : host;
      s.url = tab.url;
      s.tab_id = tab.id;
      s.tab_location = loc;
      s.favicon_page_url = tab.url;
      s.space_id = sid;
      s.space_title = stitle;
      s.match_quality = quality;
      s.frecency = frecency;
      s.score = quality * KindWeight(s.kind) + frecency + boost;
      s.can_be_top_hit = (quality >= kQualityPrefix);
      s.is_exact_tab_match = exact_tab;
      candidates.push_back(std::move(s));
    };

    // Favorites for matching profile(s).
    for (const Profile& profile : model_->profiles()) {
      if (profile_id.has_value() && profile.id != *profile_id) {
        continue;
      }
      for (const Tab& fav : profile.favorites) {
        consider_tab(fav, TabLocation::kFavorite, std::nullopt, std::nullopt);
      }
    }

    // Spaces' Pinned & Today trees.
    std::function<void(const SidebarNode&, TabLocation, const SpaceID&,
                       const std::string&)>
        walk_nodes = [&](const SidebarNode& node, TabLocation loc,
                         const SpaceID& sid, const std::string& stitle) {
          if (const Tab* t = node.as_tab()) {
            consider_tab(*t, loc, sid, stitle);
          } else if (const Folder* f = node.as_folder()) {
            for (const SidebarNode& child : f->children) {
              walk_nodes(child, loc, sid, stitle);
            }
          } else if (const Split* sp = node.as_split()) {
            for (const Tab& pane : sp->panes) {
              consider_tab(pane, TabLocation::kSplitPane, sid, stitle);
            }
          }
        };

    for (const Space& space : model_->spaces()) {
      if (profile_id.has_value() && space.profile_id != *profile_id) {
        continue;
      }
      std::string stitle = model_->DisplayTitleForSpace(space.id);
      for (const SidebarNode& n : space.pinned) {
        walk_nodes(n, TabLocation::kPinned, space.id, stitle);
      }
      for (const SidebarNode& n : space.today) {
        walk_nodes(n, TabLocation::kToday, space.id, stitle);
      }
    }
  }

  // 3. FTS5 History results (or cached recent history when history_store_ is
  // null because SQLite runs on a blocking sequence).
  if ((history_store_ || !recent_history_.empty()) &&
      scope.kind != SuggestScopeKind::kTabs &&
      scope.kind != SuggestScopeKind::kActions && !folded.empty()) {
    auto build_history_suggestion =
        [&](const HistoryEntry& entry,
            bool require_match) -> std::optional<Suggestion> {
      std::string host = DisplayHost(entry.url);
      std::string matchable = MatchableUrl(entry.url);
      if (active_site_search.has_value() &&
          !SiteContainsHost(*active_site_search, host, matchable)) {
        return std::nullopt;
      }
      std::string f_title = FoldAsciiLower(entry.title);
      std::string f_host = FoldAsciiLower(host);
      std::string f_url = FoldAsciiLower(matchable);
      if (require_match) {
        uint64_t row_mask = ComputeByteMask(f_title) | ComputeByteMask(f_host) |
                            ComputeByteMask(f_url);
        if ((row_mask & query_mask) != query_mask) {
          return std::nullopt;
        }
      }
      double quality = MultiFieldQuality(folded, tokens, {f_title},
                                         {{f_host, 1.0}, {f_url, 0.9}});
      if (quality <= 0.0) {
        if (require_match) {
          return std::nullopt;
        }
        quality = kQualitySubstring;
      }
      double frecency = HistoryFrecency(entry.visit_count, entry.typed_count,
                                        entry.last_visit, now);
      Suggestion s;
      s.id = "hist|" + entry.url;
      s.kind = SuggestionKind::kHistory;
      s.title = entry.title.empty() ? host : entry.title;
      s.subtitle = matchable;
      s.url = entry.url;
      s.favicon_page_url = entry.url;
      s.match_quality = quality;
      s.frecency = frecency;
      s.score = quality * KindWeight(s.kind) + frecency;
      s.can_be_top_hit = (quality >= kQualityPrefix && frecency >= 5.0);
      return s;
    };

    if (history_store_) {
      auto history_rows = history_store_->Search(trimmed, 24);
      for (const HistoryEntry& entry : history_rows) {
        if (auto s = build_history_suggestion(entry, /*require_match=*/false)) {
          candidates.push_back(std::move(*s));
        }
      }
    } else {
      std::vector<Suggestion> matched_history;
      for (const HistoryEntry& entry : recent_history_) {
        if (auto s = build_history_suggestion(entry, /*require_match=*/true)) {
          matched_history.push_back(std::move(*s));
        }
      }
      constexpr size_t kMaxHistoryCandidates = 24;
      if (matched_history.size() > kMaxHistoryCandidates) {
        std::partial_sort(matched_history.begin(),
                          matched_history.begin() + kMaxHistoryCandidates,
                          matched_history.end(), SuggestionOrder);
        matched_history.resize(kMaxHistoryCandidates);
      }
      for (Suggestion& s : matched_history) {
        candidates.push_back(std::move(s));
      }
    }
  }

  // 4. Open Commands / Actions.
  if (command_registry_ && (scope.kind == SuggestScopeKind::kAll ||
                            scope.kind == SuggestScopeKind::kActions)) {
    for (const CommandDefinition& cmd : command_registry_->all_commands()) {
      if (cmd.is_reserved) {
        continue;
      }
      if (context.is_command_available &&
          !context.is_command_available.Run(cmd)) {
        continue;  // Commands that cannot run now never show.
      }
      if (folded.empty() && scope.kind != SuggestScopeKind::kActions) {
        continue;
      }
      double quality = 0.0;
      if (folded.empty()) {
        quality = 50.0;
      } else {
        std::vector<std::string> titles;
        titles.reserve(1 + cmd.aliases.size());
        std::string f_title = FoldAsciiLower(cmd.title);
        uint64_t mask = ComputeByteMask(f_title);
        titles.push_back(f_title);
        for (const std::string& alias : cmd.aliases) {
          std::string fa = FoldAsciiLower(alias);
          mask |= ComputeByteMask(fa);
          titles.push_back(std::move(fa));
        }
        if ((mask & query_mask) != query_mask) {
          continue;
        }
        quality = MultiFieldQuality(folded, tokens, titles, {});
        if (quality < kQualityInitials && folded.size() >= 2 &&
            tokens.size() == 1) {
          std::string init = ComputeInitials(f_title);
          if (init == folded) {
            quality = kQualityInitials;
          }
        }
        if (quality <= 0.0) {
          continue;
        }
      }
      Suggestion s;
      s.id = "action|" + cmd.id;
      s.kind = SuggestionKind::kAction;
      s.title = cmd.title;
      s.subtitle = cmd.menu_path.empty()
                       ? "Open Action"
                       : base::JoinString(cmd.menu_path, " > ");
      s.action_id = cmd.id;
      s.command_id = cmd.command_id;
      auto shortcuts = command_registry_->EffectiveShortcuts(cmd.id);
      if (!shortcuts.empty()) {
        s.shortcut_display = shortcuts.front().DisplayString();
      }
      s.match_quality = quality;
      s.score = quality * KindWeight(s.kind);
      s.can_be_top_hit = (quality >= kQualityPrefix && folded.size() >= 3);
      if (IsQuickCreateCommand(cmd.id)) {
        s.role = SuggestionRole::kQuickCreate;
      }
      candidates.push_back(std::move(s));
    }
  }

  // 4b. Arc's new-document actions ("New Google Doc"): title-only matching;
  // they open the service's own "new" address.
  if ((scope.kind == SuggestScopeKind::kAll && !folded.empty()) ||
      scope.kind == SuggestScopeKind::kActions) {
    for (const NewDocumentAction& action : NewDocumentActions()) {
      double quality = 50.0;
      if (!folded.empty()) {
        const std::string f_title = FoldAsciiLower(action.title);
        if ((ComputeByteMask(f_title) & query_mask) != query_mask) {
          continue;
        }
        quality = MultiFieldQuality(folded, tokens, {f_title}, {});
        if (quality <= 0.0) {
          continue;
        }
      }
      Suggestion s;
      s.id = "action|" + action.id;
      s.kind = SuggestionKind::kNavigate;
      s.role = SuggestionRole::kNewDocument;
      s.title = action.title;
      s.subtitle = "New Document";
      s.url = action.url;
      s.action_id = action.id;
      s.match_quality = quality;
      s.score = quality * KindWeight(SuggestionKind::kAction);
      s.can_be_top_hit = (quality >= kQualityPrefix && folded.size() >= 3);
      candidates.push_back(std::move(s));
    }
  }

  // 4c. Extension toolbar actions (ExtensionActionsProvider).
  if (scope.kind == SuggestScopeKind::kAll && !folded.empty()) {
    for (const ExtensionActionEntry& action : extension_actions_) {
      if (action.name.empty() || action.name.size() > 16384) {
        continue;
      }
      const std::string f_name = FoldAsciiLower(action.name);
      if ((ComputeByteMask(f_name) & query_mask) != query_mask) {
        continue;
      }
      double quality = MultiFieldQuality(folded, tokens, {f_name}, {});
      if (quality < kQualityInitials && folded.size() >= 2 &&
          tokens.size() == 1 && ComputeInitials(f_name) == folded) {
        quality = kQualityInitials;
      }
      if (quality <= 0.0) {
        continue;
      }
      Suggestion s;
      s.id = "extension-action:" + action.extension_id;
      s.kind = SuggestionKind::kAction;
      s.role = SuggestionRole::kExtensionAction;
      s.title = action.name;
      s.subtitle = "Extension";
      s.action_id = "extension-action:" + action.extension_id;
      s.extension_id = action.extension_id;
      s.shortcut_display = action.shortcut_display;
      s.match_quality = quality;
      s.score = quality * KindWeight(SuggestionKind::kAction);
      s.can_be_top_hit = folded.size() >= 3 && quality >= kQualityPrefix;
      candidates.push_back(std::move(s));
    }
  }

  // 4d. Easels and Notes by title (EaselsProvider: Cmd+T only). Documents
  // already in the sidebar come as Switch to Tab rows (URL dedupe below).
  if (context.mode == SuggestMode::kNewTab &&
      scope.kind == SuggestScopeKind::kAll && folded.size() >= 2) {
    for (size_t i = 0; i < documents_.size(); ++i) {
      const DocumentEntry& doc = documents_[i];
      const std::string& f_title = folded_document_titles_[i];
      if (doc.url.empty() ||
          (ComputeByteMask(f_title) & query_mask) != query_mask) {
        continue;
      }
      const double quality = MultiFieldQuality(folded, tokens, {f_title}, {});
      if (quality <= 0.0) {
        continue;
      }
      Suggestion s;
      s.id = "document:" + doc.id;
      s.kind = SuggestionKind::kNavigate;
      s.role = SuggestionRole::kDocument;
      s.title = doc.title.empty() ? (doc.kind == DocumentEntry::Kind::kEasel
                                         ? "Untitled Easel"
                                         : "Untitled Note")
                                  : doc.title;
      s.subtitle = doc.kind == DocumentEntry::Kind::kEasel ? "Easel" : "Note";
      s.url = doc.url;
      s.favicon_page_url = doc.url;
      s.document_id = doc.id;
      s.match_quality = quality;
      // Newer documents first among equal matches (documents_ is sorted).
      s.score = quality * KindWeight(SuggestionKind::kNavigate) -
                static_cast<double>(i) * 1e-6;
      candidates.push_back(std::move(s));
    }
  }

  // 4e. Search-engine suggestions already known for this text (exact cache
  // or carry-over); FetchRemoteSuggestions() delivers newer ones later.
  if (std::optional<SearchEngineEntry> remote_engine =
          RemoteSuggestEngineFor(raw_query, context)) {
    result.remote_engine_id = remote_engine->id;
    for (Suggestion& s :
         CachedRemoteSuggestions(trimmed, *remote_engine, active_site_search)) {
      candidates.push_back(std::move(s));
    }
  }

  // 5. Deduplicate by normalized URL (merging history frecency into open tabs).
  std::unordered_map<std::string, size_t> url_group;
  std::vector<Suggestion> deduped;
  deduped.reserve(candidates.size());
  for (Suggestion& cand : candidates) {
    if (!cand.url.has_value()) {
      deduped.push_back(std::move(cand));
      continue;
    }
    std::string key = UrlDedupeKey(*cand.url);
    auto it = url_group.find(key);
    if (it == url_group.end()) {
      url_group[key] = deduped.size();
      deduped.push_back(std::move(cand));
    } else {
      Suggestion& existing = deduped[it->second];
      bool cand_wins = MergePrecedence(cand) > MergePrecedence(existing) ||
                       (MergePrecedence(cand) == MergePrecedence(existing) &&
                        SuggestionOrder(cand, existing));
      Suggestion& winner = cand_wins ? cand : existing;
      Suggestion& loser = cand_wins ? existing : cand;

      if (loser.is_what_you_typed) {
        winner.is_what_you_typed = true;
      }
      winner.can_be_top_hit = winner.can_be_top_hit || loser.can_be_top_hit;
      if (winner.kind == SuggestionKind::kSwitchToTab &&
          loser.kind == SuggestionKind::kHistory) {
        winner.score += kAbsorbedFrecencyShare * loser.frecency;
      }
      if (winner.kind == SuggestionKind::kNavigate &&
          winner.is_what_you_typed && loser.kind == SuggestionKind::kHistory &&
          winner.subtitle == *winner.url) {
        winner.subtitle = loser.title;
      }
      if (cand_wins) {
        existing = std::move(cand);
      }
    }
  }

  std::sort(deduped.begin(), deduped.end(), SuggestionOrder);

  // 6. Choose Top Hit according to OpenSuggest rules T0..T8.
  std::optional<size_t> top_index;
  TopHitRule rule = TopHitRule::kNone;
  std::optional<InlineCompletion> inline_comp;

  auto find_first = [&](auto pred) -> std::optional<size_t> {
    for (size_t i = 0; i < deduped.size(); ++i) {
      if (pred(deduped[i])) {
        return i;
      }
    }
    return std::nullopt;
  };

  if (scope.kind == SuggestScopeKind::kSiteSearch) {
    top_index = find_first([](const Suggestion& s) {
      return s.kind == SuggestionKind::kSiteSearch && s.is_what_you_typed;
    });
    rule = top_index.has_value() ? TopHitRule::kSiteSearchScope
                                 : TopHitRule::kNone;
  } else if (scope.kind == SuggestScopeKind::kTabs) {
    if (!folded.empty()) {
      top_index = find_first([](const Suggestion& s) {
        return s.kind == SuggestionKind::kSwitchToTab;
      });
      rule = top_index.has_value() ? TopHitRule::kBestTab : TopHitRule::kNone;
    }
  } else if (scope.kind == SuggestScopeKind::kActions) {
    if (!folded.empty()) {
      top_index = find_first([](const Suggestion& s) {
        return s.kind == SuggestionKind::kAction;
      });
      rule =
          top_index.has_value() ? TopHitRule::kBestAction : TopHitRule::kNone;
    }
  } else if (!folded.empty()) {
    // T3a: inline completion if allowed and no calculator/exact-tab.
    bool allow_inline = context.allows_inline_completion &&
                        !raw_query.empty() &&
                        raw_query.find(' ') == std::string::npos;
    bool has_calc_or_exact_tab =
        find_first([](const Suggestion& s) {
          return s.kind == SuggestionKind::kCalculator ||
                 (s.kind == SuggestionKind::kSwitchToTab &&
                  s.is_exact_tab_match);
        }).has_value();
    if (allow_inline && !has_calc_or_exact_tab) {
      for (size_t i = 0; i < deduped.size(); ++i) {
        const Suggestion& r = deduped[i];
        if ((r.kind == SuggestionKind::kSwitchToTab ||
             r.kind == SuggestionKind::kHistory) &&
            (r.can_be_top_hit ||
             (r.kind == SuggestionKind::kSwitchToTab && folded.size() >= 2)) &&
            r.url.has_value()) {
          if (auto comp = ComputeInlineCompletion(raw_query, *r.url, r.id)) {
            top_index = i;
            rule = TopHitRule::kInlineCompletion;
            inline_comp = std::move(comp);
            break;
          }
        }
      }
    }
    if (!top_index.has_value() && typed_url.has_value()) {
      top_index =
          find_first([](const Suggestion& s) { return s.is_what_you_typed; });
      rule = TopHitRule::kTypedUrl;
    }
    if (!top_index.has_value()) {
      top_index = find_first([](const Suggestion& s) {
        return s.kind == SuggestionKind::kCalculator;
      });
      if (top_index.has_value()) {
        rule = TopHitRule::kCalculator;
      }
    }
    if (!top_index.has_value()) {
      top_index = find_first([](const Suggestion& s) {
        return s.kind == SuggestionKind::kSwitchToTab && s.is_exact_tab_match;
      });
      if (top_index.has_value()) {
        rule = TopHitRule::kExactTab;
      }
    }
    if (!top_index.has_value() && folded.size() >= 3) {
      top_index = find_first([](const Suggestion& s) {
        return s.kind == SuggestionKind::kAction &&
               s.match_quality == kQualityExact;
      });
      if (top_index.has_value()) {
        rule = TopHitRule::kExactAction;
      }
    }
    if (!top_index.has_value()) {
      top_index =
          find_first([](const Suggestion& s) { return s.can_be_top_hit; });
      if (top_index.has_value()) {
        rule = TopHitRule::kBestEligible;
      }
    }
    if (!top_index.has_value()) {
      top_index =
          find_first([](const Suggestion& s) { return s.is_what_you_typed; });
      if (top_index.has_value()) {
        rule = TopHitRule::kTypedSearch;
      }
    }

    if (top_index.has_value() && !inline_comp.has_value() && allow_inline &&
        (rule == TopHitRule::kExactTab || rule == TopHitRule::kBestEligible)) {
      const Suggestion& top = deduped[*top_index];
      if ((top.kind == SuggestionKind::kSwitchToTab ||
           top.kind == SuggestionKind::kHistory) &&
          top.url.has_value()) {
        inline_comp = ComputeInlineCompletion(raw_query, *top.url, top.id);
      }
    }
  }

  // 7. Apply per-kind caps and max_results limit.
  int limit = std::max(1, context.max_results);
  std::vector<Suggestion> final_rows;
  final_rows.reserve(static_cast<size_t>(limit));
  std::unordered_map<int, int> kind_counts;

  if (top_index.has_value()) {
    Suggestion top = std::move(deduped[*top_index]);
    deduped.erase(deduped.begin() + static_cast<std::ptrdiff_t>(*top_index));
    kind_counts[RowCapKey(top)] = 1;
    final_rows.push_back(std::move(top));
  }
  for (Suggestion& row : deduped) {
    if (static_cast<int>(final_rows.size()) >= limit) {
      break;
    }
    int& count = kind_counts[RowCapKey(row)];
    if (count >= RowCap(row, scope.kind)) {
      continue;
    }
    ++count;
    final_rows.push_back(std::move(row));
  }

  result.suggestions = std::move(final_rows);
  result.has_top_hit = top_index.has_value();
  result.top_hit_rule = result.has_top_hit ? rule : TopHitRule::kNone;
  result.inline_completion = std::move(inline_comp);
  result.elapsed_ms = (base::TimeTicks::Now() - t0).InMillisecondsF();
  return result;
}

}  // namespace open_unified
