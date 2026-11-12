#import "OEInternal.h"

#include <set>

#include "include/cef_context_menu_handler.h"
#include "include/cef_jsdialog_handler.h"
#include "include/cef_menu_model.h"
#include "include/cef_permission_handler.h"

@implementation OEOpenRequest

- (instancetype)initOEWithURL:(NSURL*)url
                   disposition:(OEOpenDisposition)disposition
                   userGesture:(BOOL)userGesture
                requestedFrame:(NSRect)frame
               targetFrameName:(NSString*)targetFrameName
                        source:(OEWebContent*)source
                       context:(OEBrowserContext*)context {
  if ((self = [super init])) {
    _URL = [url copy];
    _disposition = disposition;
    _userGesture = userGesture;
    _requestedFrame = frame;
    _targetFrameName = [targetFrameName copy];
    _sourceWebContent = source;
    _context = context;
  }
  return self;
}

@end

@implementation OEJavaScriptDialog {
  CefRefPtr<CefJSDialogCallback> _callback;
}

- (instancetype)initOEWithKind:(OEJavaScriptDialogKind)kind
                        message:(NSString*)message
                  defaultPrompt:(NSString*)defaultPrompt
                         origin:(NSURL*)origin
                       isReload:(BOOL)isReload
                       callback:(CefRefPtr<CefJSDialogCallback>)callback {
  if ((self = [super init])) {
    _kind = kind;
    _message = [message copy];
    _defaultPromptText = [defaultPrompt copy];
    _originURL = [origin copy];
    _isReload = isReload;
    _callback = callback;
  }
  return self;
}

- (void)completeWithAccepted:(BOOL)accepted text:(NSString*)text {
  if (_callback) {
    _callback->Continue(accepted, OECef(text ?: @""));
    _callback = nullptr;
  }
}

- (void)dealloc {
  // An unanswered dialog would hang the page; treat it as cancelled.
  if (_callback) {
    _callback->Continue(false, CefString());
  }
}

@end

@implementation OEPermissionRequest {
  CefRefPtr<CefMediaAccessCallback> _media;
  uint32_t _mediaRequested;
  CefRefPtr<CefPermissionPromptCallback> _prompt;
}

- (instancetype)initOEWithOrigin:(NSURL*)origin
                            kinds:(OEPermissionKind)kinds
                    mediaCallback:(CefRefPtr<CefMediaAccessCallback>)media
                   mediaRequested:(uint32_t)mediaRequested
                   promptCallback:(CefRefPtr<CefPermissionPromptCallback>)prompt {
  if ((self = [super init])) {
    _origin = [origin copy];
    _kinds = kinds;
    _media = media;
    _mediaRequested = mediaRequested;
    _prompt = prompt;
  }
  return self;
}

- (void)oe_setProtocolHandlerScheme:(NSString*)scheme
                        urlTemplate:(NSString*)urlTemplate {
  _protocolHandlerScheme = [scheme copy];
  _protocolHandlerURLTemplate = [urlTemplate copy];
}

- (void)oe_finish:(cef_permission_request_result_t)result {
  if (_media) {
    if (result == CEF_PERMISSION_RESULT_ACCEPT) {
      _media->Continue(_mediaRequested);
    } else {
      _media->Cancel();
    }
    _media = nullptr;
  }
  if (_prompt) {
    _prompt->Continue(result);
    _prompt = nullptr;
  }
}

- (void)grant {
  [self oe_finish:CEF_PERMISSION_RESULT_ACCEPT];
}
- (void)deny {
  [self oe_finish:CEF_PERMISSION_RESULT_DENY];
}
- (void)dismiss {
  [self oe_finish:CEF_PERMISSION_RESULT_DISMISS];
}
- (void)dealloc {
  [self oe_finish:CEF_PERMISSION_RESULT_IGNORE];
}

@end

@interface OEContextMenuItem ()
- (instancetype)initOEWithModel:(CefRefPtr<CefMenuModel>)model
                           index:(size_t)index;
@end

@implementation OEContextMenuItem

// Chromium menu labels mark a mnemonic with "&" and write a literal "&" as
// "&&" (ui::RemoveAcceleratorChar). macOS menus have no mnemonics: keep the
// literal ones only ("Tom && Jerry" is "Tom & Jerry").
static NSString* OEMenuTitle(NSString* label) {
  if ([label rangeOfString:@"&"].location == NSNotFound) {
    return label;
  }
  NSMutableString* title = [NSMutableString stringWithCapacity:label.length];
  for (NSUInteger i = 0; i < label.length; ++i) {
    const unichar c = [label characterAtIndex:i];
    if (c != '&') {
      [title appendFormat:@"%C", c];
    } else if (i + 1 < label.length && [label characterAtIndex:i + 1] == '&') {
      [title appendString:@"&"];
      ++i;
    }
  }
  return title;
}

- (instancetype)initOEWithDictionary:(CefRefPtr<CefDictionaryValue>)item {
  if ((self = [super init])) {
    _separator = item->GetBool("separator");
    _commandIdentifier = item->GetInt("command");
    _title = OEMenuTitle(OEString(item->GetString("label")));
    _enabled = item->GetBool("enabled");
    _checked = item->GetBool("checked");
    NSMutableArray* sub = [NSMutableArray array];
    CefRefPtr<CefListValue> list =
        item->HasKey("submenu") ? item->GetList("submenu") : nullptr;
    for (size_t i = 0; list && i < list->GetSize(); ++i) {
      if (CefRefPtr<CefDictionaryValue> child = list->GetDictionary(i)) {
        [sub addObject:[[OEContextMenuItem alloc] initOEWithDictionary:child]];
      }
    }
    _submenu = sub;
  }
  return self;
}

- (instancetype)initOEWithModel:(CefRefPtr<CefMenuModel>)model
                           index:(size_t)index {
  if ((self = [super init])) {
    cef_menu_item_type_t type = model->GetTypeAt(index);
    _separator = type == MENUITEMTYPE_SEPARATOR;
    _commandIdentifier = model->GetCommandIdAt(index);
    _title = OEMenuTitle(OEString(model->GetLabelAt(index)));
    _enabled = model->IsEnabledAt(index);
    _checked = model->IsCheckedAt(index);
    NSMutableArray* sub = [NSMutableArray array];
    if (type == MENUITEMTYPE_SUBMENU) {
      CefRefPtr<CefMenuModel> submodel = model->GetSubMenuAt(index);
      for (size_t i = 0; submodel && i < submodel->GetCount(); ++i) {
        [sub addObject:[[OEContextMenuItem alloc] initOEWithModel:submodel
                                                             index:i]];
      }
    }
    _submenu = sub;
  }
  return self;
}

@end

@implementation OEContextMenu {
  CefRefPtr<CefRunContextMenuCallback> _callback;
  // The command ids of the delivered items (submenus included): the only
  // ids -selectCommand: runs. CEF would run any other id directly
  // (RenderViewContextMenu::ExecuteCommand checks neither visibility nor
  // enabled state), bypassing the allowlist.
  std::set<int> _commands;
}

static void OECollectCommands(NSArray<OEContextMenuItem*>* items,
                              std::set<int>* commands) {
  for (OEContextMenuItem* item in items) {
    if (item.isSeparator || !item.isEnabled) {
      continue;
    }
    if (item.submenu.count) {
      OECollectCommands(item.submenu, commands);
    } else {
      commands->insert((int)item.commandIdentifier);
    }
  }
}

- (instancetype)initOEWithParams:(CefRefPtr<CefContextMenuParams>)params
                            model:(CefRefPtr<CefMenuModel>)model
                         callback:(CefRefPtr<CefRunContextMenuCallback>)callback {
  if ((self = [super init])) {
    _callback = callback;
    int flags = params->GetTypeFlags();
    OEContextMenuTarget targets = 0;
    if (flags & CM_TYPEFLAG_PAGE) targets |= OEContextMenuTargetPage;
    if (flags & CM_TYPEFLAG_FRAME) targets |= OEContextMenuTargetFrame;
    if (flags & CM_TYPEFLAG_LINK) targets |= OEContextMenuTargetLink;
    if (flags & CM_TYPEFLAG_MEDIA) targets |= OEContextMenuTargetMedia;
    if (flags & CM_TYPEFLAG_SELECTION) targets |= OEContextMenuTargetSelection;
    if (flags & CM_TYPEFLAG_EDITABLE) targets |= OEContextMenuTargetEditable;
    _targets = targets;
    switch (params->GetMediaType()) {
      case CM_MEDIATYPE_IMAGE:
        _mediaType = OEContextMenuMediaTypeImage;
        break;
      case CM_MEDIATYPE_VIDEO:
        _mediaType = OEContextMenuMediaTypeVideo;
        break;
      case CM_MEDIATYPE_AUDIO:
        _mediaType = OEContextMenuMediaTypeAudio;
        break;
      case CM_MEDIATYPE_CANVAS:
        _mediaType = OEContextMenuMediaTypeCanvas;
        break;
      case CM_MEDIATYPE_FILE:
        _mediaType = OEContextMenuMediaTypeFile;
        break;
      case CM_MEDIATYPE_PLUGIN:
        _mediaType = OEContextMenuMediaTypePlugin;
        break;
      default:
        _mediaType = OEContextMenuMediaTypeNone;
        break;
    }
    _location = NSMakePoint(params->GetXCoord(), params->GetYCoord());
    _linkURL = OEURL(params->GetLinkUrl());
    _linkText = OEString(params->GetTitleText());
    _sourceURL = OEURL(params->GetSourceUrl());
    _pageURL = OEURL(params->GetPageUrl());
    _frameURL = OEURL(params->GetFrameUrl());
    _selectionText = OEString(params->GetSelectionText());
    _misspelledWord = OEString(params->GetMisspelledWord());
    std::vector<CefString> suggestions;
    params->GetDictionarySuggestions(suggestions);
    NSMutableArray* s = [NSMutableArray array];
    for (const CefString& word : suggestions) {
      [s addObject:OEString(word)];
    }
    _spellingSuggestions = s;
    NSMutableArray* items = [NSMutableArray array];
    for (size_t i = 0; i < model->GetCount(); ++i) {
      [items addObject:[[OEContextMenuItem alloc] initOEWithModel:model
                                                             index:i]];
    }
    _items = items;
    OECollectCommands(items, &_commands);
  }
  return self;
}

- (void)selectCommand:(NSInteger)commandIdentifier {
  if (!_callback) {
    return;
  }
  if (!_commands.count((int)commandIdentifier)) {
    NSLog(@"OEContextMenu: refused command %ld: not an enabled item of this "
          @"menu",
          (long)commandIdentifier);
    [self cancel];
    return;
  }
  _callback->Continue((int)commandIdentifier, EVENTFLAG_NONE);
  _callback = nullptr;
}

- (void)cancel {
  if (_callback) {
    _callback->Cancel();
    _callback = nullptr;
  }
}

- (void)dealloc {
  [self cancel];
}

@end

@implementation OEFindResult

- (instancetype)initOEWithCount:(NSInteger)count
                          active:(NSInteger)active
                           final:(BOOL)isFinal {
  if ((self = [super init])) {
    _matchCount = count;
    _activeMatchIndex = active;
    _isFinal = isFinal;
  }
  return self;
}

@end
