// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef OPEN_UNIFIED_BROWSER_OPEN_EXTENSION_BRIDGE_H_
#define OPEN_UNIFIED_BROWSER_OPEN_EXTENSION_BRIDGE_H_

#include <map>
#include <memory>
#include <optional>
#include <string>
#include <vector>

#include "base/callback_list.h"
#include "base/functional/callback.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "base/observer_list.h"
#include "base/observer_list_types.h"
#include "base/scoped_observation.h"
#include "base/values.h"
#include "chrome/browser/extensions/extension_action_dispatcher.h"
#include "chrome/browser/ui/toolbar/toolbar_actions_model.h"
#include "extensions/browser/extension_registry.h"
#include "extensions/browser/extension_registry_observer.h"
#include "third_party/skia/include/core/SkColor.h"
#include "ui/base/mojom/menu_source_type.mojom-forward.h"
#include "ui/gfx/geometry/point.h"
#include "ui/gfx/geometry/rect.h"
#include "ui/gfx/geometry/size.h"
#include "ui/gfx/image/image_skia.h"

class BrowserWindowInterface;
class Profile;

namespace content {
class WebContents;
}  // namespace content

namespace views {
class View;
class Widget;
}  // namespace views

namespace open_unified {

class OpenBrowserService;

// One extension's toolbar action as Open's surfaces show it: the URL pill
// (pinned actions), the Site Control 4-column grid (all actions), the
// Extensions Picker, and open://settings/extensions (every installed
// extension).
struct ExtensionActionInfo {
  ExtensionActionInfo();
  ExtensionActionInfo(const ExtensionActionInfo&);
  ExtensionActionInfo& operator=(const ExtensionActionInfo&);
  ExtensionActionInfo(ExtensionActionInfo&&) noexcept;
  ExtensionActionInfo& operator=(ExtensionActionInfo&&) noexcept;
  ~ExtensionActionInfo();

  std::string id;
  std::string name;
  std::string version;
  std::string description;
  std::string title;       // Action title for the active tab.
  std::string badge_text;  // Display badge for the active tab.
  bool enabled = false;
  bool pinned = false;
  bool force_pinned = false;
  bool has_popup = false;
  bool visible = true;     // Declarative/page-action visibility.
  std::vector<std::string> permissions;

  // --- Live toolbar state for the window's active tab ---
  // The action's own icon (ExtensionActionIconFactory: per-tab icon, the
  // declarative icon, or the manifest icon); null only while it loads.
  gfx::ImageSkia icon;
  // Chromium's toolbar rendering: the icon with the badge drawn in and the
  // grayscale "cannot act on this page" treatment (ExtensionActionViewModel::
  // GetIcon). Filled by GetAllToolbarActions only.
  gfx::ImageSkia icon_with_badge;
  SkColor badge_background_color = SK_ColorTRANSPARENT;
  SkColor badge_text_color = SK_ColorWHITE;
  std::u16string tooltip;  // ExtensionActionViewModel::GetTooltip.
  // The action can run on the active tab (ExtensionActionViewModel::
  // IsEnabled); false greys the button.
  bool runnable = true;
  bool popup_showing = false;
  // "_execute_action" shortcut, e.g. "Ctrl+Shift+Y" (empty when none).
  std::u16string shortcut;
};

// The window that hosts extension UI: a regular browser window, or a window
// without its own Browser (Little Open), which borrows its Profile's browser
// for Chromium's popup and context-menu plumbing.
struct ExtensionHostWindow {
  ExtensionHostWindow();
  ExtensionHostWindow(const ExtensionHostWindow&);
  ExtensionHostWindow& operator=(const ExtensionHostWindow&);
  ~ExtensionHostWindow();

  // Required. For Little Open: a browser of the same Profile.
  raw_ptr<BrowserWindowInterface> browser = nullptr;
  // The top-level widget that holds the anchors and owns the keyboard focus.
  // Null: the browser's own window.
  raw_ptr<views::Widget> widget = nullptr;
  // The window's active page. Null: the browser's active tab.
  base::RepeatingCallback<content::WebContents*()> active_contents;
};

// Bridges Chromium's real extension system (ExtensionRegistry,
// ToolbarActionsModel, ExtensionActionViewModel, ExtensionActionRunner,
// ExtensionPopup, ExtensionContextMenuModel, ExtensionKeybindingRegistryViews)
// to Open's views and WebUI, for one Chromium Profile. chrome.tabs and
// chrome.windows see Open's tabs because they are real TabStripModel tabs
// (OpenTabBridge).
class OpenExtensionBridge : public ToolbarActionsModel::Observer,
                            public extensions::ExtensionRegistryObserver,
                            public extensions::ExtensionActionDispatcher::Observer {
 public:
  class Observer : public base::CheckedObserver {
   public:
    // Any action added, removed, updated (icon, badge, title, visibility),
    // pinned or unpinned. The window controller forwards it to
    // OpenViewObserver::OnToolbarActionsChanged.
    virtual void OnExtensionActionsChanged() {}
    // One action's per-tab state changed (badge, icon, title). Also followed
    // by OnExtensionActionsChanged.
    virtual void OnExtensionActionUpdated(const std::string& extension_id) {}
    // A popup opened or closed for `extension_id`.
    virtual void OnExtensionPopupVisibilityChanged(
        const std::string& extension_id,
        bool showing) {}
  };

  // Callbacks for the Extensions Picker footer.
  struct PickerCallbacks {
    PickerCallbacks();
    PickerCallbacks(const PickerCallbacks&);
    PickerCallbacks& operator=(const PickerCallbacks&);
    ~PickerCallbacks();

    base::RepeatingClosure on_manage_extensions;  // open://settings/extensions
    base::RepeatingClosure on_add_extension;      // Chrome Web Store
    base::RepeatingClosure on_closed;
    bool dark = false;  // The window's appearance (panel colors).
  };

  OpenExtensionBridge(OpenBrowserService* service, ::Profile* profile);
  ~OpenExtensionBridge() override;

  OpenExtensionBridge(const OpenExtensionBridge&) = delete;
  OpenExtensionBridge& operator=(const OpenExtensionBridge&) = delete;

  void AddObserver(Observer* observer);
  void RemoveObserver(Observer* observer);

  // --- Windows ---------------------------------------------------------------

  // Registers a window that shows extension UI. Creates its per-window action
  // view models and, for a window without Chromium's own keybinding registry
  // (Little Open), an ExtensionKeybindingRegistryViews on its FocusManager,
  // so manifest "commands" and "_execute_action" work in every window.
  // Idempotent; the window is forgotten when its widget or browser goes away
  // (or on DetachWindow).
  void AttachWindow(const ExtensionHostWindow& window);
  void DetachWindow(views::Widget* widget);
  void DetachBrowser(BrowserWindowInterface* browser);

  // --- Lists -----------------------------------------------------------------

  // Toolbar actions in ToolbarActionsModel order, pinned ones first (main
  // window, no icons).
  std::vector<ExtensionActionInfo> ListActions() const;
  // Every installed extension (enabled and disabled).
  std::vector<ExtensionActionInfo> ListInstalled() const;
  // The toolbar actions as `browser`'s window shows them, with live icons,
  // badge text and colors, tooltip and runnable state for its active tab.
  // Pinned actions first in the user's order, then (with
  // `include_unpinned`) the rest by name.
  std::vector<ExtensionActionInfo> GetAllToolbarActions(
      BrowserWindowInterface* browser,
      bool include_unpinned,
      const gfx::Size& icon_size = gfx::Size(16, 16));
  std::vector<ExtensionActionInfo> GetAllToolbarActions(
      const ExtensionHostWindow& window,
      bool include_unpinned,
      const gfx::Size& icon_size = gfx::Size(16, 16));

  // --- Actions ---------------------------------------------------------------

  // Runs the action like a click on its button for the active tab of the
  // main window. A popup opens as Chromium's real ExtensionPopup bubble,
  // anchored to |anchor| (the URL pill or the Site Control tile); with no
  // anchor it anchors to the browser's top container. |done| gets true
  // when the popup is showing (or the action ran without one).
  void ExecuteAction(const std::string& extension_id,
                     views::View* anchor,
                     base::OnceCallback<void(bool shown)> done);
  // The same for the calling window. `anchor` is the clicked button; when it
  // is null, `anchor_rect_in_screen` finds the view under that rect in the
  // window (the URL pill button the sidebar reported). A second click on an
  // action whose popup is showing closes the popup (toolbar behavior).
  void ExecuteAction(const ExtensionHostWindow& window,
                     const std::string& extension_id,
                     views::View* anchor,
                     std::optional<gfx::Rect> anchor_rect_in_screen,
                     base::OnceCallback<void(bool shown)> done);
  void ExecuteAction(BrowserWindowInterface* browser,
                     const std::string& extension_id,
                     views::View* anchor,
                     std::optional<gfx::Rect> anchor_rect_in_screen,
                     base::OnceCallback<void(bool shown)> done);
  // Closes the popup the bridge opened in `widget`'s window (null: any).
  void HidePopups(views::Widget* widget = nullptr);
  bool IsPopupShowing(const std::string& extension_id) const;

  // Right-click menu of an extension button (URL pill, Site Control tile,
  // picker row): Chromium's real ExtensionContextMenuModel (name / site
  // access, Options, Remove from Open, Pin / Unpin, Manage Extension,
  // Inspect Popup). Returns false when the action is unknown.
  bool ShowContextMenu(const ExtensionHostWindow& window,
                       const std::string& extension_id,
                       views::View* anchor,
                       const gfx::Point& point_in_screen,
                       ui::mojom::MenuSourceType source_type);

  // --- Pinning ---------------------------------------------------------------

  bool IsActionPinned(const std::string& extension_id) const;
  // Persisted through ToolbarActionsModel::SetActionVisibility. Refuses
  // force-pinned (policy) actions and off-the-record Profiles.
  bool SetActionPinned(const std::string& extension_id, bool pinned);
  bool SetPinned(const std::string& extension_id, bool pinned);
  bool SetEnabled(const std::string& extension_id, bool enabled);

  // --- Extensions Picker ("open-extensions-picker") --------------------------

  // An anchored popover listing every toolbar action with its icon, badge,
  // a pin toggle and click-to-run, and a "Manage Extensions" / "Add
  // Extension" footer. Reopening replaces it.
  void ShowExtensionsPicker(const ExtensionHostWindow& window,
                            views::View* anchor,
                            const PickerCallbacks& callbacks);
  void CloseExtensionsPicker();
  bool IsExtensionsPickerShowing() const;

  // JSON for WebUI (bridge.ts ExtensionItem) and automation.
  static base::DictValue ToValue(const ExtensionActionInfo& info);

  // ToolbarActionsModel::Observer:
  void OnToolbarActionAdded(const ToolbarActionsModel::ActionId& id) override;
  void OnToolbarActionRemoved(const ToolbarActionsModel::ActionId& id) override;
  void OnToolbarActionUpdated(const ToolbarActionsModel::ActionId& id) override;
  void OnToolbarModelInitialized() override;
  void OnToolbarPinnedActionsChanged() override;
  void OnToolbarActionsModelShutdown() override;

  // extensions::ExtensionRegistryObserver:
  void OnExtensionLoaded(content::BrowserContext* browser_context,
                         const extensions::Extension* extension) override;
  void OnExtensionUnloaded(content::BrowserContext* browser_context,
                           const extensions::Extension* extension,
                           extensions::UnloadedExtensionReason reason) override;
  void OnExtensionInstalled(content::BrowserContext* browser_context,
                            const extensions::Extension* extension,
                            bool is_update) override;
  void OnExtensionUninstalled(content::BrowserContext* browser_context,
                              const extensions::Extension* extension,
                              extensions::UninstallReason reason) override;

  // extensions::ExtensionActionDispatcher::Observer:
  void OnExtensionActionUpdated(extensions::ExtensionAction* extension_action,
                                content::WebContents* web_contents,
                                content::BrowserContext* browser_context)
      override;
  void OnShuttingDown() override;

 private:
  class ActionEntry;
  class ActionDelegate;
  class PickerView;
  class PickerBubble;
  struct WindowState;

  ExtensionActionInfo InfoFor(const extensions::Extension& extension) const;
  ExtensionActionInfo InfoForTab(const extensions::Extension& extension,
                                 content::WebContents* contents) const;
  // Pinned ids in the user's order, then the rest by name.
  std::vector<std::string> OrderedActionIds(bool include_unpinned) const;
  WindowState* EnsureWindow(const ExtensionHostWindow& window);
  WindowState* FindWindow(views::Widget* widget);
  WindowState* FindWindowForBrowser(BrowserWindowInterface* browser);
  ActionEntry* EnsureEntry(WindowState* window, const std::string& id);
  views::Widget* WidgetFor(const ExtensionHostWindow& window) const;
  void DropEntry(const std::string& extension_id);
  void OnWidgetGone(views::Widget* widget);
  void OnPopupVisibility(const std::string& extension_id, bool showing);
  void OnEntryIconUpdated(const std::string& extension_id);
  void NotifyChanged();
  void NotifyActionUpdated(const std::string& extension_id);
  // Coalesces bursts (icon loads, badge ticks) into one notification.
  void NotifyChangedSoon();

  raw_ptr<OpenBrowserService> service_;
  raw_ptr<::Profile> profile_;
  raw_ptr<ToolbarActionsModel> toolbar_model_;
  base::ScopedObservation<ToolbarActionsModel, ToolbarActionsModel::Observer>
      toolbar_observation_{this};
  base::ScopedObservation<extensions::ExtensionRegistry,
                          extensions::ExtensionRegistryObserver>
      registry_observation_{this};
  base::ScopedObservation<extensions::ExtensionActionDispatcher,
                          extensions::ExtensionActionDispatcher::Observer>
      dispatcher_observation_{this};
  base::ObserverList<Observer> observers_;
  // Keyed by the window's top-level widget.
  std::map<views::Widget*, std::unique_ptr<WindowState>> windows_;
  // The open Extensions Picker (bubble owner) and its contents view.
  std::unique_ptr<PickerBubble> picker_bubble_;
  raw_ptr<PickerView> picker_view_ = nullptr;
  bool change_pending_ = false;
  base::WeakPtrFactory<OpenExtensionBridge> weak_factory_{this};
};

}  // namespace open_unified

#endif  // OPEN_UNIFIED_BROWSER_OPEN_EXTENSION_BRIDGE_H_
