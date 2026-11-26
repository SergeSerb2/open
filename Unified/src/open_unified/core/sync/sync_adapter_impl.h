// Copyright 2026 The Open Authors. All rights reserved.
// Complete 16-collection SyncStorageAdapterImpl implementing SyncDataAdapter
// (docs/sync-protocol.md §2, parity with App/Sync/AppSyncAdapters.swift and
// Packages/OpenKit/Sources/OpenSync/SyncWorkspaceCodec.swift).

#ifndef OPEN_UNIFIED_CORE_SYNC_SYNC_ADAPTER_IMPL_H_
#define OPEN_UNIFIED_CORE_SYNC_SYNC_ADAPTER_IMPL_H_

#include <map>
#include <optional>
#include <set>
#include <string>
#include <string_view>
#include <vector>

#include "base/files/file_path.h"
#include "base/functional/callback.h"
#include "base/memory/raw_ptr.h"
#include "base/values.h"
#include "open_unified/core/model/open_types.h"
#include "open_unified/core/sync/sync_engine.h"

namespace open_unified {

class ArchiveStore;
class BoostStore;
class BrowserModel;
class CommandRegistry;
class DocumentStore;
class HistoryStore;
class OpenAdBlockProfileService;

// Dependency bundle for SyncStorageAdapterImpl. All pointers are non-owning
// and must outlive the adapter (or be null). Optional callbacks allow the
// browser layer (e.g. OpenBrowserService) to bridge live sequence-bound stores,
// Chrome extensions, autofill credentials, and site permissions without core/
// depending on browser/. When callbacks are omitted, disk-backed fallbacks
// under |user_data_dir| are used where possible.
struct SyncAdapterDeps {
  SyncAdapterDeps();
  SyncAdapterDeps(SyncAdapterDeps&&) noexcept;
  SyncAdapterDeps& operator=(SyncAdapterDeps&&) noexcept;
  ~SyncAdapterDeps();

  base::FilePath user_data_dir;

  // Core in-process stores (non-owning).
  raw_ptr<BrowserModel> model = nullptr;
  raw_ptr<CommandRegistry> command_registry = nullptr;
  raw_ptr<DocumentStore> document_store = nullptr;

  // Optional window selector returning the frontmost standard window ID for
  // workspace.windowLayout.
  base::RepeatingCallback<WindowID()> get_layout_window_id;

  // Optional notification after workspace.meta/profile/space/today/windowLayout
  // changes are applied to BrowserModel (receives newly created profile IDs so
  // the browser layer can create profile directories and refresh views).
  base::RepeatingCallback<void(const std::set<ProfileID>& new_profile_ids)>
      on_workspace_applied;

  // Optional Preferences.json bridge. When unset, reads/writes
  // <user_data_dir>/State/Preferences.json directly.
  base::RepeatingCallback<std::map<std::string, base::Value>()>
      read_preferences;
  base::RepeatingCallback<void(const std::map<std::string, base::Value>& values,
                               bool remove_missing_portable_keys)>
      write_preferences;

  // Optional notification after settings.keybindings is applied.
  base::RepeatingCallback<void()> on_keybindings_applied;

  // Per-profile Archive callbacks (fallback: Profiles/<dir>/State/Archive.sqlite).
  base::RepeatingCallback<std::optional<std::vector<ArchivedTabRecord>>(
      const ProfileID&)>
      read_archive;
  base::RepeatingCallback<bool(const ProfileID&,
                               const std::vector<ArchivedTabRecord>&,
                               bool replace_all)>
      apply_archive;

  // Per-profile History callbacks (fallback: Profiles/<dir>/State/History.sqlite).
  base::RepeatingCallback<std::optional<std::vector<HistoryEntry>>(
      const ProfileID&)>
      read_history;
  base::RepeatingCallback<bool(const ProfileID&,
                               const std::vector<HistoryEntry>&,
                               bool replace_all)>
      apply_history;

  // Per-profile BoostStore accessor or read/apply callbacks (fallback:
  // Profiles/<dir>/Boosts/boosts.json).
  base::RepeatingCallback<BoostStore*(const ProfileID&)> get_boost_store;
  base::RepeatingCallback<std::optional<std::vector<Boost>>(const ProfileID&)>
      read_boosts;
  base::RepeatingCallback<bool(const ProfileID&,
                               const std::vector<Boost>& upserts,
                               const std::vector<std::string>& deletes,
                               bool replace_all)>
      apply_boosts;
  base::RepeatingCallback<void(const ProfileID&)> on_boosts_changed;

  // AdBlock config/exclusions/custom-rules bridge.
  // Priority: read_adblock/apply_adblock -> get_adblock_service -> disk files.
  base::RepeatingCallback<OpenAdBlockProfileService*(const ProfileID&)>
      get_adblock_service;
  base::RepeatingCallback<std::optional<SyncedAdBlockConfigPayload>()>
      read_adblock;
  base::RepeatingCallback<std::vector<std::string>(
      const SyncedAdBlockConfigPayload& config,
      bool replace_all,
      bool is_full_snapshot)>
      apply_adblock;

  // Optional notification after Easels or Notes are updated on disk.
  base::RepeatingCallback<void()> on_documents_changed;

  // Per-profile Chrome Web Store extensions bridge (extensions.profile).
  base::RepeatingCallback<std::optional<std::vector<SyncedExtensionRecord>>(
      const ProfileID&)>
      read_extensions;
  base::RepeatingCallback<std::vector<SyncPendingExtension>(
      const ProfileID&,
      const std::vector<SyncedExtensionRecord>&)>
      apply_extensions;

  // Per-profile Credentials/Autofill bridge (credentials.profile).
  base::RepeatingCallback<std::optional<SyncedCredentialsProfilePayload>(
      const ProfileID&)>
      read_credentials;
  base::RepeatingCallback<std::vector<std::string>(
      const SyncedCredentialsProfilePayload&,
      bool replace_all)>
      apply_credentials;

  // Per-profile Site Permissions bridge (sitePermissions.profile).
  base::RepeatingCallback<std::optional<SyncedSitePermissionsProfilePayload>(
      const ProfileID&)>
      read_site_permissions;
  base::RepeatingCallback<std::vector<std::string>(
      const SyncedSitePermissionsProfilePayload&,
      bool replace_all)>
      apply_site_permissions;

  // Optional reserved profile directory names (lowercased) that new synced
  // Profiles must never claim (e.g. retired or pending-wipe directories).
  base::RepeatingCallback<std::set<std::string>()> get_reserved_profile_dirs;
};

// Concrete 16-collection SyncStorageAdapter implementation covering:
//  1. workspace.meta        (profile/space order, ATC routing rules & default)
//  2. workspace.profile     (profile metadata, icon, favorites, ProfileSettings)
//  3. workspace.space       (space metadata, icon, theme, pinned nodes)
//  4. workspace.today       (unpinned today nodes per space)
//  5. workspace.windowLayout(sidebar width, sidebar mode, toolbar visibility)
//  6. archive.profile       (archived tabs/folders per profile, <= 2,000)
//  7. settings.preferences  (allow-listed portable open.* preferences)
//  8. settings.keybindings  (CommandRegistry overrides / keybindings.json)
//  9. adblock.config        (global enabled, per-profile lists/exclusions/rules)
// 10. boost.item            (per-profile Boosts)
// 11. easel.document        (EaselDocuments + encrypted image blobs)
// 12. note.document         (NoteDocuments + encrypted asset blobs)
// 13. history.profile       (history entries per profile, <= 5,000)
// 14. extensions.profile    (CWS extensions + pending install queue)
// 15. credentials.profile   (autofill prefs + E2EE logins/addresses/cards)
// 16. sitePermissions.profile (per-origin permission decisions & site settings)
class SyncStorageAdapterImpl final : public SyncStorageAdapter {
 public:
  explicit SyncStorageAdapterImpl(SyncAdapterDeps deps);
  ~SyncStorageAdapterImpl() override;

  SyncStorageAdapterImpl(const SyncStorageAdapterImpl&) = delete;
  SyncStorageAdapterImpl& operator=(const SyncStorageAdapterImpl&) = delete;

  // SyncStorageAdapter (SyncDataAdapter):
  SyncLocalBundle CollectLocalData(const SyncCategorySettings& categories,
                                   const SyncVaultKeys& vault_keys) override;

  SyncApplyOutcome ApplyRemoteData(
      const SyncRemoteBundle& bundle,
      SyncApplyMode mode,
      const SyncCategorySettings& categories) override;

  bool PrepareLocalBackup(const base::FilePath& backup_dir) override;

  // Sanitizes a remote Profile directory name to [A-Za-z0-9 _-]{1,64},
  // reserving "Default" unless explicitly available and avoiding collisions
  // case-insensitively.
  static std::string SanitizeProfileDirectoryName(
      std::string_view raw,
      std::set<std::string>* used_lower);

  // Validates a Chrome Web Store extension ID (32 ASCII letters 'a'..'p').
  static bool IsValidWebStoreExtensionId(std::string_view id);

 private:
  // --- Collection collectors ---
  void CollectWorkspace(const SyncCategorySettings& categories,
                        SyncLocalBundle* out);
  void CollectArchive(SyncLocalBundle* out);
  void CollectPreferences(SyncLocalBundle* out);
  void CollectKeybindings(SyncLocalBundle* out);
  void CollectAdBlock(SyncLocalBundle* out);
  void CollectBoosts(SyncLocalBundle* out);
  void CollectEasels(const SyncVaultKeys& vault_keys, SyncLocalBundle* out);
  void CollectNotes(const SyncVaultKeys& vault_keys, SyncLocalBundle* out);
  void CollectHistory(SyncLocalBundle* out);
  void CollectExtensions(SyncLocalBundle* out);
  void CollectCredentials(SyncLocalBundle* out);
  void CollectSitePermissions(SyncLocalBundle* out);

  // --- Collection appliers ---
  void ApplyWorkspace(const SyncRemoteBundle& bundle,
                      SyncApplyMode mode,
                      const SyncCategorySettings& categories,
                      SyncApplyOutcome* outcome);
  void ApplyArchive(const SyncRemoteBundle& bundle,
                    SyncApplyMode mode,
                    SyncApplyOutcome* outcome);
  void ApplyPreferences(const SyncRemoteBundle& bundle,
                        SyncApplyMode mode,
                        SyncApplyOutcome* outcome);
  void ApplyKeybindings(const SyncRemoteBundle& bundle,
                        SyncApplyMode mode,
                        SyncApplyOutcome* outcome);
  void ApplyAdBlock(const SyncRemoteBundle& bundle,
                    SyncApplyMode mode,
                    SyncApplyOutcome* outcome);
  void ApplyBoosts(const SyncRemoteBundle& bundle,
                   SyncApplyMode mode,
                   SyncApplyOutcome* outcome);
  void ApplyEasels(const SyncRemoteBundle& bundle,
                   SyncApplyMode mode,
                   SyncApplyOutcome* outcome);
  void ApplyNotes(const SyncRemoteBundle& bundle,
                  SyncApplyMode mode,
                  SyncApplyOutcome* outcome);
  void ApplyHistory(const SyncRemoteBundle& bundle,
                    SyncApplyMode mode,
                    SyncApplyOutcome* outcome);
  void ApplyExtensions(const SyncRemoteBundle& bundle,
                       SyncApplyOutcome* outcome);
  void ApplyCredentials(const SyncRemoteBundle& bundle,
                        SyncApplyMode mode,
                        SyncApplyOutcome* outcome);
  void ApplySitePermissions(const SyncRemoteBundle& bundle,
                            SyncApplyMode mode,
                            SyncApplyOutcome* outcome);

  // Path & disk fallback helpers.
  base::FilePath StateDir() const;
  base::FilePath PreferencesFilePath() const;
  base::FilePath KeybindingsFilePath() const;
  base::FilePath ProfileDirFor(const Profile& profile) const;
  DocumentStore ResolveDocumentStore() const;

  std::map<std::string, base::Value> ReadLocalPortablePreferences() const;
  bool WriteLocalPortablePreferences(
      const std::map<std::string, base::Value>& values,
      bool remove_missing) const;
  base::DictValue SerializeKeybindingsDict() const;

  SyncAdapterDeps deps_;
};

}  // namespace open_unified

#endif  // OPEN_UNIFIED_CORE_SYNC_SYNC_ADAPTER_IMPL_H_
