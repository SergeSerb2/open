// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef OPEN_BROWSER_EXTENSIONS_OPEN_ALLOY_EXTENSION_MENU_H_
#define OPEN_BROWSER_EXTENSIONS_OPEN_ALLOY_EXTENSION_MENU_H_

#include "cef/include/cef_menu_model.h"

namespace content {
struct ContextMenuParams;
class WebContents;
}  // namespace content

namespace open_engine {

// Extension chrome.contextMenus items for Alloy-style pages (Open's Peek and
// Alloy popups; parity audit A12). Chrome-style pages get them from Chrome's
// RenderViewContextMenu; CEF's Alloy menu (CefMenuManager) has none.
//
// Appends the items that match |params| to |model|, after a separator, with
// Chrome's own matcher, order, titles, submenus and command ids
// (IDC_EXTENSIONS_CONTEXT_CUSTOM_FIRST…). The state lives on |web_contents|
// until the next call. Called by CefMenuManager::CreateContextMenu (CEF patch
// 0306) before the client sees the model.
void AppendAlloyExtensionMenuItems(content::WebContents* web_contents,
                                   const content::ContextMenuParams& params,
                                   CefRefPtr<CefMenuModel> model);

// Runs |command_id| if it is one of the items appended for |web_contents|'
// current menu: contextMenus.onClicked fires with the click's page, frame,
// link and selection data (no tab: the page is outside chrome.tabs). Returns
// false for any other command. Called by CefMenuManager::ExecuteCommand.
bool ExecuteAlloyExtensionMenuCommand(content::WebContents* web_contents,
                                      int command_id);

}  // namespace open_engine

#endif  // OPEN_BROWSER_EXTENSIONS_OPEN_ALLOY_EXTENSION_MENU_H_
