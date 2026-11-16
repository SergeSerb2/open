// Private engine declarations. ObjC++ only; this is where CEF meets AppKit.
#pragma once

#import <AppKit/AppKit.h>
#import <OpenEngine/OpenEngine.h>

#include <string>
#include <vector>

#include "include/cef_app.h"
#include "include/cef_browser.h"
#include "include/cef_client.h"
#include "include/cef_extension_manager.h"
#include "include/cef_media_controller.h"
#include "include/cef_navigation_history.h"
#include "include/cef_open_page.h"
#include "include/cef_open_autofill.h"
#include "include/cef_open_profile.h"
#include "include/cef_open_omnibox.h"
#include "include/cef_page_lifecycle.h"
#include "include/cef_request_context.h"
#include "include/cef_tab_strip.h"
#include "include/cef_values.h"
#include "include/views/cef_browser_view.h"
#include "include/views/cef_window.h"

NS_ASSUME_NONNULL_BEGIN

/// Native mouse modifiers survive the renderer's asynchronous navigation IPC.
/// The next pointer/key event replaces them; only the originating window matches.
NSEventModifierFlags OENavigationModifiersForWindow(NSWindow* _Nullable window);
void OENoteNavigationInput(NSWindow* _Nullable window, NSEventModifierFlags modifiers);

#pragma mark - String helpers

inline NSString* OEString(const CefString& s) {
  std::string utf8 = s.ToString();
  return [[NSString alloc] initWithBytes:utf8.data()
                                  length:utf8.size()
                                encoding:NSUTF8StringEncoding]
             ?: @"";
}

inline CefString OECef(NSString* _Nullable s) {
  // -UTF8String is NULL for a string that has no UTF-8 form (an unpaired
  // surrogate); std::string(NULL) would crash.
  const char* utf8 = s.UTF8String;
  return CefString(utf8 ? std::string(utf8) : std::string());
}

inline NSURL* _Nullable OEURL(const CefString& s) {
  NSString* str = OEString(s);
  return str.length ? [NSURL URLWithString:str] : nil;
}

// Chromium's native NTP requires a full Chrome Browser/BrowserView (including
// NewTabFooterController). Neither our Alloy pages nor CEF's embedded Chrome
// hosts supply that controller. Open's empty page is about:blank in both styles.
inline bool OEIsChromeNewTabURL(NSURL* _Nullable url) {
  NSString* scheme = url.scheme.lowercaseString;
  NSString* name = [scheme isEqualToString:@"about"]
      ? url.resourceSpecifier.lowercaseString : url.host.lowercaseString;
  if (![scheme isEqualToString:@"chrome"] &&
      ![scheme isEqualToString:@"about"]) return false;
  name = [[name componentsSeparatedByCharactersInSet:
      [NSCharacterSet characterSetWithCharactersInString:@"/?#"]] firstObject];
  return [name isEqualToString:@"newtab"] ||
      [name isEqualToString:@"new-tab-page"] ||
      [name isEqualToString:@"new-tab-page-third-party"];
}

/// Glob match for Chrome-style match patterns, shared by browser and renderer.
bool OEMatchesPattern(const std::string& pattern, const std::string& url);

/// Process message names (browser <-> renderer).
extern const char kOEMsgScriptsUpdate[];    // browser -> renderer, full snapshot
extern const char kOEMsgScriptsPatch[];     // browser -> renderer, removed IDs + additions
extern const char kOEExtraScripts[];        // extra_info key
extern const char kOEMsgUserStyleSheet[];   // browser -> renderer: key, css
extern const char kOEExtraUserStyles[];     // extra_info key: {key: css}

#pragma mark - Engine internals

class OEClient;
void OEInstallAutofillHandler();
void OERemoveAutofillHandler();

@interface OEEngine ()
- (void)oe_registerWebContent:(OEWebContent*)webContent;
- (void)oe_unregisterWebContent:(OEWebContent*)webContent;
- (void)oe_registerBrowser:(OEBrowser*)browser;
- (void)oe_registerContext:(OEBrowserContext*)context;
- (void)oe_contextClosed:(OEBrowserContext*)context;
- (void)oe_browserDidClose;
- (void)oe_contextInitialized;
- (void)oe_extensionsChangedInContext:(OEBrowserContext*)context;
- (nullable OEBrowserContext*)oe_contextForRequestContext:
    (CefRefPtr<CefRequestContext>)requestContext;
- (CefRefPtr<CefClient>)oe_defaultClient;
@property(nonatomic, readonly) BOOL oe_isTerminating;
@end

@interface OEBrowserContext ()
- (instancetype)initOEWithIdentifier:(NSString*)identifier
                            directory:(nullable NSURL*)directory
                               global:(BOOL)global;
- (nullable instancetype)initOEIncognitoWithIdentifier:(NSString*)identifier
                                              original:(OEBrowserContext*)original;
/// Marks the wrapper closed, closes managers and drops all its CEF handles.
- (void)oe_invalidate;
- (void)oe_nativeContextClosed;
@property(nonatomic) BOOL oe_closing;
@property(nonatomic, readonly) CefRefPtr<CefRequestContext> oe_requestContext;
/// Runs `block` once the request context finished initializing (browsers
/// created earlier lose their initial navigation).
- (void)oe_whenReady:(dispatch_block_t)block;
/// YES once the request context finished initializing.
@property(nonatomic, readonly) BOOL oe_isReady;
- (void)oe_contextInitialized;
- (void)oe_closeAutofill;
/// Serialized user scripts for the renderer (extra_info / process message).
- (CefRefPtr<CefListValue>)oe_scriptsValue;
- (void)oe_handleBeforeDownload:(CefRefPtr<CefDownloadItem>)item
                  suggestedName:(NSString*)name
                     webContent:(nullable OEWebContent*)webContent
                       callback:(CefRefPtr<CefBeforeDownloadCallback>)callback;
- (void)oe_handleDownloadUpdated:(CefRefPtr<CefDownloadItem>)item
                      webContent:(nullable OEWebContent*)webContent
                        callback:(CefRefPtr<CefDownloadItemCallback>)callback;
@end

@interface OENavigationHistory ()
/// Packs a fork history as OPNH v1; nil if it breaks a container limit.
- (nullable instancetype)initOEWithCefHistory:
    (CefRefPtr<CefNavigationHistory>)history;
/// The fork history for CefRestoreNavigationHistory; null if CEF refuses it.
- (CefRefPtr<CefNavigationHistory>)oe_cefHistory;
@end

class OEDevToolsClient;
@class OEMediaState;

@interface OEWebContent ()
- (void)oe_openWorldMessage:(CefRefPtr<CefProcessMessage>)message;
@property(nonatomic, readonly) CefRefPtr<CefBrowser> oe_browser;
/// The fork's media controller, the current OEMediaSession, pending PiP
/// requests and the tab volume (OEMediaSession.mm; media-pip EM-1b).
@property(nonatomic, strong, nullable) OEMediaState* oe_mediaState;
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
- (CefRefPtr<CefDictionaryValue>)oe_extraInfoWithScripts:(CefRefPtr<CefListValue>)scripts;
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
/// From CefMediaControllerHandler::OnAudibleChanged (patch P6).
- (void)oe_setAudible:(BOOL)audible;
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

/// OEMediaSession.mm (media-pip EM-1b, EM-2, EM-3, EM-5).
@interface OEWebContent (OEMediaInternal)
/// Attaches the fork's CefMediaController to a new browser (OnAfterCreated).
- (void)oe_attachMedia:(CefRefPtr<CefBrowser>)browser;
/// CefMediaControllerHandler::OnMediaStateChanged: rebuilds mediaSession.
- (void)oe_mediaStateChanged;
/// Forgets the media state (crash); `detach` also drops the controller
/// (the browser closed).
- (void)oe_resetMediaDetaching:(BOOL)detach;
@end

@interface OEMediaPosition ()
/// A "position" dictionary of the fork's media or Picture in Picture state.
- (instancetype)initOEWithDictionary:(CefRefPtr<CefDictionaryValue>)position;
@end

/// OEPictureInPicture.mm (media-pip EM-4): Open's own Picture in Picture
/// window. The media handler (OEMediaSession.mm) forwards these.
@interface OEPictureInPicture ()
/// True when the App shows video Picture in Picture itself (a delegate is
/// set): CefMediaControllerHandler::ShouldHostPictureInPicture.
+ (BOOL)oe_shellHostsPictureInPicture;
@end

@interface OEWebContent (OEPictureInPictureInternal)
- (void)oe_pictureInPictureOpened:(CefRefPtr<CefPictureInPictureWindow>)window;
- (void)oe_pictureInPictureChanged;
- (void)oe_pictureInPictureClosed;
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
@property(nonatomic, readonly) CefRefPtr<CefExtensionManager> oe_manager;
- (void)oe_contextClosed;
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

@interface OEAuthenticationRequest ()
- (instancetype)initOEWithOrigin:(nullable NSURL*)origin
                            host:(NSString*)host port:(NSInteger)port
                           realm:(NSString*)realm scheme:(NSString*)scheme
                           proxy:(BOOL)proxy
                        callback:(CefRefPtr<CefAuthCallback>)callback;
@end

@interface OEPermissionRequest ()
- (instancetype)initOEWithOrigin:(NSURL*)origin
                            kinds:(OEPermissionKind)kinds
                    mediaCallback:(CefRefPtr<CefMediaAccessCallback>)media
                   mediaRequested:(uint32_t)mediaRequested
                   promptCallback:(CefRefPtr<CefPermissionPromptCallback>)prompt;
- (void)oe_setProtocolHandlerScheme:(NSString*)scheme
                        urlTemplate:(NSString*)urlTemplate;
@end

// DevTools docked in an embedder view (OEDevToolsDock.mm).
@interface OEDevToolsDock : NSObject
@property(nonatomic, readonly) NSView* view;
@property(nonatomic, readonly) BOOL isHostingFrontend;
- (BOOL)registerForBrowser:(CefRefPtr<CefBrowser>)browser;
- (void)unregisterForBrowser:(CefRefPtr<CefBrowser>)browser;
- (void)close;
@end

@interface OEProtocolHandler ()
- (instancetype)initOEWithScheme:(NSString*)scheme
                      urlTemplate:(NSString*)urlTemplate
                        isDefault:(BOOL)isDefault;
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
