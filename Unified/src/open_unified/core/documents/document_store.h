// Copyright 2026 The Open Authors. All rights reserved.
// Atomic Easel & Note document storage (docs/easels.md, NoteDocument.swift).

#ifndef OPEN_UNIFIED_CORE_DOCUMENTS_DOCUMENT_STORE_H_
#define OPEN_UNIFIED_CORE_DOCUMENTS_DOCUMENT_STORE_H_

#include <cstddef>
#include <cstdint>
#include <filesystem>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

#include "base/files/file_path.h"
#include "open_unified/core/model/open_types.h"

namespace open_unified {

// Hard document & asset caps.
inline constexpr size_t kEaselMaxDocumentBytes = 64 * 1024 * 1024;  // 64 MiB
inline constexpr size_t kEaselMaxImageBytes = 50 * 1024 * 1024;     // 50 MiB
inline constexpr size_t kNoteMaxDocumentBytes = 32 * 1024 * 1024;   // 32 MiB
inline constexpr size_t kNoteMaxAssetBytes = 20 * 1024 * 1024;      // 20 MiB

struct EaselIndexEntry {
  std::string id;
  std::string title;
  TimestampSec modified_at = 0.0;
  size_t element_count = 0;
};

struct NoteIndexEntry {
  std::string id;
  std::string title;
  TimestampSec modified_at = 0.0;
};

// Manages atomic load/save/list/delete and content-addressed images for
// Easels (<root>/Easels/<uuid>/document.json + images/<sha256>.<ext>) and
// Notes (<root>/Notes/<uuid>.json + <uuid>.assets/<sha256>.<ext>).
class DocumentStore {
 public:
  // When |read_only| is true the store NEVER writes, moves, or deletes
  // anything on disk: malformed or oversized documents are simply skipped and
  // every mutating call (Create/Save/Delete) fails. Used for importing the
  // legacy Open data directory, which must stay untouched.
  explicit DocumentStore(base::FilePath data_root, bool read_only = false);
  explicit DocumentStore(std::filesystem::path data_root,
                         bool read_only = false);
  ~DocumentStore();

  DocumentStore(const DocumentStore&) = delete;
  DocumentStore& operator=(const DocumentStore&) = delete;

  // --- Easels ---
  base::FilePath EaselsDir() const;
  base::FilePath EaselDir(std::string_view easel_id) const;
  base::FilePath EaselDocumentPath(std::string_view easel_id) const;
  base::FilePath EaselImagesDir(std::string_view easel_id) const;

  EaselDocument CreateEasel() const;
  std::optional<EaselDocument> LoadEasel(std::string_view easel_id) const;
  bool SaveEasel(const EaselDocument& doc) const;
  std::vector<EaselIndexEntry> ListEasels() const;
  std::vector<EaselDocument> ListEasels(std::string_view query) const;
  bool DeleteEasel(std::string_view easel_id) const;

  // Validates extension & size (<= 50 MiB), writes content-addressed
  // `images/<sha256>.<ext>`, and returns `<sha256>.<ext>`.
  std::optional<std::string> SaveEaselImage(
      std::string_view easel_id,
      const std::vector<uint8_t>& image_bytes,
      std::string_view extension) const;
  std::optional<base::FilePath> ResolveEaselImagePath(
      std::string_view easel_id,
      std::string_view filename) const;

  // Exports an Easel as a self-contained web page (`index.html`, `easel.json`,
  // and `images/`) inside |dest_folder| (created if absent).
  bool ExportEaselHtml(const EaselDocument& doc,
                       const base::FilePath& dest_folder) const;
  std::string ExportEaselHtml(const EaselDocument& doc) const {
    return RenderEaselStandaloneHtml(doc);
  }
  static std::string RenderEaselStandaloneHtml(const EaselDocument& doc);

  // --- Notes ---
  base::FilePath NotesDir() const;
  base::FilePath NotePath(std::string_view note_id) const;
  base::FilePath NoteAssetsDir(std::string_view note_id) const;

  NoteDocument CreateNote() const;
  std::optional<NoteDocument> LoadNote(std::string_view note_id) const;
  bool SaveNote(const NoteDocument& doc) const;
  std::vector<NoteIndexEntry> ListNotes() const;
  bool DeleteNote(std::string_view note_id) const;

  std::optional<std::string> SaveNoteAsset(
      std::string_view note_id,
      const std::vector<uint8_t>& asset_bytes,
      std::string_view extension) const;
  std::optional<base::FilePath> ResolveNoteAssetPath(
      std::string_view note_id,
      std::string_view filename) const;

  // Helpers.
  static bool IsValidDocumentId(std::string_view id);
  static bool IsValidAssetFilename(std::string_view filename);

 private:
  base::FilePath data_root_;
  bool read_only_ = false;
};

}  // namespace open_unified

#endif  // OPEN_UNIFIED_CORE_DOCUMENTS_DOCUMENT_STORE_H_
