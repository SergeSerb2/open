// Copyright 2026 The Open Authors. All rights reserved.
// Open Account & Sync v1 Engine, 16 Collection Codecs, SimpleURLLoader
// transport, and WebSocket wakeup listener.

#ifndef OPEN_UNIFIED_CORE_SYNC_SYNC_ENGINE_H_
#define OPEN_UNIFIED_CORE_SYNC_SYNC_ENGINE_H_

#include <cstdint>
#include <filesystem>
#include <map>
#include <memory>
#include <optional>
#include <set>
#include <string>
#include <string_view>
#include <vector>

#include "base/files/file_path.h"
#include "base/functional/callback.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/scoped_refptr.h"
#include "base/memory/weak_ptr.h"
#include "base/task/sequenced_task_runner.h"
#include "base/timer/timer.h"
#include "base/types/expected.h"
#include "base/values.h"
#include "open_unified/browser/platform/open_platform.h"
#include "open_unified/core/model/open_types.h"
#include "open_unified/core/sync/sync_crypto.h"

namespace network {
class SharedURLLoaderFactory;
namespace mojom {
class NetworkContext;
}  // namespace mojom
}  // namespace network

namespace open_unified {

class BrowserModel;

// Hard protocol limits from docs/sync-protocol.md §3.
inline constexpr size_t kSyncMaxJsonRequestBytes = 8 * 1024 * 1024;
inline constexpr size_t kSyncMaxJsonResponseBytes = 16 * 1024 * 1024;
inline constexpr size_t kSyncMaxRecordCiphertextBytes = 2 * 1024 * 1024;
inline constexpr size_t kSyncMaxMutationsPerPush = 256;
inline constexpr size_t kSyncPushBatchSize = 128;
inline constexpr size_t kSyncPushBatchBase64Bytes = 6 * 1024 * 1024;
inline constexpr int kSyncMaxChangesLimit = 500;
inline constexpr int kSyncDefaultChangesLimit = 200;
inline constexpr size_t kSyncMaxBlobBytes = 20 * 1024 * 1024;
inline constexpr size_t kSyncMaxRecordIdLength = 128;
inline constexpr size_t kSyncMaxDeviceNameLength = 128;
inline constexpr size_t kSyncMaxDisplayNameLength = 120;
inline constexpr size_t kSyncMinPasswordLength = 8;
inline constexpr size_t kSyncMaxArchiveRecordsPerProfile = 2000;
inline constexpr size_t kSyncMaxHistoryEntriesPerProfile = 5000;
inline constexpr int kSyncWsSessionRevokedCloseCode = 4001;

inline constexpr char kSyncDefaultServerUrl[] = "http://127.0.0.1:8787";

// All 16 allowed collections (docs/sync-protocol.md §2).
enum class SyncCollection {
  kWorkspaceMeta,
  kWorkspaceProfile,
  kWorkspaceSpace,
  kWorkspaceToday,
  kWorkspaceWindowLayout,
  kArchiveProfile,
  kSettingsPreferences,
  kSettingsKeybindings,
  kAdblockConfig,
  kBoostItem,
  kEaselDocument,
  kNoteDocument,
  kHistoryProfile,
  kExtensionsProfile,
  kCredentialsProfile,
  kSitePermissionsProfile,
};

std::string_view SyncCollectionToString(SyncCollection collection);
std::optional<SyncCollection> SyncCollectionFromString(std::string_view name);
const std::vector<SyncCollection>& AllSyncCollections();
std::optional<std::string> SyncCollectionSingletonId(SyncCollection collection);
bool SyncCollectionCarriesAssets(SyncCollection collection);
bool IsValidSyncRecordId(std::string_view record_id);

enum class SyncCategory {
  kWorkspace,
  kTodayTabs,
  kArchive,
  kSettingsAndShortcuts,
  kAdBlocking,
  kBoostsEaselsNotes,
  kHistory,
  kExtensions,
  kCredentialsAndPermissions,
};

std::string_view SyncCategoryToString(SyncCategory category);
std::optional<SyncCategory> SyncCategoryFromString(std::string_view name);
SyncCategory SyncCategoryForCollection(SyncCollection collection);
std::vector<SyncCollection> SyncCollectionsForCategory(SyncCategory category);

struct SyncCategorySettings {
  std::map<std::string, bool> enabled;

  bool IsEnabled(SyncCategory category) const;
  bool IsEnabled(SyncCollection collection) const;
  void SetEnabled(SyncCategory category, bool is_on);
  std::set<SyncCollection> EnabledCollections() const;
};

enum class FirstSyncStrategy {
  kReplaceLocalWithCloud,
  kMergeLocalAndCloud,
  kReplaceCloudWithLocal,
};

using InitialSyncStrategy = FirstSyncStrategy;

enum class SyncApplyMode {
  kReplaceLocal,
  kMergeOrDelta,
};

enum class SyncPushMode {
  kDelta,
  kReplaceCloud,
};

enum class SyncStatusKind {
  kSignedOut,
  kIdle,
  kSyncing,
  kAwaitingInitialChoice,
  kError,
  kNeedsReauth,
};

struct SyncCloudSummary {
  int server_revision = 0;
  int reset_revision = 0;
  bool has_cloud_data = false;
  std::map<std::string, int> collection_counts;
};

struct SyncDeviceInfo {
  std::string device_id;
  std::string device_name;
  std::string platform;
  std::optional<int64_t> last_seen_at_ms;
  bool is_current = false;

  // Compatibility accessors matching UI/IPC contracts.
  const std::string& id() const { return device_id; }
  const std::string& name() const { return device_name; }
};

struct SyncStatusInfo {
  bool signed_in = false;
  std::string email;
  std::string server_url = kSyncDefaultServerUrl;
  std::string state = "signedOut";
  std::optional<TimestampSec> last_sync_at;
  int64_t revision = 0;
  std::map<std::string, bool> categories;
  std::optional<std::string> error_message;
};

struct SyncPendingExtension {
  ProfileID profile_id;
  std::string extension_id;
  std::string name;
  bool is_enabled = true;
  bool is_pinned = false;
  int pinned_index = 0;
};

struct SyncTokens {
  std::string access_token;
  std::string refresh_token;
  int64_t access_token_expires_at_ms = 0;
};

struct SyncCredentials {
  SyncTokens tokens;
  std::string vault_key_base64;

  ~SyncCredentials();
  SyncCredentials() = default;
  SyncCredentials(const SyncCredentials&) = default;
  SyncCredentials& operator=(const SyncCredentials&) = default;
  SyncCredentials(SyncCredentials&&) noexcept = default;
  SyncCredentials& operator=(SyncCredentials&&) noexcept = default;
};

struct SyncRecordMirror {
  std::string payload_hash;
  int64_t client_updated_at_ms = 0;
  bool deleted = false;
};

struct SyncPersistedState {
  int schema_version = 1;
  std::string server_url = kSyncDefaultServerUrl;
  std::optional<std::string> account_id;
  std::optional<std::string> email;
  std::optional<std::string> display_name;
  std::string device_id;
  std::string device_name;
  int last_pulled_revision = 0;
  int last_reset_revision = 0;
  std::optional<int64_t> last_sync_at_ms;
  SyncCategorySettings categories;
  std::optional<SyncCloudSummary> awaiting_initial_choice;
  std::vector<SyncPendingExtension> pending_extension_installs;
  // Key: "<collection>|<recordId>"
  std::map<std::string, SyncRecordMirror> mirror;
  std::set<std::string> uploaded_blob_ids;
  std::vector<SyncCategory> pending_backfill_categories;

  static std::string MirrorKey(SyncCollection collection,
                               std::string_view record_id);
  static std::optional<std::pair<SyncCollection, std::string>> ParseMirrorKey(
      std::string_view key);
};

struct SyncAccountSnapshot {
  bool is_signed_in = false;
  std::string server_url = kSyncDefaultServerUrl;
  std::optional<std::string> account_id;
  std::optional<std::string> email;
  std::optional<std::string> display_name;
  std::optional<std::string> device_id;
  std::optional<std::string> device_name;
  SyncStatusKind status = SyncStatusKind::kSignedOut;
  std::string status_message;
  SyncCategorySettings categories;
  std::optional<int64_t> last_sync_at_ms;
  int last_pulled_revision = 0;
  std::vector<SyncDeviceInfo> devices;
  std::vector<SyncPendingExtension> pending_extension_installs;
  std::vector<std::string> warnings;
  bool uses_file_credential_store = false;
  bool is_busy = false;
  bool websocket_connected = false;
  size_t pending_push_count = 0;
  std::optional<SyncCloudSummary> pending_initial_choice;
};

struct SyncDetailedStatus {
  bool signed_in = false;
  std::string state = "signedOut";
  std::string status_message;
  std::string email;
  std::string display_name;
  std::string server_url = kSyncDefaultServerUrl;
  std::string device_id;
  std::string device_name;
  std::optional<int64_t> last_sync_at_ms;
  int last_pulled_revision = 0;
  size_t pending_push_count = 0;
  bool websocket_connected = false;
  bool initial_sync_required = false;
  std::optional<SyncCloudSummary> pending_initial_choice;
  std::vector<SyncDeviceInfo> devices;
  std::map<std::string, bool> categories;
  std::vector<SyncPendingExtension> pending_extension_installs;
  std::vector<std::string> warnings;
  bool is_busy = false;
  std::optional<std::string> error_message;
};

struct SyncResult {
  bool ok = false;
  std::string error_code;
  std::string error_message;
  // Populated on SignUp / RecoverAccount with the new OPEN-XXXX-... key.
  std::string recovery_key;
  // Populated on SignIn / RecoverAccount when cloud data requires a choice.
  std::optional<SyncCloudSummary> needs_initial_choice;
};

// --- 16 Collection Payload Codecs (docs/sync-protocol.md §2) ---

struct SyncedAssetRef {
  std::string filename;
  std::string blob_id;
  std::string sha256;
  int64_t byte_length = 0;
};

struct SyncedWorkspaceMetaPayload {
  int schema_version = 1;
  std::vector<ProfileID> ordered_profile_ids;
  std::vector<SpaceID> ordered_space_ids;
  std::vector<RoutingRule> routing_rules;
  RoutingDestination default_destination;
};

struct SyncedWindowLayoutPayload {
  int schema_version = 1;
  double sidebar_width = 228.0;
  SidebarMode sidebar_mode = SidebarMode::kAnchored;
  bool shows_toolbar = true;
};

struct SyncedAdBlockProfilePayload {
  std::vector<std::string> enabled_list_ids;
  std::vector<std::string> excluded_domains;
  std::string custom_rules;
};

struct SyncedAdBlockConfigPayload {
  int schema_version = 1;
  bool global_enabled = true;
  std::map<ProfileID, SyncedAdBlockProfilePayload> profiles;
};

struct SyncedExtensionRecord {
  std::string extension_id;
  std::string name;
  bool from_web_store = true;
  bool is_enabled = true;
  bool is_pinned = false;
  int pinned_index = 0;
};

struct SyncedLoginRecord {
  std::string origin_url;
  std::optional<std::string> action_url;
  std::string signon_realm;
  std::string username;
  std::string password;
  std::string username_element;
  std::string password_element;
  int scheme = 0;
  bool is_blacklisted = false;
  int times_used = 0;
  double date_created = 0.0;
  std::optional<double> date_last_used;
  std::optional<double> date_password_modified;
  std::optional<std::string> note;
};

struct SyncedAddressRecord {
  std::string guid;
  std::map<std::string, std::string> fields;
  int use_count = 0;
  std::optional<double> use_date;
  std::optional<double> date_modified;
  std::optional<std::string> language_code;
};

struct SyncedCardRecord {
  std::string guid;
  std::string name_on_card;
  int expiration_month = 0;
  int expiration_year = 0;
  std::string number;
  std::optional<std::string> nickname;
  int use_count = 0;
  std::optional<double> use_date;
  std::optional<double> date_modified;
};

struct SyncedCredentialsProfilePayload {
  int schema_version = 1;
  ProfileID profile_id;
  bool password_saving_enabled = true;
  bool credit_cards_saving_enabled = true;
  bool credit_card_reauth_enabled = true;
  bool addresses_saving_enabled = true;
  std::vector<SyncedLoginRecord> logins;
  std::vector<SyncedAddressRecord> addresses;
  std::vector<SyncedCardRecord> cards;
};

struct SyncedPermissionDecision {
  std::string origin;
  std::string permission;
  std::string decision;  // "allow", "block", "ask"
  std::optional<double> updated_at;
};

struct SyncedSiteSetting {
  std::string origin;
  std::string setting;
  std::string value;
};

struct SyncedSitePermissionsProfilePayload {
  int schema_version = 1;
  ProfileID profile_id;
  std::vector<SyncedPermissionDecision> permissions;
  std::vector<SyncedSiteSetting> site_settings;
};

// Deterministic JSON codecs for all 16 Open Sync v1 collections.
class SyncCollectionCodecs {
 public:
  // Serializes a DictValue to deterministic UTF-8 JSON bytes (sorted keys).
  static std::string EncodeDeterministicJson(const base::DictValue& dict);
  static std::optional<base::DictValue> DecodeJsonDict(std::string_view json);
  static std::optional<int> ProbeSchemaVersion(std::string_view json);
  static std::vector<SyncedAssetRef> ProbeAssetRefs(std::string_view json);

  // 1. workspace.meta
  static base::DictValue EncodeWorkspaceMeta(
      const SyncedWorkspaceMetaPayload& payload);
  static std::optional<SyncedWorkspaceMetaPayload> DecodeWorkspaceMeta(
      const base::DictValue& dict);

  // 2. workspace.profile
  static base::DictValue EncodeProfile(const Profile& profile);
  static std::optional<Profile> DecodeProfile(const base::DictValue& dict);

  // 3. workspace.space (pinned nodes only; today travels in workspace.today)
  static base::DictValue EncodeSpace(const Space& space);
  static std::optional<Space> DecodeSpace(const base::DictValue& dict);

  // 4. workspace.today
  static base::DictValue EncodeTodayTabs(const SpaceID& space_id,
                                         const std::vector<SidebarNode>& today);
  static std::optional<std::vector<SidebarNode>> DecodeTodayTabs(
      const base::DictValue& dict,
      SpaceID* out_space_id = nullptr);

  // 5. workspace.windowLayout
  static base::DictValue EncodeWindowLayout(
      const SyncedWindowLayoutPayload& layout);
  static std::optional<SyncedWindowLayoutPayload> DecodeWindowLayout(
      const base::DictValue& dict);

  // 6. archive.profile (capped at 2,000 most recent records)
  static base::DictValue EncodeArchiveProfile(
      const ProfileID& profile_id,
      std::vector<ArchivedTabRecord> records);
  static std::optional<std::vector<ArchivedTabRecord>> DecodeArchiveProfile(
      const base::DictValue& dict,
      ProfileID* out_profile_id = nullptr);

  // 7. settings.preferences (allow-listed portable open.* keys only)
  static bool IsPortablePreferenceKey(std::string_view key);
  static base::DictValue EncodePreferences(
      const std::map<std::string, base::Value>& prefs);
  static std::optional<std::map<std::string, base::Value>> DecodePreferences(
      const base::DictValue& dict);

  // 8. settings.keybindings
  static base::DictValue EncodeKeybindings(const base::DictValue& bindings);
  static std::optional<base::DictValue> DecodeKeybindings(
      const base::DictValue& dict);

  // 9. adblock.config
  static base::DictValue EncodeAdBlockConfig(
      const SyncedAdBlockConfigPayload& config);
  static std::optional<SyncedAdBlockConfigPayload> DecodeAdBlockConfig(
      const base::DictValue& dict);

  // 10. boost.item (<ProfileUUID>:<BoostUUID>)
  static std::string BoostRecordId(const ProfileID& profile_id,
                                   const std::string& boost_id);
  static base::DictValue EncodeBoostItem(const ProfileID& profile_id,
                                         const Boost& boost);
  static std::optional<Boost> DecodeBoostItem(
      const base::DictValue& dict,
      ProfileID* out_profile_id = nullptr);

  // 11. easel.document
  static base::DictValue EncodeEaselDocument(
      const EaselDocument& doc,
      std::vector<SyncedAssetRef> assets);
  static std::optional<EaselDocument> DecodeEaselDocument(
      const base::DictValue& dict,
      std::vector<SyncedAssetRef>* out_assets = nullptr);

  // 12. note.document
  static base::DictValue EncodeNoteDocument(const NoteDocument& doc,
                                            std::vector<SyncedAssetRef> assets);
  static std::optional<NoteDocument> DecodeNoteDocument(
      const base::DictValue& dict,
      std::vector<SyncedAssetRef>* out_assets = nullptr);

  // 13. history.profile (capped at 5,000 most recent entries)
  static base::DictValue EncodeHistoryProfile(
      const ProfileID& profile_id,
      std::vector<HistoryEntry> entries);
  static std::optional<std::vector<HistoryEntry>> DecodeHistoryProfile(
      const base::DictValue& dict,
      ProfileID* out_profile_id = nullptr);

  // 14. extensions.profile
  static base::DictValue EncodeExtensionsProfile(
      const ProfileID& profile_id,
      std::vector<SyncedExtensionRecord> extensions);
  static std::optional<std::vector<SyncedExtensionRecord>>
  DecodeExtensionsProfile(const base::DictValue& dict,
                          ProfileID* out_profile_id = nullptr);

  // 15. credentials.profile (E2EE only)
  static base::DictValue EncodeCredentialsProfile(
      const SyncedCredentialsProfilePayload& payload);
  static std::optional<SyncedCredentialsProfilePayload>
  DecodeCredentialsProfile(const base::DictValue& dict);

  // 16. sitePermissions.profile
  static base::DictValue EncodeSitePermissionsProfile(
      const SyncedSitePermissionsProfilePayload& payload);
  static std::optional<SyncedSitePermissionsProfilePayload>
  DecodeSitePermissionsProfile(const base::DictValue& dict);
};

// --- Local / Remote Bundle Adapter Contract ---

struct SyncLocalRecord {
  SyncCollection collection = SyncCollection::kWorkspaceMeta;
  std::string record_id;
  std::string payload_json;  // Deterministic UTF-8 JSON
};

struct SyncLocalBlob {
  std::string blob_id;
  std::vector<uint8_t> data;
};

struct SyncLocalBundle {
  std::vector<SyncLocalRecord> records;
  std::vector<SyncLocalBlob> blobs;
  std::set<SyncCollection> complete_collections;
  std::vector<std::string> warnings;
};

struct SyncRemoteRecord {
  SyncCollection collection = SyncCollection::kWorkspaceMeta;
  std::string record_id;
  bool deleted = false;
  std::optional<std::string> payload_json;
  int64_t client_updated_at_ms = 0;
  int revision = 0;
  std::optional<std::string> updated_by_device_id;
  std::string payload_hash;
};

struct SyncRemoteBundle {
  std::vector<SyncRemoteRecord> records;
  std::map<std::string, std::vector<uint8_t>> blobs;
  bool is_full_snapshot = false;
};

struct SyncApplyOutcome {
  std::vector<SyncPendingExtension> pending_extension_installs;
  std::vector<std::string> warnings;
};

class SyncDataAdapter {
 public:
  virtual ~SyncDataAdapter() = default;

  virtual SyncLocalBundle CollectLocalData(
      const SyncCategorySettings& categories,
      const SyncVaultKeys& vault_keys) = 0;

  virtual SyncApplyOutcome ApplyRemoteData(
      const SyncRemoteBundle& bundle,
      SyncApplyMode mode,
      const SyncCategorySettings& categories) = 0;

  virtual bool PrepareLocalBackup(const base::FilePath& backup_dir) = 0;
};

using SyncStorageAdapter = SyncDataAdapter;

// --- HTTP Transport Interface (SimpleURLLoader-compatible) ---

struct SyncHttpRequest {
  std::string method;  // GET, POST, PATCH, PUT, DELETE, HEAD
  std::string url;
  std::map<std::string, std::string> headers;
  std::string content_type;
  std::vector<uint8_t> body;
  size_t max_response_bytes = kSyncMaxJsonResponseBytes;
};

struct SyncHttpResponse {
  int status_code = 0;  // 0 on network/transport error
  int net_error = 0;
  std::vector<uint8_t> body;
  std::string error_message;
};

class SyncHttpTransport {
 public:
  using Callback = base::OnceCallback<void(SyncHttpResponse)>;
  virtual ~SyncHttpTransport() = default;

  virtual void Send(SyncHttpRequest request, Callback callback) = 0;
};

// Creates a Chromium network::SimpleURLLoader-backed SyncHttpTransport.
std::unique_ptr<SyncHttpTransport> CreateSimpleURLLoaderSyncTransport(
    scoped_refptr<network::SharedURLLoaderFactory> url_loader_factory);

// --- Real-Time WebSocket Wakeup Listener (/v1/sync/ws) ---

class SyncWebSocketClient {
 public:
  struct Delegate {
    virtual ~Delegate() = default;
    virtual void OnWsConnected(int server_revision, int reset_revision) = 0;
    virtual void OnWsSyncAvailable(int revision,
                                   int reset_revision,
                                   const std::string& source_device_id) = 0;
    virtual void OnWsSessionRevoked() = 0;
    virtual void OnWsDisconnected(int close_code,
                                  const std::string& reason,
                                  int http_status) = 0;
  };

  virtual ~SyncWebSocketClient() = default;
  virtual void Connect(const std::string& ws_url,
                       const std::string& access_token,
                       const std::string& device_id,
                       Delegate* delegate) = 0;
  virtual void SendText(const std::string& text) = 0;
  virtual void Disconnect() = 0;
  virtual bool IsConnected() const { return false; }
};

// --- Main SyncEngine ---

class SyncEngine final : public SyncWebSocketClient::Delegate {
 public:
  using ResultCallback = base::OnceCallback<void(SyncResult)>;
  using StatusCallback = base::OnceCallback<void(SyncStatusInfo)>;
  using DevicesCallback =
      base::OnceCallback<void(bool ok, std::vector<SyncDeviceInfo>, std::string)>;
  using SnapshotCallback =
      base::RepeatingCallback<void(const SyncAccountSnapshot&)>;
  using StatusInfoObserver =
      base::RepeatingCallback<void(const SyncStatusInfo&)>;

  SyncEngine(base::FilePath data_root,
             std::unique_ptr<SyncHttpTransport> http_transport,
             std::unique_ptr<SecretStore> secret_store = nullptr,
             std::unique_ptr<SyncWebSocketClient> ws_client = nullptr);
  SyncEngine(std::filesystem::path state_dir,
             BrowserModel* model,
             std::unique_ptr<SecretStore> secrets,
             scoped_refptr<network::SharedURLLoaderFactory> loader_factory);
  ~SyncEngine() override;

  SyncEngine(const SyncEngine&) = delete;
  SyncEngine& operator=(const SyncEngine&) = delete;

  void SetDataAdapter(SyncDataAdapter* adapter) { data_adapter_ = adapter; }
  void SetWebSocketClient(std::unique_ptr<SyncWebSocketClient> ws_client);
  void SetNetworkContextProvider(
      base::RepeatingCallback<network::mojom::NetworkContext*()> provider);
  void SetCredentialAccountKey(std::string account_key);
  void SetOnSnapshotChanged(SnapshotCallback cb) {
    on_snapshot_changed_ = std::move(cb);
  }
  void SetStatusObserver(StatusInfoObserver cb) {
    status_info_observer_ = std::move(cb);
  }

  SyncStatusInfo Status() const;
  SyncDetailedStatus GetDetailedStatus() const;
  bool is_websocket_connected() const { return ws_connected_; }
  size_t pending_push_count() const { return pending_push_count_; }
  void ConfigureServer(std::string url,
                       std::map<std::string, bool> categories,
                       StatusCallback done);
  void Register(std::string email,
                std::string password,
                std::string url,
                base::OnceCallback<void(base::expected<std::string, std::string>)>
                    done);
  void Login(std::string email,
             std::string password,
             std::string url,
             base::OnceCallback<void(base::expected<bool, std::string>)> done);
  void Logout(StatusCallback done);
  void Recover(std::string email,
               std::string recovery_key,
               std::string new_password,
               std::string url,
               base::OnceCallback<void(base::expected<void, std::string>)> done);
  void ListDevices(base::OnceCallback<void(std::vector<SyncDeviceInfo>)> done);
  void Shutdown() { StopAndFlush(); }

  const SyncAccountSnapshot& snapshot() const { return snapshot_; }
  bool is_signed_in() const {
    return state_.has_value() && state_->account_id.has_value() &&
           vault_keys_.has_value();
  }
  bool is_applying_remote() const { return is_applying_remote_; }

  // Validates and normalizes server URL (http(s)://host[:port][/path], no
  // query/fragment/userinfo, trailing slashes stripped).
  static std::optional<std::string> ValidateServerUrl(std::string_view raw);

  // Cheap when signed out (single PathExists on State/sync-state.json).
  void StartIfSignedIn();

  // Configures the default server URL before sign-in/sign-up.
  bool ConfigureServerUrl(std::string_view server_url);

  // Account lifecycle (§4.2, §4.3).
  void SignUp(const std::string& server_url,
              const std::string& email,
              const std::string& password,
              const std::string& display_name,
              ResultCallback callback);

  void SignIn(const std::string& server_url,
              const std::string& email,
              const std::string& password,
              std::optional<FirstSyncStrategy> initial_strategy,
              ResultCallback callback);

  void RecoverAccount(const std::string& server_url,
                      const std::string& email,
                      const std::string& recovery_key,
                      const std::string& new_password,
                      std::optional<FirstSyncStrategy> initial_strategy,
                      ResultCallback callback);

  void CompleteInitialSync(FirstSyncStrategy strategy, ResultCallback callback);

  void ChangePassword(const std::string& current_password,
                      const std::string& new_password,
                      bool revoke_other_sessions,
                      ResultCallback callback);
  void ChangePassword(const std::string& current_password,
                      const std::string& new_password,
                      ResultCallback callback);

  void UpdateDisplayName(const std::string& display_name,
                         ResultCallback callback);

  void RefreshDevices(DevicesCallback callback);
  void RevokeDevice(const std::string& device_id, ResultCallback callback);
  void SignOut(base::OnceClosure callback);
  void DeleteAccount(const std::string& password, ResultCallback callback);

  // Sync control (§4.4).
  void SyncNow(ResultCallback callback = {});
  void PullNow(ResultCallback callback = {});
  void SchedulePush(std::string_view reason);
  void ScheduleCollectionPush(std::string_view collection,
                              std::string_view item_id = {});
  void SetCategoryEnabled(SyncCategory category, bool enabled);
  void ResolvePendingExtensionInstalls(
      const std::vector<std::string>& extension_ids);
  void StopAndFlush();

  // Exposed for WebSocket frames delivered externally or by SyncWebSocketClient.
  void HandleWebSocketTextFrame(std::string_view json_text);

  // SyncWebSocketClient::Delegate:
  void OnWsConnected(int server_revision, int reset_revision) override;
  void OnWsSyncAvailable(int revision,
                         int reset_revision,
                         const std::string& source_device_id) override;
  void OnWsSessionRevoked() override;
  void OnWsDisconnected(int close_code,
                        const std::string& reason,
                        int http_status) override;

 private:
  struct PendingPushMutation {
    std::string key;
    SyncCollection collection = SyncCollection::kWorkspaceMeta;
    std::string record_id;
    bool deleted = false;
    std::string payload_json;
    std::string payload_hash;
    int64_t client_updated_at_ms = 0;
    std::string ciphertext_base64;
  };

  struct PullPassState {
    int start_since = 0;
    int current_since = 0;
    int current_revision = 0;
    int reset_revision = 0;
    bool full_resync = false;
    int pages = 0;
    std::map<std::string, SyncRemoteRecord> by_key;
    std::vector<std::string> order;
    std::vector<std::string> warnings;
    std::vector<SyncCollection> filter_collections;
  };

  struct PushDiffResult {
    bool ok = false;
    bool had_conflicts = false;
    int current_revision = 0;
    int reset_revision = 0;
    int accepted_count = 0;
    std::optional<int> clean_cursor;
    std::string error;
  };

  struct SyncPassContext {
    SyncPassContext();
    ~SyncPassContext();

    int round = 0;
    uint64_t generation = 0;
    std::optional<FirstSyncStrategy> initial_strategy;
    SyncCategorySettings categories;
    std::set<SyncCollection> enabled;

    std::shared_ptr<PullPassState> pull_state;
    bool full_reset = false;

    std::vector<SyncCategory> processed_backfill;
    std::set<SyncCollection> backfill_collections;
    std::vector<SyncRemoteRecord> backfill_records;

    std::optional<SyncLocalBundle> pre_apply_local;
    std::set<std::string> dirty_before_apply;
    std::set<std::string> pushed_first;
    std::optional<int> cursor_after_push;

    std::vector<SyncRemoteRecord> remote;
    std::vector<SyncRemoteRecord> changed;
    std::vector<std::string> pass_warnings;
  };

  struct BlobDownloadResult {
    BlobDownloadResult();
    BlobDownloadResult(BlobDownloadResult&&) noexcept;
    BlobDownloadResult& operator=(BlobDownloadResult&&) noexcept;
    ~BlobDownloadResult();

    bool ok = true;
    std::string error;
    std::map<std::string, std::vector<uint8_t>> blobs;
    std::set<std::string> deferred_keys;
    bool had_cap_skips = false;
    std::vector<std::string> warnings;
  };

  base::FilePath StateFilePath() const;
  base::FilePath BackupsDirPath() const;
  std::string CredentialAccountKey() const;
  scoped_refptr<base::SequencedTaskRunner> GetOrCreateIoTaskRunner() const;
  bool SaveStateToDisk() const;
  std::optional<SyncPersistedState> LoadStateFromDisk() const;
  void DeleteStateFromDisk() const;
  bool SaveCredentialsToStore(const SyncCredentials& creds);
  std::optional<SyncCredentials> LoadCredentialsFromStore();
  void DeleteCredentialsFromStore();

  void PublishSnapshot();
  void SetStatus(SyncStatusKind kind, std::string message = {});
  void ClearLocalSession(SyncStatusKind new_status, std::string message = {});

  // Authenticated HTTP request wrappers with single 401 refresh + retry.
  void SendAuthenticatedJson(
      const std::string& method,
      const std::string& path_and_query,
      std::optional<base::DictValue> body,
      base::OnceCallback<void(SyncHttpResponse)> callback);
  void SendAuthenticatedBinary(
      const std::string& method,
      const std::string& path,
      std::string content_type,
      std::string accept_header,
      std::vector<uint8_t> body,
      size_t max_response_bytes,
      base::OnceCallback<void(SyncHttpResponse)> callback);
  void SendJson(const std::string& method,
                const std::string& full_url,
                std::optional<base::DictValue> body,
                std::optional<std::string> bearer_token,
                base::OnceCallback<void(SyncHttpResponse)> callback);
  void SendRaw(const std::string& method,
               const std::string& full_url,
               std::string content_type,
               std::string accept_header,
               std::vector<uint8_t> body,
               size_t max_response_bytes,
               std::optional<std::string> bearer_token,
               base::OnceCallback<void(SyncHttpResponse)> callback);
  void RefreshAccessToken(base::OnceCallback<void(bool ok)> callback);

  // Sync pass stages (pull -> backfill -> LWW push-before-pull -> conflict
  // re-pull -> blob download -> apply -> echo suppression -> final push).
  void StartSyncPass(int round,
                     std::optional<FirstSyncStrategy> initial_strategy);
  void PullAllPages(
      std::shared_ptr<PullPassState> pull_state,
      base::OnceCallback<void(bool ok, std::string error)> on_done);
  void OnInitialPullCompleted(std::shared_ptr<SyncPassContext> ctx,
                              bool ok,
                              std::string error);
  void OnBackfillPullCompleted(std::shared_ptr<SyncPassContext> ctx,
                               std::shared_ptr<PullPassState> backfill_state,
                               bool ok,
                               std::string error);
  void ContinueAfterPulls(std::shared_ptr<SyncPassContext> ctx);
  void OnEarlyPushCompleted(std::shared_ptr<SyncPassContext> ctx,
                            PushDiffResult result);
  void OnConflictRepullCompleted(std::shared_ptr<SyncPassContext> ctx,
                                 std::shared_ptr<PullPassState> repull_state,
                                 bool ok,
                                 std::string error);
  void PrepareApplyRemote(std::shared_ptr<SyncPassContext> ctx);
  struct BlobDownloadState;

  void DownloadBlobsForRecords(
      const std::vector<SyncRemoteRecord>& records,
      uint64_t generation,
      base::OnceCallback<void(BlobDownloadResult)> on_done);
  void DownloadNextBlob(std::shared_ptr<BlobDownloadState> state);
  void ApplyAndFinishPass(std::shared_ptr<SyncPassContext> ctx,
                          BlobDownloadResult blob_result);
  void PushLocalDiff(const SyncLocalBundle& local,
                     SyncPushMode mode,
                     std::optional<int> cursor_base,
                     base::OnceCallback<void(PushDiffResult)> on_done);
  void UploadBlobsAndPushBatches(
      std::shared_ptr<std::vector<SyncLocalBlob>> blob_queue,
      size_t blob_index,
      uint64_t generation,
      std::shared_ptr<std::vector<std::vector<PendingPushMutation>>> batches,
      SyncPushMode mode,
      std::optional<int> cursor_base,
      base::OnceCallback<void(PushDiffResult)> on_done);
  void PushMutationBatches(
      std::shared_ptr<std::vector<std::vector<PendingPushMutation>>> batches,
      size_t batch_index,
      SyncPushMode mode,
      std::optional<int> cursor_base,
      std::optional<int> chain_cursor,
      bool any_conflicts,
      int last_revision,
      int last_reset_revision,
      int total_accepted,
      base::OnceCallback<void(PushDiffResult)> on_done);
  void FinishSyncPass(bool ok,
                      const std::string& error_code,
                      const std::string& error_message);

  void StartWebSocket();
  void StopWebSocket();
  void ScheduleWebSocketReconnect(bool force_refresh);
  void SendWebSocketPing();

  static std::string GenerateUuidLower();
  static int64_t NowEpochMs();
  static std::pair<std::string, std::string> ParseServerError(
      const SyncHttpResponse& resp);

  base::FilePath data_root_;
  std::string credential_account_key_;
  mutable scoped_refptr<base::SequencedTaskRunner> io_task_runner_;
  std::unique_ptr<SyncHttpTransport> http_transport_;
  std::unique_ptr<SecretStore> secret_store_;
  std::unique_ptr<SyncWebSocketClient> ws_client_;
  raw_ptr<SyncDataAdapter> data_adapter_ = nullptr;
  SnapshotCallback on_snapshot_changed_;
  StatusInfoObserver status_info_observer_;

  std::optional<SyncPersistedState> state_;
  std::optional<SyncCredentials> credentials_;
  std::optional<SyncVaultKeys> vault_keys_;

  SyncAccountSnapshot snapshot_;
  SyncStatusKind status_ = SyncStatusKind::kSignedOut;
  std::string status_message_;
  std::vector<SyncDeviceInfo> devices_;
  std::vector<std::string> warnings_;
  std::optional<std::string> last_reauth_email_;

  bool started_ = false;
  bool is_applying_remote_ = false;
  bool sync_in_flight_ = false;
  bool follow_up_sync_requested_ = false;
  bool refresh_in_flight_ = false;
  uint64_t session_generation_ = 0;

  std::vector<ResultCallback> pending_sync_callbacks_;
  std::vector<base::OnceCallback<void(bool)>> pending_refresh_callbacks_;

  base::OneShotTimer push_debounce_timer_;
  int64_t push_burst_started_ms_ = 0;
  size_t pending_push_count_ = 0;

  base::OneShotTimer ws_reconnect_timer_;
  base::RepeatingTimer ws_ping_timer_;
  double ws_backoff_seconds_ = 1.0;
  bool ws_force_refresh_next_ = false;
  bool ws_connected_ = false;

  base::WeakPtrFactory<SyncEngine> weak_factory_{this};
};

}  // namespace open_unified

#endif  // OPEN_UNIFIED_CORE_SYNC_SYNC_ENGINE_H_
