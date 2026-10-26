// OpenEngine: Open's browser engine layer.
//
// This is the only public surface of the engine. It never exposes CEF or
// Chromium types, so the shell does not change when the engine moves from CEF
// to an own Chromium fork. Threading: unless a declaration says otherwise,
// every class and method is main-thread only (the CEF UI thread is the main
// thread), which Swift sees as @MainActor.

#import <Foundation/Foundation.h>

#define OE_EXTERN extern __attribute__((visibility("default")))
#define OE_EXPORT __attribute__((visibility("default")))

NS_HEADER_AUDIT_BEGIN(nullability, sendability)

/// How a web view is hosted inside Chromium.
///
/// - Alloy: a plain content-layer WebContents placed directly in our NSView.
///   Several per window, any position, no Chrome UI. This is the default.
/// - Chrome: a Chrome-UI browser. On macOS CEF can host it only in its own
///   Views window, so the engine places that window as a borderless child
///   window over the OEWebView frame. Kept for the extension experiments in
///   docs/engine-spike.md.
typedef NS_ENUM(NSInteger, OERuntimeStyle) {
  OERuntimeStyleAlloy = 0,
  OERuntimeStyleChrome = 1,
} NS_SWIFT_NAME(RuntimeStyle);

OE_EXTERN NSErrorDomain const OEErrorDomain NS_SWIFT_NAME(EngineErrorDomain);

typedef NS_ERROR_ENUM(OEErrorDomain, OEErrorCode){
    OEErrorAlreadyStarted = 1,
    OEErrorInitializationFailed = 2,
    OEErrorJavaScriptException = 3,
    OEErrorWebViewClosed = 4,
    OEErrorDevToolsFailure = 5,
    OEErrorUnsupported = 6,
} NS_SWIFT_NAME(EngineError);

NS_HEADER_AUDIT_END(nullability, sendability)
