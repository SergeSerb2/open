// Copyright 2026 The Open Authors. All rights reserved.
// Open Account & Sync v1 client-side cryptography using BoringSSL.
// Wire-compatible with docs/sync-protocol.md and SyncServer/.

#ifndef OPEN_UNIFIED_CORE_SYNC_SYNC_CRYPTO_H_
#define OPEN_UNIFIED_CORE_SYNC_SYNC_CRYPTO_H_

#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace open_unified {

// Constants matching docs/sync-protocol.md §1.
inline constexpr char kSyncKdfAlgorithmPbkdf2Sha256[] = "pbkdf2-sha256";
inline constexpr int kSyncKdfDefaultIterations = 600000;
inline constexpr int kSyncKdfMinIterations = 300000;
inline constexpr int kSyncKdfMaxIterations = 2000000;

inline constexpr size_t kSyncKeyBytes = 32;
inline constexpr size_t kSyncNonceBytes = 12;
inline constexpr size_t kSyncGcmTagBytes = 16;
inline constexpr size_t kSyncWrappedVaultKeyBytes =
    kSyncNonceBytes + kSyncKeyBytes + kSyncGcmTagBytes;  // 60 bytes

inline constexpr char kSyncTombstonePayload[] = R"({"t":1})";

struct SyncKdfParams {
  std::string algorithm = kSyncKdfAlgorithmPbkdf2Sha256;
  int iterations = kSyncKdfDefaultIterations;
  std::string salt_base64;

  // Generates fresh KDF params with a 32-byte random salt.
  static std::optional<SyncKdfParams> Generate(
      int iterations = kSyncKdfDefaultIterations);

  // Validates algorithm, iteration range [300k..2M], and 32-byte salt.
  std::optional<std::vector<uint8_t>> ValidateAndDecodeSalt() const;
};

struct SyncDerivedPasswordKeys {
  std::vector<uint8_t> auth_verifier;     // 32 bytes (sent to server)
  std::vector<uint8_t> password_wrap_key;  // 32 bytes (stays on client)

  ~SyncDerivedPasswordKeys();
  SyncDerivedPasswordKeys() = default;
  SyncDerivedPasswordKeys(SyncDerivedPasswordKeys&&) noexcept = default;
  SyncDerivedPasswordKeys& operator=(SyncDerivedPasswordKeys&&) noexcept =
      default;
  SyncDerivedPasswordKeys(const SyncDerivedPasswordKeys&) = delete;
  SyncDerivedPasswordKeys& operator=(const SyncDerivedPasswordKeys&) = delete;
};

struct SyncDerivedRecoveryKeys {
  std::vector<uint8_t> recovery_auth_verifier;  // 32 bytes (sent to server)
  std::vector<uint8_t> recovery_wrap_key;       // 32 bytes (stays on client)

  ~SyncDerivedRecoveryKeys();
  SyncDerivedRecoveryKeys() = default;
  SyncDerivedRecoveryKeys(SyncDerivedRecoveryKeys&&) noexcept = default;
  SyncDerivedRecoveryKeys& operator=(SyncDerivedRecoveryKeys&&) noexcept =
      default;
  SyncDerivedRecoveryKeys(const SyncDerivedRecoveryKeys&) = delete;
  SyncDerivedRecoveryKeys& operator=(const SyncDerivedRecoveryKeys&) = delete;
};

struct SyncGeneratedRecoveryKey {
  std::vector<uint8_t> raw_bytes;  // 32 bytes
  std::string formatted;           // OPEN-XXXX-XXXX-... (13 groups of 4)

  ~SyncGeneratedRecoveryKey();
  SyncGeneratedRecoveryKey() = default;
  SyncGeneratedRecoveryKey(SyncGeneratedRecoveryKey&&) noexcept = default;
  SyncGeneratedRecoveryKey& operator=(SyncGeneratedRecoveryKey&&) noexcept =
      default;
  SyncGeneratedRecoveryKey(const SyncGeneratedRecoveryKey&) = delete;
  SyncGeneratedRecoveryKey& operator=(const SyncGeneratedRecoveryKey&) = delete;
};

// Vault subkeys derived via HKDF-SHA256 from the 32-byte vault key.
// Cleanses all key material in its destructor using OPENSSL_cleanse.
struct SyncVaultKeys {
  std::array<uint8_t, kSyncKeyBytes> record_enc_key{};
  std::array<uint8_t, kSyncKeyBytes> blob_enc_key{};
  std::array<uint8_t, kSyncKeyBytes> payload_hash_key{};
  std::array<uint8_t, kSyncKeyBytes> blob_id_key{};

  SyncVaultKeys() = default;
  ~SyncVaultKeys();
  SyncVaultKeys(const SyncVaultKeys&) = default;
  SyncVaultKeys& operator=(const SyncVaultKeys&) = default;
  SyncVaultKeys(SyncVaultKeys&&) noexcept;
  SyncVaultKeys& operator=(SyncVaultKeys&&) noexcept;

  static std::optional<SyncVaultKeys> DeriveFromVaultKey(
      const std::vector<uint8_t>& vault_key);
};

enum class SyncVaultWrapKind {
  kPassword,  // AAD tag: "vault-pw"
  kRecovery,  // AAD tag: "vault-rec"
};

class SyncCrypto {
 public:
  // Securely wipes memory using BoringSSL's OPENSSL_cleanse.
  static void SecureZero(void* data, size_t size);
  static void SecureZero(std::vector<uint8_t>& bytes);
  static void SecureZero(std::string& text);

  // Generates |count| cryptographically random bytes via RAND_bytes.
  static std::optional<std::vector<uint8_t>> RandomBytes(size_t count);

  // Email normalization and validation (§1.1).
  static std::string NormalizeEmail(std::string_view email);
  static bool IsValidNormalizedEmail(std::string_view normalized_email);

  // Password key derivation (§1.2):
  // PBKDF2-HMAC-SHA256 over password with salt = kdfSalt || "open-sync-v1:" ||
  // normalizedEmail, followed by HKDF-SHA256 into authKey and passwordWrapKey.
  static std::optional<SyncDerivedPasswordKeys> DerivePasswordKeys(
      std::string_view email,
      std::string_view password,
      const SyncKdfParams& kdf_params);

  // Recovery key generation, Base32 OPEN-XXXX-... formatting/parsing, and
  // HKDF-SHA256 key derivation (§1.3).
  static std::optional<SyncGeneratedRecoveryKey> GenerateRecoveryKey();
  static std::string FormatRecoveryKey(const std::vector<uint8_t>& raw_bytes);
  static std::optional<std::vector<uint8_t>> ParseRecoveryKey(
      std::string_view text);
  static std::optional<SyncDerivedRecoveryKeys> DeriveRecoveryKeys(
      const std::vector<uint8_t>& recovery_key_bytes);

  // RFC 4648 uppercase Base32 (no padding), rejecting non-zero trailing bits.
  static std::string Base32Encode(const uint8_t* data, size_t size);
  static std::optional<std::vector<uint8_t>> Base32Decode(
      std::string_view text);

  // HKDF-SHA256 with empty salt ("") and 32-byte output.
  static bool HkdfSha256(const uint8_t* ikm,
                         size_t ikm_len,
                         std::string_view info,
                         uint8_t out[kSyncKeyBytes]);

  // Exact v1 AAD strings (§1.6).
  static std::string VaultAad(SyncVaultWrapKind kind,
                              std::string_view normalized_email);
  static std::string RecordAad(std::string_view account_id,
                               std::string_view collection,
                               std::string_view record_id,
                               bool deleted);
  static std::string BlobAad(std::string_view account_id,
                             std::string_view blob_id);

  // AES-256-GCM seal/open with combined wire layout:
  // [12B nonce] || [ciphertext] || [16B GCM tag].
  static std::optional<std::vector<uint8_t>> Aes256GcmSeal(
      const uint8_t* plaintext,
      size_t plaintext_len,
      const uint8_t key[kSyncKeyBytes],
      std::string_view aad);
  static std::optional<std::vector<uint8_t>> Aes256GcmOpen(
      const uint8_t* combined,
      size_t combined_len,
      const uint8_t key[kSyncKeyBytes],
      std::string_view aad);

  // Vault key wrapping (always 60 bytes combined).
  static std::optional<std::vector<uint8_t>> WrapVaultKey(
      const std::vector<uint8_t>& vault_key,
      const std::vector<uint8_t>& wrap_key,
      SyncVaultWrapKind kind,
      std::string_view email);
  static std::optional<std::vector<uint8_t>> UnwrapVaultKey(
      const std::vector<uint8_t>& wrapped,
      const std::vector<uint8_t>& wrap_key,
      SyncVaultWrapKind kind,
      std::string_view email);

  // Record & blob encryption/decryption (§1.5, §1.6).
  static std::optional<std::vector<uint8_t>> SealRecord(
      const std::vector<uint8_t>& plaintext,
      const SyncVaultKeys& keys,
      std::string_view account_id,
      std::string_view collection,
      std::string_view record_id,
      bool deleted);
  static std::optional<std::vector<uint8_t>> OpenRecord(
      const std::vector<uint8_t>& combined,
      const SyncVaultKeys& keys,
      std::string_view account_id,
      std::string_view collection,
      std::string_view record_id,
      bool deleted);

  static std::optional<std::vector<uint8_t>> SealBlob(
      const std::vector<uint8_t>& plaintext,
      const SyncVaultKeys& keys,
      std::string_view account_id,
      std::string_view blob_id);
  static std::optional<std::vector<uint8_t>> OpenBlob(
      const std::vector<uint8_t>& combined,
      const SyncVaultKeys& keys,
      std::string_view account_id,
      std::string_view blob_id);

  // Keyed HMAC-SHA256 & plain SHA-256 helpers (64 lowercase hex chars).
  static std::string ComputePayloadHash(const uint8_t* plaintext,
                                        size_t plaintext_len,
                                        const SyncVaultKeys& keys);
  static std::string ComputePayloadHash(std::string_view plaintext,
                                        const SyncVaultKeys& keys);
  static std::string ComputeBlobId(const uint8_t* plaintext,
                                   size_t plaintext_len,
                                   const SyncVaultKeys& keys);
  static std::string Sha256Hex(const uint8_t* data, size_t size);
  static std::string HexLower(const uint8_t* data, size_t size);
  static bool IsValidBlobId(std::string_view value);
};

}  // namespace open_unified

#endif  // OPEN_UNIFIED_CORE_SYNC_SYNC_CRYPTO_H_
