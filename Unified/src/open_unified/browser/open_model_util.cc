// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "open_unified/browser/open_model_util.h"

namespace open_unified::model_util {

namespace {

// Walks up through folders and splits to the section parent.
std::optional<NodeParent> SectionParent(const BrowserModel& model,
                                        const ItemID& id) {
  std::optional<NodeParent> parent = model.GetParent(id);
  for (int depth = 0; parent && depth < 64; ++depth) {
    switch (parent->kind) {
      case NodeParentKind::kFavorites:
      case NodeParentKind::kSpacePinned:
      case NodeParentKind::kSpaceToday:
        return parent;
      case NodeParentKind::kFolder:
      case NodeParentKind::kSplitPane:
        parent = model.GetParent(parent->owner_id);
        break;
    }
  }
  return std::nullopt;
}

void AppendNodeTabs(const std::vector<SidebarNode>& nodes,
                    std::vector<ItemID>* out) {
  for (const SidebarNode& node : nodes) {
    if (const Tab* tab = node.as_tab()) {
      out->push_back(tab->id);
    } else if (const Folder* folder = node.as_folder()) {
      AppendNodeTabs(folder->children, out);
    } else if (const Split* split = node.as_split()) {
      for (const Tab& pane : split->panes) {
        out->push_back(pane.id);
      }
    }
  }
}

}  // namespace

std::optional<SpaceID> SpaceOfNode(const BrowserModel& model,
                                   const ItemID& id) {
  std::optional<NodeParent> section = SectionParent(model, id);
  if (!section || section->kind == NodeParentKind::kFavorites) {
    return std::nullopt;
  }
  return section->owner_id;
}

std::optional<ProfileID> ProfileOfNode(const BrowserModel& model,
                                       const ItemID& id) {
  std::optional<NodeParent> section = SectionParent(model, id);
  if (!section) {
    return std::nullopt;
  }
  if (section->kind == NodeParentKind::kFavorites) {
    return section->owner_id;
  }
  const Space* space = model.FindSpace(section->owner_id);
  return space ? std::optional<ProfileID>(space->profile_id) : std::nullopt;
}

std::optional<NodeParentKind> SectionOfNode(const BrowserModel& model,
                                            const ItemID& id) {
  std::optional<NodeParent> section = SectionParent(model, id);
  return section ? std::optional<NodeParentKind>(section->kind)
                 : std::nullopt;
}

std::vector<ItemID> OrderedTabIds(const BrowserModel& model,
                                  const SpaceID& space_id) {
  std::vector<ItemID> ids;
  const Space* space = model.FindSpace(space_id);
  if (!space) {
    return ids;
  }
  if (const Profile* profile = model.FindProfile(space->profile_id)) {
    for (const Tab& favorite : profile->favorites) {
      ids.push_back(favorite.id);
    }
  }
  AppendNodeTabs(space->pinned, &ids);
  AppendNodeTabs(space->today, &ids);
  return ids;
}

bool UpdateLive(BrowserModel& model,
                const ItemID& tab_id,
                const std::function<void(TabLiveState&)>& mutate) {
  const Tab* tab = model.FindTab(tab_id);
  if (!tab) {
    return false;
  }
  TabLiveState live = tab->live_state;
  mutate(live);
  return model.UpdateTabLiveState(tab_id, live);
}

std::optional<SpaceID> FocusedSpace(const BrowserModel& model,
                                    const WindowID& window_id) {
  const BrowserWindowState* window = model.FindWindow(window_id);
  if (!window && !model.windows().empty()) {
    window = &model.windows().front();
  }
  if (!window || window->focused_space_id.empty()) {
    return std::nullopt;
  }
  return window->focused_space_id;
}

}  // namespace open_unified::model_util
