// Copyright 2026 The Open Authors. All rights reserved.
// Complete Open command registry (1:1 parity with CommandRegistry.swift),
// platform-aware default shortcuts, Arc menu metadata, JSON override
// persistence (State/keybindings.json), priority routing (0.4s double-press
// for site-then-browser), and conflict detection.

#ifndef OPEN_UNIFIED_CORE_COMMANDS_COMMAND_REGISTRY_H_
#define OPEN_UNIFIED_CORE_COMMANDS_COMMAND_REGISTRY_H_

#include <cstdint>
#include <optional>
#include <string>
#include <string_view>
#include <unordered_map>
#include <vector>

#include "base/files/file_path.h"
#include "build/build_config.h"
#include "open_unified/core/model/open_types.h"

namespace open_unified {

enum class CommandId {
  kUnknown = 0,

  // App menu (9)
  kAboutOpen,
  kSetDefaultBrowser,
  kSettings,
  kCheckForUpdates,
  kImportFromBrowser,
  kHideOpen,
  kHideOthers,
  kShowAll,
  kQuitOpen,

  // File menu (23)
  kNewTab,
  kOpenCommandBar,
  kNewWindow,
  kNewIncognitoWindow,
  kNewLittleOpenWindow,
  kBlankWindow,
  kNewNote,
  kNewNoteInSplit,
  kNewEasel,
  kCloseWindow,
  kArchiveTab,
  kRestoreLastClosedTab,
  kPrint,
  kSavePageAs,
  kCapturePage,
  kCaptureFullPage,
  kCapturePortrait,
  kSharePage,
  kNewProfile,
  kNewBoost,
  kEditBoost,
  kNewLegacyBoost,
  kBoostGallery,

  // Edit menu (18)
  kUndo,
  kRedo,
  kCut,
  kCopy,
  kPaste,
  kPasteAndMatchStyle,
  kSelectAll,
  kDelete,
  kCopyUrl,
  kCopyUrlMarkdown,
  kCopyUrlQuote,
  kFind,
  kFindNext,
  kFindPrevious,
  kFindAndReplace,
  kUseSelectionToFind,
  kJumpToSelection,
  kEmojiAndSymbols,

  // View menu (24)
  kToggleSidebar,
  kToggleToolbar,
  kToggleFullScreen,
  kReload,
  kForceReload,
  kStopLoading,
  kZoomIn,
  kZoomOut,
  kZoomActualSize,
  kAddSplitView,
  kCloseSplitPane,
  kExpandCurrentSplit,
  kSeparateFromSplitView,
  kRevealTabInSidebar,
  kRevealCurrentTab,
  kExpandPinnedSection,
  kCollapsePinnedSection,
  kClearCacheAndRefresh,
  kClearCookiesAndRefresh,
  kCast,
  kExitModal,
  kAppearanceAutomatic,
  kAppearanceLight,
  kAppearanceDark,

  // Spaces menu (7)
  kNewSpace,
  kNextSpace,
  kPreviousSpace,
  kManageSpaces,
  kRenameSpace,
  kEditTheme,
  kChangeProfile,

  // Tabs menu (18)
  kPinUnpinTab,
  kNextTab,
  kPreviousTab,
  kCycleTabForward,
  kCycleTabBackward,
  kTabSwitcherForward,
  kTabSwitcherBackward,
  kClearUnpinnedTabs,
  kNewFolder,
  kDuplicateTab,
  kRenameTab,
  kExpandAllFolders,
  kCollapseAllFolders,
  kResetTab,
  kResetAllTabsInSpace,
  kPeekEmail,
  kJoinMeeting,
  kOpenInCurrentSpace,

  // Archive / Navigation menu (5)
  kGoBack,
  kGoForward,
  kViewArchive,
  kViewHistory,
  kClearArchive,

  // Extensions menu (3)
  kOpenExtensionsPicker,
  kManageExtensions,
  kAddExtension,

  // Window menu (9)
  kViewDownloads,
  kViewLibrary,
  kViewMedia,
  kViewBoosts,
  kStayOnTop,
  kViewEaselsNotes,
  kMinimizeWindow,
  kZoomWindow,
  kBringAllToFront,

  // Help menu (11)
  kExportNotes,
  kHelpCenter,
  kKeyboardShortcutsEdu,
  kGettingStarted,
  kContactTeam,
  kReleaseNotes,
  kTaskManager,
  kRecordTrace,
  kCancelTrace,
  kCopyOpenInfo,
  kRevealOpenData,

  // Developer submenu (View > Developer, 7)
  kDeveloperTools,
  kJavaScriptConsole,
  kViewSource,
  kInspectElements,
  kToggleDeveloperMode,
  kNetworkInspector,
  kAllowJsAppleEvents,

  // Text submenus (Edit > Spelling/Substitutions/Transformations/Speech/Format, 21)
  kShowSpelling,
  kCheckSpelling,
  kCheckSpellingWhileTyping,
  kCheckGrammar,
  kCorrectSpellingAutomatically,
  kShowSubstitutions,
  kSmartCopyPaste,
  kSmartQuotes,
  kSmartDashes,
  kSmartLinks,
  kTextReplacement,
  kDataDetectors,
  kMakeUpperCase,
  kMakeLowerCase,
  kCapitalize,
  kStartSpeaking,
  kStopSpeaking,
  kFontBold,
  kFontItalic,
  kFontUnderline,
  kShowFonts,

  // Code-only & Quick navigation (44)
  kImportArcNotes,
  kChangeSpaceIcon,
  kShowLittleOpenWindows,
  kCloseLittleOpenWindows,
  kExtensionShortcuts,
  kAddToFavorites,
  kRemoveFromFavorites,
  kReplacePinnedUrl,
  kSearchActions,
  kSearchTabs,
  kMuteAllTabs,
  kUnmuteAllTabs,
  kAirTrafficControl,
  kManagePasswords,
  kSearchSettings,
  kLittleOpenGlobal,
  kShowShortcutsOverlay,
  kAccountSync,
  kSyncNow,

  kGoToTab1,
  kGoToTab2,
  kGoToTab3,
  kGoToTab4,
  kGoToTab5,
  kGoToTab6,
  kGoToTab7,
  kGoToTab8,
  kGoToTab9,
  kGoToLastTab,

  kGoToSpace1,
  kGoToSpace2,
  kGoToSpace3,
  kGoToSpace4,
  kGoToSpace5,
  kGoToSpace6,
  kGoToSpace7,
  kGoToSpace8,
  kGoToSpace9,

  kFocusSplitPane1,
  kFocusSplitPane2,
  kFocusSplitPane3,
  kFocusSplitPane4,
  kNextSplitPane,
  kPreviousSplitPane,

  // Reserved out-of-scope Arc commands (4)
  kReservedNewChatGptMessage,
  kReservedSendToDia,
  kReservedShareArc,
  kReservedSignOut,

  kCommandIdCount,
};

enum class CommandScope {
  kGlobal,
  kWindow,
  kSidebarFocused,
  kCommandBar,
  kWebContent,
};

bool CommandScopesOverlap(CommandScope a, CommandScope b);

enum class ShortcutPriority {
  kBrowser,          // "browser"
  kSite,             // "site"
  kSiteThenBrowser,  // "site-then-browser" (0.4s double-press)
};

// Typed availability predicate mirroring EnabledKey in Command.swift.
enum class AvailabilityPredicate {
  kAlways = 0,
  kHasCurrentTab,
  kCurrentTabPinned,
  kCurrentTabInToday,
  kCurrentTabHasPinnedUrl,
  kCurrentTabIsFavorite,
  kCurrentTabNotFavorite,
  kCurrentTabInSplit,
  kHasMultipleSpaces,
  kCanGoBack,
  kCanGoForward,
  kTextFieldFocused,
  kHasHistory,
  kHasWebPage,
  kIsTracing,
  kNotTracing,
};

enum ModifierFlags : uint32_t {
  kModNone = 0,
  kModCtrl = 1u << 0,
  kModAlt = 1u << 1,    // Option on macOS, Alt on Windows/Linux
  kModShift = 1u << 2,
  kModMeta = 1u << 3,   // Command on macOS, Win/Super on Windows/Linux
#if BUILDFLAG(IS_MAC)
  kModPrimary = kModMeta,
#else
  kModPrimary = kModCtrl,
#endif
};

struct KeyboardShortcut {
  std::string key;  // Lowercase base key or token ("t", "left", "tab", "f12")
  uint32_t modifiers = kModNone;

  KeyboardShortcut Normalized() const;
  std::string DisplayString() const;
  std::vector<std::string> ModifierNames() const;
  static uint32_t ModifiersFromNames(const std::vector<std::string>& names);

  bool operator==(const KeyboardShortcut&) const = default;
  bool operator<(const KeyboardShortcut& other) const;
};

struct CommandDefinition {
  CommandId command_id = CommandId::kUnknown;
  std::string id;  // Stable kebab-case id matching CommandRegistry.swift
  std::string title;
  // Runtime menu-bar title matching MenuBuilder.arcMenuTitles (equals |title|
  // when Arc's menu bar uses the command's own title).
  std::string menu_title;
  std::vector<std::string> menu_path;
  std::vector<KeyboardShortcut> default_shortcuts;
  CommandScope scope = CommandScope::kWindow;
  bool is_customizable = false;
  std::string enabled_key = "always";
  AvailabilityPredicate availability_predicate = AvailabilityPredicate::kAlways;
  std::vector<std::string> aliases;
  bool is_reserved = false;
  // True when MenuBuilder keeps the item in the menu bar only as a hidden key
  // equivalent carrier (MenuBuilder.hiddenInMenu).
  bool hidden_in_menu = false;
  // True when OpenWindowUi should register this command's effective shortcuts
  // on the window FocusManager dynamically from CommandRegistry.
  bool is_window_accelerator = false;
  ShortcutPriority default_priority = ShortcutPriority::kBrowser;
};

// Alias for Wave B / UI consumers that refer to CommandInfo.
using CommandInfo = CommandDefinition;

struct KeyBindingOverride {
  std::vector<KeyboardShortcut> shortcuts;
  std::optional<ShortcutPriority> priority;

  bool operator==(const KeyBindingOverride&) const = default;
};

struct ShortcutConflict {
  enum class Kind {
    kDuplicate,
    kReservedKeyReuse,
  };
  Kind kind = Kind::kDuplicate;
  KeyboardShortcut shortcut;
  std::vector<std::string> command_ids;
  bool is_known_arc_duplicate = false;
};

struct KeyRoutingContext {
  bool is_app_active = true;
  bool is_command_bar_open = false;
  bool is_sidebar_focused = false;
  bool is_text_focused = false;
  bool is_web_content_focused = false;
};

struct KeyRoutingDecision {
  enum class Target {
    kBrowserCommand,
    kWebContent,
    kSystem,
    kSwallowed,
  };
  Target target = Target::kSystem;
  CommandId command_id = CommandId::kUnknown;
  std::string command_string_id;
};

class CommandRegistry {
 public:
  static constexpr double kDoublePressIntervalSec = 0.4;
  static constexpr int kKeybindingsSchemaVersion = 1;

  CommandRegistry();
  ~CommandRegistry();

  // Lookup
  const std::vector<CommandDefinition>& all_commands() const {
    return commands_;
  }
  const CommandDefinition* FindById(CommandId id) const;
  const CommandDefinition* FindByStringId(std::string_view id) const;

  // Dynamic queries for OpenWindowUi accelerator registration and macOS
  // MainMenuBuilder.
  std::vector<const CommandDefinition*> WindowAcceleratorCommands() const;
  std::vector<const CommandDefinition*> MenuCommands(
      std::string_view top_level_menu) const;

  static AvailabilityPredicate ParseAvailabilityPredicate(
      std::string_view enabled_key);
  static std::optional<KeyboardShortcut> ParseShortcutString(
      std::string_view text);

  // Effective bindings (overrides take precedence over defaults).
  std::vector<KeyboardShortcut> EffectiveShortcuts(CommandId id) const;
  std::vector<KeyboardShortcut> EffectiveShortcuts(std::string_view id) const;
  ShortcutPriority EffectivePriority(CommandId id) const;
  ShortcutPriority EffectivePriority(std::string_view id) const;

  // Override mutations.
  bool SetOverride(std::string_view command_id, KeyBindingOverride override_val);
  // Clears/unassigns a command's shortcut cleanly (stores an empty override so
  // EffectiveShortcuts returns {} while preserving any custom priority).
  bool ClearBinding(CommandId id);
  bool ClearBinding(std::string_view command_id);
  // Sets a command's shortcut from a display/config string (e.g. "Mod+Shift+T").
  // Passing an empty (or whitespace-only) string clears/unassigns the binding
  // via ClearBinding() and succeeds for any valid non-reserved command.
  bool SetBinding(CommandId id, std::string_view shortcut_str);
  bool SetBinding(std::string_view command_id, std::string_view shortcut_str);
  void ResetOverride(std::string_view command_id);
  void ResetAllOverrides();
  const std::unordered_map<std::string, KeyBindingOverride>& overrides() const {
    return overrides_;
  }

  // Persistence for <data_root>/State/keybindings.json.
  bool LoadOverrides(const base::FilePath& path,
                     std::string* error_out = nullptr);
  bool SaveOverrides(const base::FilePath& path,
                     std::string* error_out = nullptr) const;

  // Conflict detection.
  std::vector<ShortcutConflict> DetectConflicts() const;
  std::vector<ShortcutConflict> DetectUnexpectedConflicts() const;

  // Routes a key event using Open's 5-rule precedence and 0.4s double-press
  // handling for ShortcutPriority::kSiteThenBrowser.
  KeyRoutingDecision RouteShortcut(const KeyboardShortcut& raw_shortcut,
                                   const KeyRoutingContext& context,
                                   TimestampSec now);

 private:
  const CommandDefinition* MatchActiveCommand(
      const KeyboardShortcut& shortcut,
      std::optional<CommandScope> scope_filter) const;

  std::vector<CommandDefinition> commands_;
  std::unordered_map<CommandId, size_t> index_by_enum_;
  std::unordered_map<std::string, size_t> index_by_string_;
  std::unordered_map<std::string, KeyBindingOverride> overrides_;

  // State for 0.4s double-press detection.
  std::optional<KeyboardShortcut> last_site_press_shortcut_;
  TimestampSec last_site_press_at_ = 0.0;
};

}  // namespace open_unified

#endif  // OPEN_UNIFIED_CORE_COMMANDS_COMMAND_REGISTRY_H_
