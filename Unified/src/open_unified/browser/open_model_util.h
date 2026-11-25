// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// Reads over BrowserModel (Track 2) that the browser layer needs and the
// model does not expose directly. All UI thread.

#ifndef OPEN_UNIFIED_BROWSER_OPEN_MODEL_UTIL_H_
#define OPEN_UNIFIED_BROWSER_OPEN_MODEL_UTIL_H_

#include <functional>
#include <optional>
#include <vector>

#include "open_unified/core/model/browser_model.h"
#include "open_unified/core/model/open_types.h"

namespace open_unified::model_util {

// The Space a node belongs to (through folders and splits); nullopt for a
// Favorite (Favorites belong to the Profile) or an unknown id.
std::optional<SpaceID> SpaceOfNode(const BrowserModel& model,
                                   const ItemID& id);
// The Profile a node belongs to (a Favorite's Profile, or its Space's).
std::optional<ProfileID> ProfileOfNode(const BrowserModel& model,
                                       const ItemID& id);
// kFavorites, kSpacePinned or kSpaceToday for a node at any depth.
std::optional<NodeParentKind> SectionOfNode(const BrowserModel& model,
                                            const ItemID& id);
// Favorites of the Space's Profile, then Pinned, then Today; folders
// depth-first (collapsed ones too) and split panes in order. The order of
// chrome.tabs indices and of automation `index`.
std::vector<ItemID> OrderedTabIds(const BrowserModel& model,
                                  const SpaceID& space_id);
// Copies the tab's live state, applies |mutate| and stores it through
// BrowserModel::UpdateTabLiveState (live state never dirties browser.json).
bool UpdateLive(BrowserModel& model,
                const ItemID& tab_id,
                const std::function<void(TabLiveState&)>& mutate);
// The focused Space of |window_id| (or of the first window).
std::optional<SpaceID> FocusedSpace(const BrowserModel& model,
                                    const WindowID& window_id);

}  // namespace open_unified::model_util

#endif  // OPEN_UNIFIED_BROWSER_OPEN_MODEL_UTIL_H_
