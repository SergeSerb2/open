// Private engine declarations. ObjC++ only; this is where CEF meets AppKit.
#pragma once

#import <AppKit/AppKit.h>
#import <OpenEngine/OpenEngine.h>

#include <string>
#include <vector>

#include "include/cef_app.h"
#include "include/cef_browser.h"
#include "include/cef_client.h"
#include "include/cef_request_context.h"
#include "include/cef_tab_strip.h"
#include "include/cef_values.h"
#include "include/views/cef_browser_view.h"
#include "include/views/cef_window.h"

NS_ASSUME_NONNULL_BEGIN

#pragma mark - String helpers

inline NSString* OEString(const CefString& s) {
  std::string utf8 = s.ToString();
  return [[NSString alloc] initWithBytes:utf8.data()
                                  length:utf8.size()
                                encoding:NSUTF8StringEncoding]
             ?: @"";
}

inline CefString OECef(NSString* _Nullable s) {
  return CefString(s ? std::string(s.UTF8String) : std::string());
}

inline NSURL* _Nullable OEURL(const CefString& s) {
  NSString* str = OEString(s);
  return str.length ? [NSURL URLWithString:str] : nil;
}

/// Glob match for Chrome-style match patterns, shared by browser and renderer.
bool OEMatchesPattern(const std::string& pattern, const std::string& url);

/// Process message names (browser <-> renderer).
extern const char kOEMsgScriptsUpdate[];    // browser -> renderer
extern const char kOEMsgAudibleChanged[];   // renderer -> browser
extern const char kOEMsgMediaReport[];      // renderer -> browser (EM-1a)
extern const char kOEMsgMediaCommand[];     // browser -> renderer (EM-1a)
extern const char kOEExtraScripts[];        // extra_info key

#pragma mark - Engine internals

class OEClient;

@interface OEEngine ()
- (void)oe_registerWebContent:(OEWebContent*)webContent;
- (void)oe_unregisterWebContent:(OEWebContent*)webContent;
- (void)oe_registerBrowser:(OEBrowser*)browser;
- (void)oe_browserDidClose;
- (void)oe_contextInitialized;
- (void)oe_extensionsChangedInContext:(OEBrowserContext*)context;
- (OEBrowserContext*)oe_contextForRequestContext:
    (CefRefPtr<CefRequestContext>)requestContext;
- (CefRefPtr<CefClient>)oe_defaultClient;
@property(nonatomic, readonly) BOOL oe_isTerminating;
@end

@interface OEBrowserContext ()
- (instancetype)initOEWithIdentifier:(NSString*)identifier
                            directory:(nullable NSURL*)directory
                               global:(BOOL)global;
@property(nonatomic, readonly) CefRefPtr<CefRequestContext> oe_requestContext;
/// Runs `block` once the request context finished initializing (browsers
/// created earlier lose their initial navigation).
- (void)oe_whenReady:(dispatch_block_t)block;
/// YES once the request context finished initializing.
@property(nonatomic, readonly) BOOL oe_isReady;
- (void)oe_contextInitialized;
/// Serialized user scripts for the renderer (extra_info / process message).
- (CefRefPtr<CefListValue>)oe_scriptsValue;
- (void)oe_handleBeforeDownload:(CefRefPtr<CefDownloadItem>)item
                  suggestedName:(NSString*)name
                     webContent:(nullable OEWebContent*)webContent
                       callback:(CefRefPtr<CefBeforeDownloadCallback>)callback;
- (void)oe_handleDownloadUpdated:(CefRefPtr<CefDownloadItem>)item
                        callback:(CefRefPtr<CefDownloadItemCallback>)callback;
@end

<<<<<<< HEAD
class OEDevToolsClient;
=======
@class OEMediaFrames;
>>>>>>> origin/main

@interface OEWebContent ()
@property(nonatomic, readonly) CefRefPtr<CefBrowser> oe_browser;
/// Per-frame media probe reports and the current OEMediaSession (EM-1a).
@property(nonatomic, strong, nullable) OEMediaFrames* oe_mediaFrames;
- (void)oe_notify:(OEWebContentChange)changes;

@property(nonatomic, readonly) CefRefPtr<OEClient> oe_client;
/// Set by OEBrowser when the content joins or leaves a tab strip.
@property(nonatomic, weak, nullable) OEBrowser* oe_tabStrip;
/// Set for extension action popups; resize/close go to this browser.
@property(nonatomic, weak, nullable) OEBrowser* oe_popupOwner;
/// The OEBrowser whose hidden Chrome window hosts this page as a tab (fork
/// patch P1); nil for Alloy and Views-window Chrome style pages.
@property(nonatomic, weak, nullable) OEBrowser* oe_hostBrowser;
// -[OEBrowser identifier] of oe_hostBrowser, kept after that browser is gone
// (its -dealloc marks its pages closing).
@property(nonatomic, readonly) NSInteger oe_hostBrowserIdentifier;
- (void)oe_setHostBrowser:(nullable OEBrowser*)browser;
/// A content for a tab that Chromium creates in `browser` on its own
/// (CefTabStripHandler::OnBeforeTabCreated). It never creates its own page.
- (instancetype)initOEForChromiumTabInBrowser:(OEBrowser*)browser;
/// The page of an action popup that Chromium opens in `browser` (fork patch
/// P2; CefTabStripHandler::OnBeforeExtensionPopupCreated).
- (instancetype)initOEForExtensionPopupInBrowser:(OEBrowser*)browser
                                       extension:(NSString*)extensionIdentifier;
- (CefRefPtr<CefDictionaryValue>)oe_extraInfo;
- (CefBrowserSettings)oe_browserSettings;
@property(nonatomic, copy, nullable) NSString* oe_popupExtension;
/// Prepares this (not yet created) content to receive a popup browser from
/// OnBeforePopup. Fills windowInfo/client for Alloy-style hosting.
- (BOOL)oe_adoptPopupWithWindowInfo:(CefWindowInfo&)windowInfo
                             client:(CefRefPtr<CefClient>&)client
                           settings:(CefBrowserSettings&)settings
                          extraInfo:(CefRefPtr<CefDictionaryValue>&)extraInfo
                             opener:(OEWebContent*)opener;
/// Chrome style: adopt a popup CefBrowserView created by Chromium.
- (void)oe_adoptPopupBrowserView:(CefRefPtr<CefBrowserView>)browserView;
- (void)oe_browserCreated:(CefRefPtr<CefBrowser>)browser;
- (void)oe_browserClosed;
- (void)oe_setURL:(nullable NSURL*)url;
- (void)oe_setTitle:(NSString*)title;
- (void)oe_setFaviconURL:(nullable NSURL*)url;
- (void)oe_setLoading:(BOOL)loading canGoBack:(BOOL)back canGoForward:(BOOL)forward;
- (void)oe_setProgress:(double)progress;
- (void)oe_setFullscreen:(BOOL)fullscreen;
- (void)oe_setAudible:(BOOL)audible frame:(NSString*)frameId;
- (void)oe_setCrashState:(OEWebContentCrashState)state;
- (void)oe_setMediaCaptureCamera:(BOOL)camera microphone:(BOOL)microphone;
- (void)oe_setStatusText:(NSString*)text;
- (void)oe_notifyZoomChanged;
- (void)oe_requestContentSize:(NSSize)size;
- (void)oe_requestClose;
- (void)oe_devToolsResult:(int)messageId
                  success:(BOOL)success
                     json:(NSData*)json;
/// The DevTools window of this page opened (OEDevToolsClient::OnAfterCreated)
/// or closed (OnBeforeClose).
- (void)oe_setDevToolsFrontend:(OEDevToolsClient*)frontend;
- (void)oe_devToolsFrontendClosed:(OEDevToolsClient*)frontend;
@end

/// OEMediaSession.mm (media-pip EM-1a).
@interface OEWebContent (OEMediaInternal)
/// The media probe of one frame reported `kind` ("state" or "pip").
- (void)oe_mediaReport:(NSString*)kind json:(NSString*)json frame:(NSString*)frameId;
/// Forgets every frame's media state (crash, close).
- (void)oe_resetMedia;
@end

@interface OEContextMenuItem ()
/// From CefTabStrip::GetExtensionActionMenu (fork patch P2).
- (instancetype)initOEWithDictionary:(CefRefPtr<CefDictionaryValue>)item;
@end

@interface OEExtensionActionMenu ()
/// `menu`: the strip's menu id (CefTabStrip::GetExtensionActionMenu).
- (instancetype)initOEWithBrowser:(OEBrowser*)browser
                        extension:(NSString*)extensionIdentifier
                             menu:(int)menu
                            items:(NSArray<OEContextMenuItem*>*)items;
@end

@interface OEBrowser ()
/// The hidden Chrome window (fork patch P1). Created on first use when
/// `create` is YES; nullptr before the context is ready or after -close.
- (CefRefPtr<CefTabStrip>)oe_tabStripCreatingIfNeeded:(BOOL)create;
/// NO once the engine refused a hidden Chrome window for this browser's
/// context: its Chrome style pages use Alloy instead of a Chrome window.
@property(nonatomic, readonly) BOOL oe_canHostTabs;
/// Puts Chromium's tab strip in -webContents order on the next turn.
- (void)oe_setNeedsTabStripSync;
/// YES when `content` is the active tab of Chromium's hidden strip. Runs a
/// pending strip sync first, so a selection the shell just made counts.
/// Chrome commands (ExecuteChromeCommand) act on that active tab.
- (BOOL)oe_isChromiumActiveTab:(OEWebContent*)content;
- (void)oe_popupDidResize:(OEWebContent*)popup size:(NSSize)size;
- (void)oe_popupRequestedClose:(OEWebContent*)popup;
- (void)oe_webContentClosed:(OEWebContent*)webContent;
- (void)oe_extensionsChanged;
@end

@interface OEExtensionManager ()
- (instancetype)initOEWithContext:(OEBrowserContext*)context;
@end

@interface OEExtensionAction ()
- (instancetype)initOEWithExtension:(OEExtension*)extension;
/// From Chrome's toolbar action model or the profile's action list (fork
/// patch P2; CefTabStrip::GetExtensionActionState).
- (instancetype)initOEWithIdentifier:(NSString*)identifier
                               state:(CefRefPtr<CefDictionaryValue>)state
                        toolbarImage:(nullable NSImage*)toolbarImage
                                icon:(nullable NSImage*)icon;
@end

@interface OEExtension ()
@property(nonatomic, readonly) BOOL oe_hasAction;
@property(nonatomic, readonly, copy, nullable) NSString* oe_actionTitle;
@property(nonatomic, readonly, copy, nullable) NSURL* oe_actionPopupURL;
@property(nonatomic, readonly, nullable) NSImage* oe_actionIcon;
@end

@interface OEOpenRequest ()
- (instancetype)initOEWithURL:(nullable NSURL*)url
                   disposition:(OEOpenDisposition)disposition
                   userGesture:(BOOL)userGesture
                requestedFrame:(NSRect)frame
               targetFrameName:(NSString*)targetFrameName
                        source:(nullable OEWebContent*)source
                       context:(OEBrowserContext*)context;
@end

@interface OEJavaScriptDialog ()
- (instancetype)initOEWithKind:(OEJavaScriptDialogKind)kind
                        message:(NSString*)message
                  defaultPrompt:(NSString*)defaultPrompt
                         origin:(nullable NSURL*)origin
                       isReload:(BOOL)isReload
                       callback:(CefRefPtr<CefJSDialogCallback>)callback;
@end

@interface OEPermissionRequest ()
- (instancetype)initOEWithOrigin:(NSURL*)origin
                            kinds:(OEPermissionKind)kinds
                    mediaCallback:(CefRefPtr<CefMediaAccessCallback>)media
                   mediaRequested:(uint32_t)mediaRequested
                   promptCallback:(CefRefPtr<CefPermissionPromptCallback>)prompt;
@end

@interface OEContextMenu ()
- (instancetype)initOEWithParams:(CefRefPtr<CefContextMenuParams>)params
                            model:(CefRefPtr<CefMenuModel>)model
                         callback:(CefRefPtr<CefRunContextMenuCallback>)callback;
@end

@interface OEFindResult ()
- (instancetype)initOEWithCount:(NSInteger)count
                          active:(NSInteger)active
                           final:(BOOL)isFinal;
@end

/// Maps CEF permission bits (media + prompt) to OEPermissionKind.
OEPermissionKind OEPermissionKindsFromPrompt(uint32_t prompt);
OEPermissionKind OEPermissionKindsFromMedia(uint32_t media);

/// The CEF client attached to one OEWebContent. Implements every handler.
CefRefPtr<OEClient> OECreateClient(OEWebContent* webContent);

/// The app (browser + renderer process handlers).
CefRefPtr<CefApp> OECreateApp(NSArray<NSString*>* _Nullable extraSwitches);

/// Chrome-style Views hosting (OEChromeHost.mm).
CefRefPtr<CefWindowDelegate> OECreateChromeHostWindow(
    OEWebContent* webContent,
    CefRefPtr<CefClient> client,
    const CefString& url,
    const CefBrowserSettings& settings,
    CefRefPtr<CefDictionaryValue> extraInfo,
    CefRefPtr<CefRequestContext> context,
    bool showToolbar,
    CefRefPtr<CefBrowserView> adoptedView);
NSWindow* _Nullable OEChromeHostNSWindow(CefRefPtr<CefWindowDelegate> host);
void OEChromeHostClose(CefRefPtr<CefWindowDelegate> host);

NS_ASSUME_NONNULL_END
