// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef OPEN_UNIFIED_BROWSER_OPEN_SLEEP_CONTROLLER_H_
#define OPEN_UNIFIED_BROWSER_OPEN_SLEEP_CONTROLLER_H_

#include <map>
#include <optional>
#include <set>
#include <string>

#include "base/functional/callback.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "base/timer/timer.h"
#include "base/values.h"
#include "open_unified/browser/open_tab_bridge.h"
#include "open_unified/core/model/open_types.h"
#include "open_unified/core/sleep/opnh_codec.h"
#include "open_unified/core/sleep/sleep_scheduler.h"
#include "url/gurl.h"

namespace content {
class WebContents;
}

namespace open_unified {

class OpenBrowserService;
struct SleepHistoryRecord;

// Connects Track 2's SleepScheduler to real pages (docs/plans/memory-fork.md,
// app-shell Step G). The scheduler owns the policy (Sleep mode delays,
// keep-alive sites, audio/media/devtools/form gates) and the model's
// SleepPhase; this controller performs each action on Chromium:
//
//   freeze   UpdateWebContentsVisibility(HIDDEN) + SetPageFrozen(true)
//   discard  OPNH v1 capture of the navigation history
//            (sessions::ContentSerializedNavigationBuilder pickles,
//            SleepStore), then WebContents::Discard() in place
//   destroy  the WebContents goes away (OpenTabBridge::UnloadTab); the tab
//            stays a placeholder
//   restore  unfreeze; a discarded page reloads from its restored history
//
// After a relaunch a tab has no WebContents; RestoreOrLoad() restores the
// saved OPNH record before the first load, so back/forward and scroll/form
// state survive. Loaded pages' histories are also saved at shutdown.
//
// One repeating tick (15 s) runs only while pages are loaded.
class OpenSleepController : public OpenTabBridge::Observer {
 public:
  explicit OpenSleepController(OpenBrowserService* service);
  ~OpenSleepController() override;

  OpenSleepController(const OpenSleepController&) = delete;
  OpenSleepController& operator=(const OpenSleepController&) = delete;

  void Start();
  void Shutdown();

  // OpenTabBridge calls this right after creating |contents| for |tab_id|.
  void RestoreOrLoad(const ItemID& tab_id,
                     content::WebContents* contents,
                     const GURL& fallback_url);

  // Hook 0006: may Chromium's own lifecycle discard |contents|?
  bool MayChromeDiscard(content::WebContents* contents) const;

  // Direct operations (automation `engine-sleep`, Site Control). Each
  // returns the resulting state (StateFor()) with "ok".
  base::DictValue Hide(const ItemID& tab_id);
  base::DictValue Show(const ItemID& tab_id);
  base::DictValue Freeze(const ItemID& tab_id);
  base::DictValue Unfreeze(const ItemID& tab_id);
  void Discard(const ItemID& tab_id,
               base::OnceCallback<void(base::DictValue)> done);
  // Captures without discarding; adds `history` (entries, currentIndex,
  // pageState, opnhBytes, urls, roundTrip through the OPNH codec).
  base::DictValue Capture(const ItemID& tab_id);
  base::DictValue StateFor(const ItemID& tab_id) const;

  // Runs the scheduler now (a setting changed, a tab was hidden).
  void Tick();

  // OpenTabBridge::Observer:
  void OnTabActivated(const ItemID& tab_id) override;
  void OnTabContentsAttached(const ItemID& tab_id,
                             content::WebContents* contents) override;
  void OnTabContentsDetaching(const ItemID& tab_id,
                              content::WebContents* contents) override;
  void OnTabPrimaryPageCommitted(const ItemID& tab_id,
                                 content::WebContents* contents) override;

 private:
  // SleepScheduler callbacks.
  bool DoFreeze(const ItemID& tab_id);
  bool DoDiscard(const ItemID& tab_id);
  void DoDestroy(const ItemID& tab_id);
  bool DoRestore(const ItemID& tab_id);

  std::optional<SleepHistoryRecord> CaptureHistory(
      const ItemID& tab_id,
      content::WebContents* contents) const;
  bool RestoreHistory(content::WebContents* contents,
                      const OpnhContainer& container) const;
  void SaveHistory(const ItemID& tab_id, content::WebContents* contents);
  void OnStoredHistory(base::WeakPtr<content::WebContents> contents,
                       GURL fallback_url,
                       std::optional<SleepHistoryRecord> record);
  bool IsKeepAlive(const ItemID& tab_id, content::WebContents* contents) const;
  SleepMode ModeForTab(const ItemID& tab_id) const;
  void UpdateTimer();

  raw_ptr<OpenBrowserService> service_;
  SleepScheduler scheduler_;
  std::map<ItemID, bool> audible_;
  base::RepeatingTimer tick_timer_;
  bool started_ = false;
  bool discarding_internally_ = false;
  base::WeakPtrFactory<OpenSleepController> weak_factory_{this};
};

}  // namespace open_unified

#endif  // OPEN_UNIFIED_BROWSER_OPEN_SLEEP_CONTROLLER_H_
