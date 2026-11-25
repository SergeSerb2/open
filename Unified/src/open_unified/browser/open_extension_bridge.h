// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef OPEN_UNIFIED_BROWSER_OPEN_EXTENSION_BRIDGE_H_
#define OPEN_UNIFIED_BROWSER_OPEN_EXTENSION_BRIDGE_H_

#include <string>
#include <vector>

#include "base/functional/callback.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "base/observer_list.h"
#include "base/observer_list_types.h"
#include "base/scoped_observation.h"
#include "base/values.h"
#include "chrome/browser/ui/toolbar/toolbar_actions_model.h"
#include "extensions/browser/extension_registry.h"
#include "extensions/browser/extension_registry_observer.h"

class Profile;

namespace views {
class View;
}

namespace open_unified {

class OpenBrowserService;

// One extension's toolbar action as Open's surfaces show it: the URL pill
// (pinned actions), the Site Control 4-column grid (all actions), and
// open://settings/extensions (every installed extension).
struct ExtensionActionInfo {
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
};

// Bridges Chromium's real extension system (ExtensionRegistry,
// ToolbarActionsModel, ExtensionActionRunner, ExtensionPopup) to Open's
// views and WebUI, for one Chromium Profile. chrome.tabs/chrome.windows see
// Open's tabs because they are real TabStripModel tabs (OpenTabBridge).
class OpenExtensionBridge : public ToolbarActionsModel::Observer,
                            public extensions::ExtensionRegistryObserver {
 public:
  class Observer : public base::CheckedObserver {
   public:
    // Any action added, removed, updated, pinned or unpinned.
    virtual void OnExtensionActionsChanged() {}
  };

  OpenExtensionBridge(OpenBrowserService* service, ::Profile* profile);
  ~OpenExtensionBridge() override;

  OpenExtensionBridge(const OpenExtensionBridge&) = delete;
  OpenExtensionBridge& operator=(const OpenExtensionBridge&) = delete;

  void AddObserver(Observer* observer);
  void RemoveObserver(Observer* observer);

  // Toolbar actions in ToolbarActionsModel order, pinned ones first.
  std::vector<ExtensionActionInfo> ListActions() const;
  // Every installed extension (enabled and disabled).
  std::vector<ExtensionActionInfo> ListInstalled() const;

  // Runs the action like a click on its button for the active tab of the
  // main window. A popup opens as Chromium's real ExtensionPopup bubble,
  // anchored to |anchor| (the URL pill or the Site Control tile); with no
  // anchor it anchors to the browser's top container. |done| gets true
  // when the popup is showing (or the action ran without one).
  void ExecuteAction(const std::string& extension_id,
                     views::View* anchor,
                     base::OnceCallback<void(bool shown)> done);

  bool SetPinned(const std::string& extension_id, bool pinned);
  bool SetEnabled(const std::string& extension_id, bool enabled);

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

 private:
  ExtensionActionInfo InfoFor(const extensions::Extension& extension) const;
  void NotifyChanged();

  raw_ptr<OpenBrowserService> service_;
  raw_ptr<::Profile> profile_;
  raw_ptr<ToolbarActionsModel> toolbar_model_;
  base::ScopedObservation<ToolbarActionsModel, ToolbarActionsModel::Observer>
      toolbar_observation_{this};
  base::ScopedObservation<extensions::ExtensionRegistry,
                          extensions::ExtensionRegistryObserver>
      registry_observation_{this};
  base::ObserverList<Observer> observers_;
  base::WeakPtrFactory<OpenExtensionBridge> weak_factory_{this};
};

}  // namespace open_unified

#endif  // OPEN_UNIFIED_BROWSER_OPEN_EXTENSION_BRIDGE_H_
