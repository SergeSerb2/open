// Copyright 2026 The Open Authors. All rights reserved.
//
// Sidebar context menus as ui::SimpleMenuModel (port of OpenSidebar
// SidebarMenus.swift). Item lists, titles, order and enabled rules follow
// the Swift menus, which follow the captured Arc 1.172.2 menus
// (docs/re/interaction-states.md 15, docs/re/sidebar-menus-parity.md).
// Menus Swift marks as guesses keep their Swift order here.
//
// Every item reports one SidebarMenuCommand (an action plus its payload).
// The builder never edits the model: OpenWindowController dispatches each
// command in one switch over SidebarMenuAction.
//
// AppKit draws Option-key alternates in place of their primaries while Option
// is held. Views menus cannot swap items while open, so the builder takes the
// Option state at open time (`SidebarMenuContext::option_held`) and emits the
// alternates instead of their primaries when it is set.

#ifndef OPEN_UNIFIED_BROWSER_OPEN_SIDEBAR_MENUS_H_
#define OPEN_UNIFIED_BROWSER_OPEN_SIDEBAR_MENUS_H_

#include <map>
#include <memory>
#include <optional>
#include <set>
#include <string>
#include <vector>

#include "base/functional/callback.h"
#include "base/memory/raw_ptr.h"
#include "open_unified/core/commands/command_registry.h"
#include "open_unified/core/model/open_types.h"
#include "open_unified/ui/views/open_browser_view.h"
#include "ui/menus/simple_menu_model.h"

namespace open_unified {

class BrowserModel;

// One action per menu row. The comment lists the payload fields it uses.
enum class SidebarMenuAction {
  kNone,

  // --- One row (tab, Easel, Note, split, folder) ----------------------------
  kCopyLink,              // node_id; flag = Markdown
  kShareVia,              // node_id, text = share service id
  kChangeIcon,            // node_id
  kBeginRename,           // node_id (inline editor); empty node_id = Space
  kToggleMute,            // node_id (tab)
  kCustomizePage,         // node_id (tab)
  kReplacePinnedUrl,      // node_id (tab): pinned URL = current URL
  kEditPinnedUrl,         // node_id (tab)
  kAddSplitView,          // node_id (tab): the selected tab gains a split
  kOpenInSplitView,       // node_id (tab): another tab joins the current one
  kDuplicate,             // node_id
  kMoveToSpace,           // node_id, space_id
  kMoveToNewSpace,        // node_id
  kMove,                  // node_id, parent, index
  kNewFolderWithSelection,  // selected_node_ids
  kClose,                 // node_id ("Archive Tab", "Archive Item",
                          // "Remove ... from Sidebar", Incognito "Close Tab")
  kArchiveOtherTabs,      // space_id, selected_node_ids = tabs to keep
  kArchiveNodes,          // selected_node_ids (also Tabs Below / Above)
  kUnpin,                 // node_id ("Remove Pin")
  kRemoveFavorite,        // node_id
  kExportEasel,           // node_id
  kDeleteEasel,           // node_id
  kExportNote,            // node_id
  kDeleteNote,            // node_id

  // --- Favorite tiles (Live Calendar, unread badges) ----------------------------
  kSetShowsUnreadBadge,       // node_id, flag
  kSetShowsTimeToNextMeeting,  // node_id, flag
  kSetLiveCalendarEnabled,    // node_id, flag
  kCopyMeetingLink,           // node_id, text = meeting URL
  kDismissMeeting,            // node_id
  kSetMeetingReminder,        // node_id, value = SidebarMeetingReminder

  // --- Split View rows --------------------------------------------------------------
  kShareSplit,                // node_id (split)
  kSeparateSplit,             // node_id (split)
  kAddTabToSplit,             // node_id (split)
  kSetSplitOrientation,       // node_id (split); flag = vertical
  kSeparatePane,              // node_id (split), secondary_id (pane tab)
  kResetSplitCustomization,   // node_id (split)

  // --- Folders --------------------------------------------------------------------------
  kShareFolder,          // node_id
  kNewNestedFolder,      // node_id (parent folder)
  kTurnFolderIntoSpace,  // node_id
  kCopyAllLinks,         // node_id; flag = Markdown
  kDeleteFolder,         // node_id
  kSetLiveRepository,    // node_id, text = repository, flag = hidden
  kOpenLiveFolderSso,    // node_id
  kRefreshLiveFolder,    // node_id
  kDeleteLiveFolder,     // node_id

  // --- Multi-selection --------------------------------------------------------------
  kCopyLinks,            // selected_node_ids; flag = Markdown
  kShareNodes,           // selected_node_ids
  kSetMuted,             // selected_node_ids (tabs to toggle); flag = mute
  kSplitNodes,           // selected_node_ids
  kDuplicateNodes,       // selected_node_ids
  kSetPinned,            // selected_node_ids; flag = pin
  kMoveNodesToSpace,     // selected_node_ids, space_id
  kMoveNodesToNewSpace,  // selected_node_ids
  kMoveNodes,            // selected_node_ids, parent, index
  kDeleteFolders,        // selected_node_ids; flag = also archive the tab

  // --- Spaces -------------------------------------------------------------------------
  kChangeSpaceIcon,        // space_id
  kEditSpaceTheme,         // space_id
  kSetSpaceProfile,        // space_id, profile_id
  kNewProfile,             // space_id
  kSetSpaceHeaderShown,    // space_id, flag
  kNewFolder,              // space_id, parent (the Space's Pinned section)
  kToggleLiveFolder,       // space_id (Live Folders > GitHub)
  kShareSpace,             // space_id
  kExportSpaceIntoFolder,  // space_id, secondary_id = destination Space
  kManageSpaces,
  kDeleteSpace,  // space_id

  // --- "+" -------------------------------------------------------------------------------
  kNewSpace,
  kNewEasel,
  kNewNote,
  kNewBoost,
  kNewSplit,
  kNewTab,

  // --- URL field -------------------------------------------------------------------
  kCopyCurrentUrl,
  kSharePageVia,       // text = share service id
  kCapture,
  kCaptureFullPage,
  kCapturePortrait,
  kSetToolbarShown,    // flag
  kSetSharedQuotes,    // flag

  // --- Toolbar "More options" ------------------------------------------------
  kReload,
  kStopLoading,
  kToggleSidebar,

  // --- Pinned extension action (URL pill) ---------------------------------------
  kRunToolbarAction,        // text = extension id
  kExtensionOptions,        // text = extension id
  kUnpinToolbarAction,      // text = extension id
  kRemoveExtension,         // text = extension id
  kManageExtension,         // text = extension id
  kInspectExtensionPopup,   // text = extension id (Developer Mode)

  // --- Library button ----------------------------------------------------------------
  kToggleLibraryMediaSource,  // text = source id, flag = new enabled state
};

// Live Calendar reminder choice (LiveCalendar.ReminderInterval).
enum class SidebarMeetingReminder {
  kNever = 0,
  kOnStart,
  kTwoMinutes,
  kFiveMinutes,
  kTenMinutes,
};

// What a menu row asks for. Fields the action does not use stay empty.
struct SidebarMenuCommand {
  SidebarMenuCommand();
  SidebarMenuCommand(const SidebarMenuCommand&);
  SidebarMenuCommand(SidebarMenuCommand&&) noexcept;
  SidebarMenuCommand& operator=(const SidebarMenuCommand&);
  SidebarMenuCommand& operator=(SidebarMenuCommand&&) noexcept;
  ~SidebarMenuCommand();

  SidebarMenuAction action = SidebarMenuAction::kNone;
  ItemID node_id;
  ItemID secondary_id;
  SpaceID space_id;
  ProfileID profile_id;
  NodeParent parent;
  std::optional<size_t> index;
  std::string text;
  std::vector<ItemID> selected_node_ids;
  bool flag = false;
  int value = 0;
  // ui::EventFlags of the event that ran the item.
  int event_flags = 0;
};

using SidebarMenuActionCallback =
    base::RepeatingCallback<void(const SidebarMenuCommand& command)>;

// A system share service (macOS NSSharingService). Empty list: "Share" is
// shown disabled (Windows and Linux have no share sheet).
struct SidebarShareService {
  std::string id;
  std::u16string title;
};

// A Library "Show media from:" source (Documents, Desktop, ...).
struct SidebarLibraryMediaSource {
  std::string id;
  std::u16string title;
  bool enabled = false;
};

// One repository in a GitHub Live Folder's "Repositories" submenu.
struct SidebarLiveRepository {
  std::string name;
  bool hidden = false;
};

// Live Folder state the model does not store (its last fetch).
struct SidebarLiveFolderInfo {
  SidebarLiveFolderInfo();
  SidebarLiveFolderInfo(const SidebarLiveFolderInfo&);
  SidebarLiveFolderInfo& operator=(const SidebarLiveFolderInfo&);
  ~SidebarLiveFolderInfo();

  // Active repositories plus hidden ones, any order (the menu sorts them).
  std::vector<SidebarLiveRepository> repositories;
  bool last_fetch_failed = false;
  bool needs_sso = false;
};

// Favorite tile switches (unread badge, Live Calendar) for the target tile.
struct SidebarFavoriteTileInfo {
  SidebarFavoriteTileInfo();
  SidebarFavoriteTileInfo(const SidebarFavoriteTileInfo&);
  SidebarFavoriteTileInfo& operator=(const SidebarFavoriteTileInfo&);
  ~SidebarFavoriteTileInfo();

  // An app with an unread count (FavoriteApp.hasUnreadBadge) while badges
  // are on in Settings.
  bool supports_unread_badge = false;
  bool shows_unread_badge = false;
  // A calendar provider URL while Live Calendar is available.
  bool is_calendar = false;
  bool live_calendar_enabled = false;
  bool shows_time_to_next_meeting = false;
  // The next meeting's link (Show Meeting Link submenu), if any.
  std::optional<std::string> meeting_link;
  SidebarMeetingReminder reminder = SidebarMeetingReminder::kTwoMinutes;
};

// The pinned extension action under the pointer (kToolbarAction).
struct SidebarToolbarActionInfo {
  std::string id;
  std::u16string name;
  bool has_options_page = false;
  bool can_remove = true;  // false for policy-installed extensions
  bool has_popup = false;
};

// Everything a menu reads. `model` is required; the rest is window state the
// model does not hold. OpenWindowController fills it per right-click.
struct SidebarMenuContext {
  SidebarMenuContext();
  SidebarMenuContext(const SidebarMenuContext&);
  SidebarMenuContext& operator=(const SidebarMenuContext&);
  ~SidebarMenuContext();

  OpenMenuTarget target;
  raw_ptr<const BrowserModel> model = nullptr;
  WindowID window_id;

  // The sidebar's multi-selection. With two or more ids and the target among
  // them, a kNode target gets the selection menu.
  std::vector<ItemID> selected_node_ids;
  // The focused page (Split View: the focused pane). Drives "Add Split View"
  // versus "Open in Split View" and the Copy Link shortcut.
  std::optional<ItemID> current_tab_id;
  // The address the URL field shows (the Peek page while Peek shows);
  // nullopt for no page or a Note (no shareable address).
  std::optional<std::string> current_page_url;

  bool is_incognito = false;
  // Blank window: no Space chrome (no New Space, New Folder, Turn into
  // Space, Pin Tabs).
  bool hides_space_chrome = false;
  // Option/Alt was held when the menu opened: alternates replace primaries.
  bool option_held = false;
  bool developer_mode = false;
  bool page_is_loading = false;
  bool has_page = false;
  bool shared_quotes_enabled = true;
  // Tabs whose loaded page can take "Customize Page..." (Boosts).
  std::set<ItemID> customizable_tab_ids;
  // Show/Hide Space Header: only for a single unnamed Space.
  bool offers_space_header_toggle = false;
  bool space_header_shown = false;
  // Live Folders > GitHub is checked when the Space has a Live Folder.
  bool space_has_live_folder = false;

  std::vector<SidebarShareService> share_services;
  std::vector<SidebarLibraryMediaSource> library_media_sources;
  std::optional<SidebarLiveFolderInfo> live_folder;
  std::optional<SidebarFavoriteTileInfo> favorite_tile;
  std::optional<SidebarToolbarActionInfo> toolbar_action;
};

// The menu model for `ctx.target`, or null when that target has no menu
// (an unknown node, a Library button without media sources, a toolbar action
// without `toolbar_action`). The returned model owns its delegate, its
// submenus and `on_action`; it may be held as a ui::MenuModel.
std::unique_ptr<ui::SimpleMenuModel> BuildSidebarMenuModel(
    const SidebarMenuContext& ctx,
    SidebarMenuActionCallback on_action);

// State for the Windows/Linux Open Application Menu.
struct AppMenuContext {
  bool is_incognito = false;
  bool sidebar_hidden = false;
  bool toolbar_visible = false;
  bool is_fullscreen = false;
  bool has_active_tab = false;
};

using AppMenuCommandCallback =
    base::RepeatingCallback<void(CommandId command)>;

// Builds the Open Application Menu (Windows/Linux top-left Open button, Alt+F,
// F10). The returned model owns its delegate, submenus, and `on_command`.
std::unique_ptr<ui::SimpleMenuModel> BuildAppMenuModel(
    const AppMenuContext& ctx,
    AppMenuCommandCallback on_command);

// The pane title in a split row's menu: the tab title cut to 30 characters
// plus an ellipsis; "New Tab" for a pane that never got a page.
std::u16string SplitPaneMenuTitle(const Tab& tab);

// open://easel/... and open://note/... rows.
bool IsEaselTab(const Tab& tab);
bool IsNoteTab(const Tab& tab);

}  // namespace open_unified

#endif  // OPEN_UNIFIED_BROWSER_OPEN_SIDEBAR_MENUS_H_
