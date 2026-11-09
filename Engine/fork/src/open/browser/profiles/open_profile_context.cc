// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "open/browser/profiles/open_profile_context.h"

#include <cmath>
#include <cstdint>
#include <map>
#include <memory>
#include <set>
#include <sstream>
#include <string>
#include <utility>

#include "base/feature_list.h"
#include "base/functional/bind.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "base/no_destructor.h"
#include "base/supports_user_data.h"
#include "base/task/single_thread_task_runner.h"
#include "base/time/time.h"
#include "cef/include/cef_open_profile.h"
#include "cef/libcef/browser/chrome/chrome_browser_context.h"
#include "cef/libcef/browser/request_context_impl.h"
#include "cef/libcef/browser/thread_util.h"
#include "chrome/browser/browser_features.h"
#include "chrome/browser/browser_process.h"
#include "chrome/browser/browsing_data/chrome_browsing_data_remover_constants.h"
#include "chrome/browser/prefs/incognito_mode_prefs.h"
#include "chrome/browser/profiles/keep_alive/profile_keep_alive_types.h"
#include "chrome/browser/profiles/keep_alive/scoped_profile_keep_alive.h"
#include "chrome/browser/profiles/profile_attributes_storage.h"
#include "chrome/browser/profiles/profile_manager.h"
#include "chrome/browser/profiles/profile_observer.h"
#include "chrome/common/chrome_constants.h"
#include "chrome/common/pref_names.h"
#include "components/prefs/pref_service.h"
#include "components/prefs/scoped_user_pref_update.h"
#include "content/public/browser/browsing_data_remover.h"

namespace {

using Remover = content::BrowsingDataRemover;
const char kClosedProfileKey[] = "open_engine.closed_primary_otr";
struct ClosedProfile : base::SupportsUserData::Data {};
using HandlerMap = std::map<Profile*, CefRefPtr<CefOpenProfileHandler>>;
HandlerMap& Handlers() {
  static base::NoDestructor<HandlerMap> handlers;
  return *handlers;
}

std::set<base::FilePath>& ClosingPaths() {
  // A retired directory is never reopened during this process.
  static base::NoDestructor<std::set<base::FilePath>> paths;
  return *paths;
}

Profile* LiveProfile(CefRefPtr<CefRequestContext> context) {
  if (!CEF_CURRENTLY_ON_UIT() || !context) {
    return nullptr;
  }
  auto* browser_context = static_cast<CefRequestContextImpl*>(context.get())
                              ->GetInitializedBrowserContext();
  return browser_context ? browser_context->AsProfile() : nullptr;
}

// Self-owned for the remover operation. Its keep-alive prevents destruction
// between starting removal and its real completion, including extension cleanup.
class DataRemoval : public Remover::Observer {
 public:
  DataRemoval(Profile* profile, base::OnceCallback<void(uint64_t)> callback)
      : keep_alive_(profile, ProfileKeepAliveOrigin::kClearingBrowsingData),
        remover_(profile->GetBrowsingDataRemover()),
        callback_(std::move(callback)) {
    remover_->AddObserver(this);
  }

  void Start(base::Time begin, base::Time end, uint64_t mask) {
    remover_->RemoveAndReply(
        begin, end, mask,
        chrome_browsing_data_remover::ALL_ORIGIN_TYPES, this);
  }

  void OnBrowsingDataRemoverDone(uint64_t failed) override {
    remover_->RemoveObserver(this);
    // Post before releasing our own keep-alive. The callback may drop CEF's
    // final keep-alive, and must not run inside remover service code.
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE, base::BindOnce(std::move(callback_), failed));
    delete this;
  }

 private:
  ScopedProfileKeepAlive keep_alive_;
  raw_ptr<Remover> remover_;
  base::OnceCallback<void(uint64_t)> callback_;
};

const char kDeletionSentinelKey[] = "open_engine.profile_deletion_sentinel";

class DestructionSentinel : public base::SupportsUserData::Data {
 public:
  explicit DestructionSentinel(base::OnceClosure callback)
      : callback_(std::move(callback)) {}
  ~DestructionSentinel() override {
    // SupportsUserData is destroyed late, after Profile's members/services.
    // Continue on another task, after the complete destructor stack unwinds.
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE, std::move(callback_));
  }

 private:
  base::OnceClosure callback_;
};

class ProfileDeletion : public ProfileObserver {
 public:
  ProfileDeletion(Profile* profile,
                  CefRefPtr<CefOpenProfileDeletionHandler> handler)
      : profile_(profile),
        path_(profile->GetPath()),
        handler_(handler),
        keep_alive_(std::make_unique<ScopedProfileKeepAlive>(
            profile, ProfileKeepAliveOrigin::kProfileDeletionProcess)) {
    profile_->AddObserver(this);
    profile_->SetUserData(
        kDeletionSentinelKey,
        std::make_unique<DestructionSentinel>(base::BindOnce(
            &ProfileDeletion::Destroyed, weak_factory_.GetWeakPtr())));
  }

  ~ProfileDeletion() override {
    if (profile_) {
      profile_->RemoveObserver(this);
    }
  }

  void Start() {
    auto* removal = new DataRemoval(
        profile_, base::BindOnce(&ProfileDeletion::Wiped,
                                 weak_factory_.GetWeakPtr()));
    removal->Start(base::Time(), base::Time::Max(),
                   chrome_browsing_data_remover::WIPE_PROFILE);
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostDelayedTask(
        FROM_HERE,
        base::BindOnce(&ProfileDeletion::TimedOut, weak_factory_.GetWeakPtr()),
        base::Seconds(30));
  }

  void OnProfileWillBeDestroyed(Profile* profile) override {
    profile->RemoveObserver(this);
    profile_ = nullptr;
    // This early notification is deliberately not the completion barrier.
  }

 private:
  void Wiped(uint64_t failed) {
    if (failed || !profile_) {
      Finish("profile-wipe-failed");
      return;
    }
    profile_->GetPrefs()->OnStoreDeletionFromDisk();
    handler_->OnReadyToRelease();
    keep_alive_.reset();
    released_ = true;
    // CEF and primary OTR keep-alives can release on later UI tasks. Wait for
    // the destruction sentinel; diagnose remaining holders at the deadline.
  }

  std::string KeepAliveError() const {
    if (!profile_ || !g_browser_process ||
        !g_browser_process->profile_manager()) {
      return {};
    }
    auto counts = g_browser_process->profile_manager()->GetKeepAlivesByPath(path_);
    std::ostringstream error;
    for (const auto& [origin, count] : counts) {
      if (count > 0) {
        if (error.tellp() == 0) {
          error << "profile-keep-alive-held:";
        }
        // Numeric origin/count only. Never include the directory or name.
        error << " " << static_cast<int>(origin) << "=" << count;
      }
    }
    return error.str();
  }

  void Destroyed() {
    if (!g_browser_process || !g_browser_process->profile_manager()) {
      Finish("profile-manager-unavailable");
      return;
    }
    auto* manager = g_browser_process->profile_manager();
    if (manager->GetProfileByPath(path_)) {
      Finish("profile-reloaded-during-deletion");
      return;
    }
    auto& storage = manager->GetProfileAttributesStorage();
    if (storage.GetProfileAttributesWithPath(path_)) {
      storage.RemoveProfile(path_);
    }
    auto* prefs_service = g_browser_process->local_state();
    {
      ScopedListPrefUpdate active(prefs_service, prefs::kProfilesLastActive);
      active->EraseValue(base::Value(path_.BaseName().AsUTF8Unsafe()));
    }
    if (prefs_service->GetString(prefs::kProfileLastUsed) ==
        path_.BaseName().AsUTF8Unsafe()) {
      prefs_service->SetString(prefs::kProfileLastUsed,
                               chrome::kInitialProfile);
    }
    prefs_service->CommitPendingWrite(base::BindOnce(
        &ProfileDeletion::Finish, weak_factory_.GetWeakPtr(), std::string()));
  }

  void TimedOut() {
    const auto keep_alive_error = released_ ? KeepAliveError() : std::string();
    Finish(!keep_alive_error.empty() ? keep_alive_error :
           released_ ? "profile-destruction-timeout" : "profile-wipe-timeout");
  }

  void Finish(const std::string& error) {
    auto handler = std::move(handler_);
    // Invalidate weak callbacks before our own keep-alive can release Profile.
    weak_factory_.InvalidateWeakPtrs();
    handler->OnComplete(error);
    delete this;
  }

  raw_ptr<Profile> profile_;
  const base::FilePath path_;
  CefRefPtr<CefOpenProfileDeletionHandler> handler_;
  std::unique_ptr<ScopedProfileKeepAlive> keep_alive_;
  bool released_ = false;
  base::WeakPtrFactory<ProfileDeletion> weak_factory_{this};
};

}  // namespace

namespace open_engine {
void ProfileContextClosed(Profile* profile) {
  // Native Profiles can close while CEF wrappers are still retained (0701).
  // End ad-block work before notifying the shell or tearing down the Profile.
  if (auto* context = CefBrowserContext::FromBrowserContext(profile)) {
    context->ShutdownOpenAdBlockService();
  }
  if (profile->IsPrimaryOTRProfile())
    profile->SetUserData(kClosedProfileKey, std::make_unique<ClosedProfile>());
  auto found = Handlers().find(profile);
  if (found == Handlers().end()) {
    return;
  }
  auto handler = std::move(found->second);
  Handlers().erase(found);
  // Clear shell handles before returning to native teardown. The shell handler
  // defers releasing CEF handles until the current observer stack has unwound.
  handler->OnContextClosed();
}
}  // namespace open_engine

CefRefPtr<CefRequestContext> CefCreateIncognitoContext(
    CefRefPtr<CefRequestContext> original,
    CefRefPtr<CefRequestContextHandler> handler) {
  Profile* parent = LiveProfile(original);
  if (!parent || parent->IsOffTheRecord() || !parent->IsRegularProfile() ||
      parent->ShutdownStarted() ||
      ClosingPaths().contains(parent->GetPath()) ||
      !IncognitoModePrefs::IsIncognitoAllowed(parent) ||
      IncognitoModePrefs::GetIncognitoModeType(parent) !=
          IncognitoModePrefs::IncognitoModeType::kStandard) {
    return nullptr;
  }
  auto* profile = parent->GetPrimaryOTRProfile(/*create_if_needed=*/true);
  if (profile->ShutdownStarted() || profile->GetUserData(kClosedProfileKey))
    return nullptr;
  auto* context = ChromeBrowserContext::GetOrCreateForProfile(profile);
  if (!context->IsInitialized()) {
    return nullptr;
  }
  return CefRequestContextImpl::GetOrCreateForBrowserContext(context, handler);
}

bool CefIsOpenProfileContextLive(CefRefPtr<CefRequestContext> context) {
  return LiveProfile(context) != nullptr;
}

bool CefSetOpenProfileHandler(CefRefPtr<CefRequestContext> context,
                              CefRefPtr<CefOpenProfileHandler> handler) {
  Profile* profile = LiveProfile(context);
  if (!profile) {
    return false;
  }
  if (handler) {
    Handlers()[profile] = handler;
  } else {
    Handlers().erase(profile);
  }
  return true;
}

bool CefClearOpenProfileBrowsingData(CefRefPtr<CefRequestContext> context,
                                     int kinds,
                                     double begin,
                                     double end,
                                     CefRefPtr<CefOpenProfileCallback> callback) {
  Profile* profile = LiveProfile(context);
  if (!profile || profile->ShutdownStarted() || profile->IsOffTheRecord() ||
      !callback || kinds <= 0 || (kinds & ~15) ||
      !std::isfinite(begin) || !std::isfinite(end) || begin >= end ||
      ClosingPaths().contains(profile->GetPath())) {
    return false;
  }
  // FromSecondsSinceUnixEpoch preserves 0 as a null Time for legacy WebKit
  // callers. Here 0 means the Unix epoch, as stated by this API's contract.
  const auto delete_begin = base::Time::UnixEpoch() + base::Seconds(begin);
  const auto delete_end = base::Time::UnixEpoch() + base::Seconds(end);
  if (delete_begin >= delete_end) {
    return false;
  }
  uint64_t mask = 0;
  if (kinds & 1) mask |= chrome_browsing_data_remover::DATA_TYPE_HISTORY;
  if (kinds & 2) mask |= chrome_browsing_data_remover::DATA_TYPE_SITE_DATA;
  if (kinds & 4) mask |= Remover::DATA_TYPE_CACHE;
  if (kinds & 8) mask |= Remover::DATA_TYPE_DOWNLOADS;
  auto* removal = new DataRemoval(profile, base::BindOnce(
      [](CefRefPtr<CefOpenProfileCallback> callback, uint64_t failed) {
        callback->OnComplete(failed ? "browsing-data-backend-failed" : "");
      }, callback));
  removal->Start(delete_begin, delete_end, mask);
  return true;
}

bool CefDeleteOpenProfile(CefRefPtr<CefRequestContext> context,
                          CefRefPtr<CefOpenProfileDeletionHandler> handler) {
  Profile* profile = LiveProfile(context);
  if (!profile || profile->ShutdownStarted() || !handler || profile->IsOffTheRecord() ||
      !profile->IsRegularProfile() || !g_browser_process ||
      !g_browser_process->profile_manager()) {
    return false;
  }
  auto* manager = g_browser_process->profile_manager();
  if (profile->GetPath() ==
      manager->user_data_dir().AppendASCII(chrome::kInitialProfile)) {
    return false;
  }
  if (!base::FeatureList::IsEnabled(features::kDestroyProfileOnBrowserClose)) {
    handler->OnComplete("profile-unload-feature-disabled");
    return true;
  }
  if (!ClosingPaths().insert(profile->GetPath()).second) {
    handler->OnComplete("profile-deletion-already-started");
    return true;
  }
  (new ProfileDeletion(profile, handler))->Start();
  return true;
}
