// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef OPEN_UNIFIED_BROWSER_OPEN_BROWSER_SERVICE_H_
#define OPEN_UNIFIED_BROWSER_OPEN_BROWSER_SERVICE_H_

#include <map>
#include <memory>
#include <optional>
#include <string>
#include <vector>

#include "base/files/file_path.h"
#include "base/functional/bind.h"
#include "base/functional/callback.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "base/observer_list.h"
#include "base/observer_list_types.h"
#include "base/sequence_checker.h"
#include "base/task/bind_post_task.h"
#include "base/task/sequenced_task_runner.h"
#include "base/threading/sequence_bound.h"
#include "base/values.h"
#include "open_unified/buildflags.h"
#include "open_unified/core/model/browser_model.h"
#include "open_unified/core/model/open_types.h"

class Profile;

namespace content {
class BrowserContext;
}

namespace open_unified {

class ArchiveStore;
class BoostStore;
class CommandRegistry;
class DocumentStore;
class DownloadHistoryStore;
class FaviconStore;
class HistoryStore;
class OpenAdBlockProfileService;
class OpenAutomationServer;
class OpenBoostController;
class OpenExtensionBridge;
class OpenSleepController;
class OpenTabBridge;
class OpenViewController;
class OpenWindowController;
class RoutingEvaluator;
class SleepStore;
class SnapshotStore;
class SuggestEngine;
class SyncEngine;

// Runs |task| with the store on the store's sequence and |reply| with the
// result on the calling sequence. The stores (SQLite, files) are not
// thread-safe and must not block the UI thread.
template <typename Store, typename Result>
void RunOnStore(const base::SequenceBound<Store>& store,
                base::OnceCallback<Result(Store*)> task,
                base::OnceCallback<void(Result)> reply) {
  store.PostTaskWithThisObject(base::BindOnce(
      [](base::OnceCallback<Result(Store*)> task,
         base::OnceCallback<void(Result)> reply, Store* object) {
        std::move(reply).Run(std::move(task).Run(object));
      },
      std::move(task), base::BindPostTaskToCurrentDefault(std::move(reply))));
}

// Fire-and-forget variant.
template <typename Store>
void RunOnStore(const base::SequenceBound<Store>& store,
                base::OnceCallback<void(Store*)> task) {
  store.PostTaskWithThisObject(std::move(task));
}

// Everything Open keeps per Open Profile. The Chromium Profile lives at
// <user data>/<Profile::data_directory_name>; Open's own files live under
// <user data>/Profiles/<data_directory_name>/{State,Documents} (macOS Open
// layout, docs/plans/profiles.md §5).
struct ProfileServices {
  ProfileServices();
  ~ProfileServices();
  ProfileServices(const ProfileServices&) = delete;
  ProfileServices& operator=(const ProfileServices&) = delete;

  ProfileID id;
  raw_ptr<::Profile> chrome_profile = nullptr;
  base::FilePath state_dir;

  // One sequence for every blocking store of the Profile.
  scoped_refptr<base::SequencedTaskRunner> store_runner;
  base::SequenceBound<HistoryStore> history;
  base::SequenceBound<ArchiveStore> archive;
  base::SequenceBound<SleepStore> sleep;
  base::SequenceBound<DownloadHistoryStore> downloads;
  base::SequenceBound<FaviconStore> favicons;
  base::SequenceBound<BoostStore> boosts;
  base::SequenceBound<DocumentStore> documents;

  // UI thread; network work runs on its own runner.
  std::unique_ptr<SyncEngine> sync;
  std::unique_ptr<OpenExtensionBridge> extensions;

  // The KeyedService of |chrome_profile| (owned by its factory).
  OpenAdBlockProfileService* adblock() const;
};

// Process-wide coordinator of Open on top of Chromium (Unified/PLAN.md §1).
// Created in PreBrowserStart() by OpenBrowserMainExtraParts (it loads
// State/browser.json while blocking is still allowed), started in
// PostBrowserStart(), destroyed in PostMainMessageLoopRun(); UI thread only.
class OpenBrowserService : public BrowserModel::Observer,
                           public BrowserModel::ArchiveSink {
 public:
  class Observer : public base::CheckedObserver {
   public:
    // Push events for open:// pages (open_ipc_contract.h kEvent*).
    virtual void OnOpenEvent(const std::string& event_name,
                             const base::Value& payload) {}
  };

  explicit OpenBrowserService(base::FilePath user_data_dir);
  ~OpenBrowserService() override;

  OpenBrowserService(const OpenBrowserService&) = delete;
  OpenBrowserService& operator=(const OpenBrowserService&) = delete;

  // The single instance, or null outside PreBrowserStart..Shutdown.
  static OpenBrowserService* Get();

  // Profiles, windows (adopting Chromium's startup Browser), sleep, Boosts,
  // automation; open://onboarding on a first run.
  void Start();
  // Saves browser.json, stops timers and servers, drops Profile services.
  void Shutdown();

  bool started() const { return started_; }
  bool is_first_run() const { return first_run_; }
  const base::FilePath& user_data_dir() const { return user_data_dir_; }

  BrowserModel& model() { return *model_; }
  const BrowserModel& model() const { return *model_; }
  CommandRegistry& commands() { return *commands_; }
  SuggestEngine& suggest() { return *suggest_; }
  RoutingEvaluator& routing() { return *routing_; }
  OpenTabBridge* tab_bridge() { return tab_bridge_.get(); }
  OpenSleepController* sleep_controller() { return sleep_controller_.get(); }
  OpenBoostController* boost_controller() { return boost_controller_.get(); }
  // Track 4's OpenViewController (hook 0002 passes it to
  // OpenBrowserView::Install) and the per-window Track 5 coordinators.
  OpenViewController* view_controller();
  OpenWindowController* window_controller() { return window_controller_.get(); }
  // Extension bridge of the active Profile.
  OpenExtensionBridge* extension_bridge();

  ProfileServices* ProfileServicesFor(const ProfileID& id);
  ProfileServices* ProfileServicesForBrowserContext(
      content::BrowserContext* context);
  ::Profile* ChromeProfileFor(const ProfileID& id);
  std::optional<ProfileID> OpenProfileIdFor(content::BrowserContext* context);
  ProfileID ActiveProfileId() const;
  WindowID MainWindowId() const;

  // Creates an Open Profile and its Chromium Profile directory; |done| runs
  // when the Chromium Profile is ready.
  void CreateProfile(const std::string& name,
                     std::optional<SpaceIcon> icon,
                     base::OnceCallback<void(ProfileID)> done);

  // Coalesced atomic write of browser.json.
  void ScheduleSave();
  // Writes keybindings.json after a shortcut change (off the UI thread).
  void PersistShortcuts();

  // A committed primary-page navigation (never for incognito). For the
  // active Profile it also refreshes the command bar's history feed.
  void RecordVisit(const ProfileID& profile_id,
                   const std::string& url,
                   const std::string& title,
                   bool typed);
  // Reloads SuggestEngine's history rows (the newest kRecentHistoryLimit
  // entries of the active Profile) from its HistoryStore on the store
  // sequence; after visits, deletions, imports and Profile switches.
  void RefreshRecentHistory();
  static constexpr int kRecentHistoryLimit = 500;

  void AddObserver(Observer* observer);
  void RemoveObserver(Observer* observer);
  void BroadcastEvent(const std::string& event_name, base::Value payload);

  bool onboarding_completed() const { return onboarding_completed_; }
  void MarkOnboardingCompleted();

  // BrowserModel::Observer:
  void OnTreeChanged(const TreeChange& change) override;

  // BrowserModel::ArchiveSink:
  void OnArchiveTabs(const std::vector<ArchivedTabRecord>& records) override;
  void OnDiscardArchived(const std::vector<ItemID>& ids) override;

 private:
  void LoadOrCreateState();
  void StartProfiles();
  std::unique_ptr<ProfileServices> CreateProfileServices(
      const Profile& profile,
      ::Profile* chrome_profile);
  void MaybeStartAutomationServer();
  void ConfigureSyncFromCommandLine();
  base::FilePath ChromeProfileDir(const Profile& profile) const;
  base::FilePath OpenProfileDir(const Profile& profile) const;
  void OnNewChromeProfileReady(ProfileID id,
                               base::OnceCallback<void(ProfileID)> done,
                               ::Profile* chrome_profile);
  void BroadcastStateChanged();
  void OnRecentHistoryLoaded(ProfileID profile_id,
                             uint64_t generation,
                             std::vector<HistoryEntry> entries);

  SEQUENCE_CHECKER(sequence_checker_);

  const base::FilePath user_data_dir_;
  bool started_ = false;
  bool first_run_ = false;
  bool onboarding_completed_ = false;
  bool state_event_pending_ = false;
  // The Profile whose history SuggestEngine holds, and the newest request
  // (older replies are dropped).
  ProfileID recent_history_profile_;
  uint64_t recent_history_generation_ = 0;

  std::unique_ptr<SnapshotStore> snapshot_store_;
  std::unique_ptr<BrowserModel> model_;
  std::unique_ptr<CommandRegistry> commands_;
  std::unique_ptr<SuggestEngine> suggest_;
  std::unique_ptr<RoutingEvaluator> routing_;
  scoped_refptr<base::SequencedTaskRunner> file_runner_;

  std::map<ProfileID, std::unique_ptr<ProfileServices>> profiles_;

  std::unique_ptr<OpenTabBridge> tab_bridge_;
  std::unique_ptr<OpenSleepController> sleep_controller_;
  std::unique_ptr<OpenBoostController> boost_controller_;
  std::unique_ptr<OpenWindowController> window_controller_;
#if BUILDFLAG(OPEN_ENABLE_AUTOMATION)
  std::unique_ptr<OpenAutomationServer> automation_server_;
#endif

  base::ObserverList<Observer> observers_;
  base::WeakPtrFactory<OpenBrowserService> weak_factory_{this};
};

}  // namespace open_unified

#endif  // OPEN_UNIFIED_BROWSER_OPEN_BROWSER_SERVICE_H_
