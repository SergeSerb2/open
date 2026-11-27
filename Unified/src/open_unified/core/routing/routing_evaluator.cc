// Copyright 2026 The Open Authors. All rights reserved.

#include "open_unified/core/routing/routing_evaluator.h"

#include <algorithm>
#include <cstdint>
#include <limits>
#include <utility>

#include "base/strings/string_util.h"

namespace open_unified {

namespace {

std::string NormalizeAppId(const std::optional<std::string>& raw) {
  if (!raw.has_value()) {
    return {};
  }
  std::string trimmed;
  base::TrimWhitespaceASCII(*raw, base::TRIM_ALL, &trimmed);
  return base::ToLowerASCII(trimmed);
}

void AppendUtf8CodePoint(uint32_t cp, std::string* out) {
  if (cp <= 0x7Fu) {
    out->push_back(static_cast<char>(cp));
  } else if (cp <= 0x7FFu) {
    out->push_back(static_cast<char>(0xC0u | (cp >> 6)));
    out->push_back(static_cast<char>(0x80u | (cp & 0x3Fu)));
  } else if (cp <= 0xFFFFu) {
    out->push_back(static_cast<char>(0xE0u | (cp >> 12)));
    out->push_back(static_cast<char>(0x80u | ((cp >> 6) & 0x3Fu)));
    out->push_back(static_cast<char>(0x80u | (cp & 0x3Fu)));
  } else if (cp <= 0x10FFFFu) {
    out->push_back(static_cast<char>(0xF0u | (cp >> 18)));
    out->push_back(static_cast<char>(0x80u | ((cp >> 12) & 0x3Fu)));
    out->push_back(static_cast<char>(0x80u | ((cp >> 6) & 0x3Fu)));
    out->push_back(static_cast<char>(0x80u | (cp & 0x3Fu)));
  }
}

std::optional<uint32_t> PunycodeDigit(uint8_t b) {
  if (b >= 'a' && b <= 'z') return static_cast<uint32_t>(b - 'a');
  if (b >= 'A' && b <= 'Z') return static_cast<uint32_t>(b - 'A');
  if (b >= '0' && b <= '9') return static_cast<uint32_t>(b - '0') + 26u;
  return std::nullopt;
}

uint32_t PunycodeAdapt(uint32_t delta, uint32_t count, bool first) {
  delta = first ? (delta / 700u) : (delta / 2u);
  delta += delta / count;
  uint32_t k = 0;
  while (delta > 455u) {
    delta /= 35u;
    k += 36u;
  }
  return k + (36u * delta) / (delta + 38u);
}

// Simple glob wildcard matcher supporting '*'.
bool WildcardMatch(std::string_view text, std::string_view pattern) {
  size_t ti = 0;
  size_t pi = 0;
  size_t star_p = std::string_view::npos;
  size_t star_t = 0;
  while (ti < text.size()) {
    if (pi < pattern.size() && pattern[pi] == text[ti]) {
      ++ti;
      ++pi;
    } else if (pi < pattern.size() && pattern[pi] == '*') {
      star_p = pi++;
      star_t = ti;
    } else if (star_p != std::string_view::npos) {
      pi = star_p + 1;
      ti = ++star_t;
    } else {
      return false;
    }
  }
  while (pi < pattern.size() && pattern[pi] == '*') {
    ++pi;
  }
  return pi == pattern.size();
}

std::optional<SpaceID> FindMostRecentSpace(
    const BrowserModel& model,
    const std::optional<ProfileID>& profile_filter) {
  if (profile_filter.has_value()) {
    if (!model.FindProfile(*profile_filter)) {
      return std::nullopt;
    }
    return model.MostRecentlyFocusedSpace(*profile_filter);
  }
  for (const BrowserWindowState& w : model.windows()) {
    if (w.style == WindowStyle::kStandard &&
        model.FindSpace(w.focused_space_id)) {
      return w.focused_space_id;
    }
  }
  if (!model.spaces().empty()) {
    return model.spaces().front().id;
  }
  return std::nullopt;
}

std::optional<ResolvedRoutingTarget> ResolveSpaceTarget(
    const BrowserModel& model,
    const SpaceID& space_id) {
  const Space* space = model.FindSpace(space_id);
  if (!space) {
    return std::nullopt;
  }
  return ResolvedRoutingTarget{RoutingDestinationKind::kSpace, space->id,
                               space->profile_id};
}

}  // namespace

std::optional<std::string> DecodePunycodeLabel(std::string_view payload) {
  if (payload.empty()) {
    return std::nullopt;
  }
  for (unsigned char c : payload) {
    if (c >= 128) return std::nullopt;
  }
  std::vector<uint32_t> output;
  size_t cursor = 0;
  size_t delim = payload.rfind('-');
  if (delim != std::string_view::npos) {
    if (delim == 0) return std::nullopt;
    for (size_t i = 0; i < delim; ++i) {
      output.push_back(static_cast<uint8_t>(payload[i]));
    }
    cursor = delim + 1;
  }

  uint32_t n = 128;
  uint32_t i = 0;
  uint32_t bias = 72;
  while (cursor < payload.size()) {
    uint32_t old_i = i;
    uint32_t weight = 1;
    uint32_t k = 36;
    while (true) {
      if (cursor >= payload.size()) return std::nullopt;
      auto digit = PunycodeDigit(static_cast<uint8_t>(payload[cursor++]));
      if (!digit.has_value()) return std::nullopt;
      if (*digit > (std::numeric_limits<uint32_t>::max() - i) / weight) {
        return std::nullopt;
      }
      i += (*digit) * weight;
      uint32_t threshold = (k <= bias) ? 1u : std::min<uint32_t>(26u, k - bias);
      if (*digit < threshold) {
        break;
      }
      uint32_t factor = 36u - threshold;
      if (weight > std::numeric_limits<uint32_t>::max() / factor ||
          k > std::numeric_limits<uint32_t>::max() - 36u) {
        return std::nullopt;
      }
      weight *= factor;
      k += 36u;
    }
    uint32_t count = static_cast<uint32_t>(output.size() + 1);
    bias = PunycodeAdapt(i - old_i, count, old_i == 0);
    if (i / count > 0x10FFFFu - n) {
      return std::nullopt;
    }
    n += i / count;
    if (n >= 0xD800u && n <= 0xDFFFu) {
      return std::nullopt;
    }
    i %= count;
    output.insert(output.begin() + static_cast<std::ptrdiff_t>(i), n);
    ++i;
  }

  std::string utf8;
  for (uint32_t cp : output) {
    AppendUtf8CodePoint(cp, &utf8);
  }
  return utf8;
}

std::string CanonicalHostName(std::string_view raw) {
  std::string trimmed;
  base::TrimWhitespaceASCII(raw, base::TRIM_ALL, &trimmed);
  std::string host = base::ToLowerASCII(trimmed);
  if (host.size() >= 2 && host.front() == '[' && host.back() == ']') {
    host = host.substr(1, host.size() - 2);
  }
  while (!host.empty() && host.back() == '.') {
    host.pop_back();
  }
  if (host.find("xn--") == std::string::npos) {
    return host;
  }
  std::string decoded;
  size_t pos = 0;
  while (pos <= host.size()) {
    size_t dot = host.find('.', pos);
    std::string_view label =
        dot == std::string::npos ? std::string_view(host).substr(pos)
                                 : std::string_view(host).substr(pos, dot - pos);
    if (!decoded.empty()) {
      decoded.push_back('.');
    }
    if (base::StartsWith(label, "xn--", base::CompareCase::SENSITIVE)) {
      auto puny = DecodePunycodeLabel(label.substr(4));
      if (puny.has_value()) {
        decoded += base::ToLowerASCII(*puny);
      } else {
        decoded.append(label);
      }
    } else {
      decoded.append(label);
    }
    if (dot == std::string::npos) break;
    pos = dot + 1;
  }
  return decoded;
}

std::optional<std::string> CanonicalHostFromUrl(std::string_view url) {
  std::string trimmed;
  base::TrimWhitespaceASCII(url, base::TRIM_ALL, &trimmed);
  if (trimmed.empty()) {
    return std::nullopt;
  }
  std::string_view rest = trimmed;
  size_t scheme_sep = rest.find("://");
  if (scheme_sep != std::string_view::npos) {
    rest = rest.substr(scheme_sep + 3);
  }
  size_t end = rest.find_first_of("/?#");
  std::string_view authority =
      end == std::string_view::npos ? rest : rest.substr(0, end);
  size_t at = authority.rfind('@');
  if (at != std::string_view::npos) {
    authority = authority.substr(at + 1);
  }
  if (authority.empty()) {
    return std::nullopt;
  }
  std::string_view host_part = authority;
  if (authority.front() == '[') {
    size_t close = authority.find(']');
    if (close != std::string_view::npos) {
      host_part = authority.substr(0, close + 1);
    }
  } else {
    size_t first_colon = authority.find(':');
    size_t last_colon = authority.rfind(':');
    if (first_colon != std::string_view::npos && first_colon == last_colon) {
      host_part = authority.substr(0, last_colon);
    }
  }
  std::string host = CanonicalHostName(host_part);
  if (base::StartsWith(host, "www.", base::CompareCase::SENSITIVE)) {
    host.erase(0, 4);
  }
  if (base::StartsWith(host, "*.", base::CompareCase::SENSITIVE)) {
    host.erase(0, 2);
  }
  while (!host.empty() && host.front() == '.') host.erase(host.begin());
  while (!host.empty() && host.back() == '.') host.pop_back();
  if (host.empty()) {
    return std::nullopt;
  }
  return host;
}

std::string CanonicalPathFromUrl(std::string_view url) {
  std::string_view rest = url;
  size_t scheme_sep = rest.find("://");
  if (scheme_sep != std::string_view::npos) {
    rest = rest.substr(scheme_sep + 3);
  }
  size_t path_start = rest.find('/');
  if (path_start == std::string_view::npos) {
    return "/";
  }
  std::string_view path = rest.substr(path_start);
  size_t q = path.find_first_of("?#");
  if (q != std::string_view::npos) {
    path = path.substr(0, q);
  }
  return path.empty() ? "/" : std::string(path);
}

std::string CanonicalUrlString(std::string_view url) {
  std::string trimmed;
  base::TrimWhitespaceASCII(url, base::TRIM_ALL, &trimmed);
  size_t sep = trimmed.find("://");
  if (sep == std::string::npos) {
    return trimmed;
  }
  std::string scheme = base::ToLowerASCII(trimmed.substr(0, sep));
  std::string_view rest = std::string_view(trimmed).substr(sep + 3);
  size_t auth_end = rest.find_first_of("/?#");
  std::string_view authority =
      auth_end == std::string_view::npos ? rest : rest.substr(0, auth_end);
  std::string_view tail =
      auth_end == std::string_view::npos ? "" : rest.substr(auth_end);
  // Strip fragment for canonical dedupe comparison; keep path and query.
  size_t hash = tail.find('#');
  if (hash != std::string_view::npos) {
    tail = tail.substr(0, hash);
  }
  std::string norm_auth = base::ToLowerASCII(authority);
  // Strip default ports.
  if (scheme == "https" && base::EndsWith(norm_auth, ":443")) {
    norm_auth.resize(norm_auth.size() - 4);
  } else if (scheme == "http" && base::EndsWith(norm_auth, ":80")) {
    norm_auth.resize(norm_auth.size() - 3);
  }
  std::string result = scheme + "://" + norm_auth;
  if (tail.empty()) {
    result.push_back('/');
  } else {
    if (tail.front() != '/') {
      result.push_back('/');
    }
    result.append(tail);
  }
  return result;
}

// ---------------------------------------------------------------------------
// PeekPolicy

PeekClickContext::PeekClickContext() = default;
PeekClickContext::PeekClickContext(const PeekClickContext&) = default;
PeekClickContext::PeekClickContext(PeekClickContext&&) noexcept = default;
PeekClickContext& PeekClickContext::operator=(const PeekClickContext&) =
    default;
PeekClickContext& PeekClickContext::operator=(PeekClickContext&&) noexcept =
    default;
PeekClickContext::~PeekClickContext() = default;

namespace {

bool IsIpv4Literal(std::string_view host) {
  int dots = 0;
  for (char c : host) {
    if (c == '.') {
      ++dots;
    } else if (c < '0' || c > '9') {
      return false;
    }
  }
  return dots == 3;
}

bool IsTwoPartPublicSuffix(std::string_view sld, std::string_view tld) {
  static constexpr std::pair<std::string_view, std::string_view> kSuffixes[] = {
      {"co", "uk"},   {"org", "uk"},  {"ac", "uk"},   {"gov", "uk"},
      {"com", "au"},  {"net", "au"},  {"org", "au"},  {"co", "jp"},
      {"ne", "jp"},   {"or", "jp"},   {"co", "kr"},   {"com", "br"},
      {"com", "cn"},  {"co", "nz"},   {"co", "in"},   {"com", "sg"},
      {"com", "mx"},  {"com", "tw"},  {"com", "hk"},  {"co", "za"},
      {"co", "il"},   {"com", "tr"},  {"com", "ar"},  {"com", "pl"},
      {"com", "ua"},  {"co", "id"},   {"com", "my"},  {"co", "th"},
      {"com", "vn"},  {"com", "ph"},  {"com", "co"},  {"com", "pe"},
      {"edu", "au"},  {"gov", "au"},
  };
  for (const auto& [a, b] : kSuffixes) {
    if (sld == a && tld == b) {
      return true;
    }
  }
  return false;
}

std::string CanonicalQueryLower(std::string_view url) {
  size_t q = url.find('?');
  if (q == std::string_view::npos) {
    return {};
  }
  std::string_view rest = url.substr(q + 1);
  size_t hash = rest.find('#');
  if (hash != std::string_view::npos) {
    rest = rest.substr(0, hash);
  }
  return base::ToLowerASCII(rest);
}

std::string PercentDecode(std::string_view input) {
  std::string out;
  out.reserve(input.size());
  auto hex_val = [](char c) -> int {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
  };
  for (size_t i = 0; i < input.size(); ++i) {
    if (input[i] == '%' && i + 2 < input.size()) {
      int hi = hex_val(input[i + 1]);
      int lo = hex_val(input[i + 2]);
      if (hi >= 0 && lo >= 0) {
        out.push_back(static_cast<char>((hi << 4) | lo));
        i += 2;
        continue;
      }
    }
    out.push_back(input[i]);
  }
  return out;
}

}  // namespace

// static
bool PeekPolicy::IsAuthenticationFlow(std::string_view url) {
  auto host_opt = CanonicalHostFromUrl(url);
  if (!host_opt.has_value()) {
    return false;
  }
  const std::string& host = *host_opt;

  // Known SSO / Identity Provider hosts.
  static constexpr std::string_view kExactAuthHosts[] = {
      "accounts.google.com",      "login.microsoftonline.com",
      "login.live.com",           "appleid.apple.com",
      "idmsa.apple.com",          "login.salesforce.com",
      "signin.aws.amazon.com",    "accounts.spotify.com",
      "id.atlassian.com",         "auth.atlassian.com",
  };
  for (std::string_view h : kExactAuthHosts) {
    if (host == h) {
      return true;
    }
  }
  static constexpr std::string_view kAuthHostSuffixes[] = {
      "auth0.com",        "okta.com",          "oktapreview.com",
      "onelogin.com",     "duosecurity.com",   "pingidentity.com",
      "b2clogin.com",     "clerk.accounts.dev",
  };
  for (std::string_view suffix : kAuthHostSuffixes) {
    if (host == suffix ||
        base::EndsWith(host, std::string(".") + std::string(suffix),
                       base::CompareCase::SENSITIVE)) {
      return true;
    }
  }
  // Subdomain prefixes strongly indicative of SSO/OAuth endpoints.
  static constexpr std::string_view kAuthHostPrefixes[] = {
      "sso.", "oauth.", "auth.", "accounts.", "login.", "signin.",
  };
  for (std::string_view prefix : kAuthHostPrefixes) {
    if (base::StartsWith(host, prefix, base::CompareCase::SENSITIVE)) {
      return true;
    }
  }

  // OAuth / OIDC / SAML path patterns.
  const std::string path = base::ToLowerASCII(CanonicalPathFromUrl(url));
  if (host == "github.com" &&
      (path == "/login" || path.starts_with("/login/"))) {
    return true;
  }
  static constexpr std::string_view kAuthPaths[] = {
      "/oauth",       "/oauth2",         "/authorize",
      "/login/oauth", "/saml",           "/sso",
      "/oidc",        "/connect/authorize", "/v2/authorize",
      "/auth/realms/", "/signin",        "/sign-in",
  };
  for (std::string_view ap : kAuthPaths) {
    if (path == ap ||
        base::StartsWith(path, std::string(ap) + "/",
                         base::CompareCase::SENSITIVE) ||
        (ap.back() == '/' &&
         base::StartsWith(path, ap, base::CompareCase::SENSITIVE))) {
      return true;
    }
  }

  // Query parameters characteristic of OAuth2 / OIDC / SAML redirects.
  const std::string query = CanonicalQueryLower(url);
  if (!query.empty()) {
    const bool has_client_id =
        query.find("client_id=") != std::string::npos;
    const bool has_oauth_param =
        query.find("redirect_uri=") != std::string::npos ||
        query.find("response_type=") != std::string::npos;
    if ((has_client_id && has_oauth_param) ||
        query.find("samlrequest=") != std::string::npos) {
      return true;
    }
  }

  return false;
}

// static
std::optional<std::string> PeekPolicy::RegistrableDomain(std::string_view url) {
  auto host_opt = CanonicalHostFromUrl(url);
  if (!host_opt.has_value()) {
    return std::nullopt;
  }
  const std::string& host = *host_opt;
  if (host.find(':') != std::string::npos || IsIpv4Literal(host)) {
    return host;
  }
  std::vector<std::string_view> labels;
  size_t pos = 0;
  while (pos <= host.size()) {
    size_t dot = host.find('.', pos);
    if (dot == std::string::npos) {
      labels.push_back(std::string_view(host).substr(pos));
      break;
    }
    labels.push_back(std::string_view(host).substr(pos, dot - pos));
    pos = dot + 1;
  }
  if (labels.size() <= 2) {
    return host;
  }
  const size_t n = labels.size();
  if (IsTwoPartPublicSuffix(labels[n - 2], labels[n - 1]) && n >= 3) {
    return std::string(labels[n - 3]) + "." + std::string(labels[n - 2]) + "." +
           std::string(labels[n - 1]);
  }
  return std::string(labels[n - 2]) + "." + std::string(labels[n - 1]);
}

// static
PeekDecision PeekPolicy::Evaluate(const PeekClickContext& click) {
  if (click.shift_held && click.peek_shift_enabled) {
    return PeekDecision::kPeek;
  }
  if (click.is_authentication_flow || IsAuthenticationFlow(click.target_url)) {
    return PeekDecision::kNavigate;
  }
  if (click.source_is_pinned_or_favorite && click.peek_other_sites_enabled &&
      click.source_url.has_value()) {
    auto source_domain = RegistrableDomain(*click.source_url);
    auto target_domain = RegistrableDomain(click.target_url);
    if (source_domain.has_value() && target_domain.has_value() &&
        *source_domain != *target_domain) {
      return PeekDecision::kPeek;
    }
  }
  return PeekDecision::kNavigate;
}

// static
bool PeekPolicy::ShouldOpenInPeek(std::string_view target_url,
                                  const Tab* source_tab,
                                  bool source_is_pinned_or_favorite,
                                  bool shift_click,
                                  bool peek_other_sites_enabled,
                                  bool peek_shift_enabled) {
  PeekClickContext ctx;
  ctx.source_is_pinned_or_favorite = source_is_pinned_or_favorite;
  if (source_tab && !source_tab->url.empty()) {
    ctx.source_url = source_tab->url;
  }
  ctx.target_url = std::string(target_url);
  ctx.shift_held = shift_click;
  ctx.peek_other_sites_enabled = peek_other_sites_enabled;
  ctx.peek_shift_enabled = peek_shift_enabled;
  return Evaluate(ctx) == PeekDecision::kPeek;
}

// ---------------------------------------------------------------------------
// DeepLinkAction, Mailto, Google Meet, Deduper, DecisionLog

DeepLinkAction::DeepLinkAction() = default;
DeepLinkAction::DeepLinkAction(const DeepLinkAction&) = default;
DeepLinkAction::DeepLinkAction(DeepLinkAction&&) noexcept = default;
DeepLinkAction& DeepLinkAction::operator=(const DeepLinkAction&) = default;
DeepLinkAction& DeepLinkAction::operator=(DeepLinkAction&&) noexcept = default;
DeepLinkAction::~DeepLinkAction() = default;

DeepLinkAction ParseDeepLink(std::string_view url) {
  DeepLinkAction action;
  std::string trimmed;
  base::TrimWhitespaceASCII(url, base::TRIM_ALL, &trimmed);
  size_t colon = trimmed.find(':');
  if (colon == std::string::npos) {
    return action;
  }
  std::string scheme = base::ToLowerASCII(trimmed.substr(0, colon));
  if (scheme != "open" && scheme != "open-browser") {
    return action;
  }
  action.raw_url = trimmed;
  std::string_view rest = std::string_view(trimmed).substr(colon + 1);
  if (base::StartsWith(rest, "//", base::CompareCase::SENSITIVE)) {
    rest = rest.substr(2);
  }
  // Drop query and fragment when splitting route segments.
  size_t q = rest.find_first_of("?#");
  std::string_view route_part =
      q == std::string_view::npos ? rest : rest.substr(0, q);

  std::vector<std::string> parts;
  size_t pos = 0;
  while (pos <= route_part.size()) {
    size_t slash = route_part.find('/', pos);
    std::string_view seg =
        slash == std::string_view::npos
            ? route_part.substr(pos)
            : route_part.substr(pos, slash - pos);
    if (!seg.empty()) {
      parts.push_back(PercentDecode(seg));
    }
    if (slash == std::string_view::npos) {
      break;
    }
    pos = slash + 1;
  }
  if (parts.empty()) {
    action.kind = DeepLinkKind::kUnknown;
    return action;
  }
  action.route = base::ToLowerASCII(parts.front());
  if (parts.size() > 1) {
    std::string arg;
    for (size_t i = 1; i < parts.size(); ++i) {
      if (i > 1) arg.push_back('/');
      arg += parts[i];
    }
    action.argument = std::move(arg);
  }

  if (action.route == "quit") {
    action.kind = DeepLinkKind::kQuit;
  } else if (action.route == "restart") {
    action.kind = DeepLinkKind::kRestart;
  } else if (action.route == "space") {
    action.kind = DeepLinkKind::kSpace;
  } else if (action.route == "welcome") {
    action.kind = DeepLinkKind::kWelcome;
  } else if (action.route == "little-open" || action.route == "littleopen") {
    action.kind = DeepLinkKind::kLittleOpen;
  } else if (scheme == "open" &&
             (action.route == "settings" || action.route == "library" ||
              action.route == "onboarding" || action.route == "boosts" ||
              action.route == "note" || action.route == "easel")) {
    action.kind = DeepLinkKind::kWebUI;
  } else {
    action.kind = DeepLinkKind::kUnknown;
  }
  return action;
}

bool IsMailtoUrl(std::string_view url) {
  if (url.size() > 64 * 1024) {
    return false;
  }
  std::string trimmed;
  base::TrimWhitespaceASCII(url, base::TRIM_ALL, &trimmed);
  return base::StartsWith(trimmed, "mailto:",
                          base::CompareCase::INSENSITIVE_ASCII);
}

bool IsGoogleMeetUrl(std::string_view url) {
  size_t sep = url.find("://");
  if (sep == std::string_view::npos) {
    return false;
  }
  std::string scheme = base::ToLowerASCII(url.substr(0, sep));
  if (scheme != "http" && scheme != "https") {
    return false;
  }
  auto host = CanonicalHostFromUrl(url);
  return host.has_value() && *host == "meet.google.com";
}

bool HasGoogleMeetRule(const BrowserModel& model) {
  for (const RoutingRule& rule : model.routing_rules()) {
    if (RoutingEvaluator::MatchesHostPattern("meet.google.com",
                                             rule.host_pattern)) {
      return true;
    }
  }
  return false;
}

ExternalLinkDeduper::ExternalLinkDeduper() = default;
ExternalLinkDeduper::~ExternalLinkDeduper() = default;

bool ExternalLinkDeduper::IsDuplicateAndRecord(
    std::string_view url,
    const std::optional<std::string>& source_app_id,
    TimestampSec now) {
  // Prune stale entries older than kWindowSeconds.
  for (auto it = recent_.begin(); it != recent_.end();) {
    if ((now - it->second) >= kWindowSeconds || (now - it->second) < -1.0) {
      it = recent_.erase(it);
    } else {
      ++it;
    }
  }
  std::string source_key = NormalizeAppId(source_app_id);
  if (source_key.empty()) {
    source_key = "?";
  }
  std::string key = CanonicalUrlString(url) + "|" + source_key;
  if (recent_.contains(key)) {
    ++duplicates_dropped_;
    return true;
  }
  recent_[std::move(key)] = now;
  return false;
}

void ExternalLinkDeduper::Clear() {
  recent_.clear();
  duplicates_dropped_ = 0;
}

RoutingDecisionLog::RoutingDecisionLog() = default;
RoutingDecisionLog::~RoutingDecisionLog() = default;

void RoutingDecisionLog::Record(RoutingDecision decision) {
  entries_.push_back(std::move(decision));
  while (entries_.size() > kMaxEntries) {
    entries_.pop_front();
  }
}

std::optional<RoutingDecision> RoutingDecisionLog::latest() const {
  if (entries_.empty()) {
    return std::nullopt;
  }
  return entries_.back();
}

bool RoutingEvaluator::MatchesHostPattern(std::string_view host,
                                          std::string_view raw_pattern) {
  // IPv6 literals are excluded from host-rule matching.
  if (host.empty() || host.find(':') != std::string_view::npos) {
    return false;
  }
  std::string trimmed;
  base::TrimWhitespaceASCII(raw_pattern, base::TRIM_ALL, &trimmed);
  if (trimmed.empty()) {
    return false;
  }
  std::string pat = base::ToLowerASCII(trimmed);
  // Strip optional scheme from pattern.
  if (size_t sep = pat.find("://"); sep != std::string::npos) {
    pat = pat.substr(sep + 3);
  }
  if (size_t end = pat.find_first_of("/?#"); end != std::string::npos) {
    pat = pat.substr(0, end);
  }
  if (pat.empty()) {
    return false;
  }

  // Suffix wildcard forms: "*.example.com" or ".example.com"
  if (base::StartsWith(pat, "*.", base::CompareCase::SENSITIVE)) {
    std::string suffix = CanonicalHostName(pat.substr(2));
    if (suffix.empty()) return false;
    return host == suffix ||
           base::EndsWith(host, "." + suffix, base::CompareCase::SENSITIVE);
  }
  if (pat.front() == '.') {
    std::string suffix = CanonicalHostName(pat.substr(1));
    if (suffix.empty()) return false;
    return host == suffix ||
           base::EndsWith(host, "." + suffix, base::CompareCase::SENSITIVE);
  }

  // General wildcard pattern (e.g., "*github*", "docs.*.com")
  if (pat.find('*') != std::string::npos) {
    return WildcardMatch(host, pat);
  }

  // Exact or subdomain suffix match after canonicalizing (stripping www.).
  std::string norm = CanonicalHostName(pat);
  if (base::StartsWith(norm, "www.", base::CompareCase::SENSITIVE)) {
    norm.erase(0, 4);
  }
  if (norm.empty()) {
    return false;
  }
  return host == norm ||
         base::EndsWith(host, "." + norm, base::CompareCase::SENSITIVE);
}

bool RoutingEvaluator::MatchesPathPrefix(std::string_view url_path,
                                         std::string_view raw_prefix) {
  std::string trimmed;
  base::TrimWhitespaceASCII(raw_prefix, base::TRIM_ALL, &trimmed);
  if (trimmed.empty()) {
    return true;
  }
  if (trimmed.front() != '/') {
    trimmed.insert(trimmed.begin(), '/');
  }
  return base::StartsWith(url_path, trimmed, base::CompareCase::SENSITIVE);
}

RoutingDecision RoutingEvaluator::Evaluate(
    const RoutingRequest& request,
    const BrowserModel& model,
    bool external_links_in_little_open) const {
  RoutingDecision decision;
  decision.request = request;
  decision.normalized_host = CanonicalHostFromUrl(request.url);

  // Check scheme: only http/https route through Air Traffic Control.
  size_t colon = request.url.find("://");
  std::string scheme =
      colon != std::string::npos
          ? base::ToLowerASCII(request.url.substr(0, colon))
          : std::string();
  if (scheme != "http" && scheme != "https") {
    decision.via = RoutingVia::kRejectedNonHttp;
    return decision;
  }

  const std::string request_source = NormalizeAppId(request.source_app_id);
  const std::string url_path = CanonicalPathFromUrl(request.url);
  const auto most_recent_space_id = FindMostRecentSpace(model, std::nullopt);
  const std::optional<ProfileID> most_recent_profile =
      most_recent_space_id.has_value() &&
              model.FindSpace(*most_recent_space_id)
          ? std::optional<ProfileID>(
                model.FindSpace(*most_recent_space_id)->profile_id)
          : std::nullopt;

  const auto& rules = model.routing_rules();
  for (size_t i = 0; i < rules.size(); ++i) {
    const RoutingRule& rule = rules[i];
    if (!rule.enabled) {
      decision.traces.push_back({i, rule.id, RoutingRuleOutcome::kDisabled});
      continue;
    }

    std::string required_source = NormalizeAppId(rule.source_app_id);
    if (!required_source.empty()) {
      if (request_source.empty()) {
        decision.traces.push_back(
            {i, rule.id, RoutingRuleOutcome::kSourceUnknown});
        continue;
      }
      if (required_source != request_source) {
        decision.traces.push_back(
            {i, rule.id, RoutingRuleOutcome::kSourceMismatch});
        continue;
      }
    }

    if (!decision.normalized_host.has_value() ||
        !MatchesHostPattern(*decision.normalized_host, rule.host_pattern)) {
      decision.traces.push_back(
          {i, rule.id, RoutingRuleOutcome::kHostMismatch});
      continue;
    }

    if (rule.path_prefix.has_value() && !rule.path_prefix->empty() &&
        !MatchesPathPrefix(url_path, *rule.path_prefix)) {
      decision.traces.push_back(
          {i, rule.id, RoutingRuleOutcome::kPathMismatch});
      continue;
    }

    // Validate destination target existence.
    switch (rule.destination.kind) {
      case RoutingDestinationKind::kSpace: {
        if (!rule.destination.space_id.has_value() ||
            !model.FindSpace(*rule.destination.space_id)) {
          decision.traces.push_back(
              {i, rule.id, RoutingRuleOutcome::kTargetSpaceMissing});
          continue;
        }
        decision.traces.push_back({i, rule.id, RoutingRuleOutcome::kMatched});
        decision.via = RoutingVia::kRule;
        decision.matched_rule_id = rule.id;
        decision.resolved =
            ResolveSpaceTarget(model, *rule.destination.space_id);
        return decision;
      }
      case RoutingDestinationKind::kMostRecentSpace: {
        auto sid = FindMostRecentSpace(model, rule.destination.profile_id);
        if (!sid.has_value()) {
          if (rule.destination.profile_id.has_value()) {
            decision.traces.push_back(
                {i, rule.id, RoutingRuleOutcome::kTargetProfileMissing});
            continue;
          }
          decision.traces.push_back({i, rule.id, RoutingRuleOutcome::kMatched});
          decision.via = RoutingVia::kNoSpaces;
          decision.matched_rule_id = rule.id;
          return decision;
        }
        decision.traces.push_back({i, rule.id, RoutingRuleOutcome::kMatched});
        decision.via = RoutingVia::kRule;
        decision.matched_rule_id = rule.id;
        decision.resolved = ResolveSpaceTarget(model, *sid);
        return decision;
      }
      case RoutingDestinationKind::kLittleOpen: {
        if (rule.destination.profile_id.has_value() &&
            !model.FindProfile(*rule.destination.profile_id)) {
          decision.traces.push_back(
              {i, rule.id, RoutingRuleOutcome::kTargetProfileMissing});
          continue;
        }
        decision.traces.push_back({i, rule.id, RoutingRuleOutcome::kMatched});
        decision.via = RoutingVia::kRule;
        decision.matched_rule_id = rule.id;
        decision.resolved = ResolvedRoutingTarget{
            RoutingDestinationKind::kLittleOpen, std::nullopt,
            rule.destination.profile_id.has_value()
                ? rule.destination.profile_id
                : most_recent_profile};
        return decision;
      }
    }
  }

  // Fallback to default_destination.
  const RoutingDestination& def = model.default_destination();
  decision.via = RoutingVia::kDefaultDestination;
  switch (def.kind) {
    case RoutingDestinationKind::kSpace:
      if (def.space_id.has_value() && model.FindSpace(*def.space_id)) {
        decision.resolved = ResolveSpaceTarget(model, *def.space_id);
      } else {
        decision.via = RoutingVia::kFallbackMissingSpace;
        if (most_recent_space_id.has_value()) {
          decision.resolved = ResolveSpaceTarget(model, *most_recent_space_id);
        }
      }
      break;
    case RoutingDestinationKind::kMostRecentSpace:
      if (def.profile_id.has_value()) {
        auto sid = FindMostRecentSpace(model, def.profile_id);
        if (sid.has_value()) {
          decision.resolved = ResolveSpaceTarget(model, *sid);
        } else {
          decision.via = RoutingVia::kFallbackMissingProfile;
          if (most_recent_space_id.has_value()) {
            decision.resolved =
                ResolveSpaceTarget(model, *most_recent_space_id);
          }
        }
      } else if (most_recent_space_id.has_value()) {
        decision.resolved = ResolveSpaceTarget(model, *most_recent_space_id);
      }
      break;
    case RoutingDestinationKind::kLittleOpen:
      if (external_links_in_little_open) {
        std::optional<ProfileID> pid = def.profile_id;
        if (pid.has_value() && !model.FindProfile(*pid)) {
          decision.via = RoutingVia::kFallbackMissingProfile;
          pid = most_recent_profile;
        } else if (!pid.has_value()) {
          pid = most_recent_profile;
        }
        decision.resolved = ResolvedRoutingTarget{
            RoutingDestinationKind::kLittleOpen, std::nullopt, pid};
      } else {
        decision.via = RoutingVia::kDefaultSuppressedByToggle;
        if (most_recent_space_id.has_value()) {
          decision.resolved = ResolveSpaceTarget(model, *most_recent_space_id);
        }
      }
      break;
  }

  if (!decision.resolved.has_value()) {
    decision.via = RoutingVia::kNoSpaces;
  }
  return decision;
}

}  // namespace open_unified
