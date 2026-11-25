// Copyright 2026 The Open Authors. All rights reserved.
// Open Account & Sync v1 client-side cryptography implementation (BoringSSL).

#include "open_unified/core/sync/sync_crypto.h"

#include <openssl/evp.h>
#include <openssl/hkdf.h>
#include <openssl/hmac.h>
#include <openssl/mem.h>
#include <openssl/rand.h>
#include <openssl/sha.h>

#include <algorithm>
#include <cctype>
#include <cstring>
#include <limits>
#include <memory>

#include "base/base64.h"
#include "base/containers/span.h"
#include "base/strings/string_util.h"

namespace open_unified {

namespace {

constexpr char kSaltDomainTag[] = "open-sync-v1:";
constexpr char kAuthInfo[] = "open-sync-auth-v1";
constexpr char kWrapInfo[] = "open-sync-wrap-v1";
constexpr char kRecoveryAuthInfo[] = "open-sync-recovery-auth-v1";
constexpr char kRecoveryWrapInfo[] = "open-sync-recovery-wrap-v1";
constexpr char kRecordEncInfo[] = "open-sync-record-enc-v1";
constexpr char kBlobEncInfo[] = "open-sync-blob-enc-v1";
constexpr char kPayloadHashInfo[] = "open-sync-payload-hash-v1";
constexpr char kBlobIdInfo[] = "open-sync-blob-id-v1";

constexpr char kRecoveryPrefix[] = "OPEN";
constexpr char kBase32Alphabet[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";

struct EvpCipherCtxDeleter {
  void operator()(EVP_CIPHER_CTX* ctx) const {
    if (ctx) {
      EVP_CIPHER_CTX_free(ctx);
    }
  }
};
using ScopedEvpCipherCtx = std::unique_ptr<EVP_CIPHER_CTX, EvpCipherCtxDeleter>;

bool IsWhitespaceByte(unsigned char c) {
  return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f' ||
         c == '\v';
}

std::string HmacSha256Hex(const uint8_t key[kSyncKeyBytes],
                          const uint8_t* data,
                          size_t data_len) {
  uint8_t digest[EVP_MAX_MD_SIZE]{};
  unsigned int digest_len = 0;
  if (!HMAC(EVP_sha256(), key, kSyncKeyBytes, data, data_len, digest,
            &digest_len) ||
      digest_len != 32) {
    SyncCrypto::SecureZero(digest, sizeof(digest));
    return {};
  }
  std::string hex = SyncCrypto::HexLower(digest, digest_len);
  SyncCrypto::SecureZero(digest, sizeof(digest));
  return hex;
}

}  // namespace

// --- RAII cleansing destructors ---

SyncDerivedPasswordKeys::~SyncDerivedPasswordKeys() {
  SyncCrypto::SecureZero(auth_verifier);
  SyncCrypto::SecureZero(password_wrap_key);
}

SyncDerivedRecoveryKeys::~SyncDerivedRecoveryKeys() {
  SyncCrypto::SecureZero(recovery_auth_verifier);
  SyncCrypto::SecureZero(recovery_wrap_key);
}

SyncGeneratedRecoveryKey::~SyncGeneratedRecoveryKey() {
  SyncCrypto::SecureZero(raw_bytes);
  SyncCrypto::SecureZero(formatted);
}

SyncVaultKeys::~SyncVaultKeys() {
  SyncCrypto::SecureZero(record_enc_key.data(), record_enc_key.size());
  SyncCrypto::SecureZero(blob_enc_key.data(), blob_enc_key.size());
  SyncCrypto::SecureZero(payload_hash_key.data(), payload_hash_key.size());
  SyncCrypto::SecureZero(blob_id_key.data(), blob_id_key.size());
}

SyncVaultKeys::SyncVaultKeys(SyncVaultKeys&& other) noexcept
    : record_enc_key(other.record_enc_key),
      blob_enc_key(other.blob_enc_key),
      payload_hash_key(other.payload_hash_key),
      blob_id_key(other.blob_id_key) {
  SyncCrypto::SecureZero(other.record_enc_key.data(),
                         other.record_enc_key.size());
  SyncCrypto::SecureZero(other.blob_enc_key.data(), other.blob_enc_key.size());
  SyncCrypto::SecureZero(other.payload_hash_key.data(),
                         other.payload_hash_key.size());
  SyncCrypto::SecureZero(other.blob_id_key.data(), other.blob_id_key.size());
}

SyncVaultKeys& SyncVaultKeys::operator=(SyncVaultKeys&& other) noexcept {
  if (this != &other) {
    record_enc_key = other.record_enc_key;
    blob_enc_key = other.blob_enc_key;
    payload_hash_key = other.payload_hash_key;
    blob_id_key = other.blob_id_key;
    SyncCrypto::SecureZero(other.record_enc_key.data(),
                           other.record_enc_key.size());
    SyncCrypto::SecureZero(other.blob_enc_key.data(),
                           other.blob_enc_key.size());
    SyncCrypto::SecureZero(other.payload_hash_key.data(),
                           other.payload_hash_key.size());
    SyncCrypto::SecureZero(other.blob_id_key.data(), other.blob_id_key.size());
  }
  return *this;
}

// static
std::optional<SyncVaultKeys> SyncVaultKeys::DeriveFromVaultKey(
    const std::vector<uint8_t>& vault_key) {
  if (vault_key.size() != kSyncKeyBytes) {
    return std::nullopt;
  }
  SyncVaultKeys keys;
  if (!SyncCrypto::HkdfSha256(vault_key.data(), vault_key.size(),
                              kRecordEncInfo, keys.record_enc_key.data()) ||
      !SyncCrypto::HkdfSha256(vault_key.data(), vault_key.size(), kBlobEncInfo,
                              keys.blob_enc_key.data()) ||
      !SyncCrypto::HkdfSha256(vault_key.data(), vault_key.size(),
                              kPayloadHashInfo, keys.payload_hash_key.data()) ||
      !SyncCrypto::HkdfSha256(vault_key.data(), vault_key.size(), kBlobIdInfo,
                              keys.blob_id_key.data())) {
    return std::nullopt;
  }
  return keys;
}

// --- SyncKdfParams ---

// static
std::optional<SyncKdfParams> SyncKdfParams::Generate(int iterations) {
  if (iterations < kSyncKdfMinIterations ||
      iterations > kSyncKdfMaxIterations) {
    return std::nullopt;
  }
  auto salt = SyncCrypto::RandomBytes(kSyncKeyBytes);
  if (!salt) {
    return std::nullopt;
  }
  SyncKdfParams params;
  params.algorithm = kSyncKdfAlgorithmPbkdf2Sha256;
  params.iterations = iterations;
  params.salt_base64 = base::Base64Encode(*salt);
  SyncCrypto::SecureZero(*salt);
  return params;
}

std::optional<std::vector<uint8_t>> SyncKdfParams::ValidateAndDecodeSalt()
    const {
  if (algorithm != kSyncKdfAlgorithmPbkdf2Sha256) {
    return std::nullopt;
  }
  if (iterations < kSyncKdfMinIterations ||
      iterations > kSyncKdfMaxIterations) {
    return std::nullopt;
  }
  auto decoded = base::Base64Decode(salt_base64);
  if (!decoded || decoded->size() != kSyncKeyBytes) {
    return std::nullopt;
  }
  return decoded;
}

// --- SyncCrypto ---

// static
void SyncCrypto::SecureZero(void* data, size_t size) {
  if (data && size > 0) {
    OPENSSL_cleanse(data, size);
  }
}

// static
void SyncCrypto::SecureZero(std::vector<uint8_t>& bytes) {
  if (!bytes.empty()) {
    OPENSSL_cleanse(bytes.data(), bytes.size());
  }
}

// static
void SyncCrypto::SecureZero(std::string& text) {
  if (!text.empty()) {
    OPENSSL_cleanse(text.data(), text.size());
  }
}

// static
std::optional<std::vector<uint8_t>> SyncCrypto::RandomBytes(size_t count) {
  std::vector<uint8_t> out(count);
  if (count > 0 && RAND_bytes(out.data(), out.size()) != 1) {
    SecureZero(out);
    return std::nullopt;
  }
  return out;
}

// static
std::string SyncCrypto::NormalizeEmail(std::string_view email) {
  std::string_view trimmed = base::TrimWhitespaceASCII(email, base::TRIM_ALL);
  return base::ToLowerASCII(trimmed);
}

// static
bool SyncCrypto::IsValidNormalizedEmail(std::string_view normalized_email) {
  if (normalized_email.size() < 3 || normalized_email.size() > 254) {
    return false;
  }
  for (unsigned char c : normalized_email) {
    if (IsWhitespaceByte(c)) {
      return false;
    }
  }
  size_t at = normalized_email.rfind('@');
  if (at == std::string_view::npos || at == 0 ||
      at + 1 >= normalized_email.size()) {
    return false;
  }
  return true;
}

// static
bool SyncCrypto::HkdfSha256(const uint8_t* ikm,
                            size_t ikm_len,
                            std::string_view info,
                            uint8_t out[kSyncKeyBytes]) {
  return HKDF(out, kSyncKeyBytes, EVP_sha256(), ikm, ikm_len,
              /*salt=*/nullptr, /*salt_len=*/0,
              reinterpret_cast<const uint8_t*>(info.data()), info.size()) == 1;
}

// static
std::optional<SyncDerivedPasswordKeys> SyncCrypto::DerivePasswordKeys(
    std::string_view email,
    std::string_view password,
    const SyncKdfParams& kdf_params) {
  if (password.empty()) {
    return std::nullopt;
  }
  std::string normalized = NormalizeEmail(email);
  auto kdf_salt = kdf_params.ValidateAndDecodeSalt();
  if (!kdf_salt) {
    return std::nullopt;
  }

  // Salt input: kdfSalt || UTF8("open-sync-v1:") || UTF8(normalizedEmail)
  std::vector<uint8_t> salt;
  salt.reserve(kdf_salt->size() + std::strlen(kSaltDomainTag) +
               normalized.size());
  salt.insert(salt.end(), kdf_salt->begin(), kdf_salt->end());
  salt.insert(salt.end(), kSaltDomainTag,
              kSaltDomainTag + std::strlen(kSaltDomainTag));
  salt.insert(salt.end(), normalized.begin(), normalized.end());

  std::array<uint8_t, kSyncKeyBytes> master_key{};
  int ok = PKCS5_PBKDF2_HMAC(
      password.data(), password.size(), salt.data(), salt.size(),
      static_cast<unsigned>(kdf_params.iterations), EVP_sha256(),
      master_key.size(), master_key.data());

  SecureZero(*kdf_salt);
  SecureZero(salt);
  if (ok != 1) {
    SecureZero(master_key.data(), master_key.size());
    return std::nullopt;
  }

  SyncDerivedPasswordKeys result;
  result.auth_verifier.resize(kSyncKeyBytes);
  result.password_wrap_key.resize(kSyncKeyBytes);
  bool derived =
      HkdfSha256(master_key.data(), master_key.size(), kAuthInfo,
                 result.auth_verifier.data()) &&
      HkdfSha256(master_key.data(), master_key.size(), kWrapInfo,
                 result.password_wrap_key.data());
  SecureZero(master_key.data(), master_key.size());
  if (!derived) {
    return std::nullopt;
  }
  return result;
}

// static
std::string SyncCrypto::Base32Encode(const uint8_t* data, size_t size) {
  std::string out;
  out.reserve((size * 8 + 4) / 5);
  uint32_t buffer = 0;
  int bits = 0;
  for (size_t i = 0; i < size; ++i) {
    buffer = (buffer << 8) | data[i];
    bits += 8;
    while (bits >= 5) {
      out.push_back(kBase32Alphabet[(buffer >> (bits - 5)) & 31u]);
      bits -= 5;
    }
    buffer &= (1u << bits) - 1u;
  }
  if (bits > 0) {
    out.push_back(kBase32Alphabet[(buffer << (5 - bits)) & 31u]);
  }
  return out;
}

// static
std::optional<std::vector<uint8_t>> SyncCrypto::Base32Decode(
    std::string_view text) {
  std::array<int8_t, 256> lookup{};
  lookup.fill(-1);
  for (size_t i = 0; i < 32; ++i) {
    lookup[static_cast<unsigned char>(kBase32Alphabet[i])] =
        static_cast<int8_t>(i);
  }

  std::vector<uint8_t> out;
  out.reserve(text.size() * 5 / 8);
  uint32_t buffer = 0;
  int bits = 0;
  for (unsigned char c : text) {
    int8_t val = lookup[c];
    if (val < 0) {
      SecureZero(out);
      return std::nullopt;
    }
    buffer = (buffer << 5) | static_cast<uint32_t>(val);
    bits += 5;
    if (bits >= 8) {
      out.push_back(static_cast<uint8_t>((buffer >> (bits - 8)) & 0xFFu));
      bits -= 8;
      buffer &= (1u << bits) - 1u;
    }
  }
  // Reject non-zero trailing padding bits.
  if (bits >= 5 || buffer != 0) {
    SecureZero(out);
    return std::nullopt;
  }
  return out;
}

// static
std::optional<SyncGeneratedRecoveryKey> SyncCrypto::GenerateRecoveryKey() {
  auto raw = RandomBytes(kSyncKeyBytes);
  if (!raw) {
    return std::nullopt;
  }
  SyncGeneratedRecoveryKey result;
  result.formatted = FormatRecoveryKey(*raw);
  result.raw_bytes = std::move(*raw);
  return result;
}

// static
std::string SyncCrypto::FormatRecoveryKey(
    const std::vector<uint8_t>& raw_bytes) {
  std::string encoded = Base32Encode(raw_bytes.data(), raw_bytes.size());
  std::string out = kRecoveryPrefix;
  for (size_t i = 0; i < encoded.size(); i += 4) {
    out.push_back('-');
    out.append(encoded, i, std::min<size_t>(4, encoded.size() - i));
  }
  SecureZero(encoded);
  return out;
}

// static
std::optional<std::vector<uint8_t>> SyncCrypto::ParseRecoveryKey(
    std::string_view text) {
  std::string compact;
  compact.reserve(text.size());
  for (unsigned char c : text) {
    if (IsWhitespaceByte(c) || c == '-') {
      continue;
    }
    compact.push_back(static_cast<char>(std::toupper(c)));
  }
  // Base32 itself contains O, P, E, N, so only strip "OPEN" when it leaves 52 chars.
  if (compact.size() == 56 && base::StartsWith(compact, kRecoveryPrefix)) {
    compact.erase(0, 4);
  }
  if (compact.size() != 52) {
    SecureZero(compact);
    return std::nullopt;
  }
  auto decoded = Base32Decode(compact);
  SecureZero(compact);
  if (!decoded || decoded->size() != kSyncKeyBytes) {
    if (decoded) {
      SecureZero(*decoded);
    }
    return std::nullopt;
  }
  return decoded;
}

// static
std::optional<SyncDerivedRecoveryKeys> SyncCrypto::DeriveRecoveryKeys(
    const std::vector<uint8_t>& recovery_key_bytes) {
  if (recovery_key_bytes.size() != kSyncKeyBytes) {
    return std::nullopt;
  }
  SyncDerivedRecoveryKeys result;
  result.recovery_auth_verifier.resize(kSyncKeyBytes);
  result.recovery_wrap_key.resize(kSyncKeyBytes);
  if (!HkdfSha256(recovery_key_bytes.data(), recovery_key_bytes.size(),
                  kRecoveryAuthInfo, result.recovery_auth_verifier.data()) ||
      !HkdfSha256(recovery_key_bytes.data(), recovery_key_bytes.size(),
                  kRecoveryWrapInfo, result.recovery_wrap_key.data())) {
    return std::nullopt;
  }
  return result;
}

// static
std::string SyncCrypto::VaultAad(SyncVaultWrapKind kind,
                                 std::string_view normalized_email) {
  const char* tag =
      (kind == SyncVaultWrapKind::kPassword) ? "vault-pw" : "vault-rec";
  return std::string("open-sync-v1|") + tag + "|" +
         std::string(normalized_email);
}

// static
std::string SyncCrypto::RecordAad(std::string_view account_id,
                                  std::string_view collection,
                                  std::string_view record_id,
                                  bool deleted) {
  return std::string("open-sync-v1|rec|") + std::string(account_id) + "|" +
         std::string(collection) + "|" + std::string(record_id) + "|" +
         (deleted ? "1" : "0");
}

// static
std::string SyncCrypto::BlobAad(std::string_view account_id,
                                std::string_view blob_id) {
  return std::string("open-sync-v1|blob|") + std::string(account_id) + "|" +
         std::string(blob_id);
}

// static
std::optional<std::vector<uint8_t>> SyncCrypto::Aes256GcmSeal(
    const uint8_t* plaintext,
    size_t plaintext_len,
    const uint8_t key[kSyncKeyBytes],
    std::string_view aad) {
  if (plaintext_len > static_cast<size_t>(std::numeric_limits<int>::max()) -
                          kSyncNonceBytes - kSyncGcmTagBytes ||
      aad.size() > static_cast<size_t>(std::numeric_limits<int>::max())) {
    return std::nullopt;
  }

  auto nonce = RandomBytes(kSyncNonceBytes);
  if (!nonce) {
    return std::nullopt;
  }

  ScopedEvpCipherCtx ctx(EVP_CIPHER_CTX_new());
  if (!ctx) {
    return std::nullopt;
  }

  if (EVP_EncryptInit_ex(ctx.get(), EVP_aes_256_gcm(), nullptr, nullptr,
                         nullptr) != 1 ||
      EVP_CIPHER_CTX_ctrl(ctx.get(), EVP_CTRL_GCM_SET_IVLEN,
                          static_cast<int>(kSyncNonceBytes), nullptr) != 1 ||
      EVP_EncryptInit_ex(ctx.get(), nullptr, nullptr, key, nonce->data()) !=
          1) {
    return std::nullopt;
  }

  int out_len = 0;
  if (!aad.empty()) {
    if (EVP_EncryptUpdate(ctx.get(), nullptr, &out_len,
                          reinterpret_cast<const uint8_t*>(aad.data()),
                          static_cast<int>(aad.size())) != 1) {
      return std::nullopt;
    }
  }

  std::vector<uint8_t> combined(kSyncNonceBytes + plaintext_len +
                                kSyncGcmTagBytes);
  std::memcpy(combined.data(), nonce->data(), kSyncNonceBytes);

  int written = 0;
  if (plaintext_len > 0) {
    if (EVP_EncryptUpdate(ctx.get(), combined.data() + kSyncNonceBytes,
                          &written, plaintext,
                          static_cast<int>(plaintext_len)) != 1) {
      return std::nullopt;
    }
  }
  int final_len = 0;
  if (EVP_EncryptFinal_ex(ctx.get(),
                          combined.data() + kSyncNonceBytes + written,
                          &final_len) != 1) {
    return std::nullopt;
  }
  const size_t ct_len = static_cast<size_t>(written + final_len);
  if (EVP_CIPHER_CTX_ctrl(ctx.get(), EVP_CTRL_GCM_GET_TAG,
                          static_cast<int>(kSyncGcmTagBytes),
                          combined.data() + kSyncNonceBytes + ct_len) != 1) {
    return std::nullopt;
  }
  combined.resize(kSyncNonceBytes + ct_len + kSyncGcmTagBytes);
  return combined;
}

// static
std::optional<std::vector<uint8_t>> SyncCrypto::Aes256GcmOpen(
    const uint8_t* combined,
    size_t combined_len,
    const uint8_t key[kSyncKeyBytes],
    std::string_view aad) {
  if (combined_len < kSyncNonceBytes + kSyncGcmTagBytes ||
      combined_len > static_cast<size_t>(std::numeric_limits<int>::max()) ||
      aad.size() > static_cast<size_t>(std::numeric_limits<int>::max())) {
    return std::nullopt;
  }

  const uint8_t* nonce = combined;
  const uint8_t* ciphertext = combined + kSyncNonceBytes;
  const size_t ct_len = combined_len - kSyncNonceBytes - kSyncGcmTagBytes;
  const uint8_t* tag = ciphertext + ct_len;

  ScopedEvpCipherCtx ctx(EVP_CIPHER_CTX_new());
  if (!ctx) {
    return std::nullopt;
  }

  if (EVP_DecryptInit_ex(ctx.get(), EVP_aes_256_gcm(), nullptr, nullptr,
                         nullptr) != 1 ||
      EVP_CIPHER_CTX_ctrl(ctx.get(), EVP_CTRL_GCM_SET_IVLEN,
                          static_cast<int>(kSyncNonceBytes), nullptr) != 1 ||
      EVP_DecryptInit_ex(ctx.get(), nullptr, nullptr, key, nonce) != 1) {
    return std::nullopt;
  }

  int out_len = 0;
  if (!aad.empty()) {
    if (EVP_DecryptUpdate(ctx.get(), nullptr, &out_len,
                          reinterpret_cast<const uint8_t*>(aad.data()),
                          static_cast<int>(aad.size())) != 1) {
      return std::nullopt;
    }
  }

  std::vector<uint8_t> plaintext(ct_len);
  int written = 0;
  if (ct_len > 0) {
    if (EVP_DecryptUpdate(ctx.get(), plaintext.data(), &written, ciphertext,
                          static_cast<int>(ct_len)) != 1) {
      SecureZero(plaintext);
      return std::nullopt;
    }
  }

  if (EVP_CIPHER_CTX_ctrl(ctx.get(), EVP_CTRL_GCM_SET_TAG,
                          static_cast<int>(kSyncGcmTagBytes),
                          const_cast<uint8_t*>(tag)) != 1) {
    SecureZero(plaintext);
    return std::nullopt;
  }

  int final_len = 0;
  if (EVP_DecryptFinal_ex(ctx.get(), plaintext.data() + written, &final_len) !=
      1) {
    SecureZero(plaintext);
    return std::nullopt;
  }

  plaintext.resize(static_cast<size_t>(written + final_len));
  return plaintext;
}

// static
std::optional<std::vector<uint8_t>> SyncCrypto::WrapVaultKey(
    const std::vector<uint8_t>& vault_key,
    const std::vector<uint8_t>& wrap_key,
    SyncVaultWrapKind kind,
    std::string_view email) {
  if (vault_key.size() != kSyncKeyBytes || wrap_key.size() != kSyncKeyBytes) {
    return std::nullopt;
  }
  std::string aad = VaultAad(kind, NormalizeEmail(email));
  auto combined = Aes256GcmSeal(vault_key.data(), vault_key.size(),
                                wrap_key.data(), aad);
  if (!combined || combined->size() != kSyncWrappedVaultKeyBytes) {
    return std::nullopt;
  }
  return combined;
}

// static
std::optional<std::vector<uint8_t>> SyncCrypto::UnwrapVaultKey(
    const std::vector<uint8_t>& wrapped,
    const std::vector<uint8_t>& wrap_key,
    SyncVaultWrapKind kind,
    std::string_view email) {
  if (wrapped.size() != kSyncWrappedVaultKeyBytes ||
      wrap_key.size() != kSyncKeyBytes) {
    return std::nullopt;
  }
  std::string aad = VaultAad(kind, NormalizeEmail(email));
  auto unwrapped =
      Aes256GcmOpen(wrapped.data(), wrapped.size(), wrap_key.data(), aad);
  if (!unwrapped || unwrapped->size() != kSyncKeyBytes) {
    if (unwrapped) {
      SecureZero(*unwrapped);
    }
    return std::nullopt;
  }
  return unwrapped;
}

// static
std::optional<std::vector<uint8_t>> SyncCrypto::SealRecord(
    const std::vector<uint8_t>& plaintext,
    const SyncVaultKeys& keys,
    std::string_view account_id,
    std::string_view collection,
    std::string_view record_id,
    bool deleted) {
  std::string aad = RecordAad(account_id, collection, record_id, deleted);
  return Aes256GcmSeal(plaintext.data(), plaintext.size(),
                       keys.record_enc_key.data(), aad);
}

// static
std::optional<std::vector<uint8_t>> SyncCrypto::OpenRecord(
    const std::vector<uint8_t>& combined,
    const SyncVaultKeys& keys,
    std::string_view account_id,
    std::string_view collection,
    std::string_view record_id,
    bool deleted) {
  std::string aad = RecordAad(account_id, collection, record_id, deleted);
  return Aes256GcmOpen(combined.data(), combined.size(),
                       keys.record_enc_key.data(), aad);
}

// static
std::optional<std::vector<uint8_t>> SyncCrypto::SealBlob(
    const std::vector<uint8_t>& plaintext,
    const SyncVaultKeys& keys,
    std::string_view account_id,
    std::string_view blob_id) {
  std::string aad = BlobAad(account_id, blob_id);
  return Aes256GcmSeal(plaintext.data(), plaintext.size(),
                       keys.blob_enc_key.data(), aad);
}

// static
std::optional<std::vector<uint8_t>> SyncCrypto::OpenBlob(
    const std::vector<uint8_t>& combined,
    const SyncVaultKeys& keys,
    std::string_view account_id,
    std::string_view blob_id) {
  std::string aad = BlobAad(account_id, blob_id);
  return Aes256GcmOpen(combined.data(), combined.size(),
                       keys.blob_enc_key.data(), aad);
}

// static
std::string SyncCrypto::ComputePayloadHash(const uint8_t* plaintext,
                                           size_t plaintext_len,
                                           const SyncVaultKeys& keys) {
  return HmacSha256Hex(keys.payload_hash_key.data(), plaintext, plaintext_len);
}

// static
std::string SyncCrypto::ComputePayloadHash(std::string_view plaintext,
                                           const SyncVaultKeys& keys) {
  return ComputePayloadHash(reinterpret_cast<const uint8_t*>(plaintext.data()),
                            plaintext.size(), keys);
}

// static
std::string SyncCrypto::ComputeBlobId(const uint8_t* plaintext,
                                      size_t plaintext_len,
                                      const SyncVaultKeys& keys) {
  return HmacSha256Hex(keys.blob_id_key.data(), plaintext, plaintext_len);
}

// static
std::string SyncCrypto::Sha256Hex(const uint8_t* data, size_t size) {
  uint8_t digest[SHA256_DIGEST_LENGTH]{};
  SHA256(data, size, digest);
  return HexLower(digest, SHA256_DIGEST_LENGTH);
}

// static
std::string SyncCrypto::HexLower(const uint8_t* data, size_t size) {
  static constexpr char kHex[] = "0123456789abcdef";
  std::string out;
  out.resize(size * 2);
  for (size_t i = 0; i < size; ++i) {
    out[2 * i] = kHex[(data[i] >> 4) & 0x0Fu];
    out[2 * i + 1] = kHex[data[i] & 0x0Fu];
  }
  return out;
}

// static
bool SyncCrypto::IsValidBlobId(std::string_view value) {
  if (value.size() != 64) {
    return false;
  }
  for (char c : value) {
    bool ok = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f');
    if (!ok) {
      return false;
    }
  }
  return true;
}

}  // namespace open_unified
