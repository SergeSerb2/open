// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef OPEN_UNIFIED_BROWSER_OPEN_BOOST_CONTROLLER_H_
#define OPEN_UNIFIED_BROWSER_OPEN_BOOST_CONTROLLER_H_

#include <map>
#include <optional>
#include <set>
#include <string>
#include <vector>

#include "base/functional/callback.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "base/timer/timer.h"
#include "base/unguessable_token.h"
#include "base/values.h"
#include "open_unified/browser/open_tab_bridge.h"
#include "open_unified/core/boosts/boost_store.h"
#include "open_unified/core/model/open_types.h"

namespace content {
class RenderFrameHost;
class WebContents;
}  // namespace content

namespace open_unified {

class OpenBrowserService;

// Applies Boosts (docs/boosts.md) to matching pages of non-incognito tabs:
//
// - The managed applier (color filter, font, text zoom/transform, saved
//   Zaps, custom CSS) runs in Open's isolated world
//   (ISOLATED_WORLD_ID_OPEN = 6, hook 0004): its state and Boost ids stay
//   private from page scripts; it owns one <style> element it re-inserts
//   after SPA swaps.
// - User-authored Boost JavaScript runs in the page's main world, as on
//   macOS (inserted as a script element by the applier, so it follows the
//   page's CSP for inline script).
// - Zap: StartZap() arms a picker in world 6 with a fresh session nonce.
//   The picker keeps the chosen element's selector in world-private state;
//   the browser collects it (polling only while a session is armed),
//   checks the boost id, nonce, selector length and that the selector
//   still matches, then saves it in the BoostStore. Navigation or Escape
//   ends the session; a page cannot forge a pick or replay an old nonce.
class OpenBoostController : public OpenTabBridge::Observer {
 public:
  explicit OpenBoostController(OpenBrowserService* service);
  ~OpenBoostController() override;

  OpenBoostController(const OpenBoostController&) = delete;
  OpenBoostController& operator=(const OpenBoostController&) = delete;

  // Re-reads the Profile's Boosts (after a WebUI edit or sync) and
  // re-applies them to its loaded pages.
  void ReloadBoosts(const ProfileID& profile_id);
  // Cached Boosts of a Profile (empty until the first load finishes).
  const std::vector<Boost>& BoostsFor(const ProfileID& profile_id);
  // Boosts that match |url| (enabled ones only).
  std::vector<Boost> MatchingBoosts(const ProfileID& profile_id,
                                    const GURL& url);

  // Arms Zap for |boost_id| in the active tab. Returns false when the
  // active page is not a matching, non-incognito http(s) page.
  bool StartZap(const std::string& boost_id, std::string* message);
  void CancelZap();
  bool zap_armed() const { return zap_.has_value(); }

  // Automation readback.
  base::DictValue StateForAutomation() const;

  // Generated stylesheet for |boosts| (exposed for automation readback).
  static std::string BuildStylesheet(const std::vector<Boost>& boosts);
  static bool HostMatches(const std::string& host, const std::string& pattern);

  // OpenTabBridge::Observer:
  void OnTabDocumentAvailable(const ItemID& tab_id,
                              content::WebContents* contents) override;
  void OnTabPrimaryPageCommitted(const ItemID& tab_id,
                                 content::WebContents* contents) override;

 private:
  struct ZapSession {
    std::string boost_id;
    ProfileID profile_id;
    ItemID tab_id;
    base::UnguessableToken nonce;
  };

  // |refresh|: Boosts changed while the page is open (also removes styles
  // of a Boost that no longer applies).
  void ApplyToContents(const ItemID& tab_id,
                       content::WebContents* contents,
                       bool refresh);
  void OnBoostsLoaded(const ProfileID& profile_id, std::vector<Boost> boosts);
  void PollZap();
  void OnZapResult(base::Value result);
  void OnZapSelectorChecked(std::string selector,
                            std::string label,
                            base::Value count);

  raw_ptr<OpenBrowserService> service_;
  std::map<ProfileID, std::vector<Boost>> boosts_;
  // Tabs whose current document has Boost styles applied.
  std::set<ItemID> boosted_tabs_;
  std::optional<ZapSession> zap_;
  base::RepeatingTimer zap_poll_;
  int applied_count_ = 0;
  base::WeakPtrFactory<OpenBoostController> weak_factory_{this};
};

}  // namespace open_unified

#endif  // OPEN_UNIFIED_BROWSER_OPEN_BOOST_CONTROLLER_H_
