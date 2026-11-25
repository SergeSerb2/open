// Copyright 2026 The Open Authors. All rights reserved.

#include "open_unified/core/suggest/suggest_engine.h"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstring>
#include <functional>
#include <iomanip>
#include <set>
#include <sstream>
#include <unordered_map>
#include <utility>

#include "base/strings/string_util.h"
#include "base/time/time.h"

namespace open_unified {

namespace {

// Match quality levels matching Packages/OpenKit/Sources/OpenSuggest/TextMatching.swift.
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
    while (i < folded.size() && folded[i] == ' ') ++i;
    size_t start = i;
    while (i < folded.size() && folded[i] != ' ') ++i;
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

double MultiFieldQuality(const std::string& folded_query,
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
  std::string path =
      slash != std::string_view::npos ? std::string(before_q.substr(slash)) : "";

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
  if (base_count <= 0.0) return 0.0;
  double age_days = std::max(0.0, now - last_visit) / 86400.0;
  return std::min(30.0, 8.0 * std::log1p(base_count / (1.0 + 0.15 * age_days)));
}

double TabRecency(TimestampSec last_active, TimestampSec now) {
  double age_hours = std::max(0.0, now - last_active) / 3600.0;
  return std::max(0.0, 6.0 - std::log1p(age_hours));
}

int MergePrecedence(const Suggestion& s) {
  if (s.kind == SuggestionKind::kSwitchToTab) return 5;
  if (s.is_what_you_typed) return 4;
  if (s.kind == SuggestionKind::kHistory) return 3;
  if (s.kind == SuggestionKind::kNavigate ||
      s.kind == SuggestionKind::kSiteSearch) {
    return 2;
  }
  return 1;
}

bool SuggestionOrder(const Suggestion& a, const Suggestion& b) {
  if (a.score != b.score) return a.score > b.score;
  int pa = KindPriority(a.kind);
  int pb = KindPriority(b.kind);
  if (pa != pb) return pa > pb;
  if (a.title != b.title) return a.title < b.title;
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

// Recursive descent parser for simple arithmetic expressions (+, -, *, /, ^, ()).
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
  void SkipWs() {
    while (pos_ < s_.size() &&
           std::isspace(static_cast<unsigned char>(s_[pos_]))) {
      ++pos_;
    }
  }

  std::optional<double> ParseExpr() {
    auto lhs = ParseTerm();
    if (!lhs.has_value()) return std::nullopt;
    while (true) {
      SkipWs();
      if (pos_ >= s_.size()) break;
      char op = s_[pos_];
      if (op != '+' && op != '-') break;
      ++pos_;
      saw_operator_ = true;
      auto rhs = ParseTerm();
      if (!rhs.has_value()) return std::nullopt;
      *lhs = (op == '+') ? (*lhs + *rhs) : (*lhs - *rhs);
    }
    return lhs;
  }

  std::optional<double> ParseTerm() {
    auto lhs = ParsePower();
    if (!lhs.has_value()) return std::nullopt;
    while (true) {
      SkipWs();
      if (pos_ >= s_.size()) break;
      char op = s_[pos_];
      if (op != '*' && op != '/') break;
      ++pos_;
      saw_operator_ = true;
      auto rhs = ParsePower();
      if (!rhs.has_value()) return std::nullopt;
      if (op == '/') {
        if (*rhs == 0.0) return std::nullopt;
        *lhs /= *rhs;
      } else {
        *lhs *= *rhs;
      }
    }
    return lhs;
  }

  std::optional<double> ParsePower() {
    auto base = ParseUnary();
    if (!base.has_value()) return std::nullopt;
    SkipWs();
    if (pos_ < s_.size() && s_[pos_] == '^') {
      ++pos_;
      saw_operator_ = true;
      auto exp = ParsePower();
      if (!exp.has_value()) return std::nullopt;
      return std::pow(*base, *exp);
    }
    return base;
  }

  std::optional<double> ParseUnary() {
    SkipWs();
    if (pos_ < s_.size() && (s_[pos_] == '+' || s_[pos_] == '-')) {
      char op = s_[pos_++];
      auto val = ParseUnary();
      if (!val.has_value()) return std::nullopt;
      return op == '-' ? -(*val) : *val;
    }
    return ParsePrimary();
  }

  std::optional<double> ParsePrimary() {
    SkipWs();
    if (pos_ >= s_.size()) return std::nullopt;
    if (s_[pos_] == '(') {
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
    if (!saw_digit) return std::nullopt;
    try {
      return std::stod(std::string(s_.substr(start, pos_ - start)));
    } catch (...) {
      return std::nullopt;
    }
  }

  std::string_view s_;
  size_t pos_ = 0;
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
      "com", "org", "net", "io",  "dev", "app", "ai",  "co",  "gov", "edu",
      "me",  "tv",  "gg",  "xyz", "uk",  "ca",  "de",  "fr",  "jp",  "au",
      "nl",  "se",  "ch",  "it",  "es",  "br",  "in",  "kr",  "cn",  "ru",
      "info", "biz", "so", "us",  "eu",  "sh",  "to",  "fm",  "ly",  "page",
      "cloud", "tech", "design", "news", "blog", "store", "shop", "live",
      "local", "localhost", "test", "internal",
  };
  return kTlds.count(tld) > 0;
}

bool IsIPv4(std::string_view host) {
  int parts = 0;
  size_t pos = 0;
  while (pos <= host.size()) {
    size_t dot = host.find('.', pos);
    std::string_view part =
        dot == std::string_view::npos ? host.substr(pos)
                                      : host.substr(pos, dot - pos);
    if (part.empty() || part.size() > 3) return false;
    if (part.size() > 1 && part[0] == '0') return false;
    int val = 0;
    for (char c : part) {
      if (!std::isdigit(static_cast<unsigned char>(c))) return false;
      val = val * 10 + (c - '0');
    }
    if (val > 255) return false;
    ++parts;
    if (dot == std::string_view::npos) break;
    pos = dot + 1;
  }
  return parts == 4;
}

bool SiteContainsHost(const SiteSearchEntry& site,
                      std::string_view page_host,
                      std::string_view matchable_url) {
  if (site.host.empty()) return true;
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

SuggestEngine::SuggestEngine(const BrowserModel* model,
                             HistoryStore* history_store,
                             const CommandRegistry* command_registry)
    : model_(model),
      history_store_(history_store),
      command_registry_(command_registry) {}

SuggestEngine::~SuggestEngine() = default;

void SuggestEngine::SetRecentHistory(std::vector<HistoryEntry> entries) {
  recent_history_ = std::move(entries);
}

const std::vector<SiteSearchEntry>& SuggestEngine::BuiltInSiteSearches() {
  static const std::vector<SiteSearchEntry> kBuiltIn = {
      {"youtube", "YouTube", "youtube.com", {"yt"},
       "https://www.youtube.com/results?search_query=%s"},
      {"github", "GitHub", "github.com", {"gh"},
       "https://github.com/search?q=%s&type=repositories"},
      {"wikipedia", "Wikipedia", "wikipedia.org", {"wiki"},
       "https://en.wikipedia.org/w/index.php?search=%s"},
      {"amazon", "Amazon", "amazon.com", {"amz"},
       "https://www.amazon.com/s?k=%s"},
      {"reddit", "Reddit", "reddit.com", {},
       "https://www.reddit.com/search/?q=%s"},
      {"x", "X", "x.com", {"twitter"}, "https://x.com/search?q=%s"},
      {"google-maps", "Google Maps", "google.com/maps", {"maps", "gmaps"},
       "https://www.google.com/maps/search/%s"},
      {"google-images", "Google Images", "google.com", {"images"},
       "https://www.google.com/search?tbm=isch&q=%s"},
      {"google-news", "Google News", "news.google.com", {},
       "https://news.google.com/search?q=%s"},
      {"google-drive", "Google Drive", "drive.google.com", {"drive", "gdrive"},
       "https://drive.google.com/drive/search?q=%s"},
      {"gmail", "Gmail", "mail.google.com", {},
       "https://mail.google.com/mail/u/0/#search/%s"},
      {"google-translate", "Google Translate", "translate.google.com",
       {"translate"}, "https://translate.google.com/?sl=auto&text=%s"},
      {"stackoverflow", "Stack Overflow", "stackoverflow.com", {},
       "https://stackoverflow.com/search?q=%s"},
      {"mdn", "MDN", "developer.mozilla.org", {},
       "https://developer.mozilla.org/en-US/search?q=%s"},
      {"apple-developer", "Apple Developer", "developer.apple.com", {},
       "https://developer.apple.com/search/?q=%s"},
      {"npm", "npm", "npmjs.com", {}, "https://www.npmjs.com/search?q=%s"},
      {"hacker-news", "Hacker News", "news.ycombinator.com", {"hn"},
       "https://hn.algolia.com/?q=%s"},
      {"imdb", "IMDb", "imdb.com", {}, "https://www.imdb.com/find/?q=%s"},
      {"spotify", "Spotify", "open.spotify.com", {},
       "https://open.spotify.com/search/%s"},
      {"linkedin", "LinkedIn", "linkedin.com", {},
       "https://www.linkedin.com/search/results/all/?keywords=%s"},
      {"pinterest", "Pinterest", "pinterest.com", {},
       "https://www.pinterest.com/search/pins/?q=%s"},
      {"twitch", "Twitch", "twitch.tv", {},
       "https://www.twitch.tv/search?term=%s"},
      {"ebay", "eBay", "ebay.com", {},
       "https://www.ebay.com/sch/i.html?_nkw=%s"},
      // Built-in search engines as site search targets
      {"engine-google", "Google", "google.com", {"google", "g"},
       "https://www.google.com/search?q=%s"},
      {"engine-duckduckgo", "DuckDuckGo", "duckduckgo.com",
       {"duckduckgo", "ddg"}, "https://duckduckgo.com/?q=%s"},
      {"engine-bing", "Bing", "bing.com", {"bing"},
       "https://www.bing.com/search?q=%s"},
      {"engine-brave", "Brave Search", "search.brave.com", {"brave"},
       "https://search.brave.com/search?q=%s"},
      {"engine-ecosia", "Ecosia", "ecosia.org", {"ecosia"},
       "https://www.ecosia.org/search?q=%s"},
      {"engine-kagi", "Kagi", "kagi.com", {"kagi"},
       "https://kagi.com/search?q=%s"},
      {"engine-perplexity", "Perplexity", "perplexity.ai",
       {"perplexity", "pplx"}, "https://www.perplexity.ai/search/new?q=%s"},
      {"engine-yahoo", "Yahoo", "search.yahoo.com", {"yahoo"},
       "https://search.yahoo.com/search?p=%s"},
  };
  return kBuiltIn;
}

std::string SuggestEngine::FillSearchUrlTemplate(std::string_view url_template,
                                                 std::string_view query) {
  std::string encoded = PercentEncodeQuery(query);
  std::string out(url_template);
  size_t pos = out.find("%s");
  if (pos != std::string::npos) {
    out.replace(pos, 2, encoded);
  }
  return out;
}

std::optional<std::string> SuggestEngine::ClassifyTypedUrl(
    std::string_view raw) {
  std::string s;
  base::TrimWhitespaceASCII(raw, base::TRIM_ALL, &s);
  if (s.empty()) return std::nullopt;
  std::string lower = FoldAsciiLower(s);
  if (base::StartsWith(lower, "javascript:", base::CompareCase::SENSITIVE)) {
    return std::nullopt;
  }

  // Explicit schemes.
  static const std::set<std::string_view> kKnownSchemes = {
      "http", "https", "file", "ftp", "about", "open", "chrome",
      "chrome-extension", "view-source", "mailto",
  };
  if (size_t colon = lower.find(':'); colon != std::string::npos && colon > 0) {
    std::string_view scheme = std::string_view(lower).substr(0, colon);
    bool valid_scheme = std::isalpha(static_cast<unsigned char>(scheme[0])) != 0;
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
  std::string_view authority =
      end == std::string_view::npos ? std::string_view(s)
                                    : std::string_view(s).substr(0, end);
  std::string_view rest =
      end == std::string_view::npos ? std::string_view()
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
    if (close == std::string_view::npos) return std::nullopt;
    host_part = authority.substr(0, close + 1);
    if (close + 1 < authority.size()) {
      if (authority[close + 1] != ':') return std::nullopt;
      has_port = true;
    }
  } else if (size_t colon = authority.rfind(':');
             colon != std::string_view::npos) {
    std::string_view port_str = authority.substr(colon + 1);
    if (port_str.empty() || port_str.size() > 5 ||
        !std::all_of(port_str.begin(), port_str.end(), [](unsigned char c) {
          return std::isdigit(c) != 0;
        })) {
      return std::nullopt;
    }
    int port = std::stoi(std::string(port_str));
    if (port < 0 || port > 65535) return std::nullopt;
    host_part = authority.substr(0, colon);
    has_port = true;
  }

  std::string host = FoldAsciiLower(host_part);
  if (host.empty()) return std::nullopt;

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
  if (tld.empty()) return std::nullopt;
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
  if (raw_typed.empty()) return std::nullopt;
  for (unsigned char c : raw_typed) {
    if (std::isspace(c)) return std::nullopt;
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
  if (rest.empty()) return std::nullopt;

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
  return {"engine-google", "Google", "google.com", {"google", "g"},
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
      if (c != ' ') compact_name.push_back(c);
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
  // Shortest prefix match on name or host.
  std::optional<SiteSearchEntry> best;
  size_t best_len = 0;
  for (const SiteSearchEntry& site : sites) {
    std::string compact_name;
    for (char c : FoldAsciiLower(site.name)) {
      if (c != ' ') compact_name.push_back(c);
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

  std::optional<ProfileID> profile_id = context.profile_id;
  if (!profile_id.has_value() && model_ && context.space_id.has_value()) {
    if (const Space* sp = model_->FindSpace(*context.space_id)) {
      profile_id = sp->profile_id;
    }
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
            if (c != ' ') compact_name.push_back(c);
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
      hint.title = "Search " + trigger->name;
      hint.subtitle = "Press Tab to search " + trigger->name;
      hint.site_search_id = trigger->id;
      hint.match_quality = kQualityPrefix;
      hint.score = kQualityPrefix * KindWeight(hint.kind);
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
      if (profile_id.has_value() && profile.id != *profile_id) continue;
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
      if (profile_id.has_value() && space.profile_id != *profile_id) continue;
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
    auto build_history_suggestion = [&](const HistoryEntry& entry,
                                        bool require_match)
        -> std::optional<Suggestion> {
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
  if (command_registry_ &&
      (scope.kind == SuggestScopeKind::kAll ||
       scope.kind == SuggestScopeKind::kActions)) {
    for (const CommandDefinition& cmd : command_registry_->all_commands()) {
      if (cmd.is_reserved) continue;
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

      if (loser.is_what_you_typed) winner.is_what_you_typed = true;
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
      if (pred(deduped[i])) return i;
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
    bool has_calc_or_exact_tab = find_first([](const Suggestion& s) {
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
      top_index = find_first(
          [](const Suggestion& s) { return s.is_what_you_typed; });
      rule = TopHitRule::kTypedUrl;
    }
    if (!top_index.has_value()) {
      top_index = find_first([](const Suggestion& s) {
        return s.kind == SuggestionKind::kCalculator;
      });
      if (top_index.has_value()) rule = TopHitRule::kCalculator;
    }
    if (!top_index.has_value()) {
      top_index = find_first([](const Suggestion& s) {
        return s.kind == SuggestionKind::kSwitchToTab && s.is_exact_tab_match;
      });
      if (top_index.has_value()) rule = TopHitRule::kExactTab;
    }
    if (!top_index.has_value() && folded.size() >= 3) {
      top_index = find_first([](const Suggestion& s) {
        return s.kind == SuggestionKind::kAction &&
               s.match_quality == kQualityExact;
      });
      if (top_index.has_value()) rule = TopHitRule::kExactAction;
    }
    if (!top_index.has_value()) {
      top_index = find_first(
          [](const Suggestion& s) { return s.can_be_top_hit; });
      if (top_index.has_value()) rule = TopHitRule::kBestEligible;
    }
    if (!top_index.has_value()) {
      top_index = find_first(
          [](const Suggestion& s) { return s.is_what_you_typed; });
      if (top_index.has_value()) rule = TopHitRule::kTypedSearch;
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
  std::unordered_map<SuggestionKind, int> kind_counts;

  if (top_index.has_value()) {
    Suggestion top = std::move(deduped[*top_index]);
    deduped.erase(deduped.begin() + static_cast<std::ptrdiff_t>(*top_index));
    kind_counts[top.kind] = 1;
    final_rows.push_back(std::move(top));
  }
  for (Suggestion& row : deduped) {
    if (static_cast<int>(final_rows.size()) >= limit) break;
    int& count = kind_counts[row.kind];
    if (count >= KindCap(row.kind, scope.kind)) continue;
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
