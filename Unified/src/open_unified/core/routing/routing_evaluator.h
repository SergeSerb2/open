// Copyright 2026 The Open Authors. All rights reserved.
// Air Traffic Control external-link routing evaluator matching
// Packages/OpenKit/Sources/OpenRouting.

#ifndef OPEN_UNIFIED_CORE_ROUTING_ROUTING_EVALUATOR_H_
#define OPEN_UNIFIED_CORE_ROUTING_ROUTING_EVALUATOR_H_

#include <cstddef>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

#include "open_unified/core/model/browser_model.h"
#include "open_unified/core/model/open_types.h"

namespace open_unified {

// Host normalization helpers (lowercase, strip brackets/trailing dots,
// decode RFC 3492 Punycode `xn--` labels, strip `www.`/`*.` for rule matching).
std::string CanonicalHostName(std::string_view raw);
std::optional<std::string> CanonicalHostFromUrl(std::string_view url);
std::string CanonicalPathFromUrl(std::string_view url);
std::optional<std::string> DecodePunycodeLabel(std::string_view payload);

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
