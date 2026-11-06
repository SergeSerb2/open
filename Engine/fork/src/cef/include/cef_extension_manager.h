// Copyright (c) 2026 The Open Authors. All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are
// met:
//
//    * Redistributions of source code must retain the above copyright
// notice, this list of conditions and the following disclaimer.
//    * Redistributions in binary form must reproduce the above
// copyright notice, this list of conditions and the following disclaimer
// in the documentation and/or other materials provided with the
// distribution.
//    * Neither the name of Google Inc. nor the name Chromium Embedded
// Framework nor the names of its contributors may be used to endorse
// or promote products derived from this software without specific prior
// written permission.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
// "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
// LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
// A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
// OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
// SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
// LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
// DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
// THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
//
//
// Open per-profile extensions API. C API and wrappers are translator-generated.
#ifndef CEF_INCLUDE_CEF_EXTENSION_MANAGER_H_
#define CEF_INCLUDE_CEF_EXTENSION_MANAGER_H_
#pragma once
#include "include/cef_api_hash.h"
#include "include/cef_base.h"
#include "include/cef_browser.h"
#include "include/cef_image.h"
#include "include/cef_request_context.h"
#include "include/cef_values.h"
#if CEF_API_ADDED(CEF_EXPERIMENTAL)
///
/// A consent request. UI-thread only. Answer once; releasing it cancels.
///
/*--cef(source=library,added=experimental)--*/
class CefExtensionPrompt : public virtual CefBaseRefCounted {
 public:
  ///
  /// Immutable prompt data (type, id, name, title, acceptLabel, cancelLabel,
  /// permissions with message/details, retainedFiles, retainedDevices,
  /// triggeringExtensionName). Type uses InstallPromptData values; 100 is remove.
  ///
  /*--cef()--*/
  virtual CefRefPtr<CefDictionaryValue> GetData() = 0;
  ///
  /// The Chromium prompt icon, or null.
  ///
  /*--cef()--*/
  virtual CefRefPtr<CefImage> GetIcon() = 0;
  ///
  /// The requesting page, or null for background requests.
  ///
  /*--cef()--*/
  virtual CefRefPtr<CefBrowser> GetBrowser() = 0;
  ///
  /// Completes once. The continuation runs on a later UI turn.
  ///
  /*--cef()--*/
  virtual void Answer(bool accept) = 0;
};
///
/// Profile events, delivered on the UI thread outside model notifications.
///
/*--cef(source=client,added=experimental)--*/
class CefExtensionManagerHandler : public virtual CefBaseRefCounted {
 public:
  ///
  /// The registry or command list changed.
  ///
  /*--cef()--*/
  virtual void OnChanged(bool commands) {}
  ///
  /// The extension system is ready.
  ///
  /*--cef()--*/
  virtual void OnReady() {}
  ///
  /// An extension was installed. Startup loads do not generate this event.
  ///
  /*--cef()--*/
  virtual void OnInstalled(CefRefPtr<CefDictionaryValue> extension, bool by_user) {}
  ///
  /// An unpacked extension failed to load.
  ///
  /*--cef()--*/
  virtual void OnLoadFailed(const CefString& path, const CefString& error) {}
  ///
  /// False preserves Chrome's current dialogs. Queried before interception.
  ///
  /*--cef()--*/
  virtual bool CanShowPrompt() { return false; }
  ///
  /// Keep the prompt until answered, or release it to cancel.
  ///
  /*--cef()--*/
  virtual void OnPrompt(CefRefPtr<CefExtensionPrompt> prompt) {}
};
///
/// Completion of a Web Store install, on the UI thread, exactly once.
///
/*--cef(source=client,added=experimental)--*/
class CefExtensionInstallCallback : public virtual CefBaseRefCounted {
 public:
  ///
  /// The result; error is empty on success.
  ///
  /*--cef(optional_param=error)--*/
  virtual void OnComplete(bool installed, const CefString& error) = 0;
};
///
/// One profile's live extension registry. All methods are UI-thread only.
///
/*--cef(source=library,added=experimental)--*/
class CefExtensionManager : public virtual CefBaseRefCounted {
 public:
  ///
  /// Creates the manager, including for a context not yet initialized.
  ///
  /*--cef()--*/
  static CefRefPtr<CefExtensionManager> Create(
      CefRefPtr<CefRequestContext> context,
      CefRefPtr<CefExtensionManagerHandler> handler);
  ///
  /// Releases handlers and observers before the profile is released.
  ///
  /*--cef()--*/
  virtual void Close() = 0;
  ///
  /// True after ExtensionSystem::ready().
  ///
  /*--cef()--*/
  virtual bool IsReady() = 0;
  ///
  /// Live non-component extensions, including disabled ones, with metadata.
  ///
  /*--cef()--*/
  virtual CefRefPtr<CefListValue> GetInstalled() = 0;
  ///
  /// Active commands with Cocoa key equivalents and modifier flags.
  ///
  /*--cef()--*/
  virtual CefRefPtr<CefListValue> GetCommands() = 0;
  ///
  /// Enables (with consent after a permissions increase), disables or reloads.
  ///
  /*--cef()--*/
  virtual void SetEnabled(const CefString& id, bool enabled) = 0;
  ///
  /// Reloads the extension.
  ///
  /*--cef()--*/
  virtual void Reload(const CefString& id) = 0;
  ///
  /// Shows the uninstall prompt. Native window may be null.
  ///
  /*--cef()--*/
  virtual void Uninstall(const CefString& id, CefWindowHandle window) = 0;
  ///
  /// Installs from the Web Store with its normal consent prompt.
  ///
  /*--cef()--*/
  virtual void InstallFromWebStore(const CefString& id, CefWindowHandle window,
      CefRefPtr<CefExtensionInstallCallback> callback) = 0;
  ///
  /// Dispatches a named active command using this profile's active page.
  /// Action commands are run through CefTabStrip by the embedder.
  ///
  /*--cef()--*/
  virtual bool ExecuteCommand(const CefString& id, const CefString& name,
      CefRefPtr<CefBrowser> active_browser) = 0;
  ///
  /// Automation only (--open-automation): installs a local CRX3 through the
  /// real CrxInstaller and its consent path. Never a silent install.
  ///
  /*--cef()--*/
  virtual bool InstallLocalCrx(const CefString& path,
      CefRefPtr<CefBrowser> browser) = 0;
};
#endif
#endif
