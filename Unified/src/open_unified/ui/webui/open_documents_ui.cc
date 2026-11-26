// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "open_unified/ui/webui/open_documents_ui.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <map>
#include <optional>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include "base/base64.h"
#include "base/files/file_enumerator.h"
#include "base/files/file_path.h"
#include "base/files/file_util.h"
#include "base/files/important_file_writer.h"
#include "base/functional/bind.h"
#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/strings/strcat.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/string_split.h"
#include "base/strings/string_util.h"
#include "base/strings/utf_string_conversions.h"
#include "base/time/time.h"
#include "base/timer/timer.h"
#include "base/uuid.h"
#include "chrome/browser/profiles/profile.h"
#include "content/public/browser/navigation_controller.h"
#include "content/public/browser/render_widget_host_view.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_contents_observer.h"
#include "content/public/browser/web_ui.h"
#include "open_unified/browser/open_json.h"
#include "open_unified/browser/open_tab_bridge.h"
#include "open_unified/browser/open_window_controller.h"
#include "open_unified/core/documents/document_store.h"
#include "third_party/skia/include/core/SkBitmap.h"
#include "ui/base/page_transition_types.h"
#include "ui/gfx/codec/png_codec.h"
#include "ui/gfx/geometry/rect.h"
#include "ui/gfx/geometry/size.h"
#include "url/gurl.h"

namespace open_unified::webui {

namespace {

constexpr char kDocumentsUploadAsset[] = "documents.uploadAsset";
constexpr char kDocumentsDeleteAsset[] = "documents.deleteAsset";
constexpr char kDocumentsReadAsset[] = "documents.readAsset";
constexpr char kDocumentsCaptureUrl[] = "documents.captureUrl";
constexpr char kDocumentsExportMarkdown[] = "documents.exportMarkdown";
constexpr char kDocumentsExportHtml[] = "documents.exportHtml";
constexpr char kDocumentsExportImage[] = "documents.exportImage";
constexpr char kDocumentsDuplicate[] = "documents.duplicate";
constexpr char kDocumentsRename[] = "documents.rename";
constexpr char kDocumentsOpenUrl[] = "documents.openUrl";

constexpr size_t kMaxUploadBytes = 16 * 1024 * 1024;  // 16 MiB
constexpr size_t kMaxEncodedUploadBytes = (kMaxUploadBytes * 4) / 3 + 256;
constexpr size_t kMaxExtendedJsonBytes = 32 * 1024 * 1024;  // 32 MiB
constexpr char kEaselExtendedFileName[] = "extended.json";

bool IsDocumentId(std::string_view id) {
  return DocumentStore::IsValidDocumentId(id);
}

bool IsSafeAssetId(std::string_view asset_id) {
  if (asset_id.empty() || asset_id.size() > 160) {
    return false;
  }
  if (asset_id.find("..") != std::string_view::npos) {
    return false;
  }
  size_t dot = asset_id.rfind('.');
  if (dot == std::string_view::npos || dot == 0 || dot + 1 >= asset_id.size()) {
    return false;
  }
  for (char c : asset_id) {
    bool ok = base::IsAsciiAlphaNumeric(c) || c == '-' || c == '_' || c == '.';
    if (!ok) {
      return false;
    }
  }
  return true;
}

double NowSec() {
  return base::Time::Now().InSecondsFSinceUnixEpoch();
}

base::FilePath ProfileRootFromStore(DocumentStore* store) {
  return store->EaselsDir().DirName();
}

base::FilePath DocumentsAssetsDir(DocumentStore* store,
                                  std::string_view doc_id) {
  return ProfileRootFromStore(store)
      .AppendASCII("documents")
      .AppendASCII("assets")
      .AppendASCII(base::ToLowerASCII(doc_id));
}

base::FilePath DocumentsExportsDir(DocumentStore* store) {
  return ProfileRootFromStore(store)
      .AppendASCII("documents")
      .AppendASCII("exports");
}

base::FilePath EaselExtendedPath(DocumentStore* store,
                                 std::string_view easel_id) {
  return store->EaselDir(easel_id).AppendASCII(kEaselExtendedFileName);
}

std::string SanitizeFileNameStem(const std::string& title,
                                 const std::string& fallback) {
  std::string name;
  for (char c : title) {
    name += (base::IsAsciiAlphaNumeric(c) || c == '-' || c == '_' || c == ' ')
                ? c
                : '_';
  }
  name = std::string(base::TrimWhitespaceASCII(name, base::TRIM_ALL));
  if (name.empty()) {
    name = fallback;
  }
  if (name.size() > 80) {
    name.resize(80);
  }
  return name;
}

std::string ExportFileName(const std::string& title,
                           const std::string& fallback,
                           const std::string& ext) {
  return SanitizeFileNameStem(title, fallback) + "." + ext;
}

struct MimeSpec {
  std::string canonical_mime;
  std::string ext;
};

std::optional<MimeSpec> ValidateImageMime(std::string_view raw_mime) {
  std::string mime =
      base::ToLowerASCII(base::TrimWhitespaceASCII(raw_mime, base::TRIM_ALL));
  size_t semi = mime.find(';');
  if (semi != std::string::npos) {
    mime.resize(semi);
    mime = std::string(base::TrimWhitespaceASCII(mime, base::TRIM_ALL));
  }
  if (mime == "image/png") {
    return MimeSpec{"image/png", "png"};
  }
  if (mime == "image/jpeg" || mime == "image/jpg") {
    return MimeSpec{"image/jpeg", "jpg"};
  }
  if (mime == "image/gif") {
    return MimeSpec{"image/gif", "gif"};
  }
  if (mime == "image/webp") {
    return MimeSpec{"image/webp", "webp"};
  }
  if (mime == "image/avif") {
    return MimeSpec{"image/avif", "avif"};
  }
  return std::nullopt;
}

std::string MimeFromExtension(std::string_view asset_id) {
  size_t dot = asset_id.rfind('.');
  if (dot == std::string_view::npos || dot + 1 >= asset_id.size()) {
    return "application/octet-stream";
  }
  std::string ext = base::ToLowerASCII(asset_id.substr(dot + 1));
  if (ext == "png") return "image/png";
  if (ext == "jpg" || ext == "jpeg") return "image/jpeg";
  if (ext == "gif") return "image/gif";
  if (ext == "webp") return "image/webp";
  if (ext == "avif") return "image/avif";
  return "application/octet-stream";
}

// Extracts a valid document ID from a raw id, path ("/<id>"), query ("?id=<id>"),
// or full URL ("open://easel/<id>").
std::string ExtractIdFromCandidate(std::string_view raw) {
  std::string trimmed(base::TrimWhitespaceASCII(raw, base::TRIM_ALL));
  if (trimmed.empty()) {
    return {};
  }
  if (IsDocumentId(trimmed)) {
    return base::ToLowerASCII(trimmed);
  }
  // If it looks like a full URL, parse via GURL.
  if (trimmed.find("://") != std::string::npos) {
    GURL parsed(trimmed);
    if (parsed.is_valid()) {
      // Check ?id=... first.
      if (parsed.has_query()) {
        base::StringPairs pairs;
        base::SplitStringIntoKeyValuePairs(parsed.query(), '=', '&', &pairs);
        for (const auto& [k, v] : pairs) {
          if (k == "id" && IsDocumentId(v)) {
            return base::ToLowerASCII(v);
          }
        }
      }
      // Check path segments: open://easel/<id> -> segment [0].
      std::vector<std::string> segs = base::SplitString(
          parsed.path(), "/", base::TRIM_WHITESPACE, base::SPLIT_WANT_NONEMPTY);
      for (const std::string& seg : segs) {
        if (base::EndsWith(seg, ".html",
                           base::CompareCase::INSENSITIVE_ASCII)) {
          continue;
        }
        if (IsDocumentId(seg)) {
          return base::ToLowerASCII(seg);
        }
        break;
      }
      if (parsed.has_ref() && IsDocumentId(parsed.ref())) {
        return base::ToLowerASCII(parsed.ref());
      }
    }
    return {};
  }
  // Otherwise inspect path / query / hash fragments.
  std::string path_part = trimmed;
  size_t hash_pos = path_part.find('#');
  if (hash_pos != std::string::npos) {
    std::string ref = path_part.substr(hash_pos + 1);
    if (!ref.empty() && ref.front() == '/') {
      ref.erase(0, 1);
    }
    if (IsDocumentId(ref)) {
      return base::ToLowerASCII(ref);
    }
    path_part.resize(hash_pos);
  }
  size_t query_pos = path_part.find('?');
  if (query_pos != std::string::npos) {
    base::StringPairs pairs;
    base::SplitStringIntoKeyValuePairs(path_part.substr(query_pos + 1), '=',
                                       '&', &pairs);
    for (const auto& [k, v] : pairs) {
      if (k == "id" && IsDocumentId(v)) {
        return base::ToLowerASCII(v);
      }
    }
    path_part.resize(query_pos);
  }
  std::vector<std::string> segs = base::SplitString(
      path_part, "/", base::TRIM_WHITESPACE, base::SPLIT_WANT_NONEMPTY);
  for (const std::string& seg : segs) {
    if (base::EndsWith(seg, ".html", base::CompareCase::INSENSITIVE_ASCII)) {
      continue;
    }
    if (IsDocumentId(seg)) {
      return base::ToLowerASCII(seg);
    }
  }
  return {};
}

std::string EscapeHtml(std::string_view s) {
  std::string out;
  out.reserve(s.size());
  for (char c : s) {
    switch (c) {
      case '&': out += "&amp;"; break;
      case '<': out += "&lt;"; break;
      case '>': out += "&gt;"; break;
      case '"': out += "&quot;"; break;
      case '\'': out += "&#39;"; break;
      default: out.push_back(c); break;
    }
  }
  return out;
}

std::string EscapeMarkdownInline(std::string_view s) {
  std::string out;
  out.reserve(s.size());
  for (char c : s) {
    if (c == '\\' || c == '*' || c == '_' || c == '`' || c == '[' || c == ']' ||
        c == '~') {
      out.push_back('\\');
    }
    out.push_back(c);
  }
  return out;
}

std::string EscapeMarkdownDest(std::string_view url) {
  std::string out;
  out.reserve(url.size());
  for (char c : url) {
    switch (c) {
      case '(': out += "%28"; break;
      case ')': out += "%29"; break;
      case '<': out += "%3C"; break;
      case '>': out += "%3E"; break;
      case ' ': out += "%20"; break;
      case '\\': out += "%5C"; break;
      default: out.push_back(c); break;
    }
  }
  return out;
}

size_t CountWords(std::string_view text) {
  size_t count = 0;
  bool in_word = false;
  for (unsigned char c : text) {
    bool ws = (c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f' ||
               c == '\v');
    if (!ws && !in_word) {
      ++count;
      in_word = true;
    } else if (ws) {
      in_word = false;
    }
  }
  return count;
}

// Normalizes an incoming Easel dict (which may contain rich extended item types
// like sticky, line, frame, liveCapture, link) into a base EaselDocument for
// DocumentStore::SaveEasel compatibility.
std::optional<EaselDocument> ParseBaseEaselWithExtendedTypes(
    const base::Value* value) {
  if (!value || !value->is_dict()) {
    return std::nullopt;
  }
  const base::DictValue& d = value->GetDict();
  EaselDocument e;
  e.format_version = json::GetInt(d, "format_version", 1);
  e.id = base::ToLowerASCII(json::GetString(d, "id"));
  e.title = json::GetString(d, "title");
  e.canvas_width =
      std::clamp(json::GetDouble(d, "canvas_width", 1000.0), 1.0, 20000.0);
  e.canvas_height =
      std::clamp(json::GetDouble(d, "canvas_height", 1400.0), 1.0, 20000.0);
  e.palette = json::GetString(d, "palette", "vibrant");
  if (e.palette != "vibrant" && e.palette != "chill") {
    e.palette = "vibrant";
  }
  e.created_at = json::GetDouble(d, "created_at", 0.0);
  e.modified_at = json::GetDouble(d, "modified_at", 0.0);
  if (!IsDocumentId(e.id)) {
    return std::nullopt;
  }
  if (const base::ListValue* elements = d.FindList("elements")) {
    if (elements->size() > 10000) {
      return std::nullopt;
    }
    for (const base::Value& item : *elements) {
      const base::DictValue* ed = item.GetIfDict();
      if (!ed) continue;
      EaselElement el;
      el.id = json::GetString(*ed, "id");
      std::string raw_type = json::GetString(*ed, "type");
      if (raw_type == "text" || raw_type == "image" || raw_type == "rect" ||
          raw_type == "ellipse" || raw_type == "arrow" ||
          raw_type == "freehand" || raw_type == "live_card") {
        el.type = raw_type;
      } else if (raw_type == "sticky" || raw_type == "frame" ||
                 raw_type == "rectangle") {
        el.type = "rect";
      } else if (raw_type == "line") {
        el.type = "arrow";
      } else if (raw_type == "liveCapture" || raw_type == "link") {
        el.type = "live_card";
      } else {
        el.type = "rect";
      }
      el.x = json::GetDouble(*ed, "x", 0.0);
      el.y = json::GetDouble(*ed, "y", 0.0);
      el.width = std::max(1.0, json::GetDouble(*ed, "width", 200.0));
      el.height = std::max(1.0, json::GetDouble(*ed, "height", 100.0));
      el.content = json::GetString(*ed, "content");
      if (el.content.empty()) {
        if (auto asset_id = json::FindString(*ed, "asset_id")) {
          el.content = *asset_id;
        } else if (auto live_url = json::FindString(*ed, "live_url")) {
          el.content = *live_url;
        }
      }
      el.fill_color = json::GetString(*ed, "fill_color");
      el.stroke_color = json::GetString(*ed, "stroke_color");
      el.stroke_width = json::GetDouble(*ed, "stroke_width", 2.0);
      el.font_size = json::GetDouble(*ed, "font_size", 16.0);
      el.z_index = json::GetInt(*ed, "z_index", 0);
      e.elements.push_back(std::move(el));
    }
  }
  return e;
}

// Reads an asset file from <profile_dir>/documents/assets/<doc_id>/<asset_id>,
// falling back to DocumentStore's legacy Easels/images or Notes/.assets dirs.
std::optional<std::pair<std::string, std::string>> LoadAssetAsDataUrl(
    DocumentStore* store,
    std::string_view doc_type,
    std::string_view doc_id,
    std::string_view asset_id) {
  if (!IsDocumentId(doc_id) || !IsSafeAssetId(asset_id)) {
    return std::nullopt;
  }
  base::FilePath path = DocumentsAssetsDir(store, doc_id).AppendASCII(asset_id);
  if (!base::PathExists(path)) {
    if (doc_type == "note") {
      if (auto legacy = store->ResolveNoteAssetPath(doc_id, asset_id);
          legacy && base::PathExists(*legacy)) {
        path = *legacy;
      }
    } else {
      if (auto legacy = store->ResolveEaselImagePath(doc_id, asset_id);
          legacy && base::PathExists(*legacy)) {
        path = *legacy;
      }
    }
  }
  if (!base::PathExists(path)) {
    return std::nullopt;
  }
  std::string raw;
  if (!base::ReadFileToStringWithMaxSize(path, &raw, kMaxUploadBytes)) {
    return std::nullopt;
  }
  std::string mime = MimeFromExtension(asset_id);
  std::string b64 = base::Base64Encode(raw);
  return std::make_pair(mime, base::StrCat({"data:", mime, ";base64,", b64}));
}

// Resolves an image URL (open://.../asset/<doc>/<asset> or /asset/<doc>/<asset>
// or bare <asset_id>) to an inlined data URL for standalone HTML export.
std::string ResolveInlineImageSrc(DocumentStore* store,
                                  std::string_view doc_type,
                                  std::string_view doc_id,
                                  const std::string& raw_src) {
  if (base::StartsWith(raw_src, "data:image/",
                       base::CompareCase::INSENSITIVE_ASCII)) {
    return raw_src;
  }
  std::string asset_id;
  size_t slash = raw_src.rfind('/');
  if (slash != std::string::npos && slash + 1 < raw_src.size()) {
    asset_id = raw_src.substr(slash + 1);
  } else {
    asset_id = raw_src;
  }
  if (auto loaded = LoadAssetAsDataUrl(store, doc_type, doc_id, asset_id)) {
    return loaded->second;
  }
  return raw_src;
}

std::string RenderNoteMarkdown(const NoteDocument& doc) {
  std::string out;
  if (!doc.title.empty()) {
    out += "# ";
    out += doc.title;
    out += "\n\n";
  }
  const std::u16string u16 = base::UTF8ToUTF16(doc.text);
  size_t pos = 0;
  std::map<int, int> ordered_counters;

  while (pos <= u16.size()) {
    size_t nl = u16.find(u'\n', pos);
    size_t line_end = (nl == std::u16string::npos) ? u16.size() : nl;
    int line_start = static_cast<int>(pos);
    int line_len = static_cast<int>(line_end - pos);

    // Find block format covering this line.
    const NoteFormatRange* block = nullptr;
    for (const auto& f : doc.formats) {
      if (f.type == "h1" || f.type == "h2" || f.type == "h3" ||
          f.type == "bulletList" || f.type == "numberedList" ||
          f.type == "checklist" || f.type == "checklistChecked" ||
          f.type == "blockquote" || f.type == "codeBlock" ||
          f.type == "divider" || f.type == "image") {
        int f_end = std::max(f.location + f.length, f.location + 1);
        if (f.location <= line_start && line_start < f_end) {
          block = &f;
          break;
        }
      }
    }

    if (block && block->type == "divider") {
      ordered_counters.clear();
      out += "---\n";
    } else if (block && block->type == "image" && block->url) {
      ordered_counters.clear();
      std::string alt =
          base::UTF16ToUTF8(u16.substr(pos, static_cast<size_t>(line_len)));
      if (alt == "[image]") alt.clear();
      out += "![";
      out += EscapeMarkdownInline(alt);
      out += "](";
      out += EscapeMarkdownDest(*block->url);
      out += ")\n";
    } else if (block && block->type == "codeBlock") {
      ordered_counters.clear();
      std::string code_line =
          base::UTF16ToUTF8(u16.substr(pos, static_cast<size_t>(line_len)));
      out += "```\n";
      out += code_line;
      out += "\n```\n";
    } else {
      // Render inline runs over [pos, line_end).
      std::string body;
      if (line_len > 0) {
        size_t i = 0;
        while (i < static_cast<size_t>(line_len)) {
          int abs = line_start + static_cast<int>(i);
          auto inline_state = [&](int idx) {
            struct State {
              bool bold = false;
              bool italic = false;
              bool underline = false;
              bool strike = false;
              bool code = false;
              std::string link;
              bool operator==(const State&) const = default;
            } st;
            for (const auto& f : doc.formats) {
              if (idx < f.location || idx >= f.location + f.length) continue;
              if (f.type == "bold") st.bold = true;
              else if (f.type == "italic") st.italic = true;
              else if (f.type == "underline") st.underline = true;
              else if (f.type == "strikethrough") st.strike = true;
              else if (f.type == "code") st.code = true;
              else if (f.type == "link" && f.url) st.link = *f.url;
            }
            return st;
          };
          auto st = inline_state(abs);
          size_t j = i + 1;
          while (j < static_cast<size_t>(line_len) &&
                 inline_state(line_start + static_cast<int>(j)) == st) {
            ++j;
          }
          std::string chunk = base::UTF16ToUTF8(u16.substr(pos + i, j - i));
          if (st.code) {
            chunk = "`" + chunk + "`";
          } else {
            chunk = EscapeMarkdownInline(chunk);
            if (st.strike) chunk = "~~" + chunk + "~~";
            if (st.underline) chunk = "<u>" + chunk + "</u>";
            if (st.italic) chunk = "*" + chunk + "*";
            if (st.bold) chunk = "**" + chunk + "**";
          }
          if (!st.link.empty()) {
            chunk = "[" + chunk + "](" + EscapeMarkdownDest(st.link) + ")";
          }
          body += chunk;
          i = j;
        }
      }

      int level = std::clamp(block && block->level ? *block->level : 0, 0, 5);
      if (block && block->type == "h1") {
        ordered_counters.clear();
        out += "## " + body + "\n";
      } else if (block && block->type == "h2") {
        ordered_counters.clear();
        out += "### " + body + "\n";
      } else if (block && block->type == "h3") {
        ordered_counters.clear();
        out += "#### " + body + "\n";
      } else if (block && block->type == "blockquote") {
        ordered_counters.clear();
        out += "> " + body + "\n";
      } else if (block && block->type == "bulletList") {
        out += std::string(static_cast<size_t>(level) * 2, ' ') + "- " + body +
               "\n";
      } else if (block && block->type == "numberedList") {
        int n = ++ordered_counters[level];
        for (auto it = ordered_counters.begin(); it != ordered_counters.end();) {
          if (it->first > level) it = ordered_counters.erase(it);
          else ++it;
        }
        out += std::string(static_cast<size_t>(level) * 3, ' ') +
               base::NumberToString(n) + ". " + body + "\n";
      } else if (block && block->type == "checklist") {
        ordered_counters.clear();
        out += "- [ ] " + body + "\n";
      } else if (block && block->type == "checklistChecked") {
        ordered_counters.clear();
        out += "- [x] " + body + "\n";
      } else {
        ordered_counters.clear();
        out += body + "\n";
      }
    }

    if (nl == std::u16string::npos) {
      break;
    }
    pos = nl + 1;
  }

  return out;
}

std::string RenderNoteHtml(const NoteDocument& doc, DocumentStore* store) {
  std::string title = doc.title.empty() ? "Untitled Note" : doc.title;
  std::string out =
      "<!doctype html>\n<html lang=\"en\"><head><meta charset=\"utf-8\">"
      "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">"
      "<title>" +
      EscapeHtml(title) +
      "</title>\n<style>"
      "body{font:16px/1.65 -apple-system,BlinkMacSystemFont,'Inter',system-ui,"
      "sans-serif;max-width:720px;margin:56px auto;padding:0 24px;color:#14151f;"
      "background:#ffffff}"
      "h1.doc-title{font-size:32px;font-weight:800;letter-spacing:-0.025em;"
      "color:#220C7F;margin:0 0 20px}"
      "h1,h2,h3{color:#4b4372;margin:22px 0 8px}"
      "blockquote{margin:12px 0;padding:8px 16px;border-left:3px solid #3139ff;"
      "color:#5c5f72;background:rgba(49,57,255,0.04);border-radius:0 8px 8px 0}"
      "code{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:0.9em;"
      "background:rgba(20,22,36,0.06);padding:2px 5px;border-radius:5px}"
      "pre{background:#15151c;color:#f2f3f8;padding:14px 16px;border-radius:10px;"
      "overflow-x:auto}pre code{background:none;padding:0}"
      "hr{border:none;border-top:1px solid rgba(20,22,36,0.12);margin:20px 0}"
      "img{max-width:100%;border-radius:10px;display:block;margin:12px 0}"
      "a{color:#220C7F}"
      ".todo{display:flex;align-items:flex-start;gap:8px;margin:6px 0}"
      ".todo.done span{text-decoration:line-through;opacity:0.65}"
      "@media(prefers-color-scheme:dark){body{background:#15151c;color:#f2f3f8}"
      "h1.doc-title{color:#E6E6FF}h1,h2,h3{color:#CDCDFF}a{color:#9ca4ff}"
      "code{background:rgba(255,255,255,0.09)}hr{border-color:rgba(255,255,255,0.14)}"
      "blockquote{color:#a1a5b8;background:rgba(85,97,255,0.12)}}"
      "</style></head><body>\n<h1 class=\"doc-title\">" +
      EscapeHtml(title) + "</h1>\n";

  const std::u16string u16 = base::UTF8ToUTF16(doc.text);
  size_t pos = 0;
  std::string open_list;

  auto close_list = [&]() {
    if (!open_list.empty()) {
      out += "</" + open_list + ">\n";
      open_list.clear();
    }
  };

  while (pos <= u16.size()) {
    size_t nl = u16.find(u'\n', pos);
    size_t line_end = (nl == std::u16string::npos) ? u16.size() : nl;
    int line_start = static_cast<int>(pos);
    int line_len = static_cast<int>(line_end - pos);

    const NoteFormatRange* block = nullptr;
    for (const auto& f : doc.formats) {
      if (f.type == "h1" || f.type == "h2" || f.type == "h3" ||
          f.type == "bulletList" || f.type == "numberedList" ||
          f.type == "checklist" || f.type == "checklistChecked" ||
          f.type == "blockquote" || f.type == "codeBlock" ||
          f.type == "divider" || f.type == "image") {
        int f_end = std::max(f.location + f.length, f.location + 1);
        if (f.location <= line_start && line_start < f_end) {
          block = &f;
          break;
        }
      }
    }

    if (block && block->type == "divider") {
      close_list();
      out += "<hr>\n";
    } else if (block && block->type == "image" && block->url) {
      close_list();
      std::string src =
          ResolveInlineImageSrc(store, "note", doc.id, *block->url);
      std::string alt =
          base::UTF16ToUTF8(u16.substr(pos, static_cast<size_t>(line_len)));
      out += "<p><img src=\"" + EscapeHtml(src) + "\" alt=\"" +
             EscapeHtml(alt) + "\"></p>\n";
    } else if (block && block->type == "codeBlock") {
      close_list();
      std::string code_line =
          base::UTF16ToUTF8(u16.substr(pos, static_cast<size_t>(line_len)));
      out += "<pre><code>" + EscapeHtml(code_line) + "</code></pre>\n";
    } else {
      std::string body;
      if (line_len > 0) {
        size_t i = 0;
        while (i < static_cast<size_t>(line_len)) {
          int abs = line_start + static_cast<int>(i);
          auto inline_state = [&](int idx) {
            struct State {
              bool bold = false;
              bool italic = false;
              bool underline = false;
              bool strike = false;
              bool code = false;
              std::string link;
              bool operator==(const State&) const = default;
            } st;
            for (const auto& f : doc.formats) {
              if (idx < f.location || idx >= f.location + f.length) continue;
              if (f.type == "bold") st.bold = true;
              else if (f.type == "italic") st.italic = true;
              else if (f.type == "underline") st.underline = true;
              else if (f.type == "strikethrough") st.strike = true;
              else if (f.type == "code") st.code = true;
              else if (f.type == "link" && f.url) st.link = *f.url;
            }
            return st;
          };
          auto st = inline_state(abs);
          size_t j = i + 1;
          while (j < static_cast<size_t>(line_len) &&
                 inline_state(line_start + static_cast<int>(j)) == st) {
            ++j;
          }
          std::string chunk =
              EscapeHtml(base::UTF16ToUTF8(u16.substr(pos + i, j - i)));
          if (st.code) chunk = "<code>" + chunk + "</code>";
          if (st.strike) chunk = "<s>" + chunk + "</s>";
          if (st.underline) chunk = "<u>" + chunk + "</u>";
          if (st.italic) chunk = "<em>" + chunk + "</em>";
          if (st.bold) chunk = "<strong>" + chunk + "</strong>";
          if (!st.link.empty()) {
            GURL u(st.link);
            if (u.is_valid() &&
                (u.SchemeIsHTTPOrHTTPS() || u.SchemeIs("mailto"))) {
              chunk = "<a href=\"" + EscapeHtml(u.spec()) + "\">" + chunk +
                      "</a>";
            }
          }
          body += chunk;
          i = j;
        }
      }

      if (block && (block->type == "bulletList" ||
                    block->type == "numberedList")) {
        std::string tag = (block->type == "bulletList") ? "ul" : "ol";
        if (open_list != tag) {
          close_list();
          open_list = tag;
          out += "<" + tag + ">\n";
        }
        out += "<li>" + body + "</li>\n";
      } else {
        close_list();
        if (block && block->type == "h1") out += "<h1>" + body + "</h1>\n";
        else if (block && block->type == "h2") out += "<h2>" + body + "</h2>\n";
        else if (block && block->type == "h3") out += "<h3>" + body + "</h3>\n";
        else if (block && block->type == "blockquote")
          out += "<blockquote>" + body + "</blockquote>\n";
        else if (block && (block->type == "checklist" ||
                           block->type == "checklistChecked")) {
          bool checked = block->type == "checklistChecked";
          out += std::string("<div class=\"todo") +
                 (checked ? " done" : "") + "\"><input type=\"checkbox\"" +
                 (checked ? " checked" : "") + " disabled><span>" + body +
                 "</span></div>\n";
        } else {
          out += body.empty() ? "<p><br></p>\n" : ("<p>" + body + "</p>\n");
        }
      }
    }

    if (nl == std::u16string::npos) {
      break;
    }
    pos = nl + 1;
  }
  close_list();
  out += "</body></html>\n";
  return out;
}

// Renders a rich standalone HTML file for an Easel (supporting all extended
// item types, SVG arrows/lines/freehand paths, stickies, frames, and inlined
// images).
std::string RenderRichEaselHtml(const base::DictValue& doc_dict,
                                DocumentStore* store) {
  std::string doc_id = base::ToLowerASCII(json::GetString(doc_dict, "id"));
  std::string title = json::GetString(doc_dict, "title");
  if (title.empty()) title = "Untitled Easel";
  double canvas_w = json::GetDouble(doc_dict, "canvas_width", 1000.0);
  double canvas_h = json::GetDouble(doc_dict, "canvas_height", 1400.0);

  // Clone and inline any local assets so the HTML is truly self-contained.
  base::DictValue export_dict = doc_dict.Clone();
  if (base::ListValue* elements = export_dict.FindList("elements")) {
    for (base::Value& item : *elements) {
      base::DictValue* ed = item.GetIfDict();
      if (!ed) continue;
      if (const std::string* img_url = ed->FindString("image_url")) {
        ed->Set("image_url",
                ResolveInlineImageSrc(store, "easel", doc_id, *img_url));
      } else if (const std::string* asset_id = ed->FindString("asset_id")) {
        if (auto data =
                LoadAssetAsDataUrl(store, "easel", doc_id, *asset_id)) {
          ed->Set("image_url", data->second);
        }
      } else if (json::GetString(*ed, "type") == "image") {
        std::string content = json::GetString(*ed, "content");
        if (!content.empty()) {
          ed->Set("image_url",
                  ResolveInlineImageSrc(store, "easel", doc_id, content));
        }
      }
    }
  }

  std::string json_str;
  base::JSONWriter::Write(export_dict, &json_str);
  // Prevent premature </script> termination.
  std::string safe_json;
  safe_json.reserve(json_str.size());
  for (size_t i = 0; i < json_str.size(); ++i) {
    if (json_str[i] == '<' && i + 1 < json_str.size() &&
        json_str[i + 1] == '/') {
      safe_json += "<\\/";
      ++i;
    } else {
      safe_json.push_back(json_str[i]);
    }
  }

  std::string html =
      "<!doctype html>\n<html lang=\"en\"><head><meta charset=\"utf-8\">"
      "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">"
      "<title>" +
      EscapeHtml(title) +
      "</title>\n<style>"
      ":root{--bg:#fdfcfd;--ink:#101118;--card:#fff;--edge:rgba(0,0,0,.1)}"
      "@media(prefers-color-scheme:dark){:root{--bg:#19121c;--ink:#f2f2f5;"
      "--card:#201b28;--edge:rgba(255,255,255,.12)}}"
      "body{margin:0;background:var(--bg);color:var(--ink);font-family:"
      "-apple-system,BlinkMacSystemFont,'Inter',system-ui,sans-serif}"
      "h1{text-align:center;font-size:26px;margin:28px 16px 12px;font-weight:700}"
      "#canvas{position:relative;margin:0 auto 48px;overflow:visible}"
      ".el{position:absolute;box-sizing:border-box}"
      "</style></head><body><h1>" +
      EscapeHtml(title) + "</h1><div id=\"canvas\" style=\"width:" +
      base::NumberToString(static_cast<int>(canvas_w)) + "px;height:" +
      base::NumberToString(static_cast<int>(canvas_h)) +
      "px\"></div><script type=\"application/json\" id=\"easel-data\">" +
      safe_json +
      "</script><script>(function(){"
      "const doc=JSON.parse(document.getElementById('easel-data').textContent);"
      "const c=document.getElementById('canvas');"
      "const els=(doc.elements||[]).slice().sort((a,b)=>(a.z_index||0)-(b.z_index||0));"
      "for(const el of els){"
      "const d=document.createElement('div');d.className='el';"
      "d.style.left=el.x+'px';d.style.top=el.y+'px';"
      "d.style.width=el.width+'px';d.style.height=el.height+'px';"
      "d.style.zIndex=String(el.z_index||0);"
      "if(el.rotation)d.style.transform='rotate('+el.rotation+'deg)';"
      "if(el.type==='text'){"
      "d.style.fontSize=(el.font_size||18)+'px';d.style.whiteSpace='pre-wrap';"
      "if(el.text_color)d.style.color=el.text_color;"
      "if(el.font_weight)d.style.fontWeight=el.font_weight;"
      "if(el.font_style)d.style.fontStyle=el.font_style;"
      "if(el.text_align)d.style.textAlign=el.text_align;"
      "d.textContent=el.content||'';"
      "}else if(el.type==='sticky'){"
      "d.style.background=el.fill_color||'#FFF3B0';d.style.color='#1d1b16';"
      "d.style.borderRadius='10px';d.style.padding='14px';"
      "d.style.boxShadow='0 6px 18px rgba(0,0,0,.12)';d.style.whiteSpace='pre-wrap';"
      "d.style.fontSize=(el.font_size||15)+'px';d.textContent=el.content||'';"
      "}else if(el.type==='rect'||el.type==='ellipse'||el.type==='frame'){"
      "d.style.background=el.fill_color||'transparent';"
      "d.style.border=(el.stroke_width||2)+'px '+(el.type==='frame'?'dashed ':'solid ')+(el.stroke_color||'#3139FF');"
      "d.style.borderRadius=el.type==='ellipse'?'50%':'12px';"
      "if(el.content){d.style.display='flex';d.style.alignItems=el.type==='frame'?'flex-start':'center';"
      "d.style.justifyContent=el.type==='frame'?'flex-start':'center';d.style.padding='10px';d.textContent=el.content;}"
      "}else if(el.type==='arrow'||el.type==='line'||el.type==='freehand'){"
      "const ns='http://www.w3.org/2000/svg';const s=document.createElementNS(ns,'svg');"
      "s.setAttribute('width','100%');s.setAttribute('height','100%');"
      "s.setAttribute('viewBox','0 0 '+el.width+' '+el.height);"
      "if(el.type==='freehand'){const p=document.createElementNS(ns,'path');"
      "p.setAttribute('d',el.content||'');p.setAttribute('fill','none');"
      "p.setAttribute('stroke',el.stroke_color||'#3139FF');p.setAttribute('stroke-width',String(el.stroke_width||3));"
      "p.setAttribute('stroke-linecap','round');p.setAttribute('stroke-linejoin','round');s.appendChild(p);"
      "}else{const x1=el.start_x??6,y1=el.start_y??(el.height/2),x2=el.end_x??(el.width-6),y2=el.end_y??(el.height/2);"
      "const l=document.createElementNS(ns,'line');l.setAttribute('x1',x1);l.setAttribute('y1',y1);"
      "l.setAttribute('x2',x2);l.setAttribute('y2',y2);l.setAttribute('stroke',el.stroke_color||'#3139FF');"
      "l.setAttribute('stroke-width',String(el.stroke_width||3));l.setAttribute('stroke-linecap','round');s.appendChild(l);"
      "if(el.type==='arrow'){const ang=Math.atan2(y2-y1,x2-x1),sz=12;"
      "const h=document.createElementNS(ns,'polyline');"
      "h.setAttribute('points',(x2-sz*Math.cos(ang-0.45))+','+(y2-sz*Math.sin(ang-0.45))+' '+x2+','+y2+' '+(x2-sz*Math.cos(ang+0.45))+','+(y2-sz*Math.sin(ang+0.45)));"
      "h.setAttribute('fill','none');h.setAttribute('stroke',el.stroke_color||'#3139FF');"
      "h.setAttribute('stroke-width',String(el.stroke_width||3));h.setAttribute('stroke-linecap','round');s.appendChild(h);}}"
      "d.appendChild(s);"
      "}else if(el.type==='image'){"
      "const img=document.createElement('img');img.src=el.image_url||'';img.alt=el.content||'Image';"
      "img.style.width='100%';img.style.height='100%';img.style.objectFit='cover';img.style.borderRadius='10px';d.appendChild(img);"
      "}else if(el.type==='live_card'||el.type==='liveCapture'){"
      "d.style.border='1px solid var(--edge)';d.style.borderRadius='12px';d.style.background='var(--card)';d.style.overflow='hidden';d.style.display='flex';d.style.flexDirection='column';"
      "const hdr=document.createElement('div');hdr.style.padding='8px 10px';hdr.style.fontSize='12px';hdr.style.borderBottom='1px solid var(--edge)';"
      "const a=document.createElement('a');const u=el.live_url||el.content||'';a.textContent=el.live_title||u;"
      "try{const p=new URL(u);if(/^https?:$/.test(p.protocol))a.href=p.href;}catch(_){}"
      "hdr.appendChild(a);d.appendChild(hdr);"
      "if(el.image_url){const img=document.createElement('img');img.src=el.image_url;img.style.width='100%';img.style.flex='1';img.style.objectFit='cover';d.appendChild(img);}"
      "}"
      "c.appendChild(d);"
      "}})();</script></body></html>\n";
  return html;
}

}  // namespace

// Short-lived offscreen WebContents capture session for Easel Live Web Cards
// when no existing open tab already has the target URL loaded.
class OpenDocumentsUI::UrlCaptureSession : public content::WebContentsObserver {
 public:
  using DoneCallback = base::OnceCallback<void(std::string title,
                                               std::vector<uint8_t> png_bytes,
                                               std::string source)>;

  UrlCaptureSession(::Profile* chrome_profile,
                    const GURL& url,
                    gfx::Size viewport_size,
                    DoneCallback done)
      : viewport_size_(viewport_size), done_(std::move(done)) {
    content::WebContents::CreateParams params(chrome_profile);
    params.initially_hidden = false;
    contents_ = content::WebContents::Create(params);
    Observe(contents_.get());
    contents_->Resize(gfx::Rect(viewport_size_));

    content::NavigationController::LoadURLParams load_params(url);
    load_params.transition_type = ui::PAGE_TRANSITION_LINK;
    contents_->GetController().LoadURLWithParams(load_params);

    timeout_.Start(FROM_HERE, base::Seconds(8),
                   base::BindOnce(&UrlCaptureSession::CaptureNow,
                                  weak_factory_.GetWeakPtr(),
                                  /*timed_out=*/true));
  }

  ~UrlCaptureSession() override {
    timeout_.Stop();
    Observe(nullptr);
    contents_.reset();
  }

  // content::WebContentsObserver:
  void DidStopLoading() override {
    if (capturing_ || !contents_) return;
    // Wait briefly for first paint after load completion.
    timeout_.Start(FROM_HERE, base::Milliseconds(350),
                   base::BindOnce(&UrlCaptureSession::CaptureNow,
                                  weak_factory_.GetWeakPtr(),
                                  /*timed_out=*/false));
  }

 private:
  void CaptureNow(bool timed_out) {
    if (capturing_ || !done_) return;
    capturing_ = true;
    timeout_.Stop();

    std::string title =
        contents_ ? base::UTF16ToUTF8(contents_->GetTitle()) : std::string();
    content::RenderWidgetHostView* view =
        contents_ ? contents_->GetRenderWidgetHostView() : nullptr;
    if (!view || !view->IsSurfaceAvailableForCopy()) {
      std::move(done_).Run(std::move(title), {},
                           timed_out ? "offscreen_timeout" : "metadata_only");
      return;
    }

    view->CopyFromSurface(
        gfx::Rect(), viewport_size_, base::Seconds(4),
        base::BindOnce(&UrlCaptureSession::OnBitmapCopied,
                       weak_factory_.GetWeakPtr(), std::move(title)));
  }

  void OnBitmapCopied(std::string title,
                      const content::CopyFromSurfaceResult& result) {
    if (!done_) return;
    std::vector<uint8_t> png_bytes;
    if (result.has_value() && !result->bitmap.drawsNothing()) {
      if (auto encoded = gfx::PNGCodec::FastEncodeBGRASkBitmap(
              result->bitmap, /*discard_transparency=*/true)) {
        png_bytes = std::move(*encoded);
      }
    }
    std::string source =
        png_bytes.empty() ? "metadata_only" : "offscreen_snapshot";
    std::move(done_).Run(std::move(title), std::move(png_bytes),
                         std::move(source));
  }

  gfx::Size viewport_size_;
  std::unique_ptr<content::WebContents> contents_;
  base::OneShotTimer timeout_;
  bool capturing_ = false;
  DoneCallback done_;
  base::WeakPtrFactory<UrlCaptureSession> weak_factory_{this};
};

OpenDocumentsUI::OpenDocumentsUI(OpenWebUIMessageHandler* handler)
    : OpenRpcDomain(handler) {}

OpenDocumentsUI::~OpenDocumentsUI() {
  active_captures_.clear();
}

void OpenDocumentsUI::OnJavascriptDisallowed() {
  active_captures_.clear();
}

void OpenDocumentsUI::RegisterMethods() {
  auto bind = [this](void (OpenDocumentsUI::*method)(const base::DictValue&,
                                                     Reply)) {
    return base::BindRepeating(method, weak_factory_.GetWeakPtr());
  };
  Register(kEaselLoad, bind(&OpenDocumentsUI::EaselLoad));
  Register(kEaselSave, bind(&OpenDocumentsUI::EaselSave));
  Register(kEaselExportHtml, bind(&OpenDocumentsUI::EaselExportHtml));
  Register(kNoteLoad, bind(&OpenDocumentsUI::NoteLoad));
  Register(kNoteSave, bind(&OpenDocumentsUI::NoteSave));

  Register(kDocumentsUploadAsset, bind(&OpenDocumentsUI::UploadAsset));
  Register(kDocumentsDeleteAsset, bind(&OpenDocumentsUI::DeleteAsset));
  Register(kDocumentsReadAsset, bind(&OpenDocumentsUI::ReadAsset));
  Register(kDocumentsCaptureUrl, bind(&OpenDocumentsUI::CaptureUrl));
  Register(kDocumentsExportMarkdown, bind(&OpenDocumentsUI::ExportMarkdown));
  Register(kDocumentsExportHtml, bind(&OpenDocumentsUI::ExportHtml));
  Register(kDocumentsExportImage, bind(&OpenDocumentsUI::ExportImage));
  Register(kDocumentsDuplicate, bind(&OpenDocumentsUI::DuplicateDocument));
  Register(kDocumentsRename, bind(&OpenDocumentsUI::RenameDocument));
  Register(kDocumentsOpenUrl, bind(&OpenDocumentsUI::OpenUrl));
}

std::string OpenDocumentsUI::CurrentDocType(
    const base::DictValue& payload) const {
  std::string explicit_type = base::ToLowerASCII(
      json::GetString(payload, "docType",
                      json::GetString(payload, "doc_type")));
  if (explicit_type == "note" || explicit_type == "easel") {
    return explicit_type;
  }
  if (web_ui() && web_ui()->GetWebContents()) {
    const GURL& url = web_ui()->GetWebContents()->GetVisibleURL();
    std::string host = base::ToLowerASCII(url.host());
    if (host == "note" || host == "open-note") {
      return "note";
    }
  }
  return "easel";
}

std::string OpenDocumentsUI::ResolveDocumentId(
    const base::DictValue& payload) const {
  for (std::string_view key : {"id", "docId", "doc_id", "url", "pathname"}) {
    std::string raw = json::GetString(payload, key);
    if (std::string extracted = ExtractIdFromCandidate(raw);
        !extracted.empty()) {
      return extracted;
    }
  }
  if (web_ui() && web_ui()->GetWebContents()) {
    if (std::string from_visible = ExtractIdFromCandidate(
            web_ui()->GetWebContents()->GetVisibleURL().spec());
        !from_visible.empty()) {
      return from_visible;
    }
    if (std::string from_committed = ExtractIdFromCandidate(
            web_ui()->GetWebContents()->GetLastCommittedURL().spec());
        !from_committed.empty()) {
      return from_committed;
    }
  }
  return {};
}

void OpenDocumentsUI::SyncTabTitleAndUrl(std::string_view doc_type,
                                         const std::string& doc_id,
                                         const std::string& title) {
  OpenBrowserService* svc = service();
  if (!svc || !svc->tab_bridge() || !IsDocumentId(doc_id)) {
    return;
  }
  const std::string canonical_url = OpenWebUIURL(doc_type, doc_id);
  const std::string display_title =
      !title.empty() ? title
                     : (doc_type == "note" ? "Untitled Note"
                                           : "Untitled Easel");

  // Update the current WebContents's own tab first.
  if (web_ui() && web_ui()->GetWebContents()) {
    if (auto tab_id =
            OpenTabBridge::TabIdForWebContents(web_ui()->GetWebContents())) {
      svc->model().UpdateTabNavigation(*tab_id, canonical_url, display_title);
    }
  }
  // Also update any other loaded tab displaying the same document.
  for (const auto& [tab_id, contents] : svc->tab_bridge()->LoadedTabs()) {
    const Tab* tab = svc->model().FindTab(tab_id);
    if (!tab) continue;
    if (ExtractIdFromCandidate(tab->url) == doc_id) {
      svc->model().UpdateTabNavigation(tab_id, canonical_url, display_title);
    }
  }
}

// --- Easel Load / Save / Export ---

void OpenDocumentsUI::EaselLoad(const base::DictValue& payload, Reply reply) {
  ProfileServices* ps = service()->ProfileServicesFor(profile_id());
  if (!ps) {
    ReplyError(std::move(reply), "no such profile");
    return;
  }
  const std::string requested_id = ResolveDocumentId(payload);
  RunOnStore(
      ps->documents,
      base::BindOnce(
          [](std::string requested_id,
             DocumentStore* store) -> base::DictValue {
            std::optional<EaselDocument> doc;
            if (!requested_id.empty()) {
              doc = store->LoadEasel(requested_id);
            }
            if (!doc) {
              if (!requested_id.empty() && IsDocumentId(requested_id)) {
                EaselDocument fresh;
                fresh.id = requested_id;
                fresh.title = "Untitled Easel";
                double now = NowSec();
                fresh.created_at = now;
                fresh.modified_at = now;
                store->SaveEasel(fresh);
                doc = std::move(fresh);
              } else {
                doc = store->CreateEasel();
              }
            }

            base::DictValue result = json::EaselToValue(*doc);

            // Merge lossless extended schema sidecar when present.
            base::FilePath ext_path = EaselExtendedPath(store, doc->id);
            std::string raw_ext;
            if (base::PathExists(ext_path) &&
                base::ReadFileToStringWithMaxSize(ext_path, &raw_ext,
                                                  kMaxExtendedJsonBytes)) {
              if (auto ext_dict =
                      base::JSONReader::ReadDict(raw_ext, base::JSON_PARSE_RFC);
                  ext_dict &&
                  base::ToLowerASCII(json::GetString(*ext_dict, "id")) ==
                      doc->id) {
                // Keep authoritative title/timestamps if document.json is newer.
                double ext_mod = json::GetDouble(*ext_dict, "modified_at", 0.0);
                if (doc->modified_at > ext_mod + 0.5) {
                  ext_dict->Set("title", doc->title);
                  ext_dict->Set("modified_at", doc->modified_at);
                }
                ext_dict->Set("id", doc->id);
                result = std::move(*ext_dict);
              }
            }
            return result;
          },
          requested_id),
      base::BindOnce(
          [](base::WeakPtr<OpenDocumentsUI> self, Reply reply,
             base::DictValue doc_dict) {
            if (self) {
              self->SyncTabTitleAndUrl(
                  kHostEasel, json::GetString(doc_dict, "id"),
                  json::GetString(doc_dict, "title"));
            }
            ReplyOk(std::move(reply),
                    base::DictValue().Set("document", std::move(doc_dict)));
          },
          weak_factory_.GetWeakPtr(), std::move(reply)));
}

void OpenDocumentsUI::EaselSave(const base::DictValue& payload, Reply reply) {
  const base::Value* doc_val = payload.Find("document");
  std::optional<EaselDocument> base_doc =
      ParseBaseEaselWithExtendedTypes(doc_val);
  ProfileServices* ps = service()->ProfileServicesFor(profile_id());
  if (!base_doc || !IsDocumentId(base_doc->id) || !ps) {
    ReplyError(std::move(reply), "invalid easel");
    return;
  }

  const double modified_at = NowSec();
  base_doc->modified_at = modified_at;
  base::DictValue full_dict = doc_val->GetDict().Clone();
  full_dict.Set("id", base_doc->id);
  full_dict.Set("modified_at", modified_at);

  const std::string doc_id = base_doc->id;
  const std::string title = base_doc->title;

  RunOnStore(
      ps->documents,
      base::BindOnce(
          [](EaselDocument base_doc, base::DictValue full_dict,
             DocumentStore* store) -> bool {
            if (!store->SaveEasel(base_doc)) {
              return false;
            }
            std::string ext_json;
            if (!base::JSONWriter::Write(full_dict, &ext_json) ||
                ext_json.size() > kMaxExtendedJsonBytes) {
              return false;
            }
            base::FilePath ext_path = EaselExtendedPath(store, base_doc.id);
            if (!base::CreateDirectory(ext_path.DirName())) {
              return false;
            }
            return base::ImportantFileWriter::WriteFileAtomically(ext_path,
                                                                  ext_json);
          },
          std::move(*base_doc), std::move(full_dict)),
      base::BindOnce(
          [](base::WeakPtr<OpenDocumentsUI> self, std::string doc_id,
             std::string title, double modified_at, Reply reply, bool ok) {
            if (!ok) {
              ReplyError(std::move(reply), "the easel could not be saved");
              return;
            }
            if (self) {
              self->SyncTabTitleAndUrl(kHostEasel, doc_id, title);
            }
            ReplyOk(std::move(reply), base::DictValue()
                                          .Set("ok", true)
                                          .Set("modified_at", modified_at));
          },
          weak_factory_.GetWeakPtr(), doc_id, title, modified_at,
          std::move(reply)));
}

void OpenDocumentsUI::EaselExportHtml(const base::DictValue& payload,
                                      Reply reply) {
  const base::Value* doc_val = payload.Find("document");
  ProfileServices* ps = service()->ProfileServicesFor(profile_id());
  if (!doc_val || !doc_val->is_dict() || !ps) {
    ReplyError(std::move(reply), "invalid easel");
    return;
  }
  base::DictValue doc_dict = doc_val->GetDict().Clone();
  const std::string filename =
      ExportFileName(json::GetString(doc_dict, "title"), "Easel", "html");
  RunOnStore(
      ps->documents,
      base::BindOnce(
          [](base::DictValue doc_dict, DocumentStore* store) {
            return RenderRichEaselHtml(doc_dict, store);
          },
          std::move(doc_dict)),
      base::BindOnce(
          [](std::string filename, Reply reply, std::string html) {
            ReplyOk(std::move(reply), base::DictValue()
                                          .Set("html", std::move(html))
                                          .Set("filename", filename));
          },
          filename, std::move(reply)));
}

// --- Note Load / Save ---

void OpenDocumentsUI::NoteLoad(const base::DictValue& payload, Reply reply) {
  ProfileServices* ps = service()->ProfileServicesFor(profile_id());
  if (!ps) {
    ReplyError(std::move(reply), "no such profile");
    return;
  }
  const std::string requested_id = ResolveDocumentId(payload);
  RunOnStore(
      ps->documents,
      base::BindOnce(
          [](std::string requested_id, DocumentStore* store) -> NoteDocument {
            if (!requested_id.empty()) {
              if (auto doc = store->LoadNote(requested_id)) {
                return *doc;
              }
              if (IsDocumentId(requested_id)) {
                NoteDocument fresh;
                fresh.id = requested_id;
                fresh.title = "Untitled Note";
                double now = NowSec();
                fresh.created_at = now;
                fresh.modified_at = now;
                store->SaveNote(fresh);
                return fresh;
              }
            }
            return store->CreateNote();
          },
          requested_id),
      base::BindOnce(
          [](base::WeakPtr<OpenDocumentsUI> self, Reply reply,
             NoteDocument doc) {
            if (self) {
              self->SyncTabTitleAndUrl(kHostNote, doc.id, doc.title);
            }
            int words = static_cast<int>(CountWords(doc.text));
            int chars = static_cast<int>(base::UTF8ToUTF16(doc.text).size());
            ReplyOk(std::move(reply),
                    base::DictValue()
                        .Set("document", json::NoteToValue(doc))
                        .Set("word_count", words)
                        .Set("char_count", chars));
          },
          weak_factory_.GetWeakPtr(), std::move(reply)));
}

void OpenDocumentsUI::NoteSave(const base::DictValue& payload, Reply reply) {
  std::optional<NoteDocument> document =
      json::NoteFromValue(payload.Find("document"));
  ProfileServices* ps = service()->ProfileServicesFor(profile_id());
  if (!document || !IsDocumentId(document->id) || !ps) {
    ReplyError(std::move(reply), "invalid note");
    return;
  }
  document->id = base::ToLowerASCII(document->id);
  document->modified_at = NowSec();
  const double modified_at = document->modified_at;
  const std::string doc_id = document->id;
  const std::string title = document->title;
  const int words = static_cast<int>(CountWords(document->text));
  const int chars = static_cast<int>(base::UTF8ToUTF16(document->text).size());

  RunOnStore(
      ps->documents,
      base::BindOnce(
          [](NoteDocument document, DocumentStore* store) {
            return store->SaveNote(document);
          },
          std::move(*document)),
      base::BindOnce(
          [](base::WeakPtr<OpenDocumentsUI> self, std::string doc_id,
             std::string title, double modified_at, int words, int chars,
             Reply reply, bool ok) {
            if (!ok) {
              ReplyError(std::move(reply), "the note could not be saved");
              return;
            }
            if (self) {
              self->SyncTabTitleAndUrl(kHostNote, doc_id, title);
            }
            ReplyOk(std::move(reply), base::DictValue()
                                          .Set("ok", true)
                                          .Set("modified_at", modified_at)
                                          .Set("word_count", words)
                                          .Set("char_count", chars));
          },
          weak_factory_.GetWeakPtr(), doc_id, title, modified_at, words, chars,
          std::move(reply)));
}

// --- Unified documents.* RPCs ---

void OpenDocumentsUI::UploadAsset(const base::DictValue& payload, Reply reply) {
  ProfileServices* ps = service()->ProfileServicesFor(profile_id());
  if (!ps) {
    ReplyError(std::move(reply), "no such profile");
    return;
  }
  const std::string doc_id = ResolveDocumentId(payload);
  if (!IsDocumentId(doc_id)) {
    ReplyError(std::move(reply), "invalid document id");
    return;
  }
  const std::string doc_type = CurrentDocType(payload);

  std::string raw_data = json::GetString(payload, "data");
  std::string raw_mime = json::GetString(
      payload, "mimeType", json::GetString(payload, "mime_type"));

  // Allow caller to pass a full data URL ("data:image/png;base64,...") cleanly.
  if (base::StartsWith(raw_data, "data:",
                       base::CompareCase::INSENSITIVE_ASCII)) {
    size_t comma = raw_data.find(',');
    if (comma == std::string::npos) {
      ReplyError(std::move(reply), "malformed data URL");
      return;
    }
    std::string header = raw_data.substr(5, comma - 5);
    if (raw_mime.empty()) {
      size_t semi = header.find(';');
      raw_mime = (semi == std::string::npos) ? header : header.substr(0, semi);
    }
    raw_data.erase(0, comma + 1);
  }

  std::optional<MimeSpec> mime = ValidateImageMime(raw_mime);
  if (!mime) {
    ReplyError(std::move(reply), "unsupported image MIME type");
    return;
  }
  if (raw_data.empty() || raw_data.size() > kMaxEncodedUploadBytes) {
    ReplyError(std::move(reply), "asset exceeds 16 MiB limit");
    return;
  }

  std::string decoded_str;
  if (!base::Base64Decode(raw_data, &decoded_str,
                          base::Base64DecodePolicy::kForgiving) ||
      decoded_str.empty() || decoded_str.size() > kMaxUploadBytes) {
    ReplyError(std::move(reply), "invalid base64 asset data");
    return;
  }

  std::vector<uint8_t> bytes(decoded_str.begin(), decoded_str.end());
  const std::string canonical_b64 = base::Base64Encode(bytes);
  const std::string data_url =
      base::StrCat({"data:", mime->canonical_mime, ";base64,", canonical_b64});

  RunOnStore(
      ps->documents,
      base::BindOnce(
          [](std::string doc_id, std::string doc_type, MimeSpec mime,
             std::vector<uint8_t> bytes,
             DocumentStore* store) -> std::optional<std::string> {
            // Save content-addressed via DocumentStore first when extension is
            // supported, so we get a deterministic <sha256>.<ext> filename.
            std::optional<std::string> asset_id;
            if (mime.ext != "avif") {
              asset_id = (doc_type == "note")
                             ? store->SaveNoteAsset(doc_id, bytes, mime.ext)
                             : store->SaveEaselImage(doc_id, bytes, mime.ext);
            }
            if (!asset_id) {
              asset_id = base::Uuid::GenerateRandomV4().AsLowercaseString() +
                         "." + mime.ext;
            }
            base::FilePath dir = DocumentsAssetsDir(store, doc_id);
            if (!base::CreateDirectory(dir)) {
              return std::nullopt;
            }
            base::FilePath dest = dir.AppendASCII(*asset_id);
            std::string_view sv(reinterpret_cast<const char*>(bytes.data()),
                                bytes.size());
            if (!base::ImportantFileWriter::WriteFileAtomically(dest, sv)) {
              return std::nullopt;
            }
            return asset_id;
          },
          doc_id, doc_type, *mime, std::move(bytes)),
      base::BindOnce(
          [](std::string doc_id, std::string doc_type, std::string mime_type,
             size_t size_bytes, std::string data_url, Reply reply,
             std::optional<std::string> asset_id) {
            if (!asset_id) {
              ReplyError(std::move(reply), "could not store asset");
              return;
            }
            std::string host = (doc_type == "note") ? kHostNote : kHostEasel;
            std::string url =
                base::StrCat({"open://", host, "/asset/", doc_id, "/",
                              *asset_id});
            std::string rel_url =
                base::StrCat({"/asset/", doc_id, "/", *asset_id});
            ReplyOk(std::move(reply),
                    base::DictValue()
                        .Set("assetId", *asset_id)
                        .Set("url", url)
                        .Set("relativeUrl", rel_url)
                        .Set("dataUrl", std::move(data_url))
                        .Set("mimeType", mime_type)
                        .Set("sizeBytes", static_cast<int>(size_bytes)));
          },
          doc_id, doc_type, mime->canonical_mime, decoded_str.size(), data_url,
          std::move(reply)));
}

void OpenDocumentsUI::DeleteAsset(const base::DictValue& payload, Reply reply) {
  ProfileServices* ps = service()->ProfileServicesFor(profile_id());
  if (!ps) {
    ReplyError(std::move(reply), "no such profile");
    return;
  }
  const std::string doc_id = ResolveDocumentId(payload);
  const std::string asset_id = json::GetString(
      payload, "assetId", json::GetString(payload, "asset_id"));
  const std::string doc_type = CurrentDocType(payload);
  if (!IsDocumentId(doc_id) || !IsSafeAssetId(asset_id)) {
    ReplyError(std::move(reply), "invalid asset reference");
    return;
  }

  RunOnStore(
      ps->documents,
      base::BindOnce(
          [](std::string doc_id, std::string doc_type, std::string asset_id,
             DocumentStore* store) -> bool {
            bool ok = true;
            base::FilePath p =
                DocumentsAssetsDir(store, doc_id).AppendASCII(asset_id);
            if (base::PathExists(p)) {
              ok = base::DeleteFile(p) && ok;
            }
            if (doc_type == "note") {
              if (auto legacy = store->ResolveNoteAssetPath(doc_id, asset_id);
                  legacy && base::PathExists(*legacy)) {
                ok = base::DeleteFile(*legacy) && ok;
              }
            } else {
              if (auto legacy = store->ResolveEaselImagePath(doc_id, asset_id);
                  legacy && base::PathExists(*legacy)) {
                ok = base::DeleteFile(*legacy) && ok;
              }
            }
            return ok;
          },
          doc_id, doc_type, asset_id),
      base::BindOnce(
          [](Reply reply, bool ok) {
            ReplyOk(std::move(reply), base::DictValue().Set("ok", ok));
          },
          std::move(reply)));
}

void OpenDocumentsUI::ReadAsset(const base::DictValue& payload, Reply reply) {
  ProfileServices* ps = service()->ProfileServicesFor(profile_id());
  if (!ps) {
    ReplyError(std::move(reply), "no such profile");
    return;
  }
  const std::string doc_id = ResolveDocumentId(payload);
  const std::string asset_id = json::GetString(
      payload, "assetId", json::GetString(payload, "asset_id"));
  const std::string doc_type = CurrentDocType(payload);
  if (!IsDocumentId(doc_id) || !IsSafeAssetId(asset_id)) {
    ReplyError(std::move(reply), "invalid asset reference");
    return;
  }
  RunOnStore(
      ps->documents,
      base::BindOnce(
          [](std::string doc_id, std::string doc_type, std::string asset_id,
             DocumentStore* store) {
            return LoadAssetAsDataUrl(store, doc_type, doc_id, asset_id);
          },
          doc_id, doc_type, asset_id),
      base::BindOnce(
          [](std::string asset_id, Reply reply,
             std::optional<std::pair<std::string, std::string>> result) {
            if (!result) {
              ReplyError(std::move(reply), "asset not found");
              return;
            }
            ReplyOk(std::move(reply),
                    base::DictValue()
                        .Set("assetId", asset_id)
                        .Set("mimeType", result->first)
                        .Set("dataUrl", std::move(result->second)));
          },
          asset_id, std::move(reply)));
}

void OpenDocumentsUI::CaptureUrl(const base::DictValue& payload, Reply reply) {
  ProfileServices* ps = service()->ProfileServicesFor(profile_id());
  if (!ps) {
    ReplyError(std::move(reply), "no such profile");
    return;
  }
  const std::string doc_id = ResolveDocumentId(payload);
  if (!IsDocumentId(doc_id)) {
    ReplyError(std::move(reply), "invalid document id");
    return;
  }
  const std::string raw_url = json::GetString(payload, "url");
  const GURL url(raw_url);
  if (!url.is_valid() || !url.SchemeIsHTTPOrHTTPS()) {
    ReplyError(std::move(reply), "only http(s) URLs can be captured");
    return;
  }

  const int width =
      std::clamp(json::GetInt(payload, "width", 1024), 240, 1920);
  const int height =
      std::clamp(json::GetInt(payload, "height", 640), 160, 1440);
  const gfx::Size target_size(width, height);

  // 1. Check if an already-loaded tab has this URL and a copyable surface.
  if (OpenTabBridge* bridge = service()->tab_bridge()) {
    for (const auto& [tab_id, contents] : bridge->LoadedTabs()) {
      if (!contents) continue;
      const GURL& visible = contents->GetVisibleURL();
      if (visible == url ||
          (visible.host() == url.host() && visible.path() == url.path())) {
        content::RenderWidgetHostView* view =
            contents->GetRenderWidgetHostView();
        if (view && view->IsSurfaceAvailableForCopy()) {
          std::string tab_title = base::UTF16ToUTF8(contents->GetTitle());
          view->CopyFromSurface(
              gfx::Rect(), target_size, base::Seconds(4),
              base::BindOnce(
                  [](base::WeakPtr<OpenDocumentsUI> self, std::string doc_id,
                     std::string url_spec, std::string tab_title, Reply reply,
                     const content::CopyFromSurfaceResult& result) {
                    if (!self) return;
                    std::vector<uint8_t> png;
                    if (result.has_value() && !result->bitmap.drawsNothing()) {
                      if (auto encoded = gfx::PNGCodec::FastEncodeBGRASkBitmap(
                              result->bitmap, /*discard_transparency=*/true)) {
                        png = std::move(*encoded);
                      }
                    }
                    self->FinishCaptureSession(
                        /*capture_id=*/0, doc_id, url_spec, tab_title,
                        std::move(png),
                        png.empty() ? "metadata_only" : "tab_snapshot",
                        std::move(reply));
                  },
                  weak_factory_.GetWeakPtr(), doc_id, url.spec(),
                  std::move(tab_title), std::move(reply)));
          return;
        }
      }
    }
  }

  // 2. Otherwise capture via a short-lived offscreen WebContents.
  ::Profile* chrome_profile = profile();
  if (!chrome_profile) {
    ReplyError(std::move(reply), "profile unavailable for capture");
    return;
  }

  const uint64_t capture_id = next_capture_id_++;
  auto session = std::make_unique<UrlCaptureSession>(
      chrome_profile, url, target_size,
      base::BindOnce(
          [](base::WeakPtr<OpenDocumentsUI> self, uint64_t capture_id,
             std::string doc_id, std::string url_spec, Reply reply,
             std::string title, std::vector<uint8_t> png_bytes,
             std::string source) {
            if (!self) return;
            self->FinishCaptureSession(capture_id, doc_id, url_spec, title,
                                       std::move(png_bytes), source,
                                       std::move(reply));
          },
          weak_factory_.GetWeakPtr(), capture_id, doc_id, url.spec(),
          std::move(reply)));
  active_captures_.emplace(capture_id, std::move(session));
}

void OpenDocumentsUI::FinishCaptureSession(uint64_t capture_id,
                                           const std::string& doc_id,
                                           const std::string& url,
                                           const std::string& title,
                                           std::vector<uint8_t> png_bytes,
                                           const std::string& source,
                                           Reply reply) {
  if (capture_id != 0) {
    active_captures_.erase(capture_id);
  }
  const double refreshed_at = NowSec();
  std::string display_title = title.empty() ? GURL(url).host() : title;

  if (png_bytes.empty()) {
    ReplyOk(std::move(reply),
            base::DictValue()
                .Set("ok", true)
                .Set("url", url)
                .Set("title", display_title)
                .Set("lastRefreshedAt", refreshed_at)
                .Set("source", source));
    return;
  }

  ProfileServices* ps = service()->ProfileServicesFor(profile_id());
  if (!ps) {
    ReplyError(std::move(reply), "no such profile");
    return;
  }
  std::string data_url =
      base::StrCat({"data:image/png;base64,", base::Base64Encode(png_bytes)});
  RunOnStore(
      ps->documents,
      base::BindOnce(
          [](std::string doc_id, std::vector<uint8_t> png_bytes,
             DocumentStore* store) -> std::optional<std::string> {
            auto asset_id = store->SaveEaselImage(doc_id, png_bytes, "png");
            if (!asset_id) {
              asset_id = base::Uuid::GenerateRandomV4().AsLowercaseString() +
                         ".png";
            }
            base::FilePath dir = DocumentsAssetsDir(store, doc_id);
            if (!base::CreateDirectory(dir)) {
              return std::nullopt;
            }
            std::string_view sv(reinterpret_cast<const char*>(png_bytes.data()),
                                png_bytes.size());
            if (!base::ImportantFileWriter::WriteFileAtomically(
                    dir.AppendASCII(*asset_id), sv)) {
              return std::nullopt;
            }
            return asset_id;
          },
          doc_id, std::move(png_bytes)),
      base::BindOnce(
          [](std::string doc_id, std::string url, std::string display_title,
             double refreshed_at, std::string source, std::string data_url,
             Reply reply, std::optional<std::string> asset_id) {
            base::DictValue out;
            out.Set("ok", true);
            out.Set("url", url);
            out.Set("title", display_title);
            out.Set("lastRefreshedAt", refreshed_at);
            out.Set("source", source);
            if (asset_id) {
              out.Set("assetId", *asset_id);
              out.Set("imageUrl", base::StrCat({"open://easel/asset/", doc_id,
                                                "/", *asset_id}));
              out.Set("relativeUrl",
                      base::StrCat({"/asset/", doc_id, "/", *asset_id}));
              out.Set("dataUrl", std::move(data_url));
            }
            ReplyOk(std::move(reply), std::move(out));
          },
          doc_id, url, display_title, refreshed_at, source, std::move(data_url),
          std::move(reply)));
}

void OpenDocumentsUI::ExportMarkdown(const base::DictValue& payload,
                                     Reply reply) {
  ProfileServices* ps = service()->ProfileServicesFor(profile_id());
  if (!ps) {
    ReplyError(std::move(reply), "no such profile");
    return;
  }
  if (const base::Value* doc_val = payload.Find("document")) {
    auto doc = json::NoteFromValue(doc_val);
    if (!doc) {
      ReplyError(std::move(reply), "invalid note");
      return;
    }
    ReplyOk(std::move(reply),
            base::DictValue()
                .Set("markdown", RenderNoteMarkdown(*doc))
                .Set("filename", ExportFileName(doc->title, "Note", "md")));
    return;
  }
  const std::string doc_id = ResolveDocumentId(payload);
  if (!IsDocumentId(doc_id)) {
    ReplyError(std::move(reply), "invalid document id");
    return;
  }
  RunOnStore(
      ps->documents,
      base::BindOnce(
          [](std::string doc_id, DocumentStore* store) {
            return store->LoadNote(doc_id);
          },
          doc_id),
      base::BindOnce(
          [](Reply reply, std::optional<NoteDocument> doc) {
            if (!doc) {
              ReplyError(std::move(reply), "note not found");
              return;
            }
            ReplyOk(std::move(reply),
                    base::DictValue()
                        .Set("markdown", RenderNoteMarkdown(*doc))
                        .Set("filename",
                             ExportFileName(doc->title, "Note", "md")));
          },
          std::move(reply)));
}

void OpenDocumentsUI::ExportHtml(const base::DictValue& payload, Reply reply) {
  ProfileServices* ps = service()->ProfileServicesFor(profile_id());
  if (!ps) {
    ReplyError(std::move(reply), "no such profile");
    return;
  }
  const std::string doc_type = CurrentDocType(payload);
  if (doc_type == "easel") {
    if (payload.Find("document")) {
      EaselExportHtml(payload, std::move(reply));
      return;
    }
    const std::string doc_id = ResolveDocumentId(payload);
    if (!IsDocumentId(doc_id)) {
      ReplyError(std::move(reply), "invalid easel id");
      return;
    }
    RunOnStore(
        ps->documents,
        base::BindOnce(
            [](std::string doc_id,
               DocumentStore* store) -> std::optional<std::pair<std::string, std::string>> {
              auto doc = store->LoadEasel(doc_id);
              if (!doc) return std::nullopt;
              base::DictValue d = json::EaselToValue(*doc);
              base::FilePath ext_path = EaselExtendedPath(store, doc_id);
              std::string raw_ext;
              if (base::PathExists(ext_path) &&
                  base::ReadFileToStringWithMaxSize(ext_path, &raw_ext,
                                                    kMaxExtendedJsonBytes)) {
                if (auto ext = base::JSONReader::ReadDict(
                        raw_ext, base::JSON_PARSE_RFC)) {
                  d = std::move(*ext);
                }
              }
              return std::make_pair(
                  RenderRichEaselHtml(d, store),
                  ExportFileName(doc->title, "Easel", "html"));
            },
            doc_id),
        base::BindOnce(
            [](Reply reply,
               std::optional<std::pair<std::string, std::string>> res) {
              if (!res) {
                ReplyError(std::move(reply), "easel not found");
                return;
              }
              ReplyOk(std::move(reply), base::DictValue()
                                            .Set("html", std::move(res->first))
                                            .Set("filename", res->second));
            },
            std::move(reply)));
    return;
  }

  // Note HTML export.
  std::optional<NoteDocument> inline_doc =
      payload.Find("document") ? json::NoteFromValue(payload.Find("document"))
                               : std::nullopt;
  const std::string doc_id =
      inline_doc ? inline_doc->id : ResolveDocumentId(payload);
  if (!inline_doc && !IsDocumentId(doc_id)) {
    ReplyError(std::move(reply), "invalid note");
    return;
  }
  RunOnStore(
      ps->documents,
      base::BindOnce(
          [](std::optional<NoteDocument> inline_doc, std::string doc_id,
             DocumentStore* store)
              -> std::optional<std::pair<std::string, std::string>> {
            std::optional<NoteDocument> doc = std::move(inline_doc);
            if (!doc) {
              doc = store->LoadNote(doc_id);
            }
            if (!doc) return std::nullopt;
            return std::make_pair(RenderNoteHtml(*doc, store),
                                  ExportFileName(doc->title, "Note", "html"));
          },
          std::move(inline_doc), doc_id),
      base::BindOnce(
          [](Reply reply,
             std::optional<std::pair<std::string, std::string>> res) {
            if (!res) {
              ReplyError(std::move(reply), "note not found");
              return;
            }
            ReplyOk(std::move(reply), base::DictValue()
                                          .Set("html", std::move(res->first))
                                          .Set("filename", res->second));
          },
          std::move(reply)));
}

void OpenDocumentsUI::ExportImage(const base::DictValue& payload, Reply reply) {
  ProfileServices* ps = service()->ProfileServicesFor(profile_id());
  if (!ps) {
    ReplyError(std::move(reply), "no such profile");
    return;
  }
  std::string raw_data = json::GetString(payload, "data");
  if (base::StartsWith(raw_data, "data:",
                       base::CompareCase::INSENSITIVE_ASCII)) {
    size_t comma = raw_data.find(',');
    if (comma != std::string::npos) {
      raw_data.erase(0, comma + 1);
    }
  }
  if (raw_data.empty() || raw_data.size() > kMaxEncodedUploadBytes) {
    ReplyError(std::move(reply), "invalid or oversized image data");
    return;
  }
  std::string decoded;
  if (!base::Base64Decode(raw_data, &decoded,
                          base::Base64DecodePolicy::kForgiving) ||
      decoded.empty() || decoded.size() > kMaxUploadBytes) {
    ReplyError(std::move(reply), "invalid base64 PNG data");
    return;
  }
  const std::string title = json::GetString(payload, "title", "Easel");
  const std::string filename = ExportFileName(title, "Easel", "png");
  const std::string data_url =
      base::StrCat({"data:image/png;base64,", base::Base64Encode(decoded)});

  RunOnStore(
      ps->documents,
      base::BindOnce(
          [](std::string filename, std::string decoded,
             DocumentStore* store) -> std::optional<std::string> {
            base::FilePath dir = DocumentsExportsDir(store);
            if (!base::CreateDirectory(dir)) {
              return std::nullopt;
            }
            base::FilePath dest = dir.AppendASCII(filename);
            if (!base::ImportantFileWriter::WriteFileAtomically(dest,
                                                                decoded)) {
              return std::nullopt;
            }
            return dest.AsUTF8Unsafe();
          },
          filename, std::move(decoded)),
      base::BindOnce(
          [](std::string filename, std::string data_url, Reply reply,
             std::optional<std::string> saved_path) {
            if (!saved_path) {
              ReplyError(std::move(reply), "could not write exported PNG");
              return;
            }
            ReplyOk(std::move(reply),
                    base::DictValue()
                        .Set("ok", true)
                        .Set("filename", filename)
                        .Set("savedPath", *saved_path)
                        .Set("dataUrl", std::move(data_url)));
          },
          filename, std::move(data_url), std::move(reply)));
}

void OpenDocumentsUI::DuplicateDocument(const base::DictValue& payload,
                                        Reply reply) {
  ProfileServices* ps = service()->ProfileServicesFor(profile_id());
  if (!ps) {
    ReplyError(std::move(reply), "no such profile");
    return;
  }
  const std::string doc_id = ResolveDocumentId(payload);
  const std::string doc_type = CurrentDocType(payload);
  const bool open_in_tab = json::GetBool(payload, "open", true);
  if (!IsDocumentId(doc_id)) {
    ReplyError(std::move(reply), "invalid document id");
    return;
  }

  RunOnStore(
      ps->documents,
      base::BindOnce(
          [](std::string doc_id, std::string doc_type, DocumentStore* store)
              -> std::optional<std::pair<std::string, std::string>> {
            const std::string new_id =
                base::Uuid::GenerateRandomV4().AsLowercaseString();
            const double now = NowSec();

            auto copy_dir_files = [](const base::FilePath& src,
                                     const base::FilePath& dst) {
              if (!base::DirectoryExists(src)) return;
              if (!base::CreateDirectory(dst)) return;
              base::FileEnumerator e(src, false, base::FileEnumerator::FILES);
              for (base::FilePath f = e.Next(); !f.empty(); f = e.Next()) {
                base::CopyFile(f, dst.Append(f.BaseName()));
              }
            };

            if (doc_type == "note") {
              auto orig = store->LoadNote(doc_id);
              if (!orig) return std::nullopt;
              NoteDocument copy = *orig;
              copy.id = new_id;
              copy.title = (copy.title.empty() ? "Untitled Note" : copy.title) +
                           " Copy";
              copy.created_at = now;
              copy.modified_at = now;
              // Rewrite asset URLs referencing the old doc id.
              const std::string old_prefix = "/asset/" + doc_id + "/";
              const std::string new_prefix = "/asset/" + new_id + "/";
              for (auto& fmt : copy.formats) {
                if (fmt.url) {
                  base::ReplaceSubstringsAfterOffset(&(*fmt.url), 0, old_prefix,
                                                     new_prefix);
                }
              }
              if (!store->SaveNote(copy)) return std::nullopt;
              copy_dir_files(store->NoteAssetsDir(doc_id),
                             store->NoteAssetsDir(new_id));
              copy_dir_files(DocumentsAssetsDir(store, doc_id),
                             DocumentsAssetsDir(store, new_id));
              return std::make_pair(copy.id, copy.title);
            }

            // Easel duplicate.
            auto orig = store->LoadEasel(doc_id);
            if (!orig) return std::nullopt;
            EaselDocument copy = *orig;
            copy.id = new_id;
            copy.title =
                (copy.title.empty() ? "Untitled Easel" : copy.title) + " Copy";
            copy.created_at = now;
            copy.modified_at = now;
            if (!store->SaveEasel(copy)) return std::nullopt;

            base::FilePath src_ext = EaselExtendedPath(store, doc_id);
            std::string raw_ext;
            if (base::PathExists(src_ext) &&
                base::ReadFileToStringWithMaxSize(src_ext, &raw_ext,
                                                  kMaxExtendedJsonBytes)) {
              if (auto ext = base::JSONReader::ReadDict(raw_ext,
                                                        base::JSON_PARSE_RFC)) {
                ext->Set("id", copy.id);
                ext->Set("title", copy.title);
                ext->Set("created_at", now);
                ext->Set("modified_at", now);
                std::string out_ext;
                if (base::JSONWriter::Write(*ext, &out_ext)) {
                  const std::string old_prefix = "/asset/" + doc_id + "/";
                  const std::string new_prefix = "/asset/" + new_id + "/";
                  base::ReplaceSubstringsAfterOffset(&out_ext, 0, old_prefix,
                                                     new_prefix);
                  base::ImportantFileWriter::WriteFileAtomically(
                      EaselExtendedPath(store, new_id), out_ext);
                }
              }
            }
            copy_dir_files(store->EaselImagesDir(doc_id),
                           store->EaselImagesDir(new_id));
            copy_dir_files(DocumentsAssetsDir(store, doc_id),
                           DocumentsAssetsDir(store, new_id));
            return std::make_pair(copy.id, copy.title);
          },
          doc_id, doc_type),
      base::BindOnce(
          [](base::WeakPtr<OpenDocumentsUI> self, std::string doc_type,
             bool open_in_tab, Reply reply,
             std::optional<std::pair<std::string, std::string>> created) {
            if (!created) {
              ReplyError(std::move(reply), "document could not be duplicated");
              return;
            }
            const std::string host =
                (doc_type == "note") ? kHostNote : kHostEasel;
            const std::string url = OpenWebUIURL(host, created->first);
            if (open_in_tab && self && self->service() &&
                self->service()->tab_bridge()) {
              self->service()->tab_bridge()->OpenTab(GURL(url),
                                                     /*background=*/false);
            }
            ReplyOk(std::move(reply), base::DictValue()
                                          .Set("ok", true)
                                          .Set("id", created->first)
                                          .Set("title", created->second)
                                          .Set("url", url));
          },
          weak_factory_.GetWeakPtr(), doc_type, open_in_tab, std::move(reply)));
}

void OpenDocumentsUI::RenameDocument(const base::DictValue& payload,
                                     Reply reply) {
  ProfileServices* ps = service()->ProfileServicesFor(profile_id());
  if (!ps) {
    ReplyError(std::move(reply), "no such profile");
    return;
  }
  const std::string doc_id = ResolveDocumentId(payload);
  const std::string doc_type = CurrentDocType(payload);
  std::string title = json::GetString(payload, "title");
  if (!IsDocumentId(doc_id) || title.size() > 1000) {
    ReplyError(std::move(reply), "invalid rename parameters");
    return;
  }
  const double modified_at = NowSec();

  RunOnStore(
      ps->documents,
      base::BindOnce(
          [](std::string doc_id, std::string doc_type, std::string title,
             double modified_at, DocumentStore* store) -> bool {
            if (doc_type == "note") {
              auto doc = store->LoadNote(doc_id);
              if (!doc) return false;
              doc->title = title;
              doc->modified_at = modified_at;
              return store->SaveNote(*doc);
            }
            auto doc = store->LoadEasel(doc_id);
            if (!doc) return false;
            doc->title = title;
            doc->modified_at = modified_at;
            if (!store->SaveEasel(*doc)) return false;
            base::FilePath ext_path = EaselExtendedPath(store, doc_id);
            std::string raw_ext;
            if (base::PathExists(ext_path) &&
                base::ReadFileToStringWithMaxSize(ext_path, &raw_ext,
                                                  kMaxExtendedJsonBytes)) {
              if (auto ext = base::JSONReader::ReadDict(raw_ext,
                                                        base::JSON_PARSE_RFC)) {
                ext->Set("title", title);
                ext->Set("modified_at", modified_at);
                std::string out_ext;
                if (base::JSONWriter::Write(*ext, &out_ext)) {
                  base::ImportantFileWriter::WriteFileAtomically(ext_path,
                                                                 out_ext);
                }
              }
            }
            return true;
          },
          doc_id, doc_type, title, modified_at),
      base::BindOnce(
          [](base::WeakPtr<OpenDocumentsUI> self, std::string doc_type,
             std::string doc_id, std::string title, double modified_at,
             Reply reply, bool ok) {
            if (!ok) {
              ReplyError(std::move(reply), "could not rename document");
              return;
            }
            if (self) {
              self->SyncTabTitleAndUrl(doc_type, doc_id, title);
            }
            ReplyOk(std::move(reply), base::DictValue()
                                          .Set("ok", true)
                                          .Set("id", doc_id)
                                          .Set("title", title)
                                          .Set("modified_at", modified_at));
          },
          weak_factory_.GetWeakPtr(), doc_type, doc_id, title, modified_at,
          std::move(reply)));
}

void OpenDocumentsUI::OpenUrl(const base::DictValue& payload, Reply reply) {
  const GURL url(json::GetString(payload, "url"));
  if (!url.is_valid() ||
      !(url.SchemeIsHTTPOrHTTPS() || url.SchemeIs(kOpenScheme) ||
        url.SchemeIs("mailto"))) {
    ReplyError(std::move(reply),
               "only http(s), mailto:, and open:// URLs can be opened");
    return;
  }
  const std::string mode =
      base::ToLowerASCII(json::GetString(payload, "mode", "tab"));

  if (mode == "peek" && service()->window_controller()) {
    OpenWindowUi* ui =
        service()->window_controller()->WindowUiFor(service()->ActiveWindowId());
    if (!ui) {
      ui = service()->window_controller()->MainWindowUi();
    }
    if (ui) {
      std::optional<ItemID> source;
      if (web_ui() && web_ui()->GetWebContents()) {
        source =
            OpenTabBridge::TabIdForWebContents(web_ui()->GetWebContents());
      }
      ui->OpenPeek(url, source);
      ReplyOk(std::move(reply), base::DictValue().Set("ok", true));
      return;
    }
  }

  OpenTabBridge* bridge = service()->tab_bridge();
  if (!bridge) {
    ReplyError(std::move(reply), "tab bridge unavailable");
    return;
  }
  if (mode == "background") {
    bridge->OpenTab(url, /*background=*/true);
  } else if (json::GetBool(payload, "new_tab", true)) {
    bridge->OpenTab(url, /*background=*/false);
  } else if (std::optional<ItemID> active = bridge->ActiveTabId()) {
    bridge->Navigate(*active, url);
  } else {
    bridge->OpenTab(url, /*background=*/false);
  }
  ReplyOk(std::move(reply), base::DictValue().Set("ok", true));
}

}  // namespace open_unified::webui
