#import "OEClient.h"

#include "include/cef_open_page.h"
#include "include/cef_parser.h"
#include "OEContextMenuAllowlist.h"

namespace {

OEOpenDisposition OEMapDisposition(cef_window_open_disposition_t d) {
  switch (d) {
    case CEF_WOD_NEW_FOREGROUND_TAB:
      return OEOpenDispositionNewForegroundTab;
    case CEF_WOD_NEW_BACKGROUND_TAB:
      return OEOpenDispositionNewBackgroundTab;
    case CEF_WOD_NEW_POPUP:
      return OEOpenDispositionNewPopup;
    case CEF_WOD_NEW_WINDOW:
      return OEOpenDispositionNewWindow;
    case CEF_WOD_OFF_THE_RECORD:
      return OEOpenDispositionOffTheRecord;
    case CEF_WOD_SAVE_TO_DISK:
      return OEOpenDispositionSaveToDisk;
    case CEF_WOD_NEW_PICTURE_IN_PICTURE:
      return OEOpenDispositionNewPictureInPicture;
    default:
      return OEOpenDispositionCurrentTab;
  }
}

// CEF's user-gesture navigation IPC can arrive after NSApp.currentEvent changed.
// OEApplication keeps the originating pointer flags until the next input event.
NSEventModifierFlags OENavigationModifiers(OEWebContent* page) {
  return OENavigationModifiersForWindow(page.view.window);
}

bool OECancelNavigation(OEWebContent* page, NSURL* url,
                        bool gesture, NSEventModifierFlags modifiers) {
  id<OEWebContentDelegate> delegate = page.delegate;
  return page && url && gesture &&
      [delegate respondsToSelector:@selector(webContent:shouldNavigateToURL:
                                                userGesture:modifiers:)] &&
      ![delegate webContent:page shouldNavigateToURL:url
                    userGesture:gesture modifiers:modifiers];
}

}  // namespace

CefRefPtr<OEClient> OECreateClient(OEWebContent* webContent) {
  return new OEClient(webContent);
}

bool OEClient::OnProcessMessageReceived(CefRefPtr<CefBrowser> browser,
    CefRefPtr<CefFrame> frame, CefProcessId source,
    CefRefPtr<CefProcessMessage> message) {
  auto name = message->GetName();
  if (source != PID_RENDERER || !frame->IsMain() ||
      (name != "oe.open.message" && name != "oe.open.reply")) return false;
  [view_ oe_openWorldMessage:message];
  return true;
}

#pragma mark Life span

bool OEClient::OnBeforePopup(CefRefPtr<CefBrowser> browser,
                             CefRefPtr<CefFrame> frame,
                             int popup_id,
                             const CefString& target_url,
                             const CefString& target_frame_name,
                             WindowOpenDisposition target_disposition,
                             bool user_gesture,
                             const CefPopupFeatures& features,
                             CefWindowInfo& windowInfo,
                             CefRefPtr<CefClient>& client,
                             CefBrowserSettings& settings,
                             CefRefPtr<CefDictionaryValue>& extra_info,
                             bool* no_javascript_access) {
  OEWebContent* source = view_;
  NSEventModifierFlags modifiers = OENavigationModifiers(source);
  if ((modifiers & (NSEventModifierFlagCommand | NSEventModifierFlagOption)) ==
          (NSEventModifierFlagCommand | NSEventModifierFlagOption) &&
      OECancelNavigation(source, OEURL(target_url), user_gesture, modifiers)) {
    return true;
  }
  if (target_disposition == CEF_WOD_NEW_WINDOW &&
      OECancelNavigation(source, OEURL(target_url), user_gesture,
                         NSEventModifierFlagShift)) {
    return true;
  }
  id<OEWebContentDelegate> delegate = source.delegate;
  // Document PiP of a Chrome-style page: CEF uses Chromium's default creation,
  // where the fork's EM-7 hook (chromium/0403) shows it through the shell's
  // pictureInPictureDelegate, or Chromium's own window without one.
  if (source && target_disposition == CEF_WOD_NEW_PICTURE_IN_PICTURE &&
      source.runtimeStyle == OERuntimeStyleChrome) {
    return false;
  }
  if (!source ||
      ![delegate respondsToSelector:@selector(webContent:
                                        createWebContentForOpenRequest:)]) {
    return false;  // Chromium's default popup window.
  }
  NSRect frameRect = NSZeroRect;
  if (features.widthSet || features.heightSet) {
    frameRect = NSMakeRect(features.xSet ? features.x : 0,
                           features.ySet ? features.y : 0,
                           features.widthSet ? features.width : 0,
                           features.heightSet ? features.height : 0);
  }
  OEOpenRequest* request =
      [[OEOpenRequest alloc] initOEWithURL:OEURL(target_url)
                                disposition:OEMapDisposition(target_disposition)
                                userGesture:user_gesture
                             requestedFrame:frameRect
                            targetFrameName:OEString(target_frame_name)
                                     source:source
                                    context:source.context];
  OEWebContent* target = [delegate webContent:source
                createWebContentForOpenRequest:request];
  if (!target) {
    return true;  // Blocked by the shell.
  }
  if (![target oe_adoptPopupWithWindowInfo:windowInfo
                                    client:client
                                  settings:settings
                                 extraInfo:extra_info
                                    opener:source]) {
    return true;
  }
  return false;
}

namespace {

// True unless |browser| is a browser other than the page's own (a stray
// callback must not create, retitle, or close the page).
bool OEIsPageBrowser(OEWebContent* view, CefRefPtr<CefBrowser> browser) {
  CefRefPtr<CefBrowser> own = view.oe_browser;
  return !own || own->IsSame(browser);
}

}  // namespace

void OEClient::OnBeforeDevToolsPopup(CefRefPtr<CefBrowser> browser,
                                     CefWindowInfo& windowInfo,
                                     CefRefPtr<CefClient>& client,
                                     CefBrowserSettings& settings,
                                     CefRefPtr<CefDictionaryValue>& extra_info,
                                     bool* use_default_window) {
  // With the page's own client the DevTools page's creation, title, and close
  // would reach the inspected page: closing DevTools closed the tab.
  // |browser| is the inspected page: with a hosted tab, Chrome's command
  // targets the hidden strip's active tab, which CEF maps to its browser.
  OEWebContent* inspected = view_;
  if (!OEIsPageBrowser(inspected, browser)) {
    inspected = [[OEEngine shared] webContentWithIdentifier:browser->GetIdentifier()];
  }
  client = new OEDevToolsClient(inspected);
}

#pragma mark DevTools window

void OEDevToolsClient::OnAfterCreated(CefRefPtr<CefBrowser> browser) {
  browser_ = browser;
  [inspected_ oe_setDevToolsFrontend:this];
}

void OEDevToolsClient::OnBeforeClose(CefRefPtr<CefBrowser> browser) {
  // CEF requires dropping every browser reference here.
  FailPending();
  registration_ = nullptr;
  browser_ = nullptr;
  [inspected_ oe_devToolsFrontendClosed:this];
}

void OEDevToolsClient::FailPending() {
  NSDictionary<NSNumber*, void (^)(id, NSError*)>* pending = [pending_ copy];
  [pending_ removeAllObjects];
  for (void (^done)(id, NSError*) in pending.allValues) {
    done(nil, [NSError errorWithDomain:OEErrorDomain
                                  code:OEErrorWebContentClosed
                              userInfo:nil]);
  }
}

void OEDevToolsClient::Evaluate(NSString* script,
                                void (^completion)(id, NSError*)) {
  void (^done)(id, NSError*) = [completion copy];
  if (!browser_) {
    done(nil, [NSError errorWithDomain:OEErrorDomain
                                  code:OEErrorWebContentClosed
                              userInfo:@{
                                NSLocalizedDescriptionKey : @"No DevTools window"
                              }]);
    return;
  }
  CefRefPtr<CefBrowserHost> host = browser_->GetHost();
  if (!registration_) {
    registration_ = host->AddDevToolsMessageObserver(this);
  }
  CefRefPtr<CefDictionaryValue> params = CefDictionaryValue::Create();
  params->SetString("expression", OECef(script));
  params->SetBool("returnByValue", true);
  params->SetBool("awaitPromise", true);
  int messageId = host->ExecuteDevToolsMethod(0, "Runtime.evaluate", params);
  if (messageId == 0) {
    done(nil, [NSError errorWithDomain:OEErrorDomain
                                  code:OEErrorDevToolsFailure
                              userInfo:nil]);
    return;
  }
  pending_[@(messageId)] = done;
}

void OEDevToolsClient::OnDevToolsMethodResult(CefRefPtr<CefBrowser> browser,
                                              int message_id,
                                              bool success,
                                              const void* result,
                                              size_t result_size) {
  void (^done)(id, NSError*) = pending_[@(message_id)];
  if (!done) {
    return;
  }
  [pending_ removeObjectForKey:@(message_id)];
  id object = [NSJSONSerialization
      JSONObjectWithData:[NSData dataWithBytes:result length:result_size]
                 options:NSJSONReadingFragmentsAllowed
                   error:nil];
  NSDictionary* dict = [object isKindOfClass:NSDictionary.class] ? object : @{};
  NSDictionary* exception = dict[@"exceptionDetails"];
  if (!success || exception) {
    NSString* message = success ? [exception description]
                                : (dict[@"message"] ?: @"Runtime.evaluate failed");
    done(nil, [NSError errorWithDomain:OEErrorDomain
                                  code:OEErrorJavaScriptException
                              userInfo:@{NSLocalizedDescriptionKey : message}]);
    return;
  }
  done(dict[@"result"][@"value"] ?: NSNull.null, nil);
}

void OEClient::OnAfterCreated(CefRefPtr<CefBrowser> browser) {
  OEWebContent* view = view_;
  if (!view) {
    // The page was deallocated while Chromium was still creating its browser
    // (a hosted or Views popup has no creation keep-alive). Nobody owns this
    // browser any more: close it instead of leaving an orphaned tab.
    browser->GetHost()->CloseBrowser(true);
    return;
  }
  if (!OEIsPageBrowser(view, browser)) {
    return;
  }
  [view oe_browserCreated:browser];
}

bool OEClient::DoClose(CefRefPtr<CefBrowser> browser) {
  OEWebContent* view = view_;
  if (!OEIsPageBrowser(view, browser)) {
    return false;
  }
  if (!closing_ && view) {
    // window.close() from the page. Tell the shell; the close continues.
    close_requested_ = true;
    [view oe_requestClose];
  }
  // The browser is a child view inside our window. Returning false would
  // send performClose: to OUR window; instead tear down the browser's view,
  // which destroys the browser and leads to OnBeforeClose.
  NSView* host = (__bridge NSView*)browser->GetHost()->GetWindowHandle();
  dispatch_async(dispatch_get_main_queue(), ^{
    [host removeFromSuperview];
  });
  return true;
}

void OEClient::OnBeforeClose(CefRefPtr<CefBrowser> browser) {
  // Chrome style pages never get DoClose: Chromium closes a hosted tab
  // itself (window.close(), chrome.tabs.remove). Tell the shell first.
  OEWebContent* view = view_;
  if (!OEIsPageBrowser(view, browser)) {
    [[OEEngine shared] oe_browserDidClose];
    return;
  }
  CancelAuthenticationRequests();
  if (!closing_ && !close_requested_ && view.oe_hostBrowser) {
    close_requested_ = true;
    [view oe_requestClose];
  }
  [view_ oe_browserClosed];
  [[OEEngine shared] oe_browserDidClose];
}

#pragma mark Display

void OEClient::OnAddressChange(CefRefPtr<CefBrowser> browser,
                               CefRefPtr<CefFrame> frame,
                               const CefString& url) {
  if (frame->IsMain()) {
    [view_ oe_setURL:OEURL(url)];
  }
}

void OEClient::OnTitleChange(CefRefPtr<CefBrowser> browser,
                             const CefString& title) {
  [view_ oe_setTitle:OEString(title)];
}

void OEClient::OnFaviconURLChange(CefRefPtr<CefBrowser> browser,
                                  const std::vector<CefString>& icon_urls) {
  [view_ oe_setFaviconURL:icon_urls.empty() ? nil : OEURL(icon_urls[0])];
}

void OEClient::OnFullscreenModeChange(CefRefPtr<CefBrowser> browser,
                                      bool fullscreen) {
  [view_ oe_setFullscreen:fullscreen];
}

void OEClient::OnStatusMessage(CefRefPtr<CefBrowser> browser,
                               const CefString& value) {
  [view_ oe_setStatusText:OEString(value)];
}

bool OEClient::OnConsoleMessage(CefRefPtr<CefBrowser> browser,
                                cef_log_severity_t level,
                                const CefString& message,
                                const CefString& source,
                                int line) {
  OEWebContent* view = view_;
  if ([view.delegate respondsToSelector:@selector
                     (webContent:didLogConsoleMessage:level:source:line:)]) {
    [view.delegate webContent:view
        didLogConsoleMessage:OEString(message)
                       level:level
                      source:OEString(source)
                        line:line];
  }
  return false;
}

bool OEClient::OnAutoResize(CefRefPtr<CefBrowser> browser,
                            const CefSize& new_size) {
  OEWebContent* view = view_;
  if (!view) {
    return false;
  }
  [view oe_requestContentSize:NSMakeSize(new_size.width, new_size.height)];
  return true;
}

void OEClient::OnLoadingProgressChange(CefRefPtr<CefBrowser> browser,
                                       double progress) {
  [view_ oe_setProgress:progress];
}

void OEClient::OnMediaAccessChange(CefRefPtr<CefBrowser> browser,
                                   bool has_video_access,
                                   bool has_audio_access) {
  [view_ oe_setMediaCaptureCamera:has_video_access
                       microphone:has_audio_access];
}

#pragma mark Load

void OEClient::OnLoadStart(CefRefPtr<CefBrowser> browser,
                           CefRefPtr<CefFrame> frame,
                           TransitionType transition_type) {
  OEWebContent* view = view_;
  if (frame->IsMain() &&
      [view.delegate respondsToSelector:@selector(webContent:didCommitNavigationToURL:isReload:)]) {
    if (NSURL* url = OEURL(frame->GetURL())) {
      // A traversal can retain the entry's original reload source. Its
      // forward/back qualifier makes this a new visit, not another reload.
      const bool reload = (transition_type & TT_SOURCE_MASK) == TT_RELOAD &&
                          !(transition_type & TT_FORWARD_BACK_FLAG);
      [view.delegate webContent:view didCommitNavigationToURL:url isReload:reload];
    }
  }
}

void OEClient::OnLoadingStateChange(CefRefPtr<CefBrowser> browser,
                                    bool isLoading,
                                    bool canGoBack,
                                    bool canGoForward) {
  [view_ oe_setLoading:isLoading canGoBack:canGoBack canGoForward:canGoForward];
}

void OEClient::OnLoadEnd(CefRefPtr<CefBrowser> browser,
                         CefRefPtr<CefFrame> frame,
                         int httpStatusCode) {
  OEWebContent* view = view_;
  if (frame->IsMain() &&
      [view.delegate respondsToSelector:@selector(webContent:
                                            didFinishLoadWithStatus:)]) {
    [view.delegate webContent:view didFinishLoadWithStatus:httpStatusCode];
  }
}

void OEClient::OnLoadError(CefRefPtr<CefBrowser> browser,
                           CefRefPtr<CefFrame> frame,
                           ErrorCode errorCode,
                           const CefString& errorText,
                           const CefString& failedUrl) {
  OEWebContent* view = view_;
  if (!frame->IsMain() || errorCode == ERR_ABORTED) {
    return;
  }
  if ([view.delegate respondsToSelector:@selector(webContent:
                                            didFailLoadWithError:)]) {
    NSMutableDictionary* info = [NSMutableDictionary
        dictionaryWithObject:OEString(errorText)
                      forKey:NSLocalizedDescriptionKey];
    if (NSURL* failed = OEURL(failedUrl)) {
      info[NSURLErrorFailingURLErrorKey] = failed;
    }
    NSError* error = [NSError errorWithDomain:@"org.chromium.net"
                                         code:errorCode
                                     userInfo:info];
    [view.delegate webContent:view didFailLoadWithError:error];
  }
}

#pragma mark Keyboard

bool OEClient::OnPreKeyEvent(CefRefPtr<CefBrowser> browser,
                             const CefKeyEvent& event,
                             CefEventHandle os_event,
                             bool* is_keyboard_shortcut) {
  OEWebContent* view = view_;
  NSEvent* ns = (__bridge NSEvent*)os_event;
  if (!ns || ns.type != NSEventTypeKeyDown ||
      ![view.delegate respondsToSelector:@selector(webContent:
                                             handleKeyEventBeforePage:)]) {
    return false;
  }
  return [view.delegate webContent:view handleKeyEventBeforePage:ns];
}

bool OEClient::OnKeyEvent(CefRefPtr<CefBrowser> browser,
                          const CefKeyEvent& event,
                          CefEventHandle os_event) {
  OEWebContent* view = view_;
  NSEvent* ns = (__bridge NSEvent*)os_event;
  if (!ns || ns.type != NSEventTypeKeyDown) {
    return false;
  }
  if ([view.delegate respondsToSelector:@selector(webContent:
                                            handleUnconsumedKeyEvent:)] &&
      [view.delegate webContent:view handleUnconsumedKeyEvent:ns]) {
    return true;
  }
  // Give the app menu its key equivalents (CEF does this for Alloy too; for
  // Chrome style the Views window would swallow them otherwise).
  if (browser->GetHost()->GetRuntimeStyle() == CEF_RUNTIME_STYLE_CHROME &&
      (ns.modifierFlags & NSEventModifierFlagCommand)) {
    return [[NSApp mainMenu] performKeyEquivalent:ns];
  }
  return false;
}

#pragma mark JavaScript dialogs

bool OEClient::OnJSDialog(CefRefPtr<CefBrowser> browser,
                          const CefString& origin_url,
                          JSDialogType dialog_type,
                          const CefString& message_text,
                          const CefString& default_prompt_text,
                          CefRefPtr<CefJSDialogCallback> callback,
                          bool& suppress_message) {
  OEWebContent* view = view_;
  if (!view || closing_) {
    // The page is closing or its owner is gone (the shell clears the delegate
    // before -close). Returning false alone would show CEF's default dialog
    // for a page nobody shows any more; suppress it (the call fails).
    suppress_message = true;
    return false;
  }
  if (![view.delegate respondsToSelector:@selector(webContent:
                                             runJavaScriptDialog:)]) {
    return false;
  }
  OEJavaScriptDialogKind kind =
      dialog_type == JSDIALOGTYPE_CONFIRM  ? OEJavaScriptDialogKindConfirm
      : dialog_type == JSDIALOGTYPE_PROMPT ? OEJavaScriptDialogKindPrompt
                                           : OEJavaScriptDialogKindAlert;
  OEJavaScriptDialog* dialog = [[OEJavaScriptDialog alloc]
      initOEWithKind:kind
              message:OEString(message_text)
        defaultPrompt:OEString(default_prompt_text)
               origin:OEURL(origin_url)
             isReload:NO
             callback:callback];
  return [view.delegate webContent:view runJavaScriptDialog:dialog];
}

bool OEClient::OnBeforeUnloadDialog(CefRefPtr<CefBrowser> browser,
                                    const CefString& message_text,
                                    bool is_reload,
                                    CefRefPtr<CefJSDialogCallback> callback) {
  OEWebContent* view = view_;
  if (!view || closing_) {
    // The shell already closed this page: let it unload instead of showing
    // CEF's default beforeunload dialog for a page that is gone.
    callback->Continue(true, CefString());
    return true;
  }
  if (![view.delegate respondsToSelector:@selector(webContent:
                                             runJavaScriptDialog:)]) {
    return false;
  }
  OEJavaScriptDialog* dialog = [[OEJavaScriptDialog alloc]
      initOEWithKind:OEJavaScriptDialogKindBeforeUnload
              message:OEString(message_text)
        defaultPrompt:@""
               origin:view.URL
             isReload:is_reload
             callback:callback];
  return [view.delegate webContent:view runJavaScriptDialog:dialog];
}

#pragma mark Permissions

bool OEClient::OnRequestMediaAccessPermission(
    CefRefPtr<CefBrowser> browser,
    CefRefPtr<CefFrame> frame,
    const CefString& requesting_origin,
    uint32_t requested_permissions,
    CefRefPtr<CefMediaAccessCallback> callback) {
  OEWebContent* view = view_;
  if (!view || closing_) {
    callback->Cancel();  // No prompt for a page that is closing.
    return true;
  }
  if (![view.delegate respondsToSelector:@selector(webContent:
                                             decidePermissionRequest:)]) {
    return false;
  }
  OEPermissionRequest* request = [[OEPermissionRequest alloc]
      initOEWithOrigin:OEURL(requesting_origin)
                            ?: [NSURL URLWithString:@"about:blank"]
                  kinds:OEPermissionKindsFromMedia(requested_permissions)
          mediaCallback:callback
         mediaRequested:requested_permissions
         promptCallback:nullptr];
  return [view.delegate webContent:view decidePermissionRequest:request];
}

bool OEClient::OnShowPermissionPrompt(
    CefRefPtr<CefBrowser> browser,
    uint64_t prompt_id,
    const CefString& requesting_origin,
    uint32_t requested_permissions,
    CefRefPtr<CefPermissionPromptCallback> callback) {
  OEWebContent* view = view_;
  if (!view || closing_) {
    // No prompt for a page that is closing (Chrome style would otherwise
    // show its own bubble).
    callback->Continue(CEF_PERMISSION_RESULT_IGNORE);
    return true;
  }
  if (![view.delegate respondsToSelector:@selector(webContent:
                                             decidePermissionRequest:)]) {
    return false;
  }
  OEPermissionRequest* request = [[OEPermissionRequest alloc]
      initOEWithOrigin:OEURL(requesting_origin)
                            ?: [NSURL URLWithString:@"about:blank"]
                  kinds:OEPermissionKindsFromPrompt(requested_permissions)
          mediaCallback:nullptr
         mediaRequested:0
         promptCallback:callback];
  if (requested_permissions & CEF_PERMISSION_TYPE_REGISTER_PROTOCOL_HANDLER) {
    // Fork API (cef_open_page.h): the scheme and URL of the pending request.
    CefRefPtr<CefDictionaryValue> handler =
        CefGetPendingProtocolHandlerRequest(browser);
    if (handler) {
      [request oe_setProtocolHandlerScheme:OEString(handler->GetString("scheme"))
                               urlTemplate:OEString(handler->GetString("url"))];
    }
  }
  return [view.delegate webContent:view decidePermissionRequest:request];
}

#pragma mark Context menu

void OEClient::OnBeforeContextMenu(CefRefPtr<CefBrowser> browser,
                                   CefRefPtr<CefFrame> frame,
                                   CefRefPtr<CefContextMenuParams> params,
                                   CefRefPtr<CefMenuModel> model) {
  // Chrome style pages get Chrome's full menu: keep only the items Open
  // supports. Alloy style menus are CEF's short list with other ids.
  if (browser->GetHost()->GetRuntimeStyle() == CEF_RUNTIME_STYLE_CHROME) {
    OEFilterChromeContextMenu(model);
  }
}

bool OEClient::RunContextMenu(CefRefPtr<CefBrowser> browser,
                              CefRefPtr<CefFrame> frame,
                              CefRefPtr<CefContextMenuParams> params,
                              CefRefPtr<CefMenuModel> model,
                              CefRefPtr<CefRunContextMenuCallback> callback) {
  OEWebContent* view = view_;
  if (!view || closing_) {
    callback->Cancel();  // Not CEF's default menu over a closing page.
    return true;
  }
  if (![view.delegate respondsToSelector:@selector(webContent:showContextMenu:)]) {
    return false;
  }
  OEContextMenu* menu = [[OEContextMenu alloc] initOEWithParams:params
                                                           model:model
                                                        callback:callback];
  return [view.delegate webContent:view showContextMenu:menu];
}

#pragma mark Downloads

bool OEClient::CanDownload(CefRefPtr<CefBrowser> browser,
                           const CefString& url,
                           const CefString& request_method) {
  return true;
}

bool OEClient::OnBeforeDownload(CefRefPtr<CefBrowser> browser,
                                CefRefPtr<CefDownloadItem> download_item,
                                const CefString& suggested_name,
                                CefRefPtr<CefBeforeDownloadCallback> callback) {
  OEWebContent* view = view_;
  OEBrowserContext* context = download_context_;
  if (!context || context.oe_closing ||
      context.state == OEBrowserContextStateClosed) {
    return true;  // Not executing the destination callback cancels the download.
  }
  [context oe_handleBeforeDownload:download_item
                     suggestedName:OEString(suggested_name)
                        webContent:view
                          callback:callback];
  return true;
}

void OEClient::OnDownloadUpdated(CefRefPtr<CefBrowser> browser,
                                 CefRefPtr<CefDownloadItem> download_item,
                                 CefRefPtr<CefDownloadItemCallback> callback) {
  OEBrowserContext* context = download_context_;
  if (!context || context.oe_closing ||
      context.state == OEBrowserContextStateClosed) {
    if (callback && download_item->IsInProgress()) callback->Cancel();
    return;
  }
  [context oe_handleDownloadUpdated:download_item webContent:view_ callback:callback];
}

#pragma mark Find

void OEClient::OnFindResult(CefRefPtr<CefBrowser> browser,
                            int identifier,
                            int count,
                            const CefRect& selectionRect,
                            int activeMatchOrdinal,
                            bool finalUpdate) {
  OEWebContent* view = view_;
  if ([view.delegate respondsToSelector:@selector(webContent:
                                            didUpdateFindResult:)]) {
    [view.delegate webContent:view
        didUpdateFindResult:[[OEFindResult alloc]
                                initOEWithCount:count
                                          active:activeMatchOrdinal
                                           final:finalUpdate]];
  }
}

#pragma mark Requests

void OEClient::SetClosing() {
  closing_ = true;
  CancelAuthenticationRequests();
}

void OEClient::CancelAuthenticationRequests() {
  ++auth_epoch_;
  OEWebContent* page = view_;
  NSArray<OEAuthenticationRequest*>* requests = auth_requests_.allObjects;
  [auth_requests_ removeAllObjects];
  for (OEAuthenticationRequest* request in requests) {
    if (!request.isPending) continue;
    [request cancel];
    if ([page.delegate respondsToSelector:
          @selector(webContent:didCancelAuthenticationRequest:)]) {
      [page.delegate webContent:page didCancelAuthenticationRequest:request];
    }
  }
}

bool OEClient::GetAuthCredentials(CefRefPtr<CefBrowser> browser,
    const CefString& origin_url, bool isProxy, const CefString& host,
    int port, const CefString& realm, const CefString& scheme,
    CefRefPtr<CefAuthCallback> callback) {
  if (origin_url.length() > 16384 || host.length() > 1024 ||
      realm.length() > 4096 || scheme.length() > 64) {
    callback->Cancel();
    return true;
  }
  // Do not read view_ or any page state on CEF's IO thread. The ref-counted
  // client and callback survive dispatch; the page remains weak.
  CefRefPtr<OEClient> client(this);
  const uint64_t epoch = auth_epoch_.load();
  NSString* origin = OEString(origin_url);
  NSString* authHost = OEString(host);
  NSString* authRealm = OEString(realm);
  NSString* authScheme = OEString(scheme);
  dispatch_async(dispatch_get_main_queue(), ^{
    OEWebContent* page = client->view_;
    for (OEAuthenticationRequest* old in client->auth_requests_.allObjects)
      if (!old.isPending) [client->auth_requests_ removeObject:old];
    if (client->closing_ || client->auth_epoch_.load() != epoch ||
        !OEIsPageBrowser(page, browser) ||
        client->auth_requests_.count >= 16 ||
        ![page.delegate respondsToSelector:
            @selector(webContent:handleAuthenticationRequest:)]) {
      callback->Cancel();
      return;
    }
    OEAuthenticationRequest* request = [[OEAuthenticationRequest alloc]
        initOEWithOrigin:[NSURL URLWithString:origin] host:authHost port:port
        realm:authRealm scheme:authScheme proxy:isProxy callback:callback];
    [client->auth_requests_ addObject:request];
    if (![page.delegate webContent:page handleAuthenticationRequest:request])
      [request cancel];
  });
  return true;
}

bool OEClient::OnBeforeBrowse(CefRefPtr<CefBrowser> browser,
                              CefRefPtr<CefFrame> frame,
                              CefRefPtr<CefRequest> request,
                              bool user_gesture,
                              bool is_redirect) {
  OEWebContent* page = view_;
  if (frame->IsMain() && !is_redirect && OEIsPageBrowser(page, browser))
    CancelAuthenticationRequests();
  // Also cover renderer navigation, redirects and popup creation. Shell-only
  // loadURL filtering does not see these. Leave the current document intact:
  // starting a replacement here (even deferred) could override a newer load.
  // Refuse NTP even before an adopted popup has attached its page. No Open
  // client supplies the full Chrome BrowserView's NTP controller.
  if (frame->IsMain() && OEIsChromeNewTabURL(OEURL(request->GetURL()))) {
    return true;
  }
  if (!page || !frame->IsMain() || !user_gesture || is_redirect ||
      !OEIsPageBrowser(page, browser)) {
    return false;
  }
  return OECancelNavigation(page, OEURL(request->GetURL()), user_gesture,
                            OENavigationModifiers(page));
}

bool OEClient::OnOpenURLFromTab(CefRefPtr<CefBrowser> browser,
                                CefRefPtr<CefFrame> frame,
                                const CefString& target_url,
                                WindowOpenDisposition target_disposition,
                                bool user_gesture) {
  OEWebContent* source = view_;
  NSEventModifierFlags modifiers = OENavigationModifiers(source);
  if ((modifiers & (NSEventModifierFlagCommand | NSEventModifierFlagOption)) ==
          (NSEventModifierFlagCommand | NSEventModifierFlagOption) &&
      OECancelNavigation(source, OEURL(target_url), user_gesture, modifiers)) {
    return true;
  }
  if (target_disposition == CEF_WOD_NEW_WINDOW &&
      OECancelNavigation(source, OEURL(target_url), user_gesture,
                         NSEventModifierFlagShift)) {
    return true;
  }
  if (target_disposition == CEF_WOD_CURRENT_TAB || !source ||
      ![source.delegate respondsToSelector:@selector(webContent:
                                               createWebContentForOpenRequest:)]) {
    return false;
  }
  OEOpenRequest* request =
      [[OEOpenRequest alloc] initOEWithURL:OEURL(target_url)
                                disposition:OEMapDisposition(target_disposition)
                                userGesture:user_gesture
                             requestedFrame:NSZeroRect
                            targetFrameName:@""
                                     source:source
                                    context:source.context];
  OEWebContent* target = [source.delegate webContent:source
                       createWebContentForOpenRequest:request];
  if (target && request.URL && !target.live) {
    [target loadURL:request.URL];
  }
  return true;
}

void OEClient::OnRenderViewReady(CefRefPtr<CefBrowser> browser) {
  OEWebContent* view = view_;
  if (!view) {
    return;
  }
  // New renderer process for this browser: give it the current scripts.
  CefRefPtr<CefProcessMessage> msg =
      CefProcessMessage::Create(kOEMsgScriptsUpdate);
  msg->GetArgumentList()->SetList(0, [view.context oe_scriptsValue]);
  browser->GetMainFrame()->SendProcessMessage(PID_RENDERER, msg);
  [view oe_setCrashState:OEWebContentCrashStateNone];
}

void OEClient::OnRenderProcessTerminated(CefRefPtr<CefBrowser> browser,
                                         TerminationStatus status,
                                         int error_code,
                                         const CefString& error_string) {
  OEWebContentCrashState state = OEWebContentCrashStateCrashed;
  if (status == TS_PROCESS_WAS_KILLED) {
    state = OEWebContentCrashStateKilled;
  } else if (status == TS_PROCESS_OOM) {
    state = OEWebContentCrashStateOutOfMemory;
  }
  [view_ oe_setCrashState:state];
}

bool OEClient::OnRenderProcessUnresponsive(
    CefRefPtr<CefBrowser> browser,
    CefRefPtr<CefUnresponsiveProcessCallback> callback) {
  [view_ oe_setCrashState:OEWebContentCrashStateUnresponsive];
  return false;
}

void OEClient::OnRenderProcessResponsive(CefRefPtr<CefBrowser> browser) {
  [view_ oe_setCrashState:OEWebContentCrashStateNone];
}

#pragma mark DevTools protocol

void OEClient::OnDevToolsMethodResult(CefRefPtr<CefBrowser> browser,
                                      int message_id,
                                      bool success,
                                      const void* result,
                                      size_t result_size) {
  [view_ oe_devToolsResult:message_id
                   success:success
                      json:[NSData dataWithBytes:result length:result_size]];
}

void OEClient::OnDevToolsEvent(CefRefPtr<CefBrowser> browser,
                               const CefString& method,
                               const void* params,
                               size_t params_size) {
  OEWebContent* view = view_;
  if (![view.delegate respondsToSelector:@selector
                      (webContent:didReceiveDevToolsEvent:parameters:)]) {
    return;
  }
  id obj = [NSJSONSerialization
      JSONObjectWithData:[NSData dataWithBytes:params length:params_size]
                 options:0
                   error:nil];
  [view.delegate webContent:view
      didReceiveDevToolsEvent:OEString(method)
                   parameters:[obj isKindOfClass:NSDictionary.class] ? obj : @{}];
}
