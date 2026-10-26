// OEBrowser: one shell window's tab strip (per profile) and its extension
// actions.
//
// Fork patch P1 (docs/engine-patches.md): each OEBrowser owns a CefTabStrip,
// one hidden Chrome Browser + TabStripModel with no Views. Chrome style
// contents inserted here become its tabs, hosted in our views, so
// chrome.tabs and chrome.windows see the shell's tabs. The shell owns order,
// pinning, and selection; this class mirrors them into the strip, and turns
// Chromium's own tab changes into delegate requests. P2 replaces the
// manifest-based actions and the URL-loaded popup with Chrome's
// ToolbarActionsModel and a real ExtensionViewHost popup.

#import "OEClient.h"

#include "include/internal/cef_types_mac.h"

@interface OEBrowser ()
- (void)oe_prepareChromiumTabClient:(CefRefPtr<CefClient>&)client
                           settings:(CefBrowserSettings&)settings
                          extraInfo:(CefRefPtr<CefDictionaryValue>&)extraInfo;
- (void)oe_chromiumTabCreated:(CefRefPtr<CefBrowser>)browser
                       active:(BOOL)active;
- (void)oe_activationRequested:(CefRefPtr<CefBrowser>)browser;
- (void)oe_moveRequested:(CefRefPtr<CefBrowser>)browser toStripIndex:(int)index;
- (void)oe_pinRequested:(CefRefPtr<CefBrowser>)browser pinned:(BOOL)pinned;
- (BOOL)oe_discardRequested:(CefRefPtr<CefBrowser>)browser;
- (void)oe_closeRequested;
+ (void)oe_markPagesClosingForBrowser:(NSInteger)identifier;
@end

namespace {

// Chrome's popup size limits (extension_popup.h: kMinWidth/kMinHeight,
// kMaxWidth/kMaxHeight).
constexpr NSSize kPopupMinSize = {25, 25};
constexpr NSSize kPopupMaxSize = {800, 600};

NSInteger gNextBrowserIdentifier = 1;

// Chromium's tab requests, on the browser UI thread (our main thread).
class OETabStripHandler : public CefTabStripHandler {
 public:
  explicit OETabStripHandler(OEBrowser* browser) : browser_(browser) {}

  void OnBeforeTabCreated(CefRefPtr<CefTabStrip> tab_strip,
                          const CefString& target_url,
                          CefRefPtr<CefClient>& client,
                          CefBrowserSettings& settings,
                          CefRefPtr<CefDictionaryValue>& extra_info) override {
    [browser_ oe_prepareChromiumTabClient:client
                                 settings:settings
                                extraInfo:extra_info];
  }
  void OnTabCreated(CefRefPtr<CefTabStrip> tab_strip,
                    CefRefPtr<CefBrowser> browser,
                    int index,
                    bool active) override {
    [browser_ oe_chromiumTabCreated:browser active:active];
  }
  void OnTabActivateRequested(CefRefPtr<CefTabStrip> tab_strip,
                              CefRefPtr<CefBrowser> browser) override {
    [browser_ oe_activationRequested:browser];
  }
  void OnTabMoveRequested(CefRefPtr<CefTabStrip> tab_strip,
                          CefRefPtr<CefBrowser> browser,
                          int index) override {
    [browser_ oe_moveRequested:browser toStripIndex:index];
  }
  void OnTabPinRequested(CefRefPtr<CefTabStrip> tab_strip,
                         CefRefPtr<CefBrowser> browser,
                         bool pinned) override {
    [browser_ oe_pinRequested:browser pinned:pinned];
  }
  bool OnTabDiscardRequested(CefRefPtr<CefTabStrip> tab_strip,
                             CefRefPtr<CefBrowser> browser) override {
    return [browser_ oe_discardRequested:browser];
  }
  void OnCloseRequested(CefRefPtr<CefTabStrip> tab_strip) override {
    [browser_ oe_closeRequested];
  }
  void OnExtensionActionUpdated(CefRefPtr<CefTabStrip> tab_strip,
                                const CefString& extension_id) override {
    [browser_ oe_extensionsChanged];
  }

 private:
  __weak OEBrowser* browser_;
  IMPLEMENT_REFCOUNTING(OETabStripHandler);
};

}  // namespace

@implementation OEBrowser {
  NSMutableArray<OEWebContent*>* _tabs;
  NSHashTable<OEWebContent*>* _pinned;
  NSArray<OEExtensionAction*>* _actions;
  OEWebContent* _popup;
  OEExtensionAction* _popupAction;
  // Fork patch P1.
  CefRefPtr<CefTabStrip> _strip;
  // Pages Chromium is creating in the strip, until OnTabCreated.
  NSMutableArray<OEWebContent*>* _chromiumTabs;
  BOOL _stripSyncScheduled;
  // Action state is per tab: refresh it once the strip's active tab is set.
  BOOL _actionsNeedRefresh;
  BOOL _stripRefused;
  BOOL _closed;
}

@synthesize window = _window;

- (instancetype)initWithContext:(OEBrowserContext*)context {
  if ((self = [super init])) {
    _identifier = gNextBrowserIdentifier++;
    _context = context;
    _tabs = [NSMutableArray array];
    _pinned = [NSHashTable weakObjectsHashTable];
    _chromiumTabs = [NSMutableArray array];
    [[OEEngine shared] oe_registerBrowser:self];
  }
  return self;
}

- (void)dealloc {
  if (_strip) {
    [OEBrowser oe_markPagesClosingForBrowser:_identifier];
    _strip->Close();
  }
}

- (NSString*)description {
  return [NSString stringWithFormat:@"<OEBrowser %ld tabs=%lu>",
                                    (long)_identifier,
                                    (unsigned long)_tabs.count];
}

- (void)setWindow:(NSWindow*)window {
  _window = window;
  if (_strip) {
    _strip->SetHostView(CAST_NSVIEW_TO_CEF_WINDOW_HANDLE(window.contentView));
  }
}

- (NSInteger)chromeWindowIdentifier {
  return _strip ? _strip->GetWindowId() : -1;
}

#pragma mark Tab strip

- (NSArray<OEWebContent*>*)webContents {
  return [_tabs copy];
}

- (void)insertWebContent:(OEWebContent*)webContent atIndex:(NSUInteger)index {
  // A page belongs to its context's browsers, and a hosted tab to the
  // hidden Chrome window it lives in: neither can join another one.
  if (webContent.context != _context ||
      (webContent.oe_hostBrowser && webContent.oe_hostBrowser != self)) {
    NSLog(@"OEBrowser: refused to insert a page of another %@",
          webContent.context != _context ? @"profile" : @"window");
    return;
  }
  OEBrowser* old = webContent.oe_tabStrip;
  if (old && old != self) {
    [old removeWebContent:webContent];
  }
  NSUInteger current = [_tabs indexOfObjectIdenticalTo:webContent];
  NSUInteger target = MIN(index, _tabs.count - (current == NSNotFound ? 0 : 1));
  if (current != target) {
    if (current != NSNotFound) {
      [_tabs removeObjectAtIndex:current];
    }
    [_tabs insertObject:webContent atIndex:target];
    [self oe_setNeedsTabStripSync];
  }
  webContent.oe_tabStrip = self;
}

- (void)removeWebContent:(OEWebContent*)webContent {
  if (![_tabs containsObject:webContent]) {
    return;
  }
  [_tabs removeObject:webContent];
  [_pinned removeObject:webContent];
  if (webContent.oe_tabStrip == self) {
    webContent.oe_tabStrip = nil;
  }
  if (_activeWebContent == webContent) {
    _activeWebContent = nil;
  }
}

- (void)moveWebContent:(OEWebContent*)webContent toIndex:(NSUInteger)index {
  NSUInteger current = [_tabs indexOfObjectIdenticalTo:webContent];
  if (current == NSNotFound) {
    return;
  }
  [_tabs removeObjectAtIndex:current];
  [_tabs insertObject:webContent atIndex:MIN(index, _tabs.count)];
  [self oe_setNeedsTabStripSync];
}

- (void)setPinned:(BOOL)pinned forWebContent:(OEWebContent*)webContent {
  if (pinned == [_pinned containsObject:webContent]) {
    return;
  }
  if (pinned) {
    [_pinned addObject:webContent];
  } else {
    [_pinned removeObject:webContent];
  }
  [self oe_setNeedsTabStripSync];
}

- (BOOL)isPinnedWebContent:(OEWebContent*)webContent {
  return [_pinned containsObject:webContent];
}

- (void)setActiveWebContent:(OEWebContent*)activeWebContent {
  if (activeWebContent && ![_tabs containsObject:activeWebContent]) {
    return;
  }
  if (_activeWebContent == activeWebContent) {
    return;
  }
  _activeWebContent = activeWebContent;
  if (_strip) {
    // Action state (badge, title) is per tab: oe_syncTabStrip reports it
    // once Chromium's active tab matches.
    _actionsNeedRefresh = YES;
  }
  [self oe_setNeedsTabStripSync];
}

- (void)oe_webContentClosed:(OEWebContent*)webContent {
  if (webContent == _popup) {
    [self oe_finishPopup];
    return;
  }
  [_chromiumTabs removeObject:webContent];
  [self removeWebContent:webContent];
}

- (void)close {
  [self closeExtensionPopup];
  for (OEWebContent* content in [_tabs copy]) {
    [self removeWebContent:content];
  }
  for (OEWebContent* content in [_chromiumTabs copy]) {
    [content close];
  }
  _closed = YES;
  if (_strip) {
    // The hidden window closes its remaining tabs; those are not closes the
    // pages asked for.
    [OEBrowser oe_markPagesClosingForBrowser:_identifier];
    _strip->Close();
    _strip = nullptr;
  }
}

+ (void)oe_markPagesClosingForBrowser:(NSInteger)identifier {
  for (OEWebContent* content in [OEEngine shared].allWebContents) {
    if (content.oe_hostBrowserIdentifier == identifier) {
      content.oe_client->SetClosing();
    }
  }
}

#pragma mark Hidden Chrome window (fork patch P1)

- (CefRefPtr<CefTabStrip>)oe_tabStripCreatingIfNeeded:(BOOL)create {
  if (!_strip && create && !_closed && !_stripRefused) {
    _strip = CefTabStrip::Create(_context.oe_requestContext,
                                 new OETabStripHandler(self));
    if (_strip) {
      _strip->SetHostView(
          CAST_NSVIEW_TO_CEF_WINDOW_HANDLE(_window.contentView));
    } else {
      // Pages wait for their context before they get here, so this is the
      // engine refusing the context, not a context that is not ready.
      _stripRefused = YES;
    }
  }
  return _strip;
}

- (BOOL)oe_canHostTabs {
  return !_stripRefused;
}

- (void)oe_setNeedsTabStripSync {
  if (!_strip || _stripSyncScheduled) {
    return;
  }
  _stripSyncScheduled = YES;
  __weak OEBrowser* weakSelf = self;
  dispatch_async(dispatch_get_main_queue(), ^{
    [weakSelf oe_syncTabStrip];
  });
}

// Puts the strip in -webContents order. Chrome keeps pinned tabs first; the
// shell orders favorites and pinned tabs first anyway. Tabs the shell has not
// placed (sized popups in panels) stay after these.
- (void)oe_syncTabStrip {
  _stripSyncScheduled = NO;
  if (!_strip) {
    return;
  }
  NSMutableArray<OEWebContent*>* pinned = [NSMutableArray array];
  NSMutableArray<OEWebContent*>* unpinned = [NSMutableArray array];
  for (OEWebContent* content in _tabs) {
    if (content.oe_hostBrowser == self && content.oe_browser) {
      [([_pinned containsObject:content] ? pinned : unpinned)
          addObject:content];
    }
  }
  int index = 0;
  for (OEWebContent* content in [pinned arrayByAddingObjectsFromArray:unpinned]) {
    _strip->UpdateTab(content.oe_browser, index++,
                      [_pinned containsObject:content]);
  }
  OEWebContent* active = _activeWebContent;
  if (active.oe_hostBrowser == self && active.oe_browser) {
    _strip->ActivateTab(active.oe_browser);
  }
  if (_actionsNeedRefresh) {
    _actionsNeedRefresh = NO;
    [self oe_extensionsChanged];
  }
}

- (nullable OEWebContent*)oe_contentForBrowser:(CefRefPtr<CefBrowser>)browser {
  return browser ? [[OEEngine shared]
                       webContentWithIdentifier:browser->GetIdentifier()]
                 : nil;
}

- (void)oe_prepareChromiumTabClient:(CefRefPtr<CefClient>&)client
                           settings:(CefBrowserSettings&)settings
                          extraInfo:(CefRefPtr<CefDictionaryValue>&)extraInfo {
  OEWebContent* content =
      [[OEWebContent alloc] initOEForChromiumTabInBrowser:self];
  [_chromiumTabs addObject:content];
  client = content.oe_client.get();
  settings = [content oe_browserSettings];
  extraInfo = [content oe_extraInfo];
}

- (void)oe_chromiumTabCreated:(CefRefPtr<CefBrowser>)browser
                       active:(BOOL)active {
  OEWebContent* content = nil;
  for (OEWebContent* candidate in _chromiumTabs) {
    if (candidate.oe_browser && candidate.oe_browser->IsSame(browser)) {
      content = candidate;
      break;
    }
  }
  if (!content) {
    return;
  }
  [_chromiumTabs removeObject:content];
  if ([_delegate respondsToSelector:@selector(browser:
                                        didOpenWebContent:active:)]) {
    [_delegate browser:self didOpenWebContent:content active:active];
  } else {
    [content close];
  }
  [self oe_setNeedsTabStripSync];
}

- (void)oe_activationRequested:(CefRefPtr<CefBrowser>)browser {
  OEWebContent* content = [self oe_contentForBrowser:browser];
  if (content && [_tabs containsObject:content]) {
    if ([_delegate respondsToSelector:@selector(browser:
                                          requestsActivationOfWebContent:)]) {
      [_delegate browser:self requestsActivationOfWebContent:content];
    } else {
      self.activeWebContent = content;
    }
  }
  // Put back whatever the shell decided.
  [self oe_setNeedsTabStripSync];
}

- (void)oe_moveRequested:(CefRefPtr<CefBrowser>)browser
            toStripIndex:(int)index {
  OEWebContent* content = [self oe_contentForBrowser:browser];
  if (content && [_tabs containsObject:content]) {
    // Chromium already moved the tab: place it before the tab that now
    // follows it in the strip, else after the one before it.
    OEWebContent* next = [self oe_contentForBrowser:_strip->GetTabAt(index + 1)];
    OEWebContent* previous =
        index > 0 ? [self oe_contentForBrowser:_strip->GetTabAt(index - 1)]
                  : nil;
    NSMutableArray* others = [_tabs mutableCopy];
    [others removeObjectIdenticalTo:content];
    NSUInteger target = others.count;
    if (next && [others indexOfObjectIdenticalTo:next] != NSNotFound) {
      target = [others indexOfObjectIdenticalTo:next];
    } else if (previous &&
               [others indexOfObjectIdenticalTo:previous] != NSNotFound) {
      target = [others indexOfObjectIdenticalTo:previous] + 1;
    }
    if ([_delegate respondsToSelector:@selector(browser:
                                          requestsMoveOfWebContent:toIndex:)]) {
      [_delegate browser:self
          requestsMoveOfWebContent:content
                           toIndex:target];
    } else {
      [self moveWebContent:content toIndex:target];
    }
  }
  [self oe_setNeedsTabStripSync];
}

- (void)oe_pinRequested:(CefRefPtr<CefBrowser>)browser pinned:(BOOL)pinned {
  OEWebContent* content = [self oe_contentForBrowser:browser];
  if (content && [_tabs containsObject:content]) {
    if ([_delegate respondsToSelector:@selector(browser:
                                          requestsPinned:forWebContent:)]) {
      [_delegate browser:self requestsPinned:pinned forWebContent:content];
    } else {
      [self setPinned:pinned forWebContent:content];
    }
  }
  [self oe_setNeedsTabStripSync];
}

- (BOOL)oe_discardRequested:(CefRefPtr<CefBrowser>)browser {
  OEWebContent* content = [self oe_contentForBrowser:browser];
  return content && [_tabs containsObject:content] &&
         [_delegate respondsToSelector:@selector(browser:
                                           requestsDiscardOfWebContent:)] &&
         [_delegate browser:self requestsDiscardOfWebContent:content];
}

- (void)oe_closeRequested {
  if ([_delegate respondsToSelector:@selector(browserRequestsClose:)]) {
    [_delegate browserRequestsClose:self];
  } else {
    NSLog(@"OEBrowser %ld: refused a window close from Chromium",
          (long)_identifier);
  }
}

#pragma mark Extension actions

- (NSArray<OEExtensionAction*>*)extensionActions {
  if (!_actions) {
    NSMutableArray* actions = [NSMutableArray array];
    for (OEExtension* extension in _context.extensions.installedExtensions) {
      if (extension.enabled && extension.oe_hasAction) {
        OEExtensionAction* action =
            [[OEExtensionAction alloc] initOEWithExtension:extension];
        if (_strip) {
          // Live state from Chrome's action model for the active tab (P1).
          CefString identifier = OECef(extension.identifier);
          cef_color_t color = _strip->GetExtensionActionBadgeColor(identifier);
          NSColor* badgeColor =
              CefColorGetA(color)
                  ? [NSColor colorWithSRGBRed:CefColorGetR(color) / 255.0
                                        green:CefColorGetG(color) / 255.0
                                         blue:CefColorGetB(color) / 255.0
                                        alpha:CefColorGetA(color) / 255.0]
                  : nil;
          [action
              oe_applyBadgeText:OEString(
                                    _strip->GetExtensionActionBadgeText(identifier))
                     badgeColor:badgeColor
                          title:OEString(_strip->GetExtensionActionTitle(identifier))
                        enabled:_strip->IsExtensionActionEnabled(identifier)];
        }
        [actions addObject:action];
      }
    }
    _actions = actions;
  }
  return _actions;
}

- (void)oe_extensionsChanged {
  _actions = nil;
  if ([_delegate respondsToSelector:@selector
                 (browserDidUpdateExtensionActions:)]) {
    [_delegate browserDidUpdateExtensionActions:self];
  }
}

- (BOOL)executeExtensionAction:(NSString*)extensionIdentifier {
  OEExtensionAction* action = nil;
  for (OEExtensionAction* a in self.extensionActions) {
    if ([a.extensionIdentifier isEqualToString:extensionIdentifier]) {
      action = a;
      break;
    }
  }
  if (!action || !action.enabled || !action.hasPopup) {
    // Popup-less actions dispatch chrome.action.onClicked inside Chrome's
    // ExtensionActionViewModel, which stock CEF does not expose (patch P2).
    return NO;
  }
  // Like Chrome: clicking the action of the open popup closes it.
  BOOL toggleOff = _popup &&
                   [_popupAction.extensionIdentifier
                       isEqualToString:extensionIdentifier];
  [self closeExtensionPopup];
  if (toggleOff) {
    return YES;
  }
  // Stock CEF: load the popup page in a plain web content. It renders and
  // runs, but Chromium sees a tab, not an ExtensionViewHost popup, so
  // chrome.tabs.query({active: true, currentWindow: true}) inside it does not
  // return the page the user is looking at (patch P2).
  OEWebContentConfiguration* config =
      [[OEWebContentConfiguration alloc] initWithContext:_context];
  // Alloy until patch P2: a Chrome style popup would get its own Views
  // window. Its chrome.tabs calls see this window as the current window
  // (the most recently active Chrome window of the profile, P1).
  config.runtimeStyle = OERuntimeStyleAlloy;
  OEWebContent* popup = [[OEWebContent alloc] initWithConfiguration:config
                                                                URL:action.popupURL];
  popup.oe_popupOwner = self;
  popup.oe_popupExtension = extensionIdentifier;
  [popup enableAutoResizeWithMinimumSize:kPopupMinSize
                             maximumSize:kPopupMaxSize];
  _popup = popup;
  _popupAction = action;
  if ([_delegate respondsToSelector:@selector
                 (browser:didOpenExtensionPopup:forAction:)]) {
    [_delegate browser:self didOpenExtensionPopup:popup forAction:action];
  }
  return YES;
}

- (nullable OEWebContent*)extensionPopup {
  return _popup;
}

- (void)closeExtensionPopup {
  OEWebContent* popup = _popup;
  if (!popup) {
    return;
  }
  [popup close];  // -> oe_webContentClosed: is not called: no tab strip.
  [self oe_finishPopup];
}

- (void)oe_finishPopup {
  OEWebContent* popup = _popup;
  if (!popup) {
    return;
  }
  _popup = nil;
  _popupAction = nil;
  popup.oe_popupOwner = nil;
  if ([_delegate respondsToSelector:@selector(browser:didCloseExtensionPopup:)]) {
    [_delegate browser:self didCloseExtensionPopup:popup];
  }
}

- (void)oe_popupDidResize:(OEWebContent*)popup size:(NSSize)size {
  if (popup != _popup) {
    return;
  }
  NSSize clamped = NSMakeSize(
      MIN(MAX(size.width, kPopupMinSize.width), kPopupMaxSize.width),
      MIN(MAX(size.height, kPopupMinSize.height), kPopupMaxSize.height));
  if ([_delegate respondsToSelector:@selector
                 (browser:didResizeExtensionPopup:toSize:)]) {
    [_delegate browser:self didResizeExtensionPopup:popup toSize:clamped];
  }
}

- (void)oe_popupRequestedClose:(OEWebContent*)popup {
  if (popup == _popup) {
    [self closeExtensionPopup];
  }
}

@end
