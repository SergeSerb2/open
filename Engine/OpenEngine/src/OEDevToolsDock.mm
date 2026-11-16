// DevTools docked in an embedder view (IMC 10:55, 2026-11-12; CEF patch 0302,
// cef_open_page.h CefSetOpenDevToolsDockDelegate). A hosted Chrome-style page
// has no CefBrowserView, so CEF cannot give its DevTools a parent view. With a
// dock delegate registered, CEF creates the DevTools browser as a Views-hosted
// popup and hands its CefBrowserView to the delegate below. We put that view
// in a frameless CefWindow and keep the window over the dock view as a child
// window, as OEChromeHost does for hosted pages.

#import "OEInternal.h"

#include "include/cef_open_page.h"
#include "include/views/cef_browser_view_delegate.h"
#include "include/views/cef_window.h"
#include "include/views/cef_window_delegate.h"

@class OEDevToolsDock;

@interface OEDevToolsDockView : NSView
@property(nonatomic, weak) OEDevToolsDock* dock;
@end

@interface OEDevToolsDock ()
- (void)oe_adoptBrowserView:(CefRefPtr<CefBrowserView>)browserView;
- (void)oe_windowReady:(NSWindow*)window;
/// `host`: the OEDockWindowDelegate whose window went away.
- (void)oe_windowDestroyed:(const void*)host;
- (void)oe_sync;
@end

namespace {

NSWindow* DockNSWindow(CefRefPtr<CefWindow> window) {
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

class OEDockWindowDelegate : public CefWindowDelegate {
 public:
  OEDockWindowDelegate(OEDevToolsDock* dock,
                       CefRefPtr<CefBrowserView> browser_view)
      : dock_(dock), browser_view_(browser_view) {}

  void OnWindowCreated(CefRefPtr<CefWindow> window) override {
    window_ = window;
    window->AddChildView(browser_view_);
    window->Show();
    NSWindow* ns = DockNSWindow(window);
    ns.hasShadow = NO;
    [dock_ oe_windowReady:ns];
  }
  void OnWindowDestroyed(CefRefPtr<CefWindow> window) override {
    window_ = nullptr;
    browser_view_ = nullptr;
    [dock_ oe_windowDestroyed:this];
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
  void Close() {
    if (window_) {
      window_->Close();
    }
  }

 private:
  __weak OEDevToolsDock* dock_;
  CefRefPtr<CefBrowserView> browser_view_;
  CefRefPtr<CefWindow> window_;
  IMPLEMENT_REFCOUNTING(OEDockWindowDelegate);
};

// Registered with CefSetOpenDevToolsDockDelegate for one DevTools opening.
class OEDockBrowserViewDelegate : public CefBrowserViewDelegate {
 public:
  explicit OEDockBrowserViewDelegate(OEDevToolsDock* dock) : dock_(dock) {}

  cef_runtime_style_t GetBrowserRuntimeStyle() override {
    return CEF_RUNTIME_STYLE_CHROME;
  }
  bool OnPopupBrowserViewCreated(CefRefPtr<CefBrowserView> browser_view,
                                 CefRefPtr<CefBrowserView> popup_browser_view,
                                 bool is_devtools) override {
    OEDevToolsDock* dock = dock_;

    if (!is_devtools || !dock) {
      return false;  // CEF opens its own window.
    }
    [dock oe_adoptBrowserView:popup_browser_view];
    return true;
  }

 private:
  __weak OEDevToolsDock* dock_;
  IMPLEMENT_REFCOUNTING(OEDockBrowserViewDelegate);
};

}  // namespace

@implementation OEDevToolsDockView

- (BOOL)isFlipped {
  return YES;
}
- (void)viewDidMoveToWindow {
  [super viewDidMoveToWindow];
  [self.dock oe_sync];
}
- (void)setFrame:(NSRect)frame {
  [super setFrame:frame];
  [self.dock oe_sync];
}
- (void)viewDidHide {
  [super viewDidHide];
  [self.dock oe_sync];
}
- (void)viewDidUnhide {
  [super viewDidUnhide];
  [self.dock oe_sync];
}

@end

@implementation OEDevToolsDock {
  OEDevToolsDockView* _view;
  CefRefPtr<OEDockWindowDelegate> _host;
  NSWindow* __weak _window;
  NSWindow* __weak _observedWindow;
}

- (instancetype)init {
  if ((self = [super init])) {
    _view = [[OEDevToolsDockView alloc] initWithFrame:NSMakeRect(0, 0, 400, 400)];
    _view.dock = self;
    _view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  }
  return self;
}

- (NSView*)view {
  return _view;
}

- (BOOL)isHostingFrontend {
  return _host != nullptr;
}

- (BOOL)registerForBrowser:(CefRefPtr<CefBrowser>)browser {
  if (!browser) {
    return NO;
  }
  return CefSetOpenDevToolsDockDelegate(browser,
                                        new OEDockBrowserViewDelegate(self));
}

- (void)unregisterForBrowser:(CefRefPtr<CefBrowser>)browser {
  if (browser) {
    CefSetOpenDevToolsDockDelegate(browser, nullptr);
  }
}

- (void)oe_adoptBrowserView:(CefRefPtr<CefBrowserView>)browserView {
  [self close];
  _host = new OEDockWindowDelegate(self, browserView);
  CefWindow::CreateTopLevelWindow(_host.get());
}

- (void)oe_windowReady:(NSWindow*)window {
  _window = window;
  [self oe_sync];
  // Views applies its own initial bounds after Show(); place it again.
  __weak OEDevToolsDock* weakSelf = self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 10),
                 dispatch_get_main_queue(), ^{
                   [weakSelf oe_sync];
                 });
}

- (void)oe_windowDestroyed:(const void*)host {
  // Views destroys a closed window on a later turn. By then -oe_adoptBrowserView:
  // may have replaced it with a new host whose window is already up; the old
  // window's destruction must not drop the new one.
  if (_host && _host.get() != host) {
    return;
  }
  _window = nil;
  _host = nullptr;
}

- (void)close {
  if (_host) {
    CefRefPtr<OEDockWindowDelegate> host = _host;
    _host = nullptr;
    host->Close();
  }
}

- (void)oe_hostWindowChanged:(NSNotification*)note {
  [self oe_sync];
}

// Keeps the DevTools window over the dock view (hidden with it).
- (void)oe_sync {
  NSWindow* host = _view.window;
  if (host != _observedWindow) {
    NSNotificationCenter* nc = NSNotificationCenter.defaultCenter;
    if (_observedWindow) {
      [nc removeObserver:self name:nil object:_observedWindow];
    }
    for (NSNotificationName name in @[
           NSWindowDidMoveNotification, NSWindowDidResizeNotification,
           NSWindowDidEndLiveResizeNotification
         ]) {
      if (host) {
        [nc addObserver:self
               selector:@selector(oe_hostWindowChanged:)
                   name:name
                 object:host];
      }
    }
    _observedWindow = host;
  }
  NSWindow* child = _window;
  if (!child) {
    return;
  }
  if (!host || _view.isHiddenOrHasHiddenAncestor) {
    if (child.parentWindow) {
      [child.parentWindow removeChildWindow:child];
    }
    [child orderOut:nil];
    return;
  }
  NSRect onScreen =
      [host convertRectToScreen:[_view convertRect:_view.bounds toView:nil]];
  if (child.parentWindow != host) {
    [child.parentWindow removeChildWindow:child];
    [host addChildWindow:child ordered:NSWindowAbove];
  }
  if (!NSEqualRects(child.frame, onScreen)) {
    [child setFrame:onScreen display:YES];
  }
  if (!child.isVisible) {
    [child orderWindow:NSWindowAbove relativeTo:host.windowNumber];
  }
}

- (void)dealloc {
  [NSNotificationCenter.defaultCenter removeObserver:self];
}

@end
