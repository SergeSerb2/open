// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "open/browser/extensions/open_alloy_extension_menu.h"

#include <memory>

#include "base/functional/bind.h"
#include "base/supports_user_data.h"
#include "chrome/browser/extensions/context_menu_helpers.h"
#include "chrome/browser/extensions/context_menu_matcher.h"
#include "content/public/browser/context_menu_params.h"
#include "content/public/browser/global_routing_id.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/web_contents.h"
#include "ui/base/models/menu_model.h"
#include "ui/menus/simple_menu_model.h"

namespace open_engine {

namespace {

const char kAlloyExtensionMenuKey[] = "open_engine.alloy_extension_menu";

// ContextMenuParams does not name its frame, and CEF's Alloy path drops the
// one Chromium passed. A right click focuses its frame first.
content::RenderFrameHost* ClickedFrame(content::WebContents* web_contents) {
  content::RenderFrameHost* focused = web_contents->GetFocusedFrame();
  return focused ? focused : web_contents->GetPrimaryMainFrame();
}

// One context menu's extension items: Chrome's matcher over a private
// SimpleMenuModel, which is then copied into CEF's model.
class AlloyExtensionMenu : public base::SupportsUserData::Data,
                           public ui::SimpleMenuModel::Delegate {
 public:
  AlloyExtensionMenu(content::WebContents* web_contents,
                     const content::ContextMenuParams& params)
      : params_(params),
        frame_(ClickedFrame(web_contents)->GetGlobalId()),
        model_(this),
        matcher_(web_contents->GetBrowserContext(),
                 this,
                 &model_,
                 base::BindRepeating(
                     extensions::context_menu_helpers::MenuItemMatchesParams,
                     params)) {
    extensions::context_menu_helpers::PopulateExtensionItems(
        web_contents->GetBrowserContext(), params_, matcher_);
  }

  // Copies the visible items of |source| to |target|.
  void CopyTo(ui::MenuModel* source, CefRefPtr<CefMenuModel> target) {
    for (size_t i = 0; i < source->GetItemCount(); ++i) {
      const int id = source->GetCommandIdAt(i);
      const ui::MenuModel::ItemType type = source->GetTypeAt(i);
      if (type == ui::MenuModel::TYPE_SEPARATOR) {
        target->AddSeparator();
        continue;
      }
      if (!source->IsVisibleAt(i)) {
        continue;
      }
      const CefString label(source->GetLabelAt(i));
      switch (type) {
        case ui::MenuModel::TYPE_CHECK:
          target->AddCheckItem(id, label);
          target->SetChecked(id, source->IsItemCheckedAt(i));
          break;
        case ui::MenuModel::TYPE_RADIO:
          target->AddRadioItem(id, label, source->GetGroupIdAt(i));
          target->SetChecked(id, source->IsItemCheckedAt(i));
          break;
        case ui::MenuModel::TYPE_SUBMENU: {
          CefRefPtr<CefMenuModel> submenu = target->AddSubMenu(id, label);
          if (submenu && source->GetSubmenuModelAt(i)) {
            CopyTo(source->GetSubmenuModelAt(i), submenu);
          }
          break;
        }
        default:
          target->AddItem(id, label);
          break;
      }
      target->SetEnabled(id, source->IsEnabledAt(i));
    }
  }

  ui::SimpleMenuModel* model() { return &model_; }
  bool HasVisibleItems() { return matcher_.HasVisibleItems(&model_); }

  bool Execute(content::WebContents* web_contents, int command_id) {
    if (!extensions::ContextMenuMatcher::IsExtensionsCustomCommandId(
            command_id) ||
        !matcher_.extension_item_map().contains(command_id) ||
        !matcher_.IsCommandIdEnabled(command_id)) {
      return false;
    }
    // The frame of the click, if it is still there; else the main frame.
    content::RenderFrameHost* frame = content::RenderFrameHost::FromID(frame_);
    if (!frame || content::WebContents::FromRenderFrameHost(frame) !=
                      web_contents) {
      frame = web_contents->GetPrimaryMainFrame();
    }
    matcher_.ExecuteCommand(command_id, web_contents, frame, params_);
    return true;
  }

  // ui::SimpleMenuModel::Delegate:
  bool IsCommandIdChecked(int command_id) const override {
    return matcher_.IsCommandIdChecked(command_id);
  }
  bool IsCommandIdEnabled(int command_id) const override {
    return matcher_.IsCommandIdEnabled(command_id);
  }
  bool IsCommandIdVisible(int command_id) const override {
    return matcher_.IsCommandIdVisible(command_id);
  }
  // Commands run through ExecuteAlloyExtensionMenuCommand, never the model.
  void ExecuteCommand(int command_id, int event_flags) override {}

 private:
  const content::ContextMenuParams params_;
  const content::GlobalRenderFrameHostId frame_;
  ui::SimpleMenuModel model_;
  extensions::ContextMenuMatcher matcher_;
};

}  // namespace

void AppendAlloyExtensionMenuItems(content::WebContents* web_contents,
                                   const content::ContextMenuParams& params,
                                   CefRefPtr<CefMenuModel> model) {
  if (!web_contents || !model) {
    return;
  }
  // Replaces (and so ends) the previous menu's state.
  auto menu = std::make_unique<AlloyExtensionMenu>(web_contents, params);
  AlloyExtensionMenu* raw = menu.get();
  web_contents->SetUserData(kAlloyExtensionMenuKey, std::move(menu));
  if (!raw->HasVisibleItems()) {
    return;
  }
  if (model->GetCount() > 0) {
    model->AddSeparator();
  }
  raw->CopyTo(raw->model(), model);
}

bool ExecuteAlloyExtensionMenuCommand(content::WebContents* web_contents,
                                      int command_id) {
  auto* menu = web_contents
                   ? static_cast<AlloyExtensionMenu*>(
                         web_contents->GetUserData(kAlloyExtensionMenuKey))
                   : nullptr;
  return menu && menu->Execute(web_contents, command_id);
}

}  // namespace open_engine
