// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef OPEN_BROWSER_EXTENSIONS_OPEN_EXTENSIONS_TOOLBAR_H_
#define OPEN_BROWSER_EXTENSIONS_OPEN_EXTENSIONS_TOOLBAR_H_

#include <map>
#include <memory>
#include <set>
#include <string>
#include <vector>

#include "base/callback_list.h"
#include "base/containers/flat_map.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "base/scoped_observation.h"
#include "cef/include/cef_image.h"
#include "cef/include/cef_values.h"
#include "chrome/browser/ui/extensions/extension_popup_types.h"
#include "chrome/browser/ui/extensions/extensions_toolbar_view_model.h"
#include "ui/base/unowned_user_data/scoped_unowned_user_data.h"

class Browser;
class Profile;

namespace extensions {
class ExtensionContextMenuModel;
class ExtensionViewHost;
}

namespace ui {
class MenuModel;
}

namespace open_engine {

class OpenExtensionPopup;
class OpenTabStrip;

// Chrome's toolbar action model for one hidden tab-strip Browser (fork patch
// P2, docs/engine-patches.md): an ExtensionsToolbarViewModel, registered as
// the window's ExtensionsContainer, whose actions run, open popups, and
// report changes through the strip's CefTabStripHandler. There is no Views
// toolbar: the embedder draws the actions. Template:
// chrome/browser/ui/android/extensions/extensions_toolbar_android.cc.
class OpenExtensionsToolbar : public ExtensionsToolbarViewModel::Delegate,
                              public ExtensionsToolbarViewModel::Observer {
 public:
  // CefTabStrip::ExecuteExtensionAction sources.
  enum Source { kToolbarButton = 0, kMenuEntry = 1, kCommand = 2 };
  // CefTabStripHandler::OnExtensionPopupOpened sources.
  enum PopupSource { kPopupUser = 0, kPopupCommand = 1, kPopupApi = 2 };

  OpenExtensionsToolbar(OpenTabStrip* strip, Browser* browser);
  OpenExtensionsToolbar(const OpenExtensionsToolbar&) = delete;
  OpenExtensionsToolbar& operator=(const OpenExtensionsToolbar&) = delete;
  ~OpenExtensionsToolbar() override;

  // CefTabStrip without a live model (no hidden Browser): the profile's
  // action list, pins, and tab-independent defaults.
  static std::vector<std::string> ProfileActionIds(Profile* profile);
  static CefRefPtr<CefDictionaryValue> ProfileState(Profile* profile,
                                                    const std::string& id);
  static CefRefPtr<CefImage> ProfileImage(Profile* profile,
                                          const std::string& id,
                                          int size);

  // CefTabStrip, for this window.
  bool IsReady();
  std::vector<std::string> ActionIds();
  CefRefPtr<CefDictionaryValue> State(const std::string& id);
  CefRefPtr<CefImage> Image(const std::string& id, int size, bool toolbar);
  void SetPinned(const std::string& id, bool pinned);
  void MovePinned(const std::string& id, int index);
  bool Execute(const std::string& id, int source);
  void ClosePopup();
  bool PopupStaysOpenOnBlur() const;
  CefRefPtr<CefListValue> Menu(const std::string& id, int source, int* menu_id);
  bool RunMenuCommand(int menu_id, int command_id);
  void ReleaseMenu(int menu_id);

  // OpenTabStrip: the active tab changed. Closes the popup, as Chrome's
  // ExtensionPopup::OnTabStripModelChanged does.
  void OnActiveTabChanged();

  // OpenExtensionActionDelegate.
  void TriggerPopup(const std::string& id,
                    std::unique_ptr<extensions::ExtensionViewHost> host,
                    PopupShowAction show_action,
                    bool by_user,
                    ShowPopupCallback callback);
  bool IsShowingPopup(const std::string& id) const;
  gfx::NativeView PopupNativeView() const;
  // A disabled action ran: Chrome shows its context menu instead.
  void RequestMenu(const std::string& id);

  // OpenExtensionPopup.
  OpenTabStrip* strip() const { return strip_; }
  void PopupWantsClose(OpenExtensionPopup* popup);

  // ExtensionsToolbarViewModel::Delegate:
  std::unique_ptr<ExtensionActionViewModel> CreateActionViewModel(
      const ToolbarActionsModel::ActionId& action_id,
      ExtensionsContainer* extensions_container) override;
  void HideActivePopup() override;
  void CloseExtensionsMenuIfOpen() override {}
  bool CanShowToolbarActionPopupForAPICall(
      const ToolbarActionsModel::ActionId& action_id) override;
  void ToggleExtensionsMenu() override {}

  // ExtensionsToolbarViewModel::Observer:
  void OnActionsInitialized() override;
  void OnActionAdded(const ToolbarActionsModel::ActionId& action_id) override;
  void OnActionRemoved(const ToolbarActionsModel::ActionId& action_id) override;
  void OnActionUpdated(const ToolbarActionsModel::ActionId& action_id) override;
  void OnPinnedActionsChanged() override;
  void OnActiveWebContentsChanged(bool is_same_document,
                                  content::WebContents* web_contents) override;

 private:
  struct OpenMenu {
    OpenMenu();
    OpenMenu(OpenMenu&&);
    OpenMenu& operator=(OpenMenu&&);
    ~OpenMenu();
    std::string action_id;
    std::unique_ptr<extensions::ExtensionContextMenuModel> model;
  };

  ToolbarActionViewModel* Action(const std::string& id) const;
  content::WebContents* ActiveContents() const;
  // Closes the popup on a later turn (not inside the notification that
  // asked), unless another popup took its place.
  void ClosePopupSoon();
  void DropMenusFor(const std::string& id);
  void ObserveIcon(const std::string& id);
  // Coalesced handler calls: at most one per action (and one list change)
  // per message loop turn.
  void ScheduleListChanged();
  void ScheduleUpdated(const std::string& id);
  void Flush();

  const raw_ptr<OpenTabStrip> strip_;
  const raw_ptr<Browser> browser_;
  // The action model destructors read popup state. Keep it alive until after model_.
  std::unique_ptr<OpenExtensionPopup> popup_;
  std::unique_ptr<ExtensionsToolbarViewModel> model_;
  ui::ScopedUnownedUserData<ExtensionsContainer> container_user_data_;
  base::ScopedObservation<ExtensionsToolbarViewModel,
                          ExtensionsToolbarViewModel::Observer>
      observation_{this};
  base::flat_map<std::string, base::CallbackListSubscription>
      icon_subscriptions_;
  // Counts popups, so a deferred close cannot hit a later popup.
  int popup_serial_ = 0;
  // The user source of the action that runs now (Execute); a popup that
  // Chromium triggers on its own comes from chrome.action.openPopup().
  int running_source_ = -1;
  // GetExtensionActionMenu: each returned menu's own model, by menu id.
  std::map<int, OpenMenu> menus_;
  bool list_changed_ = false;
  std::set<std::string> updated_;
  bool flush_scheduled_ = false;

  base::WeakPtrFactory<OpenExtensionsToolbar> weak_ptr_factory_{this};
};

}  // namespace open_engine

#endif  // OPEN_BROWSER_EXTENSIONS_OPEN_EXTENSIONS_TOOLBAR_H_
