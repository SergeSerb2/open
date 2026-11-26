// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "open_unified/browser/open_updater_service.h"

#include <algorithm>
#include <cctype>
#include <utility>

#include "base/functional/bind.h"
#include "base/json/json_reader.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/string_split.h"
#include "base/strings/string_util.h"
#include "build/build_config.h"
#include "net/base/load_flags.h"
#include "net/http/http_request_headers.h"
#include "net/http/http_response_headers.h"
#include "net/traffic_annotation/network_traffic_annotation.h"
#include "services/network/public/cpp/resource_request.h"
#include "services/network/public/cpp/shared_url_loader_factory.h"
#include "services/network/public/cpp/simple_url_loader.h"
#include "services/network/public/mojom/url_response_head.mojom.h"

namespace open_unified {

namespace {

constexpr base::TimeDelta kUpdateRequestTimeout = base::Seconds(15);
constexpr size_t kMaxReleaseNotesBytes = 64 * 1024;

constexpr net::NetworkTrafficAnnotationTag kUpdaterTrafficAnnotation =
    net::DefineNetworkTrafficAnnotation("open_updater_service", R"(
        semantics {
          sender: "Open Unified Updater Service"
          description:
            "Queries the GitHub Releases API for Open Unified to check whether "
            "a newer version of the browser is available."
          trigger:
            "Automatic periodic update check or user clicking Check for "
            "Updates in Settings or the application menu."
          data:
            "No user data or cookies. Sends only an Open-Unified/<version> "
            "User-Agent header."
          destination: OTHER
          destination_other: "GitHub Releases API at api.github.com"
          internal {
            contacts {
              email: "engineering@openbrowser.dev"
            }
          }
          user_data {
            type: NONE
          }
          last_reviewed: "2026-11-26"
        }
        policy {
          cookies_allowed: NO
          setting:
            "Controlled by the 'Automatically check for updates' preference "
            "in open://settings."
          policy_exception_justification:
            "Update checks can be disabled in Settings; no credentials or "
            "cookies are sent."
        })");

struct ParsedSemver {
  uint32_t major = 0;
  uint32_t minor = 0;
  uint32_t patch = 0;
  std::string prerelease;
  bool valid = false;
};

ParsedSemver ParseSemver(std::string_view raw) {
  ParsedSemver out;
  std::string normalized = OpenUpdaterService::ExtractVersionFromTag(raw);
  if (normalized.empty()) {
    return out;
  }

  // Strip build metadata ("+...").
  if (const size_t plus = normalized.find('+'); plus != std::string::npos) {
    normalized.resize(plus);
  }

  std::string core = normalized;
  if (const size_t dash = normalized.find('-'); dash != std::string::npos) {
    core = normalized.substr(0, dash);
    out.prerelease = normalized.substr(dash + 1);
  }

  const std::vector<std::string_view> parts = base::SplitStringPiece(
      core, ".", base::KEEP_WHITESPACE, base::SPLIT_WANT_ALL);
  if (parts.empty() || parts.size() > 4) {
    return out;
  }

  uint32_t nums[3] = {0, 0, 0};
  for (size_t i = 0; i < std::min<size_t>(parts.size(), 3); ++i) {
    if (parts[i].empty() || !base::StringToUint(parts[i], &nums[i])) {
      return out;
    }
  }
  out.major = nums[0];
  out.minor = nums[1];
  out.patch = nums[2];
  out.valid = true;
  return out;
}

int ComparePrerelease(std::string_view a, std::string_view b) {
  if (a.empty() && b.empty()) {
    return 0;
  }
  // SemVer 2.0.0: a normal version has higher precedence than a pre-release.
  if (a.empty()) {
    return 1;
  }
  if (b.empty()) {
    return -1;
  }

  const std::vector<std::string_view> a_ids = base::SplitStringPiece(
      a, ".", base::KEEP_WHITESPACE, base::SPLIT_WANT_ALL);
  const std::vector<std::string_view> b_ids = base::SplitStringPiece(
      b, ".", base::KEEP_WHITESPACE, base::SPLIT_WANT_ALL);
  const size_t count = std::min(a_ids.size(), b_ids.size());
  for (size_t i = 0; i < count; ++i) {
    uint64_t a_num = 0;
    uint64_t b_num = 0;
    const bool a_is_num = base::StringToUint64(a_ids[i], &a_num);
    const bool b_is_num = base::StringToUint64(b_ids[i], &b_num);
    if (a_is_num && b_is_num) {
      if (a_num != b_num) {
        return a_num < b_num ? -1 : 1;
      }
    } else if (a_is_num != b_is_num) {
      // Numeric identifiers always have lower precedence than non-numeric.
      return a_is_num ? -1 : 1;
    } else {
      const int cmp = base::CompareCaseInsensitiveASCII(a_ids[i], b_ids[i]);
      if (cmp != 0) {
        return cmp;
      }
    }
  }
  if (a_ids.size() != b_ids.size()) {
    return a_ids.size() < b_ids.size() ? -1 : 1;
  }
  return 0;
}

bool HasUnifiedTagPrefix(std::string_view tag_name) {
  const std::string lower = base::ToLowerASCII(tag_name);
  return lower.starts_with("unified-") || lower.starts_with("unified/") ||
         lower.starts_with("unified_") || lower == "unified";
}

bool IsSafeDownloadUrl(const GURL& url) {
  return url.is_valid() && url.SchemeIs(url::kHttpsScheme);
}

int ScoreAssetForCurrentPlatform(std::string_view raw_name) {
  const std::string name = base::ToLowerASCII(raw_name);
  // Skip checksum / signature / debug-symbol sidecar files.
  if (name.ends_with(".sha256") || name.ends_with(".sha512") ||
      name.ends_with(".sig") || name.ends_with(".asc") ||
      name.ends_with(".txt") || name.ends_with(".json") ||
      name.ends_with(".blockmap") || name.ends_with(".dsym.zip") ||
      name.ends_with(".pdb")) {
    return -1;
  }

  const bool mentions_arm64 =
      name.find("arm64") != std::string::npos ||
      name.find("aarch64") != std::string::npos ||
      name.find("apple-silicon") != std::string::npos;
  const bool mentions_x64 =
      name.find("x86_64") != std::string::npos ||
      name.find("amd64") != std::string::npos ||
      name.find("x64") != std::string::npos ||
      name.find("intel") != std::string::npos ||
      name.find("win64") != std::string::npos;
  const bool mentions_universal = name.find("universal") != std::string::npos;

#if defined(ARCH_CPU_ARM64)
  const bool arch_match = mentions_arm64;
  const bool arch_mismatch = mentions_x64 && !mentions_arm64 && !mentions_universal;
#else
  const bool arch_match = mentions_x64;
  const bool arch_mismatch = mentions_arm64 && !mentions_x64 && !mentions_universal;
#endif

  if (arch_mismatch) {
    return -1;
  }

  int score = 0;
#if BUILDFLAG(IS_MAC)
  const bool wrong_os =
      name.find("linux") != std::string::npos ||
      name.find("windows") != std::string::npos ||
      name.find("win32") != std::string::npos ||
      name.find("win64") != std::string::npos;
  if (wrong_os) {
    return -1;
  }
  if (name.ends_with(".dmg")) {
    score = 100;
  } else if (name.ends_with(".pkg")) {
    score = 70;
  } else if (name.ends_with(".zip") &&
             (name.find("mac") != std::string::npos ||
              name.find("darwin") != std::string::npos ||
              name.find("osx") != std::string::npos ||
              mentions_arm64 || mentions_universal)) {
    score = 50;
  } else {
    return -1;
  }
#elif BUILDFLAG(IS_LINUX)
  const bool wrong_os =
      name.find("mac") != std::string::npos ||
      name.find("darwin") != std::string::npos ||
      name.find("windows") != std::string::npos ||
      name.find("win64") != std::string::npos;
  if (wrong_os) {
    return -1;
  }
  if (name.ends_with(".appimage")) {
    score = 100;
  } else if (name.ends_with(".tar.gz") || name.ends_with(".tgz")) {
    score = 85;
  } else if (name.ends_with(".tar.xz")) {
    score = 70;
  } else if (name.ends_with(".deb")) {
    score = 60;
  } else {
    return -1;
  }
#elif BUILDFLAG(IS_WIN)
  const bool wrong_os =
      name.find("mac") != std::string::npos ||
      name.find("darwin") != std::string::npos ||
      name.find("linux") != std::string::npos;
  if (wrong_os) {
    return -1;
  }
  if (name.ends_with(".exe")) {
    score = 100;
  } else if (name.ends_with(".msi")) {
    score = 90;
  } else if (name.ends_with(".zip")) {
    score = 75;
  } else {
    return -1;
  }
#else
  return -1;
#endif

  if (arch_match) {
    score += 30;
  } else if (mentions_universal) {
    score += 15;
  }
  if (name.find("unified") != std::string::npos) {
    score += 10;
  }
  return score;
}

std::string StateToString(UpdateState state) {
  switch (state) {
    case UpdateState::kIdle:
      return "idle";
    case UpdateState::kChecking:
      return "checking";
    case UpdateState::kUpToDate:
      return "up_to_date";
    case UpdateState::kUpdateAvailable:
      return "update_available";
    case UpdateState::kError:
      return "error";
  }
  return "idle";
}

}  // namespace

UpdateReleaseInfo::UpdateReleaseInfo() = default;
UpdateReleaseInfo::UpdateReleaseInfo(const UpdateReleaseInfo&) = default;
UpdateReleaseInfo::UpdateReleaseInfo(UpdateReleaseInfo&&) noexcept = default;
UpdateReleaseInfo& UpdateReleaseInfo::operator=(const UpdateReleaseInfo&) =
    default;
UpdateReleaseInfo& UpdateReleaseInfo::operator=(UpdateReleaseInfo&&) noexcept =
    default;
UpdateReleaseInfo::~UpdateReleaseInfo() = default;

UpdateCheckStatus::UpdateCheckStatus() = default;
UpdateCheckStatus::UpdateCheckStatus(const UpdateCheckStatus&) = default;
UpdateCheckStatus::UpdateCheckStatus(UpdateCheckStatus&&) noexcept = default;
UpdateCheckStatus& UpdateCheckStatus::operator=(const UpdateCheckStatus&) =
    default;
UpdateCheckStatus& UpdateCheckStatus::operator=(UpdateCheckStatus&&) noexcept =
    default;
UpdateCheckStatus::~UpdateCheckStatus() = default;

OpenUpdaterService::OpenUpdaterService(
    scoped_refptr<network::SharedURLLoaderFactory> url_loader_factory,
    std::string current_version)
    : url_loader_factory_(std::move(url_loader_factory)),
      current_version_(current_version.empty() ? std::string(kOpenAppVersion)
                                               : std::move(current_version)) {
  last_status_.current_version = current_version_;
}

OpenUpdaterService::~OpenUpdaterService() {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  CancelPendingCheck();
}

void OpenUpdaterService::SetURLLoaderFactory(
    scoped_refptr<network::SharedURLLoaderFactory> url_loader_factory) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  url_loader_factory_ = std::move(url_loader_factory);
}

void OpenUpdaterService::SetChannel(UpdateChannel channel) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  if (channel_ == channel) {
    return;
  }
  channel_ = channel;
  // Invalidate cached timestamp so next check evaluates the new channel.
  last_status_.last_checked_at = base::Time();
}

void OpenUpdaterService::SetChannelFromString(std::string_view channel_name) {
  const std::string lower = base::ToLowerASCII(channel_name);
  if (lower == "stable") {
    SetChannel(UpdateChannel::kStable);
  } else if (lower == "beta") {
    SetChannel(UpdateChannel::kBeta);
  } else {
    SetChannel(UpdateChannel::kUnified);
  }
}

// static
std::string_view OpenUpdaterService::ChannelToString(UpdateChannel channel) {
  switch (channel) {
    case UpdateChannel::kUnified:
      return "unified";
    case UpdateChannel::kStable:
      return "stable";
    case UpdateChannel::kBeta:
      return "beta";
  }
  return "unified";
}

void OpenUpdaterService::SetCurrentVersion(std::string version) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  current_version_ =
      version.empty() ? std::string(kOpenAppVersion) : std::move(version);
  last_status_.current_version = current_version_;
}

void OpenUpdaterService::SetReleasesApiUrl(GURL url) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  if (url.is_valid()) {
    releases_api_url_ = std::move(url);
  }
}

void OpenUpdaterService::CancelPendingCheck() {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  if (!active_loader_) {
    return;
  }
  active_loader_.reset();
  if (last_status_.state == UpdateState::kChecking) {
    last_status_.state = UpdateState::kIdle;
  }
  auto callbacks = std::move(pending_callbacks_);
  pending_callbacks_.clear();
  UpdateCheckStatus cancelled = last_status_;
  cancelled.state = UpdateState::kError;
  cancelled.error_message = "Update check cancelled.";
  for (auto& cb : callbacks) {
    if (cb) {
      std::move(cb).Run(cancelled);
    }
  }
}

void OpenUpdaterService::CheckForUpdates(bool user_initiated,
                                         UpdateCheckCallback cb) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);

  // Return cached status for background checks inside TTL.
  if (!user_initiated && !active_loader_ &&
      (last_status_.state == UpdateState::kUpToDate ||
       last_status_.state == UpdateState::kUpdateAvailable) &&
      !last_status_.last_checked_at.is_null() &&
      (base::Time::Now() - last_status_.last_checked_at) < cache_ttl_) {
    if (cb) {
      std::move(cb).Run(last_status_);
    }
    return;
  }

  if (cb) {
    pending_callbacks_.push_back(std::move(cb));
  }

  // Coalesce into an already running request.
  if (active_loader_) {
    if (user_initiated) {
      last_status_.user_initiated = true;
    }
    return;
  }

  if (!url_loader_factory_) {
    UpdateCheckStatus err;
    err.state = UpdateState::kError;
    err.current_version = current_version_;
    err.error_message = "Network service unavailable for update check.";
    err.last_checked_at = base::Time::Now();
    err.user_initiated = user_initiated;
    FinishCheck(std::move(err));
    return;
  }

  if (!releases_api_url_.is_valid() ||
      (!releases_api_url_.SchemeIs(url::kHttpsScheme) &&
       !releases_api_url_.HostIsIPAddress() &&
       releases_api_url_.host() != "localhost")) {
    UpdateCheckStatus err;
    err.state = UpdateState::kError;
    err.current_version = current_version_;
    err.error_message = "Invalid update feed URL.";
    err.last_checked_at = base::Time::Now();
    err.user_initiated = user_initiated;
    FinishCheck(std::move(err));
    return;
  }

  last_status_.state = UpdateState::kChecking;
  last_status_.current_version = current_version_;
  last_status_.error_message.clear();
  last_status_.user_initiated = user_initiated;

  auto request = std::make_unique<network::ResourceRequest>();
  request->url = releases_api_url_;
  request->method = net::HttpRequestHeaders::kGetMethod;
  // Never send or save cookies or ambient credentials.
  request->credentials_mode = network::mojom::CredentialsMode::kOmit;
  request->load_flags = net::LOAD_BYPASS_CACHE | net::LOAD_DISABLE_CACHE;
  request->headers.SetHeader(net::HttpRequestHeaders::kUserAgent,
                             "Open-Unified/" + current_version_);
  request->headers.SetHeader(net::HttpRequestHeaders::kAccept,
                             "application/vnd.github+json");
  request->headers.SetHeader("X-GitHub-Api-Version", "2022-11-28");

  active_loader_ = network::SimpleURLLoader::Create(
      std::move(request), kUpdaterTrafficAnnotation);
  active_loader_->SetAllowHttpErrorResults(true);
  active_loader_->SetTimeoutDuration(kUpdateRequestTimeout);
  active_loader_->SetRetryOptions(
      1, network::SimpleURLLoader::RETRY_ON_5XX |
             network::SimpleURLLoader::RETRY_ON_NETWORK_CHANGE);

  active_loader_->DownloadToString(
      url_loader_factory_.get(),
      base::BindOnce(&OpenUpdaterService::OnReleasesFetched,
                     weak_factory_.GetWeakPtr(), user_initiated),
      kOpenUpdaterMaxResponseBytes);
}

void OpenUpdaterService::OnReleasesFetched(
    bool user_initiated,
    std::optional<std::string> response_body) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);

  auto loader = std::move(active_loader_);
  UpdateCheckStatus status;
  status.current_version = current_version_;
  status.last_checked_at = base::Time::Now();
  status.user_initiated = user_initiated || last_status_.user_initiated;

  int net_error = loader ? loader->NetError() : -1;
  if (loader && loader->ResponseInfo() && loader->ResponseInfo()->headers) {
    status.http_status_code =
        loader->ResponseInfo()->headers->response_code();
  }

  if (!response_body.has_value()) {
    status.state = UpdateState::kError;
    status.error_message =
        "Failed to reach update server (net error " +
        base::NumberToString(net_error) + ").";
    FinishCheck(std::move(status));
    return;
  }

  if (status.http_status_code == 403 || status.http_status_code == 429) {
    status.state = UpdateState::kError;
    status.error_message =
        "GitHub Releases API rate limit exceeded. Try again later.";
    FinishCheck(std::move(status));
    return;
  }

  if (status.http_status_code < 200 || status.http_status_code >= 300) {
    status.state = UpdateState::kError;
    status.error_message =
        "Update server returned HTTP " +
        base::NumberToString(status.http_status_code) + ".";
    FinishCheck(std::move(status));
    return;
  }

  std::optional<UpdateReleaseInfo> available;
  std::string parse_error;
  if (!ParseReleasesJson(*response_body, current_version_, channel_, &available,
                         &parse_error)) {
    status.state = UpdateState::kError;
    status.error_message =
        parse_error.empty() ? "Invalid update metadata." : parse_error;
    FinishCheck(std::move(status));
    return;
  }

  if (available.has_value()) {
    status.state = UpdateState::kUpdateAvailable;
    status.available_release = std::move(available);
  } else {
    status.state = UpdateState::kUpToDate;
  }
  FinishCheck(std::move(status));
}

void OpenUpdaterService::FinishCheck(UpdateCheckStatus status) {
  last_status_ = std::move(status);
  auto callbacks = std::move(pending_callbacks_);
  pending_callbacks_.clear();
  for (auto& cb : callbacks) {
    if (cb) {
      std::move(cb).Run(last_status_);
    }
  }
}

base::DictValue OpenUpdaterService::ToValue() const {
  base::DictValue out;
  out.Set("state", StateToString(last_status_.state));
  out.Set("channel", std::string(ChannelToString(channel_)));
  out.Set("current_version", current_version_);
  out.Set("checking", is_checking());
  if (!last_status_.last_checked_at.is_null()) {
    out.Set("last_checked_at",
            last_status_.last_checked_at.InSecondsFSinceUnixEpoch());
  }
  if (!last_status_.error_message.empty()) {
    out.Set("error", last_status_.error_message);
  }
  if (last_status_.available_release) {
    const UpdateReleaseInfo& rel = *last_status_.available_release;
    base::DictValue rel_dict;
    rel_dict.Set("tag_name", rel.tag_name);
    rel_dict.Set("version", rel.version);
    rel_dict.Set("name", rel.name);
    rel_dict.Set("release_notes", rel.release_notes);
    rel_dict.Set("html_url", rel.html_url.spec());
    rel_dict.Set("download_url", rel.download_url.spec());
    rel_dict.Set("asset_name", rel.asset_name);
    rel_dict.Set("asset_size_bytes", static_cast<double>(rel.asset_size_bytes));
    rel_dict.Set("published_at", rel.published_at);
    rel_dict.Set("prerelease", rel.prerelease);
    out.Set("available_release", std::move(rel_dict));
  }
  return out;
}

// static
std::string OpenUpdaterService::ExtractVersionFromTag(
    std::string_view tag_name) {
  std::string_view s = base::TrimWhitespaceASCII(tag_name, base::TRIM_ALL);
  if (s.empty()) {
    return std::string();
  }

  // Strip known channel prefixes ("unified-", "unified/", "unified_").
  const std::string lower = base::ToLowerASCII(s);
  if (lower.starts_with("unified-") || lower.starts_with("unified/") ||
      lower.starts_with("unified_")) {
    s.remove_prefix(8);
  } else if (lower.starts_with("open-unified-")) {
    s.remove_prefix(13);
  } else if (lower.starts_with("open-")) {
    s.remove_prefix(5);
  }

  if (!s.empty() && (s[0] == 'v' || s[0] == 'V')) {
    s.remove_prefix(1);
  }

  // Find the first digit to tolerate prefixes like "release-1.2.3".
  size_t digit_pos = 0;
  while (digit_pos < s.size() &&
         !std::isdigit(static_cast<unsigned char>(s[digit_pos]))) {
    ++digit_pos;
  }
  if (digit_pos >= s.size()) {
    return std::string();
  }
  s.remove_prefix(digit_pos);
  return std::string(s);
}

// static
int OpenUpdaterService::CompareVersions(std::string_view a,
                                        std::string_view b) {
  const ParsedSemver va = ParseSemver(a);
  const ParsedSemver vb = ParseSemver(b);
  if (!va.valid || !vb.valid) {
    return base::CompareCaseInsensitiveASCII(a, b);
  }
  if (va.major != vb.major) {
    return va.major < vb.major ? -1 : 1;
  }
  if (va.minor != vb.minor) {
    return va.minor < vb.minor ? -1 : 1;
  }
  if (va.patch != vb.patch) {
    return va.patch < vb.patch ? -1 : 1;
  }
  return ComparePrerelease(va.prerelease, vb.prerelease);
}

// static
std::optional<UpdateReleaseAsset>
OpenUpdaterService::SelectAssetForCurrentPlatform(
    const std::vector<UpdateReleaseAsset>& assets) {
  int best_score = -1;
  std::optional<UpdateReleaseAsset> best;
  for (const UpdateReleaseAsset& asset : assets) {
    if (!IsSafeDownloadUrl(asset.download_url)) {
      continue;
    }
    const int score = ScoreAssetForCurrentPlatform(asset.name);
    if (score > best_score) {
      best_score = score;
      best = asset;
    }
  }
  return best;
}

// static
bool OpenUpdaterService::ParseReleasesJson(
    std::string_view json_body,
    std::string_view current_version,
    UpdateChannel channel,
    std::optional<UpdateReleaseInfo>* out_available_release,
    std::string* out_error) {
  if (out_available_release) {
    out_available_release->reset();
  }
  if (out_error) {
    out_error->clear();
  }

  std::optional<base::ListValue> releases =
      base::JSONReader::ReadList(json_body, base::JSON_PARSE_RFC);
  if (!releases.has_value()) {
    if (out_error) {
      *out_error = "Malformed GitHub Releases JSON payload.";
    }
    return false;
  }

  // First check whether the feed contains any unified-prefixed releases when
  // running on the kUnified channel.
  bool feed_has_unified_tags = false;
  if (channel == UpdateChannel::kUnified) {
    for (const base::Value& entry : *releases) {
      const base::DictValue* dict = entry.GetIfDict();
      if (!dict || dict->FindBool("draft").value_or(false)) {
        continue;
      }
      if (const std::string* tag = dict->FindString("tag_name");
          tag && HasUnifiedTagPrefix(*tag)) {
        feed_has_unified_tags = true;
        break;
      }
    }
  }

  std::optional<UpdateReleaseInfo> best;
  for (const base::Value& entry : *releases) {
    const base::DictValue* dict = entry.GetIfDict();
    if (!dict) {
      continue;
    }
    if (dict->FindBool("draft").value_or(false)) {
      continue;
    }
    const bool prerelease = dict->FindBool("prerelease").value_or(false);
    const std::string* tag_ptr = dict->FindString("tag_name");
    if (!tag_ptr || tag_ptr->empty()) {
      continue;
    }
    const std::string& tag = *tag_ptr;

    // Channel filter.
    if (channel == UpdateChannel::kStable) {
      if (prerelease || HasUnifiedTagPrefix(tag)) {
        continue;
      }
    } else if (channel == UpdateChannel::kUnified) {
      if (feed_has_unified_tags && !HasUnifiedTagPrefix(tag)) {
        continue;
      }
    }

    const std::string version = ExtractVersionFromTag(tag);
    if (version.empty() || !ParseSemver(version).valid) {
      continue;
    }
    if (CompareVersions(version, current_version) <= 0) {
      continue;
    }

    if (best && CompareVersions(version, best->version) <= 0) {
      continue;
    }

    UpdateReleaseInfo info;
    info.tag_name = tag;
    info.version = version;
    info.prerelease = prerelease;
    if (const std::string* name = dict->FindString("name")) {
      info.name = *name;
    }
    if (info.name.empty()) {
      info.name = "Open " + info.version;
    }
    if (const std::string* body = dict->FindString("body")) {
      info.release_notes = body->size() > kMaxReleaseNotesBytes
                               ? body->substr(0, kMaxReleaseNotesBytes)
                               : *body;
    }
    if (const std::string* html_url = dict->FindString("html_url")) {
      GURL parsed(*html_url);
      if (IsSafeDownloadUrl(parsed)) {
        info.html_url = std::move(parsed);
      }
    }
    if (const std::string* published = dict->FindString("published_at")) {
      info.published_at = *published;
    }

    std::vector<UpdateReleaseAsset> assets;
    if (const base::ListValue* asset_list = dict->FindList("assets")) {
      for (const base::Value& asset_val : *asset_list) {
        const base::DictValue* asset_dict = asset_val.GetIfDict();
        if (!asset_dict) {
          continue;
        }
        const std::string* asset_name = asset_dict->FindString("name");
        const std::string* asset_url =
            asset_dict->FindString("browser_download_url");
        if (!asset_name || !asset_url) {
          continue;
        }
        GURL parsed_url(*asset_url);
        if (!IsSafeDownloadUrl(parsed_url)) {
          continue;
        }
        UpdateReleaseAsset asset;
        asset.name = *asset_name;
        asset.download_url = std::move(parsed_url);
        if (std::optional<double> sz = asset_dict->FindDouble("size")) {
          asset.size_bytes = static_cast<int64_t>(*sz);
        } else if (std::optional<int> sz_int = asset_dict->FindInt("size")) {
          asset.size_bytes = static_cast<int64_t>(*sz_int);
        }
        assets.push_back(std::move(asset));
      }
    }

    if (auto chosen = SelectAssetForCurrentPlatform(assets)) {
      info.download_url = std::move(chosen->download_url);
      info.asset_name = std::move(chosen->name);
      info.asset_size_bytes = chosen->size_bytes;
    } else if (info.html_url.is_valid()) {
      info.download_url = info.html_url;
    }

    best = std::move(info);
  }

  if (out_available_release) {
    *out_available_release = std::move(best);
  }
  return true;
}

}  // namespace open_unified
