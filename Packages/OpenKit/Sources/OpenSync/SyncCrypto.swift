import Foundation
import CryptoKit
import CommonCrypto
import Security
import Darwin

/// Password KDF parameters (docs/sync-protocol.md §1.2). Wire field names are exact.
public struct SyncKDFParams: Codable, Equatable, Sendable {
    public static let pbkdf2SHA256 = "pbkdf2-sha256"
    public static let defaultIterations = 600_000
    public static let iterationRange = 300_000...2_000_000

    public var algorithm: String
    public var iterations: Int
    public var saltBase64: String

    public init(algorithm: String = SyncKDFParams.pbkdf2SHA256, iterations: Int = SyncKDFParams.defaultIterations, saltBase64: String) {
        self.algorithm = algorithm; self.iterations = iterations; self.saltBase64 = saltBase64
    }

    /// Fresh parameters with a new random 32-byte salt.
    public static func generate(iterations: Int = SyncKDFParams.defaultIterations) throws -> SyncKDFParams {
        SyncKDFParams(iterations: iterations, saltBase64: try SyncCrypto.randomBytes(32).base64EncodedString())
    }

    /// The decoded salt, after checking the algorithm, iteration range and salt length.
    public func validatedSalt() throws -> Data {
        guard algorithm == Self.pbkdf2SHA256 else { throw SyncError.crypto("Unsupported key derivation algorithm \(algorithm).") }
        guard Self.iterationRange.contains(iterations) else { throw SyncError.crypto("Key derivation iterations out of range.") }
        guard let salt = Data(base64Encoded: saltBase64), salt.count == 32 else { throw SyncError.crypto("Key derivation salt must be 32 bytes.") }
        return salt
    }
}

/// Client-side cryptography for Open Sync v1 (docs/sync-protocol.md §1).
public enum SyncCrypto {
    // MARK: Constants (§1.2–§1.6)

    static let saltDomainTag = "open-sync-v1:"
    static let authInfo = "open-sync-auth-v1"
    static let wrapInfo = "open-sync-wrap-v1"
    static let recoveryAuthInfo = "open-sync-recovery-auth-v1"
    static let recoveryWrapInfo = "open-sync-recovery-wrap-v1"
    static let recordEncInfo = "open-sync-record-enc-v1"
    static let blobEncInfo = "open-sync-blob-enc-v1"
    static let payloadHashInfo = "open-sync-payload-hash-v1"
    static let blobIdInfo = "open-sync-blob-id-v1"

    public static let keyByteCount = 32
    public static let wrappedVaultKeyByteCount = 60
    public static let recoveryKeyPrefix = "OPEN"
    static let base32Alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".utf8)

    /// Minimal deleted-record payload sealed with `deleted = 1` in the AAD (§1.6).
    public static let tombstonePayload = Data(#"{"t":1}"#.utf8)

    // MARK: Zeroing

    /// Overwrites the buffer with zeros in a way the optimizer may not remove.
    public static func zeroBytes(_ bytes: inout [UInt8]) {
        guard !bytes.isEmpty else { return }
        bytes.withUnsafeMutableBytes { raw in
            if let base = raw.baseAddress { _ = memset_s(base, raw.count, 0, raw.count) }
        }
    }

    public static func zeroData(_ data: inout Data) {
        guard !data.isEmpty else { return }
        data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            if let base = raw.baseAddress { _ = memset_s(base, raw.count, 0, raw.count) }
        }
    }

    // MARK: Random

    public static func randomBytes(_ count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        defer { zeroBytes(&bytes) }
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        guard status == errSecSuccess else { throw SyncError.crypto("The system random number generator failed (\(status)).") }
        return Data(bytes)
    }

    // MARK: Email

    /// `email.trim().toLowerCase()` (§1.1).
    public static func normalizeEmail(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// 3...254 UTF-8 bytes with a non-empty local part and domain around one `@`.
    public static func isValidNormalizedEmail(_ email: String) -> Bool {
        let length = email.utf8.count
        guard (SyncLimits.emailLength).contains(length), let at = email.lastIndex(of: "@") else { return false }
        let local = email[..<at], domain = email[email.index(after: at)...]
        return !local.isEmpty && !domain.isEmpty && !email.contains(where: \.isWhitespace)
    }

    // MARK: Password keys (§1.2)

    /// PBKDF2-HMAC-SHA256 over the password, then HKDF-SHA256 into `authKey` and `passwordWrapKey`.
    /// Slow by design (600k iterations): call off the main actor.
    public static func derivePasswordKeys(email: String, password: String, kdfParams: SyncKDFParams) throws -> (authVerifier: Data, passwordWrapKey: SymmetricKey) {
        let normalized = normalizeEmail(email)
        let kdfSalt = try kdfParams.validatedSalt()
        var passwordBytes = Array(password.utf8)
        defer { zeroBytes(&passwordBytes) }
        guard !passwordBytes.isEmpty else { throw SyncError.weakPassword("The password is empty.") }
        var salt = [UInt8](kdfSalt) + Array(saltDomainTag.utf8) + Array(normalized.utf8)
        defer { zeroBytes(&salt) }
        var masterKey = [UInt8](repeating: 0, count: keyByteCount)
        defer { zeroBytes(&masterKey) }
        let rounds = UInt32(kdfParams.iterations)
        let status: Int32 = passwordBytes.withUnsafeBufferPointer { passwordBuffer in
            salt.withUnsafeBufferPointer { saltBuffer in
                masterKey.withUnsafeMutableBufferPointer { output in
                    passwordBuffer.withMemoryRebound(to: CChar.self) { passwordChars in
                        CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                             passwordChars.baseAddress, passwordChars.count,
                                             saltBuffer.baseAddress, saltBuffer.count,
                                             CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds,
                                             output.baseAddress, output.count)
                    }
                }
            }
        }
        guard status == Int32(kCCSuccess) else { throw SyncError.crypto("Password key derivation failed (\(status)).") }
        let master = SymmetricKey(data: masterKey)
        let authKey = hkdf(master, info: authInfo)
        let wrapKey = hkdf(master, info: wrapInfo)
        return (authVerifier: keyData(authKey), passwordWrapKey: wrapKey)
    }

    // MARK: Recovery key (§1.3)

    /// 32 random bytes and their `OPEN-XXXX-…` form (13 groups of 4 Base32 characters).
    public static func generateRecoveryKey() throws -> (rawBytes: Data, formatted: String) {
        let raw = try randomBytes(keyByteCount)
        return (raw, formatRecoveryKey(raw))
    }

    public static func formatRecoveryKey(_ raw: Data) -> String {
        let encoded = base32Encode(raw)
        var groups: [String] = []
        var index = encoded.startIndex
        while index < encoded.endIndex {
            let end = encoded.index(index, offsetBy: 4, limitedBy: encoded.endIndex) ?? encoded.endIndex
            groups.append(String(encoded[index..<end]))
            index = end
        }
        return ([recoveryKeyPrefix] + groups).joined(separator: "-")
    }

    /// Strips whitespace and hyphens, uppercases, strips the optional `OPEN` prefix, and decodes
    /// exactly 52 Base32 characters to 32 bytes. Non-zero trailing padding bits are rejected.
    public static func parseRecoveryKey(_ text: String) throws -> Data {
        var compact = String(text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) && $0 != "-" }).uppercased()
        // Base32 itself contains O, P, E and N, so strip the prefix only when it leaves 52 characters.
        if compact.count == 56, compact.hasPrefix(recoveryKeyPrefix) { compact.removeFirst(4) }
        guard compact.count == 52 else { throw SyncError.invalidRecoveryKey }
        guard let decoded = base32Decode(compact), decoded.count == keyByteCount else { throw SyncError.invalidRecoveryKey }
        return decoded
    }

    public static func deriveRecoveryKeys(recoveryKeyBytes: Data) -> (recoveryAuthVerifier: Data, recoveryWrapKey: SymmetricKey) {
        let input = SymmetricKey(data: recoveryKeyBytes)
        return (keyData(hkdf(input, info: recoveryAuthInfo)), hkdf(input, info: recoveryWrapInfo))
    }

    static func base32Encode(_ data: Data) -> String {
        var output: [UInt8] = []
        output.reserveCapacity((data.count * 8 + 4) / 5)
        var buffer: UInt32 = 0, bits = 0
        for byte in data {
            buffer = (buffer << 8) | UInt32(byte); bits += 8
            while bits >= 5 {
                output.append(base32Alphabet[Int((buffer >> UInt32(bits - 5)) & 31)]); bits -= 5
            }
            buffer &= (1 << UInt32(bits)) - 1
        }
        if bits > 0 { output.append(base32Alphabet[Int((buffer << UInt32(5 - bits)) & 31)]) }
        return String(decoding: output, as: UTF8.self)
    }

    static func base32Decode(_ text: String) -> Data? {
        var lookup = [Int8](repeating: -1, count: 256)
        for (index, char) in base32Alphabet.enumerated() { lookup[Int(char)] = Int8(index) }
        var output = Data()
        output.reserveCapacity(text.utf8.count * 5 / 8)
        var buffer: UInt32 = 0, bits = 0
        for char in text.utf8 {
            let value = lookup[Int(char)]
            guard value >= 0 else { return nil }
            buffer = (buffer << 5) | UInt32(value); bits += 5
            if bits >= 8 {
                output.append(UInt8((buffer >> UInt32(bits - 8)) & 0xFF)); bits -= 8
                buffer &= (1 << UInt32(bits)) - 1
            }
        }
        // Leftover bits are padding and must be zero.
        guard bits < 5, buffer == 0 else { return nil }
        return output
    }

    // MARK: Vault subkeys (§1.4)

    /// HKDF-derived vault subkeys. Holds key material; never logged.
    public struct VaultKeys: @unchecked Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
        public let recordEncKey: SymmetricKey
        public let blobEncKey: SymmetricKey
        public let payloadHashKey: SymmetricKey
        public let blobIdKey: SymmetricKey

        public init(vaultKey: Data) throws {
            guard vaultKey.count == SyncCrypto.keyByteCount else { throw SyncError.crypto("The vault key must be 32 bytes.") }
            let input = SymmetricKey(data: vaultKey)
            recordEncKey = SyncCrypto.hkdf(input, info: SyncCrypto.recordEncInfo)
            blobEncKey = SyncCrypto.hkdf(input, info: SyncCrypto.blobEncInfo)
            payloadHashKey = SyncCrypto.hkdf(input, info: SyncCrypto.payloadHashInfo)
            blobIdKey = SyncCrypto.hkdf(input, info: SyncCrypto.blobIdInfo)
        }

        public var description: String { "SyncCrypto.VaultKeys(redacted)" }
        public var debugDescription: String { description }
        public var customMirror: Mirror { Mirror(self, children: [:]) }
    }

    // MARK: Vault key wrapping (§1.5, §1.6)

    public enum WrapKind: Sendable {
        case password, recovery
        var tag: String { self == .password ? "vault-pw" : "vault-rec" }
    }

    public static func vaultAAD(_ kind: WrapKind, normalizedEmail: String) -> Data {
        Data("open-sync-v1|\(kind.tag)|\(normalizedEmail)".utf8)
    }

    /// AES-256-GCM combined box (12 nonce + 32 key + 16 tag = 60 bytes).
    public static func wrapVaultKey(_ vaultKey: Data, wrapKey: SymmetricKey, kind: WrapKind, email: String) throws -> Data {
        guard vaultKey.count == keyByteCount else { throw SyncError.crypto("The vault key must be 32 bytes.") }
        let combined = try seal(vaultKey, key: wrapKey, aad: vaultAAD(kind, normalizedEmail: normalizeEmail(email)))
        guard combined.count == wrappedVaultKeyByteCount else { throw SyncError.crypto("Unexpected wrapped key length.") }
        return combined
    }

    public static func unwrapVaultKey(_ wrapped: Data, wrapKey: SymmetricKey, kind: WrapKind, email: String) throws -> Data {
        guard wrapped.count == wrappedVaultKeyByteCount else { throw SyncError.crypto("The wrapped vault key has the wrong length.") }
        let key: Data
        do { key = try open(wrapped, key: wrapKey, aad: vaultAAD(kind, normalizedEmail: normalizeEmail(email))) }
        catch { throw kind == .password ? SyncError.invalidCredentials : SyncError.invalidRecoveryKey }
        guard key.count == keyByteCount else { throw SyncError.crypto("The vault key has the wrong length.") }
        return key
    }

    // MARK: Records and blobs (§1.5, §1.6)

    public static func recordAAD(accountId: String, collection: String, recordId: String, deleted: Bool) -> Data {
        Data("open-sync-v1|rec|\(accountId)|\(collection)|\(recordId)|\(deleted ? "1" : "0")".utf8)
    }

    public static func blobAAD(accountId: String, blobId: String) -> Data {
        Data("open-sync-v1|blob|\(accountId)|\(blobId)".utf8)
    }

    public static func sealRecord(_ plaintext: Data, keys: VaultKeys, accountId: String, collection: String, recordId: String, deleted: Bool) throws -> Data {
        try seal(plaintext, key: keys.recordEncKey, aad: recordAAD(accountId: accountId, collection: collection, recordId: recordId, deleted: deleted))
    }

    public static func openRecord(_ combined: Data, keys: VaultKeys, accountId: String, collection: String, recordId: String, deleted: Bool) throws -> Data {
        try open(combined, key: keys.recordEncKey, aad: recordAAD(accountId: accountId, collection: collection, recordId: recordId, deleted: deleted))
    }

    public static func sealBlob(_ plaintext: Data, keys: VaultKeys, accountId: String, blobId: String) throws -> Data {
        try seal(plaintext, key: keys.blobEncKey, aad: blobAAD(accountId: accountId, blobId: blobId))
    }

    public static func openBlob(_ combined: Data, keys: VaultKeys, accountId: String, blobId: String) throws -> Data {
        try open(combined, key: keys.blobEncKey, aad: blobAAD(accountId: accountId, blobId: blobId))
    }

    /// HMAC-SHA256(payloadHashKey, plaintext) as 64 lowercase hex characters.
    public static func computePayloadHash(_ plaintext: Data, keys: VaultKeys) -> String {
        hex(Data(HMAC<SHA256>.authenticationCode(for: plaintext, using: keys.payloadHashKey)))
    }

    /// Content-addressed blob ID: HMAC-SHA256(blobIdKey, plaintext) as 64 lowercase hex characters.
    public static func computeBlobID(_ plaintext: Data, keys: VaultKeys) -> String {
        hex(Data(HMAC<SHA256>.authenticationCode(for: plaintext, using: keys.blobIdKey)))
    }

    public static func sha256Hex(_ data: Data) -> String { hex(Data(SHA256.hash(data: data))) }

    public static func isValidBlobID(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    // MARK: Primitives

    static func hkdf(_ input: SymmetricKey, info: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: input, salt: Data(), info: Data(info.utf8), outputByteCount: keyByteCount)
    }

    static func keyData(_ key: SymmetricKey) -> Data { key.withUnsafeBytes { Data($0) } }

    static func seal(_ plaintext: Data, key: SymmetricKey, aad: Data) throws -> Data {
        let box: AES.GCM.SealedBox
        do { box = try AES.GCM.seal(plaintext, using: key, nonce: AES.GCM.Nonce(), authenticating: aad) }
        catch { throw SyncError.crypto("Encryption failed.") }
        guard let combined = box.combined else { throw SyncError.crypto("Encryption produced no combined box.") }
        return combined
    }

    static func open(_ combined: Data, key: SymmetricKey, aad: Data) throws -> Data {
        guard combined.count >= 28 else { throw SyncError.crypto("The ciphertext is too short.") }
        do {
            let box = try AES.GCM.SealedBox(combined: combined)
            return try AES.GCM.open(box, using: key, authenticating: aad)
        } catch {
            throw SyncError.crypto("Decryption failed: the data was changed or the key is wrong.")
        }
    }

    private static let hexDigits = Array("0123456789abcdef".utf8)

    public static func hex(_ data: Data) -> String {
        var output = [UInt8](repeating: 0, count: data.count * 2)
        var index = 0
        for byte in data {
            output[index] = hexDigits[Int(byte >> 4)]; output[index + 1] = hexDigits[Int(byte & 0x0F)]
            index += 2
        }
        return String(decoding: output, as: UTF8.self)
    }
}
