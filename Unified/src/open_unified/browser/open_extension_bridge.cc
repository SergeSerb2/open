// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "open_unified/browser/open_extension_bridge.h"

#include <algorithm>
#include <utility>

#include "base/functional/bind.h"
#include "base/strings/utf_string_conversions.h"
#include "chrome/browser/extensions/extension_action_runner.h"
#include "chrome/browser/extensions/extension_view_host.h"
#include "chrome/browser/extensions/extension_view_host_factory.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/extensions/extension_popup_types.h"
#include "chrome/browser/ui/views/extensions/extension_popup.h"
#include "chrome/browser/ui/views/frame/browser_view.h"
#include "chrome/browser/ui/views/frame/top_container_view.h"
#include "components/sessions/content/session_tab_helper.h"
#include "content/public/browser/web_contents.h"
#include "extensions/browser/disable_reason.h"
#include "extensions/browser/extension_action.h"
#include "extensions/browser/extension_action_manager.h"
#include "extensions/browser/extension_registrar.h"
#include "extensions/common/extension.h"
#include "extensions/common/manifest_handlers/description_info.h"
#include "extensions/common/permissions/permissions_data.h"
#include "open_unified/browser/open_browser_service.h"
#include "open_unified/browser/open_tab_bridge.h"
#include "ui/views/bubble/bubble_anchor.h"
#include "ui/views/bubble/bubble_border.h"
#include "ui/views/view.h"

namespace open_unified {

namespace {

int ActiveTabSessionId(OpenBrowserService* service) {
  OpenTabBridge* bridge = service->tab_bridge();
  content::WebContents* contents =
      bridge ? bridge->ActiveWebContents() : nullptr;
  return contents ? sessions::SessionTabHelper::IdForTab(contents).id() : -1;
}

}  // namespace

OpenExtensionBridge::OpenExtensionBridge(OpenBrowserService* service,
                                         ::Profile* profile)
    : service_(service),
      profile_(profile),
      toolbar_model_(ToolbarActionsModel::Get(profile)) {
  if (toolbar_model_) {
    toolbar_observation_.Observe(toolbar_model_.get());
  }
  registry_observation_.Observe(extensions::ExtensionRegistry::Get(profile));
}

OpenExtensionBridge::~OpenExtensionBridge() = default;

void OpenExtensionBridge::AddObserver(Observer* observer) {
  observers_.AddObserver(observer);
}

void OpenExtensionBridge::RemoveObserver(Observer* observer) {
  observers_.RemoveObserver(observer);
}

ExtensionActionInfo OpenExtensionBridge::InfoFor(
    const extensions::Extension& extension) const {
  ExtensionActionInfo info;
  info.id = extension.id();
  info.name = extension.name();
  info.version = extension.VersionString();
  info.description = extensions::DescriptionInfo::GetDescription(extension);
  info.enabled = extensions::ExtensionRegistry::Get(profile_)
                     ->enabled_extensions()
                     .Contains(extension.id());
  if (toolbar_model_) {
    info.pinned = toolbar_model_->IsActionPinned(extension.id());
    info.force_pinned = toolbar_model_->IsActionForcePinned(extension.id());
  }
  for (const auto& permission :
       extension.permissions_data()->active_permissions().GetAPIsAsStrings()) {
    info.permissions.push_back(permission);
  }
  std::sort(info.permissions.begin(), info.permissions.end());

  const int tab_id = ActiveTabSessionId(service_);
  if (extensions::ExtensionAction* action =
          extensions::ExtensionActionManager::Get(profile_)
              ->GetExtensionAction(extension)) {
    info.title = action->GetTitle(tab_id);
    info.badge_text = action->GetDisplayBadgeText(tab_id);
    info.has_popup = action->HasPopup(tab_id);
    info.visible = action->GetIsVisible(tab_id);
  }
  if (info.title.empty()) {
    info.title = info.name;
  }
  return info;
}

std::vector<ExtensionActionInfo> OpenExtensionBridge::ListActions() const {
  std::vector<ExtensionActionInfo> result;
  if (!toolbar_model_) {
    return result;
  }
  auto* registry = extensions::ExtensionRegistry::Get(profile_);
  // Pinned actions in the user's order, then the rest by name (Arc's grid).
  std::vector<std::string> seen;
  for (const auto& id : toolbar_model_->pinned_action_ids()) {
    if (const extensions::Extension* extension =
            registry->enabled_extensions().GetByID(id)) {
      result.push_back(InfoFor(*extension));
      seen.push_back(id);
    }
  }
  std::vector<ExtensionActionInfo> rest;
  for (const auto& id : toolbar_model_->action_ids()) {
    if (std::find(seen.begin(), seen.end(), id) != seen.end()) {
      continue;
    }
    if (const extensions::Extension* extension =
            registry->enabled_extensions().GetByID(id)) {
      rest.push_back(InfoFor(*extension));
    }
  }
  std::sort(rest.begin(), rest.end(),
            [](const ExtensionActionInfo& a, const ExtensionActionInfo& b) {
              return a.name < b.name;
            });
  result.insert(result.end(), rest.begin(), rest.end());
  return result;
}

std::vector<ExtensionActionInfo> OpenExtensionBridge::ListInstalled() const {
  std::vector<ExtensionActionInfo> result;
  const extensions::ExtensionSet installed =
      extensions::ExtensionRegistry::Get(profile_)
          ->GenerateInstalledExtensionsSet();
  for (const auto& extension : installed) {
    // Component and theme extensions are not user-manageable.
    if (extension->location() ==
            extensions::mojom::ManifestLocation::kComponent ||
        extension->location() ==
            extensions::mojom::ManifestLocation::kExternalComponent ||
        extension->is_theme()) {
      continue;
    }
    result.push_back(InfoFor(*extension));
  }
  std::sort(result.begin(), result.end(),
            [](const ExtensionActionInfo& a, const ExtensionActionInfo& b) {
              return a.name < b.name;
            });
  return result;
}

void OpenExtensionBridge::ExecuteAction(
    const std::string& extension_id,
    views::View* anchor,
    base::OnceCallback<void(bool shown)> done) {
  const extensions::Extension* extension =
      extensions::ExtensionRegistry::Get(profile_)
          ->enabled_extensions()
          .GetByID(extension_id);
  OpenTabBridge* bridge = service_->tab_bridge();
  BrowserWindowInterface* browser = bridge ? bridge->MainBrowser() : nullptr;
  content::WebContents* contents =
      bridge ? bridge->ActiveWebContents() : nullptr;
  if (!extension || !browser || !contents ||
      browser->GetProfile()->GetOriginalProfile() != profile_.get()) {
    std::move(done).Run(false);
    return;
  }
  auto* runner = extensions::ExtensionActionRunner::GetForWebContents(contents);
  if (!runner) {
    std::move(done).Run(false);
    return;
  }
  // Grants activeTab like a real click, runs chrome.action.onClicked when
  // there is no popup, and tells us to show one when there is.
  const extensions::ExtensionAction::ShowAction show =
      runner->RunAction(extension, /*grant_tab_permissions=*/true);
  if (show != extensions::ExtensionAction::ShowAction::kShowPopup) {
    std::move(done).Run(true);
    return;
  }
  extensions::ExtensionAction* action =
      extensions::ExtensionActionManager::Get(profile_)->GetExtensionAction(
          *extension);
  const GURL popup_url =
      action ? action->GetPopupUrl(ActiveTabSessionId(service_)) : GURL();
  if (!popup_url.is_valid()) {
    std::move(done).Run(false);
    return;
  }
  std::unique_ptr<extensions::ExtensionViewHost> host =
      extensions::ExtensionViewHostFactory::CreatePopupHost(*extension,
                                                            popup_url, browser);
  if (!anchor) {
    BrowserView* browser_view =
        BrowserView::GetBrowserViewForBrowser(browser);
    anchor = browser_view ? browser_view->top_container() : nullptr;
  }
  if (!host || !anchor) {
    std::move(done).Run(false);
    return;
  }
  ExtensionPopup::ShowPopup(
      browser, std::move(host), views::BubbleAnchor(anchor),
      views::BubbleBorder::TOP_RIGHT, PopupShowAction::kShow,
      base::BindOnce(
          [](base::OnceCallback<void(bool)> done,
             extensions::ExtensionHost* popup_host) {
            std::move(done).Run(popup_host != nullptr);
          },
          std::move(done)));
}

bool OpenExtensionBridge::SetPinned(const std::string& extension_id,
                                    bool pinned) {
  if (!toolbar_model_ || !toolbar_model_->HasAction(extension_id) ||
      toolbar_model_->IsActionForcePinned(extension_id)) {
    return false;
  }
  toolbar_model_->SetActionVisibility(extension_id, pinned);
  return true;
}

bool OpenExtensionBridge::SetEnabled(const std::string& extension_id,
                                     bool enabled) {
  auto* registry = extensions::ExtensionRegistry::Get(profile_);
  if (!registry->GetInstalledExtension(extension_id)) {
    return false;
  }
  auto* registrar = extensions::ExtensionRegistrar::Get(profile_);
  if (enabled) {
    registrar->EnableExtension(extension_id);
  } else {
    registrar->DisableExtension(
        extension_id, {extensions::disable_reason::DISABLE_USER_ACTION});
  }
  return true;
}

// static
base::DictValue OpenExtensionBridge::ToValue(
    const ExtensionActionInfo& info) {
  base::ListValue permissions;
  for (const auto& permission : info.permissions) {
    permissions.Append(permission);
  }
  return base::DictValue()
      .Set("id", info.id)
      .Set("name", info.name)
      .Set("version", info.version)
      .Set("description", info.description)
      .Set("title", info.title)
      .Set("badge_text", info.badge_text)
      .Set("enabled", info.enabled)
      .Set("pinned", info.pinned)
      .Set("force_pinned", info.force_pinned)
      .Set("has_popup", info.has_popup)
      .Set("visible", info.visible)
      .Set("permissions", std::move(permissions));
}

void OpenExtensionBridge::NotifyChanged() {
  for (Observer& observer : observers_) {
    observer.OnExtensionActionsChanged();
  }
}

void OpenExtensionBridge::OnToolbarActionAdded(
    const ToolbarActionsModel::ActionId& id) {
  NotifyChanged();
}

void OpenExtensionBridge::OnToolbarActionRemoved(
    const ToolbarActionsModel::ActionId& id) {
  NotifyChanged();
}

void OpenExtensionBridge::OnToolbarActionUpdated(
    const ToolbarActionsModel::ActionId& id) {
  NotifyChanged();
}

void OpenExtensionBridge::OnToolbarModelInitialized() {
  NotifyChanged();
}

void OpenExtensionBridge::OnToolbarPinnedActionsChanged() {
  NotifyChanged();
}

void OpenExtensionBridge::OnToolbarActionsModelShutdown() {
  toolbar_observation_.Reset();
  toolbar_model_ = nullptr;
}

void OpenExtensionBridge::OnExtensionLoaded(
    content::BrowserContext* browser_context,
    const extensions::Extension* extension) {
  NotifyChanged();
}

void OpenExtensionBridge::OnExtensionUnloaded(
    content::BrowserContext* browser_context,
    const extensions::Extension* extension,
    extensions::UnloadedExtensionReason reason) {
  NotifyChanged();
}

}  // namespace open_unified
