// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "open/browser/extensions/open_extensions_toolbar.h"

#include <algorithm>
#include <utility>

#include "base/functional/bind.h"
#include "base/strings/utf_string_conversions.h"
#include "base/task/single_thread_task_runner.h"
#include "cef/libcef/browser/image_impl.h"
#include "chrome/browser/extensions/extension_action_runner.h"
#include "chrome/browser/extensions/extension_view_host.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/ui/browser.h"
#include "chrome/browser/ui/extensions/extension_action_delegate.h"
#include "chrome/browser/ui/extensions/extension_action_view_model.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"
#include "chrome/browser/ui/toolbar/toolbar_actions_model.h"
#include "components/sessions/content/session_tab_helper.h"
#include "content/public/browser/web_contents.h"
#include "extensions/browser/extension_action.h"
#include "extensions/browser/extension_action_manager.h"
#include "extensions/browser/extension_registry.h"
#include "extensions/browser/permissions_manager.h"
#include "extensions/browser/permissions/site_permissions_helper.h"
#include "open/browser/extensions/open_extension_popup.h"
#include "open/browser/tab_strip/open_tab_strip.h"
#include "skia/ext/image_operations.h"
#include "ui/base/models/image_model.h"
#include "ui/base/models/menu_model.h"
#include "ui/gfx/image/image_skia_operations.h"
#include "url/origin.h"

namespace open_engine {

namespace {

using InvocationSource = ToolbarActionViewModel::InvocationSource;

// One action's ExtensionActionDelegate: popups and their state go to the
// window's toolbar. Template: extension_action_delegate_android.cc.
class OpenExtensionActionDelegate : public ExtensionActionDelegate {
 public:
  OpenExtensionActionDelegate(OpenExtensionsToolbar* toolbar, std::string id)
      : toolbar_(toolbar), id_(std::move(id)) {}

  void AttachToModel(ExtensionActionViewModel* model) override {}
  void DetachFromModel() override {}
  // Keyboard commands need a keybinding registry (docs/followups.md).
  void RegisterCommand() override {}
  void UnregisterCommand() override {}
  bool IsShowingPopup() const override {
    return toolbar_->IsShowingPopup(id_);
  }
  void HidePopup() override {
    if (IsShowingPopup()) {
      toolbar_->HideActivePopup();
    }
  }
  gfx::NativeView GetPopupNativeView() override {
    return toolbar_->PopupNativeView();
  }
  void TriggerPopup(std::unique_ptr<extensions::ExtensionViewHost> host,
                    PopupShowAction show_action,
                    bool by_user,
                    ShowPopupCallback callback) override {
    toolbar_->TriggerPopup(id_, std::move(host), show_action, by_user,
                           std::move(callback));
  }
  // The embedder shows the context menu (GetExtensionActionMenu).
  void ShowContextMenuAsFallback() override {}
  void CloseExtensionsMenuIfOpen() override {}

 private:
  const raw_ptr<OpenExtensionsToolbar> toolbar_;
  const std::string id_;
};

gfx::ImageSkia Resized(const gfx::ImageSkia& image, int size) {
  if (image.isNull() || (image.width() == size && image.height() == size)) {
    return image;
  }
  return gfx::ImageSkiaOperations::CreateResizedImage(
      image, skia::ImageOperations::RESIZE_BEST, gfx::Size(size, size));
}

// CefTabStrip::GetExtensionActionState "siteAccess".
int SiteAccess(Profile* profile,
               const extensions::Extension& extension,
               content::WebContents* contents,
               extensions::SitePermissionsHelper::SiteInteraction interaction) {
  using Interaction = extensions::SitePermissionsHelper::SiteInteraction;
  auto* permissions = extensions::PermissionsManager::Get(profile);
  if (!contents || !permissions) {
    return 0;
  }
  const GURL& url = contents->GetLastCommittedURL();
  if (permissions->GetUserSiteSetting(url::Origin::Create(url)) ==
      extensions::PermissionsManager::UserSiteSetting::kBlockAllExtensions) {
    return 4;
  }
  if (interaction == Interaction::kNone) {
    return 0;
  }
  using Access = extensions::PermissionsManager::UserSiteAccess;
  if (permissions->CanAffectExtension(extension) &&
      permissions->CanUserSelectSiteAccess(extension, url, Access::kOnClick)) {
    switch (permissions->GetUserSiteAccess(extension, url)) {
      case Access::kOnClick:
        return 1;
      case Access::kOnSite:
        return 2;
      case Access::kOnAllSites:
        return 3;
    }
  }
  return interaction == Interaction::kGranted ? 3 : 1;
}

CefRefPtr<CefListValue> MenuItems(ui::MenuModel* model) {
  auto items = CefListValue::Create();
  for (size_t i = 0; i < model->GetItemCount(); ++i) {
    if (!model->IsVisibleAt(i)) {
      continue;
    }
    auto item = CefDictionaryValue::Create();
    const auto type = model->GetTypeAt(i);
    item->SetBool("separator", type == ui::MenuModel::TYPE_SEPARATOR);
    item->SetInt("command", model->GetCommandIdAt(i));
    item->SetString("label", base::UTF16ToUTF8(model->GetLabelAt(i)));
    item->SetBool("enabled", model->IsEnabledAt(i));
    item->SetBool("checked", (type == ui::MenuModel::TYPE_CHECK ||
                              type == ui::MenuModel::TYPE_RADIO) &&
                                 model->IsItemCheckedAt(i));
    if (type == ui::MenuModel::TYPE_SUBMENU && model->GetSubmenuModelAt(i)) {
      item->SetList("submenu", MenuItems(model->GetSubmenuModelAt(i)));
    }
    items->SetDictionary(items->GetSize(), item);
  }
  return items;
}

}  // namespace

OpenExtensionsToolbar::OpenExtensionsToolbar(OpenTabStrip* strip,
                                             Browser* browser)
    : strip_(strip),
      browser_(browser),
      model_(std::make_unique<ExtensionsToolbarViewModel>(
          this,
          browser,
          ToolbarActionsModel::Get(browser->GetProfile()))),
      container_user_data_(browser->GetUnownedUserDataHost(), *model_) {
  observation_.Observe(model_.get());
  if (model_->AreActionsInitialized()) {
    OnActionsInitialized();
  }
}

OpenExtensionsToolbar::~OpenExtensionsToolbar() {
  if (popup_) {
    auto popup = std::move(popup_);
    popup->NotifyClosing();
  }
}

bool OpenExtensionsToolbar::IsReady() {
  return model_->AreActionsInitialized();
}

std::vector<std::string> OpenExtensionsToolbar::ActionIds() {
  if (!IsReady()) {
    return {};
  }
  std::vector<std::string> ids(model_->GetPinnedActionIds().begin(),
                               model_->GetPinnedActionIds().end());
  for (const auto& id : model_->GetAllActionIds()) {
    if (std::find(ids.begin(), ids.end(), id) == ids.end()) {
      ids.push_back(id);
    }
  }
  return ids;
}

ToolbarActionViewModel* OpenExtensionsToolbar::Action(
    const std::string& id) const {
  return model_->GetActionModelForId(id);
}

content::WebContents* OpenExtensionsToolbar::ActiveContents() const {
  return browser_->tab_strip_model()->GetActiveWebContents();
}

CefRefPtr<CefDictionaryValue> OpenExtensionsToolbar::State(
    const std::string& id) {
  ToolbarActionViewModel* action = Action(id);
  if (!action) {
    return nullptr;
  }
  content::WebContents* contents = ActiveContents();
  auto state = CefDictionaryValue::Create();
  state->SetString("name", base::UTF16ToUTF8(action->GetActionName()));
  state->SetString("title", base::UTF16ToUTF8(action->GetActionTitle(contents)));
  state->SetString("accessibleName",
                   base::UTF16ToUTF8(action->GetAccessibleName(contents)));
  state->SetString("tooltip", base::UTF16ToUTF8(action->GetTooltip(contents)));
  state->SetBool("enabled", action->IsEnabled(contents));
  state->SetBool("showingPopup", IsShowingPopup(id));
  const auto& pinned = model_->GetPinnedActionIds();
  auto it = std::find(pinned.begin(), pinned.end(), id);
  state->SetBool("pinned", it != pinned.end());
  state->SetInt("pinnedIndex",
                it == pinned.end() ? -1 : static_cast<int>(it - pinned.begin()));

  Profile* profile = browser_->GetProfile();
  const extensions::Extension* extension =
      extensions::ExtensionRegistry::Get(profile)->enabled_extensions().GetByID(
          id);
  extensions::ExtensionAction* extension_action =
      extension ? extensions::ExtensionActionManager::Get(profile)
                      ->GetExtensionAction(*extension)
                : nullptr;
  const int tab_id = contents
                         ? sessions::SessionTabHelper::IdForTab(contents).id()
                         : extensions::ExtensionAction::kDefaultTabId;
  if (extension_action) {
    state->SetString("badgeText", extension_action->GetDisplayBadgeText(tab_id));
    state->SetInt("badgeBackgroundColor",
                  static_cast<int>(
                      extension_action->GetBadgeBackgroundColor(tab_id)));
    const SkColor text_color = extension_action->GetBadgeTextColor(tab_id);
    if (SkColorGetA(text_color)) {
      state->SetInt("badgeTextColor", static_cast<int>(text_color));
    }
    state->SetBool("hasPopup", extension_action->HasPopup(tab_id));
  } else {
    state->SetString("badgeText", "");
    state->SetInt("badgeBackgroundColor", 0);
    state->SetBool("hasPopup", false);
  }
  bool wants_to_run = false;
  if (contents && extension) {
    if (auto* runner =
            extensions::ExtensionActionRunner::GetForWebContents(contents)) {
      wants_to_run = runner->WantsToRun(extension);
    }
  }
  state->SetBool("wantsToRun", wants_to_run);
  state->SetInt("siteAccess",
                extension ? SiteAccess(profile, *extension, contents,
                                       action->GetSiteInteraction(contents))
                          : 0);
  return state;
}

CefRefPtr<CefImage> OpenExtensionsToolbar::Image(const std::string& id,
                                                 int size,
                                                 bool toolbar) {
  ToolbarActionViewModel* action = Action(id);
  if (!action || size <= 0) {
    return nullptr;
  }
  content::WebContents* contents = ActiveContents();
  gfx::ImageSkia image;
  if (toolbar) {
    // Icon, badge, disabled state, and decorations, as Chrome's toolbar
    // draws them (IconWithBadgeImageSource).
    ui::ImageModel model = action->GetIcon(contents, gfx::Size(size, size));
    if (model.IsImage()) {
      image = model.GetImage().AsImageSkia();
    }
  } else {
    Profile* profile = browser_->GetProfile();
    const extensions::Extension* extension =
        extensions::ExtensionRegistry::Get(profile)
            ->enabled_extensions()
            .GetByID(id);
    auto* extension_action =
        extension ? extensions::ExtensionActionManager::Get(profile)
                        ->GetExtensionAction(*extension)
                  : nullptr;
    if (extension_action) {
      const int tab_id =
          contents ? sessions::SessionTabHelper::IdForTab(contents).id()
                   : extensions::ExtensionAction::kDefaultTabId;
      gfx::Image plain = extension_action->GetExplicitlySetIcon(tab_id);
      if (plain.IsEmpty()) {
        plain = extension_action->GetDeclarativeIcon(tab_id);
      }
      if (plain.IsEmpty()) {
        plain = extension_action->GetDefaultIconImage();
      }
      image = Resized(plain.AsImageSkia(), size);
    }
  }
  if (image.isNull()) {
    return nullptr;
  }
  // Make the 1x and 2x representations now: the image source draws lazily.
  image.GetRepresentation(1.0f);
  image.GetRepresentation(2.0f);
  return new CefImageImpl(image);
}

void OpenExtensionsToolbar::SetPinned(const std::string& id, bool pinned) {
  if (Action(id)) {
    ToolbarActionsModel::Get(browser_->GetProfile())
        ->SetActionVisibility(id, pinned);
  }
}

void OpenExtensionsToolbar::MovePinned(const std::string& id, int index) {
  const auto& pinned = model_->GetPinnedActionIds();
  if (Action(id) && index >= 0 &&
      std::find(pinned.begin(), pinned.end(), id) != pinned.end()) {
    model_->MovePinnedAction(id, static_cast<size_t>(index));
  }
}

bool OpenExtensionsToolbar::Execute(const std::string& id, int source) {
  if (!Action(id)) {
    return false;
  }
  running_source_ = source;
  model_->ExecuteUserAction(id, source == kMenuEntry ? InvocationSource::kMenuEntry
                                : source == kCommand
                                    ? InvocationSource::kCommand
                                    : InvocationSource::kToolbarButton);
  running_source_ = -1;
  return true;
}

void OpenExtensionsToolbar::ClosePopup() {
  HideActivePopup();
}

CefRefPtr<CefListValue> OpenExtensionsToolbar::Menu(const std::string& id,
                                                    int source) {
  ToolbarActionViewModel* action = Action(id);
  if (!action) {
    return nullptr;
  }
  menu_ = action->GetContextMenu(
      source == 1
          ? extensions::ExtensionContextMenuModel::ContextMenuSource::kMenuItem
          : extensions::ExtensionContextMenuModel::ContextMenuSource::
                kToolbarAction);
  menu_action_ = id;
  return menu_ ? MenuItems(menu_) : CefListValue::Create();
}

void OpenExtensionsToolbar::RunMenuCommand(const std::string& id,
                                           int command_id) {
  if (!menu_ || menu_action_ != id) {
    return;
  }
  ui::MenuModel* model = menu_;
  menu_ = nullptr;
  size_t index = 0;
  if (ui::MenuModel::GetModelAndIndexForCommandId(command_id, &model,
                                                  &index)) {
    model->ActivatedAt(index);
  }
}

void OpenExtensionsToolbar::TriggerPopup(
    const std::string& id,
    std::unique_ptr<extensions::ExtensionViewHost> host,
    PopupShowAction show_action,
    bool by_user,
    ShowPopupCallback callback) {
  // One popup per window, as in Chrome.
  HideActivePopup();
  const int source = running_source_ == kCommand ? kPopupCommand
                     : (by_user || running_source_ >= 0) ? kPopupUser
                                                         : kPopupApi;
  popup_ = std::make_unique<OpenExtensionPopup>(
      this, id, std::move(host), show_action == PopupShowAction::kShowAndInspect,
      std::move(callback), source);
  if (!popup_->Start()) {
    popup_.reset();
  }
  ScheduleUpdated(id);
}

bool OpenExtensionsToolbar::IsShowingPopup(const std::string& id) const {
  return popup_ && popup_->action_id() == id;
}

gfx::NativeView OpenExtensionsToolbar::PopupNativeView() const {
  return popup_ ? popup_->native_view() : gfx::NativeView();
}

void OpenExtensionsToolbar::PopupWantsClose(OpenExtensionPopup* popup) {
  // Not inside the ExtensionHost's own close notification.
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce(
                     [](base::WeakPtr<OpenExtensionsToolbar> self,
                        OpenExtensionPopup* popup) {
                       if (self && self->popup_.get() == popup) {
                         self->HideActivePopup();
                       }
                     },
                     weak_ptr_factory_.GetWeakPtr(), popup));
}

std::unique_ptr<ExtensionActionViewModel>
OpenExtensionsToolbar::CreateActionViewModel(
    const ToolbarActionsModel::ActionId& action_id,
    ExtensionsContainer* extensions_container) {
  return ExtensionActionViewModel::Create(
      action_id, browser_,
      std::make_unique<OpenExtensionActionDelegate>(this, action_id));
}

void OpenExtensionsToolbar::HideActivePopup() {
  if (!popup_) {
    return;
  }
  auto popup = std::move(popup_);
  const std::string id = popup->action_id();
  popup->NotifyClosing();
  popup.reset();
  ScheduleUpdated(id);
}

bool OpenExtensionsToolbar::CanShowToolbarActionPopupForAPICall(
    const ToolbarActionsModel::ActionId& action_id) {
  return Action(action_id) != nullptr;
}

void OpenExtensionsToolbar::OnActionsInitialized() {
  for (const auto& id : model_->GetAllActionIds()) {
    ObserveIcon(id);
  }
  ScheduleListChanged();
}

void OpenExtensionsToolbar::OnActionAdded(
    const ToolbarActionsModel::ActionId& action_id) {
  ObserveIcon(action_id);
  ScheduleListChanged();
}

void OpenExtensionsToolbar::OnActionRemoved(
    const ToolbarActionsModel::ActionId& action_id) {
  icon_subscriptions_.erase(action_id);
  if (menu_action_ == action_id) {
    menu_ = nullptr;
  }
  if (IsShowingPopup(action_id)) {
    HideActivePopup();
  }
  ScheduleListChanged();
}

void OpenExtensionsToolbar::OnActionUpdated(
    const ToolbarActionsModel::ActionId& action_id) {
  ScheduleUpdated(action_id);
}

void OpenExtensionsToolbar::OnPinnedActionsChanged() {
  ScheduleListChanged();
}

void OpenExtensionsToolbar::OnActiveWebContentsChanged(
    bool is_same_document,
    content::WebContents* web_contents) {
  // Every action's state is per tab.
  for (const auto& id : model_->GetAllActionIds()) {
    ScheduleUpdated(id);
  }
}

void OpenExtensionsToolbar::ObserveIcon(const std::string& id) {
  ToolbarActionViewModel* action = Action(id);
  if (!action) {
    return;
  }
  icon_subscriptions_.insert_or_assign(
      id, action->RegisterIconUpdateObserver(
              base::BindRepeating(&OpenExtensionsToolbar::ScheduleUpdated,
                                  base::Unretained(this), id)));
}

void OpenExtensionsToolbar::ScheduleListChanged() {
  list_changed_ = true;
  if (!flush_scheduled_) {
    flush_scheduled_ = true;
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE, base::BindOnce(&OpenExtensionsToolbar::Flush,
                                  weak_ptr_factory_.GetWeakPtr()));
  }
}

void OpenExtensionsToolbar::ScheduleUpdated(const std::string& id) {
  updated_.insert(id);
  if (!flush_scheduled_) {
    flush_scheduled_ = true;
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE, base::BindOnce(&OpenExtensionsToolbar::Flush,
                                  weak_ptr_factory_.GetWeakPtr()));
  }
}

void OpenExtensionsToolbar::Flush() {
  flush_scheduled_ = false;
  const bool list_changed = std::exchange(list_changed_, false);
  const std::set<std::string> updated = std::exchange(updated_, {});
  auto handler = strip_->handler();
  if (!handler || strip_->closing()) {
    return;
  }
  CefRefPtr<CefTabStrip> self(strip_.get());
  if (list_changed) {
    handler->OnExtensionActionsChanged(self);
  }
  for (const auto& id : updated) {
    handler->OnExtensionActionUpdated(self, id);
  }
}

}  // namespace open_engine
