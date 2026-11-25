// Copyright 2026 The Open Authors. All rights reserved.
// Cross-platform C++20 BrowserModel matching Packages/OpenKit OpenModel
// invariants, O(1) indexing, undo/redo, and TreeChange observation.

#ifndef OPEN_UNIFIED_CORE_MODEL_BROWSER_MODEL_H_
#define OPEN_UNIFIED_CORE_MODEL_BROWSER_MODEL_H_

#include <cstddef>
#include <cstdint>
#include <functional>
#include <optional>
#include <set>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

#include "base/memory/raw_ptr.h"
#include "open_unified/core/model/open_types.h"

namespace open_unified {

// Formatting helper matching OpenModel's archiveLocation strings:
// "pinned:<id>", "today:<id>", "folder:<id>", "favorites:<id>", "split:<id>".
std::string FormatArchiveLocation(const NodeParent& parent);
std::optional<NodeParent> ParseArchiveLocation(std::string_view location);

// Returns auto-archive threshold in seconds, or std::nullopt for kNever.
std::optional<double> AutoArchiveSeconds(AutoArchiveInterval interval);

enum class ProfileNameIssue {
  kNone,
  kEmpty,
  kTooLong,
  kInvalidCharacters,
  kDuplicate,
};

enum class ProfileDeleteBlock {
  kNone,
  kIsDefault,
  kSpacesAssigned,
};

struct NodeIndexEntry {
  NodeParent parent;
  size_t index = 0;
  SidebarNode::Kind kind = SidebarNode::Kind::kTab;
};

class BrowserModel {
 public:
  static constexpr double kMinSidebarWidth = 164.0;
  static constexpr double kMaxSidebarWidth = 500.0;
  static constexpr size_t kMaxSplitPanes = 4;
  static constexpr size_t kMaxUndoDepth = 200;

  class Observer {
   public:
    virtual ~Observer() = default;
    virtual void OnTreeChanged(const TreeChange& change) = 0;
  };

  class ArchiveSink {
   public:
    virtual ~ArchiveSink() = default;
    virtual void OnArchiveTabs(
        const std::vector<ArchivedTabRecord>& records) = 0;
    virtual void OnDiscardArchived(const std::vector<ItemID>& ids) = 0;
  };

  BrowserModel();
  BrowserModel(std::vector<Profile> profiles,
               std::vector<Space> spaces,
               std::vector<BrowserWindowState> windows,
               std::vector<RoutingRule> routing_rules = {},
               RoutingDestination default_destination = {
                   RoutingDestinationKind::kLittleOpen, std::nullopt,
                   std::nullopt});
  ~BrowserModel();

  BrowserModel(const BrowserModel&) = delete;
  BrowserModel& operator=(const BrowserModel&) = delete;

  // Ensures at least one default Profile, one Space, and one Window exist.
  void EnsureDefaultWorkspace();

  // --- Observers & Archive Sink ---
  void AddObserver(Observer* observer);
  void RemoveObserver(Observer* observer);
  void SetArchiveSink(ArchiveSink* sink) { archive_sink_ = sink; }
  ArchiveSink* archive_sink() const { return archive_sink_; }

  // --- State Accessors ---
  const std::vector<Profile>& profiles() const { return profiles_; }
  const std::vector<Space>& spaces() const { return spaces_; }
  const std::vector<BrowserWindowState>& windows() const { return windows_; }
  const std::vector<RoutingRule>& routing_rules() const {
    return routing_rules_;
  }
  const RoutingDestination& default_destination() const {
    return default_destination_;
  }

  void SetRoutingRules(std::vector<RoutingRule> rules);
  void SetDefaultDestination(RoutingDestination destination);

  uint64_t tree_revision() const { return tree_revision_; }
  uint64_t undo_generation() const { return undo_generation_; }

  const std::unordered_map<ItemID, NodeIndexEntry>& index() const {
    return index_;
  }
  const std::unordered_map<ItemID, NodeParent>& parent_by_id() const {
    return parent_by_id_;
  }

  // --- O(1) / O(depth) Lookup ---
  Profile* FindProfile(const ProfileID& id);
  const Profile* FindProfile(const ProfileID& id) const;
  Space* FindSpace(const SpaceID& id);
  const Space* FindSpace(const SpaceID& id) const;
  BrowserWindowState* FindWindow(const WindowID& id);
  const BrowserWindowState* FindWindow(const WindowID& id) const;

  bool HasNode(const ItemID& id) const;
  std::optional<NodeParent> GetParent(const ItemID& id) const;
  std::optional<NodeIndexEntry> GetIndexEntry(const ItemID& id) const;

  // Returns pointers into internal containers; valid until the next structural
  // mutation of the owning container.
  SidebarNode* FindNode(const ItemID& id);
  const SidebarNode* FindNode(const ItemID& id) const;
  Tab* FindTab(const ItemID& id);
  const Tab* FindTab(const ItemID& id) const;
  Folder* FindFolder(const ItemID& id);
  const Folder* FindFolder(const ItemID& id) const;
  Split* FindSplit(const ItemID& id);
  const Split* FindSplit(const ItemID& id) const;

  bool IsPinned(const ItemID& tab_id) const;
  bool IsFavorite(const ItemID& tab_id) const;
  bool IsSelectable(const ItemID& id, const SpaceID& space_id) const;
  std::optional<ItemID> SelectedNodeId(const SpaceID& space_id,
                                       const WindowID& window_id) const;
  std::optional<ItemID> SidebarSelectionId(const ItemID& id) const;
  std::string DisplayTitleForSpace(const SpaceID& space_id) const;
  std::optional<SpaceID> MostRecentlyFocusedSpace(
      const ProfileID& profile_id) const;
  const Profile* DefaultProfile() const;

  bool CanMoveNode(const ItemID& id, const NodeParent& destination) const;
  ProfileNameIssue ValidateProfileName(
      const std::string& raw_name,
      const std::optional<ProfileID>& excluding_id = std::nullopt) const;
  ProfileDeleteBlock GetProfileDeleteBlock(const ProfileID& id) const;

  // Full index rebuild from profiles_, spaces_, windows_. Used on load/import.
  void RebuildIndex();

  // --- Undo / Redo ---
  bool CanUndo() const { return !undo_stack_.empty(); }
  bool CanRedo() const { return !redo_stack_.empty(); }
  bool Undo();
  bool Redo();
  std::optional<std::string> UndoActionName() const;
  std::optional<std::string> RedoActionName() const;
  void ClearUndoHistory();

  // --- Tab & Tree Mutations ---
  ItemID NewTab(const SpaceID& space_id,
                const std::string& url,
                const std::string& title = "",
                std::optional<size_t> position = std::nullopt,
                bool unread = false);
  bool CloseTab(const ItemID& id);
  bool PinTab(const ItemID& id);
  bool UnpinTab(const ItemID& id);
  bool AddFavorite(const ItemID& tab_id,
                   const ProfileID& profile_id,
                   std::optional<size_t> position = std::nullopt);
  bool RemoveFavorite(const ItemID& tab_id,
                      std::optional<SpaceID> into_space_id = std::nullopt);
  bool MoveNode(const ItemID& id,
                const NodeParent& destination,
                std::optional<size_t> position = std::nullopt);
  ItemID CreateFolder(const NodeParent& parent,
                      const std::string& title = "Folder",
                      std::optional<size_t> position = std::nullopt,
                      const std::vector<ItemID>& node_ids = {});
  bool RenameNode(const ItemID& id, const std::string& title);
  bool SetFolderExpanded(const ItemID& folder_id, bool expanded);
  bool SetPinnedCollapsed(const SpaceID& space_id, bool collapsed);
  bool SetMuted(const ItemID& tab_id, bool muted);
  ItemID DuplicateNode(const ItemID& id,
                       std::optional<SpaceID> into_space_id = std::nullopt);
  std::vector<ItemID> ResetPinnedTabs(const SpaceID& space_id);
  bool ResetPinnedTab(const ItemID& tab_id);
  ItemID RestoreArchivedTab(const ArchivedTabRecord& record);

  // --- Split View Mutations ---
  ItemID MakeSplit(const std::vector<ItemID>& tab_ids,
                   SplitOrientation orientation = SplitOrientation::kHorizontal);
  bool Unsplit(const ItemID& split_id);
  bool AddPane(const ItemID& split_id,
               const ItemID& tab_id,
               std::optional<size_t> position = std::nullopt);
  bool RemovePane(const ItemID& split_id,
                  const ItemID& tab_id,
                  bool archive = false);
  bool SetSplitFractions(const ItemID& split_id,
                         const std::vector<double>& fractions);
  bool SetSplitOrientation(const ItemID& split_id,
                           SplitOrientation orientation);

  // --- Space Mutations ---
  SpaceID CreateSpace(const ProfileID& profile_id,
                      std::optional<std::string> title = std::nullopt,
                      std::optional<SpaceIcon> icon = std::nullopt,
                      std::optional<SpaceTheme> theme = std::nullopt);
  bool UpdateSpace(
      const SpaceID& space_id,
      std::optional<std::string> title = std::nullopt,
      std::optional<std::optional<SpaceIcon>> icon = std::nullopt,
      std::optional<SpaceTheme> theme = std::nullopt,
      std::optional<ProfileID> profile_id = std::nullopt);
  bool DeleteSpace(const SpaceID& space_id, bool archive_tabs = true);
  bool MoveSpaceToProfile(const SpaceID& space_id,
                          const ProfileID& profile_id);
  size_t ClearToday(const SpaceID& space_id,
                    const std::set<ItemID>& keeping = {});
  size_t ArchiveExpiredTabs(TimestampSec now);

  // --- Focus & Selection ---
  bool FocusSpace(const WindowID& window_id, const SpaceID& space_id);
  bool SelectNode(const WindowID& window_id,
                  const SpaceID& space_id,
                  const std::optional<ItemID>& node_id);

  // --- Profile Mutations ---
  ProfileID CreateProfile(const std::string& name,
                          std::optional<SpaceIcon> icon = std::nullopt,
                          ProfileSettings settings = {});
  bool RenameProfile(const ProfileID& profile_id, const std::string& new_name);
  bool SetProfileIcon(const ProfileID& profile_id,
                      std::optional<SpaceIcon> icon);
  bool DeleteProfile(const ProfileID& profile_id);
  bool UpdateProfileSettings(const ProfileID& profile_id,
                             const ProfileSettings& settings);

  // --- Window Mutations ---
  WindowID CreateWindow(const SpaceID& focused_space_id,
                        WindowStyle style = WindowStyle::kStandard);
  bool CloseWindow(const WindowID& window_id);
  bool SetSidebarWidth(const WindowID& window_id, double width);
  bool SetSidebarMode(const WindowID& window_id,
                      SidebarMode mode,
                      bool register_undo = true);

  // --- Runtime Live State (Non-Persisted, Non-Undoable) ---
  bool UpdateTabLiveState(const ItemID& tab_id,
                          const TabLiveState& live_state);
  bool UpdateTabNavigation(const ItemID& tab_id,
                           const std::string& url,
                           const std::string& title);

 private:
  struct UndoStep {
    std::string action_name;
    std::function<bool(BrowserModel&)> undo;
    std::function<bool(BrowserModel&)> redo;
  };

  struct SelectionSlot {
    WindowID window_id;
    SpaceID space_id;
  };

  struct SavedPinnedUrl {
    ItemID tab_id;
    std::optional<std::string> pinned_url;
  };

  struct CollapseInfo {
    NodeParent parent;
    ItemID remaining_tab_id;
    std::vector<SelectionSlot> reselected;
  };

  static TimestampSec NowSec();
  static bool KeepsPinnedUrl(const std::optional<NodeParent>& section);
  static bool LeftPinnedUrl(const Tab& tab);

  void Emit(const TreeChange& change);
  void PushUndo(std::string action_name,
                std::function<bool(BrowserModel&)> undo,
                std::function<bool(BrowserModel&)> redo);
  void CommitVisibilityTransition();
  std::set<ItemID> ComputeShownTabIds() const;
  void StampVisibleTabs(const ItemID& node_id, TimestampSec now);

  std::optional<NodeParent> SectionOf(const NodeParent& parent) const;
  std::pair<std::optional<SpaceID>, std::optional<ProfileID>> OwnerOf(
      const NodeParent& parent) const;
  std::optional<SpaceID> TargetSpaceForProfile(
      const std::optional<ProfileID>& profile_id) const;
  bool ParentExists(const NodeParent& parent) const;

  // Container accessors.
  std::vector<SidebarNode>* GetNodeList(const NodeParent& parent);
  const std::vector<SidebarNode>* GetNodeList(const NodeParent& parent) const;
  std::vector<Tab>* GetTabList(const NodeParent& parent);
  const std::vector<Tab>* GetTabList(const NodeParent& parent) const;

  // Indexing helpers.
  void RegisterSubtree(const SidebarNode& node,
                       const NodeParent& parent,
                       size_t index);
  void RegisterTab(const Tab& tab, const NodeParent& parent, size_t index);
  void UnregisterSubtree(const SidebarNode& node);
  void UnregisterTab(const Tab& tab);
  void ReindexSiblings(const NodeParent& parent, size_t from_index = 0);

  // Low-level structural primitives (no undo registration).
  std::optional<size_t> AttachNode(SidebarNode node,
                                   const NodeParent& parent,
                                   std::optional<size_t> position);
  std::optional<std::pair<SidebarNode, size_t>> DetachNode(const ItemID& id);
  std::vector<SavedPinnedUrl> ApplyPinnedRule(
      SidebarNode& node,
      const std::optional<NodeParent>& from_section,
      const std::optional<NodeParent>& to_section);
  void RestorePinnedUrls(const std::vector<SavedPinnedUrl>& saved);

  void CollectArchiveRecords(const SidebarNode& node,
                             const NodeParent& parent,
                             const std::string& reason,
                             TimestampSec now,
                             std::vector<ArchivedTabRecord>* out) const;
  std::vector<SelectionSlot> RetargetSelections(const ItemID& old_id,
                                                const ItemID& new_id);
  void RestoreSelections(const std::vector<SelectionSlot>& slots,
                         const ItemID& expected_current_id,
                         const ItemID& restore_id);
  void RecordFocusedSpace(const SpaceID& space_id);

  // Split helper: removes pane from split, rebalances fractions, collapses if
  // 1 pane left.
  struct TakenPane {
    Tab tab;
    size_t pane_index = 0;
    std::vector<double> previous_fractions;
    std::optional<ItemID> previous_focused_pane_id;
    std::optional<CollapseInfo> collapsed;
    Split split_metadata;  // id, orientation, custom_title, icon_override
  };
  std::optional<TakenPane> TakePane(const ItemID& tab_id,
                                    const ItemID& split_id);
  bool RestoreTakenPane(const TakenPane& taken);

  // Auto-archive recursive sweep helper.
  bool SweepExpiredList(std::vector<SidebarNode>& list,
                        const NodeParent& parent,
                        TimestampSec cutoff,
                        TimestampSec now,
                        const SpaceID& space_id,
                        const ProfileID& profile_id,
                        const std::set<ItemID>& shown_tabs,
                        std::vector<ArchivedTabRecord>* archived,
                        std::vector<NodeParent>* changed_parents);

  // Helper to deep-clone a node with fresh UUIDs.
  static SidebarNode DeepCloneNode(const SidebarNode& node);

  // Rebuilds space/profile/window index maps after vector insertion/erasure.
  void RebuildContainerIndexMaps();

  std::vector<Profile> profiles_;
  std::vector<Space> spaces_;
  std::vector<BrowserWindowState> windows_;
  std::vector<RoutingRule> routing_rules_;
  RoutingDestination default_destination_{
      RoutingDestinationKind::kLittleOpen, std::nullopt, std::nullopt};

  std::vector<SpaceID> focused_space_order_;
  std::set<ItemID> shown_tab_ids_;

  std::unordered_map<ItemID, NodeIndexEntry> index_;
  std::unordered_map<ItemID, NodeParent> parent_by_id_;
  std::unordered_map<SpaceID, size_t> space_index_by_id_;
  std::unordered_map<ProfileID, size_t> profile_index_by_id_;
  std::unordered_map<WindowID, size_t> window_index_by_id_;
  std::unordered_set<std::string> unavailable_profile_dirs_;

  std::vector<Observer*> observers_;
  raw_ptr<ArchiveSink> archive_sink_ = nullptr;

  std::vector<UndoStep> undo_stack_;
  std::vector<UndoStep> redo_stack_;
  bool is_undoing_or_redoing_ = false;
  uint64_t tree_revision_ = 0;
  uint64_t undo_generation_ = 0;
};

}  // namespace open_unified

#endif  // OPEN_UNIFIED_CORE_MODEL_BROWSER_MODEL_H_
