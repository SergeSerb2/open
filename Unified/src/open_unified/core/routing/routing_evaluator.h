// Copyright 2026 The Open Authors. All rights reserved.
// Air Traffic Control external-link routing evaluator matching
// Packages/OpenKit/Sources/OpenRouting.

#ifndef OPEN_UNIFIED_CORE_ROUTING_ROUTING_EVALUATOR_H_
#define OPEN_UNIFIED_CORE_ROUTING_ROUTING_EVALUATOR_H_

#include <cstddef>
#include <deque>
#include <optional>
#include <string>
#include <string_view>
#include <unordered_map>
#include <vector>

#include "open_unified/core/model/browser_model.h"
#include "open_unified/core/model/open_types.h"

namespace open_unified {

// Host normalization helpers (lowercase, strip brackets/trailing dots,
// decode RFC 3492 Punycode `xn--` labels, strip `www.`/`*.` for rule matching).
std::string CanonicalHostName(std::string_view raw);
std::optional<std::string> CanonicalHostFromUrl(std::string_view url);
std::string CanonicalPathFromUrl(std::string_view url);
std::string CanonicalUrlString(std::string_view url);
std::optional<std::string> DecodePunycodeLabel(std::string_view payload);

// PeekPolicy (matching Packages/OpenKit/Sources/OpenFeatures/PeekPolicy.swift):
// decides whether an in-page link click opens in the Peek overlay or navigates
// normally, including the OAuth/SSO authentication-flow exemption.
struct PeekClickContext {
  PeekClickContext();
  PeekClickContext(const PeekClickContext&);
  PeekClickContext(PeekClickContext&&) noexcept;
  PeekClickContext& operator=(const PeekClickContext&);
  PeekClickContext& operator=(PeekClickContext&&) noexcept;
  ~PeekClickContext();

  bool source_is_pinned_or_favorite = false;
  std::optional<std::string> source_url;
  std::string target_url;
  bool shift_held = false;
  bool peek_other_sites_enabled = true;
  bool peek_shift_enabled = true;
  // Explicit override; IsAuthenticationFlow(target_url) is also checked.
  bool is_authentication_flow = false;
};

enum class PeekDecision {
  kNavigate,
  kPeek,
};

class PeekPolicy {
 public:
  // True for OAuth / OIDC / SAML / SSO / sign-in authentication URLs that must
  // navigate normally instead of opening inside a Peek overlay.
  static bool IsAuthenticationFlow(std::string_view url);

  // Extracts the registrable domain (eTLD+1) for cross-site comparison.
  static std::optional<std::string> RegistrableDomain(std::string_view url);

  static PeekDecision Evaluate(const PeekClickContext& click);

  static bool ShouldOpenInPeek(std::string_view target_url,
                               const Tab* source_tab,
                               bool source_is_pinned_or_favorite,
                               bool shift_click,
                               bool peek_other_sites_enabled,
                               bool peek_shift_enabled);
};

// Deep links: open:// and open-browser:// routes
// (quit, restart, space/<name|index>, welcome, little-open, WebUI pages).
enum class DeepLinkKind {
  kNone,
  kQuit,
  kRestart,
  kSpace,
  kWelcome,
  kLittleOpen,
  kWebUI,
  kUnknown,
};

struct DeepLinkAction {
  DeepLinkAction();
  DeepLinkAction(const DeepLinkAction&);
  DeepLinkAction(DeepLinkAction&&) noexcept;
  DeepLinkAction& operator=(const DeepLinkAction&);
  DeepLinkAction& operator=(DeepLinkAction&&) noexcept;
  ~DeepLinkAction();

  DeepLinkKind kind = DeepLinkKind::kNone;
  std::string route;
  std::string argument;
  std::string raw_url;
};

DeepLinkAction ParseDeepLink(std::string_view url);
bool IsMailtoUrl(std::string_view url);
bool IsGoogleMeetUrl(std::string_view url);
bool HasGoogleMeetRule(const BrowserModel& model);

struct RoutingRequest {
  std::string url;
  std::optional<std::string> source_app_id;
  TimestampSec received_at = 0.0;
};

enum class RoutingRuleOutcome {
  kMatched,
  kDisabled,
  kSourceUnknown,
  kSourceMismatch,
  kHostMismatch,
  kPathMismatch,
  kTargetSpaceMissing,
  kTargetProfileMissing,
};

struct RoutingRuleTrace {
  size_t rule_index = 0;
  RuleID rule_id;
  RoutingRuleOutcome outcome = RoutingRuleOutcome::kHostMismatch;
};

enum class RoutingVia {
  kRule,
  kDefaultDestination,
  kFallbackMissingSpace,
  kFallbackMissingProfile,
  kDefaultSuppressedByToggle,
  kRejectedNonHttp,
  kNoSpaces,
};

struct ResolvedRoutingTarget {
  RoutingDestinationKind kind = RoutingDestinationKind::kMostRecentSpace;
  std::optional<SpaceID> space_id;
  std::optional<ProfileID> profile_id;

  bool operator==(const ResolvedRoutingTarget&) const = default;
};

struct RoutingDecision {
  RoutingRequest request;
  std::optional<std::string> normalized_host;
  std::vector<RoutingRuleTrace> traces;
  RoutingVia via = RoutingVia::kDefaultDestination;
  std::optional<RuleID> matched_rule_id;
  std::optional<ResolvedRoutingTarget> resolved;
};

// 2-second duplicate external URL suppressor (matching ExternalLinkIntake.swift).
class ExternalLinkDeduper {
 public:
  static constexpr double kWindowSeconds = 2.0;

  ExternalLinkDeduper();
  ~ExternalLinkDeduper();

  // Returns true if |(url, source_app_id)| was already seen within the last
  // kWindowSeconds; otherwise records it and returns false.
  bool IsDuplicateAndRecord(std::string_view url,
                            const std::optional<std::string>& source_app_id,
                            TimestampSec now);

  size_t duplicates_dropped() const { return duplicates_dropped_; }
  void Clear();

 private:
  std::unordered_map<std::string, TimestampSec> recent_;
  size_t duplicates_dropped_ = 0;
};

// Bounded, memory-only log of recent Air Traffic Control routing decisions
// (URLs stay in memory only and are never written to system logs or disk).
class RoutingDecisionLog {
 public:
  static constexpr size_t kMaxEntries = 200;

  RoutingDecisionLog();
  ~RoutingDecisionLog();

  void Record(RoutingDecision decision);
  const std::deque<RoutingDecision>& entries() const { return entries_; }
  std::optional<RoutingDecision> latest() const;
  size_t size() const { return entries_.size(); }
  void Clear() { entries_.clear(); }

 private:
  std::deque<RoutingDecision> entries_;
};

class RoutingEvaluator {
 public:
  RoutingEvaluator() = default;
  ~RoutingEvaluator() = default;

  // Evaluates |request| against ordered RoutingRules in |model|, falling back
  // to |model.default_destination()|.
  RoutingDecision Evaluate(const RoutingRequest& request,
                           const BrowserModel& model,
                           bool external_links_in_little_open = true) const;

  // Host matching helper supporting exact host ("github.com"), suffix/wildcard
  // ("*.github.com", ".github.com"), substring wildcard ("*corp*"), and
  // domain suffix matching.
  static bool MatchesHostPattern(std::string_view host,
                                 std::string_view raw_pattern);

  // Path prefix matching (normalized leading '/').
  static bool MatchesPathPrefix(std::string_view url_path,
                                std::string_view raw_prefix);
};

}  // namespace open_unified

#endif  // OPEN_UNIFIED_CORE_ROUTING_ROUTING_EVALUATOR_H_
