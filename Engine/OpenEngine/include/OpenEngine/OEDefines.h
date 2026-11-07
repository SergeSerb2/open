// OpenEngine: Open's browser engine layer.
//
// This is the only public surface of the engine. It never exposes CEF or
// Chromium types, so the shell does not change when the engine moves from
// stock CEF to our own Chromium fork.
//
// Shape (same split as Arc's ADK over ArcCore, docs/re/architecture-map.md §5):
//
//   OEEngine          process lifecycle, message loop     (ADK Application)
//   OEBrowserContext  one profile: storage, scripts,      (ADK BrowserContext)
//                     network filter, permissions,
//                     downloads, extensions
//   OEBrowser         one shell window's tab strip, as    (ADK Browser)
//                     Chromium's extension system sees it
//   OEWebContent      one page; its `view` goes anywhere  (ADK WebContent)
//
// The shell allocates configuration and value objects. The engine allocates
// web contents for popups it creates, downloads, dialogs, and requests, and
// hands them over through delegates. All delegates are plain protocols.
//
// Threading: unless a declaration says otherwise, every class and method is
// main-thread only (the CEF UI thread is the main thread), which Swift sees as
// @MainActor.

#import <Foundation/Foundation.h>

#define OE_EXTERN extern __attribute__((visibility("default")))
#define OE_EXPORT __attribute__((visibility("default")))

NS_HEADER_AUDIT_BEGIN(nullability, sendability)

/// How a web content is hosted inside Chromium.
///
/// - Alloy: a content-layer WebContents placed directly in our NSView. Any
///   number per window, any position, no Chrome UI. Chromium's tab APIs do
///   not see it. Used for extension action popups until fork patch P2.
/// - Chrome: a tab of Chrome's browser layer. With fork patch P1 a Chrome
///   style content that is in an OEBrowser when its page is created becomes
///   a tab of that window's hidden Chrome window, hosted in our NSView, so
///   chrome.tabs and chrome.windows see it (docs/engine-patches.md). Any
///   other Chrome style content (and every one on stock CEF) gets its own
///   Views window, glued over the content's view as a borderless child
///   window (CEF issue #3294); the Web Store install prompt needs that today.
typedef NS_ENUM(NSInteger, OERuntimeStyle) {
  OERuntimeStyleAlloy = 0,
  OERuntimeStyleChrome = 1,
};

OE_EXTERN NSErrorDomain const OEErrorDomain;

typedef NS_ERROR_ENUM(OEErrorDomain, OEErrorCode){
    OEErrorAlreadyStarted = 1,
    OEErrorInitializationFailed = 2,
    OEErrorJavaScriptException = 3,
    OEErrorWebContentClosed = 4,
    OEErrorDevToolsFailure = 5,
    OEErrorUnsupported = 6,
    OEErrorEphemeralContext = 7,
    OEErrorMockKeychain = 8,
};

NS_HEADER_AUDIT_END(nullability, sendability)
