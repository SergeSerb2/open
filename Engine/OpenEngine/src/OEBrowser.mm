// OEBrowser: one shell window's tab strip (per profile) and its extension
// actions.
//
// Fork patch P1 (docs/engine-patches.md): each OEBrowser owns a CefTabStrip,
// one hidden Chrome Browser + TabStripModel with no Views. Chrome style
// contents inserted here become its tabs, hosted in our views, so
// chrome.tabs and chrome.windows see the shell's tabs. The shell owns order,
// pinning, and selection; this class mirrors them into the strip, and turns
// Chromium's own tab changes into delegate requests. P2 adds Chrome's
// ToolbarActionsModel (the window's extension actions) and real
// ExtensionViewHost popups.

#import "OEClient.h"

#include <functional>
#include <limits>
#include <string_view>

#include "include/internal/cef_types_mac.h"

@interface OEOmniboxSuggestion ()
- (instancetype)initOEWithRow:(CefRefPtr<CefDictionaryValue>)row;
@end

@implementation OEOmniboxSuggestion
- (instancetype)initOEWithRow:(CefRefPtr<CefDictionaryValue>)row {
  if ((self = [super init])) {
    _content = OEString(row->GetString("content"));
    _descriptionText = OEString(row->GetString("description"));
    _deletable = row->GetBool("deletable");
    auto ranges = [&](const char* key) -> NSArray<NSValue*>* {
      NSMutableArray* result = [NSMutableArray array];
      auto list = row->GetList(key);
      for (size_t i = 0; list && i < MIN(list->GetSize(), size_t(256)); ++i) {
        auto range = list->GetDictionary(i);
        if (!range) continue;
        int location = range->GetInt("location"), length = range->GetInt("length");
        if (location >= 0 && length >= 0 && size_t(location) + size_t(length) <= _descriptionText.length)
          [result addObject:[NSValue valueWithRange:NSMakeRange(location, length)]];
      }
      return result;
    };
    _matchRanges = ranges("match"); _dimRanges = ranges("dim"); _urlRanges = ranges("url");
  }
  return self;
}
@end

@interface OEBrowser ()
- (void)oe_extensionWindowCreated:(CefRefPtr<CefTabStrip>)strip
                             frame:(NSRect)frame extension:(NSString*)identifier;
- (void)oe_extensionWindowFrame:(NSRect)frame focused:(BOOL)focused;
- (void)oe_omniboxSuggestions:(CefRefPtr<CefListValue>)rows request:(int)request;
- (void)oe_omniboxDefaultChanged:(NSString*)identifier;
- (void)oe_prepareChromiumTabClient:(CefRefPtr<CefClient>&)client
                           settings:(CefBrowserSettings&)settings
                          extraInfo:(CefRefPtr<CefDictionaryValue>&)extraInfo;
- (void)oe_chromiumTabCreated:(CefRefPtr<CefBrowser>)browser
                       active:(BOOL)active;
- (void)oe_activationRequested:(CefRefPtr<CefBrowser>)browser;
- (void)oe_moveRequested:(CefRefPtr<CefBrowser>)browser
                previous:(CefRefPtr<CefBrowser>)previous next:(CefRefPtr<CefBrowser>)next;
- (void)oe_pinRequested:(CefRefPtr<CefBrowser>)browser pinned:(BOOL)pinned;
- (BOOL)oe_discardRequested:(CefRefPtr<CefBrowser>)browser;
- (void)oe_closeRequested;
- (void)oe_extensionActionUpdated:(NSString*)identifier;
- (void)oe_preparePopupClient:(CefRefPtr<CefClient>&)client
                     settings:(CefBrowserSettings&)settings
                    extraInfo:(CefRefPtr<CefDictionaryValue>&)extraInfo
                    extension:(NSString*)identifier;
- (void)oe_extensionPopupOpened:(CefRefPtr<CefBrowser>)browser
                      extension:(NSString*)identifier
                         source:(int)source;
- (void)oe_extensionPopupResized:(CefRefPtr<CefBrowser>)browser
                            size:(NSSize)size;
- (void)oe_extensionPopupReady:(CefRefPtr<CefBrowser>)browser;
- (void)oe_extensionPopupClosed:(CefRefPtr<CefBrowser>)browser;
- (void)oe_extensionActionMenuRequested:(NSString*)identifier;
- (BOOL)oe_runMenu:(int)menu command:(NSInteger)command;
- (void)oe_releaseMenu:(int)menu;
+ (void)oe_markPagesClosingForBrowser:(NSInteger)identifier;
@end

namespace {

class OEOmniboxHandler : public CefOpenOmniboxHandler {
 public:
  explicit OEOmniboxHandler(OEBrowser* browser) : browser_(browser) {}
  void OnSuggestions(int request, CefRefPtr<CefListValue> rows) override {
    [browser_ oe_omniboxSuggestions:rows request:request];
  }
  void OnDefaultChanged(const CefString& id) override {
    [browser_ oe_omniboxDefaultChanged:OEString(id)];
  }
 private:
  __weak OEBrowser* browser_;
  IMPLEMENT_REFCOUNTING(OEOmniboxHandler);
};

// Chrome's popup size limits (extension_popup.h: kMinWidth/kMinHeight,
// kMaxWidth/kMaxHeight).
constexpr NSSize kPopupMinSize = {25, 25};
constexpr NSSize kPopupMaxSize = {800, 600};

NSInteger gNextBrowserIdentifier = 1;

// A CefImage (1x and 2x) as an NSImage of `points` square. Raw pixels, no
// PNG encode and decode. `cache` keeps the last image per `key`: an
// unchanged image (most updates: a tab switch, a badge on another action)
// costs two pixel copies and a hash, and returns the same NSImage.
NSImage* OEImageFromCef(CefRefPtr<CefImage> image,
                        CGFloat points,
                        NSString* key,
                        NSMutableDictionary<NSString*, NSArray*>* cache) {
  if (!image || image->IsEmpty()) {
    [cache removeObjectForKey:key];
    return nil;
  }
  NSMutableData* pixels[2] = {nil, nil};
  int widths[2] = {0, 0};
  int heights[2] = {0, 0};
  size_t hash = 0;
  for (int i = 0; i < 2; ++i) {
    CefRefPtr<CefBinaryValue> bitmap =
        image->GetAsBitmap(i ? 2.0f : 1.0f, CEF_COLOR_TYPE_RGBA_8888,
                           CEF_ALPHA_TYPE_PREMULTIPLIED, widths[i], heights[i]);
    if (!bitmap || !bitmap->GetSize() || widths[i] <= 0 || heights[i] <= 0 ||
        bitmap->GetSize() != size_t(widths[i]) * size_t(heights[i]) * 4) {
      continue;
    }
    pixels[i] = [NSMutableData dataWithLength:bitmap->GetSize()];
    bitmap->GetData(pixels[i].mutableBytes, pixels[i].length, 0);
    hash = hash * 31 + std::hash<std::string_view>()(std::string_view(
                           static_cast<const char*>(pixels[i].bytes),
                           pixels[i].length)) +
           size_t(widths[i]);
  }
  NSArray* cached = cache[key];
  if (cached && [cached[0] unsignedLongValue] == hash) {
    return cached[1];
  }
  NSImage* out = [[NSImage alloc] initWithSize:NSMakeSize(points, points)];
  CGColorSpaceRef sRGB = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  for (int i = 0; i < 2; ++i) {
    if (!pixels[i]) {
      continue;
    }
    CGContextRef context = CGBitmapContextCreate(
        pixels[i].mutableBytes, widths[i], heights[i], 8, size_t(widths[i]) * 4,
        sRGB, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGImageRef cgImage = context ? CGBitmapContextCreateImage(context) : nullptr;
    if (cgImage) {
      NSBitmapImageRep* rep = [[NSBitmapImageRep alloc] initWithCGImage:cgImage];
      rep.size = NSMakeSize(points, points);
      [out addRepresentation:rep];
      CGImageRelease(cgImage);
    }
    if (context) {
      CGContextRelease(context);
    }
  }
  CGColorSpaceRelease(sRGB);
  if (!out.representations.count) {
    [cache removeObjectForKey:key];
    return nil;
  }
  cache[key] = @[ @(hash), out ];
  return out;
}

NSArray<OEContextMenuItem*>* OEMenuItems(CefRefPtr<CefListValue> list) {
  NSMutableArray* items = [NSMutableArray array];
  for (size_t i = 0; list && i < list->GetSize(); ++i) {
    if (CefRefPtr<CefDictionaryValue> item = list->GetDictionary(i)) {
      [items addObject:[[OEContextMenuItem alloc] initOEWithDictionary:item]];
    }
  }
  return items;
}

// Chromium's tab requests, on the browser UI thread (our main thread).
class OETabStripHandler : public CefTabStripHandler {
 public:
  explicit OETabStripHandler(OEBrowser* browser) : browser_(browser) {}

  static NSRect CocoaFrame(const CefRect& frame) {
    if (frame.IsEmpty()) return NSZeroRect;
    return NSMakeRect(frame.x, NSScreen.screens.firstObject.frame.size.height - frame.y - frame.height,
                      frame.width, frame.height);
  }
  void OnExtensionWindowCreated(CefRefPtr<CefTabStrip> parent,
      CefRefPtr<CefTabStrip> window, const CefRect& frame,
      const CefString& extension) override {
    [browser_ oe_extensionWindowCreated:window frame:CocoaFrame(frame) extension:OEString(extension)];
  }
  void OnExtensionWindowFrameRequested(CefRefPtr<CefTabStrip> window,
      const CefRect& frame, bool focused) override {
    [browser_ oe_extensionWindowFrame:CocoaFrame(frame) focused:focused];
  }

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
                          int index, CefRefPtr<CefBrowser> previous,
                          CefRefPtr<CefBrowser> next) override {
    [browser_ oe_moveRequested:browser previous:previous next:next];
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
    [browser_ oe_extensionActionUpdated:OEString(extension_id)];
  }
  void OnExtensionActionsChanged(CefRefPtr<CefTabStrip> tab_strip) override {
    [browser_ oe_extensionsChanged];
  }
  void OnExtensionActionMenuRequested(CefRefPtr<CefTabStrip> tab_strip,
                                      const CefString& extension_id) override {
    [browser_ oe_extensionActionMenuRequested:OEString(extension_id)];
  }
  void OnBeforeExtensionPopupCreated(
      CefRefPtr<CefTabStrip> tab_strip,
      const CefString& extension_id,
      CefRefPtr<CefClient>& client,
      CefBrowserSettings& settings,
      CefRefPtr<CefDictionaryValue>& extra_info) override {
    [browser_ oe_preparePopupClient:client
                           settings:settings
                          extraInfo:extra_info
                          extension:OEString(extension_id)];
  }
  void OnExtensionPopupOpened(CefRefPtr<CefTabStrip> tab_strip,
                              CefRefPtr<CefBrowser> browser,
                              const CefString& extension_id,
                              int source) override {
    [browser_ oe_extensionPopupOpened:browser
                            extension:OEString(extension_id)
                               source:source];
  }
  void OnExtensionPopupResized(CefRefPtr<CefTabStrip> tab_strip,
                               CefRefPtr<CefBrowser> browser,
                               int width,
                               int height) override {
    [browser_ oe_extensionPopupResized:browser size:NSMakeSize(width, height)];
  }
  void OnExtensionPopupReady(CefRefPtr<CefTabStrip> tab_strip,
                             CefRefPtr<CefBrowser> browser) override {
    [browser_ oe_extensionPopupReady:browser];
  }
  void OnExtensionPopupClosed(CefRefPtr<CefTabStrip> tab_strip,
                              CefRefPtr<CefBrowser> browser) override {
    [browser_ oe_extensionPopupClosed:browser];
  }

 private:
  __weak OEBrowser* browser_;
  IMPLEMENT_REFCOUNTING(OETabStripHandler);
};

}  // namespace

@implementation OEBrowser {
  NSMutableArray<OEBrowser*>* _pendingExtensionWindows;
  __weak OEBrowser* _extensionWindowParent;
  NSString* _extensionWindowIdentifier;
  NSRect _extensionWindowFrame;
  BOOL _extensionWindowOpened;
  CefRefPtr<CefOpenOmnibox> _omnibox;
  void (^_omniboxCompletion)(NSArray<OEOmniboxSuggestion*>*);
  int _omniboxRequest;
  NSMutableArray<OEWebContent*>* _tabs;
  NSHashTable<OEWebContent*>* _pinned;
  NSArray<OEExtensionAction*>* _actions;
  // _actions came from the live model (extensionActionsReady at the time).
  BOOL _actionsLive;
  BOOL _actionsAwaitContext;
  // OEImageFromCef's cache: "<id>/<size>/<toolbar>" -> @[hash, NSImage].
  NSMutableDictionary<NSString*, NSArray*>* _actionImages;
  OEWebContent* _popup;
  OEExtensionAction* _popupAction;
  // P2: the page made for the popup Chromium is opening, until it opens.
  OEWebContent* _pendingPopup;
  OEExtensionPopupSource _popupSource;
  NSString* _popupExtension;
  NSUInteger _popupDelegateDepth;
  BOOL _popupCloseScheduled;
  // Fork patch P1.
  CefRefPtr<CefTabStrip> _strip;
  // Pages Chromium is creating in the strip, until OnTabCreated.
  NSMutableArray<OEWebContent*>* _chromiumTabs;
  NSMutableOrderedSet<OEWebContent*>* _shellMoves;
  BOOL _stripSyncScheduled;
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
    _shellMoves = [NSMutableOrderedSet orderedSet];
    _actionImages = [NSMutableDictionary dictionary];
    [[OEEngine shared] oe_registerBrowser:self];
  }
  return self;
}

- (void)dealloc {
  if (_omnibox) _omnibox->Close();
  if (_strip) {
    // The Browser leaves Chromium's collection before its asynchronous
    // deletion. Native key notifications during popup/window teardown must
    // not activate that unregistered Browser in the meantime.
    _strip->SetHostView(nullptr);
    // Without -close: close the popup first, as -close does. The handler's
    // weak reference to self is already nil, so no delegate calls follow.
    _strip->CloseExtensionPopup();
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

- (BOOL)transferWebContent:(OEWebContent*)webContent
              fromBrowser:(OEBrowser*)source atIndex:(NSUInteger)index {
  if (!source || source == self || _closed || source->_closed ||
      _context.oe_closing || index > _tabs.count ||
      _context != source.context || webContent.context != _context ||
      webContent.oe_hostBrowser != source || webContent.oe_tabStrip != source ||
      ![source->_tabs containsObject:webContent] ||
      [_tabs containsObject:webContent] || !webContent.oe_browser ||
      !webContent.oe_browser->IsValid() || webContent.oe_client->IsClosing() ||
      _popup || source->_popup || _pendingPopup || source->_pendingPopup) return NO;
  [source oe_syncTabStrip];
  [self oe_syncTabStrip];
  CefRefPtr<CefTabStrip> target = [self oe_tabStripCreatingIfNeeded:YES];
  if (!target) return NO;
  const BOOL pinned = [source isPinnedWebContent:webContent];
  const NSUInteger position = MIN(index, _tabs.count);
  // Only live hosted pages contribute to Chromium's strip index.
  int liveIndex = 0;
  for (NSUInteger i = 0; i < position; ++i) {
    OEWebContent* page = _tabs[i];
    if (page.oe_hostBrowser == self && page.oe_browser) ++liveIndex;
  }
  if (!target->TransferTab(webContent.oe_browser, liveIndex, pinned)) return NO;
  [source->_shellMoves removeObject:webContent];
  [source->_chromiumTabs removeObject:webContent];
  [source removeWebContent:webContent];
  [webContent oe_setHostBrowser:self];
  [_tabs insertObject:webContent atIndex:position];
  webContent.oe_tabStrip = self;
  if (pinned) [_pinned addObject:webContent];
  _actions = nil;
  source->_actions = nil;
  [source oe_setNeedsTabStripSync];
  [self oe_setNeedsTabStripSync];
  return YES;
}

- (void)moveWebContent:(OEWebContent*)webContent toIndex:(NSUInteger)index {
  NSUInteger current = [_tabs indexOfObjectIdenticalTo:webContent];
  if (current == NSNotFound) {
    return;
  }
  [_tabs removeObjectAtIndex:current];
  [_tabs insertObject:webContent atIndex:MIN(index, _tabs.count)];
  [_shellMoves addObject:webContent];
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
  // Invalidate only. Chromium sends the change event; a same-turn caller
  // (for example a focused-pane context menu) can already read fresh state.
  _actions = nil;
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
  OEBrowser* parent = _extensionWindowParent;
  _extensionWindowParent = nil;
  if (parent) [parent->_pendingExtensionWindows removeObjectIdenticalTo:self];
  for (OEBrowser* window in [_pendingExtensionWindows copy]) [window close];
  [_pendingExtensionWindows removeAllObjects];
  _omniboxCompletion = nil; _omniboxRequest = 0;
  if (_omnibox) { _omnibox->Close(); _omnibox = nullptr; }
  if (_popupDelegateDepth) {
    // Keep this browser alive until Chromium's popup callback unwinds too.
    dispatch_async(dispatch_get_main_queue(), ^{ [self close]; });
    return;
  }
  if (_strip) {
    _strip->SetHostView(nullptr);
  }
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
  if (!_context.oe_isReady || !_context.oe_requestContext) return nullptr;
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
  NSArray<OEWebContent*>* ordered = [pinned arrayByAddingObjectsFromArray:unpinned];
  // Preserve the model operation's identity: a move to the end must move that
  // page, rather than shift every neighbour forward and omit its onMoved event.
  for (OEWebContent* content in _shellMoves) {
    NSUInteger position = [ordered indexOfObjectIdenticalTo:content];
    if (position != NSNotFound)
      _strip->UpdateTab(content.oe_browser, (int)position, [_pinned containsObject:content]);
  }
  [_shellMoves removeAllObjects];
  int index = 0;
  for (OEWebContent* content in ordered) {
    _strip->UpdateTab(content.oe_browser, index++,
                      [_pinned containsObject:content]);
  }
  OEWebContent* active = _activeWebContent;
  if (active.oe_hostBrowser == self && active.oe_browser) {
    _strip->ActivateTab(active.oe_browser);
  }
}

- (BOOL)oe_isChromiumActiveTab:(OEWebContent*)content {
  if (!_strip || content.oe_hostBrowser != self || !content.oe_browser) {
    return NO;
  }
  if (_stripSyncScheduled) {
    // The scheduled block still runs later; a second sync is idempotent.
    [self oe_syncTabStrip];
  }
  int index = _strip->GetActiveIndex();
  CefRefPtr<CefBrowser> active =
      index >= 0 && index < _strip->GetTabCount() ? _strip->GetTabAt(index)
                                                  : nullptr;
  return active && active->IsSame(content.oe_browser);
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
  if (_extensionWindowIdentifier) {
    [self insertWebContent:content atIndex:_tabs.count];
    self.activeWebContent = content;
    if (!_extensionWindowOpened) {
      _extensionWindowOpened = YES;
      OEBrowser* retainedSelf = self;
      OEBrowser* parent = _extensionWindowParent;
      if (parent) [parent->_pendingExtensionWindows removeObjectIdenticalTo:retainedSelf];
      _extensionWindowParent = nil;
      OEEngine* engine = OEEngine.shared;
      if ([engine.delegate respondsToSelector:@selector(engine:didOpenExtensionWindow:content:requestedFrame:extension:)]) {
        [engine.delegate engine:engine didOpenExtensionWindow:retainedSelf content:content
                 requestedFrame:_extensionWindowFrame extension:_extensionWindowIdentifier];
      } else { [self close]; }
    }
    return;
  }
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
                previous:(CefRefPtr<CefBrowser>)previousBrowser
                    next:(CefRefPtr<CefBrowser>)nextBrowser {
  OEWebContent* content = [self oe_contentForBrowser:browser];
  if (content && [_tabs containsObject:content]) {
    // Chromium already moved the tab: place it before the tab that now
    // follows it in the strip, else after the one before it.
    OEWebContent* next = [self oe_contentForBrowser:nextBrowser];
    OEWebContent* previous = [self oe_contentForBrowser:previousBrowser];
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
  if (_extensionWindowIdentifier) {
    OEWebContent* content = _tabs.firstObject;
    if ([content.delegate respondsToSelector:@selector(webContentDidRequestClose:)])
      [content.delegate webContentDidRequestClose:content];
    else [self close];
    return;
  }
  if ([_delegate respondsToSelector:@selector(browserRequestsClose:)]) {
    [_delegate browserRequestsClose:self];
  } else {
    NSLog(@"OEBrowser %ld: refused a window close from Chromium",
          (long)_identifier);
  }
}

- (void)oe_extensionWindowCreated:(CefRefPtr<CefTabStrip>)strip
                             frame:(NSRect)frame extension:(NSString*)identifier {
  OEBrowser* window = [[OEBrowser alloc] initWithContext:_context];
  window->_strip = strip;
  window->_extensionWindowIdentifier = [identifier copy];
  window->_extensionWindowFrame = frame;
  window->_extensionWindowParent = self;
  strip->SetHandler(new OETabStripHandler(window));
  if (!_pendingExtensionWindows) _pendingExtensionWindows = [NSMutableArray array];
  [_pendingExtensionWindows addObject:window];
}

- (void)oe_extensionWindowFrame:(NSRect)frame focused:(BOOL)focused {
  if (!_extensionWindowIdentifier || _closed) return;
  if (!_extensionWindowOpened) { _extensionWindowFrame = frame; return; }
  OEEngine* engine = OEEngine.shared;
  if ([engine.delegate respondsToSelector:@selector(engine:extensionWindow:requestsFrame:focused:)])
    [engine.delegate engine:engine extensionWindow:self requestsFrame:frame focused:focused];
}

#pragma mark Extension actions

- (BOOL)extensionActionsReady {
  return _strip && _strip->AreExtensionActionsReady();
}

// P2: one action's snapshot from Chrome's toolbar action model (live), or
// from the profile's action list.
- (nullable OEExtensionAction*)oe_engineActionFor:(NSString*)identifier {
  CefString cid = OECef(identifier);
  CefRefPtr<CefDictionaryValue> state = _strip->GetExtensionActionState(cid);
  if (!state) {
    return nil;
  }
  for (OEExtensionCommand* command in _context.extensions.commands) {
    if (command.actionCommand && [command.extensionIdentifier isEqualToString:identifier]) {
      state->SetString("shortcutKeyEquivalent", OECef(command.keyEquivalent));
      state->SetInt("shortcutModifierFlags", static_cast<int>(command.modifierFlags));
      break;
    }
  }
  NSString* key = [identifier stringByAppendingString:@"/"];
  return [[OEExtensionAction alloc]
      initOEWithIdentifier:identifier
                     state:state
              toolbarImage:OEImageFromCef(
                               _strip->GetExtensionActionImage(cid, 28, true),
                               28, [key stringByAppendingString:@"28/t"],
                               _actionImages)
                      icon:OEImageFromCef(
                               _strip->GetExtensionActionImage(cid, 16, false),
                               16, [key stringByAppendingString:@"16"],
                               _actionImages)];
}

- (NSArray<OEExtensionAction*>*)extensionActions {
  if (_closed || _context.state == OEBrowserContextStateClosed || _context.oe_closing) return @[];
  const BOOL live = self.extensionActionsReady;
  if (_actions && _actionsLive != live) {
    _actions = nil;
  }
  if (_actions) {
    return _actions;
  }
  // The profile's list needs the strip object (not its Chrome window), and
  // the strip needs a ready context.
  CefRefPtr<CefTabStrip> strip =
      [self oe_tabStripCreatingIfNeeded:_context.oe_isReady];
  if (strip) {
    std::vector<CefString> ids;
    strip->GetExtensionActionIds(ids);
    NSMutableArray* actions = [NSMutableArray array];
    for (const CefString& cid : ids) {
      if (OEExtensionAction* action = [self oe_engineActionFor:OEString(cid)]) {
        [actions addObject:action];
      }
    }
    // An empty profile list may only mean the profile's model is not
    // initialized yet: read it again next time.
    _actions = live || actions.count ? actions : nil;
    _actionsLive = live;
    return actions;
  }
  if (!_stripRefused) {
    // Not ready yet (or closed): nothing to show, and nothing cached.
    if (!_closed && !_actionsAwaitContext) {
      _actionsAwaitContext = YES;
      __weak OEBrowser* weakSelf = self;
      [_context oe_whenReady:^{
        OEBrowser* strongSelf = weakSelf;
        if (strongSelf) {
          strongSelf->_actionsAwaitContext = NO;
          [strongSelf oe_extensionsChanged];
        }
      }];
    }
    return @[];
  }
  // The engine refused this profile a Chrome window: the manifest list, for
  // display only. Nothing runs.
  NSMutableArray* actions = [NSMutableArray array];
  for (OEExtension* extension in _context.extensions.installedExtensions) {
    if (extension.enabled && extension.oe_hasAction) {
      [actions addObject:[[OEExtensionAction alloc]
                             initOEWithExtension:extension]];
    }
  }
  _actions = actions;
  _actionsLive = NO;
  return _actions;
}

- (void)oe_extensionsChanged {
  _actions = nil;
  if (!self.extensionActionsReady) {
    [_actionImages removeAllObjects];
  } else {
    std::vector<CefString> ids;
    _strip->GetExtensionActionIds(ids);
    NSMutableSet* live = [NSMutableSet set];
    for (const auto& id : ids) [live addObject:OEString(id)];
    for (NSString* id in _actionImages.allKeys) {
      if (![live containsObject:[id componentsSeparatedByString:@"/"].firstObject]) [_actionImages removeObjectForKey:id];
    }
  }
  if ([_delegate respondsToSelector:@selector
                 (browserDidUpdateExtensionActions:)]) {
    [_delegate browserDidUpdateExtensionActions:self];
  }
}

#pragma mark Extension omnibox

- (void)omniboxStartSessionForExtension:(NSString*)identifier {
  if (_closed || !_context.oe_isReady) return;
  if (!_omnibox) _omnibox = CefOpenOmnibox::Create(_context.oe_requestContext, new OEOmniboxHandler(self));
  if (_omnibox) _omnibox->Start(OECef(identifier));
}

- (BOOL)omniboxInputChanged:(NSString*)text forExtension:(NSString*)identifier
                 completion:(void (^)(NSArray<OEOmniboxSuggestion*>*))completion {
  _omniboxCompletion = nil; _omniboxRequest = 0;
  if (_closed || !_omnibox || text.length > 16384) return NO;
  _omniboxRequest = _omnibox->InputChanged(OECef(identifier), OECef(text));
  if (!_omniboxRequest) return NO;
  _omniboxCompletion = [completion copy];
  return YES;
}

- (nullable OEOmniboxSuggestion*)omniboxDefaultSuggestionForExtension:(NSString*)identifier {
  auto row = _omnibox ? _omnibox->GetDefault(OECef(identifier)) : nullptr;
  return row ? [[OEOmniboxSuggestion alloc] initOEWithRow:row] : nil;
}

- (void)omniboxInputEntered:(NSString*)text forExtension:(NSString*)identifier
                disposition:(OEOmniboxDisposition)disposition {
  _omniboxCompletion = nil; _omniboxRequest = 0;
  if (_stripSyncScheduled) [self oe_syncTabStrip];
  if (_omnibox && _activeWebContent.oe_browser)
    _omnibox->Enter(OECef(identifier), OECef(text), _activeWebContent.oe_browser, (int)disposition);
}

- (void)omniboxInputCancelledForExtension:(NSString*)identifier {
  _omniboxCompletion = nil; _omniboxRequest = 0;
  if (_omnibox) _omnibox->Cancel(OECef(identifier));
}

- (void)omniboxDeleteSuggestion:(NSString*)content forExtension:(NSString*)identifier {
  if (_omnibox) _omnibox->DeleteSuggestion(OECef(identifier), OECef(content));
}

- (void)oe_omniboxSuggestions:(CefRefPtr<CefListValue>)rows request:(int)request {
  if (_closed || request != _omniboxRequest || !_omniboxCompletion) return;
  auto completion = _omniboxCompletion;
  _omniboxCompletion = nil; _omniboxRequest = 0;
  NSMutableArray* result = [NSMutableArray array];
  for (size_t i = 0; rows && i < MIN(rows->GetSize(), size_t(4)); ++i) {
    if (auto row = rows->GetDictionary(i)) [result addObject:[[OEOmniboxSuggestion alloc] initOEWithRow:row]];
  }
  completion(result);
}

- (void)oe_omniboxDefaultChanged:(NSString*)identifier {
  if (!_closed && [_delegate respondsToSelector:@selector(browser:omniboxDefaultSuggestionDidChangeForExtension:)])
    [_delegate browser:self omniboxDefaultSuggestionDidChangeForExtension:identifier];
}

- (void)oe_extensionActionUpdated:(NSString*)identifier {
  NSUInteger index = [_actions indexOfObjectPassingTest:^BOOL(
                                   OEExtensionAction* a, NSUInteger i, BOOL* stop) {
    return [a.extensionIdentifier isEqualToString:identifier];
  }];
  OEExtensionAction* fresh =
      self.extensionActionsReady && _actions && index != NSNotFound
          ? [self oe_engineActionFor:identifier]
          : nil;
  if (!fresh || ![_delegate respondsToSelector:@selector
                            (browser:didUpdateExtensionAction:)]) {
    [self oe_extensionsChanged];
    return;
  }
  NSMutableArray* actions = [_actions mutableCopy];
  actions[index] = fresh;
  _actions = actions;
  if ([_popupAction.extensionIdentifier isEqualToString:identifier]) {
    _popupAction = fresh;
  }
  [_delegate browser:self didUpdateExtensionAction:fresh];
}

- (void)setExtensionAction:(NSString*)extensionIdentifier pinned:(BOOL)pinned {
  if (_strip) {
    _strip->SetExtensionActionPinned(OECef(extensionIdentifier), pinned);
  }
}

- (void)moveExtensionAction:(NSString*)extensionIdentifier
              toPinnedIndex:(NSUInteger)index {
  if (index > static_cast<NSUInteger>(std::numeric_limits<int>::max())) {
    NSLog(@"Open refused an extension move index outside the engine range");
    return;
  }
  if (_strip) {
    _strip->MoveExtensionAction(OECef(extensionIdentifier), (int)index);
  }
}

- (BOOL)executeExtensionCommand:(NSString*)name forExtension:(NSString*)identifier {
  if (_stripSyncScheduled) [self oe_syncTabStrip];
  for (OEExtensionCommand* command in _context.extensions.commands) {
    if ([command.extensionIdentifier isEqualToString:identifier] && [command.name isEqualToString:name]) {
      if (command.actionCommand) return [self executeExtensionAction:identifier source:OEExtensionActionSourceCommand];
      auto manager = _context.extensions.oe_manager;
      return manager && _activeWebContent.oe_browser && manager->ExecuteCommand(OECef(identifier), OECef(name), _activeWebContent.oe_browser);
    }
  }
  return NO;
}

- (BOOL)executeExtensionAction:(NSString*)extensionIdentifier
                        source:(OEExtensionActionSource)source {
  if (_stripSyncScheduled) {
    [self oe_syncTabStrip];
  }
  if (!self.extensionActionsReady) {
    // No live Chrome tab in this window: nothing can run. Never the
    // manifest popup in a plain page: extensions see a tab there, not their
    // popup (Bitwarden does not work, P1).
    return NO;
  }
  if (_popupDelegateDepth) {
    // Executing can toggle or replace the current popup. Neither may delete
    // the ExtensionViewHost while it is notifying us.
    BOOL known = NO;
    for (OEExtensionAction* action in self.extensionActions) {
      if ([action.extensionIdentifier isEqualToString:extensionIdentifier]) {
        known = YES;
        break;
      }
    }
    if (!known) {
      return NO;
    }
    NSString* identifier = [extensionIdentifier copy];
    OEWebContent* popup = _popup;
    const BOOL togglesPopup =
        popup && [_popupExtension isEqualToString:identifier];
    dispatch_async(dispatch_get_main_queue(), ^{
      if (!togglesPopup || self->_popup == popup) {
        [self executeExtensionAction:identifier source:source];
      }
    });
    return YES;
  }
  // Like Chrome's toolbar button: running the action whose popup is open
  // closes it.
  if (_popup && [_popupExtension isEqualToString:extensionIdentifier]) {
    [self closeExtensionPopup];
    return YES;
  }
  // Chrome's model: the popup, or chrome.action.onClicked.
  return _strip->ExecuteExtensionAction(OECef(extensionIdentifier),
                                        (int)source);
}

- (BOOL)executeExtensionAction:(NSString*)extensionIdentifier {
  return [self executeExtensionAction:extensionIdentifier
                               source:OEExtensionActionSourceToolbarButton];
}

- (nullable OEExtensionActionMenu*)
    contextMenuForExtensionAction:(NSString*)extensionIdentifier
                           source:(OEExtensionMenuSource)source {
  if (_stripSyncScheduled) {
    [self oe_syncTabStrip];
  }
  if (!self.extensionActionsReady) {
    return nil;
  }
  int menu = 0;
  CefRefPtr<CefListValue> list = _strip->GetExtensionActionMenu(
      OECef(extensionIdentifier), (int)source, menu);
  if (!list || !menu) {
    return nil;
  }
  return [[OEExtensionActionMenu alloc] initOEWithBrowser:self
                                                extension:extensionIdentifier
                                                     menu:menu
                                                    items:OEMenuItems(list)];
}

- (BOOL)oe_runMenu:(int)menu command:(NSInteger)command {
  return _strip && _strip->RunExtensionActionMenuCommand(menu, (int)command);
}

- (void)oe_releaseMenu:(int)menu {
  if (_strip) {
    _strip->ReleaseExtensionActionMenu(menu);
  }
}

- (void)oe_extensionActionMenuRequested:(NSString*)identifier {
  if ([_delegate respondsToSelector:@selector
                 (browser:requestsContextMenuForExtensionAction:)]) {
    [_delegate browser:self requestsContextMenuForExtensionAction:identifier];
  }
}

- (nullable OEWebContent*)extensionPopup {
  return _popup;
}

- (OEExtensionPopupSource)extensionPopupSource {
  return _popupSource;
}

- (nullable NSString*)extensionPopupExtensionIdentifier {
  return _popupExtension;
}

- (BOOL)extensionPopupStaysOpenOnBlur {
  return _popup && _strip && _strip->ExtensionPopupStaysOpenOnBlur();
}

- (void)closeExtensionPopup {
  OEWebContent* popup = _popup;
  if (!popup) {
    return;
  }
  if (_popupDelegateDepth) {
    if (!_popupCloseScheduled) {
      _popupCloseScheduled = YES;
      dispatch_async(dispatch_get_main_queue(), ^{
        self->_popupCloseScheduled = NO;
        // A request for an older popup must not close its replacement.
        if (self->_popup == popup) {
          [self closeExtensionPopup];
        }
      });
    }
    return;
  }
  // The engine closes the popup and reports the close.
  if (_strip) {
    _strip->CloseExtensionPopup();
  }
  if (_popup == popup) {
    [self oe_finishPopup];
  }
}

#pragma mark Chrome popups (fork patch P2)

- (void)oe_preparePopupClient:(CefRefPtr<CefClient>&)client
                     settings:(CefBrowserSettings&)settings
                    extraInfo:(CefRefPtr<CefDictionaryValue>&)extraInfo
                    extension:(NSString*)identifier {
  OEWebContent* content =
      [[OEWebContent alloc] initOEForExtensionPopupInBrowser:self
                                                   extension:identifier];
  _pendingPopup = content;
  // The engine reports the open in this same call. Still pending on the
  // next turn: the popup's browser failed, so drop the page.
  __weak OEBrowser* weakSelf = self;
  dispatch_async(dispatch_get_main_queue(), ^{
    OEBrowser* strongSelf = weakSelf;
    if (strongSelf && strongSelf->_pendingPopup == content) {
      strongSelf->_pendingPopup = nil;
      [content close];
    }
  });
  client = content.oe_client.get();
  settings = [content oe_browserSettings];
  extraInfo = [content oe_extraInfo];
}

- (void)oe_extensionPopupOpened:(CefRefPtr<CefBrowser>)browser
                      extension:(NSString*)identifier
                         source:(int)source {
  OEWebContent* content = _pendingPopup;
  _pendingPopup = nil;
  if (!content) {
    return;
  }
  if (_popup && _popup != content) {
    [self oe_finishPopup];
  }
  _popup = content;
  _popupSource = (OEExtensionPopupSource)source;
  _popupExtension = [identifier copy];
  OEExtensionAction* action = nil;
  for (OEExtensionAction* a in self.extensionActions) {
    if ([a.extensionIdentifier isEqualToString:identifier]) {
      action = a;
      break;
    }
  }
  _popupAction = action;
  if (action && [_delegate respondsToSelector:@selector
                           (browser:didOpenExtensionPopup:forAction:)]) {
    ++_popupDelegateDepth;
    [_delegate browser:self didOpenExtensionPopup:content forAction:action];
    --_popupDelegateDepth;
  }
}

- (BOOL)oe_isPopupBrowser:(CefRefPtr<CefBrowser>)browser {
  CefRefPtr<CefBrowser> own = _popup.oe_browser;
  return own && browser && own->IsSame(browser);
}

- (void)oe_extensionPopupResized:(CefRefPtr<CefBrowser>)browser
                            size:(NSSize)size {
  if ([self oe_isPopupBrowser:browser]) {
    [self oe_popupDidResize:_popup size:size];
  }
}

- (void)oe_extensionPopupReady:(CefRefPtr<CefBrowser>)browser {
  if ([self oe_isPopupBrowser:browser] &&
      [_delegate respondsToSelector:@selector(browser:extensionPopupIsReady:)]) {
    ++_popupDelegateDepth;
    [_delegate browser:self extensionPopupIsReady:_popup];
    --_popupDelegateDepth;
  }
}

- (void)oe_extensionPopupClosed:(CefRefPtr<CefBrowser>)browser {
  if (![self oe_isPopupBrowser:browser]) {
    return;
  }
  // The engine closes the page next; that is not a close the page asked for.
  _popup.oe_client->SetClosing();
  [self oe_finishPopup];
}

- (void)oe_finishPopup {
  OEWebContent* popup = _popup;
  if (!popup) {
    return;
  }
  _popup = nil;
  _popupAction = nil;
  _popupExtension = nil;
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
    ++_popupDelegateDepth;
    [_delegate browser:self didResizeExtensionPopup:popup toSize:clamped];
    --_popupDelegateDepth;
  }
}

- (void)oe_popupRequestedClose:(OEWebContent*)popup {
  if (popup == _popup) {
    [self closeExtensionPopup];
  }
}

@end

@implementation OEExtensionActionMenu {
  __weak OEBrowser* _browser;
  int _menu;
  BOOL _done;
}

- (instancetype)initOEWithBrowser:(OEBrowser*)browser
                        extension:(NSString*)extensionIdentifier
                             menu:(int)menu
                            items:(NSArray<OEContextMenuItem*>*)items {
  if ((self = [super init])) {
    _browser = browser;
    _extensionIdentifier = [extensionIdentifier copy];
    _menu = menu;
    _items = [items copy];
  }
  return self;
}

- (void)dealloc {
  [self cancel];
}

- (BOOL)selectCommand:(NSInteger)commandIdentifier {
  if (_done) {
    return NO;
  }
  _done = YES;
  OEBrowser* browser = _browser;
  return [browser oe_runMenu:_menu command:commandIdentifier];
}

- (void)cancel {
  if (_done) {
    return;
  }
  _done = YES;
  [_browser oe_releaseMenu:_menu];
}

@end
