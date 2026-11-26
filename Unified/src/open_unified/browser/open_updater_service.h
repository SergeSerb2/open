// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// OpenUpdaterService: Cross-platform GitHub Releases update checker for Open
// Unified.
//
// Queries https://api.github.com/repos/SergeSerb2/open-releases/releases via
// Chromium's network::SimpleURLLoader with:
// - User-Agent: Open-Unified/<version>
// - 1 MiB response cap
// - Zero cookies/credentials (CredentialsMode::kOmit)
// - Channel matching ("unified" tag prefix, "stable", or "beta") + semver
//   comparison against kOpenAppVersion
// - OS & CPU architecture asset selection (.dmg on macOS arm64/x64,
//   .AppImage/.tar.gz on Linux, .exe/.zip on Windows)
// - Timestamped result caching and in-flight request coalescing.

#ifndef OPEN_UNIFIED_BROWSER_OPEN_UPDATER_SERVICE_H_
#define OPEN_UNIFIED_BROWSER_OPEN_UPDATER_SERVICE_H_

#include <cstdint>
#include <memory>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

#include "base/functional/callback.h"
#include "base/memory/scoped_refptr.h"
#include "base/memory/weak_ptr.h"
#include "base/sequence_checker.h"
#include "base/time/time.h"
#include "base/values.h"
#include "url/gurl.h"

namespace network {
class SharedURLLoaderFactory;
class SimpleURLLoader;
}  // namespace network

namespace open_unified {

// Default application version for Open Unified release checks.
inline constexpr char kOpenAppVersion[] = "0.2.0";

// Default GitHub Releases API endpoint.
inline constexpr char kOpenReleasesApiUrl[] =
    "https://api.github.com/repos/SergeSerb2/open-releases/releases";

// Maximum downloaded response body size (1 MiB).
inline constexpr size_t kOpenUpdaterMaxResponseBytes = 1024 * 1024;

enum class UpdateChannel {
  kUnified,  // Matches "unified" tag prefix (or semver fallback), incl. pre-releases.
  kStable,   // Stable releases only (skips prerelease == true).
  kBeta,     // Both stable and pre-release builds.
};

enum class UpdateState {
  kIdle,
  kChecking,
  kUpToDate,
  kUpdateAvailable,
  kError,
};

struct UpdateReleaseAsset {
  std::string name;
  GURL download_url;
  int64_t size_bytes = 0;
};

struct UpdateReleaseInfo {
  UpdateReleaseInfo();
  UpdateReleaseInfo(const UpdateReleaseInfo&);
  UpdateReleaseInfo(UpdateReleaseInfo&&) noexcept;
  UpdateReleaseInfo& operator=(const UpdateReleaseInfo&);
  UpdateReleaseInfo& operator=(UpdateReleaseInfo&&) noexcept;
  ~UpdateReleaseInfo();

  std::string tag_name;
  std::string version;
  std::string name;
  std::string release_notes;
  GURL html_url;
  GURL download_url;
  std::string asset_name;
  int64_t asset_size_bytes = 0;
  std::string published_at;
  bool prerelease = false;
};

struct UpdateCheckStatus {
  UpdateCheckStatus();
  UpdateCheckStatus(const UpdateCheckStatus&);
  UpdateCheckStatus(UpdateCheckStatus&&) noexcept;
  UpdateCheckStatus& operator=(const UpdateCheckStatus&);
  UpdateCheckStatus& operator=(UpdateCheckStatus&&) noexcept;
  ~UpdateCheckStatus();

  UpdateState state = UpdateState::kIdle;
  std::string current_version;
  std::optional<UpdateReleaseInfo> available_release;
  std::string error_message;
  base::Time last_checked_at;
  int http_status_code = 0;
  bool user_initiated = false;
};

class OpenUpdaterService {
 public:
  using UpdateCheckCallback =
      base::OnceCallback<void(const UpdateCheckStatus&)>;

  explicit OpenUpdaterService(
      scoped_refptr<network::SharedURLLoaderFactory> url_loader_factory,
      std::string current_version = kOpenAppVersion);
  ~OpenUpdaterService();

  OpenUpdaterService(const OpenUpdaterService&) = delete;
  OpenUpdaterService& operator=(const OpenUpdaterService&) = delete;

  // Sets or updates the SharedURLLoaderFactory used for GitHub API requests.
  void SetURLLoaderFactory(
      scoped_refptr<network::SharedURLLoaderFactory> url_loader_factory);

  // Checks GitHub Releases for an update.
  // - If a request is already in flight, |cb| is coalesced onto it.
  // - If |user_initiated| is false and a non-error check succeeded within
  //   |cache_ttl_|, returns the cached status immediately without network I/O.
  // - If |user_initiated| is true, bypasses the cache TTL.
  void CheckForUpdates(bool user_initiated, UpdateCheckCallback cb);

  // Cancels any in-flight request (pending callbacks receive a cancelled error).
  void CancelPendingCheck();

  const UpdateCheckStatus& GetLastStatus() const { return last_status_; }
  base::Time last_checked_at() const { return last_status_.last_checked_at; }
  bool is_checking() const { return active_loader_ != nullptr; }

  void SetChannel(UpdateChannel channel);
  void SetChannelFromString(std::string_view channel_name);
  UpdateChannel channel() const { return channel_; }
  static std::string_view ChannelToString(UpdateChannel channel);

  void SetCurrentVersion(std::string version);
  const std::string& current_version() const { return current_version_; }

  void SetReleasesApiUrl(GURL url);
  const GURL& releases_api_url() const { return releases_api_url_; }

  void SetCacheTtl(base::TimeDelta ttl) { cache_ttl_ = ttl; }

  // Serializes the latest status for open://settings and automation.
  base::DictValue ToValue() const;

  // Pure parsing & comparison helpers.
  // Compares two semver strings (stripping leading "unified-", "v", etc.).
  // Returns < 0 if a < b, 0 if equal, > 0 if a > b.
  static int CompareVersions(std::string_view a, std::string_view b);

  // Extracts a normalized semver string from a release tag (e.g.
  // "unified-v1.2.3-beta.1" -> "1.2.3-beta.1"), or empty if unparseable.
  static std::string ExtractVersionFromTag(std::string_view tag_name);

  // Selects the best download asset for the current host OS and CPU arch.
  static std::optional<UpdateReleaseAsset> SelectAssetForCurrentPlatform(
      const std::vector<UpdateReleaseAsset>& assets);

  // Parses the GitHub /releases JSON array and picks the newest release
  // matching |channel| that is strictly newer than |current_version|.
  // Returns std::nullopt on JSON parse error (setting |error_out|); returns
  // a valid optional (possibly empty inner release when up to date) on success.
  static bool ParseReleasesJson(
      std::string_view json_body,
      std::string_view current_version,
      UpdateChannel channel,
      std::optional<UpdateReleaseInfo>* out_available_release,
      std::string* out_error);

 private:
  void OnReleasesFetched(bool user_initiated,
                         std::optional<std::string> response_body);
  void FinishCheck(UpdateCheckStatus status);

  SEQUENCE_CHECKER(sequence_checker_);

  scoped_refptr<network::SharedURLLoaderFactory> url_loader_factory_;
  std::string current_version_;
  UpdateChannel channel_ = UpdateChannel::kUnified;
  GURL releases_api_url_{kOpenReleasesApiUrl};
  base::TimeDelta cache_ttl_ = base::Hours(1);

  UpdateCheckStatus last_status_;
  std::unique_ptr<network::SimpleURLLoader> active_loader_;
  std::vector<UpdateCheckCallback> pending_callbacks_;
  base::WeakPtrFactory<OpenUpdaterService> weak_factory_{this};
};

}  // namespace open_unified

#endif  // OPEN_UNIFIED_BROWSER_OPEN_UPDATER_SERVICE_H_
