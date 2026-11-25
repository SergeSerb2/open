// Copyright 2026 The Open Authors. All rights reserved.

#include "open_unified/core/commands/command_registry.h"

#include <algorithm>
#include <cctype>
#include <map>
#include <set>
#include <utility>

#include "base/files/file_util.h"
#include "base/files/important_file_writer.h"
#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/strings/string_util.h"
#include "base/values.h"

namespace open_unified {

namespace {

std::string ShiftedToBaseKey(const std::string& key) {
  static const std::unordered_map<std::string, std::string> kMap = {
      {"!", "1"},  {"@", "2"}, {"#", "3"}, {"$", "4"}, {"%", "5"},  {"^", "6"},
      {"&", "7"},  {"*", "8"}, {"(", "9"}, {")", "0"}, {"_", "-"},  {"+", "="},
      {"{", "["},  {"}", "]"}, {"|", "\\"}, {":", ";"}, {"\"", "'"}, {"<", ","},
      {">", "."},  {"?", "/"}, {"~", "`"},
  };
  auto it = kMap.find(key);
  return it != kMap.end() ? it->second : key;
}

std::string DisplayKeyName(const std::string& key) {
  if (key == " " || key == "space") return "Space";
  if (key == "\t" || key == "tab") return "Tab";
  if (key == "\r" || key == "\n" || key == "return") return "Return";
  if (key == "escape" || key == "esc") return "Esc";
  if (key == "left") return "Left";
  if (key == "right") return "Right";
  if (key == "up") return "Up";
  if (key == "down") return "Down";
  if (key.size() == 1) {
    return std::string(1, static_cast<char>(std::toupper(
                              static_cast<unsigned char>(key[0]))));
  }
  if (key.size() >= 2 && (key[0] == 'f' || key[0] == 'F') &&
      std::all_of(key.begin() + 1, key.end(),
                  [](unsigned char c) { return std::isdigit(c) != 0; })) {
    return base::ToUpperASCII(key);
  }
  if (!key.empty()) {
    std::string out = key;
    out[0] = static_cast<char>(std::toupper(static_cast<unsigned char>(out[0])));
    return out;
  }
  return key;
}

const char* PriorityToString(ShortcutPriority p) {
  switch (p) {
    case ShortcutPriority::kBrowser:
      return "browser";
    case ShortcutPriority::kSite:
      return "site";
    case ShortcutPriority::kSiteThenBrowser:
      return "site-then-browser";
  }
  return "browser";
}

std::optional<ShortcutPriority> PriorityFromString(const std::string* s) {
  if (!s) return std::nullopt;
  if (*s == "browser") return ShortcutPriority::kBrowser;
  if (*s == "site") return ShortcutPriority::kSite;
  if (*s == "site-then-browser") return ShortcutPriority::kSiteThenBrowser;
  return std::nullopt;
}

bool IsKnownArcDuplicatePair(const std::vector<std::string>& ids) {
  std::set<std::string> s(ids.begin(), ids.end());
  return s == std::set<std::string>{"new-folder", "new-incognito-window"} ||
         s == std::set<std::string>{"little-open-global",
                                    "new-little-open-window"} ||
         s == std::set<std::string>{"show-fonts", "new-tab"};
}

KeyboardShortcut Primary(std::string key) {
  return KeyboardShortcut{std::move(key), kModPrimary}.Normalized();
}

KeyboardShortcut PrimaryShift(std::string key) {
  return KeyboardShortcut{std::move(key), kModPrimary | kModShift}.Normalized();
}

KeyboardShortcut PrimaryAlt(std::string key) {
  return KeyboardShortcut{std::move(key), kModPrimary | kModAlt}.Normalized();
}

KeyboardShortcut Ctrl(std::string key) {
  return KeyboardShortcut{std::move(key), kModCtrl}.Normalized();
}

KeyboardShortcut CtrlShift(std::string key) {
  return KeyboardShortcut{std::move(key), kModCtrl | kModShift}.Normalized();
}

KeyboardShortcut SpaceSwitch(std::string key) {
#if BUILDFLAG(IS_MAC)
  return KeyboardShortcut{std::move(key), kModCtrl}.Normalized();
#else
  return KeyboardShortcut{std::move(key), kModAlt}.Normalized();
#endif
}

}  // namespace

bool CommandScopesOverlap(CommandScope a, CommandScope b) {
  if (a == b) return true;
  if (a == CommandScope::kGlobal || b == CommandScope::kGlobal) return true;
  if (a == CommandScope::kWindow || b == CommandScope::kWindow) return true;
  return false;
}

KeyboardShortcut KeyboardShortcut::Normalized() const {
  KeyboardShortcut out;
  out.modifiers = modifiers;
  out.key = base::ToLowerASCII(key);
  if ((out.modifiers & kModShift) != 0) {
    out.key = ShiftedToBaseKey(out.key);
  }
  return out;
}

std::string KeyboardShortcut::DisplayString() const {
  std::vector<std::string> parts;
#if BUILDFLAG(IS_MAC)
  if (modifiers & kModMeta) parts.push_back("Cmd");
  if (modifiers & kModCtrl) parts.push_back("Ctrl");
  if (modifiers & kModAlt) parts.push_back("Opt");
  if (modifiers & kModShift) parts.push_back("Shift");
#else
  if (modifiers & kModCtrl) parts.push_back("Ctrl");
  if (modifiers & kModAlt) parts.push_back("Alt");
  if (modifiers & kModShift) parts.push_back("Shift");
  if (modifiers & kModMeta) parts.push_back("Super");
#endif
  parts.push_back(DisplayKeyName(key));
  return base::JoinString(parts, "+");
}

std::vector<std::string> KeyboardShortcut::ModifierNames() const {
  std::vector<std::string> out;
  if (modifiers & kModCtrl) out.push_back("control");
  if (modifiers & kModAlt) out.push_back("option");
  if (modifiers & kModShift) out.push_back("shift");
  if (modifiers & kModMeta) out.push_back("command");
  return out;
}

uint32_t KeyboardShortcut::ModifiersFromNames(
    const std::vector<std::string>& names) {
  uint32_t mods = kModNone;
  for (const std::string& raw : names) {
    std::string n = base::ToLowerASCII(raw);
    if (n == "control" || n == "ctrl") {
      mods |= kModCtrl;
    } else if (n == "option" || n == "opt" || n == "alt") {
      mods |= kModAlt;
    } else if (n == "shift") {
      mods |= kModShift;
    } else if (n == "command" || n == "cmd" || n == "meta" || n == "super") {
      mods |= kModMeta;
    }
  }
  return mods;
}

bool KeyboardShortcut::operator<(const KeyboardShortcut& other) const {
  if (modifiers != other.modifiers) return modifiers < other.modifiers;
  return key < other.key;
}

CommandRegistry::CommandRegistry() {
  auto add = [&](CommandId cid, std::string id, std::string title,
                 std::vector<std::string> menu,
                 std::vector<KeyboardShortcut> shortcuts,
                 CommandScope scope = CommandScope::kWindow,
                 bool customizable = false, std::string enabled_key = "always",
                 std::vector<std::string> aliases = {}, bool reserved = false,
                 ShortcutPriority prio = ShortcutPriority::kBrowser) {
    CommandDefinition def;
    def.command_id = cid;
    def.id = std::move(id);
    def.title = std::move(title);
    def.menu_path = std::move(menu);
    def.default_shortcuts = std::move(shortcuts);
    def.scope = scope;
    def.is_customizable = customizable;
    def.enabled_key = std::move(enabled_key);
    def.aliases = std::move(aliases);
    def.is_reserved = reserved;
    def.default_priority = prio;
    size_t idx = commands_.size();
    index_by_enum_[cid] = idx;
    index_by_string_[def.id] = idx;
    commands_.push_back(std::move(def));
  };

  // --- App menu ---
  add(CommandId::kAboutOpen, "about-open", "About Open", {"Open"}, {});
  add(CommandId::kSetDefaultBrowser, "set-default-browser",
      "Set as Default Browser", {"Open"}, {}, CommandScope::kWindow, false,
      "always", {"Default Browser"});
  add(CommandId::kSettings, "settings", "Settings…", {"Open"}, {Primary(",")},
      CommandScope::kWindow, false, "always", {"Preferences"});
  add(CommandId::kCheckForUpdates, "check-for-updates", "Check for Updates…",
      {"Open"}, {});
  add(CommandId::kImportFromBrowser, "import-from-browser",
      "Import from Another Browser…", {"Open"}, {}, CommandScope::kWindow,
      false, "always",
      {"Import Bookmarks", "Import Passwords", "Import Settings", "Bookmarks"});
  add(CommandId::kHideOpen, "hide-open", "Hide Open", {"Open"}, {Primary("h")});
  add(CommandId::kHideOthers, "hide-others", "Hide Others", {"Open"},
      {PrimaryAlt("h")});
  add(CommandId::kShowAll, "show-all", "Show All", {"Open"}, {});
  add(CommandId::kQuitOpen, "quit-open", "Quit Open", {"Open"}, {Primary("q")});

  // --- File menu ---
  add(CommandId::kNewTab, "new-tab", "New Tab…", {"File"}, {Primary("t")},
      CommandScope::kWindow, true, "always", {"Open New Tab", "Create Tab"});
  add(CommandId::kOpenCommandBar, "open-command-bar", "Open Command Bar",
      {"File"}, {Primary("l")}, CommandScope::kCommandBar, true, "always",
      {"Edit URL", "Command Bar", "Omnibox"});
  add(CommandId::kNewWindow, "new-window", "New Window", {"File"},
      {Primary("n")}, CommandScope::kWindow, true, "always",
      {"Create Window", "Duplicate Window"});
  add(CommandId::kNewIncognitoWindow, "new-incognito-window",
      "New Incognito Window", {"File"}, {PrimaryShift("n")},
      CommandScope::kWindow, true, "always", {"Incognito", "Private Window"});
  add(CommandId::kNewLittleOpenWindow, "new-little-open-window",
      "New Little Open Window", {"File"}, {PrimaryAlt("n")},
      CommandScope::kWindow, true, "always",
      {"Little Open", "Little Arc", "Quick Lookup", "Mini Window"});
  add(CommandId::kBlankWindow, "blank-window", "Blank Window", {"File"},
      {KeyboardShortcut{"n", kModMeta | kModCtrl}.Normalized()});
  add(CommandId::kNewNote, "new-note", "New Note", {"File"},
      {CtrlShift("n")}, CommandScope::kWindow, true, "always",
      {"Create Note", "Note", "Scratchpad"});
  add(CommandId::kNewNoteInSplit, "new-note-in-split", "New Note (in Split)",
      {"File"}, {KeyboardShortcut{"n", kModCtrl | kModAlt}.Normalized()},
      CommandScope::kWindow, true, "always",
      {"Create Note in Split View", "Note Split", "Scratchpad Split"});
  add(CommandId::kNewEasel, "new-easel", "New Easel", {"File"},
      {CtrlShift("e")}, CommandScope::kWindow, false, "always",
      {"Easel", "Create Easel", "Canvas", "Scrapbook"});
  add(CommandId::kCloseWindow, "close-window", "Close Window", {"File"},
      {PrimaryShift("w")});
  add(CommandId::kArchiveTab, "archive-tab", "Archive Tab", {"File"},
      {Primary("w")}, CommandScope::kWindow, true, "hasCurrentTab",
      {"Close Tab", "Close Current Tab"});
  add(CommandId::kRestoreLastClosedTab, "restore-last-closed-tab",
      "Restore Last Closed Tab", {"File"}, {PrimaryShift("t")},
      CommandScope::kWindow, true, "hasHistory", {"Reopen Closed Tab"});
  add(CommandId::kPrint, "print", "Print…", {"File"}, {Primary("p")},
      CommandScope::kWindow, false, "hasCurrentTab", {"Print Page"});
  add(CommandId::kSavePageAs, "save-page-as", "Save Page As…", {"File"},
      {PrimaryShift("s")}, CommandScope::kWindow, false, "hasCurrentTab",
      {"Save Page", "Save File"});
  add(CommandId::kCapturePage, "capture-page", "Capture…", {"File"},
      {PrimaryShift("2")}, CommandScope::kWindow, false, "hasCurrentTab",
      {"Capture"});
  add(CommandId::kCaptureFullPage, "capture-full-page", "Capture Full Page",
      {"File"}, {}, CommandScope::kWindow, false, "hasCurrentTab");
  add(CommandId::kCapturePortrait, "capture-portrait",
      "Capture in Portrait Mode", {"File"}, {}, CommandScope::kWindow, false,
      "hasCurrentTab");
  add(CommandId::kSharePage, "share-page", "Share…", {"File"}, {},
      CommandScope::kWindow, false, "hasCurrentTab");
  add(CommandId::kNewProfile, "new-profile", "New Profile", {"File"}, {},
      CommandScope::kWindow, false, "always", {"Create Profile"});
  add(CommandId::kNewBoost, "new-boost", "New Boost", {"File"}, {},
      CommandScope::kWindow, false, "hasCurrentTab",
      {"Boost", "Create Boost", "Boost the Current Page"});
  add(CommandId::kEditBoost, "edit-boost", "Edit Boost", {"File"}, {},
      CommandScope::kWindow, false, "hasCurrentTab", {"Boost"});
  add(CommandId::kBoostGallery, "boost-gallery", "Boost Gallery", {"File"}, {},
      CommandScope::kWindow, false, "always",
      {"Boosts Gallery", "Boosts Store"});

  // --- Edit menu ---
  add(CommandId::kUndo, "undo", "Undo", {"Edit"}, {Primary("z")},
      CommandScope::kWebContent, false, "textFieldFocused");
  add(CommandId::kRedo, "redo", "Redo", {"Edit"}, {PrimaryShift("z")},
      CommandScope::kWebContent, false, "textFieldFocused");
  add(CommandId::kCut, "cut", "Cut", {"Edit"}, {Primary("x")},
      CommandScope::kWebContent, false, "textFieldFocused");
  add(CommandId::kCopy, "copy", "Copy", {"Edit"}, {Primary("c")},
      CommandScope::kWebContent, false, "textFieldFocused");
  add(CommandId::kPaste, "paste", "Paste", {"Edit"}, {Primary("v")},
      CommandScope::kWebContent, false, "textFieldFocused");
  add(CommandId::kPasteAndMatchStyle, "paste-and-match-style",
      "Paste and Match Style", {"Edit"}, {PrimaryShift("v")},
      CommandScope::kWebContent, false, "textFieldFocused");
  add(CommandId::kSelectAll, "select-all", "Select All", {"Edit"},
      {Primary("a")}, CommandScope::kWebContent);
  add(CommandId::kDelete, "delete", "Delete", {"Edit"}, {},
      CommandScope::kWebContent, false, "textFieldFocused");
  add(CommandId::kCopyUrl, "copy-url", "Copy URL", {"Edit"},
      {PrimaryShift("c")}, CommandScope::kWindow, true, "hasCurrentTab",
      {"Copy Link"});
  add(CommandId::kCopyUrlMarkdown, "copy-url-markdown", "Copy URL as Markdown",
      {"Edit"},
      {KeyboardShortcut{"c", kModPrimary | kModAlt | kModShift}.Normalized()},
      CommandScope::kWindow, true, "hasCurrentTab",
      {"Copy Link as Markdown", "Copy Markdown"});
  add(CommandId::kCopyUrlQuote, "copy-url-quote", "Copy URL as Quote", {"Edit"},
      {KeyboardShortcut{"c", kModMeta | kModCtrl | kModShift}.Normalized()},
      CommandScope::kWindow, true, "hasCurrentTab",
      {"Copy Quote", "Copy Link to Highlight"});
  add(CommandId::kFind, "find", "Find…", {"Edit", "Find"}, {Primary("f")},
      CommandScope::kWindow, false, "hasCurrentTab",
      {"Find on Page", "Search Page"});
  add(CommandId::kFindNext, "find-next", "Find Next", {"Edit", "Find"},
      {Primary("g")}, CommandScope::kWindow, false, "hasCurrentTab");
  add(CommandId::kFindPrevious, "find-previous", "Find Previous",
      {"Edit", "Find"}, {PrimaryShift("g")}, CommandScope::kWindow, false,
      "hasCurrentTab");
  add(CommandId::kFindAndReplace, "find-and-replace", "Find and Replace…",
      {"Edit", "Find"}, {PrimaryAlt("f")}, CommandScope::kWindow, false,
      "hasCurrentTab");

  // --- View menu ---
  add(CommandId::kToggleSidebar, "toggle-sidebar", "Show/Hide Sidebar",
      {"View"}, {Primary("s")}, CommandScope::kWindow, true, "always",
      {"Toggle Sidebar", "Hide Sidebar", "Show Sidebar"});
  add(CommandId::kToggleToolbar, "toggle-toolbar", "Show/Hide Toolbar",
      {"View"}, {PrimaryShift("d")}, CommandScope::kWindow, false, "always",
      {"Toggle Toolbar"});
  add(CommandId::kToggleFullScreen, "toggle-full-screen", "Enter Full Screen",
      {"View"},
#if BUILDFLAG(IS_MAC)
      {KeyboardShortcut{"f", kModMeta | kModCtrl}.Normalized()},
#else
      {KeyboardShortcut{"f11", kModNone}.Normalized()},
#endif
      CommandScope::kWindow, false, "always",
      {"Exit Full Screen", "Full Screen", "Toggle Full Screen"});
  add(CommandId::kReload, "reload", "Refresh the Page", {"View"},
      {Primary("r")}, CommandScope::kWindow, false, "hasCurrentTab",
      {"Reload Page", "Reload", "Refresh"});
  add(CommandId::kForceReload, "force-reload", "Force Refresh the Page",
      {"View"}, {PrimaryShift("r")}, CommandScope::kWindow, false,
      "hasCurrentTab", {"Force Reload", "Force Refresh"});
  add(CommandId::kStopLoading, "stop-loading", "Stop Loading", {"View"},
      {Primary(".")}, CommandScope::kWindow, false, "hasCurrentTab");
  add(CommandId::kZoomIn, "zoom-in", "Zoom In", {"View"},
      {Primary("+"), Primary("=")}, CommandScope::kWindow, true,
      "hasCurrentTab");
  add(CommandId::kZoomOut, "zoom-out", "Zoom Out", {"View"},
      {Primary("-"), PrimaryShift("-")}, CommandScope::kWindow, false,
      "hasCurrentTab");
  add(CommandId::kZoomActualSize, "zoom-actual-size", "Zoom to Actual Size",
      {"View"}, {Primary("0")}, CommandScope::kWindow, false, "hasCurrentTab",
      {"Reset Zoom"});
  add(CommandId::kAddSplitView, "add-split-view", "Add Split View", {"View"},
      {CtrlShift("=")}, CommandScope::kWindow, true, "hasCurrentTab",
      {"Split View", "Split", "Create Split View Pane"});
  add(CommandId::kCloseSplitPane, "close-split-pane", "Close this Split Pane",
      {"View"}, {CtrlShift("-")}, CommandScope::kWindow, true,
      "currentTabInSplit", {"Close Split View", "Close Split Pane"});
  add(CommandId::kExpandCurrentSplit, "expand-current-split",
      "Expand Current Split", {"View"}, {}, CommandScope::kWindow, false,
      "currentTabInSplit", {"Maximize Split Pane"});
  add(CommandId::kSeparateFromSplitView, "separate-from-split-view",
      "Separate Page from Split View", {"View"}, {}, CommandScope::kWindow,
      false, "currentTabInSplit", {"Separate from Split View"});
  add(CommandId::kRevealCurrentTab, "reveal-current-tab", "Reveal Current Tab",
      {"View"}, {Ctrl("space")}, CommandScope::kWindow, false, "hasCurrentTab",
      {"Reveal Tab in Sidebar", "Focus Sidebar", "Show Tab in Sidebar"});
  add(CommandId::kExpandPinnedSection, "expand-pinned-section",
      "Expand Pinned Section", {"View"}, {}, CommandScope::kWindow, false,
      "always", {"Expand Pinned Tabs", "Show Pinned Tabs"});
  add(CommandId::kCollapsePinnedSection, "collapse-pinned-section",
      "Collapse Pinned Section", {"View"}, {}, CommandScope::kWindow, false,
      "always", {"Collapse Pinned Tabs", "Hide Pinned Tabs"});
  add(CommandId::kClearCacheAndRefresh, "clear-cache-and-refresh",
      "Clear Cache and Refresh", {"View"}, {}, CommandScope::kWindow, false,
      "hasCurrentTab", {"Clear Cache"});
  add(CommandId::kClearCookiesAndRefresh, "clear-cookies-and-refresh",
      "Clear Cookies and Refresh", {"View"}, {}, CommandScope::kWindow, false,
      "hasCurrentTab", {"Clear Cookies"});
  add(CommandId::kExitModal, "exit-modal", "Exit", {"View"},
      {KeyboardShortcut{"escape", kModNone}}, CommandScope::kCommandBar);
  add(CommandId::kAppearanceAutomatic, "appearance-automatic", "Automatic",
      {"View", "Appearance"}, {}, CommandScope::kWindow, false, "always",
      {"Automatic Appearance"});
  add(CommandId::kAppearanceLight, "appearance-light", "Light",
      {"View", "Appearance"}, {}, CommandScope::kWindow, false, "always",
      {"Light Mode"});
  add(CommandId::kAppearanceDark, "appearance-dark", "Dark",
      {"View", "Appearance"}, {}, CommandScope::kWindow, false, "always",
      {"Dark Mode"});

  // --- Spaces menu ---
  add(CommandId::kNewSpace, "new-space", "New Space…", {"Spaces"}, {},
      CommandScope::kWindow, false, "always",
      {"Create New Space", "Create Space", "Add Space"});
  add(CommandId::kNextSpace, "next-space", "Next Space", {"Spaces"},
      {PrimaryAlt("right")}, CommandScope::kWindow, true, "hasMultipleSpaces",
      {"Focus Next Space"});
  add(CommandId::kPreviousSpace, "previous-space", "Previous Space", {"Spaces"},
      {PrimaryAlt("left")}, CommandScope::kWindow, true, "hasMultipleSpaces",
      {"Focus Previous Space"});
  add(CommandId::kManageSpaces, "manage-spaces", "Manage Spaces…", {"Spaces"},
      {}, CommandScope::kWindow, false, "always",
      {"Space Management", "Organize", "Toggle Space Manager", "View Spaces"});
  add(CommandId::kRenameSpace, "rename-space", "Rename Space", {"Spaces"}, {},
      CommandScope::kWindow, false, "always", {"Rename Current Space"});
  add(CommandId::kEditTheme, "edit-theme", "Edit Theme…", {"Spaces"}, {},
      CommandScope::kWindow, false, "always", {"Theme", "Edit Space Theme"});
  add(CommandId::kChangeProfile, "change-profile", "Change Profile", {"Spaces"},
      {}, CommandScope::kWindow, false, "always", {"Move Space to Profile"});

  // --- Tabs menu ---
  add(CommandId::kPinUnpinTab, "pin-unpin-tab", "Pin/Unpin Tab", {"Tabs"},
      {Primary("d")}, CommandScope::kWindow, true, "hasCurrentTab",
      {"Pin Tab", "Unpin Tab", "Pin", "Unpin"});
  add(CommandId::kNextTab, "next-tab", "Next Tab", {"Tabs"},
      {PrimaryAlt("down")}, CommandScope::kWindow, true);
  add(CommandId::kPreviousTab, "previous-tab", "Previous Tab", {"Tabs"},
      {PrimaryAlt("up")}, CommandScope::kWindow, true);
  add(CommandId::kCycleTabForward, "cycle-tab-forward", "Cycle Tab Forward",
      {"Tabs"}, {KeyboardShortcut{"right", kModMeta | kModCtrl}.Normalized()});
  add(CommandId::kCycleTabBackward, "cycle-tab-backward", "Cycle Tab Backward",
      {"Tabs"}, {KeyboardShortcut{"left", kModMeta | kModCtrl}.Normalized()});
  add(CommandId::kTabSwitcherForward, "tab-switcher-forward",
      "Tab Switcher (forward)", {"Tabs"}, {Ctrl("tab")}, CommandScope::kWindow,
      true);
  add(CommandId::kTabSwitcherBackward, "tab-switcher-backward",
      "Tab Switcher (backward)", {"Tabs"}, {CtrlShift("tab")},
      CommandScope::kWindow, true);
  add(CommandId::kClearUnpinnedTabs, "clear-unpinned-tabs",
      "Clear Unpinned Tabs", {"Tabs"}, {PrimaryShift("k")},
      CommandScope::kWindow, true, "always",
      {"Close Unpinned Tabs", "Clear Tabs", "Clear Today"});
  add(CommandId::kNewFolder, "new-folder", "New Folder…", {"Tabs"},
      {PrimaryShift("n")}, CommandScope::kSidebarFocused, false, "always",
      {"Create Folder", "Create New Folder", "New Folder from Selection"});
  add(CommandId::kDuplicateTab, "duplicate-tab", "Duplicate", {"Tabs"}, {},
      CommandScope::kWindow, false, "hasCurrentTab",
      {"Duplicate Tab", "Duplicate Current Tab"});
  add(CommandId::kRenameTab, "rename-tab", "Rename Current Item", {"Tabs"}, {},
      CommandScope::kWindow, false, "hasCurrentTab",
      {"Rename Tab", "Rename Current Tab"});
  add(CommandId::kExpandAllFolders, "expand-all-folders", "Expand All Folders",
      {"Tabs"}, {});
  add(CommandId::kCollapseAllFolders, "collapse-all-folders",
      "Collapse All Folders", {"Tabs"}, {});
  add(CommandId::kResetTab, "reset-tab", "Reset Tab to Original URL", {"Tabs"},
      {}, CommandScope::kWindow, false, "currentTabHasPinnedURL",
      {"Reset Tab"});
  add(CommandId::kResetAllTabsInSpace, "reset-all-tabs-in-space",
      "Reset all tabs in this Space", {"Tabs"}, {}, CommandScope::kWindow,
      false, "always", {"Reset Pinned Tabs"});
  add(CommandId::kPeekEmail, "peek-email", "Peek Email…", {"Tabs"},
      {PrimaryShift("e")});
  add(CommandId::kJoinMeeting, "join-meeting", "Join Meeting", {"Tabs"},
      {KeyboardShortcut{"j", kModMeta | kModCtrl}.Normalized()});
  add(CommandId::kOpenInCurrentSpace, "open-in-current-space",
      "Open Little Open or Peek in…", {"Tabs"}, {Primary("o")},
      CommandScope::kWindow, false, "hasCurrentTab");

  // --- Archive / Navigation ---
  add(CommandId::kGoBack, "go-back", "Go Back", {"Archive"},
#if BUILDFLAG(IS_MAC)
      {Primary("["), Primary("left")},
#else
      {Primary("["), KeyboardShortcut{"left", kModAlt}.Normalized()},
#endif
      CommandScope::kWindow, true, "canGoBack", {"Back", "Navigate Back"});
  add(CommandId::kGoForward, "go-forward", "Go Forward", {"Archive"},
#if BUILDFLAG(IS_MAC)
      {Primary("]"), Primary("right")},
#else
      {Primary("]"), KeyboardShortcut{"right", kModAlt}.Normalized()},
#endif
      CommandScope::kWindow, true, "canGoForward",
      {"Forward", "Navigate Forward"});
  add(CommandId::kViewArchive, "view-archive", "View Archive", {"Archive"}, {},
      CommandScope::kWindow, false, "always", {"Archive", "Open Archive"});
  add(CommandId::kViewHistory, "view-history", "View History", {"Archive"},
      {Primary("y")}, CommandScope::kWindow, false, "always",
      {"Show History", "History"});
  add(CommandId::kClearArchive, "clear-archive", "Clear Archive", {"Archive"},
      {}, CommandScope::kWindow, false, "always", {"Delete Archive"});

  // --- Extensions ---
  add(CommandId::kOpenExtensionsPicker, "open-extensions-picker",
      "Open Extensions", {"Extensions"}, {Primary("e")}, CommandScope::kWindow,
      true, "always",
      {"Extensions picker", "Pinned extensions", "Run extension"});
  add(CommandId::kManageExtensions, "manage-extensions", "Manage Extensions…",
      {"Extensions"}, {}, CommandScope::kWindow, false, "always",
      {"Extensions"});
  add(CommandId::kAddExtension, "add-extension", "Add Extension…",
      {"Extensions"}, {}, CommandScope::kWindow, false, "always",
      {"Chrome Web Store"});

  // --- Window ---
  add(CommandId::kViewDownloads, "view-downloads", "View Downloads", {"Window"},
      {PrimaryShift("j")}, CommandScope::kWindow, false, "always",
      {"Downloads"});
  add(CommandId::kViewLibrary, "view-library", "View Library", {"Window"},
      {PrimaryShift("l")}, CommandScope::kWindow, false, "always", {"Library"});
  add(CommandId::kViewMedia, "view-media", "View Media", {"Window"}, {});
  add(CommandId::kViewBoosts, "view-boosts", "View Boosts", {"Window"}, {});
  add(CommandId::kStayOnTop, "stay-on-top", "Stay On Top", {"Window"}, {},
      CommandScope::kWindow, false, "always",
      {"Float Window", "Always on Top"});
  add(CommandId::kViewEaselsNotes, "view-easels-notes", "View Easels & Notes",
      {"Window"}, {}, CommandScope::kWindow, false, "always",
      {"Easels", "Notes"});
  add(CommandId::kMinimizeWindow, "minimize-window", "Minimize", {"Window"},
      {Primary("m")});
  add(CommandId::kZoomWindow, "zoom-window", "Zoom", {"Window"}, {});

  // --- Help & Developer ---
  add(CommandId::kExportNotes, "export-notes", "Export Notes…", {"Help"}, {},
      CommandScope::kWindow, false, "always",
      {"Export Notes", "Backup Notes", "Download Notes"});
  add(CommandId::kHelpCenter, "help-center", "Open Help Center", {"Help"}, {},
      CommandScope::kWindow, false, "always", {"Visit Help Center"});
  add(CommandId::kKeyboardShortcutsEdu, "keyboard-shortcuts-edu",
      "Essential Keyboard Shortcuts", {"Help"}, {}, CommandScope::kWindow,
      false, "always", {"Keyboard Shortcuts", "Keyboard", "Shortcuts"});
  add(CommandId::kTaskManager, "task-manager", "Open Task Manager",
      {"Help", "Troubleshooting"}, {}, CommandScope::kWindow, false, "always",
      {"Task Manager", "CPU", "Memory", "RAM"});
  add(CommandId::kDeveloperTools, "developer-tools", "Developer Tools",
      {"View", "Developer"},
#if BUILDFLAG(IS_MAC)
      {KeyboardShortcut{"f12", kModNone}, PrimaryAlt("i")},
#else
      {KeyboardShortcut{"f12", kModNone}, PrimaryShift("i")},
#endif
      CommandScope::kWindow, false, "hasCurrentTab",
      {"DevTools", "Debug Tools"});
  add(CommandId::kJavaScriptConsole, "javascript-console", "JavaScript Console",
      {"View", "Developer"},
#if BUILDFLAG(IS_MAC)
      {PrimaryAlt("j")},
#else
      {PrimaryShift("j")},
#endif
      CommandScope::kWindow, false, "hasCurrentTab",
      {"Console", "JS Console", "Toggle Console"});
  add(CommandId::kViewSource, "view-source", "View Source",
      {"View", "Developer"},
#if BUILDFLAG(IS_MAC)
      {PrimaryAlt("u")},
#else
      {Primary("u")},
#endif
      CommandScope::kWindow, false, "hasCurrentTab");
  add(CommandId::kInspectElements, "inspect-elements", "Inspect Elements",
      {"View", "Developer"},
#if BUILDFLAG(IS_MAC)
      {PrimaryAlt("c")},
#else
      {PrimaryShift("c")},
#endif
      CommandScope::kWindow, false, "hasCurrentTab");
  add(CommandId::kToggleDeveloperMode, "toggle-developer-mode",
      "Toggle Developer Mode", {"View", "Developer"}, {Ctrl("d")});

  // --- Code-only commands ---
  add(CommandId::kAddToFavorites, "add-to-favorites", "Add to Favorites", {},
      {}, CommandScope::kWindow, false, "currentTabNotFavorite",
      {"Favorite", "Move to Favorites"});
  add(CommandId::kRemoveFromFavorites, "remove-from-favorites",
      "Remove from Favorites", {}, {}, CommandScope::kWindow, false,
      "currentTabIsFavorite", {"Unfavorite", "Remove Favorite"});
  add(CommandId::kReplacePinnedUrl, "replace-pinned-url",
      "Replace Pinned URL with Current Site", {}, {}, CommandScope::kWindow,
      false, "currentTabHasPinnedURL",
      {"Replace Pinned Tab", "Update Pinned URL"});
  add(CommandId::kSearchActions, "search-actions", "Search Actions", {}, {},
      CommandScope::kWindow, true, "always", {"Actions", "Commands"});
  add(CommandId::kSearchTabs, "search-tabs", "Search Tabs", {}, {},
      CommandScope::kWindow, true, "always", {"Tabs"});
  add(CommandId::kMuteAllTabs, "mute-all-tabs", "Mute All Tabs", {}, {},
      CommandScope::kWindow, false, "always", {"Mute"});
  add(CommandId::kUnmuteAllTabs, "unmute-all-tabs", "Unmute All Tabs", {}, {},
      CommandScope::kWindow, false, "always", {"Unmute"});
  add(CommandId::kAirTrafficControl, "air-traffic-control",
      "Air Traffic Control", {}, {}, CommandScope::kWindow, false, "always",
      {"Link Routing", "Link Preferences", "Air Traffic Controller"});
  add(CommandId::kManagePasswords, "manage-passwords", "Manage Passwords", {},
      {}, CommandScope::kWindow, false, "always", {"Passwords"});
  add(CommandId::kSearchSettings, "search-settings", "Search Settings", {}, {},
      CommandScope::kWindow, false, "always",
      {"Manage Search Settings", "Search Engine", "Default Search Engine"});
  add(CommandId::kLittleOpenGlobal, "little-open-global",
      "Show Little Open (Global)", {}, {PrimaryAlt("n")}, CommandScope::kGlobal,
      false, "always", {"Little Open", "Little Arc"});
  add(CommandId::kAccountSync, "account-sync", "Account & Sync…", {}, {},
      CommandScope::kWindow, false, "always",
      {"Sync", "Arc Sync", "Sign In", "Open Account", "Cloud Sync"});
  add(CommandId::kSyncNow, "sync-now", "Sync Now", {}, {},
      CommandScope::kWindow, false, "always",
      {"Sync Account", "Refresh Sync"});

  // Go to Tab 1..9 + Last
  static constexpr CommandId kTabIds[9] = {
      CommandId::kGoToTab1, CommandId::kGoToTab2, CommandId::kGoToTab3,
      CommandId::kGoToTab4, CommandId::kGoToTab5, CommandId::kGoToTab6,
      CommandId::kGoToTab7, CommandId::kGoToTab8, CommandId::kGoToTab9,
  };
  for (int i = 0; i < 9; ++i) {
    std::string num = std::to_string(i + 1);
    add(kTabIds[i], "go-to-tab-" + num, "Go to Tab " + num, {}, {Primary(num)},
        CommandScope::kWindow, true, "always", {"Go to Sidebar Item " + num});
  }
  add(CommandId::kGoToLastTab, "go-to-last-tab", "Go to Last Tab", {}, {},
      CommandScope::kWindow, false, "always", {"Go to Last Sidebar Item"});

  // Go to Space 1..9
  static constexpr CommandId kSpaceIds[9] = {
      CommandId::kGoToSpace1, CommandId::kGoToSpace2, CommandId::kGoToSpace3,
      CommandId::kGoToSpace4, CommandId::kGoToSpace5, CommandId::kGoToSpace6,
      CommandId::kGoToSpace7, CommandId::kGoToSpace8, CommandId::kGoToSpace9,
  };
  for (int i = 0; i < 9; ++i) {
    std::string num = std::to_string(i + 1);
    add(kSpaceIds[i], "go-to-space-" + num, "Go to Space " + num, {},
        {SpaceSwitch(num)}, CommandScope::kWindow, true);
  }

  // Split panes 1..4 + next/prev
  static constexpr CommandId kSplitIds[4] = {
      CommandId::kFocusSplitPane1, CommandId::kFocusSplitPane2,
      CommandId::kFocusSplitPane3, CommandId::kFocusSplitPane4,
  };
  for (int i = 0; i < 4; ++i) {
    std::string num = std::to_string(i + 1);
    add(kSplitIds[i], "focus-split-pane-" + num, "Focus Split Pane " + num, {},
        {CtrlShift(num)}, CommandScope::kWindow, false, "currentTabInSplit");
  }
  add(CommandId::kNextSplitPane, "next-split-pane", "Next Split Pane", {},
      {CtrlShift("]")}, CommandScope::kWindow, false, "currentTabInSplit");
  add(CommandId::kPreviousSplitPane, "previous-split-pane",
      "Previous Split Pane", {}, {CtrlShift("[")}, CommandScope::kWindow, false,
      "currentTabInSplit");

  // Reserved out-of-scope Arc shortcut
  add(CommandId::kReservedNewChatGptMessage, "reserved-new-chatgpt-message",
      "New ChatGPT Message (reserved)", {}, {PrimaryAlt("g")},
      CommandScope::kWindow, false, "always", {}, /*reserved=*/true);
}

CommandRegistry::~CommandRegistry() = default;

const CommandDefinition* CommandRegistry::FindById(CommandId id) const {
  auto it = index_by_enum_.find(id);
  return it != index_by_enum_.end() ? &commands_[it->second] : nullptr;
}

const CommandDefinition* CommandRegistry::FindByStringId(
    std::string_view id) const {
  auto it = index_by_string_.find(std::string(id));
  return it != index_by_string_.end() ? &commands_[it->second] : nullptr;
}

std::vector<KeyboardShortcut> CommandRegistry::EffectiveShortcuts(
    CommandId id) const {
  const CommandDefinition* def = FindById(id);
  if (!def) return {};
  return EffectiveShortcuts(def->id);
}

std::vector<KeyboardShortcut> CommandRegistry::EffectiveShortcuts(
    std::string_view id) const {
  const CommandDefinition* def = FindByStringId(id);
  if (!def) return {};
  if (def->is_reserved) {
    return def->default_shortcuts;
  }
  auto it = overrides_.find(def->id);
  if (it != overrides_.end()) {
    return it->second.shortcuts;
  }
  return def->default_shortcuts;
}

ShortcutPriority CommandRegistry::EffectivePriority(CommandId id) const {
  const CommandDefinition* def = FindById(id);
  if (!def) return ShortcutPriority::kBrowser;
  return EffectivePriority(def->id);
}

ShortcutPriority CommandRegistry::EffectivePriority(std::string_view id) const {
  const CommandDefinition* def = FindByStringId(id);
  if (!def) return ShortcutPriority::kBrowser;
  auto it = overrides_.find(def->id);
  if (it != overrides_.end() && it->second.priority.has_value()) {
    return *it->second.priority;
  }
  return def->default_priority;
}

bool CommandRegistry::SetOverride(std::string_view command_id,
                                  KeyBindingOverride override_val) {
  const CommandDefinition* def = FindByStringId(command_id);
  if (!def || def->is_reserved) {
    return false;
  }
  for (KeyboardShortcut& sc : override_val.shortcuts) {
    sc = sc.Normalized();
  }
  overrides_[def->id] = std::move(override_val);
  return true;
}

void CommandRegistry::ResetOverride(std::string_view command_id) {
  overrides_.erase(std::string(command_id));
}

void CommandRegistry::ResetAllOverrides() {
  overrides_.clear();
}

bool CommandRegistry::LoadOverrides(const base::FilePath& path,
                                    std::string* error_out) {
  if (!base::PathExists(path)) {
    overrides_.clear();
    return true;
  }
  std::string raw;
  if (!base::ReadFileToString(path, &raw)) {
    if (error_out) *error_out = "CommandRegistry: failed to read keybindings.json";
    return false;
  }
  auto parsed = base::JSONReader::ReadDict(raw, base::JSON_PARSE_RFC);
  if (!parsed.has_value()) {
    if (error_out) *error_out = "CommandRegistry: invalid JSON in keybindings.json";
    return false;
  }
  if (parsed->FindInt("version").value_or(0) != kKeybindingsSchemaVersion) {
    if (error_out) *error_out = "CommandRegistry: unsupported keybindings version";
    return false;
  }
  std::unordered_map<std::string, KeyBindingOverride> loaded;
  if (const base::DictValue* bindings = parsed->FindDict("bindings")) {
    for (const auto& [cmd_id, val] : *bindings) {
      const CommandDefinition* def = FindByStringId(cmd_id);
      // Gracefully skip unknown commands (forward/backward compatibility).
      if (!def || def->is_reserved) {
        continue;
      }
      const base::DictValue* bd = val.GetIfDict();
      if (!bd) continue;
      KeyBindingOverride ov;
      if (const base::ListValue* sclist = bd->FindList("shortcuts")) {
        for (const base::Value& sv : *sclist) {
          const base::DictValue* sd = sv.GetIfDict();
          if (!sd) continue;
          const std::string* key = sd->FindString("key");
          if (!key || key->empty()) continue;
          std::vector<std::string> mod_names;
          if (const base::ListValue* mods = sd->FindList("modifiers")) {
            for (const base::Value& mv : *mods) {
              if (mv.is_string()) {
                mod_names.push_back(mv.GetString());
              }
            }
          }
          KeyboardShortcut sc{*key, KeyboardShortcut::ModifiersFromNames(mod_names)};
          ov.shortcuts.push_back(sc.Normalized());
        }
      }
      ov.priority = PriorityFromString(bd->FindString("priority"));
      loaded[cmd_id] = std::move(ov);
    }
  }
  overrides_ = std::move(loaded);
  return true;
}

bool CommandRegistry::SaveOverrides(const base::FilePath& path,
                                    std::string* error_out) const {
  if (!base::CreateDirectory(path.DirName())) {
    if (error_out) *error_out = "CommandRegistry: failed to create State dir";
    return false;
  }
  base::DictValue root;
  root.Set("version", kKeybindingsSchemaVersion);
  base::DictValue bindings;
  for (const auto& [cmd_id, ov] : overrides_) {
    base::DictValue bd;
    base::ListValue sclist;
    for (const KeyboardShortcut& sc : ov.shortcuts) {
      base::DictValue sd;
      sd.Set("key", sc.key);
      base::ListValue mods;
      for (const std::string& m : sc.ModifierNames()) {
        mods.Append(m);
      }
      sd.Set("modifiers", std::move(mods));
      sclist.Append(std::move(sd));
    }
    bd.Set("shortcuts", std::move(sclist));
    if (ov.priority.has_value()) {
      bd.Set("priority", PriorityToString(*ov.priority));
    }
    bindings.Set(cmd_id, std::move(bd));
  }
  root.Set("bindings", std::move(bindings));

  std::string json;
  if (!base::JSONWriter::WriteWithOptions(
          root, base::JSONWriter::OPTIONS_PRETTY_PRINT, &json)) {
    if (error_out) *error_out = "CommandRegistry: failed to serialize keybindings";
    return false;
  }
  if (!base::ImportantFileWriter::WriteFileAtomically(path, json)) {
    if (error_out) *error_out = "CommandRegistry: failed to write keybindings.json";
    return false;
  }
  return true;
}

std::vector<ShortcutConflict> CommandRegistry::DetectConflicts() const {
  struct Owner {
    std::string id;
    CommandScope scope;
    bool reserved;
  };
  std::map<KeyboardShortcut, std::vector<Owner>> owners;
  for (const CommandDefinition& cmd : commands_) {
    auto shortcuts = EffectiveShortcuts(cmd.id);
    for (const KeyboardShortcut& sc : shortcuts) {
      owners[sc.Normalized()].push_back({cmd.id, cmd.scope, cmd.is_reserved});
    }
  }

  std::vector<ShortcutConflict> conflicts;
  for (const auto& [shortcut, list] : owners) {
    std::vector<Owner> active;
    std::vector<Owner> reserved;
    for (const Owner& o : list) {
      if (o.reserved) {
        reserved.push_back(o);
      } else {
        active.push_back(o);
      }
    }
    if (!reserved.empty()) {
      for (const Owner& a : active) {
        std::vector<std::string> ids = {a.id};
        for (const Owner& r : reserved) ids.push_back(r.id);
        std::sort(ids.begin(), ids.end());
        conflicts.push_back(
            {ShortcutConflict::Kind::kReservedKeyReuse, shortcut, std::move(ids),
             false});
      }
    }
    bool added_dup = false;
    for (size_t i = 0; i < active.size() && !added_dup; ++i) {
      for (size_t j = i + 1; j < active.size(); ++j) {
        if (active[i].id != active[j].id &&
            CommandScopesOverlap(active[i].scope, active[j].scope)) {
          std::set<std::string> ids;
          for (const Owner& o : active) {
            if (CommandScopesOverlap(o.scope, active[i].scope) ||
                CommandScopesOverlap(o.scope, active[j].scope)) {
              ids.insert(o.id);
            }
          }
          std::vector<std::string> sorted_ids(ids.begin(), ids.end());
          bool known = IsKnownArcDuplicatePair(sorted_ids);
          conflicts.push_back({ShortcutConflict::Kind::kDuplicate, shortcut,
                               std::move(sorted_ids), known});
          added_dup = true;
          break;
        }
      }
    }
  }
  return conflicts;
}

std::vector<ShortcutConflict> CommandRegistry::DetectUnexpectedConflicts()
    const {
  std::vector<ShortcutConflict> out;
  for (ShortcutConflict& c : DetectConflicts()) {
    if (!c.is_known_arc_duplicate) {
      out.push_back(std::move(c));
    }
  }
  return out;
}

const CommandDefinition* CommandRegistry::MatchActiveCommand(
    const KeyboardShortcut& shortcut,
    std::optional<CommandScope> scope_filter) const {
  for (const CommandDefinition& cmd : commands_) {
    if (cmd.is_reserved) continue;
    if (scope_filter.has_value() && cmd.scope != *scope_filter) continue;
    auto shortcuts = EffectiveShortcuts(cmd.id);
    if (std::find(shortcuts.begin(), shortcuts.end(), shortcut) !=
        shortcuts.end()) {
      return &cmd;
    }
  }
  return nullptr;
}

KeyRoutingDecision CommandRegistry::RouteShortcut(
    const KeyboardShortcut& raw_shortcut,
    const KeyRoutingContext& context,
    TimestampSec now) {
  KeyboardShortcut shortcut = raw_shortcut.Normalized();
  auto browser_cmd = [](const CommandDefinition* def) {
    return KeyRoutingDecision{KeyRoutingDecision::Target::kBrowserCommand,
                              def->command_id, def->id};
  };

  // Rule 1: Another app is frontmost -> only global commands fire.
  if (!context.is_app_active) {
    if (const CommandDefinition* cmd =
            MatchActiveCommand(shortcut, CommandScope::kGlobal)) {
      return browser_cmd(cmd);
    }
    return {KeyRoutingDecision::Target::kSystem, CommandId::kUnknown, {}};
  }

  // Rule 2: Command bar is open -> Escape closes, commandBar scope wins.
  if (context.is_command_bar_open) {
    if (shortcut.key == "escape" && shortcut.modifiers == kModNone) {
      return {KeyRoutingDecision::Target::kBrowserCommand,
              CommandId::kExitModal, "exit-modal"};
    }
    if (const CommandDefinition* cmd =
            MatchActiveCommand(shortcut, CommandScope::kCommandBar)) {
      return browser_cmd(cmd);
    }
    return {KeyRoutingDecision::Target::kSystem, CommandId::kUnknown, {}};
  }

  const CommandDefinition* cmd = MatchActiveCommand(shortcut, std::nullopt);
  if (!cmd) {
    return {context.is_web_content_focused
                ? KeyRoutingDecision::Target::kWebContent
                : KeyRoutingDecision::Target::kSystem,
            CommandId::kUnknown,
            {}};
  }

  if (cmd->scope == CommandScope::kGlobal) {
    return browser_cmd(cmd);
  }

  // Rule 4: Sidebar focus picks sidebar command over window twin (e.g.,
  // New Folder vs New Incognito Window).
  if (context.is_sidebar_focused && cmd->scope != CommandScope::kSidebarFocused) {
    if (const CommandDefinition* sb =
            MatchActiveCommand(shortcut, CommandScope::kSidebarFocused)) {
      return browser_cmd(sb);
    }
  }
  if (!context.is_sidebar_focused &&
      cmd->scope == CommandScope::kSidebarFocused) {
    if (const CommandDefinition* win =
            MatchActiveCommand(shortcut, CommandScope::kWindow)) {
      return browser_cmd(win);
    }
  }

  // Rule 3: Text edit commands belong to the system/responder chain.
  if (context.is_text_focused && cmd->scope == CommandScope::kWebContent) {
    return {KeyRoutingDecision::Target::kSystem, CommandId::kUnknown, {}};
  }

  // Rule 5: Browser vs site shortcut priority over web content.
  if (context.is_web_content_focused) {
    switch (EffectivePriority(cmd->id)) {
      case ShortcutPriority::kBrowser:
        return browser_cmd(cmd);
      case ShortcutPriority::kSite:
        return {KeyRoutingDecision::Target::kWebContent, CommandId::kUnknown,
                {}};
      case ShortcutPriority::kSiteThenBrowser:
        if (last_site_press_shortcut_.has_value() &&
            *last_site_press_shortcut_ == shortcut &&
            (now - last_site_press_at_) <= kDoublePressIntervalSec) {
          last_site_press_shortcut_.reset();
          return browser_cmd(cmd);
        }
        last_site_press_shortcut_ = shortcut;
        last_site_press_at_ = now;
        return {KeyRoutingDecision::Target::kWebContent, CommandId::kUnknown,
                {}};
    }
  }

  return browser_cmd(cmd);
}

}  // namespace open_unified
