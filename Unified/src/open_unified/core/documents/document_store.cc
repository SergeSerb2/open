// Copyright 2026 The Open Authors. All rights reserved.
// DocumentStore implementation for Easels & Notes.

#include "open_unified/core/documents/document_store.h"

#include <algorithm>
#include <cmath>
#include <set>
#include <utility>

#include "base/files/file_enumerator.h"
#include "base/files/file_util.h"
#include "base/files/important_file_writer.h"
#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/string_util.h"
#include "base/time/time.h"
#include "base/uuid.h"
#include "base/values.h"
#include "crypto/hash.h"

namespace open_unified {

namespace {

constexpr char kEaselsDirName[] = "Easels";
constexpr char kNotesDirName[] = "Notes";
constexpr char kEaselDocFileName[] = "document.json";
constexpr char kEaselImagesDirName[] = "images";

std::string Sha256HexBytes(const std::vector<uint8_t>& bytes) {
  std::string_view sv(reinterpret_cast<const char*>(bytes.data()), bytes.size());
  return base::HexEncodeLower(crypto::hash::Sha256(sv));
}

bool IsAllowedImageExtension(std::string_view ext) {
  return ext == "png" || ext == "jpg" || ext == "jpeg" || ext == "gif" ||
         ext == "webp" || ext == "heic" || ext == "tiff";
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

std::string EscapeEmbeddedJsonScript(std::string json) {
  std::string out;
  out.reserve(json.size());
  for (size_t i = 0; i < json.size(); ++i) {
    if (json[i] == '<' && i + 1 < json.size() && json[i + 1] == '/') {
      out += "<\\/";
      ++i;
    } else {
      out.push_back(json[i]);
    }
  }
  return out;
}

base::DictValue EncodeEaselDict(const EaselDocument& doc) {
  base::DictValue d;
  d.Set("formatVersion", doc.format_version);
  d.Set("id", base::ToLowerASCII(doc.id));
  d.Set("title", doc.title);
  d.Set("canvasWidth", doc.canvas_width);
  d.Set("canvasHeight", doc.canvas_height);
  d.Set("palette", doc.palette.empty() ? "vibrant" : doc.palette);
  base::ListValue elems;
  for (const auto& el : doc.elements) {
    base::DictValue ed;
    ed.Set("id", el.id);
    ed.Set("type", el.type);
    ed.Set("x", el.x);
    ed.Set("y", el.y);
    ed.Set("width", el.width);
    ed.Set("height", el.height);
    ed.Set("content", el.content);
    ed.Set("fillColor", el.fill_color);
    ed.Set("strokeColor", el.stroke_color);
    ed.Set("strokeWidth", el.stroke_width);
    ed.Set("fontSize", el.font_size);
    ed.Set("zIndex", el.z_index);
    elems.Append(std::move(ed));
  }
  d.Set("elements", std::move(elems));
  d.Set("createdAt", doc.created_at);
  d.Set("modifiedAt", doc.modified_at);
  return d;
}

std::optional<EaselDocument> DecodeEaselDict(const base::DictValue& d) {
  const auto* id = d.FindString("id");
  if (!id || !DocumentStore::IsValidDocumentId(*id)) return std::nullopt;
  EaselDocument doc;
  doc.format_version = d.FindInt("formatVersion").value_or(1);
  doc.id = base::ToLowerASCII(*id);
  if (const auto* s = d.FindString("title")) doc.title = *s;
  doc.canvas_width = d.FindDouble("canvasWidth").value_or(1000.0);
  doc.canvas_height = d.FindDouble("canvasHeight").value_or(1400.0);
  if (!std::isfinite(doc.canvas_width) || doc.canvas_width <= 0.0 ||
      !std::isfinite(doc.canvas_height) || doc.canvas_height <= 0.0) {
    return std::nullopt;
  }
  if (const auto* s = d.FindString("palette")) doc.palette = *s;
  if (const auto* elems = d.FindList("elements")) {
    for (const auto& v : *elems) {
      const auto* ed = v.GetIfDict();
      if (!ed) continue;
      EaselElement el;
      if (const auto* s = ed->FindString("id")) el.id = *s;
      if (const auto* s = ed->FindString("type")) el.type = *s;
      el.x = ed->FindDouble("x").value_or(0.0);
      el.y = ed->FindDouble("y").value_or(0.0);
      el.width = ed->FindDouble("width").value_or(200.0);
      el.height = ed->FindDouble("height").value_or(100.0);
      if (const auto* s = ed->FindString("content")) el.content = *s;
      if (const auto* s = ed->FindString("fillColor")) el.fill_color = *s;
      if (const auto* s = ed->FindString("strokeColor")) el.stroke_color = *s;
      el.stroke_width = ed->FindDouble("strokeWidth").value_or(2.0);
      el.font_size = ed->FindDouble("fontSize").value_or(16.0);
      el.z_index = ed->FindInt("zIndex").value_or(0);
      doc.elements.push_back(std::move(el));
    }
  }
  doc.created_at = d.FindDouble("createdAt").value_or(0.0);
  doc.modified_at = d.FindDouble("modifiedAt").value_or(doc.created_at);
  return doc;
}

base::DictValue EncodeNoteDict(const NoteDocument& doc) {
  base::DictValue d;
  d.Set("formatVersion", doc.format_version);
  d.Set("id", base::ToLowerASCII(doc.id));
  d.Set("title", doc.title);
  d.Set("text", doc.text);
  base::ListValue fmts;
  for (const auto& f : doc.formats) {
    base::DictValue fd;
    fd.Set("type", f.type);
    fd.Set("location", f.location);
    fd.Set("length", f.length);
    if (f.url) fd.Set("url", *f.url);
    if (f.level) fd.Set("level", *f.level);
    fmts.Append(std::move(fd));
  }
  d.Set("formats", std::move(fmts));
  d.Set("createdAt", doc.created_at);
  d.Set("modifiedAt", doc.modified_at);
  return d;
}

std::optional<NoteDocument> DecodeNoteDict(const base::DictValue& d) {
  const auto* id = d.FindString("id");
  if (!id || !DocumentStore::IsValidDocumentId(*id)) return std::nullopt;
  NoteDocument doc;
  doc.format_version = d.FindInt("formatVersion").value_or(1);
  doc.id = base::ToLowerASCII(*id);
  if (const auto* s = d.FindString("title")) doc.title = *s;
  if (const auto* s = d.FindString("text")) doc.text = *s;
  if (const auto* fmts = d.FindList("formats")) {
    for (const auto& v : *fmts) {
      const auto* fd = v.GetIfDict();
      if (!fd) continue;
      NoteFormatRange r;
      if (const auto* s = fd->FindString("type")) r.type = *s;
      r.location = fd->FindInt("location").value_or(0);
      r.length = fd->FindInt("length").value_or(0);
      if (const auto* s = fd->FindString("url")) r.url = *s;
      r.level = fd->FindInt("level");
      doc.formats.push_back(std::move(r));
    }
  }
  doc.created_at = d.FindDouble("createdAt").value_or(0.0);
  doc.modified_at = d.FindDouble("modifiedAt").value_or(doc.created_at);
  return doc;
}

}  // namespace

DocumentStore::DocumentStore(base::FilePath data_root)
    : data_root_(std::move(data_root)) {}

DocumentStore::DocumentStore(std::filesystem::path data_root)
    : data_root_(base::FilePath::FromUTF8Unsafe(data_root.string())) {}

DocumentStore::~DocumentStore() = default;

EaselDocument DocumentStore::CreateEasel() const {
  EaselDocument doc;
  doc.id = base::Uuid::GenerateRandomV4().AsLowercaseString();
  doc.title = "Untitled Easel";
  double now = base::Time::Now().InSecondsFSinceUnixEpoch();
  doc.created_at = now;
  doc.modified_at = now;
  SaveEasel(doc);
  return doc;
}

std::vector<EaselDocument> DocumentStore::ListEasels(
    std::string_view query) const {
  std::string needle = base::ToLowerASCII(query);
  std::vector<EaselDocument> out;
  for (const auto& entry : ListEasels()) {
    if (!needle.empty() &&
        base::ToLowerASCII(entry.title).find(needle) == std::string::npos) {
      continue;
    }
    if (auto doc = LoadEasel(entry.id)) {
      out.push_back(std::move(*doc));
    }
  }
  return out;
}

NoteDocument DocumentStore::CreateNote() const {
  NoteDocument doc;
  doc.id = base::Uuid::GenerateRandomV4().AsLowercaseString();
  doc.title = "Untitled Note";
  double now = base::Time::Now().InSecondsFSinceUnixEpoch();
  doc.created_at = now;
  doc.modified_at = now;
  SaveNote(doc);
  return doc;
}

// static
bool DocumentStore::IsValidDocumentId(std::string_view id) {
  if (id.empty() || id.size() > 64) return false;
  for (char c : id) {
    bool ok = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') ||
              (c >= 'A' && c <= 'F') || c == '-';
    if (!ok) return false;
  }
  return true;
}

// static
bool DocumentStore::IsValidAssetFilename(std::string_view filename) {
  size_t dot = filename.find('.');
  if (dot != 64 || dot + 1 >= filename.size()) return false;
  for (size_t i = 0; i < 64; ++i) {
    char c = filename[i];
    if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) return false;
  }
  return IsAllowedImageExtension(filename.substr(dot + 1));
}

// --- Easels ---

base::FilePath DocumentStore::EaselsDir() const {
  return data_root_.AppendASCII(kEaselsDirName);
}

base::FilePath DocumentStore::EaselDir(std::string_view easel_id) const {
  return EaselsDir().AppendASCII(base::ToLowerASCII(easel_id));
}

base::FilePath DocumentStore::EaselDocumentPath(
    std::string_view easel_id) const {
  return EaselDir(easel_id).AppendASCII(kEaselDocFileName);
}

base::FilePath DocumentStore::EaselImagesDir(std::string_view easel_id) const {
  return EaselDir(easel_id).AppendASCII(kEaselImagesDirName);
}

std::optional<EaselDocument> DocumentStore::LoadEasel(
    std::string_view easel_id) const {
  if (!IsValidDocumentId(easel_id)) return std::nullopt;
  base::FilePath path = EaselDocumentPath(easel_id);
  if (!base::PathExists(path)) return std::nullopt;

  std::string raw;
  if (!base::ReadFileToStringWithMaxSize(path, &raw, kEaselMaxDocumentBytes)) {
    // Move refused oversized/unreadable file aside so fresh edits never lose it.
    std::string refused_name =
        "document.refused-" +
        base::NumberToString(base::Time::Now().InMillisecondsSinceUnixEpoch() / 1000) +
        ".json";
    base::Move(path, path.DirName().AppendASCII(refused_name));
    return std::nullopt;
  }
  auto dict = base::JSONReader::ReadDict(raw, base::JSON_PARSE_RFC);
  auto doc = dict ? DecodeEaselDict(*dict) : std::nullopt;
  if (!doc || doc->id != base::ToLowerASCII(easel_id)) {
    std::string refused_name =
        "document.refused-" +
        base::NumberToString(base::Time::Now().InMillisecondsSinceUnixEpoch() / 1000) +
        ".json";
    base::Move(path, path.DirName().AppendASCII(refused_name));
    return std::nullopt;
  }
  return doc;
}

bool DocumentStore::SaveEasel(const EaselDocument& doc) const {
  if (!IsValidDocumentId(doc.id)) return false;
  std::string json;
  if (!base::JSONWriter::Write(EncodeEaselDict(doc), &json)) return false;
  if (json.size() > kEaselMaxDocumentBytes) return false;
  base::FilePath path = EaselDocumentPath(doc.id);
  if (!base::CreateDirectory(path.DirName())) return false;
  return base::ImportantFileWriter::WriteFileAtomically(path, json);
}

std::vector<EaselIndexEntry> DocumentStore::ListEasels() const {
  std::vector<EaselIndexEntry> out;
  base::FilePath root = EaselsDir();
  if (!base::DirectoryExists(root)) return out;

  base::FileEnumerator enumerator(root, false,
                                  base::FileEnumerator::DIRECTORIES);
  size_t scanned = 0;
  for (base::FilePath dir = enumerator.Next(); !dir.empty() && scanned < 10000;
       dir = enumerator.Next(), ++scanned) {
    std::string id = dir.BaseName().AsUTF8Unsafe();
    if (!IsValidDocumentId(id)) continue;
    base::FilePath doc_path = dir.AppendASCII(kEaselDocFileName);
    std::string raw;
    if (!base::ReadFileToStringWithMaxSize(doc_path, &raw,
                                           kEaselMaxDocumentBytes)) {
      continue;
    }
    auto dict = base::JSONReader::ReadDict(raw, base::JSON_PARSE_RFC);
    auto doc = dict ? DecodeEaselDict(*dict) : std::nullopt;
    if (!doc) continue;
    EaselIndexEntry entry;
    entry.id = doc->id;
    entry.title = doc->title.empty() ? "Untitled Easel" : doc->title;
    entry.modified_at = doc->modified_at;
    entry.element_count = doc->elements.size();
    out.push_back(std::move(entry));
  }
  std::sort(out.begin(), out.end(),
            [](const EaselIndexEntry& a, const EaselIndexEntry& b) {
              return a.modified_at > b.modified_at;
            });
  return out;
}

bool DocumentStore::DeleteEasel(std::string_view easel_id) const {
  if (!IsValidDocumentId(easel_id)) return false;
  base::FilePath dir = EaselDir(easel_id);
  if (!base::PathExists(dir)) return true;
  return base::DeletePathRecursively(dir);
}

std::optional<std::string> DocumentStore::SaveEaselImage(
    std::string_view easel_id,
    const std::vector<uint8_t>& image_bytes,
    std::string_view extension) const {
  if (!IsValidDocumentId(easel_id) || image_bytes.empty() ||
      image_bytes.size() > kEaselMaxImageBytes) {
    return std::nullopt;
  }
  std::string ext = base::ToLowerASCII(extension);
  if (!ext.empty() && ext.front() == '.') ext.erase(0, 1);
  if (!IsAllowedImageExtension(ext)) return std::nullopt;

  std::string filename = Sha256HexBytes(image_bytes) + "." + ext;
  base::FilePath dir = EaselImagesDir(easel_id);
  if (!base::CreateDirectory(dir)) return std::nullopt;
  base::FilePath dest = dir.AppendASCII(filename);
  if (!base::PathExists(dest)) {
    std::string_view sv(reinterpret_cast<const char*>(image_bytes.data()),
                        image_bytes.size());
    if (!base::ImportantFileWriter::WriteFileAtomically(dest, sv)) {
      return std::nullopt;
    }
  }
  return filename;
}

std::optional<base::FilePath> DocumentStore::ResolveEaselImagePath(
    std::string_view easel_id,
    std::string_view filename) const {
  if (!IsValidDocumentId(easel_id) || !IsValidAssetFilename(filename)) {
    return std::nullopt;
  }
  return EaselImagesDir(easel_id).AppendASCII(filename);
}

bool DocumentStore::ExportEaselHtml(const EaselDocument& doc,
                                    const base::FilePath& dest_folder) const {
  if (!IsValidDocumentId(doc.id)) return false;
  if (!base::CreateDirectory(dest_folder)) return false;

  std::string json;
  if (!base::JSONWriter::Write(EncodeEaselDict(doc), &json)) return false;
  if (!base::ImportantFileWriter::WriteFileAtomically(
          dest_folder.AppendASCII("easel.json"), json)) {
    return false;
  }

  std::string html = RenderEaselStandaloneHtml(doc);
  if (!base::ImportantFileWriter::WriteFileAtomically(
          dest_folder.AppendASCII("index.html"), html)) {
    return false;
  }

  // Copy referenced content-addressed images into `<dest_folder>/images/`.
  base::FilePath dest_images = dest_folder.AppendASCII(kEaselImagesDirName);
  bool created_images_dir = false;
  for (const auto& el : doc.elements) {
    if (el.type != "image" || !IsValidAssetFilename(el.content)) continue;
    auto src = ResolveEaselImagePath(doc.id, el.content);
    if (!src || !base::PathExists(*src)) continue;
    if (!created_images_dir) {
      if (!base::CreateDirectory(dest_images)) return false;
      created_images_dir = true;
    }
    base::CopyFile(*src, dest_images.AppendASCII(el.content));
  }
  return true;
}

// static
std::string DocumentStore::RenderEaselStandaloneHtml(const EaselDocument& doc) {
  std::string title = doc.title.empty() ? "Untitled Easel" : doc.title;
  std::string json;
  base::JSONWriter::Write(EncodeEaselDict(doc), &json);
  std::string embedded_json = EscapeEmbeddedJsonScript(std::move(json));

  std::string html = R"(<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>)";
  html += EscapeHtml(title);
  html += R"(</title>
<style>
:root{--bg:#fdfcfd;--ink:#101118;--card:#fff;--edge:rgba(0,0,0,.08)}
@media(prefers-color-scheme:dark){:root{--bg:#16121b;--ink:#f2f2f5;--card:#050625;--edge:rgba(255,255,255,.1)}}
body{margin:0;background:var(--bg);color:var(--ink);font-family:system-ui,-apple-system,sans-serif}
h1{text-align:center;font-size:26px;margin:28px 16px 12px;font-weight:700}
#canvas{position:relative;margin:0 auto 48px;overflow:visible}
.el{position:absolute;box-sizing:border-box}
.el-text{white-space:pre-wrap;overflow:hidden}
.el-img img{width:100%;height:100%;object-fit:cover;display:block;border-radius:6px}
.el-card{border-radius:10px;border:1px solid var(--edge);background:var(--card);padding:12px;overflow:hidden}
</style>
</head>
<body>
<h1 id="title">)";
  html += EscapeHtml(title);
  html += R"(</h1>
<div id="canvas"></div>
<script type="application/json" id="easel-data">)";
  html += embedded_json;
  html += R"(</script>
<script>
(function(){
  const doc = JSON.parse(document.getElementById('easel-data').textContent);
  const canvas = document.getElementById('canvas');
  canvas.style.width = (doc.canvasWidth || 1000) + 'px';
  canvas.style.height = (doc.canvasHeight || 1400) + 'px';
  const elems = (doc.elements || []).slice().sort((a,b) => (a.zIndex||0) - (b.zIndex||0));
  for (const el of elems) {
    const node = document.createElement('div');
    node.className = 'el';
    node.style.left = el.x + 'px';
    node.style.top = el.y + 'px';
    node.style.width = el.width + 'px';
    node.style.height = el.height + 'px';
    node.style.zIndex = String(el.zIndex || 0);
    if (el.type === 'text') {
      node.classList.add('el-text');
      node.style.fontSize = (el.fontSize || 16) + 'px';
      if (el.fillColor) node.style.color = el.fillColor;
      node.textContent = el.content || '';
    } else if (el.type === 'image') {
      node.classList.add('el-img');
      const img = document.createElement('img');
      img.src = 'images/' + el.content;
      node.appendChild(img);
    } else if (el.type === 'rect' || el.type === 'ellipse') {
      node.style.background = el.fillColor || 'transparent';
      if (el.strokeColor) node.style.border = (el.strokeWidth || 2) + 'px solid ' + el.strokeColor;
      if (el.type === 'ellipse') node.style.borderRadius = '50%';
    } else if (el.type === 'live_card') {
      node.classList.add('el-card');
      const a = document.createElement('a');
      a.textContent = el.content || '';
      try { const u = new URL(el.content); if (/^https?:$/.test(u.protocol)) a.href = u.href; } catch (_) {}
      node.appendChild(a);
    }
    canvas.appendChild(node);
  }
})();
</script>
</body>
</html>
)";
  return html;
}

// --- Notes ---

base::FilePath DocumentStore::NotesDir() const {
  return data_root_.AppendASCII(kNotesDirName);
}

base::FilePath DocumentStore::NotePath(std::string_view note_id) const {
  return NotesDir().AppendASCII(base::ToLowerASCII(note_id) + ".json");
}

base::FilePath DocumentStore::NoteAssetsDir(std::string_view note_id) const {
  return NotesDir().AppendASCII(base::ToLowerASCII(note_id) + ".assets");
}

std::optional<NoteDocument> DocumentStore::LoadNote(
    std::string_view note_id) const {
  if (!IsValidDocumentId(note_id)) return std::nullopt;
  base::FilePath path = NotePath(note_id);
  if (!base::PathExists(path)) return std::nullopt;
  std::string raw;
  if (!base::ReadFileToStringWithMaxSize(path, &raw, kNoteMaxDocumentBytes)) {
    return std::nullopt;
  }
  auto dict = base::JSONReader::ReadDict(raw, base::JSON_PARSE_RFC);
  return dict ? DecodeNoteDict(*dict) : std::nullopt;
}

bool DocumentStore::SaveNote(const NoteDocument& doc) const {
  if (!IsValidDocumentId(doc.id)) return false;
  // Preflight text byte length before serializing to avoid excessive allocations.
  if (doc.text.size() > kNoteMaxDocumentBytes) return false;
  std::string json;
  if (!base::JSONWriter::Write(EncodeNoteDict(doc), &json)) return false;
  if (json.size() > kNoteMaxDocumentBytes) return false;
  base::FilePath path = NotePath(doc.id);
  if (!base::CreateDirectory(path.DirName())) return false;
  return base::ImportantFileWriter::WriteFileAtomically(path, json);
}

std::vector<NoteIndexEntry> DocumentStore::ListNotes() const {
  std::vector<NoteIndexEntry> out;
  base::FilePath root = NotesDir();
  if (!base::DirectoryExists(root)) return out;

  base::FileEnumerator enumerator(root, false, base::FileEnumerator::FILES,
                                  FILE_PATH_LITERAL("*.json"));
  size_t scanned = 0;
  for (base::FilePath file = enumerator.Next(); !file.empty() && scanned < 10000;
       file = enumerator.Next(), ++scanned) {
    std::string raw;
    if (!base::ReadFileToStringWithMaxSize(file, &raw, kNoteMaxDocumentBytes)) {
      continue;
    }
    auto dict = base::JSONReader::ReadDict(raw, base::JSON_PARSE_RFC);
    auto doc = dict ? DecodeNoteDict(*dict) : std::nullopt;
    if (!doc) continue;
    NoteIndexEntry entry;
    entry.id = doc->id;
    entry.title = doc->title.empty() ? "Untitled Note" : doc->title;
    entry.modified_at = doc->modified_at;
    out.push_back(std::move(entry));
  }
  std::sort(out.begin(), out.end(),
            [](const NoteIndexEntry& a, const NoteIndexEntry& b) {
              return a.modified_at > b.modified_at;
            });
  return out;
}

bool DocumentStore::DeleteNote(std::string_view note_id) const {
  if (!IsValidDocumentId(note_id)) return false;
  bool ok = true;
  base::FilePath path = NotePath(note_id);
  if (base::PathExists(path)) {
    ok = base::DeleteFile(path) && ok;
  }
  base::FilePath assets = NoteAssetsDir(note_id);
  if (base::PathExists(assets)) {
    ok = base::DeletePathRecursively(assets) && ok;
  }
  return ok;
}

std::optional<std::string> DocumentStore::SaveNoteAsset(
    std::string_view note_id,
    const std::vector<uint8_t>& asset_bytes,
    std::string_view extension) const {
  if (!IsValidDocumentId(note_id) || asset_bytes.empty() ||
      asset_bytes.size() > kNoteMaxAssetBytes) {
    return std::nullopt;
  }
  std::string ext = base::ToLowerASCII(extension);
  if (!ext.empty() && ext.front() == '.') ext.erase(0, 1);
  if (!IsAllowedImageExtension(ext)) return std::nullopt;

  std::string filename = Sha256HexBytes(asset_bytes) + "." + ext;
  base::FilePath dir = NoteAssetsDir(note_id);
  if (!base::CreateDirectory(dir)) return std::nullopt;
  base::FilePath dest = dir.AppendASCII(filename);
  if (!base::PathExists(dest)) {
    std::string_view sv(reinterpret_cast<const char*>(asset_bytes.data()),
                        asset_bytes.size());
    if (!base::ImportantFileWriter::WriteFileAtomically(dest, sv)) {
      return std::nullopt;
    }
  }
  return filename;
}

std::optional<base::FilePath> DocumentStore::ResolveNoteAssetPath(
    std::string_view note_id,
    std::string_view filename) const {
  if (!IsValidDocumentId(note_id) || !IsValidAssetFilename(filename)) {
    return std::nullopt;
  }
  return NoteAssetsDir(note_id).AppendASCII(filename);
}

}  // namespace open_unified
