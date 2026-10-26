#import "OEClient.h"

#include "include/cef_parser.h"

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
    default:
      return OEOpenDispositionCurrentTab;
  }
}

}  // namespace

CefRefPtr<OEClient> OECreateClient(OEWebContent* webContent) {
  return new OEClient(webContent);
}

bool OEClient::OnProcessMessageReceived(CefRefPtr<CefBrowser> browser,
                                        CefRefPtr<CefFrame> frame,
                                        CefProcessId source_process,
                                        CefRefPtr<CefProcessMessage> message) {
  if (message->GetName() == kOEMsgAudibleChanged) {
    [view_ oe_setAudible:message->GetArgumentList()->GetBool(0)
                   frame:OEString(message->GetArgumentList()->GetString(1))];
    return true;
  }
  return false;
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
  id<OEWebContentDelegate> delegate = source.delegate;
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

// The client of a page's DevTools window. Chrome opens that window itself
// (the context menu's Inspect), and CEF gives it the inspected page's client
// unless OnBeforeDevToolsPopup picks another one.
class OEDevToolsClient : public CefClient {
  IMPLEMENT_REFCOUNTING(OEDevToolsClient);
};

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
  // With this client the DevTools page's creation, title, and close would
  // reach the inspected page: closing DevTools closed the tab.
  client = new OEDevToolsClient();
}

void OEClient::OnAfterCreated(CefRefPtr<CefBrowser> browser) {
  if (!OEIsPageBrowser(view_, browser)) {
    return;
  }
  [view_ oe_browserCreated:browser];
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
  return [view.delegate webContent:view decidePermissionRequest:request];
}

#pragma mark Context menu

bool OEClient::RunContextMenu(CefRefPtr<CefBrowser> browser,
                              CefRefPtr<CefFrame> frame,
                              CefRefPtr<CefContextMenuParams> params,
                              CefRefPtr<CefMenuModel> model,
                              CefRefPtr<CefRunContextMenuCallback> callback) {
  OEWebContent* view = view_;
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
  OEBrowserContext* context = view.context ?: OEEngine.shared.defaultContext;
  [context oe_handleBeforeDownload:download_item
                     suggestedName:OEString(suggested_name)
                        webContent:view
                          callback:callback];
  return true;
}

void OEClient::OnDownloadUpdated(CefRefPtr<CefBrowser> browser,
                                 CefRefPtr<CefDownloadItem> download_item,
                                 CefRefPtr<CefDownloadItemCallback> callback) {
  OEBrowserContext* context = view_.context ?: OEEngine.shared.defaultContext;
  [context oe_handleDownloadUpdated:download_item callback:callback];
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

bool OEClient::OnOpenURLFromTab(CefRefPtr<CefBrowser> browser,
                                CefRefPtr<CefFrame> frame,
                                const CefString& target_url,
                                WindowOpenDisposition target_disposition,
                                bool user_gesture) {
  OEWebContent* source = view_;
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
