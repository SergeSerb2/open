// Chrome-style hosting. On macOS CEF accepts a Chrome-style browser only
// inside its own Views window (cef_types_mac.h: "Alloy style will always be
// used ... if |parent_view| is provided"). We create a frameless CefWindow per
// OEWebContent and keep it glued over the view as a child NSWindow.

#import "OEInternal.h"

#include "include/views/cef_browser_view_delegate.h"
#include "include/views/cef_window_delegate.h"

@interface OEWebContent (ChromeHost)
- (nullable OEWebContent*)oe_takePendingChromePopup;
- (void)oe_chromeWindowReady:(NSWindow*)window;
@end

namespace {

NSWindow* NSWindowFor(CefRefPtr<CefWindow> window) {
  if (!window) {
    return nil;
  }
  id handle = (__bridge id)window->GetWindowHandle();
  if ([handle isKindOfClass:NSWindow.class]) {
    return handle;
  }
  if ([handle isKindOfClass:NSView.class]) {
    return [(NSView*)handle window];
  }
  return nil;
}

class OEChromeBrowserViewDelegate : public CefBrowserViewDelegate {
 public:
  OEChromeBrowserViewDelegate(OEWebContent* view, bool toolbar)
      : view_(view), toolbar_(toolbar) {}

  cef_runtime_style_t GetBrowserRuntimeStyle() override {
    return CEF_RUNTIME_STYLE_CHROME;
  }

  ChromeToolbarType GetChromeToolbarType(
      CefRefPtr<CefBrowserView> browser_view) override {
    return toolbar_ ? CEF_CTT_NORMAL : CEF_CTT_NONE;
  }

  CefRefPtr<CefBrowserViewDelegate> GetDelegateForPopupBrowserView(
      CefRefPtr<CefBrowserView> browser_view,
      const CefBrowserSettings& settings,
      CefRefPtr<CefClient> client,
      bool is_devtools) override {
    return new OEChromeBrowserViewDelegate(nil, false);
  }

  bool OnPopupBrowserViewCreated(CefRefPtr<CefBrowserView> browser_view,
                                 CefRefPtr<CefBrowserView> popup_browser_view,
                                 bool is_devtools) override {
    if (is_devtools) {
      return false;
    }
    OEWebContent* target = [view_ oe_takePendingChromePopup];
    if (!target) {
      return false;
    }
    [target oe_adoptPopupBrowserView:popup_browser_view];
    return true;
  }

 private:
  __weak OEWebContent* view_;
  bool toolbar_;
  IMPLEMENT_REFCOUNTING(OEChromeBrowserViewDelegate);
};

class OEChromeHostWindow : public CefWindowDelegate {
 public:
  OEChromeHostWindow(OEWebContent* view,
                     CefRefPtr<CefClient> client,
                     const CefString& url,
                     const CefBrowserSettings& settings,
                     CefRefPtr<CefDictionaryValue> extra,
                     CefRefPtr<CefRequestContext> context,
                     bool toolbar,
                     CefRefPtr<CefBrowserView> adopted)
      : view_(view),
        client_(client),
        url_(url),
        settings_(settings),
        extra_(extra),
        context_(context),
        toolbar_(toolbar),
        browser_view_(adopted) {}

  void OnWindowCreated(CefRefPtr<CefWindow> window) override {
    window_ = window;
    if (!browser_view_) {
      browser_view_ = CefBrowserView::CreateBrowserView(
          client_, url_, settings_, extra_, context_,
          new OEChromeBrowserViewDelegate(view_, toolbar_));
    }
    window->AddChildView(browser_view_);
    window->Show();
    NSWindow* ns = NSWindowFor(window);
    ns.hasShadow = NO;
    [view_ oe_chromeWindowReady:ns];
  }

  void OnWindowDestroyed(CefRefPtr<CefWindow> window) override {
    window_ = nullptr;
    browser_view_ = nullptr;
  }

  bool IsFrameless(CefRefPtr<CefWindow> window) override { return true; }
  bool WithStandardWindowButtons(CefRefPtr<CefWindow> window) override {
    return false;
  }
  bool CanMaximize(CefRefPtr<CefWindow> window) override { return false; }
  bool CanMinimize(CefRefPtr<CefWindow> window) override { return false; }
  cef_runtime_style_t GetWindowRuntimeStyle() override {
    return CEF_RUNTIME_STYLE_CHROME;
  }

  CefRect GetInitialBounds(CefRefPtr<CefWindow> window) override {
    NSView* view = view_.view;
    NSWindow* host = view.window;
    if (!host) {
      return CefRect(100, 100, 800, 600);
    }
    NSRect screen =
        [host convertRectToScreen:[view convertRect:view.bounds toView:nil]];
    CGFloat primaryHeight = NSScreen.screens.firstObject.frame.size.height;
    return CefRect((int)screen.origin.x,
                   (int)(primaryHeight - NSMaxY(screen)),
                   (int)screen.size.width, (int)screen.size.height);
  }

  void Close() {
    if (window_) {
      window_->Close();
    }
  }

  NSWindow* NativeWindow() { return NSWindowFor(window_); }

 private:
  __weak OEWebContent* view_;
  CefRefPtr<CefClient> client_;
  CefString url_;
  CefBrowserSettings settings_;
  CefRefPtr<CefDictionaryValue> extra_;
  CefRefPtr<CefRequestContext> context_;
  bool toolbar_;
  CefRefPtr<CefWindow> window_;
  CefRefPtr<CefBrowserView> browser_view_;
  IMPLEMENT_REFCOUNTING(OEChromeHostWindow);
};

}  // namespace

CefRefPtr<CefWindowDelegate> OECreateChromeHostWindow(
    OEWebContent* webContent,
    CefRefPtr<CefClient> client,
    const CefString& url,
    const CefBrowserSettings& settings,
    CefRefPtr<CefDictionaryValue> extraInfo,
    CefRefPtr<CefRequestContext> context,
    bool showToolbar,
    CefRefPtr<CefBrowserView> adoptedView) {
  CefRefPtr<OEChromeHostWindow> host =
      new OEChromeHostWindow(webContent, client, url, settings, extraInfo,
                             context, showToolbar, adoptedView);
  CefWindow::CreateTopLevelWindow(host.get());
  return host.get();
}

NSWindow* OEChromeHostNSWindow(CefRefPtr<CefWindowDelegate> host) {
  return static_cast<OEChromeHostWindow*>(host.get())->NativeWindow();
}

void OEChromeHostClose(CefRefPtr<CefWindowDelegate> host) {
  static_cast<OEChromeHostWindow*>(host.get())->Close();
}
