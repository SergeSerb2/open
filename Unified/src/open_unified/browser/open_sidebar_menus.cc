// Copyright 2026 The Open Authors. All rights reserved.

#include "open_unified/browser/open_sidebar_menus.h"

#include <algorithm>
#include <functional>
#include <map>
#include <utility>

#include "base/memory/raw_ref.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/string_util.h"
#include "base/strings/utf_string_conversions.h"
#include "build/build_config.h"
#include "open_unified/browser/open_browser_service.h"
#include "open_unified/browser/open_model_util.h"
#include "open_unified/core/model/browser_model.h"
#include "ui/base/accelerators/accelerator.h"
#include "ui/base/models/menu_separator_types.h"
#include "ui/events/event_constants.h"
#include "ui/events/keycodes/keyboard_codes.h"
#include "url/gurl.h"

namespace open_unified {

SidebarMenuCommand::SidebarMenuCommand() = default;
SidebarMenuCommand::SidebarMenuCommand(const SidebarMenuCommand&) = default;
SidebarMenuCommand::SidebarMenuCommand(SidebarMenuCommand&&) noexcept =
    default;
SidebarMenuCommand& SidebarMenuCommand::operator=(const SidebarMenuCommand&) =
    default;
SidebarMenuCommand& SidebarMenuCommand::operator=(
    SidebarMenuCommand&&) noexcept = default;
SidebarMenuCommand::~SidebarMenuCommand() = default;

SidebarLiveFolderInfo::SidebarLiveFolderInfo() = default;
SidebarLiveFolderInfo::SidebarLiveFolderInfo(const SidebarLiveFolderInfo&) =
    default;
SidebarLiveFolderInfo& SidebarLiveFolderInfo::operator=(
    const SidebarLiveFolderInfo&) = default;
SidebarLiveFolderInfo::~SidebarLiveFolderInfo() = default;

SidebarFavoriteTileInfo::SidebarFavoriteTileInfo() = default;
SidebarFavoriteTileInfo::SidebarFavoriteTileInfo(
    const SidebarFavoriteTileInfo&) = default;
SidebarFavoriteTileInfo& SidebarFavoriteTileInfo::operator=(
    const SidebarFavoriteTileInfo&) = default;
SidebarFavoriteTileInfo::~SidebarFavoriteTileInfo() = default;

SidebarMenuContext::SidebarMenuContext() = default;
SidebarMenuContext::SidebarMenuContext(const SidebarMenuContext&) = default;
SidebarMenuContext& SidebarMenuContext::operator=(const SidebarMenuContext&) =
    default;
SidebarMenuContext::~SidebarMenuContext() = default;

namespace {

using Action = SidebarMenuAction;

#if BUILDFLAG(IS_MAC)
constexpr int kPrimary = ui::EF_COMMAND_DOWN;
#else
constexpr int kPrimary = ui::EF_CONTROL_DOWN;
#endif

std::u16string U16(std::string_view s) {
  return base::UTF8ToUTF16(s);
}

SidebarMenuCommand Cmd(Action action) {
  SidebarMenuCommand c;
  c.action = action;
  return c;
}

SidebarMenuCommand NodeCmd(Action action, const ItemID& node_id) {
  SidebarMenuCommand c = Cmd(action);
  c.node_id = node_id;
  return c;
}

SidebarMenuCommand SpaceCmd(Action action, const SpaceID& space_id) {
  SidebarMenuCommand c = Cmd(action);
  c.space_id = space_id;
  return c;
}

SidebarMenuCommand IdsCmd(Action action, std::vector<ItemID> ids) {
  SidebarMenuCommand c = Cmd(action);
  c.selected_node_ids = std::move(ids);
  return c;
}

SidebarMenuCommand Flagged(SidebarMenuCommand c, bool flag) {
  c.flag = flag;
  return c;
}

// ---------------------------------------------------------------------------
// The model. One delegate serves the root and every submenu; the root owns
// the submenus, the per-row commands and the callback.

class SidebarMenuModel : public ui::SimpleMenuModel::Delegate,
                         public ui::SimpleMenuModel {
 public:
  explicit SidebarMenuModel(SidebarMenuActionCallback on_action)
      : ui::SimpleMenuModel(this), on_action_(std::move(on_action)) {}
  SidebarMenuModel(const SidebarMenuModel&) = delete;
  SidebarMenuModel& operator=(const SidebarMenuModel&) = delete;
  ~SidebarMenuModel() override = default;

  struct Entry {
    SidebarMenuCommand command;
    bool enabled = true;
    bool checked = false;
    std::optional<ui::Accelerator> accelerator;
  };

  int NewEntry(Entry entry) {
    const int id = next_id_++;
    entries_[id] = std::move(entry);
    return id;
  }

  ui::SimpleMenuModel* NewSubmenu() {
    submenus_.push_back(std::make_unique<ui::SimpleMenuModel>(this));
    return submenus_.back().get();
  }

  // ui::SimpleMenuModel::Delegate:
  bool IsCommandIdChecked(int command_id) const override {
    auto it = entries_.find(command_id);
    return it != entries_.end() && it->second.checked;
  }
  bool IsCommandIdEnabled(int command_id) const override {
    auto it = entries_.find(command_id);
    return it == entries_.end() || it->second.enabled;
  }
  void ExecuteCommand(int command_id, int event_flags) override {
    auto it = entries_.find(command_id);
    if (it == entries_.end() || !it->second.enabled ||
        it->second.command.action == Action::kNone || !on_action_) {
      return;
    }
    // The handler may delete this model (it closes the menu): copy first.
    SidebarMenuCommand command = it->second.command;
    command.event_flags = event_flags;
    SidebarMenuActionCallback callback = on_action_;
    callback.Run(command);
  }
  bool GetAcceleratorForCommandId(
      int command_id,
      ui::Accelerator* accelerator) const override {
    auto it = entries_.find(command_id);
    if (it == entries_.end() || !it->second.accelerator) {
      return false;
    }
    *accelerator = *it->second.accelerator;
    return true;
  }

 private:
  SidebarMenuActionCallback on_action_;
  std::map<int, Entry> entries_;
  std::vector<std::unique_ptr<ui::SimpleMenuModel>> submenus_;
  int next_id_ = 1;
};

// ---------------------------------------------------------------------------
// Builder: SidebarMenus.swift, one function per Swift menu.

class Builder {
 public:
  Builder(const SidebarMenuContext& ctx, SidebarMenuModel* root)
      : ctx_(ctx), model_(*ctx.model), root_(root) {}

  // --- Row helpers ------------------------------------------------------------
  void Item(ui::SimpleMenuModel* m,
            std::u16string title,
            SidebarMenuCommand command,
            bool enabled = true,
            std::optional<ui::Accelerator> accelerator = std::nullopt) {
    SidebarMenuModel::Entry e;
    e.command = std::move(command);
    e.enabled = enabled;
    e.accelerator = accelerator;
    m->AddItem(root_->NewEntry(std::move(e)), title);
  }
  // A row with a checkmark state (NSMenuItem.state). Rows with Action::kNone
  // are the checked "already here" rows that do nothing.
  void Check(ui::SimpleMenuModel* m,
             std::u16string title,
             SidebarMenuCommand command,
             bool checked,
             bool enabled = true) {
    SidebarMenuModel::Entry e;
    e.command = std::move(command);
    e.enabled = enabled;
    e.checked = checked;
    m->AddCheckItem(root_->NewEntry(std::move(e)), title);
  }
  // A disabled informational row ("Show media from:", Live Folder notes).
  void Note(ui::SimpleMenuModel* m, std::u16string title) {
    Item(m, std::move(title), Cmd(Action::kNone), /*enabled=*/false);
  }
  void Sep(ui::SimpleMenuModel* m) { m->AddSeparator(ui::NORMAL_SEPARATOR); }
  ui::SimpleMenuModel* Sub(ui::SimpleMenuModel* m,
                           std::u16string title,
                           bool enabled = true) {
    ui::SimpleMenuModel* sub = root_->NewSubmenu();
    SidebarMenuModel::Entry e;
    e.enabled = enabled;
    m->AddSubMenu(root_->NewEntry(std::move(e)), title, sub);
    return sub;
  }

  // --- Model reads ---------------------------------------------------------------
  const Tab* CurrentTab() const {
    return ctx_->current_tab_id ? model_->FindTab(*ctx_->current_tab_id)
                               : nullptr;
  }
  bool IsCurrent(const Tab& tab) const {
    return ctx_->current_tab_id && *ctx_->current_tab_id == tab.id;
  }
  std::optional<SpaceID> SpaceOf(const ItemID& id) const {
    return model_util::SpaceOfNode(*model_, id);
  }
  std::u16string SpaceTitle(const Space& space) const {
    return U16(model_->DisplayTitleForSpace(space.id));
  }

  // --- Shared items -------------------------------------------------------------
  // Copy Link; the selected tab's row shows Copy URL's Cmd+Shift+C.
  void CopyLink(ui::SimpleMenuModel* m, const Tab& tab) {
    std::optional<ui::Accelerator> accel;
    if (IsCurrent(tab)) {
      accel = ui::Accelerator(ui::VKEY_C, kPrimary | ui::EF_SHIFT_DOWN);
    }
    Item(m, u"Copy Link", Flagged(NodeCmd(Action::kCopyLink, tab.id), false),
         true, accel);
  }

  // "Share >": this machine's share services (none on Windows / Linux).
  void Share(ui::SimpleMenuModel* m, const ItemID& node_id, bool page) {
    const bool any = !ctx_->share_services.empty();
    ui::SimpleMenuModel* sub = Sub(m, u"Share", any);
    for (const SidebarShareService& s : ctx_->share_services) {
      SidebarMenuCommand c = page ? Cmd(Action::kSharePageVia)
                                  : NodeCmd(Action::kShareVia, node_id);
      c.text = s.id;
      Item(sub, s.title, std::move(c));
    }
  }

  // Mute / Unmute; disabled for a silent, unmuted tab.
  void Mute(ui::SimpleMenuModel* m, const Tab& tab) {
    Item(m, tab.is_muted ? u"Unmute" : u"Mute",
         NodeCmd(Action::kToggleMute, tab.id),
         tab.live_state.is_audible || tab.is_muted);
  }

  void Customize(ui::SimpleMenuModel* m, const Tab& tab) {
    if (ctx_->is_incognito || !ctx_->customizable_tab_ids.contains(tab.id)) {
      return;
    }
    Item(m, u"Customize Page…", NodeCmd(Action::kCustomizePage, tab.id));
  }

  // "Add Split View" on the selected tab, "Open in Split View" on another.
  void SplitItem(ui::SimpleMenuModel* m, const Tab& tab) {
    if (IsCurrent(tab)) {
      Item(m, u"Add Split View", NodeCmd(Action::kAddSplitView, tab.id));
    } else {
      Item(m, u"Open in Split View",
           NodeCmd(Action::kOpenInSplitView, tab.id));
    }
  }

  void EditPinnedPage(ui::SimpleMenuModel* m, const Tab& tab) {
    ui::SimpleMenuModel* sub = Sub(m, u"Edit Pinned Page");
    const bool left =
        tab.pinned_url.has_value() && !tab.pinned_url->empty() &&
        GURL(*tab.pinned_url) != GURL(tab.url);
    Item(sub, u"Replace Pinned URL with Current",
         NodeCmd(Action::kReplacePinnedUrl, tab.id), left);
    Item(sub, u"Edit…", NodeCmd(Action::kEditPinnedUrl, tab.id));
  }

  // Ordinary (non-live) folders of a Space in sidebar order (Pinned, then
  // Today), with nesting depth.
  void SpaceFolders(const std::vector<SidebarNode>& nodes,
                    int depth,
                    std::vector<std::pair<const Folder*, int>>* out) const {
    for (const SidebarNode& node : nodes) {
      const Folder* folder = node.as_folder();
      if (!folder || folder->live.has_value()) {
        continue;
      }
      out->emplace_back(folder, depth);
      SpaceFolders(folder->children, depth + 1, out);
    }
  }

  // Folder targets appended to "Move to >".
  void FolderMoveItems(ui::SimpleMenuModel* m,
                       const std::vector<ItemID>& ids,
                       const std::optional<SpaceID>& space_id) {
    if (ctx_->is_incognito || ctx_->hides_space_chrome || !space_id) {
      return;
    }
    const Space* space = model_->FindSpace(*space_id);
    if (!space) {
      return;
    }
    std::vector<std::pair<const Folder*, int>> all;
    SpaceFolders(space->pinned, 0, &all);
    SpaceFolders(space->today, 0, &all);
    std::vector<std::pair<const Folder*, int>> candidates;
    for (const auto& candidate : all) {
      const NodeParent dest{NodeParentKind::kFolder, candidate.first->id};
      if (std::all_of(ids.begin(), ids.end(), [&](const ItemID& id) {
            return model_->CanMoveNode(id, dest);
          })) {
        candidates.push_back(candidate);
      }
    }
    if (candidates.empty()) {
      return;
    }
    Sep(m);
    Note(m, u"Folders");
    for (const auto& [folder, depth] : candidates) {
      const NodeParent dest{NodeParentKind::kFolder, folder->id};
      const bool already_here =
          std::all_of(ids.begin(), ids.end(), [&](const ItemID& id) {
            return model_->GetParent(id) == dest;
          });
      // Views menus have no indentation level: indent with spaces.
      std::u16string title(static_cast<size_t>(depth) * 3, u' ');
      title += folder->title.empty() ? u"Folder" : U16(folder->title);
      if (ids.size() == 1) {
        SidebarMenuCommand c;
        if (!already_here) {
          c = NodeCmd(Action::kMove, ids[0]);
          c.parent = dest;
          c.index = folder->children.size();
        }
        Check(m, title, std::move(c), already_here);
      } else {
        SidebarMenuCommand c = IdsCmd(Action::kMoveNodes, ids);
        c.parent = dest;
        c.index = folder->children.size();
        Item(m, title, std::move(c), !already_here);
      }
    }
  }

  // "Move to >": every Space (the current one checked), "New Space...", and
  // eligible folders of the current Space.
  void MoveTo(ui::SimpleMenuModel* m, const ItemID& node_id) {
    ui::SimpleMenuModel* sub = Sub(m, u"Move to");
    const std::optional<SpaceID> current = SpaceOf(node_id);
    for (const Space& space : model_->spaces()) {
      const bool here = current && *current == space.id;
      SidebarMenuCommand c;
      if (!here) {
        c = NodeCmd(Action::kMoveToSpace, node_id);
        c.space_id = space.id;
      }
      Check(sub, SpaceTitle(space), std::move(c), here);
    }
    Sep(sub);
    Item(sub, u"New Space…", NodeCmd(Action::kMoveToNewSpace, node_id));
    FolderMoveItems(sub, {node_id}, current);
  }

  void MoveToMany(ui::SimpleMenuModel* m, const std::vector<ItemID>& ids) {
    ui::SimpleMenuModel* sub = Sub(m, u"Move to");
    std::set<SpaceID> current;
    bool any_outside = false;
    for (const ItemID& id : ids) {
      if (std::optional<SpaceID> s = SpaceOf(id)) {
        current.insert(*s);
      } else {
        any_outside = true;
      }
    }
    for (const Space& space : model_->spaces()) {
      SidebarMenuCommand c = IdsCmd(Action::kMoveNodesToSpace, ids);
      c.space_id = space.id;
      // Swift compares only the rows that have a Space (Favorites have none).
      const bool all_here =
          current.size() == 1 && *current.begin() == space.id;
      Item(sub, SpaceTitle(space), std::move(c), !all_here);
    }
    Sep(sub);
    Item(sub, u"New Space…", IdsCmd(Action::kMoveNodesToNewSpace, ids),
         !ctx_->hides_space_chrome);
    const bool one_space = !any_outside && current.size() == 1;
    FolderMoveItems(sub, ids,
                    one_space ? std::optional<SpaceID>(*current.begin())
                              : std::nullopt);
  }

  // After "Archive Tab" / "Archive Item" of a Today row: Archive Other Tabs
  // (Option), Archive Tabs Below, Archive Tabs Above (Option).
  void ArchiveAlternates(ui::SimpleMenuModel* m, const ItemID& node_id) {
    const std::optional<SpaceID> space_id = SpaceOf(node_id);
    const Space* space = space_id ? model_->FindSpace(*space_id) : nullptr;
    if (!space) {
      return;
    }
    std::set<ItemID> keep(ctx_->selected_node_ids.begin(),
                          ctx_->selected_node_ids.end());
    keep.insert(node_id);
    std::vector<ItemID> below, above;
    std::optional<size_t> index;
    for (size_t i = 0; i < space->today.size(); ++i) {
      if (space->today[i].id() == node_id) {
        index = i;
      }
    }
    if (index) {
      for (size_t i = 0; i < space->today.size(); ++i) {
        if (i < *index) {
          above.push_back(space->today[i].id());
        } else if (i > *index) {
          below.push_back(space->today[i].id());
        }
      }
    }
    if (ctx_->option_held) {
      const bool others = std::any_of(
          space->today.begin(), space->today.end(),
          [&](const SidebarNode& n) { return !keep.contains(n.id()); });
      SidebarMenuCommand c = SpaceCmd(Action::kArchiveOtherTabs, space->id);
      c.selected_node_ids.assign(keep.begin(), keep.end());
      Item(m, u"Archive Other Tabs", std::move(c), others);
      const bool has_above = !above.empty();
      Item(m, u"Archive Tabs Above",
           IdsCmd(Action::kArchiveNodes, std::move(above)), has_above);
    } else {
      const bool has_below = !below.empty();
      Item(m, u"Archive Tabs Below",
           IdsCmd(Action::kArchiveNodes, std::move(below)), has_below);
    }
  }

  // --- Menus ----------------------------------------------------------------------
  bool Node(ui::SimpleMenuModel* m, const ItemID& node_id) {
    const std::vector<ItemID>& sel = ctx_->selected_node_ids;
    if (sel.size() > 1 &&
        std::find(sel.begin(), sel.end(), node_id) != sel.end()) {
      Selection(m, sel);
      return true;
    }
    const SidebarNode* node = model_->FindNode(node_id);
    if (!node) {
      return false;
    }
    if (const Folder* folder = node->as_folder()) {
      FolderMenu(m, *folder);
      return true;
    }
    if (const Split* split = node->as_split()) {
      SplitMenu(m, *split);
      return true;
    }
    const Tab& tab = *node->as_tab();
    const std::optional<NodeParentKind> section =
        model_util::SectionOfNode(*model_, tab.id);
    if (section == NodeParentKind::kFavorites) {
      FavoriteMenu(m, tab);
    } else if (section == NodeParentKind::kSpacePinned) {
      PinnedTab(m, tab);
    } else {
      TodayTab(m, tab);
    }
    return true;
  }

  // Today (unpinned) tab: capture session 3 Part D order.
  void TodayTab(ui::SimpleMenuModel* m, const Tab& tab) {
    if (IsEaselTab(tab)) {
      return Easel(m, tab);
    }
    if (IsNoteTab(tab)) {
      return NoteRow(m, tab);
    }
    if (ctx_->is_incognito) {
      Item(m, u"Copy Link", NodeCmd(Action::kCopyLink, tab.id));
      Item(m, u"Open in Split View", NodeCmd(Action::kOpenInSplitView, tab.id));
      Item(m, u"Duplicate", NodeCmd(Action::kDuplicate, tab.id));
      Item(m, u"Close Tab", NodeCmd(Action::kClose, tab.id));
      return;
    }
    CopyLink(m, tab);
    Share(m, tab.id, /*page=*/false);
    Sep(m);
    Item(m, u"Change Icon…", NodeCmd(Action::kChangeIcon, tab.id));
    Item(m, u"Rename…", NodeCmd(Action::kBeginRename, tab.id));
    Mute(m, tab);
    Customize(m, tab);
    Sep(m);
    SplitItem(m, tab);
    Item(m, u"Duplicate", NodeCmd(Action::kDuplicate, tab.id));
    MoveTo(m, tab.id);
    Item(m, u"New Folder with Tab",
         IdsCmd(Action::kNewFolderWithSelection, {tab.id}));
    Sep(m);
    if (!ctx_->option_held) {
      Item(m, u"Archive Tab", NodeCmd(Action::kClose, tab.id));
    }
    ArchiveAlternates(m, tab.id);
  }

  // The shared pinned / Favorite list up to its last separator.
  void PinnedItems(ui::SimpleMenuModel* m,
                   const Tab& tab,
                   bool include_new_folder) {
    CopyLink(m, tab);
    Share(m, tab.id, /*page=*/false);
    Sep(m);
    Item(m, u"Change Icon…", NodeCmd(Action::kChangeIcon, tab.id));
    Item(m, u"Rename…", NodeCmd(Action::kBeginRename, tab.id));
    Mute(m, tab);
    Customize(m, tab);
    EditPinnedPage(m, tab);
    Sep(m);
    SplitItem(m, tab);
    Item(m, u"Duplicate", NodeCmd(Action::kDuplicate, tab.id));
    MoveTo(m, tab.id);
    if (include_new_folder) {
      Item(m, u"New Folder with Tab",
           IdsCmd(Action::kNewFolderWithSelection, {tab.id}));
    }
    Sep(m);
  }

  void PinnedTab(ui::SimpleMenuModel* m, const Tab& tab) {
    if (IsEaselTab(tab)) {
      return Easel(m, tab);
    }
    if (IsNoteTab(tab)) {
      return NoteRow(m, tab);
    }
    PinnedItems(m, tab, /*include_new_folder=*/true);
    Item(m, u"Remove Pin", NodeCmd(Action::kUnpin, tab.id));
  }

  // Easel row (C-measurements-s4 `e7-row-menu-ax`).
  void Easel(ui::SimpleMenuModel* m, const Tab& tab) {
    Item(m, u"Copy Link", NodeCmd(Action::kCopyLink, tab.id));
    Item(m, u"Save as Web Page…", NodeCmd(Action::kExportEasel, tab.id));
    Sep(m);
    Item(m, u"Change Icon…", NodeCmd(Action::kChangeIcon, tab.id));
    Item(m, u"Rename…", NodeCmd(Action::kBeginRename, tab.id));
    Sep(m);
    Item(m, u"Add Split View", NodeCmd(Action::kAddSplitView, tab.id));
    MoveTo(m, tab.id);
    Sep(m);
    Item(m, u"Remove Easel from Sidebar", NodeCmd(Action::kClose, tab.id));
    Item(m, u"Delete Easel", NodeCmd(Action::kDeleteEasel, tab.id));
  }

  // Note row, in the Easel row's order. Copy Link stays disabled.
  void NoteRow(ui::SimpleMenuModel* m, const Tab& tab) {
    Item(m, u"Copy Link", NodeCmd(Action::kCopyLink, tab.id), false);
    Item(m, u"Export Note…", NodeCmd(Action::kExportNote, tab.id));
    Sep(m);
    Item(m, u"Change Icon…", NodeCmd(Action::kChangeIcon, tab.id));
    Item(m, u"Rename…", NodeCmd(Action::kBeginRename, tab.id));
    Sep(m);
    Item(m, u"Add Split View", NodeCmd(Action::kAddSplitView, tab.id));
    MoveTo(m, tab.id);
    Sep(m);
    Item(m, u"Remove Note from Sidebar", NodeCmd(Action::kClose, tab.id));
    Item(m, u"Delete Note", NodeCmd(Action::kDeleteNote, tab.id));
  }

  // Favorite tile: Live Calendar items, tile switches, the pinned list and
  // "Remove Favorite" last.
  void FavoriteMenu(ui::SimpleMenuModel* m, const Tab& tab) {
    if (ctx_->favorite_tile) {
      LiveCalendarItems(m, tab, *ctx_->favorite_tile);
      TileItems(m, tab, *ctx_->favorite_tile);
    }
    PinnedItems(m, tab, /*include_new_folder=*/false);
    Item(m, u"Remove Favorite", NodeCmd(Action::kRemoveFavorite, tab.id));
  }

  void TileItems(ui::SimpleMenuModel* m,
                 const Tab& tab,
                 const SidebarFavoriteTileInfo& tile) {
    bool any = false;
    if (tile.supports_unread_badge) {
      Check(m, u"Show Unread Badge",
            Flagged(NodeCmd(Action::kSetShowsUnreadBadge, tab.id),
                    !tile.shows_unread_badge),
            tile.shows_unread_badge);
      any = true;
    }
    if (tile.is_calendar) {
      if (tile.live_calendar_enabled) {
        Check(m, u"Show Time to Next Meeting",
              Flagged(NodeCmd(Action::kSetShowsTimeToNextMeeting, tab.id),
                      !tile.shows_time_to_next_meeting),
              tile.shows_time_to_next_meeting);
      }
      Item(m,
           tile.live_calendar_enabled ? u"Disable Live Calendar"
                                      : u"Enable Live Calendar",
           Flagged(NodeCmd(Action::kSetLiveCalendarEnabled, tab.id),
                   !tile.live_calendar_enabled));
      any = true;
    }
    if (any) {
      Sep(m);
    }
  }

  void LiveCalendarItems(ui::SimpleMenuModel* m,
                         const Tab& tab,
                         const SidebarFavoriteTileInfo& tile) {
    if (!tile.is_calendar || !tile.live_calendar_enabled) {
      return;
    }
    if (tile.meeting_link) {
      ui::SimpleMenuModel* show = Sub(m, u"Show Meeting Link");
      Note(show, U16(*tile.meeting_link));
      Sep(show);
      SidebarMenuCommand copy = NodeCmd(Action::kCopyMeetingLink, tab.id);
      copy.text = *tile.meeting_link;
      Item(show, u"Copy Link", std::move(copy));
      Item(show, u"Dismiss", NodeCmd(Action::kDismissMeeting, tab.id));
    }
    ui::SimpleMenuModel* remind = Sub(m, u"Meeting Reminder");
    static constexpr std::pair<SidebarMeetingReminder, const char16_t*>
        kChoices[] = {
            {SidebarMeetingReminder::kNever, u"Never"},
            {SidebarMeetingReminder::kOnStart, u"On Start"},
            {SidebarMeetingReminder::kTwoMinutes, u"Two Minutes Before"},
            {SidebarMeetingReminder::kFiveMinutes, u"Five Minutes Before"},
            {SidebarMeetingReminder::kTenMinutes, u"Ten Minutes Before"},
        };
    for (const auto& [value, title] : kChoices) {
      SidebarMenuCommand c = NodeCmd(Action::kSetMeetingReminder, tab.id);
      c.value = static_cast<int>(value);
      Check(remind, title, std::move(c), tile.reminder == value);
    }
    Sep(m);
  }

  // Split row (session 12 C12-D2-2).
  void SplitMenu(ui::SimpleMenuModel* m, const Split& split) {
    if (!ctx_->is_incognito) {
      Item(m, u"Share Split View…", NodeCmd(Action::kShareSplit, split.id));
      Sep(m);
    }
    Item(m, u"Separate All Tabs", NodeCmd(Action::kSeparateSplit, split.id));
    Item(m, u"Add Tab…", NodeCmd(Action::kAddTabToSplit, split.id),
         split.panes.size() < 4);
    const bool horizontal = split.orientation == SplitOrientation::kHorizontal;
    Item(m,
         horizontal ? u"Convert to Vertical Split View"
                    : u"Convert to Horizontal Split View",
         Flagged(NodeCmd(Action::kSetSplitOrientation, split.id), horizontal));
    Sep(m);
    Note(m, u"Tab Options");
    for (const Tab& pane : split.panes) {
      ui::SimpleMenuModel* sub = Sub(m, SplitPaneMenuTitle(pane));
      SidebarMenuCommand separate = NodeCmd(Action::kSeparatePane, split.id);
      separate.secondary_id = pane.id;
      Item(sub, u"Separate from Split View", std::move(separate));
      Sep(sub);
      Share(sub, pane.id, /*page=*/false);
      Mute(sub, pane);
      Item(sub, u"Copy Link",
           Flagged(NodeCmd(Action::kCopyLink, pane.id), false));
      Item(sub, u"Copy link as Markdown",
           Flagged(NodeCmd(Action::kCopyLink, pane.id), true));
      Sep(sub);
      Item(sub, u"Archive Item", NodeCmd(Action::kClose, pane.id));
    }
    Sep(m);
    const bool customized =
        (split.custom_title && !split.custom_title->empty()) ||
        split.icon_override.has_value();
    if (customized) {
      Item(m, u"Reset Name and Icon",
           NodeCmd(Action::kResetSplitCustomization, split.id));
    }
    Item(m, u"Change Icon…", NodeCmd(Action::kChangeIcon, split.id));
    Item(m, u"Rename…", NodeCmd(Action::kBeginRename, split.id));
    Sep(m);
    Item(m, u"Duplicate", NodeCmd(Action::kDuplicate, split.id));
    if (!ctx_->is_incognito) {
      MoveTo(m, split.id);
      Item(m, u"New Folder with Split View",
           IdsCmd(Action::kNewFolderWithSelection, {split.id}));
    }
    Sep(m);
    if (ctx_->is_incognito) {
      Item(m, u"Close Split View", NodeCmd(Action::kClose, split.id));
      return;
    }
    if (!ctx_->option_held) {
      Item(m, u"Archive Item", NodeCmd(Action::kClose, split.id));
    }
    ArchiveAlternates(m, split.id);
  }

  // Folder (F0119, F0134).
  void FolderMenu(ui::SimpleMenuModel* m, const Folder& folder) {
    if (folder.live.has_value() && !ctx_->is_incognito) {
      return LiveFolder(m, folder);
    }
    Item(m, u"Share Folder…", NodeCmd(Action::kShareFolder, folder.id));
    Sep(m);
    Item(m, u"New Nested Folder…",
         NodeCmd(Action::kNewNestedFolder, folder.id));
    Item(m, u"Turn “" + U16(folder.title) + u"” into Space",
         NodeCmd(Action::kTurnFolderIntoSpace, folder.id),
         !ctx_->hides_space_chrome);
    if (!folder.children.empty()) {
      Item(m, u"Copy All Links",
           Flagged(NodeCmd(Action::kCopyAllLinks, folder.id), false));
      Item(m, u"Copy All Links as Markdown",
           Flagged(NodeCmd(Action::kCopyAllLinks, folder.id), true));
    }
    Sep(m);
    Item(m, u"Change Icon…", NodeCmd(Action::kChangeIcon, folder.id));
    Item(m, u"Rename…", NodeCmd(Action::kBeginRename, folder.id));
    Sep(m);
    Item(m, u"Duplicate", NodeCmd(Action::kDuplicate, folder.id));
    MoveTo(m, folder.id);
    Sep(m);
    Item(m, u"Delete", NodeCmd(Action::kDeleteFolder, folder.id));
  }

  // Live Folder (live-data 2.2; order is Swift's guess).
  void LiveFolder(ui::SimpleMenuModel* m, const Folder& folder) {
    const SidebarLiveFolderInfo info =
        ctx_->live_folder.value_or(SidebarLiveFolderInfo());
    Note(m, U16(folder.title));
    if (info.last_fetch_failed) {
      Note(m, u"Failed to update");
    }
    Sep(m);
    std::vector<SidebarLiveRepository> repos = info.repositories;
    std::sort(repos.begin(), repos.end(),
              [](const SidebarLiveRepository& a,
                 const SidebarLiveRepository& b) {
                return base::ToLowerASCII(a.name) < base::ToLowerASCII(b.name);
              });
    ui::SimpleMenuModel* repo_menu = Sub(m, u"Repositories");
    for (const SidebarLiveRepository& repo : repos) {
      SidebarMenuCommand c =
          Flagged(NodeCmd(Action::kSetLiveRepository, folder.id), !repo.hidden);
      c.text = repo.name;
      Check(repo_menu, U16(repo.name), std::move(c), !repo.hidden);
    }
    Sep(repo_menu);
    Note(repo_menu,
         u"This list is generated based on your currently active pull "
         u"requests.");
    ui::SimpleMenuModel* sso = Sub(m, u"Single Sign-On");
    Check(sso, u"Required", NodeCmd(Action::kOpenLiveFolderSso, folder.id),
          info.needs_sso,
          info.needs_sso && folder.live_sso_url.has_value());
    Sep(sso);
    Note(sso, u"SSO ensures all of your organizations' PRs appear");
    Item(m, u"Refresh", NodeCmd(Action::kRefreshLiveFolder, folder.id));
    Sep(m);
    Item(m, u"Copy All Links",
         Flagged(NodeCmd(Action::kCopyAllLinks, folder.id), false));
    Sep(m);
    Item(m, u"Delete Live Folder",
         NodeCmd(Action::kDeleteLiveFolder, folder.id));
  }

  // Multi-selection (capture session 8 item 6; C13-D2-6).
  void Selection(ui::SimpleMenuModel* m, const std::vector<ItemID>& ids) {
    const std::u16string count = base::NumberToString16(ids.size());
    if (ctx_->is_incognito) {
      Item(m, u"Copy Links",
           Flagged(IdsCmd(Action::kCopyLinks, ids), false));
      Item(m, u"Duplicate", IdsCmd(Action::kDuplicateNodes, ids));
      Item(m, u"Close Tabs", IdsCmd(Action::kArchiveNodes, ids));
      return;
    }
    std::vector<ItemID> folders, tabs;
    std::vector<const Tab*> tab_objects;
    for (const ItemID& id : ids) {
      const SidebarNode* node = model_->FindNode(id);
      if (!node) {
        continue;
      }
      if (node->as_folder()) {
        folders.push_back(id);
      } else {
        tabs.push_back(id);
        if (const Tab* tab = node->as_tab()) {
          tab_objects.push_back(tab);
        }
      }
    }
    const bool archive_folder_tabs = ArchivesFolderTabs(folders, tabs);
    std::function<bool(const SidebarNode&)> has_links =
        [&](const SidebarNode& node) -> bool {
      if (const Tab* tab = node.as_tab()) {
        return !IsNoteTab(*tab);
      }
      if (const Split* split = node.as_split()) {
        return !split->panes.empty();
      }
      const Folder* folder = node.as_folder();
      return std::any_of(folder->children.begin(), folder->children.end(),
                         has_links);
    };
    const bool can_copy =
        std::any_of(ids.begin(), ids.end(), [&](const ItemID& id) {
          const SidebarNode* node = model_->FindNode(id);
          return node && has_links(*node);
        });
    const bool only_tabs =
        folders.empty() && tab_objects.size() == ids.size();
    const bool any_favorite =
        std::any_of(ids.begin(), ids.end(), [&](const ItemID& id) {
          return model_util::SectionOfNode(*model_, id) ==
                 NodeParentKind::kFavorites;
        });
    const bool can_split =
        only_tabs && ids.size() >= 2 && ids.size() <= 4 && !any_favorite;

    if (ctx_->option_held) {
      Item(m, u"Copy links as Markdown",
           Flagged(IdsCmd(Action::kCopyLinks, ids), true), can_copy);
    } else {
      Item(m, u"Copy Links", Flagged(IdsCmd(Action::kCopyLinks, ids), false),
           can_copy);
    }
    Item(m, u"Share " + count + u" Items…",
         IdsCmd(Action::kShareNodes, ids), can_copy);
    Sep(m);
    if (folders.empty()) {
      const bool can_mute =
          std::any_of(tab_objects.begin(), tab_objects.end(), [](const Tab* t) {
            return t->live_state.is_audible || t->is_muted;
          });
      const bool unmute =
          std::none_of(tab_objects.begin(), tab_objects.end(),
                       [](const Tab* t) {
                         return t->live_state.is_audible && !t->is_muted;
                       }) &&
          std::any_of(tab_objects.begin(), tab_objects.end(),
                      [](const Tab* t) { return t->is_muted; });
      std::vector<ItemID> toggles;
      for (const Tab* t : tab_objects) {
        if ((t->live_state.is_audible || t->is_muted) &&
            t->is_muted == unmute) {
          toggles.push_back(t->id);
        }
      }
      Item(m, u"Change Icon…", Cmd(Action::kNone), false);
      Item(m, unmute ? u"Unmute" : u"Mute",
           Flagged(IdsCmd(Action::kSetMuted, std::move(toggles)), !unmute),
           can_mute);
      Sep(m);
    }
    Item(m, u"Open in Split View", IdsCmd(Action::kSplitNodes, ids),
         can_split);
    if (folders.empty()) {
      Item(m, u"Duplicate", IdsCmd(Action::kDuplicateNodes, ids));
      if (ctx_->option_held) {
        // Pin Tabs / Unpin Tabs: splits are skipped (Cmd+D rows).
        std::vector<ItemID> pinnable;
        bool all_pinned = !tab_objects.empty();
        for (const Tab* t : tab_objects) {
          const auto section = model_util::SectionOfNode(*model_, t->id);
          if (section == NodeParentKind::kFavorites) {
            continue;
          }
          pinnable.push_back(t->id);
          all_pinned &= section == NodeParentKind::kSpacePinned;
        }
        const bool any_pinnable = !pinnable.empty();
        Item(m, all_pinned ? u"Unpin Tabs" : u"Pin Tabs",
             Flagged(IdsCmd(Action::kSetPinned, std::move(pinnable)),
                     !all_pinned),
             any_pinnable && !ctx_->hides_space_chrome);
      }
    }
    MoveToMany(m, ids);
    Item(m, u"New Folder with " + count + u" Items",
         IdsCmd(Action::kNewFolderWithSelection, ids));
    Sep(m);
    if (!tabs.empty() && !archive_folder_tabs) {
      const bool only = folders.empty() && !tab_objects.empty() &&
                        tab_objects.size() == ids.size();
      const bool all_notes =
          only && std::all_of(tab_objects.begin(), tab_objects.end(),
                              [](const Tab* t) { return IsNoteTab(*t); });
      const bool all_easels =
          only && std::all_of(tab_objects.begin(), tab_objects.end(),
                              [](const Tab* t) { return IsEaselTab(*t); });
      const std::u16string title =
          all_notes    ? u"Remove Notes from Sidebar"
          : all_easels ? u"Remove Easels from Sidebar"
                       : u"Archive Tabs";
      std::set<SpaceID> today_spaces;
      bool all_today = true;
      for (const ItemID& id : ids) {
        const std::optional<NodeParent> parent = model_->GetParent(id);
        if (parent && parent->kind == NodeParentKind::kSpaceToday) {
          today_spaces.insert(parent->owner_id);
        } else {
          all_today = false;
        }
      }
      const bool one_today_space =
          folders.empty() && all_today && today_spaces.size() == 1;
      if (!(ctx_->option_held && one_today_space)) {
        Item(m, title, IdsCmd(Action::kArchiveNodes, tabs));
      }
      if (one_today_space) {
        const Space* space = model_->FindSpace(*today_spaces.begin());
        if (ctx_->option_held && space) {
          const std::set<ItemID> keep(ids.begin(), ids.end());
          const bool others = std::any_of(
              space->today.begin(), space->today.end(),
              [&](const SidebarNode& n) { return !keep.contains(n.id()); });
          SidebarMenuCommand c =
              SpaceCmd(Action::kArchiveOtherTabs, space->id);
          c.selected_node_ids = ids;
          Item(m, u"Archive Other Tabs", std::move(c), others);
          Item(m, u"Archive Tabs Above", Cmd(Action::kNone), false);
        } else {
          Item(m, u"Archive Tabs Below", Cmd(Action::kNone), false);
        }
      }
    }
    if (!folders.empty()) {
      Item(m, u"Delete",
           Flagged(IdsCmd(Action::kDeleteFolders,
                          archive_folder_tabs ? ids : folders),
                   archive_folder_tabs));
      if (archive_folder_tabs) {
        Sep(m);
      }
    }
  }

  // C13-D2-6: one ordinary root folder of tabs plus one separate Today tab
  // in the same Space deletes the folder and archives the tab together.
  bool ArchivesFolderTabs(const std::vector<ItemID>& folders,
                          const std::vector<ItemID>& tabs) const {
    if (ctx_->option_held || folders.size() != 1 || tabs.size() != 1) {
      return false;
    }
    const Folder* folder = model_->FindFolder(folders[0]);
    const Tab* tab = model_->FindTab(tabs[0]);
    if (!folder || folder->live.has_value() || folder->children.empty() ||
        !tab || IsNoteTab(*tab) || IsEaselTab(*tab)) {
      return false;
    }
    const std::optional<NodeParent> tab_parent = model_->GetParent(tab->id);
    if (!tab_parent || tab_parent->kind != NodeParentKind::kSpaceToday) {
      return false;
    }
    const std::optional<NodeParent> folder_parent =
        model_->GetParent(folder->id);
    if (!folder_parent || folder_parent->owner_id != tab_parent->owner_id ||
        (folder_parent->kind != NodeParentKind::kSpacePinned &&
         folder_parent->kind != NodeParentKind::kSpaceToday)) {
      return false;
    }
    return std::all_of(folder->children.begin(), folder->children.end(),
                       [](const SidebarNode& child) {
                         const Tab* t = child.as_tab();
                         return t && !IsNoteTab(*t) && !IsEaselTab(*t);
                       });
  }

  // Set Profile choices, then "New Profile...".
  void ProfileChoices(ui::SimpleMenuModel* m, const Space& space) {
    for (const Profile& profile : model_->profiles()) {
      SidebarMenuCommand c = SpaceCmd(Action::kSetSpaceProfile, space.id);
      c.profile_id = profile.id;
      Check(m, U16(profile.name), std::move(c), profile.id == space.profile_id);
    }
    Sep(m);
    Item(m, u"New Profile…", SpaceCmd(Action::kNewProfile, space.id));
  }

  // Space: title, "..." button, empty sidebar area, switcher icon (F0117,
  // A0414, BottomBarView switcher right-click).
  bool SpaceMenu(ui::SimpleMenuModel* m, const SpaceID& space_id) {
    const Space* space = model_->FindSpace(space_id);
    if (!space) {
      return false;
    }
    if (ctx_->hides_space_chrome) {
      Item(m, u"New Tab", Cmd(Action::kNewTab));
      return true;
    }
    Item(m, u"Change Space Icon…",
         SpaceCmd(Action::kChangeSpaceIcon, space->id));
    {
      SidebarMenuCommand rename = SpaceCmd(Action::kBeginRename, space->id);
      Item(m, u"Rename Space…", std::move(rename));
    }
    Item(m, u"Edit Theme Color…",
         SpaceCmd(Action::kEditSpaceTheme, space->id));
    ProfileChoices(Sub(m, u"Set Profile"), *space);
    if (ctx_->offers_space_header_toggle) {
      Item(m,
           ctx_->space_header_shown ? u"Hide Space Header"
                                   : u"Show Space Header",
           Flagged(SpaceCmd(Action::kSetSpaceHeaderShown, space->id),
                   !ctx_->space_header_shown));
    }
    Sep(m);
    {
      SidebarMenuCommand c = SpaceCmd(Action::kNewFolder, space->id);
      c.parent = NodeParent{NodeParentKind::kSpacePinned, space->id};
      Item(m, u"New Folder", std::move(c));
    }
    ui::SimpleMenuModel* live = Sub(m, u"Live Folders");
    Check(live, u"GitHub", SpaceCmd(Action::kToggleLiveFolder, space->id),
          ctx_->space_has_live_folder, !ctx_->is_incognito);
    Sep(m);
    Item(m, u"Share Space…", SpaceCmd(Action::kShareSpace, space->id),
         false);
    ui::SimpleMenuModel* exp = Sub(
        m, u"Export “" + SpaceTitle(*space) + u"” into Folder");
    for (const Space& other : model_->spaces()) {
      SidebarMenuCommand c =
          SpaceCmd(Action::kExportSpaceIntoFolder, space->id);
      c.secondary_id = other.id;
      Item(exp, SpaceTitle(other), std::move(c), other.id != space->id);
    }
    Sep(m);
    Item(m, u"Manage Spaces…", Cmd(Action::kManageSpaces));
    Sep(m);
    Item(m, u"Delete Space", SpaceCmd(Action::kDeleteSpace, space->id),
         model_->spaces().size() > 1);
    return true;
  }

  // Bottom-bar "+" (capture session 3 Part D): New Space, New Folder, -,
  // New Easel Ctrl+Shift+E, New Boost, -, New Split Ctrl+Shift+=, New Tab.
  // The popover (OpenPlusPopover) is the normal surface; this is its menu
  // fallback with the same rows and rules.
  void Plus(ui::SimpleMenuModel* m, const SpaceID& space_id) {
    const Tab* current = CurrentTab();
    bool can_split = false;
    if (current) {
      if (const std::optional<NodeParent> parent =
              model_->GetParent(current->id)) {
        if (parent->kind == NodeParentKind::kFavorites) {
          can_split = false;
        } else if (parent->kind == NodeParentKind::kSplitPane) {
          const Split* split = model_->FindSplit(parent->owner_id);
          can_split = split && split->panes.size() < 4;
        } else {
          can_split = true;
        }
      }
    }
    const SpaceID focused =
        !space_id.empty()
            ? space_id
            : model_util::FocusedSpace(*model_, ctx_->window_id).value_or("");
    Item(m, u"New Space", Cmd(Action::kNewSpace), !ctx_->hides_space_chrome);
    {
      SidebarMenuCommand c = SpaceCmd(Action::kNewFolder, focused);
      c.parent = NodeParent{NodeParentKind::kSpacePinned, focused};
      Item(m, u"New Folder", std::move(c),
           !focused.empty() && !ctx_->hides_space_chrome);
    }
    Sep(m);
    Item(m, u"New Note", Cmd(Action::kNewNote), !ctx_->is_incognito,
#if BUILDFLAG(IS_MAC)
         ui::Accelerator(ui::VKEY_N, ui::EF_CONTROL_DOWN | ui::EF_SHIFT_DOWN));
#else
         ui::Accelerator(ui::VKEY_N, ui::EF_ALT_DOWN | ui::EF_SHIFT_DOWN));
#endif
    Item(m, u"New Easel", Cmd(Action::kNewEasel), !ctx_->is_incognito,
         ui::Accelerator(ui::VKEY_E, ui::EF_CONTROL_DOWN | ui::EF_SHIFT_DOWN));
    Item(m, u"New Boost", Cmd(Action::kNewBoost),
         !ctx_->is_incognito && current != nullptr);
    Sep(m);
    Item(m, u"New Split", Cmd(Action::kNewSplit), can_split,
         ui::Accelerator(ui::VKEY_OEM_PLUS,
                         ui::EF_CONTROL_DOWN | ui::EF_SHIFT_DOWN));
    Item(m, u"New Tab", Cmd(Action::kNewTab), true,
         ui::Accelerator(ui::VKEY_T, kPrimary));
  }

  // Compact toolbar "More options" (capture session 9): Reload / Stop
  // Loading, Toggle Sidebar. OpenToolbarMorePopover is the normal surface.
  void ToolbarMore(ui::SimpleMenuModel* m) {
    if (ctx_->page_is_loading) {
      Item(m, u"Stop Loading", Cmd(Action::kStopLoading), ctx_->has_page,
           ui::Accelerator(ui::VKEY_OEM_PERIOD, kPrimary));
    } else {
      Item(m, u"Reload", Cmd(Action::kReload), ctx_->has_page,
           ui::Accelerator(ui::VKEY_R, kPrimary));
    }
    Item(m, u"Toggle Sidebar", Cmd(Action::kToggleSidebar), true,
         ui::Accelerator(ui::VKEY_S, kPrimary));
  }

  // URL field right-click (capture session 3 Part D).
  void UrlField(ui::SimpleMenuModel* m) {
    const bool page = ctx_->current_page_url.has_value();
    const bool tab = CurrentTab() != nullptr;
    Item(m, u"Copy URL", Cmd(Action::kCopyCurrentUrl), page);
    if (page) {
      Share(m, ItemID(), /*page=*/true);
    } else {
      Sub(m, u"Share", /*enabled=*/false);
    }
    Item(m, u"Capture…", Cmd(Action::kCapture), tab);
    Item(m, u"Capture Full Page", Cmd(Action::kCaptureFullPage), tab);
    Item(m, u"Capture in Portrait Mode", Cmd(Action::kCapturePortrait), tab);
    Sep(m);
    Item(m, u"Show as Toolbar", Flagged(Cmd(Action::kSetToolbarShown), true));
    Item(m,
         ctx_->shared_quotes_enabled ? u"Disable Shared Quotes"
                                    : u"Enable Shared Quotes",
         Flagged(Cmd(Action::kSetSharedQuotes), !ctx_->shared_quotes_enabled));
  }

  // Pinned extension action right-click. Chromium's extension context menu
  // with Open's labels (ExtensionsMenuBuilder.relabel: "Unpin",
  // "Remove from Open..."). Order: Open's choice.
  bool ToolbarAction(ui::SimpleMenuModel* m) {
    if (!ctx_->toolbar_action) {
      return false;
    }
    const SidebarToolbarActionInfo& a = *ctx_->toolbar_action;
    auto cmd = [&](Action action) {
      SidebarMenuCommand c = Cmd(action);
      c.text = a.id;
      return c;
    };
    Item(m, a.name.empty() ? u"Extension" : a.name,
         cmd(Action::kRunToolbarAction));
    if (a.has_options_page) {
      Item(m, u"Options", cmd(Action::kExtensionOptions));
    }
    Sep(m);
    Item(m, u"Unpin", cmd(Action::kUnpinToolbarAction));
    Item(m, u"Remove from Open…", cmd(Action::kRemoveExtension),
         a.can_remove);
    Item(m, u"Manage Extension", cmd(Action::kManageExtension));
    if (ctx_->developer_mode && a.has_popup) {
      Sep(m);
      Item(m, u"Inspect Popup", cmd(Action::kInspectExtensionPopup));
    }
    return true;
  }

  // Library button right-click (C-report-s3 Part D): a disabled
  // "Show media from:" header, then one checkmark row per source.
  bool Library(ui::SimpleMenuModel* m) {
    if (ctx_->library_media_sources.empty()) {
      return false;
    }
    Note(m, u"Show media from:");
    for (const SidebarLibraryMediaSource& source : ctx_->library_media_sources) {
      SidebarMenuCommand c =
          Flagged(Cmd(Action::kToggleLibraryMediaSource), !source.enabled);
      c.text = source.id;
      Check(m, source.title, std::move(c), source.enabled);
    }
    return true;
  }

 private:
  const raw_ref<const SidebarMenuContext> ctx_;
  const raw_ref<const BrowserModel> model_;
  raw_ptr<SidebarMenuModel> root_;
};

}  // namespace

std::u16string SplitPaneMenuTitle(const Tab& tab) {
  std::u16string title;
  const bool blank = !tab.custom_title && tab.url == "about:blank" &&
                     (tab.title.empty() || tab.title == "about:blank");
  title = blank ? u"New Tab" : U16(tab.display_title());
  if (title.size() > 30) {
    title = title.substr(0, 30) + u"…";
  }
  return title;
}

bool IsEaselTab(const Tab& tab) {
  const GURL url(tab.url);
  return url.SchemeIs("open") && base::EqualsCaseInsensitiveASCII(
                                     url.host(), "easel");
}

bool IsNoteTab(const Tab& tab) {
  const GURL url(tab.url);
  return url.SchemeIs("open") && base::EqualsCaseInsensitiveASCII(
                                     url.host(), "note");
}

std::unique_ptr<ui::SimpleMenuModel> BuildSidebarMenuModel(
    const SidebarMenuContext& ctx,
    SidebarMenuActionCallback on_action) {
  if (!ctx.model) {
    return nullptr;
  }
  auto root = std::make_unique<SidebarMenuModel>(std::move(on_action));
  Builder b(ctx, root.get());
  bool built = true;
  const OpenMenuTarget& t = ctx.target;
  switch (t.kind) {
    case OpenMenuTarget::Kind::kNode:
    case OpenMenuTarget::Kind::kFavorite:
      built = b.Node(root.get(), t.node_id);
      break;
    case OpenMenuTarget::Kind::kSpace:
    case OpenMenuTarget::Kind::kSwitcherItem:
      built = b.SpaceMenu(root.get(), t.space_id);
      break;
    case OpenMenuTarget::Kind::kPlusButton:
      b.Plus(root.get(), t.space_id);
      break;
    case OpenMenuTarget::Kind::kToolbarMore:
      b.ToolbarMore(root.get());
      break;
    case OpenMenuTarget::Kind::kUrlField:
      b.UrlField(root.get());
      break;
    case OpenMenuTarget::Kind::kToolbarAction:
      built = b.ToolbarAction(root.get());
      break;
    case OpenMenuTarget::Kind::kLibrary:
      built = b.Library(root.get());
      break;
  }
  if (!built || root->GetItemCount() == 0) {
    return nullptr;
  }
  return root;
}

namespace {

class AppMenuModel : public ui::SimpleMenuModel::Delegate,
                     public ui::SimpleMenuModel {
 public:
  explicit AppMenuModel(AppMenuCommandCallback on_command)
      : ui::SimpleMenuModel(this), on_command_(std::move(on_command)) {}
  AppMenuModel(const AppMenuModel&) = delete;
  AppMenuModel& operator=(const AppMenuModel&) = delete;
  ~AppMenuModel() override = default;

  struct Entry {
    CommandId command = CommandId::kUnknown;
    bool enabled = true;
    std::optional<ui::Accelerator> accelerator;
  };

  int NewEntry(Entry entry) {
    const int id = next_id_++;
    entries_[id] = std::move(entry);
    return id;
  }

  ui::SimpleMenuModel* NewSubmenu() {
    submenus_.push_back(std::make_unique<ui::SimpleMenuModel>(this));
    return submenus_.back().get();
  }

  // ui::SimpleMenuModel::Delegate:
  bool IsCommandIdEnabled(int command_id) const override {
    auto it = entries_.find(command_id);
    return it == entries_.end() || it->second.enabled;
  }

  void ExecuteCommand(int command_id, int /*event_flags*/) override {
    auto it = entries_.find(command_id);
    if (it == entries_.end() || !it->second.enabled ||
        it->second.command == CommandId::kUnknown || !on_command_) {
      return;
    }
    const CommandId command = it->second.command;
    AppMenuCommandCallback callback = on_command_;
    callback.Run(command);
  }

  bool GetAcceleratorForCommandId(
      int command_id,
      ui::Accelerator* accelerator) const override {
    auto it = entries_.find(command_id);
    if (it == entries_.end() || !it->second.accelerator) {
      return false;
    }
    *accelerator = *it->second.accelerator;
    return true;
  }

 private:
  AppMenuCommandCallback on_command_;
  std::map<int, Entry> entries_;
  std::vector<std::unique_ptr<ui::SimpleMenuModel>> submenus_;
  int next_id_ = 1;
};

ui::KeyboardCode KeyCodeForShortcutToken(std::string_view token) {
  if (token.size() == 1) {
    const char c = token[0];
    if (c >= 'a' && c <= 'z') {
      return static_cast<ui::KeyboardCode>(ui::VKEY_A + (c - 'a'));
    }
    if (c >= '0' && c <= '9') {
      return static_cast<ui::KeyboardCode>(ui::VKEY_0 + (c - '0'));
    }
    switch (c) {
      case '[':
        return ui::VKEY_OEM_4;
      case ']':
        return ui::VKEY_OEM_6;
      case ',':
        return ui::VKEY_OEM_COMMA;
      case '.':
        return ui::VKEY_OEM_PERIOD;
      case '/':
        return ui::VKEY_OEM_2;
      case '-':
        return ui::VKEY_OEM_MINUS;
      case '=':
      case '+':
        return ui::VKEY_OEM_PLUS;
      case ';':
        return ui::VKEY_OEM_1;
      case '\'':
        return ui::VKEY_OEM_7;
      case '\\':
        return ui::VKEY_OEM_5;
      case '`':
        return ui::VKEY_OEM_3;
      default:
        return ui::VKEY_UNKNOWN;
    }
  }
  static constexpr struct {
    std::string_view name;
    ui::KeyboardCode code;
  } kNamed[] = {
      {"tab", ui::VKEY_TAB},       {"escape", ui::VKEY_ESCAPE},
      {"esc", ui::VKEY_ESCAPE},    {"return", ui::VKEY_RETURN},
      {"enter", ui::VKEY_RETURN},  {"space", ui::VKEY_SPACE},
      {"left", ui::VKEY_LEFT},     {"right", ui::VKEY_RIGHT},
      {"up", ui::VKEY_UP},         {"down", ui::VKEY_DOWN},
      {"delete", ui::VKEY_DELETE}, {"backspace", ui::VKEY_BACK},
      {"home", ui::VKEY_HOME},     {"end", ui::VKEY_END},
      {"pageup", ui::VKEY_PRIOR},  {"pagedown", ui::VKEY_NEXT},
  };
  for (const auto& named : kNamed) {
    if (named.name == token) {
      return named.code;
    }
  }
  if (token.size() >= 2 && token.size() <= 3 && token[0] == 'f') {
    int n = 0;
    for (char c : token.substr(1)) {
      if (c < '0' || c > '9') {
        return ui::VKEY_UNKNOWN;
      }
      n = n * 10 + (c - '0');
    }
    if (n >= 1 && n <= 24) {
      return static_cast<ui::KeyboardCode>(ui::VKEY_F1 + (n - 1));
    }
  }
  return ui::VKEY_UNKNOWN;
}

std::optional<ui::Accelerator> AcceleratorForCommand(
    const CommandRegistry& registry,
    CommandId command) {
  const std::vector<KeyboardShortcut> shortcuts =
      registry.EffectiveShortcuts(command);
  if (shortcuts.empty()) {
    return std::nullopt;
  }
  const KeyboardShortcut& sc = shortcuts.front();
  const ui::KeyboardCode code =
      KeyCodeForShortcutToken(base::ToLowerASCII(sc.key));
  if (code == ui::VKEY_UNKNOWN) {
    return std::nullopt;
  }
  int flags = ui::EF_NONE;
  if (sc.modifiers & kModCtrl) {
    flags |= ui::EF_CONTROL_DOWN;
  }
  if (sc.modifiers & kModAlt) {
    flags |= ui::EF_ALT_DOWN;
  }
  if (sc.modifiers & kModShift) {
    flags |= ui::EF_SHIFT_DOWN;
  }
  if (sc.modifiers & kModMeta) {
    flags |= ui::EF_COMMAND_DOWN;
  }
  return ui::Accelerator(code, flags);
}

}  // namespace

std::unique_ptr<ui::SimpleMenuModel> BuildAppMenuModel(
    const AppMenuContext& ctx,
    AppMenuCommandCallback on_command) {
  auto root = std::make_unique<AppMenuModel>(std::move(on_command));
  static const CommandRegistry kDefaultRegistry;
  const CommandRegistry& registry =
      OpenBrowserService::Get() ? OpenBrowserService::Get()->commands()
                                : kDefaultRegistry;

  auto add = [&](ui::SimpleMenuModel* menu, std::u16string title,
                 CommandId command, bool enabled = true) {
    AppMenuModel::Entry entry;
    entry.command = command;
    entry.enabled = enabled;
    entry.accelerator = AcceleratorForCommand(registry, command);
    menu->AddItem(root->NewEntry(std::move(entry)), std::move(title));
  };
  auto sep = [](ui::SimpleMenuModel* menu) {
    menu->AddSeparator(ui::NORMAL_SEPARATOR);
  };
  auto sub = [&](ui::SimpleMenuModel* menu, std::u16string title,
                 bool enabled = true) -> ui::SimpleMenuModel* {
    ui::SimpleMenuModel* child = root->NewSubmenu();
    AppMenuModel::Entry entry;
    entry.enabled = enabled;
    menu->AddSubMenu(root->NewEntry(std::move(entry)), std::move(title), child);
    return child;
  };

  // --- Window & Tab Creation ---
  add(root.get(), u"New Tab", CommandId::kNewTab);
  add(root.get(), u"New Window", CommandId::kNewWindow);
  add(root.get(), u"New Incognito Window", CommandId::kNewIncognitoWindow);
  add(root.get(), u"New Blank Window", CommandId::kBlankWindow);
  add(root.get(), u"New Little Open", CommandId::kNewLittleOpenWindow);

  sep(root.get());

  // --- Workspace & Documents ---
  add(root.get(), u"New Space", CommandId::kNewSpace, !ctx.is_incognito);
  add(root.get(), u"New Folder", CommandId::kNewFolder, !ctx.is_incognito);
  add(root.get(), u"New Note", CommandId::kNewNote, !ctx.is_incognito);
  add(root.get(), u"New Easel", CommandId::kNewEasel, !ctx.is_incognito);
  add(root.get(), u"New Boost", CommandId::kNewBoost,
      !ctx.is_incognito && ctx.has_active_tab);

  sep(root.get());

  // --- View Submenu ---
  ui::SimpleMenuModel* view_menu = sub(root.get(), u"View");
  add(view_menu, ctx.sidebar_hidden ? u"Show Sidebar" : u"Hide Sidebar",
      CommandId::kToggleSidebar);
  add(view_menu, ctx.toolbar_visible ? u"Hide Toolbar" : u"Show Toolbar",
      CommandId::kToggleToolbar);
  add(view_menu, ctx.is_fullscreen ? u"Exit Fullscreen" : u"Fullscreen",
      CommandId::kToggleFullScreen);
  sep(view_menu);
  add(view_menu, u"Zoom In", CommandId::kZoomIn, ctx.has_active_tab);
  add(view_menu, u"Zoom Out", CommandId::kZoomOut, ctx.has_active_tab);
  add(view_menu, u"Actual Size", CommandId::kZoomActualSize,
      ctx.has_active_tab);

  // --- Library Submenu ---
  ui::SimpleMenuModel* library_menu =
      sub(root.get(), u"Library", !ctx.is_incognito);
  add(library_menu, u"Downloads", CommandId::kViewDownloads, !ctx.is_incognito);
  add(library_menu, u"History", CommandId::kViewHistory, !ctx.is_incognito);
  add(library_menu, u"Archive", CommandId::kViewArchive, !ctx.is_incognito);
  add(library_menu, u"Easels & Notes", CommandId::kViewEaselsNotes,
      !ctx.is_incognito);
  add(library_menu, u"Media", CommandId::kViewMedia, !ctx.is_incognito);
  add(library_menu, u"Spaces", CommandId::kManageSpaces, !ctx.is_incognito);
  add(library_menu, u"Boosts", CommandId::kViewBoosts, !ctx.is_incognito);

  // --- Developer Submenu ---
  ui::SimpleMenuModel* dev_menu = sub(root.get(), u"Developer");
  add(dev_menu, u"Developer Tools", CommandId::kDeveloperTools,
      ctx.has_active_tab);
  add(dev_menu, u"Inspect Elements", CommandId::kInspectElements,
      ctx.has_active_tab);
  add(dev_menu, u"JavaScript Console", CommandId::kJavaScriptConsole,
      ctx.has_active_tab);
  add(dev_menu, u"View Page Source", CommandId::kViewSource,
      ctx.has_active_tab);
  add(dev_menu, u"Task Manager", CommandId::kTaskManager);

  sep(root.get());

  // --- Tools & Page ---
  add(root.get(), u"Extensions", CommandId::kManageExtensions);
  add(root.get(), u"Import from Another Browser…",
      CommandId::kImportFromBrowser);
  add(root.get(), u"Print…", CommandId::kPrint, ctx.has_active_tab);
  add(root.get(), u"Save Page As…", CommandId::kSavePageAs, ctx.has_active_tab);

  sep(root.get());

  // --- Settings & App ---
  add(root.get(), u"Settings", CommandId::kSettings);
  add(root.get(), u"About Open", CommandId::kAboutOpen);
  add(root.get(), u"Quit Open", CommandId::kQuitOpen);

  return root;
}

}  // namespace open_unified
