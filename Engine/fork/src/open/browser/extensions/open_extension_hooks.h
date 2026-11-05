// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license in LICENSE.
#ifndef OPEN_BROWSER_EXTENSIONS_OPEN_EXTENSION_HOOKS_H_
#define OPEN_BROWSER_EXTENSIONS_OPEN_EXTENSION_HOOKS_H_
#include "chrome/browser/extensions/extension_install_prompt.h"
#include "chrome/browser/extensions/extension_install_prompt_show_params.h"
#include "chrome/browser/extensions/extension_uninstall_dialog.h"
namespace download { class DownloadItem; }
namespace open_engine {
// Chromium targets cannot depend on libcef. The overlay registers these
// pointers; a null hook, or an unhandled request, preserves the platform UI.
struct ExtensionHooks {
  bool (*show_install)(std::unique_ptr<ExtensionInstallPromptShowParams>&,
      ExtensionInstallPrompt::DoneCallback&,
      std::unique_ptr<extensions::InstallPromptData>&) = nullptr;
  std::unique_ptr<extensions::ExtensionUninstallDialog> (*create_uninstall)(
      Profile*, gfx::NativeWindow,
      extensions::ExtensionUninstallDialog::Delegate*) = nullptr;
  // A managed install owns its dummy requestor until completion. CEF must
  // allow only that install's internal download without a CefBrowser.
  bool (*allow_download_without_browser)(download::DownloadItem*) = nullptr;
};
inline ExtensionHooks& GetExtensionHooks() {
  static ExtensionHooks hooks;
  return hooks;
}
}  // namespace open_engine
#endif
