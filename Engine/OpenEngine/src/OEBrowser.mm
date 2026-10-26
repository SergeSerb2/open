// OEBrowser: one shell window's tab strip and its extension actions.
//
// Stock CEF has no way to give Chromium's extension system a tab strip that
// is not a Chrome window, so here the tab strip is bookkeeping that the shell
// keeps exact. Fork patch P1 (docs/engine-patches.md) mirrors it into a
// hidden Chrome Browser/TabStripModel; P2 replaces the manifest-based actions
// and the URL-loaded popup with Chrome's ToolbarActionsModel and a real
// ExtensionViewHost popup.

#import "OEInternal.h"

namespace {

// Chrome's popup size limits (extension_popup.h: kMinWidth/kMinHeight,
// kMaxWidth/kMaxHeight).
constexpr NSSize kPopupMinSize = {25, 25};
constexpr NSSize kPopupMaxSize = {800, 600};

NSInteger gNextBrowserIdentifier = 1;

}  // namespace

@implementation OEBrowser {
  NSMutableArray<OEWebContent*>* _tabs;
  NSHashTable<OEWebContent*>* _pinned;
  NSArray<OEExtensionAction*>* _actions;
  OEWebContent* _popup;
  OEExtensionAction* _popupAction;
}

- (instancetype)initWithContext:(OEBrowserContext*)context {
  if ((self = [super init])) {
    _identifier = gNextBrowserIdentifier++;
    _context = context;
    _tabs = [NSMutableArray array];
    _pinned = [NSHashTable weakObjectsHashTable];
    [[OEEngine shared] oe_registerBrowser:self];
  }
  return self;
}

- (NSString*)description {
  return [NSString stringWithFormat:@"<OEBrowser %ld tabs=%lu>",
                                    (long)_identifier,
                                    (unsigned long)_tabs.count];
}

#pragma mark Tab strip

- (NSArray<OEWebContent*>*)webContents {
  return [_tabs copy];
}

- (void)insertWebContent:(OEWebContent*)webContent atIndex:(NSUInteger)index {
  OEBrowser* old = webContent.oe_tabStrip;
  if (old && old != self) {
    [old removeWebContent:webContent];
  }
  [_tabs removeObject:webContent];
  [_tabs insertObject:webContent atIndex:MIN(index, _tabs.count)];
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
  if (![_tabs containsObject:webContent]) {
    return;
  }
  [_tabs removeObject:webContent];
  [_tabs insertObject:webContent atIndex:MIN(index, _tabs.count)];
}

- (void)setPinned:(BOOL)pinned forWebContent:(OEWebContent*)webContent {
  if (pinned) {
    [_pinned addObject:webContent];
  } else {
    [_pinned removeObject:webContent];
  }
}

- (BOOL)isPinnedWebContent:(OEWebContent*)webContent {
  return [_pinned containsObject:webContent];
}

- (void)setActiveWebContent:(OEWebContent*)activeWebContent {
  if (activeWebContent && ![_tabs containsObject:activeWebContent]) {
    return;
  }
  _activeWebContent = activeWebContent;
}

- (void)oe_webContentClosed:(OEWebContent*)webContent {
  if (webContent == _popup) {
    [self oe_finishPopup];
    return;
  }
  [self removeWebContent:webContent];
}

- (void)close {
  [self closeExtensionPopup];
  for (OEWebContent* content in [_tabs copy]) {
    [self removeWebContent:content];
  }
}

#pragma mark Extension actions

- (NSArray<OEExtensionAction*>*)extensionActions {
  if (!_actions) {
    NSMutableArray* actions = [NSMutableArray array];
    for (OEExtension* extension in _context.extensions.installedExtensions) {
      if (extension.enabled && extension.oe_hasAction) {
        [actions addObject:[[OEExtensionAction alloc]
                               initOEWithExtension:extension]];
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
  config.runtimeStyle =
      _activeWebContent ? _activeWebContent.runtimeStyle : config.runtimeStyle;
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
