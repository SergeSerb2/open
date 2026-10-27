#pragma once

#include "include/cef_menu_model.h"

// The Chromium items a Chrome style page's context menu may keep in Open
// (docs/engine-api.md, "Context menu items"). Removes every other item,
// including items a later Chromium adds, then empty submenus and extra
// separators. Alloy style menus use CEF's own ids: do not pass them here.
void OEFilterChromeContextMenu(CefRefPtr<CefMenuModel> model);
