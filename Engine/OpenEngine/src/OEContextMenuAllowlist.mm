#include "OEContextMenuAllowlist.h"

#include "include/cef_command_ids.h"

namespace {

// Command id ranges as Chromium 156 defines them
// (chrome/browser/renderer_context_menu/render_view_context_menu.cc,
// chrome/browser/extensions/context_menu_matcher.cc).
constexpr int kSpellingSuggestionLast = IDC_SPELLCHECK_SUGGESTION_0 + 4;
constexpr int kPageItemsLast = IDC_CONTENT_CONTEXT_CUSTOM_FIRST + 1000;
constexpr int kExtensionItemsLast = IDC_EXTENSIONS_CONTEXT_CUSTOM_FIRST + 1000;
constexpr int kProtocolHandlerLast =
    IDC_CONTENT_CONTEXT_PROTOCOL_HANDLER_FIRST + 199;
// ui::TextServicesContextMenu::MenuCommands (macOS): the Speech submenu
// (kSpeechMenu = 100, Start and Stop Speaking) and its Writing Direction
// ids up to kWritingDirectionRtl = 106.
constexpr int kTextServicesFirst = 100;
constexpr int kTextServicesLast = 106;

bool IsAllowed(int command_id) {
  switch (command_id) {
    // Navigation and page.
    case IDC_BACK:
    case IDC_FORWARD:
    case IDC_RELOAD:
    case IDC_CONTENT_CONTEXT_RELOADFRAME:
    case IDC_CONTENT_CONTEXT_EXIT_FULLSCREEN:
    case IDC_SAVE_PAGE:
    case IDC_PRINT:
    case IDC_VIEW_SOURCE:
    case IDC_CONTENT_CONTEXT_VIEWFRAMESOURCE:
    case IDC_CONTENT_CONTEXT_INSPECTELEMENT:
    case IDC_CONTENT_CONTEXT_INSPECTBACKGROUNDPAGE:
    // Links. "Open Link With" lists the page's protocol handlers.
    case IDC_CONTENT_CONTEXT_OPENLINKNEWTAB:
    case IDC_CONTENT_CONTEXT_OPENLINKNEWWINDOW:
    case IDC_CONTENT_CONTEXT_OPENLINKWITH:
    case IDC_CONTENT_CONTEXT_SAVELINKAS:
    case IDC_CONTENT_CONTEXT_COPYLINKLOCATION:
    case IDC_CONTENT_CONTEXT_COPYLINKTEXT:
    // Images.
    case IDC_CONTENT_CONTEXT_OPENIMAGENEWTAB:
    case IDC_CONTENT_CONTEXT_OPEN_ORIGINAL_IMAGE_NEW_TAB:
    case IDC_CONTENT_CONTEXT_LOAD_IMAGE:
    case IDC_CONTENT_CONTEXT_SAVEIMAGEAS:
    case IDC_CONTENT_CONTEXT_COPYIMAGE:
    case IDC_CONTENT_CONTEXT_COPYIMAGELOCATION:
    // Audio, video, and plugins.
    case IDC_CONTENT_CONTEXT_LOOP:
    case IDC_CONTENT_CONTEXT_CONTROLS:
    case IDC_CONTENT_CONTEXT_PICTUREINPICTURE:
    case IDC_CONTENT_CONTEXT_OPENAVNEWTAB:
    case IDC_CONTENT_CONTEXT_SAVEAVAS:
    case IDC_CONTENT_CONTEXT_COPYAVLOCATION:
    case IDC_CONTENT_CONTEXT_VIDEO_FRAME:
    case IDC_CONTENT_CONTEXT_COPYVIDEOFRAME:
    case IDC_CONTENT_CONTEXT_SAVEVIDEOFRAMEAS:
    case IDC_CONTENT_CONTEXT_SAVEPLUGINAS:
    case IDC_CONTENT_CONTEXT_ROTATECW:
    case IDC_CONTENT_CONTEXT_ROTATECCW:
    // Selection.
    case IDC_CONTENT_CONTEXT_COPY:
    case IDC_CONTENT_CONTEXT_SEARCHWEBFOR:
    case IDC_CONTENT_CONTEXT_SEARCHWEBFORNEWTAB:
    case IDC_CONTENT_CONTEXT_GOTOURL:
    case IDC_CONTENT_CONTEXT_COPYLINKTOTEXT:
    case IDC_CONTENT_CONTEXT_REMOVELINKTOTEXT:
    case IDC_CONTENT_CONTEXT_RESHARELINKTOTEXT:
    case IDC_CONTENT_CONTEXT_LOOK_UP:
    // Editable fields.
    case IDC_CONTENT_CONTEXT_UNDO:
    case IDC_CONTENT_CONTEXT_REDO:
    case IDC_CONTENT_CONTEXT_CUT:
    case IDC_CONTENT_CONTEXT_PASTE:
    case IDC_CONTENT_CONTEXT_PASTE_AND_MATCH_STYLE:
    case IDC_CONTENT_CONTEXT_DELETE:
    case IDC_CONTENT_CONTEXT_SELECTALL:
    case IDC_CONTENT_CONTEXT_EMOJI:
    case IDC_CONTENT_CONTEXT_DICTATION:
    // Spelling.
    case IDC_SPELLCHECK_MENU:
    case IDC_CHECK_SPELLING_WHILE_TYPING:
    case IDC_SPELLCHECK_ADD_TO_DICTIONARY:
    case IDC_SPELLCHECK_REMOVE_FROM_DICTIONARY:
    case IDC_CONTENT_CONTEXT_NO_SPELLING_SUGGESTIONS:
    case IDC_CONTENT_CONTEXT_SPELLING_SUGGESTION:
    // Writing Direction (macOS).
    case IDC_WRITING_DIRECTION_MENU:
    case IDC_WRITING_DIRECTION_DEFAULT:
    case IDC_WRITING_DIRECTION_LTR:
    case IDC_WRITING_DIRECTION_RTL:
    // Passwords: Chromium's own fill UI stays (plans/passwords-autofill.md
    // D-3); passkeys from a phone are a site sign-in path.
    case IDC_CONTENT_CONTEXT_AUTOFILL_FALLBACK_PASSWORDS_SELECT_PASSWORD:
    case IDC_CONTENT_CONTEXT_AUTOFILL_FALLBACK_PASSWORDS_USE_PASSKEY_FROM_ANOTHER_DEVICE:
    case IDC_CONTENT_CONTEXT_USE_PASSKEY_FROM_ANOTHER_DEVICE:
      return true;
  }
  // Spelling suggestions, protocol handlers, items the page adds, items
  // extensions add (chrome.contextMenus), and macOS Speech.
  return (command_id >= IDC_SPELLCHECK_SUGGESTION_0 &&
          command_id <= kSpellingSuggestionLast) ||
         (command_id >= IDC_CONTENT_CONTEXT_PROTOCOL_HANDLER_FIRST &&
          command_id <= kProtocolHandlerLast) ||
         (command_id >= IDC_CONTENT_CONTEXT_CUSTOM_FIRST &&
          command_id <= kPageItemsLast) ||
         (command_id >= IDC_EXTENSIONS_CONTEXT_CUSTOM_FIRST &&
          command_id <= kExtensionItemsLast) ||
         (command_id >= kTextServicesFirst && command_id <= kTextServicesLast);
}

// Drops separators at the start and end and runs of more than one.
void TrimSeparators(CefRefPtr<CefMenuModel> model) {
  bool previous_separator = true;
  for (size_t i = 0; i < model->GetCount();) {
    const bool separator = model->GetTypeAt(i) == MENUITEMTYPE_SEPARATOR;
    if (separator && previous_separator) {
      model->RemoveAt(i);
      continue;
    }
    previous_separator = separator;
    ++i;
  }
  while (model->GetCount() > 0 &&
         model->GetTypeAt(model->GetCount() - 1) == MENUITEMTYPE_SEPARATOR) {
    model->RemoveAt(model->GetCount() - 1);
  }
}

}  // namespace

void OEFilterChromeContextMenu(CefRefPtr<CefMenuModel> model) {
  for (size_t i = model->GetCount(); i-- > 0;) {
    const cef_menu_item_type_t type = model->GetTypeAt(i);
    if (type == MENUITEMTYPE_SEPARATOR) {
      continue;
    }
    if (!IsAllowed(model->GetCommandIdAt(i))) {
      model->RemoveAt(i);
      continue;
    }
    if (type == MENUITEMTYPE_SUBMENU) {
      CefRefPtr<CefMenuModel> submenu = model->GetSubMenuAt(i);
      if (submenu) {
        OEFilterChromeContextMenu(submenu);
      }
      if (!submenu || submenu->GetCount() == 0) {
        model->RemoveAt(i);
      }
    }
  }
  TrimSeparators(model);
}
