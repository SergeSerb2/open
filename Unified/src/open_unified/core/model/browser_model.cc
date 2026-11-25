// Copyright 2026 The Open Authors. All rights reserved.

#include "open_unified/core/model/browser_model.h"

#include <algorithm>
#include <cmath>
#include <numeric>
#include <utility>

#include "base/strings/string_util.h"
#include "base/time/time.h"
#include "open_unified/core/model/uuid_util.h"

namespace open_unified {

namespace {

std::string LowerAscii(std::string_view input) {
  return base::ToLowerASCII(input);
}

std::string TrimAscii(std::string_view input) {
  std::string out;
  base::TrimWhitespaceASCII(input, base::TRIM_ALL, &out);
  return out;
}

// Extracts host + path for pinned URL comparison matching Swift's
// `tab.url.host != pinned.host || tab.url.path != pinned.path`.
std::pair<std::string, std::string> ExtractHostAndPath(std::string_view url) {
  size_t scheme_end = url.find("://");
  std::string_view rest =
      scheme_end != std::string_view::npos ? url.substr(scheme_end + 3) : url;
  // Strip query and fragment.
  size_t q = rest.find_first_of("?#");
  if (q != std::string_view::npos) {
    rest = rest.substr(0, q);
  }
  size_t slash = rest.find('/');
  std::string_view authority =
      slash != std::string_view::npos ? rest.substr(0, slash) : rest;
  std::string_view path =
      slash != std::string_view::npos ? rest.substr(slash) : "";
  // Strip userinfo if present.
  size_t at = authority.rfind('@');
  if (at != std::string_view::npos) {
    authority = authority.substr(at + 1);
  }
  // Strip port if not IPv6 bracketed.
  if (!authority.empty() && authority.front() != '[') {
    size_t colon = authority.rfind(':');
    if (colon != std::string_view::npos) {
      authority = authority.substr(0, colon);
    }
  }
  return {LowerAscii(authority), std::string(path)};
}

std::vector<double> EqualFractions(size_t count) {
  if (count == 0) {
    return {};
  }
  return std::vector<double>(count, 1.0 / static_cast<double>(count));
}

}  // namespace

std::string FormatArchiveLocation(const NodeParent& parent) {
  switch (parent.kind) {
    case NodeParentKind::kSpacePinned:
      return "pinned:" + parent.owner_id;
    case NodeParentKind::kSpaceToday:
      return "today:" + parent.owner_id;
    case NodeParentKind::kFolder:
      return "folder:" + parent.owner_id;
    case NodeParentKind::kFavorites:
      return "favorites:" + parent.owner_id;
    case NodeParentKind::kSplitPane:
      return "split:" + parent.owner_id;
  }
  return "today:" + parent.owner_id;
}

std::optional<NodeParent> ParseArchiveLocation(std::string_view location) {
  size_t colon = location.find(':');
  if (colon == std::string_view::npos) {
    return std::nullopt;
  }
  std::string_view prefix = location.substr(0, colon);
  std::string_view raw_id = location.substr(colon + 1);
  auto normalized = NormalizeUuid(raw_id);
  if (!normalized.has_value()) {
    return std::nullopt;
  }
  if (prefix == "pinned") {
    return NodeParent{NodeParentKind::kSpacePinned, *normalized};
  }
  if (prefix == "today") {
    return NodeParent{NodeParentKind::kSpaceToday, *normalized};
  }
  if (prefix == "folder") {
    return NodeParent{NodeParentKind::kFolder, *normalized};
  }
  if (prefix == "favorites") {
    return NodeParent{NodeParentKind::kFavorites, *normalized};
  }
  if (prefix == "split") {
    return NodeParent{NodeParentKind::kSplitPane, *normalized};
  }
  return std::nullopt;
}

std::optional<double> AutoArchiveSeconds(AutoArchiveInterval interval) {
  switch (interval) {
    case AutoArchiveInterval::kNever:
      return std::nullopt;
    case AutoArchiveInterval::kOneHour:
      return 3600.0;
    case AutoArchiveInterval::kSixHours:
      return 6.0 * 3600.0;
    case AutoArchiveInterval::kTwelveHours:
      return 12.0 * 3600.0;
    case AutoArchiveInterval::kTwentyFourHours:
      return 24.0 * 3600.0;
    case AutoArchiveInterval::kSevenDays:
      return 7.0 * 86400.0;
    case AutoArchiveInterval::kThirtyDays:
      return 30.0 * 86400.0;
  }
  return 12.0 * 3600.0;
}

BrowserModel::BrowserModel() = default;

BrowserModel::BrowserModel(std::vector<Profile> profiles,
                           std::vector<Space> spaces,
                           std::vector<BrowserWindowState> windows,
                           std::vector<RoutingRule> routing_rules,
                           RoutingDestination default_destination)
    : profiles_(std::move(profiles)),
      spaces_(std::move(spaces)),
      windows_(std::move(windows)),
      routing_rules_(std::move(routing_rules)),
      default_destination_(std::move(default_destination)) {
  RebuildIndex();
}

BrowserModel::~BrowserModel() = default;

void BrowserModel::EnsureDefaultWorkspace() {
  if (profiles_.empty()) {
    Profile p;
    p.id = GenerateUuidV4();
    p.name = "Default";
    p.data_directory_name = "Default";
    profiles_.push_back(std::move(p));
  }
  if (spaces_.empty()) {
    Space s;
    s.id = GenerateUuidV4();
    s.title = "Personal";
    s.profile_id = profiles_.front().id;
    s.theme.style = SpaceStyle{};
    spaces_.push_back(std::move(s));
  }
  if (windows_.empty()) {
    BrowserWindowState w;
    w.id = GenerateUuidV4();
    w.focused_space_id = spaces_.front().id;
    windows_.push_back(std::move(w));
  }
  RebuildIndex();
}

// --- Observers ---

void BrowserModel::AddObserver(Observer* observer) {
  if (!observer) {
    return;
  }
  if (std::find(observers_.begin(), observers_.end(), observer) ==
      observers_.end()) {
    observers_.push_back(observer);
  }
}

void BrowserModel::RemoveObserver(Observer* observer) {
  observers_.erase(std::remove(observers_.begin(), observers_.end(), observer),
                   observers_.end());
}

void BrowserModel::SetRoutingRules(std::vector<RoutingRule> rules) {
  routing_rules_ = std::move(rules);
  ++tree_revision_;
}

void BrowserModel::SetDefaultDestination(RoutingDestination destination) {
  default_destination_ = std::move(destination);
  ++tree_revision_;
}

// --- Helpers ---

TimestampSec BrowserModel::NowSec() {
  return base::Time::Now().InSecondsFSinceUnixEpoch();
}

bool BrowserModel::KeepsPinnedUrl(const std::optional<NodeParent>& section) {
  if (!section.has_value()) {
    return false;
  }
  return section->kind == NodeParentKind::kSpacePinned ||
         section->kind == NodeParentKind::kFavorites;
}

bool BrowserModel::LeftPinnedUrl(const Tab& tab) {
  if (!tab.pinned_url.has_value()) {
    return false;
  }
  return ExtractHostAndPath(tab.url) != ExtractHostAndPath(*tab.pinned_url);
}

void BrowserModel::Emit(const TreeChange& change) {
  ++tree_revision_;
  CommitVisibilityTransition();
  // Copy observer list in case a callback mutates observers_.
  auto snapshot = observers_;
  for (Observer* observer : snapshot) {
    observer->OnTreeChanged(change);
  }
}

void BrowserModel::PushUndo(std::string action_name,
                            std::function<bool(BrowserModel&)> undo,
                            std::function<bool(BrowserModel&)> redo) {
  CommitVisibilityTransition();
  if (is_undoing_or_redoing_) {
    return;
  }
  ++undo_generation_;
  redo_stack_.clear();
  undo_stack_.push_back(
      UndoStep{std::move(action_name), std::move(undo), std::move(redo)});
  if (undo_stack_.size() > kMaxUndoDepth) {
    undo_stack_.erase(undo_stack_.begin());
  }
}

bool BrowserModel::Undo() {
  if (undo_stack_.empty()) {
    return false;
  }
  UndoStep step = std::move(undo_stack_.back());
  undo_stack_.pop_back();
  is_undoing_or_redoing_ = true;
  bool ok = step.undo(*this);
  is_undoing_or_redoing_ = false;
  if (ok) {
    ++undo_generation_;
    CommitVisibilityTransition();
    redo_stack_.push_back(std::move(step));
  }
  return ok;
}

bool BrowserModel::Redo() {
  if (redo_stack_.empty()) {
    return false;
  }
  UndoStep step = std::move(redo_stack_.back());
  redo_stack_.pop_back();
  is_undoing_or_redoing_ = true;
  bool ok = step.redo(*this);
  is_undoing_or_redoing_ = false;
  if (ok) {
    ++undo_generation_;
    CommitVisibilityTransition();
    undo_stack_.push_back(std::move(step));
  }
  return ok;
}

std::optional<std::string> BrowserModel::UndoActionName() const {
  if (undo_stack_.empty()) {
    return std::nullopt;
  }
  return undo_stack_.back().action_name;
}

std::optional<std::string> BrowserModel::RedoActionName() const {
  if (redo_stack_.empty()) {
    return std::nullopt;
  }
  return redo_stack_.back().action_name;
}

void BrowserModel::ClearUndoHistory() {
  undo_stack_.clear();
  redo_stack_.clear();
}

std::set<ItemID> BrowserModel::ComputeShownTabIds() const {
  std::set<ItemID> shown;
  for (const BrowserWindowState& window : windows_) {
    auto it = window.selected_node_by_space.find(window.focused_space_id);
    if (it == window.selected_node_by_space.end()) {
      continue;
    }
    const ItemID& selected_id = it->second;
    if (!IsSelectable(selected_id, window.focused_space_id)) {
      continue;
    }
    if (const Split* split = FindSplit(selected_id)) {
      for (const Tab& pane : split->panes) {
        shown.insert(pane.id);
      }
    } else if (const Tab* tab = FindTab(selected_id)) {
      shown.insert(tab->id);
    }
  }
  return shown;
}

void BrowserModel::CommitVisibilityTransition() {
  std::set<ItemID> current = ComputeShownTabIds();
  TimestampSec now = 0.0;
  for (const ItemID& departed_id : shown_tab_ids_) {
    if (current.find(departed_id) == current.end()) {
      if (Tab* tab = FindTab(departed_id)) {
        if (now == 0.0) {
          now = NowSec();
        }
        tab->last_active_at = now;
      }
    }
  }
  shown_tab_ids_ = std::move(current);
}

void BrowserModel::StampVisibleTabs(const ItemID& node_id, TimestampSec now) {
  if (Split* split = FindSplit(node_id)) {
    for (Tab& pane : split->panes) {
      pane.last_active_at = now;
      pane.is_unread = false;
    }
  } else if (Tab* tab = FindTab(node_id)) {
    tab->last_active_at = now;
    tab->is_unread = false;
  }
}

// --- Index & Lookup ---

void BrowserModel::RebuildContainerIndexMaps() {
  profile_index_by_id_.clear();
  for (size_t i = 0; i < profiles_.size(); ++i) {
    profile_index_by_id_.emplace(profiles_[i].id, i);
  }
  space_index_by_id_.clear();
  for (size_t i = 0; i < spaces_.size(); ++i) {
    space_index_by_id_.emplace(spaces_[i].id, i);
  }
  window_index_by_id_.clear();
  for (size_t i = 0; i < windows_.size(); ++i) {
    window_index_by_id_.emplace(windows_[i].id, i);
  }
}

void BrowserModel::RebuildIndex() {
  ++tree_revision_;
  index_.clear();
  parent_by_id_.clear();
  RebuildContainerIndexMaps();
  for (const Profile& profile : profiles_) {
    unavailable_profile_dirs_.insert(LowerAscii(profile.data_directory_name));
    NodeParent fav_parent{NodeParentKind::kFavorites, profile.id};
    for (size_t i = 0; i < profile.favorites.size(); ++i) {
      RegisterTab(profile.favorites[i], fav_parent, i);
    }
  }
  for (const Space& space : spaces_) {
    NodeParent pinned_parent{NodeParentKind::kSpacePinned, space.id};
    for (size_t i = 0; i < space.pinned.size(); ++i) {
      RegisterSubtree(space.pinned[i], pinned_parent, i);
    }
    NodeParent today_parent{NodeParentKind::kSpaceToday, space.id};
    for (size_t i = 0; i < space.today.size(); ++i) {
      RegisterSubtree(space.today[i], today_parent, i);
    }
  }
  CommitVisibilityTransition();
}

void BrowserModel::RegisterSubtree(const SidebarNode& node,
                                   const NodeParent& parent,
                                   size_t index) {
  const ItemID& id = node.id();
  index_[id] = NodeIndexEntry{parent, index, node.kind()};
  parent_by_id_[id] = parent;
  if (const Folder* folder = node.as_folder()) {
    NodeParent folder_parent{NodeParentKind::kFolder, folder->id};
    for (size_t i = 0; i < folder->children.size(); ++i) {
      RegisterSubtree(folder->children[i], folder_parent, i);
    }
  } else if (const Split* split = node.as_split()) {
    NodeParent split_parent{NodeParentKind::kSplitPane, split->id};
    for (size_t i = 0; i < split->panes.size(); ++i) {
      RegisterTab(split->panes[i], split_parent, i);
    }
  }
}

void BrowserModel::RegisterTab(const Tab& tab,
                               const NodeParent& parent,
                               size_t index) {
  index_[tab.id] = NodeIndexEntry{parent, index, SidebarNode::Kind::kTab};
  parent_by_id_[tab.id] = parent;
}

void BrowserModel::UnregisterSubtree(const SidebarNode& node) {
  index_.erase(node.id());
  parent_by_id_.erase(node.id());
  if (const Folder* folder = node.as_folder()) {
    for (const SidebarNode& child : folder->children) {
      UnregisterSubtree(child);
    }
  } else if (const Split* split = node.as_split()) {
    for (const Tab& pane : split->panes) {
      UnregisterTab(pane);
    }
  }
}

void BrowserModel::UnregisterTab(const Tab& tab) {
  index_.erase(tab.id);
  parent_by_id_.erase(tab.id);
}

void BrowserModel::ReindexSiblings(const NodeParent& parent,
                                   size_t from_index) {
  if (const auto* nodes = GetNodeList(parent)) {
    for (size_t i = from_index; i < nodes->size(); ++i) {
      const ItemID& id = (*nodes)[i].id();
      index_[id] = NodeIndexEntry{parent, i, (*nodes)[i].kind()};
      parent_by_id_[id] = parent;
    }
  } else if (const auto* tabs = GetTabList(parent)) {
    for (size_t i = from_index; i < tabs->size(); ++i) {
      const ItemID& id = (*tabs)[i].id;
      index_[id] = NodeIndexEntry{parent, i, SidebarNode::Kind::kTab};
      parent_by_id_[id] = parent;
    }
  }
}

Profile* BrowserModel::FindProfile(const ProfileID& id) {
  auto it = profile_index_by_id_.find(id);
  if (it == profile_index_by_id_.end() || it->second >= profiles_.size()) {
    return nullptr;
  }
  return &profiles_[it->second];
}

const Profile* BrowserModel::FindProfile(const ProfileID& id) const {
  auto it = profile_index_by_id_.find(id);
  if (it == profile_index_by_id_.end() || it->second >= profiles_.size()) {
    return nullptr;
  }
  return &profiles_[it->second];
}

Space* BrowserModel::FindSpace(const SpaceID& id) {
  auto it = space_index_by_id_.find(id);
  if (it == space_index_by_id_.end() || it->second >= spaces_.size()) {
    return nullptr;
  }
  return &spaces_[it->second];
}

const Space* BrowserModel::FindSpace(const SpaceID& id) const {
  auto it = space_index_by_id_.find(id);
  if (it == space_index_by_id_.end() || it->second >= spaces_.size()) {
    return nullptr;
  }
  return &spaces_[it->second];
}

BrowserWindowState* BrowserModel::FindWindow(const WindowID& id) {
  auto it = window_index_by_id_.find(id);
  if (it == window_index_by_id_.end() || it->second >= windows_.size()) {
    return nullptr;
  }
  return &windows_[it->second];
}

const BrowserWindowState* BrowserModel::FindWindow(const WindowID& id) const {
  auto it = window_index_by_id_.find(id);
  if (it == window_index_by_id_.end() || it->second >= windows_.size()) {
    return nullptr;
  }
  return &windows_[it->second];
}

bool BrowserModel::HasNode(const ItemID& id) const {
  return index_.find(id) != index_.end();
}

std::optional<NodeParent> BrowserModel::GetParent(const ItemID& id) const {
  auto it = parent_by_id_.find(id);
  if (it == parent_by_id_.end()) {
    return std::nullopt;
  }
  return it->second;
}

std::optional<NodeIndexEntry> BrowserModel::GetIndexEntry(
    const ItemID& id) const {
  auto it = index_.find(id);
  if (it == index_.end()) {
    return std::nullopt;
  }
  return it->second;
}

std::vector<SidebarNode>* BrowserModel::GetNodeList(const NodeParent& parent) {
  switch (parent.kind) {
    case NodeParentKind::kSpacePinned: {
      Space* space = FindSpace(parent.owner_id);
      return space ? &space->pinned : nullptr;
    }
    case NodeParentKind::kSpaceToday: {
      Space* space = FindSpace(parent.owner_id);
      return space ? &space->today : nullptr;
    }
    case NodeParentKind::kFolder: {
      Folder* folder = FindFolder(parent.owner_id);
      return folder ? &folder->children : nullptr;
    }
    case NodeParentKind::kFavorites:
    case NodeParentKind::kSplitPane:
      return nullptr;
  }
  return nullptr;
}

const std::vector<SidebarNode>* BrowserModel::GetNodeList(
    const NodeParent& parent) const {
  switch (parent.kind) {
    case NodeParentKind::kSpacePinned: {
      const Space* space = FindSpace(parent.owner_id);
      return space ? &space->pinned : nullptr;
    }
    case NodeParentKind::kSpaceToday: {
      const Space* space = FindSpace(parent.owner_id);
      return space ? &space->today : nullptr;
    }
    case NodeParentKind::kFolder: {
      const Folder* folder = FindFolder(parent.owner_id);
      return folder ? &folder->children : nullptr;
    }
    case NodeParentKind::kFavorites:
    case NodeParentKind::kSplitPane:
      return nullptr;
  }
  return nullptr;
}

std::vector<Tab>* BrowserModel::GetTabList(const NodeParent& parent) {
  switch (parent.kind) {
    case NodeParentKind::kFavorites: {
      Profile* profile = FindProfile(parent.owner_id);
      return profile ? &profile->favorites : nullptr;
    }
    case NodeParentKind::kSplitPane: {
      Split* split = FindSplit(parent.owner_id);
      return split ? &split->panes : nullptr;
    }
    case NodeParentKind::kSpacePinned:
    case NodeParentKind::kSpaceToday:
    case NodeParentKind::kFolder:
      return nullptr;
  }
  return nullptr;
}

const std::vector<Tab>* BrowserModel::GetTabList(
    const NodeParent& parent) const {
  switch (parent.kind) {
    case NodeParentKind::kFavorites: {
      const Profile* profile = FindProfile(parent.owner_id);
      return profile ? &profile->favorites : nullptr;
    }
    case NodeParentKind::kSplitPane: {
      const Split* split = FindSplit(parent.owner_id);
      return split ? &split->panes : nullptr;
    }
    case NodeParentKind::kSpacePinned:
    case NodeParentKind::kSpaceToday:
    case NodeParentKind::kFolder:
      return nullptr;
  }
  return nullptr;
}

SidebarNode* BrowserModel::FindNode(const ItemID& id) {
  auto it = index_.find(id);
  if (it == index_.end()) {
    return nullptr;
  }
  const NodeIndexEntry& entry = it->second;
  auto* list = GetNodeList(entry.parent);
  if (!list || entry.index >= list->size()) {
    return nullptr;
  }
  return &(*list)[entry.index];
}

const SidebarNode* BrowserModel::FindNode(const ItemID& id) const {
  auto it = index_.find(id);
  if (it == index_.end()) {
    return nullptr;
  }
  const NodeIndexEntry& entry = it->second;
  const auto* list = GetNodeList(entry.parent);
  if (!list || entry.index >= list->size()) {
    return nullptr;
  }
  return &(*list)[entry.index];
}

Tab* BrowserModel::FindTab(const ItemID& id) {
  auto it = index_.find(id);
  if (it == index_.end() || it->second.kind != SidebarNode::Kind::kTab) {
    return nullptr;
  }
  const NodeIndexEntry& entry = it->second;
  if (entry.parent.kind == NodeParentKind::kFavorites ||
      entry.parent.kind == NodeParentKind::kSplitPane) {
    auto* list = GetTabList(entry.parent);
    if (!list || entry.index >= list->size()) {
      return nullptr;
    }
    return &(*list)[entry.index];
  }
  SidebarNode* node = FindNode(id);
  return node ? node->as_tab() : nullptr;
}

const Tab* BrowserModel::FindTab(const ItemID& id) const {
  auto it = index_.find(id);
  if (it == index_.end() || it->second.kind != SidebarNode::Kind::kTab) {
    return nullptr;
  }
  const NodeIndexEntry& entry = it->second;
  if (entry.parent.kind == NodeParentKind::kFavorites ||
      entry.parent.kind == NodeParentKind::kSplitPane) {
    const auto* list = GetTabList(entry.parent);
    if (!list || entry.index >= list->size()) {
      return nullptr;
    }
    return &(*list)[entry.index];
  }
  const SidebarNode* node = FindNode(id);
  return node ? node->as_tab() : nullptr;
}

Folder* BrowserModel::FindFolder(const ItemID& id) {
  auto it = index_.find(id);
  if (it == index_.end() || it->second.kind != SidebarNode::Kind::kFolder) {
    return nullptr;
  }
  SidebarNode* node = FindNode(id);
  return node ? node->as_folder() : nullptr;
}

const Folder* BrowserModel::FindFolder(const ItemID& id) const {
  auto it = index_.find(id);
  if (it == index_.end() || it->second.kind != SidebarNode::Kind::kFolder) {
    return nullptr;
  }
  const SidebarNode* node = FindNode(id);
  return node ? node->as_folder() : nullptr;
}

Split* BrowserModel::FindSplit(const ItemID& id) {
  auto it = index_.find(id);
  if (it == index_.end() || it->second.kind != SidebarNode::Kind::kSplit) {
    return nullptr;
  }
  SidebarNode* node = FindNode(id);
  return node ? node->as_split() : nullptr;
}

const Split* BrowserModel::FindSplit(const ItemID& id) const {
  auto it = index_.find(id);
  if (it == index_.end() || it->second.kind != SidebarNode::Kind::kSplit) {
    return nullptr;
  }
  const SidebarNode* node = FindNode(id);
  return node ? node->as_split() : nullptr;
}

std::optional<NodeParent> BrowserModel::SectionOf(
    const NodeParent& parent) const {
  NodeParent cursor = parent;
  int hops = 0;
  while (hops++ < 128) {
    switch (cursor.kind) {
      case NodeParentKind::kSpacePinned:
      case NodeParentKind::kSpaceToday:
      case NodeParentKind::kFavorites:
        return cursor;
      case NodeParentKind::kFolder:
      case NodeParentKind::kSplitPane: {
        auto it = parent_by_id_.find(cursor.owner_id);
        if (it == parent_by_id_.end()) {
          return std::nullopt;
        }
        cursor = it->second;
        break;
      }
    }
  }
  return std::nullopt;
}

std::pair<std::optional<SpaceID>, std::optional<ProfileID>>
BrowserModel::OwnerOf(const NodeParent& parent) const {
  auto sec = SectionOf(parent);
  if (!sec.has_value()) {
    return {std::nullopt, std::nullopt};
  }
  switch (sec->kind) {
    case NodeParentKind::kSpacePinned:
    case NodeParentKind::kSpaceToday: {
      const Space* space = FindSpace(sec->owner_id);
      return {sec->owner_id,
              space ? std::optional<ProfileID>(space->profile_id)
                    : std::nullopt};
    }
    case NodeParentKind::kFavorites:
      return {std::nullopt, sec->owner_id};
    case NodeParentKind::kFolder:
    case NodeParentKind::kSplitPane:
      return {std::nullopt, std::nullopt};
  }
  return {std::nullopt, std::nullopt};
}

std::optional<SpaceID> BrowserModel::TargetSpaceForProfile(
    const std::optional<ProfileID>& profile_id) const {
  if (profile_id.has_value()) {
    for (const BrowserWindowState& window : windows_) {
      if (const Space* focused = FindSpace(window.focused_space_id)) {
        if (focused->profile_id == *profile_id) {
          return focused->id;
        }
      }
    }
    for (const Space& space : spaces_) {
      if (space.profile_id == *profile_id) {
        return space.id;
      }
    }
  }
  if (!windows_.empty() && FindSpace(windows_.front().focused_space_id)) {
    return windows_.front().focused_space_id;
  }
  if (!spaces_.empty()) {
    return spaces_.front().id;
  }
  return std::nullopt;
}

bool BrowserModel::ParentExists(const NodeParent& parent) const {
  switch (parent.kind) {
    case NodeParentKind::kSpacePinned:
    case NodeParentKind::kSpaceToday:
      return FindSpace(parent.owner_id) != nullptr;
    case NodeParentKind::kFolder:
      return FindFolder(parent.owner_id) != nullptr;
    case NodeParentKind::kFavorites:
      return FindProfile(parent.owner_id) != nullptr;
    case NodeParentKind::kSplitPane:
      return FindSplit(parent.owner_id) != nullptr;
  }
  return false;
}

bool BrowserModel::IsPinned(const ItemID& tab_id) const {
  auto parent = GetParent(tab_id);
  if (!parent.has_value()) {
    return false;
  }
  auto sec = SectionOf(*parent);
  return sec.has_value() && sec->kind == NodeParentKind::kSpacePinned;
}

bool BrowserModel::IsFavorite(const ItemID& tab_id) const {
  auto parent = GetParent(tab_id);
  return parent.has_value() && parent->kind == NodeParentKind::kFavorites;
}

bool BrowserModel::IsSelectable(const ItemID& id,
                                const SpaceID& space_id) const {
  auto it = index_.find(id);
  if (it == index_.end() || it->second.kind == SidebarNode::Kind::kFolder) {
    return false;
  }
  const Space* space = FindSpace(space_id);
  if (!space) {
    return false;
  }
  auto sec = SectionOf(it->second.parent);
  if (!sec.has_value()) {
    return false;
  }
  if (sec->kind == NodeParentKind::kSpacePinned ||
      sec->kind == NodeParentKind::kSpaceToday) {
    return sec->owner_id == space->id;
  }
  if (sec->kind == NodeParentKind::kFavorites) {
    return sec->owner_id == space->profile_id;
  }
  return false;
}

std::optional<ItemID> BrowserModel::SelectedNodeId(
    const SpaceID& space_id,
    const WindowID& window_id) const {
  const BrowserWindowState* window = FindWindow(window_id);
  if (!window) {
    return std::nullopt;
  }
  auto it = window->selected_node_by_space.find(space_id);
  if (it == window->selected_node_by_space.end()) {
    return std::nullopt;
  }
  if (!IsSelectable(it->second, space_id)) {
    return std::nullopt;
  }
  return it->second;
}

std::optional<ItemID> BrowserModel::SidebarSelectionId(const ItemID& id) const {
  auto parent = GetParent(id);
  if (!parent.has_value()) {
    return std::nullopt;
  }
  if (parent->kind == NodeParentKind::kSplitPane) {
    return parent->owner_id;
  }
  return id;
}

std::string BrowserModel::DisplayTitleForSpace(const SpaceID& space_id) const {
  auto it = space_index_by_id_.find(space_id);
  if (it == space_index_by_id_.end()) {
    return "Space";
  }
  const Space& space = spaces_[it->second];
  if (space.title.has_value() && !space.title->empty()) {
    return *space.title;
  }
  return "Space " + std::to_string(it->second + 1);
}

std::optional<SpaceID> BrowserModel::MostRecentlyFocusedSpace(
    const ProfileID& profile_id) const {
  for (const SpaceID& id : focused_space_order_) {
    if (const Space* space = FindSpace(id)) {
      if (space->profile_id == profile_id) {
        return space->id;
      }
    }
  }
  for (const BrowserWindowState& window : windows_) {
    if (window.style != WindowStyle::kStandard) {
      continue;
    }
    if (const Space* space = FindSpace(window.focused_space_id)) {
      if (space->profile_id == profile_id) {
        return space->id;
      }
    }
  }
  for (const Space& space : spaces_) {
    if (space.profile_id == profile_id) {
      return space.id;
    }
  }
  return std::nullopt;
}

const Profile* BrowserModel::DefaultProfile() const {
  for (const Profile& profile : profiles_) {
    if (profile.data_directory_name == "Default") {
      return &profile;
    }
  }
  return profiles_.empty() ? nullptr : &profiles_.front();
}

bool BrowserModel::CanMoveNode(const ItemID& id,
                               const NodeParent& destination) const {
  auto it = index_.find(id);
  if (it == index_.end()) {
    return false;
  }
  const NodeIndexEntry& entry = it->second;
  if (entry.parent.kind == NodeParentKind::kSplitPane) {
    return false;
  }
  switch (destination.kind) {
    case NodeParentKind::kSplitPane:
      return false;
    case NodeParentKind::kFavorites:
      return entry.kind == SidebarNode::Kind::kTab &&
             FindProfile(destination.owner_id) != nullptr;
    case NodeParentKind::kSpacePinned:
    case NodeParentKind::kSpaceToday:
      return FindSpace(destination.owner_id) != nullptr;
    case NodeParentKind::kFolder: {
      if (!FindFolder(destination.owner_id)) {
        return false;
      }
      ItemID cursor = destination.owner_id;
      int hops = 0;
      while (hops++ < 128) {
        if (cursor == id) {
          return false;
        }
        auto pit = parent_by_id_.find(cursor);
        if (pit == parent_by_id_.end() ||
            pit->second.kind != NodeParentKind::kFolder) {
          break;
        }
        cursor = pit->second.owner_id;
      }
      return true;
    }
  }
  return false;
}

ProfileNameIssue BrowserModel::ValidateProfileName(
    const std::string& raw_name,
    const std::optional<ProfileID>& excluding_id) const {
  std::string name = TrimAscii(raw_name);
  if (name.empty()) {
    return ProfileNameIssue::kEmpty;
  }
  if (name.size() > 64) {
    return ProfileNameIssue::kTooLong;
  }
  if (name == "." || name == "..") {
    return ProfileNameIssue::kInvalidCharacters;
  }
  for (unsigned char c : name) {
    if (c == '/' || c == ':' || c == '\\' || c < 0x20 || c == 0x7F) {
      return ProfileNameIssue::kInvalidCharacters;
    }
  }
  std::string lower = LowerAscii(name);
  for (const Profile& profile : profiles_) {
    if (excluding_id.has_value() && profile.id == *excluding_id) {
      continue;
    }
    if (LowerAscii(TrimAscii(profile.name)) == lower) {
      return ProfileNameIssue::kDuplicate;
    }
  }
  return ProfileNameIssue::kNone;
}

ProfileDeleteBlock BrowserModel::GetProfileDeleteBlock(
    const ProfileID& id) const {
  if (!FindProfile(id)) {
    return ProfileDeleteBlock::kNone;
  }
  const Profile* def = DefaultProfile();
  if (def && def->id == id) {
    return ProfileDeleteBlock::kIsDefault;
  }
  for (const Space& space : spaces_) {
    if (space.profile_id == id) {
      return ProfileDeleteBlock::kSpacesAssigned;
    }
  }
  return ProfileDeleteBlock::kNone;
}

// --- Low-Level Primitives ---

std::optional<size_t> BrowserModel::AttachNode(SidebarNode node,
                                               const NodeParent& parent,
                                               std::optional<size_t> position) {
  if (HasNode(node.id())) {
    return std::nullopt;
  }
  const ItemID inserted_id = node.id();
  if (parent.kind == NodeParentKind::kFavorites ||
      parent.kind == NodeParentKind::kSplitPane) {
    Tab* tab = node.as_tab();
    if (!tab) {
      return std::nullopt;
    }
    auto* list = GetTabList(parent);
    if (!list) {
      return std::nullopt;
    }
    size_t pos =
        position.has_value() ? std::min(*position, list->size()) : list->size();
    list->insert(list->begin() + static_cast<std::ptrdiff_t>(pos),
                 std::move(*tab));
    RegisterTab((*list)[pos], parent, pos);
    ReindexSiblings(parent, pos + 1);
    TreeChange change;
    change.kind = TreeChange::Kind::kInsert;
    change.parent = parent;
    change.index = pos;
    change.node_id = inserted_id;
    Emit(change);
    return pos;
  }

  auto* list = GetNodeList(parent);
  if (!list) {
    return std::nullopt;
  }
  size_t pos =
      position.has_value() ? std::min(*position, list->size()) : list->size();
  list->insert(list->begin() + static_cast<std::ptrdiff_t>(pos),
               std::move(node));
  RegisterSubtree((*list)[pos], parent, pos);
  ReindexSiblings(parent, pos + 1);
  TreeChange change;
  change.kind = TreeChange::Kind::kInsert;
  change.parent = parent;
  change.index = pos;
  change.node_id = inserted_id;
  Emit(change);
  return pos;
}

std::optional<std::pair<SidebarNode, size_t>> BrowserModel::DetachNode(
    const ItemID& id) {
  auto it = index_.find(id);
  if (it == index_.end()) {
    return std::nullopt;
  }
  NodeParent parent = it->second.parent;
  size_t pos = it->second.index;

  if (parent.kind == NodeParentKind::kFavorites ||
      parent.kind == NodeParentKind::kSplitPane) {
    auto* list = GetTabList(parent);
    if (!list || pos >= list->size()) {
      return std::nullopt;
    }
    Tab removed_tab = std::move((*list)[pos]);
    list->erase(list->begin() + static_cast<std::ptrdiff_t>(pos));
    UnregisterTab(removed_tab);
    ReindexSiblings(parent, pos);
    TreeChange change;
    change.kind = TreeChange::Kind::kRemove;
    change.parent = parent;
    change.index = pos;
    change.node_id = id;
    Emit(change);
    return std::make_pair(SidebarNode(std::move(removed_tab)), pos);
  }

  auto* list = GetNodeList(parent);
  if (!list || pos >= list->size()) {
    return std::nullopt;
  }
  SidebarNode removed_node = std::move((*list)[pos]);
  list->erase(list->begin() + static_cast<std::ptrdiff_t>(pos));
  if (parent.kind == NodeParentKind::kFolder) {
    if (Folder* folder = FindFolder(parent.owner_id)) {
      if (folder->peeked_child_id == id) {
        folder->peeked_child_id.reset();
      }
    }
  }
  UnregisterSubtree(removed_node);
  ReindexSiblings(parent, pos);
  TreeChange change;
  change.kind = TreeChange::Kind::kRemove;
  change.parent = parent;
  change.index = pos;
  change.node_id = id;
  Emit(change);
  return std::make_pair(std::move(removed_node), pos);
}

std::vector<BrowserModel::SavedPinnedUrl> BrowserModel::ApplyPinnedRule(
    SidebarNode& node,
    const std::optional<NodeParent>& from_section,
    const std::optional<NodeParent>& to_section) {
  bool kept_before = KeepsPinnedUrl(from_section);
  bool keeps_after = KeepsPinnedUrl(to_section);
  std::vector<SavedPinnedUrl> prior;
  if (!kept_before && !keeps_after) {
    return prior;
  }
  auto apply_tab = [&](Tab& tab) {
    prior.push_back({tab.id, tab.pinned_url});
    if (keeps_after) {
      if (!tab.pinned_url.has_value()) {
        tab.pinned_url = tab.url;
      }
    } else {
      tab.pinned_url.reset();
    }
  };
  std::function<void(SidebarNode&)> visit = [&](SidebarNode& n) {
    if (Tab* tab = n.as_tab()) {
      apply_tab(*tab);
    } else if (Folder* folder = n.as_folder()) {
      for (SidebarNode& child : folder->children) {
        visit(child);
      }
    } else if (Split* split = n.as_split()) {
      for (Tab& pane : split->panes) {
        apply_tab(pane);
      }
    }
  };
  visit(node);
  return prior;
}

void BrowserModel::RestorePinnedUrls(
    const std::vector<SavedPinnedUrl>& saved) {
  for (const auto& entry : saved) {
    if (Tab* tab = FindTab(entry.tab_id)) {
      tab->pinned_url = entry.pinned_url;
    }
  }
}

void BrowserModel::CollectArchiveRecords(
    const SidebarNode& node,
    const NodeParent& parent,
    const std::string& reason,
    TimestampSec now,
    std::vector<ArchivedTabRecord>* out) const {
  auto [space_id, profile_id] = OwnerOf(parent);
  std::function<void(const SidebarNode&, const NodeParent&)> walk =
      [&](const SidebarNode& n, const NodeParent& p) {
        if (const Tab* tab = n.as_tab()) {
          ArchivedTabRecord rec;
          rec.id = tab->id;
          rec.url = tab->url;
          rec.title = tab->display_title();
          rec.space_id = space_id;
          rec.profile_id = profile_id;
          rec.archived_at = now;
          rec.reason = reason;
          rec.original_location = FormatArchiveLocation(p);
          rec.payload_json = "{}";
          rec.kind = "tab";
          out->push_back(std::move(rec));
        } else if (const Folder* folder = n.as_folder()) {
          NodeParent fp{NodeParentKind::kFolder, folder->id};
          for (const SidebarNode& child : folder->children) {
            if (folder->live.has_value() && child.as_tab() &&
                child.as_tab()->live_item_url.has_value()) {
              continue;
            }
            walk(child, fp);
          }
        } else if (const Split* split = n.as_split()) {
          NodeParent sp{NodeParentKind::kSplitPane, split->id};
          for (const Tab& pane : split->panes) {
            walk(SidebarNode(pane), sp);
          }
        }
      };
  walk(node, parent);
}

std::vector<BrowserModel::SelectionSlot> BrowserModel::RetargetSelections(
    const ItemID& old_id,
    const ItemID& new_id) {
  std::vector<SelectionSlot> moved;
  for (BrowserWindowState& window : windows_) {
    for (auto& [space_id, selected_id] : window.selected_node_by_space) {
      if (selected_id == old_id) {
        selected_id = new_id;
        moved.push_back({window.id, space_id});
      }
    }
  }
  return moved;
}

void BrowserModel::RestoreSelections(const std::vector<SelectionSlot>& slots,
                                     const ItemID& expected_current_id,
                                     const ItemID& restore_id) {
  for (const auto& slot : slots) {
    if (BrowserWindowState* window = FindWindow(slot.window_id)) {
      auto it = window->selected_node_by_space.find(slot.space_id);
      if (it != window->selected_node_by_space.end() &&
          it->second == expected_current_id) {
        it->second = restore_id;
      }
    }
  }
}

void BrowserModel::RecordFocusedSpace(const SpaceID& space_id) {
  focused_space_order_.erase(
      std::remove_if(focused_space_order_.begin(), focused_space_order_.end(),
                     [&](const SpaceID& id) {
                       return id == space_id || !FindSpace(id);
                     }),
      focused_space_order_.end());
  if (FindSpace(space_id)) {
    focused_space_order_.insert(focused_space_order_.begin(), space_id);
  }
}

SidebarNode BrowserModel::DeepCloneNode(const SidebarNode& node) {
  TimestampSec now = NowSec();
  auto clone_tab = [&](const Tab& t) {
    Tab copy;
    copy.id = GenerateUuidV4();
    copy.url = t.url;
    copy.title = t.title;
    copy.custom_title = t.custom_title;
    copy.pinned_url = t.pinned_url;
    copy.custom_icon = t.custom_icon;
    copy.icon_override = t.icon_override;
    copy.created_at = now;
    copy.last_active_at = now;
    copy.is_muted = t.is_muted;
    return copy;
  };
  if (const Tab* tab = node.as_tab()) {
    return SidebarNode(clone_tab(*tab));
  }
  if (const Folder* folder = node.as_folder()) {
    Folder copy;
    copy.id = GenerateUuidV4();
    copy.title = folder->title;
    copy.is_expanded = folder->is_expanded;
    copy.custom_icon = folder->custom_icon;
    copy.icon_override = folder->icon_override;
    for (const SidebarNode& child : folder->children) {
      SidebarNode cloned_child = DeepCloneNode(child);
      if (folder->peeked_child_id == child.id()) {
        copy.peeked_child_id = cloned_child.id();
      }
      copy.children.push_back(std::move(cloned_child));
    }
    return SidebarNode(std::move(copy));
  }
  const Split* split = node.as_split();
  Split copy;
  copy.id = GenerateUuidV4();
  copy.orientation = split->orientation;
  copy.fractions = split->fractions;
  copy.custom_title = split->custom_title;
  copy.icon_override = split->icon_override;
  for (const Tab& pane : split->panes) {
    Tab cloned_pane = clone_tab(pane);
    if (split->focused_pane_id == pane.id) {
      copy.focused_pane_id = cloned_pane.id;
    }
    copy.panes.push_back(std::move(cloned_pane));
  }
  return SidebarNode(std::move(copy));
}

// --- Tab & Tree Mutations ---

ItemID BrowserModel::NewTab(const SpaceID& space_id,
                            const std::string& url,
                            const std::string& title,
                            std::optional<size_t> position,
                            bool unread) {
  if (!FindSpace(space_id)) {
    return {};
  }
  TimestampSec now = NowSec();
  Tab tab;
  tab.id = GenerateUuidV4();
  tab.url = url;
  tab.title = title;
  tab.created_at = now;
  tab.last_active_at = now;
  tab.is_unread = unread;
  const ItemID id = tab.id;
  NodeParent parent{NodeParentKind::kSpaceToday, space_id};
  auto inserted_pos = AttachNode(SidebarNode(tab), parent, position.value_or(0));
  if (!inserted_pos.has_value()) {
    return {};
  }
  size_t slot = *inserted_pos;
  PushUndo(
      "New Tab",
      [id](BrowserModel& m) { return m.DetachNode(id).has_value(); },
      [tab, parent, slot](BrowserModel& m) {
        return m.AttachNode(SidebarNode(tab), parent, slot).has_value();
      });
  return id;
}

std::optional<BrowserModel::TakenPane> BrowserModel::TakePane(
    const ItemID& tab_id,
    const ItemID& split_id) {
  auto parent = GetParent(tab_id);
  if (!parent.has_value() || parent->kind != NodeParentKind::kSplitPane ||
      parent->owner_id != split_id) {
    return std::nullopt;
  }
  Split* split = FindSplit(split_id);
  if (!split) {
    return std::nullopt;
  }
  TakenPane taken;
  taken.previous_fractions = split->fractions;
  taken.previous_focused_pane_id = split->focused_pane_id;
  taken.split_metadata.id = split->id;
  taken.split_metadata.orientation = split->orientation;
  taken.split_metadata.custom_title = split->custom_title;
  taken.split_metadata.icon_override = split->icon_override;

  size_t prev_count = split->panes.size();
  auto detached = DetachNode(tab_id);
  if (!detached.has_value() || !detached->first.as_tab()) {
    return std::nullopt;
  }
  taken.tab = std::move(*detached->first.as_tab());
  taken.pane_index = detached->second;

  // Re-fetch split after DetachNode.
  split = FindSplit(split_id);
  if (!split) {
    return std::nullopt;
  }

  // Rebalance surviving fractions.
  std::vector<double> surviving;
  if (taken.previous_fractions.size() == prev_count) {
    bool valid = true;
    for (size_t i = 0; i < prev_count; ++i) {
      double f = taken.previous_fractions[i];
      if (!std::isfinite(f) || f < 0.0) {
        valid = false;
        break;
      }
      if (i != taken.pane_index) {
        surviving.push_back(f);
      }
    }
    if (!valid) {
      surviving.clear();
    }
  }
  double total = std::accumulate(surviving.begin(), surviving.end(), 0.0);
  if (std::isfinite(total) && total > 0.0) {
    for (double& f : surviving) {
      f /= total;
    }
    split->fractions = std::move(surviving);
  } else {
    split->fractions = EqualFractions(split->panes.size());
  }

  if (split->focused_pane_id == tab_id) {
    split->focused_pane_id =
        split->panes.empty() ? std::nullopt
                             : std::optional<ItemID>(split->panes.front().id);
  }

  // Collapse 1-pane split back to a lone tab.
  if (split->panes.size() == 1) {
    auto split_entry = GetIndexEntry(split_id);
    if (split_entry.has_value()) {
      NodeParent split_parent = split_entry->parent;
      size_t split_pos = split_entry->index;
      Tab remaining = std::move(split->panes.front());
      ItemID remaining_id = remaining.id;
      auto* parent_list = GetNodeList(split_parent);
      if (parent_list && split_pos < parent_list->size()) {
        index_.erase(split_id);
        parent_by_id_.erase(split_id);
        (*parent_list)[split_pos] = SidebarNode(std::move(remaining));
        index_[remaining_id] =
            NodeIndexEntry{split_parent, split_pos, SidebarNode::Kind::kTab};
        parent_by_id_[remaining_id] = split_parent;
        auto reselected = RetargetSelections(split_id, remaining_id);
        taken.collapsed =
            CollapseInfo{split_parent, remaining_id, std::move(reselected)};
        TreeChange reload;
        reload.kind = TreeChange::Kind::kReload;
        reload.parent = split_parent;
        Emit(reload);
      }
    }
  }
  return taken;
}

bool BrowserModel::RestoreTakenPane(const TakenPane& taken) {
  const ItemID& split_id = taken.split_metadata.id;
  if (taken.collapsed.has_value()) {
    const CollapseInfo& c = *taken.collapsed;
    auto rem_entry = GetIndexEntry(c.remaining_tab_id);
    if (!rem_entry.has_value() || !(rem_entry->parent == c.parent)) {
      return false;
    }
    auto* list = GetNodeList(c.parent);
    if (!list || rem_entry->index >= list->size()) {
      return false;
    }
    Tab* rem_tab = (*list)[rem_entry->index].as_tab();
    if (!rem_tab) {
      return false;
    }
    Split restored = taken.split_metadata;
    restored.panes.push_back(std::move(*rem_tab));
    (*list)[rem_entry->index] = SidebarNode(std::move(restored));
    index_[split_id] =
        NodeIndexEntry{c.parent, rem_entry->index, SidebarNode::Kind::kSplit};
    parent_by_id_[split_id] = c.parent;
    NodeParent sp{NodeParentKind::kSplitPane, split_id};
    index_[c.remaining_tab_id] =
        NodeIndexEntry{sp, 0, SidebarNode::Kind::kTab};
    parent_by_id_[c.remaining_tab_id] = sp;
    RestoreSelections(c.reselected, c.remaining_tab_id, split_id);
    TreeChange reload;
    reload.kind = TreeChange::Kind::kReload;
    reload.parent = c.parent;
    Emit(reload);
  }
  NodeParent sp{NodeParentKind::kSplitPane, split_id};
  if (!AttachNode(SidebarNode(taken.tab), sp, taken.pane_index).has_value()) {
    return false;
  }
  if (Split* split = FindSplit(split_id)) {
    split->fractions = taken.previous_fractions;
    split->focused_pane_id = taken.previous_focused_pane_id;
  }
  return true;
}

bool BrowserModel::CloseTab(const ItemID& id) {
  auto parent = GetParent(id);
  if (!parent.has_value()) {
    return false;
  }
  if (parent->kind == NodeParentKind::kSplitPane) {
    ItemID split_id = parent->owner_id;
    std::vector<ArchivedTabRecord> records;
    if (const Tab* tab = FindTab(id)) {
      CollectArchiveRecords(SidebarNode(*tab), *parent, "closed", NowSec(),
                            &records);
    }
    auto taken = TakePane(id, split_id);
    if (!taken.has_value()) {
      return false;
    }
    if (archive_sink_ && !records.empty()) {
      archive_sink_->OnArchiveTabs(records);
    }
    PushUndo(
        "Close Tab",
        [taken = *taken, id](BrowserModel& m) {
          if (!m.RestoreTakenPane(taken)) {
            return false;
          }
          if (m.archive_sink_) {
            m.archive_sink_->OnDiscardArchived({id});
          }
          return true;
        },
        [id, split_id](BrowserModel& m) {
          std::vector<ArchivedTabRecord> rec;
          if (const Tab* t = m.FindTab(id)) {
            m.CollectArchiveRecords(
                SidebarNode(*t),
                NodeParent{NodeParentKind::kSplitPane, split_id}, "closed",
                NowSec(), &rec);
          }
          if (!m.TakePane(id, split_id).has_value()) {
            return false;
          }
          if (m.archive_sink_ && !rec.empty()) {
            m.archive_sink_->OnArchiveTabs(rec);
          }
          return true;
        });
    return true;
  }

  std::vector<ArchivedTabRecord> records;
  if (const SidebarNode* node = FindNode(id)) {
    CollectArchiveRecords(*node, *parent, "closed", NowSec(), &records);
  } else if (const Tab* tab = FindTab(id)) {
    CollectArchiveRecords(SidebarNode(*tab), *parent, "closed", NowSec(),
                          &records);
  }

  auto detached = DetachNode(id);
  if (!detached.has_value()) {
    return false;
  }
  if (archive_sink_ && !records.empty()) {
    archive_sink_->OnArchiveTabs(records);
  }
  std::vector<ItemID> archived_ids;
  archived_ids.reserve(records.size());
  for (const auto& rec : records) {
    archived_ids.push_back(rec.id);
  }
  SidebarNode saved_node = std::move(detached->first);
  size_t saved_pos = detached->second;
  NodeParent saved_parent = *parent;

  PushUndo(
      "Close Tab",
      [saved_node, saved_parent, saved_pos, archived_ids](BrowserModel& m) {
        if (!m.AttachNode(saved_node, saved_parent, saved_pos).has_value()) {
          return false;
        }
        if (m.archive_sink_ && !archived_ids.empty()) {
          m.archive_sink_->OnDiscardArchived(archived_ids);
        }
        return true;
      },
      [id](BrowserModel& m) {
        auto p = m.GetParent(id);
        if (!p.has_value()) {
          return false;
        }
        std::vector<ArchivedTabRecord> rec;
        if (const SidebarNode* n = m.FindNode(id)) {
          m.CollectArchiveRecords(*n, *p, "closed", NowSec(), &rec);
        } else if (const Tab* t = m.FindTab(id)) {
          m.CollectArchiveRecords(SidebarNode(*t), *p, "closed", NowSec(),
                                  &rec);
        }
        if (!m.DetachNode(id).has_value()) {
          return false;
        }
        if (m.archive_sink_ && !rec.empty()) {
          m.archive_sink_->OnArchiveTabs(rec);
        }
        return true;
      });
  return true;
}

bool BrowserModel::PinTab(const ItemID& id) {
  auto parent = GetParent(id);
  if (!parent.has_value()) {
    return false;
  }
  auto sec = SectionOf(*parent);
  if (!sec.has_value()) {
    return false;
  }
  if (sec->kind == NodeParentKind::kSpaceToday) {
    return MoveNode(id, NodeParent{NodeParentKind::kSpacePinned, sec->owner_id},
                    std::nullopt);
  }
  if (sec->kind == NodeParentKind::kFavorites) {
    auto target = TargetSpaceForProfile(sec->owner_id);
    if (!target.has_value()) {
      return false;
    }
    return MoveNode(id, NodeParent{NodeParentKind::kSpacePinned, *target},
                    std::nullopt);
  }
  return false;
}

bool BrowserModel::UnpinTab(const ItemID& id) {
  auto parent = GetParent(id);
  if (!parent.has_value()) {
    return false;
  }
  auto sec = SectionOf(*parent);
  if (!sec.has_value() || sec->kind != NodeParentKind::kSpacePinned) {
    return false;
  }
  return MoveNode(id, NodeParent{NodeParentKind::kSpaceToday, sec->owner_id},
                  size_t{0});
}

bool BrowserModel::AddFavorite(const ItemID& tab_id,
                               const ProfileID& profile_id,
                               std::optional<size_t> position) {
  if (!FindTab(tab_id)) {
    return false;
  }
  NodeParent dest{NodeParentKind::kFavorites, profile_id};
  if (!position.has_value() && GetParent(tab_id) == dest) {
    return false;
  }
  return MoveNode(tab_id, dest, position);
}

bool BrowserModel::RemoveFavorite(const ItemID& tab_id,
                                  std::optional<SpaceID> into_space_id) {
  auto parent = GetParent(tab_id);
  if (!parent.has_value() || parent->kind != NodeParentKind::kFavorites) {
    return false;
  }
  auto target = into_space_id.has_value()
                    ? into_space_id
                    : TargetSpaceForProfile(parent->owner_id);
  if (!target.has_value()) {
    return false;
  }
  return MoveNode(tab_id, NodeParent{NodeParentKind::kSpaceToday, *target},
                  size_t{0});
}

bool BrowserModel::MoveNode(const ItemID& id,
                            const NodeParent& destination,
                            std::optional<size_t> position) {
  if (!CanMoveNode(id, destination)) {
    return false;
  }
  auto entry = GetIndexEntry(id);
  if (!entry.has_value()) {
    return false;
  }
  NodeParent source = entry->parent;
  size_t from_index = entry->index;
  auto from_section = SectionOf(source);
  auto to_section = SectionOf(destination);

  // Extract node from source without emitting remove/insert (emit single kMove).
  SidebarNode moved;
  if (source.kind == NodeParentKind::kFavorites) {
    auto* list = GetTabList(source);
    if (!list || from_index >= list->size()) {
      return false;
    }
    moved = SidebarNode(std::move((*list)[from_index]));
    list->erase(list->begin() + static_cast<std::ptrdiff_t>(from_index));
    ReindexSiblings(source, from_index);
  } else {
    auto* list = GetNodeList(source);
    if (!list || from_index >= list->size()) {
      return false;
    }
    moved = std::move((*list)[from_index]);
    list->erase(list->begin() + static_cast<std::ptrdiff_t>(from_index));
    if (source.kind == NodeParentKind::kFolder && !(source == destination)) {
      if (Folder* folder = FindFolder(source.owner_id)) {
        if (folder->peeked_child_id == id) {
          folder->peeked_child_id.reset();
        }
      }
    }
    ReindexSiblings(source, from_index);
  }

  auto prior_pinned = ApplyPinnedRule(moved, from_section, to_section);

  size_t to_index = 0;
  if (destination.kind == NodeParentKind::kFavorites) {
    auto* list = GetTabList(destination);
    Tab* tab = moved.as_tab();
    if (!list || !tab) {
      return false;
    }
    to_index =
        position.has_value() ? std::min(*position, list->size()) : list->size();
    list->insert(list->begin() + static_cast<std::ptrdiff_t>(to_index),
                 std::move(*tab));
    ReindexSiblings(destination, to_index);
  } else {
    auto* list = GetNodeList(destination);
    if (!list) {
      return false;
    }
    to_index =
        position.has_value() ? std::min(*position, list->size()) : list->size();
    list->insert(list->begin() + static_cast<std::ptrdiff_t>(to_index),
                 std::move(moved));
    ReindexSiblings(destination, to_index);
  }

  TreeChange change;
  change.kind = TreeChange::Kind::kMove;
  change.parent = source;
  change.index = from_index;
  change.to_parent = destination;
  change.to_index = to_index;
  change.node_id = id;
  Emit(change);

  PushUndo(
      "Move Item",
      [id, source, from_index, prior_pinned](BrowserModel& m) {
        if (!m.MoveNode(id, source, from_index)) {
          return false;
        }
        m.RestorePinnedUrls(prior_pinned);
        return true;
      },
      [id, destination, to_index](BrowserModel& m) {
        return m.MoveNode(id, destination, to_index);
      });
  return true;
}

ItemID BrowserModel::CreateFolder(const NodeParent& parent,
                                  const std::string& title,
                                  std::optional<size_t> position,
                                  const std::vector<ItemID>& node_ids) {
  if (parent.kind == NodeParentKind::kFavorites ||
      parent.kind == NodeParentKind::kSplitPane || !ParentExists(parent)) {
    return {};
  }
  Folder folder;
  folder.id = GenerateUuidV4();
  folder.title = title;
  folder.is_expanded = true;
  const ItemID folder_id = folder.id;

  auto slot = AttachNode(SidebarNode(std::move(folder)), parent, position);
  if (!slot.has_value()) {
    return {};
  }

  struct MovedItem {
    ItemID id;
    NodeParent source;
    size_t source_index;
    std::vector<SavedPinnedUrl> prior_pinned;
  };
  std::vector<MovedItem> moved_items;
  NodeParent folder_parent{NodeParentKind::kFolder, folder_id};

  bool prev_undoing = is_undoing_or_redoing_;
  is_undoing_or_redoing_ = true;
  for (const ItemID& item_id : node_ids) {
    if (!CanMoveNode(item_id, folder_parent)) {
      continue;
    }
    auto entry = GetIndexEntry(item_id);
    if (!entry.has_value()) {
      continue;
    }
    // Capture prior pinned URLs before moving.
    std::vector<SavedPinnedUrl> prior;
    if (const Tab* t = FindTab(item_id)) {
      prior.push_back({t->id, t->pinned_url});
    }
    if (MoveNode(item_id, folder_parent, std::nullopt)) {
      moved_items.push_back({item_id, entry->parent, entry->index, prior});
    }
  }
  is_undoing_or_redoing_ = prev_undoing;

  size_t folder_slot = *slot;
  PushUndo(
      "New Folder",
      [folder_id, parent, moved_items](BrowserModel& m) {
        if (m.GetParent(folder_id) != parent) {
          return false;
        }
        for (auto it = moved_items.rbegin(); it != moved_items.rend(); ++it) {
          if (m.GetParent(it->id) ==
              NodeParent{NodeParentKind::kFolder, folder_id}) {
            m.MoveNode(it->id, it->source, it->source_index);
            m.RestorePinnedUrls(it->prior_pinned);
          }
        }
        return m.DetachNode(folder_id).has_value();
      },
      [folder_id, parent, folder_slot, title, node_ids](BrowserModel& m) {
        Folder f;
        f.id = folder_id;
        f.title = title;
        f.is_expanded = true;
        if (!m.AttachNode(SidebarNode(std::move(f)), parent, folder_slot)
                 .has_value()) {
          return false;
        }
        NodeParent fp{NodeParentKind::kFolder, folder_id};
        for (const ItemID& nid : node_ids) {
          if (m.CanMoveNode(nid, fp)) {
            m.MoveNode(nid, fp, std::nullopt);
          }
        }
        return true;
      });
  return folder_id;
}

bool BrowserModel::RenameNode(const ItemID& id, const std::string& title) {
  if (Tab* tab = FindTab(id)) {
    std::optional<std::string> old_val = tab->custom_title;
    std::optional<std::string> new_val =
        title.empty() ? std::nullopt : std::optional<std::string>(title);
    if (old_val == new_val) {
      return false;
    }
    tab->custom_title = new_val;
    TreeChange change;
    change.kind = TreeChange::Kind::kUpdate;
    change.node_id = id;
    if (auto p = GetParent(id)) {
      change.parent = *p;
    }
    Emit(change);
    PushUndo(
        "Rename Tab",
        [id, old_val](BrowserModel& m) {
          Tab* t = m.FindTab(id);
          if (!t) return false;
          t->custom_title = old_val;
          TreeChange c;
          c.kind = TreeChange::Kind::kUpdate;
          c.node_id = id;
          m.Emit(c);
          return true;
        },
        [id, new_val](BrowserModel& m) {
          Tab* t = m.FindTab(id);
          if (!t) return false;
          t->custom_title = new_val;
          TreeChange c;
          c.kind = TreeChange::Kind::kUpdate;
          c.node_id = id;
          m.Emit(c);
          return true;
        });
    return true;
  }
  if (Split* split = FindSplit(id)) {
    std::optional<std::string> old_val = split->custom_title;
    std::optional<std::string> new_val =
        title.empty() ? std::nullopt : std::optional<std::string>(title);
    if (old_val == new_val) {
      return false;
    }
    split->custom_title = new_val;
    TreeChange change;
    change.kind = TreeChange::Kind::kUpdate;
    change.node_id = id;
    Emit(change);
    PushUndo(
        "Rename Split",
        [id, old_val](BrowserModel& m) {
          Split* s = m.FindSplit(id);
          if (!s) return false;
          s->custom_title = old_val;
          TreeChange c;
          c.kind = TreeChange::Kind::kUpdate;
          c.node_id = id;
          m.Emit(c);
          return true;
        },
        [id, new_val](BrowserModel& m) {
          Split* s = m.FindSplit(id);
          if (!s) return false;
          s->custom_title = new_val;
          TreeChange c;
          c.kind = TreeChange::Kind::kUpdate;
          c.node_id = id;
          m.Emit(c);
          return true;
        });
    return true;
  }
  if (Folder* folder = FindFolder(id)) {
    std::string old_val = folder->title;
    if (old_val == title) {
      return false;
    }
    folder->title = title;
    TreeChange change;
    change.kind = TreeChange::Kind::kUpdate;
    change.node_id = id;
    Emit(change);
    PushUndo(
        "Rename Folder",
        [id, old_val](BrowserModel& m) {
          Folder* f = m.FindFolder(id);
          if (!f) return false;
          f->title = old_val;
          TreeChange c;
          c.kind = TreeChange::Kind::kUpdate;
          c.node_id = id;
          m.Emit(c);
          return true;
        },
        [id, title](BrowserModel& m) {
          Folder* f = m.FindFolder(id);
          if (!f) return false;
          f->title = title;
          TreeChange c;
          c.kind = TreeChange::Kind::kUpdate;
          c.node_id = id;
          m.Emit(c);
          return true;
        });
    return true;
  }
  return false;
}

bool BrowserModel::SetFolderExpanded(const ItemID& folder_id, bool expanded) {
  Folder* folder = FindFolder(folder_id);
  if (!folder || folder->is_expanded == expanded) {
    return false;
  }
  bool old_val = folder->is_expanded;
  std::optional<ItemID> old_peek = folder->peeked_child_id;
  folder->is_expanded = expanded;
  folder->peeked_child_id.reset();
  TreeChange change;
  change.kind = TreeChange::Kind::kUpdate;
  change.node_id = folder_id;
  Emit(change);
  PushUndo(
      expanded ? "Expand Folder" : "Collapse Folder",
      [folder_id, old_val, old_peek](BrowserModel& m) {
        Folder* f = m.FindFolder(folder_id);
        if (!f) return false;
        f->is_expanded = old_val;
        f->peeked_child_id = old_peek;
        TreeChange c;
        c.kind = TreeChange::Kind::kUpdate;
        c.node_id = folder_id;
        m.Emit(c);
        return true;
      },
      [folder_id, expanded](BrowserModel& m) {
        Folder* f = m.FindFolder(folder_id);
        if (!f) return false;
        f->is_expanded = expanded;
        f->peeked_child_id.reset();
        TreeChange c;
        c.kind = TreeChange::Kind::kUpdate;
        c.node_id = folder_id;
        m.Emit(c);
        return true;
      });
  return true;
}

bool BrowserModel::SetPinnedCollapsed(const SpaceID& space_id, bool collapsed) {
  Space* space = FindSpace(space_id);
  if (!space || space->is_pinned_collapsed == collapsed) {
    return false;
  }
  bool old_val = space->is_pinned_collapsed;
  space->is_pinned_collapsed = collapsed;
  TreeChange change;
  change.kind = TreeChange::Kind::kUpdate;
  change.space_id = space_id;
  Emit(change);
  PushUndo(
      collapsed ? "Collapse Pinned" : "Expand Pinned",
      [space_id, old_val](BrowserModel& m) {
        Space* s = m.FindSpace(space_id);
        if (!s) return false;
        s->is_pinned_collapsed = old_val;
        TreeChange c;
        c.kind = TreeChange::Kind::kUpdate;
        c.space_id = space_id;
        m.Emit(c);
        return true;
      },
      [space_id, collapsed](BrowserModel& m) {
        Space* s = m.FindSpace(space_id);
        if (!s) return false;
        s->is_pinned_collapsed = collapsed;
        TreeChange c;
        c.kind = TreeChange::Kind::kUpdate;
        c.space_id = space_id;
        m.Emit(c);
        return true;
      });
  return true;
}

bool BrowserModel::SetMuted(const ItemID& tab_id, bool muted) {
  Tab* tab = FindTab(tab_id);
  if (!tab || tab->is_muted == muted) {
    return false;
  }
  bool old_val = tab->is_muted;
  tab->is_muted = muted;
  TreeChange change;
  change.kind = TreeChange::Kind::kUpdate;
  change.node_id = tab_id;
  Emit(change);
  PushUndo(
      muted ? "Mute Tab" : "Unmute Tab",
      [tab_id, old_val](BrowserModel& m) {
        Tab* t = m.FindTab(tab_id);
        if (!t) return false;
        t->is_muted = old_val;
        TreeChange c;
        c.kind = TreeChange::Kind::kUpdate;
        c.node_id = tab_id;
        m.Emit(c);
        return true;
      },
      [tab_id, muted](BrowserModel& m) {
        Tab* t = m.FindTab(tab_id);
        if (!t) return false;
        t->is_muted = muted;
        TreeChange c;
        c.kind = TreeChange::Kind::kUpdate;
        c.node_id = tab_id;
        m.Emit(c);
        return true;
      });
  return true;
}

ItemID BrowserModel::DuplicateNode(const ItemID& id,
                                   std::optional<SpaceID> into_space_id) {
  auto entry = GetIndexEntry(id);
  if (!entry.has_value()) {
    return {};
  }
  NodeParent dest = entry->parent;
  size_t insert_pos = entry->index + 1;

  SidebarNode cloned;
  if (entry->parent.kind == NodeParentKind::kFavorites) {
    const Tab* tab = FindTab(id);
    if (!tab) {
      return {};
    }
    auto target_space = into_space_id.has_value()
                            ? into_space_id
                            : TargetSpaceForProfile(entry->parent.owner_id);
    if (!target_space.has_value()) {
      return {};
    }
    dest = NodeParent{NodeParentKind::kSpaceToday, *target_space};
    insert_pos = 0;
    cloned = DeepCloneNode(SidebarNode(*tab));
    if (Tab* cloned_tab = cloned.as_tab()) {
      cloned_tab->pinned_url.reset();
    }
  } else if (entry->parent.kind == NodeParentKind::kSplitPane) {
    const Split* split = FindSplit(entry->parent.owner_id);
    const Tab* tab = FindTab(id);
    if (!split || !tab || split->panes.size() >= kMaxSplitPanes) {
      return {};
    }
    cloned = DeepCloneNode(SidebarNode(*tab));
  } else {
    const SidebarNode* src = FindNode(id);
    if (!src) {
      return {};
    }
    cloned = DeepCloneNode(*src);
  }

  std::vector<double> old_fractions;
  bool is_split_pane = (dest.kind == NodeParentKind::kSplitPane);
  if (is_split_pane) {
    if (const Split* s = FindSplit(dest.owner_id)) {
      old_fractions = s->fractions;
    }
  }

  ItemID cloned_id = cloned.id();
  SidebarNode copy_for_redo = cloned;
  auto actual_pos = AttachNode(std::move(cloned), dest, insert_pos);
  if (!actual_pos.has_value()) {
    return {};
  }
  if (is_split_pane) {
    if (Split* s = FindSplit(dest.owner_id)) {
      s->fractions = EqualFractions(s->panes.size());
    }
  }
  size_t slot = *actual_pos;
  PushUndo(
      "Duplicate",
      [cloned_id, is_split_pane, dest, old_fractions](BrowserModel& m) {
        if (!m.DetachNode(cloned_id).has_value()) {
          return false;
        }
        if (is_split_pane) {
          if (Split* s = m.FindSplit(dest.owner_id)) {
            s->fractions = old_fractions;
          }
        }
        return true;
      },
      [copy_for_redo, dest, slot, is_split_pane](BrowserModel& m) {
        if (!m.AttachNode(copy_for_redo, dest, slot).has_value()) {
          return false;
        }
        if (is_split_pane) {
          if (Split* s = m.FindSplit(dest.owner_id)) {
            s->fractions = EqualFractions(s->panes.size());
          }
        }
        return true;
      });
  return cloned_id;
}

std::vector<ItemID> BrowserModel::ResetPinnedTabs(const SpaceID& space_id) {
  Space* space = FindSpace(space_id);
  if (!space) {
    return {};
  }
  struct SavedTabUrl {
    ItemID id;
    std::string old_url;
    std::string pinned_url;
    TimestampSec old_active;
  };
  std::vector<SavedTabUrl> changed;
  TimestampSec now = NowSec();
  std::function<void(SidebarNode&)> walk = [&](SidebarNode& node) {
    if (Tab* tab = node.as_tab()) {
      if (LeftPinnedUrl(*tab)) {
        changed.push_back(
            {tab->id, tab->url, *tab->pinned_url, tab->last_active_at});
        tab->url = *tab->pinned_url;
        tab->last_active_at = now;
      }
    } else if (Folder* folder = node.as_folder()) {
      for (SidebarNode& child : folder->children) {
        walk(child);
      }
    } else if (Split* split = node.as_split()) {
      for (Tab& pane : split->panes) {
        if (LeftPinnedUrl(pane)) {
          changed.push_back(
              {pane.id, pane.url, *pane.pinned_url, pane.last_active_at});
          pane.url = *pane.pinned_url;
          pane.last_active_at = now;
        }
      }
    }
  };
  for (SidebarNode& node : space->pinned) {
    walk(node);
  }
  if (changed.empty()) {
    return {};
  }
  std::vector<ItemID> ids;
  ids.reserve(changed.size());
  for (const auto& entry : changed) {
    ids.push_back(entry.id);
    TreeChange c;
    c.kind = TreeChange::Kind::kUpdate;
    c.node_id = entry.id;
    Emit(c);
  }
  PushUndo(
      "Reset Pinned Tabs",
      [changed](BrowserModel& m) {
        for (const auto& entry : changed) {
          if (Tab* t = m.FindTab(entry.id)) {
            t->url = entry.old_url;
            t->last_active_at = entry.old_active;
            TreeChange c;
            c.kind = TreeChange::Kind::kUpdate;
            c.node_id = entry.id;
            m.Emit(c);
          }
        }
        return true;
      },
      [changed](BrowserModel& m) {
        TimestampSec tnow = NowSec();
        for (const auto& entry : changed) {
          if (Tab* t = m.FindTab(entry.id)) {
            t->url = entry.pinned_url;
            t->last_active_at = tnow;
            TreeChange c;
            c.kind = TreeChange::Kind::kUpdate;
            c.node_id = entry.id;
            m.Emit(c);
          }
        }
        return true;
      });
  return ids;
}

bool BrowserModel::ResetPinnedTab(const ItemID& tab_id) {
  Tab* tab = FindTab(tab_id);
  if (!tab || !tab->pinned_url.has_value() || tab->url == *tab->pinned_url) {
    return false;
  }
  std::string old_url = tab->url;
  std::string pinned_url = *tab->pinned_url;
  tab->url = pinned_url;
  tab->last_active_at = NowSec();
  TreeChange c;
  c.kind = TreeChange::Kind::kUpdate;
  c.node_id = tab_id;
  Emit(c);
  PushUndo(
      "Reset Tab",
      [tab_id, old_url](BrowserModel& m) {
        Tab* t = m.FindTab(tab_id);
        if (!t) return false;
        t->url = old_url;
        TreeChange ch;
        ch.kind = TreeChange::Kind::kUpdate;
        ch.node_id = tab_id;
        m.Emit(ch);
        return true;
      },
      [tab_id, pinned_url](BrowserModel& m) {
        Tab* t = m.FindTab(tab_id);
        if (!t) return false;
        t->url = pinned_url;
        TreeChange ch;
        ch.kind = TreeChange::Kind::kUpdate;
        ch.node_id = tab_id;
        m.Emit(ch);
        return true;
      });
  return true;
}

ItemID BrowserModel::RestoreArchivedTab(const ArchivedTabRecord& record) {
  if (HasNode(record.id)) {
    return record.id;
  }
  TimestampSec now = NowSec();
  Tab tab;
  tab.id = record.id.empty() ? GenerateUuidV4() : record.id;
  tab.url = record.url.empty() ? "about:blank" : record.url;
  tab.title = record.title;
  tab.created_at = record.archived_at > 0.0 ? record.archived_at : now;
  tab.last_active_at = now;

  // Choose destination: original parent (if valid & split < 4 panes), else
  // original space Today, else target space Today.
  std::optional<NodeParent> dest;
  auto original = ParseArchiveLocation(record.original_location);
  if (original.has_value() && ParentExists(*original)) {
    if (original->kind == NodeParentKind::kSplitPane) {
      if (const Split* s = FindSplit(original->owner_id);
          s && s->panes.size() < kMaxSplitPanes) {
        dest = *original;
      }
    } else {
      dest = *original;
    }
  }
  if (!dest.has_value()) {
    if (record.space_id.has_value() && FindSpace(*record.space_id)) {
      dest = NodeParent{NodeParentKind::kSpaceToday, *record.space_id};
    } else if (auto target = TargetSpaceForProfile(record.profile_id)) {
      dest = NodeParent{NodeParentKind::kSpaceToday, *target};
    }
  }
  if (!dest.has_value()) {
    return {};
  }

  if (KeepsPinnedUrl(SectionOf(*dest))) {
    tab.pinned_url = tab.url;
  } else {
    tab.pinned_url.reset();
  }

  std::optional<size_t> pos =
      (dest->kind == NodeParentKind::kSplitPane) ? std::nullopt
                                                 : std::optional<size_t>(0);
  ItemID tab_id = tab.id;
  if (!AttachNode(SidebarNode(tab), *dest, pos).has_value()) {
    return {};
  }
  if (dest->kind == NodeParentKind::kSplitPane) {
    if (Split* s = FindSplit(dest->owner_id)) {
      s->fractions = EqualFractions(s->panes.size());
    }
  }
  if (archive_sink_) {
    archive_sink_->OnDiscardArchived({tab_id});
  }
  PushUndo(
      "Restore Tab",
      [tab_id, record](BrowserModel& m) {
        auto p = m.GetParent(tab_id);
        if (!p.has_value()) return false;
        if (p->kind == NodeParentKind::kSplitPane) {
          if (!m.TakePane(tab_id, p->owner_id).has_value()) return false;
        } else {
          if (!m.DetachNode(tab_id).has_value()) return false;
        }
        if (m.archive_sink_) {
          m.archive_sink_->OnArchiveTabs({record});
        }
        return true;
      },
      [record](BrowserModel& m) {
        return !m.RestoreArchivedTab(record).empty();
      });
  return tab_id;
}

// --- Split View Mutations ---

ItemID BrowserModel::MakeSplit(const std::vector<ItemID>& tab_ids,
                               SplitOrientation orientation) {
  if (tab_ids.size() < 2 || tab_ids.size() > kMaxSplitPanes) {
    return {};
  }
  std::set<ItemID> unique_ids(tab_ids.begin(), tab_ids.end());
  if (unique_ids.size() != tab_ids.size()) {
    return {};
  }
  for (const ItemID& id : tab_ids) {
    auto entry = GetIndexEntry(id);
    if (!entry.has_value() || entry->kind != SidebarNode::Kind::kTab) {
      return {};
    }
    if (entry->parent.kind == NodeParentKind::kFavorites ||
        entry->parent.kind == NodeParentKind::kSplitPane) {
      return {};
    }
  }

  auto first_entry = GetIndexEntry(tab_ids.front());
  if (!first_entry.has_value()) {
    return {};
  }
  NodeParent home = first_entry->parent;
  size_t home_slot = first_entry->index;
  auto home_section = SectionOf(home);

  struct Origin {
    ItemID tab_id;
    NodeParent parent;
    size_t index;
    std::optional<std::string> prior_pinned_url;
  };
  std::vector<Origin> origins;
  std::vector<NodeParent> changed_parents = {home};

  Split split;
  split.id = GenerateUuidV4();
  split.orientation = orientation;
  split.fractions = EqualFractions(tab_ids.size());
  split.focused_pane_id = tab_ids.front();
  const ItemID split_id = split.id;

  // Insert empty split at first tab's slot, then move each tab into split.panes.
  auto* home_list = GetNodeList(home);
  if (!home_list || home_slot > home_list->size()) {
    return {};
  }
  home_list->insert(home_list->begin() + static_cast<std::ptrdiff_t>(home_slot),
                    SidebarNode(std::move(split)));
  ReindexSiblings(home, home_slot);

  for (const ItemID& tid : tab_ids) {
    auto e = GetIndexEntry(tid);
    if (!e.has_value()) {
      continue;
    }
    NodeParent src = e->parent;
    size_t src_idx = e->index;
    auto* src_list = GetNodeList(src);
    if (!src_list || src_idx >= src_list->size() || !(*src_list)[src_idx].as_tab()) {
      continue;
    }
    Tab tab = std::move(*(*src_list)[src_idx].as_tab());
    src_list->erase(src_list->begin() + static_cast<std::ptrdiff_t>(src_idx));
    ReindexSiblings(src, src_idx);

    std::optional<std::string> prior_pinned = tab.pinned_url;
    SidebarNode wrapper(std::move(tab));
    ApplyPinnedRule(wrapper, SectionOf(src), home_section);
    Tab moved_tab = std::move(*wrapper.as_tab());

    Split* live_split = FindSplit(split_id);
    if (!live_split) {
      return {};
    }
    size_t pane_idx = live_split->panes.size();
    live_split->panes.push_back(std::move(moved_tab));
    NodeParent sp{NodeParentKind::kSplitPane, split_id};
    index_[tid] = NodeIndexEntry{sp, pane_idx, SidebarNode::Kind::kTab};
    parent_by_id_[tid] = sp;
    origins.push_back({tid, src, src_idx, prior_pinned});
    if (std::find(changed_parents.begin(), changed_parents.end(), src) ==
        changed_parents.end()) {
      changed_parents.push_back(src);
    }
  }

  std::vector<std::pair<SelectionSlot, ItemID>> reselected;
  for (const auto& origin : origins) {
    for (const auto& slot : RetargetSelections(origin.tab_id, split_id)) {
      reselected.push_back({slot, origin.tab_id});
    }
  }

  for (const NodeParent& p : changed_parents) {
    TreeChange reload;
    reload.kind = TreeChange::Kind::kReload;
    reload.parent = p;
    Emit(reload);
  }

  PushUndo(
      "Create Split View",
      [split_id, origins, changed_parents, reselected](BrowserModel& m) {
        if (!m.FindSplit(split_id)) {
          return false;
        }
        for (const auto& [slot, tid] : reselected) {
          m.RestoreSelections({slot}, split_id, tid);
        }
        // Extract panes in reverse order back to original parents.
        for (auto it = origins.rbegin(); it != origins.rend(); ++it) {
          auto e = m.GetIndexEntry(it->tab_id);
          if (!e.has_value() || e->parent.kind != NodeParentKind::kSplitPane ||
              e->parent.owner_id != split_id) {
            continue;
          }
          Split* sp = m.FindSplit(split_id);
          if (!sp || e->index >= sp->panes.size()) continue;
          Tab tab = std::move(sp->panes[e->index]);
          tab.pinned_url = it->prior_pinned_url;
          sp->panes.erase(sp->panes.begin() +
                          static_cast<std::ptrdiff_t>(e->index));
          m.ReindexSiblings(NodeParent{NodeParentKind::kSplitPane, split_id},
                            e->index);
          if (auto* dst = m.GetNodeList(it->parent)) {
            size_t pos = std::min(it->index, dst->size());
            dst->insert(dst->begin() + static_cast<std::ptrdiff_t>(pos),
                        SidebarNode(std::move(tab)));
            m.ReindexSiblings(it->parent, pos);
          }
        }
        if (auto se = m.GetIndexEntry(split_id)) {
          if (auto* hl = m.GetNodeList(se->parent)) {
            hl->erase(hl->begin() + static_cast<std::ptrdiff_t>(se->index));
            m.index_.erase(split_id);
            m.parent_by_id_.erase(split_id);
            m.ReindexSiblings(se->parent, se->index);
          }
        }
        for (const NodeParent& p : changed_parents) {
          TreeChange reload;
          reload.kind = TreeChange::Kind::kReload;
          reload.parent = p;
          m.Emit(reload);
        }
        return true;
      },
      [tab_ids, orientation](BrowserModel& m) {
        return !m.MakeSplit(tab_ids, orientation).empty();
      });
  return split_id;
}

bool BrowserModel::Unsplit(const ItemID& split_id) {
  auto entry = GetIndexEntry(split_id);
  if (!entry.has_value() || entry->kind != SidebarNode::Kind::kSplit) {
    return false;
  }
  NodeParent parent = entry->parent;
  size_t pos = entry->index;
  auto* list = GetNodeList(parent);
  if (!list || pos >= list->size()) {
    return false;
  }
  Split split = std::move(*(*list)[pos].as_split());
  list->erase(list->begin() + static_cast<std::ptrdiff_t>(pos));
  index_.erase(split_id);
  parent_by_id_.erase(split_id);

  std::vector<ItemID> pane_ids;
  pane_ids.reserve(split.panes.size());
  ItemID survivor_id;
  for (size_t i = 0; i < split.panes.size(); ++i) {
    const ItemID& pid = split.panes[i].id;
    pane_ids.push_back(pid);
    if (split.focused_pane_id == pid) {
      survivor_id = pid;
    }
    list->insert(list->begin() + static_cast<std::ptrdiff_t>(pos + i),
                 SidebarNode(std::move(split.panes[i])));
  }
  if (survivor_id.empty() && !pane_ids.empty()) {
    survivor_id = pane_ids.front();
  }
  ReindexSiblings(parent, pos);
  auto reselected = survivor_id.empty()
                        ? std::vector<SelectionSlot>{}
                        : RetargetSelections(split_id, survivor_id);

  TreeChange reload;
  reload.kind = TreeChange::Kind::kReload;
  reload.parent = parent;
  Emit(reload);

  SplitOrientation orientation = split.orientation;
  std::vector<double> fractions = split.fractions;
  std::optional<ItemID> focused = split.focused_pane_id;
  std::optional<std::string> custom_title = split.custom_title;
  std::optional<SpaceIcon> icon_override = split.icon_override;

  PushUndo(
      "Unsplit",
      [split_id, parent, pane_ids, orientation, fractions, focused,
       custom_title, icon_override, reselected, survivor_id](BrowserModel& m) {
        std::vector<ItemID> present;
        for (const ItemID& pid : pane_ids) {
          if (m.GetParent(pid) == parent) {
            present.push_back(pid);
          }
        }
        if (present.size() < 2 || m.HasNode(split_id)) {
          return false;
        }
        auto first_entry = m.GetIndexEntry(present.front());
        if (!first_entry.has_value()) return false;
        size_t slot = first_entry->index;
        auto* l = m.GetNodeList(parent);
        if (!l) return false;
        Split restored;
        restored.id = split_id;
        restored.orientation = orientation;
        restored.fractions =
            present.size() == pane_ids.size() ? fractions : EqualFractions(present.size());
        restored.focused_pane_id = focused;
        restored.custom_title = custom_title;
        restored.icon_override = icon_override;
        for (const ItemID& pid : present) {
          auto pe = m.GetIndexEntry(pid);
          if (!pe.has_value()) continue;
          Tab t = std::move(*(*l)[pe->index].as_tab());
          l->erase(l->begin() + static_cast<std::ptrdiff_t>(pe->index));
          m.ReindexSiblings(parent, pe->index);
          restored.panes.push_back(std::move(t));
        }
        slot = std::min(slot, l->size());
        l->insert(l->begin() + static_cast<std::ptrdiff_t>(slot),
                  SidebarNode(std::move(restored)));
        m.RegisterSubtree((*l)[slot], parent, slot);
        m.ReindexSiblings(parent, slot + 1);
        if (!survivor_id.empty()) {
          m.RestoreSelections(reselected, survivor_id, split_id);
        }
        TreeChange r;
        r.kind = TreeChange::Kind::kReload;
        r.parent = parent;
        m.Emit(r);
        return true;
      },
      [split_id](BrowserModel& m) { return m.Unsplit(split_id); });
  return true;
}

bool BrowserModel::AddPane(const ItemID& split_id,
                           const ItemID& tab_id,
                           std::optional<size_t> position) {
  Split* split = FindSplit(split_id);
  auto tab_entry = GetIndexEntry(tab_id);
  auto split_entry = GetIndexEntry(split_id);
  if (!split || split->panes.size() >= kMaxSplitPanes || !tab_entry.has_value() ||
      tab_entry->kind != SidebarNode::Kind::kTab || !split_entry.has_value()) {
    return false;
  }
  NodeParent src = tab_entry->parent;
  if (src.kind == NodeParentKind::kFavorites ||
      src.kind == NodeParentKind::kSplitPane) {
    return false;
  }
  size_t src_idx = tab_entry->index;
  NodeParent home = split_entry->parent;
  std::vector<double> old_fractions = split->fractions;
  std::optional<ItemID> old_focus = split->focused_pane_id;

  auto* src_list = GetNodeList(src);
  if (!src_list || src_idx >= src_list->size()) {
    return false;
  }
  Tab tab = std::move(*(*src_list)[src_idx].as_tab());
  src_list->erase(src_list->begin() + static_cast<std::ptrdiff_t>(src_idx));
  ReindexSiblings(src, src_idx);

  std::optional<std::string> prior_pinned = tab.pinned_url;
  SidebarNode wrapper(std::move(tab));
  ApplyPinnedRule(wrapper, SectionOf(src), SectionOf(home));
  Tab moved = std::move(*wrapper.as_tab());

  split = FindSplit(split_id);
  if (!split) {
    return false;
  }
  size_t pane_pos = position.has_value()
                        ? std::min(*position, split->panes.size())
                        : split->panes.size();
  split->panes.insert(
      split->panes.begin() + static_cast<std::ptrdiff_t>(pane_pos),
      std::move(moved));
  split->fractions = EqualFractions(split->panes.size());
  split->focused_pane_id = tab_id;
  NodeParent sp{NodeParentKind::kSplitPane, split_id};
  ReindexSiblings(sp, pane_pos);

  auto reselected = RetargetSelections(tab_id, split_id);

  TreeChange reload_home;
  reload_home.kind = TreeChange::Kind::kReload;
  reload_home.parent = home;
  Emit(reload_home);
  if (!(src == home)) {
    TreeChange reload_src;
    reload_src.kind = TreeChange::Kind::kReload;
    reload_src.parent = src;
    Emit(reload_src);
  }

  PushUndo(
      "Add Split Pane",
      [split_id, tab_id, src, src_idx, home, old_fractions, old_focus,
       prior_pinned, reselected](BrowserModel& m) {
        auto pe = m.GetIndexEntry(tab_id);
        if (!pe.has_value() || pe->parent.kind != NodeParentKind::kSplitPane ||
            pe->parent.owner_id != split_id) {
          return false;
        }
        Split* s = m.FindSplit(split_id);
        auto* dst = m.GetNodeList(src);
        if (!s || !dst || pe->index >= s->panes.size()) return false;
        Tab t = std::move(s->panes[pe->index]);
        t.pinned_url = prior_pinned;
        s->panes.erase(s->panes.begin() + static_cast<std::ptrdiff_t>(pe->index));
        s->fractions = old_fractions;
        s->focused_pane_id = old_focus;
        m.ReindexSiblings(NodeParent{NodeParentKind::kSplitPane, split_id},
                          pe->index);
        size_t pos = std::min(src_idx, dst->size());
        dst->insert(dst->begin() + static_cast<std::ptrdiff_t>(pos),
                    SidebarNode(std::move(t)));
        m.ReindexSiblings(src, pos);
        m.RestoreSelections(reselected, split_id, tab_id);
        TreeChange r1;
        r1.kind = TreeChange::Kind::kReload;
        r1.parent = home;
        m.Emit(r1);
        if (!(src == home)) {
          TreeChange r2;
          r2.kind = TreeChange::Kind::kReload;
          r2.parent = src;
          m.Emit(r2);
        }
        return true;
      },
      [split_id, tab_id, position](BrowserModel& m) {
        return m.AddPane(split_id, tab_id, position);
      });
  return true;
}

bool BrowserModel::RemovePane(const ItemID& split_id,
                              const ItemID& tab_id,
                              bool archive) {
  auto parent = GetParent(tab_id);
  if (!parent.has_value() || parent->kind != NodeParentKind::kSplitPane ||
      parent->owner_id != split_id) {
    return false;
  }
  if (archive) {
    return CloseTab(tab_id);
  }
  auto split_entry = GetIndexEntry(split_id);
  if (!split_entry.has_value()) {
    return false;
  }
  NodeParent split_parent = split_entry->parent;
  auto taken = TakePane(tab_id, split_id);
  if (!taken.has_value()) {
    return false;
  }
  ItemID anchor_id =
      HasNode(split_id) ? split_id : taken->collapsed->remaining_tab_id;
  auto anchor_entry = GetIndexEntry(anchor_id);
  size_t insert_pos =
      anchor_entry.has_value() ? anchor_entry->index + 1 : size_t{0};

  if (!AttachNode(SidebarNode(taken->tab), split_parent, insert_pos)
           .has_value()) {
    RestoreTakenPane(*taken);
    return false;
  }

  PushUndo(
      "Separate Split Pane",
      [tab_id, taken = *taken](BrowserModel& m) {
        auto det = m.DetachNode(tab_id);
        if (!det.has_value()) return false;
        if (!m.RestoreTakenPane(taken)) {
          m.AttachNode(std::move(det->first),
                       m.GetParent(taken.split_metadata.id)
                           .value_or(NodeParent{}),
                       det->second);
          return false;
        }
        return true;
      },
      [split_id, tab_id](BrowserModel& m) {
        return m.RemovePane(split_id, tab_id, false);
      });
  return true;
}

bool BrowserModel::SetSplitFractions(const ItemID& split_id,
                                     const std::vector<double>& fractions) {
  Split* split = FindSplit(split_id);
  if (!split || fractions.size() != split->panes.size()) {
    return false;
  }
  double sum = 0.0;
  for (double f : fractions) {
    if (!std::isfinite(f) || f < 0.0) {
      return false;
    }
    sum += f;
  }
  if (std::abs(sum - 1.0) > 0.001) {
    return false;
  }
  if (split->fractions == fractions) {
    return false;
  }
  std::vector<double> old_val = split->fractions;
  split->fractions = fractions;
  TreeChange c;
  c.kind = TreeChange::Kind::kUpdate;
  c.node_id = split_id;
  Emit(c);
  PushUndo(
      "Resize Split",
      [split_id, old_val](BrowserModel& m) {
        Split* s = m.FindSplit(split_id);
        if (!s) return false;
        s->fractions = old_val;
        TreeChange ch;
        ch.kind = TreeChange::Kind::kUpdate;
        ch.node_id = split_id;
        m.Emit(ch);
        return true;
      },
      [split_id, fractions](BrowserModel& m) {
        Split* s = m.FindSplit(split_id);
        if (!s) return false;
        s->fractions = fractions;
        TreeChange ch;
        ch.kind = TreeChange::Kind::kUpdate;
        ch.node_id = split_id;
        m.Emit(ch);
        return true;
      });
  return true;
}

bool BrowserModel::SetSplitOrientation(const ItemID& split_id,
                                       SplitOrientation orientation) {
  Split* split = FindSplit(split_id);
  if (!split || split->orientation == orientation) {
    return false;
  }
  SplitOrientation old_val = split->orientation;
  split->orientation = orientation;
  TreeChange c;
  c.kind = TreeChange::Kind::kUpdate;
  c.node_id = split_id;
  Emit(c);
  PushUndo(
      "Change Split Orientation",
      [split_id, old_val](BrowserModel& m) {
        Split* s = m.FindSplit(split_id);
        if (!s) return false;
        s->orientation = old_val;
        TreeChange ch;
        ch.kind = TreeChange::Kind::kUpdate;
        ch.node_id = split_id;
        m.Emit(ch);
        return true;
      },
      [split_id, orientation](BrowserModel& m) {
        Split* s = m.FindSplit(split_id);
        if (!s) return false;
        s->orientation = orientation;
        TreeChange ch;
        ch.kind = TreeChange::Kind::kUpdate;
        ch.node_id = split_id;
        m.Emit(ch);
        return true;
      });
  return true;
}

// --- Space Mutations ---

SpaceID BrowserModel::CreateSpace(const ProfileID& profile_id,
                                  std::optional<std::string> title,
                                  std::optional<SpaceIcon> icon,
                                  std::optional<SpaceTheme> theme) {
  if (!FindProfile(profile_id)) {
    return {};
  }
  Space space;
  space.id = GenerateUuidV4();
  space.title = std::move(title);
  space.icon = std::move(icon);
  space.theme = theme.value_or(SpaceTheme{});
  space.profile_id = profile_id;
  const SpaceID space_id = space.id;
  size_t slot = spaces_.size();
  Space copy = space;
  spaces_.push_back(std::move(space));
  RebuildContainerIndexMaps();

  TreeChange reload;
  reload.kind = TreeChange::Kind::kReload;
  reload.parent = NodeParent{NodeParentKind::kSpaceToday, space_id};
  reload.space_id = space_id;
  Emit(reload);

  PushUndo(
      "New Space",
      [space_id](BrowserModel& m) {
        if (m.spaces_.size() <= 1) return false;
        return m.DeleteSpace(space_id, false);
      },
      [copy, slot](BrowserModel& m) {
        if (m.FindSpace(copy.id)) return false;
        size_t pos = std::min(slot, m.spaces_.size());
        m.spaces_.insert(m.spaces_.begin() + static_cast<std::ptrdiff_t>(pos),
                         copy);
        m.RebuildIndex();
        TreeChange r;
        r.kind = TreeChange::Kind::kReload;
        r.parent = NodeParent{NodeParentKind::kSpaceToday, copy.id};
        r.space_id = copy.id;
        m.Emit(r);
        return true;
      });
  return space_id;
}

bool BrowserModel::UpdateSpace(const SpaceID& space_id,
                               std::optional<std::string> title,
                               std::optional<std::optional<SpaceIcon>> icon,
                               std::optional<SpaceTheme> theme,
                               std::optional<ProfileID> profile_id) {
  Space* space = FindSpace(space_id);
  if (!space) {
    return false;
  }
  if (profile_id.has_value() && !FindProfile(*profile_id)) {
    return false;
  }
  std::optional<std::string> old_title = space->title;
  std::optional<SpaceIcon> old_icon = space->icon;
  SpaceTheme old_theme = space->theme;
  ProfileID old_profile = space->profile_id;

  if (title.has_value()) {
    std::string trimmed = TrimAscii(*title);
    space->title =
        trimmed.empty() ? std::nullopt : std::optional<std::string>(trimmed);
  }
  if (icon.has_value()) {
    space->icon = *icon;
  }
  if (theme.has_value()) {
    space->theme = *theme;
  }
  bool profile_changed = false;
  if (profile_id.has_value() && space->profile_id != *profile_id) {
    space->profile_id = *profile_id;
    profile_changed = true;
  }

  std::optional<std::string> new_title = space->title;
  std::optional<SpaceIcon> new_icon = space->icon;
  SpaceTheme new_theme = space->theme;
  ProfileID new_profile = space->profile_id;

  if (profile_changed) {
    TreeChange change;
    change.kind = TreeChange::Kind::kSpaceProfileChanged;
    change.space_id = space_id;
    change.from_profile_id = old_profile;
    change.to_profile_id = new_profile;
    Emit(change);
  } else {
    TreeChange change;
    change.kind = TreeChange::Kind::kUpdate;
    change.space_id = space_id;
    Emit(change);
  }

  PushUndo(
      "Update Space",
      [space_id, old_title, old_icon, old_theme, old_profile,
       new_profile](BrowserModel& m) {
        Space* s = m.FindSpace(space_id);
        if (!s) return false;
        s->title = old_title;
        s->icon = old_icon;
        s->theme = old_theme;
        bool pchanged = (s->profile_id != old_profile);
        s->profile_id = old_profile;
        TreeChange c;
        c.kind = pchanged ? TreeChange::Kind::kSpaceProfileChanged
                          : TreeChange::Kind::kUpdate;
        c.space_id = space_id;
        c.from_profile_id = new_profile;
        c.to_profile_id = old_profile;
        m.Emit(c);
        return true;
      },
      [space_id, new_title, new_icon, new_theme, old_profile,
       new_profile](BrowserModel& m) {
        Space* s = m.FindSpace(space_id);
        if (!s) return false;
        s->title = new_title;
        s->icon = new_icon;
        s->theme = new_theme;
        bool pchanged = (s->profile_id != new_profile);
        s->profile_id = new_profile;
        TreeChange c;
        c.kind = pchanged ? TreeChange::Kind::kSpaceProfileChanged
                          : TreeChange::Kind::kUpdate;
        c.space_id = space_id;
        c.from_profile_id = old_profile;
        c.to_profile_id = new_profile;
        m.Emit(c);
        return true;
      });
  return true;
}

bool BrowserModel::DeleteSpace(const SpaceID& space_id, bool archive_tabs) {
  if (spaces_.size() <= 1) {
    return false;
  }
  auto it = space_index_by_id_.find(space_id);
  if (it == space_index_by_id_.end()) {
    return false;
  }
  size_t slot = it->second;
  Space doomed = std::move(spaces_[slot]);

  std::vector<ArchivedTabRecord> records;
  if (archive_tabs) {
    TimestampSec now = NowSec();
    NodeParent pinned_p{NodeParentKind::kSpacePinned, space_id};
    NodeParent today_p{NodeParentKind::kSpaceToday, space_id};
    for (const SidebarNode& n : doomed.pinned) {
      CollectArchiveRecords(n, pinned_p, "space-deleted", now, &records);
    }
    for (const SidebarNode& n : doomed.today) {
      CollectArchiveRecords(n, today_p, "space-deleted", now, &records);
    }
  }

  std::vector<WindowID> focused_windows;
  std::vector<std::pair<WindowID, ItemID>> saved_selections;
  for (BrowserWindowState& w : windows_) {
    if (w.focused_space_id == space_id) {
      focused_windows.push_back(w.id);
    }
    auto sel_it = w.selected_node_by_space.find(space_id);
    if (sel_it != w.selected_node_by_space.end()) {
      saved_selections.push_back({w.id, sel_it->second});
      w.selected_node_by_space.erase(sel_it);
    }
  }

  for (const SidebarNode& n : doomed.pinned) {
    UnregisterSubtree(n);
  }
  for (const SidebarNode& n : doomed.today) {
    UnregisterSubtree(n);
  }
  spaces_.erase(spaces_.begin() + static_cast<std::ptrdiff_t>(slot));
  RebuildContainerIndexMaps();

  const SpaceID& fallback = spaces_.front().id;
  for (const WindowID& wid : focused_windows) {
    if (BrowserWindowState* w = FindWindow(wid)) {
      w->focused_space_id = fallback;
    }
  }

  if (archive_sink_ && !records.empty()) {
    archive_sink_->OnArchiveTabs(records);
  }

  TreeChange reload;
  reload.kind = TreeChange::Kind::kReload;
  reload.parent = NodeParent{NodeParentKind::kSpaceToday, space_id};
  reload.space_id = space_id;
  Emit(reload);

  std::vector<ItemID> archived_ids;
  archived_ids.reserve(records.size());
  for (const auto& r : records) {
    archived_ids.push_back(r.id);
  }

  PushUndo(
      "Delete Space",
      [doomed, slot, focused_windows, saved_selections,
       archived_ids](BrowserModel& m) {
        if (m.FindSpace(doomed.id)) return false;
        size_t pos = std::min(slot, m.spaces_.size());
        m.spaces_.insert(m.spaces_.begin() + static_cast<std::ptrdiff_t>(pos),
                         doomed);
        m.RebuildContainerIndexMaps();
        const Space& restored = m.spaces_[pos];
        NodeParent pp{NodeParentKind::kSpacePinned, restored.id};
        for (size_t i = 0; i < restored.pinned.size(); ++i) {
          m.RegisterSubtree(restored.pinned[i], pp, i);
        }
        NodeParent tp{NodeParentKind::kSpaceToday, restored.id};
        for (size_t i = 0; i < restored.today.size(); ++i) {
          m.RegisterSubtree(restored.today[i], tp, i);
        }
        for (const WindowID& wid : focused_windows) {
          if (BrowserWindowState* w = m.FindWindow(wid)) {
            w->focused_space_id = restored.id;
          }
        }
        for (const auto& [wid, nid] : saved_selections) {
          if (BrowserWindowState* w = m.FindWindow(wid)) {
            w->selected_node_by_space[restored.id] = nid;
          }
        }
        if (m.archive_sink_ && !archived_ids.empty()) {
          m.archive_sink_->OnDiscardArchived(archived_ids);
        }
        TreeChange r;
        r.kind = TreeChange::Kind::kReload;
        r.parent = tp;
        r.space_id = restored.id;
        m.Emit(r);
        return true;
      },
      [space_id, archive_tabs](BrowserModel& m) {
        return m.DeleteSpace(space_id, archive_tabs);
      });
  return true;
}

bool BrowserModel::MoveSpaceToProfile(const SpaceID& space_id,
                                      const ProfileID& profile_id) {
  Space* space = FindSpace(space_id);
  if (!space || !FindProfile(profile_id) || space->profile_id == profile_id) {
    return false;
  }
  return UpdateSpace(space_id, std::nullopt, std::nullopt, std::nullopt,
                     profile_id);
}

size_t BrowserModel::ClearToday(const SpaceID& space_id,
                                const std::set<ItemID>& keeping) {
  Space* space = FindSpace(space_id);
  if (!space) {
    return 0;
  }
  std::function<bool(const SidebarNode&)> retained = [&](const SidebarNode& n) {
    if (keeping.count(n.id()) > 0) {
      return true;
    }
    if (const Folder* folder = n.as_folder()) {
      if (folder->live.has_value()) {
        return true;
      }
      for (const SidebarNode& child : folder->children) {
        if (retained(child)) {
          return true;
        }
      }
      return false;
    }
    if (const Split* split = n.as_split()) {
      for (const Tab& pane : split->panes) {
        if (keeping.count(pane.id) > 0) {
          return true;
        }
      }
      return false;
    }
    return false;
  };

  struct RemovedEntry {
    size_t original_index;
    SidebarNode node;
  };
  std::vector<RemovedEntry> removed;
  std::vector<SidebarNode> kept;
  kept.reserve(space->today.size());

  NodeParent today_parent{NodeParentKind::kSpaceToday, space_id};
  TimestampSec now = NowSec();
  std::vector<ArchivedTabRecord> records;

  for (size_t i = 0; i < space->today.size(); ++i) {
    if (retained(space->today[i])) {
      kept.push_back(std::move(space->today[i]));
    } else {
      CollectArchiveRecords(space->today[i], today_parent, "clear-today", now,
                            &records);
      UnregisterSubtree(space->today[i]);
      removed.push_back({i, std::move(space->today[i])});
    }
  }
  if (removed.empty()) {
    return 0;
  }
  size_t removed_count = removed.size();
  space->today = std::move(kept);
  ReindexSiblings(today_parent, 0);

  if (archive_sink_ && !records.empty()) {
    archive_sink_->OnArchiveTabs(records);
  }

  TreeChange reload;
  reload.kind = TreeChange::Kind::kReload;
  reload.parent = today_parent;
  reload.space_id = space_id;
  Emit(reload);

  std::vector<ItemID> archived_ids;
  archived_ids.reserve(records.size());
  for (const auto& r : records) {
    archived_ids.push_back(r.id);
  }

  PushUndo(
      "Clear Today",
      [space_id, today_parent, removed = std::move(removed),
       archived_ids](BrowserModel& m) {
        Space* s = m.FindSpace(space_id);
        if (!s) return false;
        bool restored = false;
        for (const auto& entry : removed) {
          if (m.HasNode(entry.node.id())) continue;
          size_t pos = std::min(entry.original_index, s->today.size());
          s->today.insert(s->today.begin() + static_cast<std::ptrdiff_t>(pos),
                          entry.node);
          m.RegisterSubtree(s->today[pos], today_parent, pos);
          restored = true;
        }
        if (!restored) return false;
        m.ReindexSiblings(today_parent, 0);
        if (m.archive_sink_ && !archived_ids.empty()) {
          m.archive_sink_->OnDiscardArchived(archived_ids);
        }
        TreeChange r;
        r.kind = TreeChange::Kind::kReload;
        r.parent = today_parent;
        r.space_id = space_id;
        m.Emit(r);
        return true;
      },
      [space_id, keeping](BrowserModel& m) {
        return m.ClearToday(space_id, keeping) > 0;
      });
  return removed_count;
}

bool BrowserModel::SweepExpiredList(std::vector<SidebarNode>& list,
                                    const NodeParent& parent,
                                    TimestampSec cutoff,
                                    TimestampSec now,
                                    const SpaceID& space_id,
                                    const ProfileID& profile_id,
                                    const std::set<ItemID>& shown_tabs,
                                    std::vector<ArchivedTabRecord>* archived,
                                    std::vector<NodeParent>* changed_parents) {
  std::vector<SidebarNode> kept;
  kept.reserve(list.size());
  bool list_changed = false;

  for (SidebarNode& node : list) {
    if (Tab* tab = node.as_tab()) {
      bool is_shown = shown_tabs.count(tab->id) > 0;
      bool is_live_row = tab->live_item_url.has_value();
      if (!is_shown && !is_live_row && tab->last_active_at < cutoff) {
        ArchivedTabRecord rec;
        rec.id = tab->id;
        rec.url = tab->url;
        rec.title = tab->display_title();
        rec.space_id = space_id;
        rec.profile_id = profile_id;
        rec.archived_at = now;
        rec.reason = "auto-archive";
        rec.original_location = FormatArchiveLocation(parent);
        rec.payload_json = "{}";
        rec.kind = "tab";
        archived->push_back(std::move(rec));
        UnregisterTab(*tab);
        list_changed = true;
      } else {
        kept.push_back(std::move(node));
      }
    } else if (Folder* folder = node.as_folder()) {
      NodeParent fp{NodeParentKind::kFolder, folder->id};
      if (SweepExpiredList(folder->children, fp, cutoff, now, space_id,
                           profile_id, shown_tabs, archived, changed_parents)) {
        ReindexSiblings(fp, 0);
      }
      kept.push_back(std::move(node));
    } else if (Split* split = node.as_split()) {
      NodeParent sp{NodeParentKind::kSplitPane, split->id};
      std::vector<Tab> live_panes;
      std::vector<double> live_fractions;
      bool split_changed = false;
      bool has_valid_fractions = (split->fractions.size() == split->panes.size());
      for (size_t i = 0; i < split->panes.size(); ++i) {
        Tab& pane = split->panes[i];
        bool is_shown = shown_tabs.count(pane.id) > 0;
        if (!is_shown && pane.last_active_at < cutoff) {
          ArchivedTabRecord rec;
          rec.id = pane.id;
          rec.url = pane.url;
          rec.title = pane.display_title();
          rec.space_id = space_id;
          rec.profile_id = profile_id;
          rec.archived_at = now;
          rec.reason = "auto-archive";
          rec.original_location = FormatArchiveLocation(sp);
          rec.payload_json = "{}";
          rec.kind = "tab";
          archived->push_back(std::move(rec));
          UnregisterTab(pane);
          split_changed = true;
        } else {
          if (has_valid_fractions) {
            live_fractions.push_back(split->fractions[i]);
          }
          live_panes.push_back(std::move(pane));
        }
      }
      if (!split_changed) {
        kept.push_back(std::move(node));
        continue;
      }
      if (live_panes.size() >= 2) {
        double sum =
            std::accumulate(live_fractions.begin(), live_fractions.end(), 0.0);
        if (has_valid_fractions && std::isfinite(sum) && sum > 0.0) {
          for (double& f : live_fractions) f /= sum;
          split->fractions = std::move(live_fractions);
        } else {
          split->fractions = EqualFractions(live_panes.size());
        }
        bool focus_ok = false;
        for (const Tab& p : live_panes) {
          if (split->focused_pane_id == p.id) {
            focus_ok = true;
            break;
          }
        }
        if (!focus_ok) {
          split->focused_pane_id = live_panes.front().id;
        }
        split->panes = std::move(live_panes);
        ReindexSiblings(sp, 0);
        changed_parents->push_back(sp);
        kept.push_back(std::move(node));
      } else {
        // Under 2 panes: dissolve split; lone survivor takes its slot.
        ItemID split_id = split->id;
        index_.erase(split_id);
        parent_by_id_.erase(split_id);
        if (live_panes.size() == 1) {
          ItemID survivor_id = live_panes.front().id;
          RetargetSelections(split_id, survivor_id);
          kept.push_back(SidebarNode(std::move(live_panes.front())));
        }
        list_changed = true;
      }
    }
  }

  if (list_changed) {
    list = std::move(kept);
    changed_parents->push_back(parent);
  }
  return list_changed;
}

size_t BrowserModel::ArchiveExpiredTabs(TimestampSec now) {
  std::set<ItemID> shown = ComputeShownTabIds();
  std::vector<ArchivedTabRecord> archived;
  std::vector<NodeParent> changed_parents;

  for (Space& space : spaces_) {
    const Profile* profile = FindProfile(space.profile_id);
    if (!profile) {
      continue;
    }
    auto threshold = AutoArchiveSeconds(profile->settings.auto_archive_after);
    if (!threshold.has_value()) {
      continue;
    }
    TimestampSec cutoff = now - *threshold;
    NodeParent today_p{NodeParentKind::kSpaceToday, space.id};
    if (SweepExpiredList(space.today, today_p, cutoff, now, space.id,
                         space.profile_id, shown, &archived,
                         &changed_parents)) {
      ReindexSiblings(today_p, 0);
    }
  }

  if (archive_sink_ && !archived.empty()) {
    archive_sink_->OnArchiveTabs(archived);
  }
  for (const NodeParent& p : changed_parents) {
    TreeChange reload;
    reload.kind = TreeChange::Kind::kReload;
    reload.parent = p;
    Emit(reload);
  }
  return archived.size();
}

// --- Focus & Selection ---

bool BrowserModel::FocusSpace(const WindowID& window_id,
                              const SpaceID& space_id) {
  BrowserWindowState* window = FindWindow(window_id);
  if (!window || !FindSpace(space_id)) {
    return false;
  }
  SpaceID old_space = window->focused_space_id;
  if (old_space == space_id) {
    RecordFocusedSpace(space_id);
    return true;
  }
  RecordFocusedSpace(space_id);
  window->focused_space_id = space_id;
  TreeChange change;
  change.kind = TreeChange::Kind::kUpdate;
  change.space_id = space_id;
  Emit(change);
  PushUndo(
      "Switch Space",
      [window_id, old_space](BrowserModel& m) {
        BrowserWindowState* w = m.FindWindow(window_id);
        if (!w || !m.FindSpace(old_space)) return false;
        w->focused_space_id = old_space;
        m.RecordFocusedSpace(old_space);
        TreeChange c;
        c.kind = TreeChange::Kind::kUpdate;
        c.space_id = old_space;
        m.Emit(c);
        return true;
      },
      [window_id, space_id](BrowserModel& m) {
        BrowserWindowState* w = m.FindWindow(window_id);
        if (!w || !m.FindSpace(space_id)) return false;
        w->focused_space_id = space_id;
        m.RecordFocusedSpace(space_id);
        TreeChange c;
        c.kind = TreeChange::Kind::kUpdate;
        c.space_id = space_id;
        m.Emit(c);
        return true;
      });
  return true;
}

bool BrowserModel::SelectNode(const WindowID& window_id,
                              const SpaceID& space_id,
                              const std::optional<ItemID>& node_id) {
  BrowserWindowState* window = FindWindow(window_id);
  if (!window || !FindSpace(space_id)) {
    return false;
  }
  if (node_id.has_value() && !IsSelectable(*node_id, space_id)) {
    return false;
  }
  std::optional<ItemID> old_sel;
  auto it = window->selected_node_by_space.find(space_id);
  if (it != window->selected_node_by_space.end()) {
    old_sel = it->second;
  }
  if (old_sel == node_id) {
    if (node_id.has_value()) {
      StampVisibleTabs(*node_id, NowSec());
    }
    return true;
  }
  if (node_id.has_value()) {
    window->selected_node_by_space[space_id] = *node_id;
    StampVisibleTabs(*node_id, NowSec());
  } else {
    window->selected_node_by_space.erase(space_id);
  }
  TreeChange change;
  change.kind = TreeChange::Kind::kUpdate;
  change.space_id = space_id;
  if (node_id.has_value()) {
    change.node_id = *node_id;
  }
  Emit(change);
  PushUndo(
      "Select Tab",
      [window_id, space_id, old_sel](BrowserModel& m) {
        BrowserWindowState* w = m.FindWindow(window_id);
        if (!w) return false;
        if (old_sel.has_value()) {
          w->selected_node_by_space[space_id] = *old_sel;
          m.StampVisibleTabs(*old_sel, NowSec());
        } else {
          w->selected_node_by_space.erase(space_id);
        }
        TreeChange c;
        c.kind = TreeChange::Kind::kUpdate;
        c.space_id = space_id;
        m.Emit(c);
        return true;
      },
      [window_id, space_id, node_id](BrowserModel& m) {
        BrowserWindowState* w = m.FindWindow(window_id);
        if (!w) return false;
        if (node_id.has_value()) {
          w->selected_node_by_space[space_id] = *node_id;
          m.StampVisibleTabs(*node_id, NowSec());
        } else {
          w->selected_node_by_space.erase(space_id);
        }
        TreeChange c;
        c.kind = TreeChange::Kind::kUpdate;
        c.space_id = space_id;
        m.Emit(c);
        return true;
      });
  return true;
}

// --- Profile Mutations ---

ProfileID BrowserModel::CreateProfile(const std::string& name,
                                      std::optional<SpaceIcon> icon,
                                      ProfileSettings settings) {
  if (ValidateProfileName(name) != ProfileNameIssue::kNone) {
    return {};
  }
  Profile profile;
  profile.id = GenerateUuidV4();
  profile.name = TrimAscii(name);
  profile.icon = std::move(icon);
  profile.settings = std::move(settings);
  if (!profiles_.empty() || unavailable_profile_dirs_.count("default") > 0) {
    std::string dir;
    do {
      dir = "Profile-" + base::ToUpperASCII(GenerateUuidV4().substr(0, 8));
    } while (unavailable_profile_dirs_.count(LowerAscii(dir)) > 0);
    profile.data_directory_name = dir;
  } else {
    profile.data_directory_name = "Default";
  }
  unavailable_profile_dirs_.insert(LowerAscii(profile.data_directory_name));

  const ProfileID profile_id = profile.id;
  size_t slot = profiles_.size();
  Profile copy = profile;
  profiles_.push_back(std::move(profile));
  RebuildContainerIndexMaps();

  TreeChange reload;
  reload.kind = TreeChange::Kind::kReload;
  reload.parent = NodeParent{NodeParentKind::kFavorites, profile_id};
  Emit(reload);

  PushUndo(
      "New Profile",
      [profile_id](BrowserModel& m) {
        for (const Space& s : m.spaces_) {
          if (s.profile_id == profile_id) return false;
        }
        auto it = m.profile_index_by_id_.find(profile_id);
        if (it == m.profile_index_by_id_.end()) return false;
        for (const Tab& fav : m.profiles_[it->second].favorites) {
          m.UnregisterTab(fav);
        }
        m.profiles_.erase(m.profiles_.begin() +
                          static_cast<std::ptrdiff_t>(it->second));
        m.RebuildContainerIndexMaps();
        TreeChange r;
        r.kind = TreeChange::Kind::kReload;
        r.parent = NodeParent{NodeParentKind::kFavorites, profile_id};
        m.Emit(r);
        return true;
      },
      [copy, slot](BrowserModel& m) {
        if (m.FindProfile(copy.id)) return false;
        size_t pos = std::min(slot, m.profiles_.size());
        m.profiles_.insert(
            m.profiles_.begin() + static_cast<std::ptrdiff_t>(pos), copy);
        m.RebuildContainerIndexMaps();
        NodeParent fp{NodeParentKind::kFavorites, copy.id};
        for (size_t i = 0; i < m.profiles_[pos].favorites.size(); ++i) {
          m.RegisterTab(m.profiles_[pos].favorites[i], fp, i);
        }
        TreeChange r;
        r.kind = TreeChange::Kind::kReload;
        r.parent = fp;
        m.Emit(r);
        return true;
      });
  return profile_id;
}

bool BrowserModel::RenameProfile(const ProfileID& profile_id,
                                 const std::string& new_name) {
  Profile* profile = FindProfile(profile_id);
  if (!profile ||
      ValidateProfileName(new_name, profile_id) != ProfileNameIssue::kNone) {
    return false;
  }
  std::string trimmed = TrimAscii(new_name);
  std::string old_name = profile->name;
  if (old_name == trimmed) {
    return true;
  }
  profile->name = trimmed;
  TreeChange c;
  c.kind = TreeChange::Kind::kUpdate;
  c.parent = NodeParent{NodeParentKind::kFavorites, profile_id};
  Emit(c);
  PushUndo(
      "Rename Profile",
      [profile_id, old_name](BrowserModel& m) {
        Profile* p = m.FindProfile(profile_id);
        if (!p) return false;
        p->name = old_name;
        TreeChange ch;
        ch.kind = TreeChange::Kind::kUpdate;
        ch.parent = NodeParent{NodeParentKind::kFavorites, profile_id};
        m.Emit(ch);
        return true;
      },
      [profile_id, trimmed](BrowserModel& m) {
        Profile* p = m.FindProfile(profile_id);
        if (!p) return false;
        p->name = trimmed;
        TreeChange ch;
        ch.kind = TreeChange::Kind::kUpdate;
        ch.parent = NodeParent{NodeParentKind::kFavorites, profile_id};
        m.Emit(ch);
        return true;
      });
  return true;
}

bool BrowserModel::SetProfileIcon(const ProfileID& profile_id,
                                  std::optional<SpaceIcon> icon) {
  Profile* profile = FindProfile(profile_id);
  if (!profile) {
    return false;
  }
  std::optional<SpaceIcon> old_icon = profile->icon;
  if (old_icon == icon) {
    return true;
  }
  profile->icon = icon;
  TreeChange c;
  c.kind = TreeChange::Kind::kReload;
  c.parent = NodeParent{NodeParentKind::kFavorites, profile_id};
  Emit(c);
  PushUndo(
      "Change Profile Icon",
      [profile_id, old_icon](BrowserModel& m) {
        Profile* p = m.FindProfile(profile_id);
        if (!p) return false;
        p->icon = old_icon;
        TreeChange ch;
        ch.kind = TreeChange::Kind::kReload;
        ch.parent = NodeParent{NodeParentKind::kFavorites, profile_id};
        m.Emit(ch);
        return true;
      },
      [profile_id, icon](BrowserModel& m) {
        Profile* p = m.FindProfile(profile_id);
        if (!p) return false;
        p->icon = icon;
        TreeChange ch;
        ch.kind = TreeChange::Kind::kReload;
        ch.parent = NodeParent{NodeParentKind::kFavorites, profile_id};
        m.Emit(ch);
        return true;
      });
  return true;
}

bool BrowserModel::DeleteProfile(const ProfileID& profile_id) {
  if (!FindProfile(profile_id) ||
      GetProfileDeleteBlock(profile_id) != ProfileDeleteBlock::kNone) {
    return false;
  }
  auto it = profile_index_by_id_.find(profile_id);
  if (it == profile_index_by_id_.end()) {
    return false;
  }
  size_t slot = it->second;
  Profile doomed = std::move(profiles_[slot]);

  std::vector<ArchivedTabRecord> records;
  NodeParent fav_parent{NodeParentKind::kFavorites, profile_id};
  TimestampSec now = NowSec();
  for (const Tab& fav : doomed.favorites) {
    CollectArchiveRecords(SidebarNode(fav), fav_parent, "closed", now,
                          &records);
    UnregisterTab(fav);
  }
  profiles_.erase(profiles_.begin() + static_cast<std::ptrdiff_t>(slot));
  RebuildContainerIndexMaps();

  if (archive_sink_ && !records.empty()) {
    archive_sink_->OnArchiveTabs(records);
  }
  TreeChange reload;
  reload.kind = TreeChange::Kind::kReload;
  reload.parent = fav_parent;
  Emit(reload);

  std::vector<ItemID> archived_ids;
  for (const auto& r : records) {
    archived_ids.push_back(r.id);
  }
  PushUndo(
      "Delete Profile",
      [doomed, slot, archived_ids, fav_parent](BrowserModel& m) {
        if (m.FindProfile(doomed.id)) return false;
        size_t pos = std::min(slot, m.profiles_.size());
        m.profiles_.insert(
            m.profiles_.begin() + static_cast<std::ptrdiff_t>(pos), doomed);
        m.RebuildContainerIndexMaps();
        for (size_t i = 0; i < m.profiles_[pos].favorites.size(); ++i) {
          m.RegisterTab(m.profiles_[pos].favorites[i], fav_parent, i);
        }
        if (m.archive_sink_ && !archived_ids.empty()) {
          m.archive_sink_->OnDiscardArchived(archived_ids);
        }
        TreeChange r;
        r.kind = TreeChange::Kind::kReload;
        r.parent = fav_parent;
        m.Emit(r);
        return true;
      },
      [profile_id](BrowserModel& m) { return m.DeleteProfile(profile_id); });
  return true;
}

bool BrowserModel::UpdateProfileSettings(const ProfileID& profile_id,
                                         const ProfileSettings& settings) {
  Profile* profile = FindProfile(profile_id);
  if (!profile) {
    return false;
  }
  ProfileSettings old_settings = profile->settings;
  profile->settings = settings;
  TreeChange c;
  c.kind = TreeChange::Kind::kUpdate;
  c.parent = NodeParent{NodeParentKind::kFavorites, profile_id};
  Emit(c);
  PushUndo(
      "Update Profile Settings",
      [profile_id, old_settings](BrowserModel& m) {
        Profile* p = m.FindProfile(profile_id);
        if (!p) return false;
        p->settings = old_settings;
        TreeChange ch;
        ch.kind = TreeChange::Kind::kUpdate;
        ch.parent = NodeParent{NodeParentKind::kFavorites, profile_id};
        m.Emit(ch);
        return true;
      },
      [profile_id, settings](BrowserModel& m) {
        Profile* p = m.FindProfile(profile_id);
        if (!p) return false;
        p->settings = settings;
        TreeChange ch;
        ch.kind = TreeChange::Kind::kUpdate;
        ch.parent = NodeParent{NodeParentKind::kFavorites, profile_id};
        m.Emit(ch);
        return true;
      });
  return true;
}

// --- Window Mutations ---

WindowID BrowserModel::CreateWindow(const SpaceID& focused_space_id,
                                    WindowStyle style) {
  if (!FindSpace(focused_space_id)) {
    return {};
  }
  BrowserWindowState window;
  window.id = GenerateUuidV4();
  window.focused_space_id = focused_space_id;
  window.style = style;
  window.last_focused_at = NowSec();
  const WindowID window_id = window.id;
  BrowserWindowState copy = window;
  windows_.push_back(std::move(window));
  RebuildContainerIndexMaps();
  CommitVisibilityTransition();

  PushUndo(
      "New Window",
      [window_id](BrowserModel& m) { return m.CloseWindow(window_id); },
      [copy](BrowserModel& m) {
        if (m.FindWindow(copy.id)) return false;
        m.windows_.push_back(copy);
        m.RebuildContainerIndexMaps();
        m.CommitVisibilityTransition();
        return true;
      });
  return window_id;
}

bool BrowserModel::CloseWindow(const WindowID& window_id) {
  auto it = window_index_by_id_.find(window_id);
  if (it == window_index_by_id_.end()) {
    return false;
  }
  size_t slot = it->second;
  BrowserWindowState saved = std::move(windows_[slot]);
  windows_.erase(windows_.begin() + static_cast<std::ptrdiff_t>(slot));
  RebuildContainerIndexMaps();
  CommitVisibilityTransition();

  PushUndo(
      "Close Window",
      [saved, slot](BrowserModel& m) {
        if (m.FindWindow(saved.id)) return false;
        size_t pos = std::min(slot, m.windows_.size());
        m.windows_.insert(
            m.windows_.begin() + static_cast<std::ptrdiff_t>(pos), saved);
        m.RebuildContainerIndexMaps();
        m.CommitVisibilityTransition();
        return true;
      },
      [window_id](BrowserModel& m) { return m.CloseWindow(window_id); });
  return true;
}

bool BrowserModel::SetSidebarWidth(const WindowID& window_id, double width) {
  if (!std::isfinite(width)) {
    return false;
  }
  BrowserWindowState* window = FindWindow(window_id);
  if (!window) {
    return false;
  }
  double clamped = std::clamp(width, kMinSidebarWidth, kMaxSidebarWidth);
  double old_width = window->sidebar_width;
  if (clamped == old_width) {
    return false;
  }
  window->sidebar_width = clamped;
  TreeChange c;
  c.kind = TreeChange::Kind::kUpdate;
  Emit(c);
  PushUndo(
      "Resize Sidebar",
      [window_id, old_width](BrowserModel& m) {
        BrowserWindowState* w = m.FindWindow(window_id);
        if (!w) return false;
        w->sidebar_width = old_width;
        TreeChange ch;
        ch.kind = TreeChange::Kind::kUpdate;
        m.Emit(ch);
        return true;
      },
      [window_id, clamped](BrowserModel& m) {
        BrowserWindowState* w = m.FindWindow(window_id);
        if (!w) return false;
        w->sidebar_width = clamped;
        TreeChange ch;
        ch.kind = TreeChange::Kind::kUpdate;
        m.Emit(ch);
        return true;
      });
  return true;
}

bool BrowserModel::SetSidebarMode(const WindowID& window_id,
                                  SidebarMode mode,
                                  bool register_undo) {
  BrowserWindowState* window = FindWindow(window_id);
  if (!window || window->sidebar_mode == mode) {
    return false;
  }
  SidebarMode old_mode = window->sidebar_mode;
  window->sidebar_mode = mode;
  TreeChange c;
  c.kind = TreeChange::Kind::kUpdate;
  Emit(c);
  if (register_undo) {
    PushUndo(
        mode == SidebarMode::kHidden ? "Hide Sidebar" : "Show Sidebar",
        [window_id, old_mode](BrowserModel& m) {
          BrowserWindowState* w = m.FindWindow(window_id);
          if (!w) return false;
          w->sidebar_mode = old_mode;
          TreeChange ch;
          ch.kind = TreeChange::Kind::kUpdate;
          m.Emit(ch);
          return true;
        },
        [window_id, mode](BrowserModel& m) {
          BrowserWindowState* w = m.FindWindow(window_id);
          if (!w) return false;
          w->sidebar_mode = mode;
          TreeChange ch;
          ch.kind = TreeChange::Kind::kUpdate;
          m.Emit(ch);
          return true;
        });
  }
  return true;
}

// --- Runtime Live State ---

bool BrowserModel::UpdateTabLiveState(const ItemID& tab_id,
                                      const TabLiveState& live_state) {
  Tab* tab = FindTab(tab_id);
  if (!tab) {
    return false;
  }
  tab->live_state = live_state;
  TreeChange change;
  change.kind = TreeChange::Kind::kUpdate;
  change.node_id = tab_id;
  if (auto p = GetParent(tab_id)) {
    change.parent = *p;
  }
  Emit(change);
  return true;
}

bool BrowserModel::UpdateTabNavigation(const ItemID& tab_id,
                                       const std::string& url,
                                       const std::string& title) {
  Tab* tab = FindTab(tab_id);
  if (!tab) {
    return false;
  }
  bool changed = false;
  if (!url.empty() && tab->url != url) {
    tab->url = url;
    changed = true;
  }
  if (!title.empty() && tab->title != title) {
    tab->title = title;
    changed = true;
  }
  if (!changed) {
    return false;
  }
  TreeChange change;
  change.kind = TreeChange::Kind::kUpdate;
  change.node_id = tab_id;
  if (auto p = GetParent(tab_id)) {
    change.parent = *p;
  }
  Emit(change);
  return true;
}

}  // namespace open_unified
