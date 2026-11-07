import Foundation
import Security
import LocalAuthentication
import CommonCrypto
import Darwin

/// Capability issued only at an explicit user-consent boundary. Never infer consent
/// from a saved preference or from possession of a key. The reason records that boundary.
public final class SecretsImportConsent: Sendable {
    public let reason: String
    private init(reason: String) { self.reason = reason }

    /// Call only after the user explicitly approves secret import (CLI flag or app sheet).
    public static func grantedByUser(reason: String) -> SecretsImportConsent {
        precondition(!reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        return SecretsImportConsent(reason: reason)
    }
}

/// Internal access proof. Synthetic access is bound to a fixture created by this
/// module, with no caller-supplied path, blob, key, or Keychain operation.
enum SecretsReadAccess {
    case user(SecretsImportConsent)
    case synthetic(SyntheticSecretsFixture)

    func permits(_ directory: URL) -> Bool {
        switch self {
        case .user: return true
        case .synthetic(let fixture):
            return directory.standardizedFileURL.path == fixture.directory.standardizedFileURL.path ||
                ["Default", "Profile 1"].contains(directory.lastPathComponent) &&
                directory.deletingLastPathComponent().standardizedFileURL.path == fixture.directory.standardizedFileURL.path
        }
    }
}

public enum ChromiumCryptoError: Error {
    case keychainItemNotFound
    case keychainAccessDenied(OSStatus)
    case keychainFailed(OSStatus)
    case badPrefix
    case decryptFailed
}

/// Call only after explicit consent. This never creates or updates an item.
public func fetchKeychainPassword(service: String, account: String, consent: SecretsImportConsent) throws -> [UInt8] {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    switch status {
    case errSecSuccess:
        guard var data = result as? Data else { throw ChromiumCryptoError.keychainFailed(errSecDecode) }
        result = nil
        defer { data.resetBytes(in: 0..<data.count) }
        return Array(data)
    case errSecItemNotFound: throw ChromiumCryptoError.keychainItemNotFound
    case errSecAuthFailed, errSecUserCanceled, errSecInteractionNotAllowed:
        throw ChromiumCryptoError.keychainAccessDenied(status)
    default: throw ChromiumCryptoError.keychainFailed(status)
    }
}

/// Consent still gates this metadata probe. It must not cause a second prompt.
public func keychainItemExists(service: String, account: String, consent: SecretsImportConsent) -> Bool {
    // interactionNotAllowed on the authentication context replaces the deprecated
    // kSecUseAuthenticationUIFail: the query fails instead of showing any UI.
    let context = LAContext()
    context.interactionNotAllowed = true
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
        kSecReturnAttributes as String: true,
        kSecReturnData as String: false,
        kSecMatchLimit as String: kSecMatchLimitOne,
        kSecUseAuthenticationContext as String: context,
    ]
    return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
}

public func probeChromiumKeychainPair(consent: SecretsImportConsent) throws -> (service: String, account: String) {
    for pair in [("Arc Safe Storage", "Arc"), ("Chrome Safe Storage", "Chrome"), ("Chromium Safe Storage", "Chromium")] {
        if keychainItemExists(service: pair.0, account: pair.1, consent: consent) { return pair }
    }
    throw ChromiumCryptoError.keychainItemNotFound
}

/// Clears the local by-value password buffer. The caller must also clear its own buffer.
public func deriveChromiumKey(passwordBytes: [UInt8]) -> [UInt8] {
    var passwordBuffer = passwordBytes
    defer { zeroSecretBytes(&passwordBuffer) }
    let salt = Array("saltysalt".utf8)
    var key = [UInt8](repeating: 0, count: 16)
    let status = passwordBuffer.withUnsafeMutableBytes { password in
        salt.withUnsafeBytes { saltBuffer in
            key.withUnsafeMutableBytes { output in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), password.baseAddress?.assumingMemoryBound(to: CChar.self), password.count,
                                    saltBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self), saltBuffer.count,
                                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
                                    output.baseAddress?.assumingMemoryBound(to: UInt8.self), output.count)
            }
        }
    }
    if status != kCCSuccess { zeroSecretBytes(&key) }
    return key
}

/// Prevents the compiler from removing the overwrite as a dead store.
public func zeroSecretBytes(_ bytes: inout [UInt8]) {
    bytes.withUnsafeMutableBytes { buffer in
        if let base = buffer.baseAddress { _ = memset_s(base, buffer.count, 0, buffer.count) }
    }
    bytes.removeAll(keepingCapacity: false)
}

public func decryptChromiumBlob(_ blob: [UInt8], key: [UInt8], consent: SecretsImportConsent) throws -> [UInt8] {
    try decryptChromiumBlob(blob, key: key, access: .user(consent))
}

func decryptChromiumBlob(_ blob: [UInt8], key: [UInt8], access: SecretsReadAccess) throws -> [UInt8] {
    guard !blob.isEmpty else { throw ChromiumCryptoError.decryptFailed }
    let versioned = blob.count >= 3 && blob[0] == 0x76 &&
        (0x30...0x39).contains(blob[1]) && (0x30...0x39).contains(blob[2])
    if versioned && !blob.starts(with: [0x76, 0x31, 0x30]) { throw ChromiumCryptoError.badPrefix }
    guard versioned else { return blob }
    guard key.count == 16, blob.count >= 19, (blob.count - 3) % 16 == 0 else { throw ChromiumCryptoError.decryptFailed }
    let iv = [UInt8](repeating: 0x20, count: 16)
    func decrypt(_ candidate: [UInt8]) -> (status: CCCryptorStatus, bytes: [UInt8]) {
        var output = [UInt8](repeating: 0, count: blob.count + kCCBlockSizeAES128)
        var written = 0
        let capacity = output.count
        let status = candidate.withUnsafeBytes { keyBuffer in
            iv.withUnsafeBytes { ivBuffer in
                blob.withUnsafeBytes { input in
                    output.withUnsafeMutableBytes { destination in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                keyBuffer.baseAddress, candidate.count, ivBuffer.baseAddress,
                                input.baseAddress!.advanced(by: 3), input.count - 3,
                                destination.baseAddress, capacity, &written)
                    }
                }
            }
        }
        guard status == kCCSuccess else { zeroSecretBytes(&output); return (status, []) }
        // Validate the final CBC block explicitly before trusting PKCS7 removal.
        // This also makes the padding-failure fallback independent of platform behavior.
        var tail = [UInt8](repeating: 0, count: 16)
        defer { zeroSecretBytes(&tail) }
        var tailWritten = 0
        let tailStatus = candidate.withUnsafeBytes { keyBuffer in
            iv.withUnsafeBytes { ivBuffer in
                blob.withUnsafeBytes { input in
                    tail.withUnsafeMutableBytes { destination in
                        let previous = input.count > 19 ? input.baseAddress!.advanced(by: input.count - 32) : ivBuffer.baseAddress!
                        return CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), 0,
                                       keyBuffer.baseAddress, candidate.count, previous,
                                       input.baseAddress!.advanced(by: input.count - 16), 16,
                                       destination.baseAddress, 16, &tailWritten)
                    }
                }
            }
        }
        let padding = Int(tail.last ?? 0)
        guard tailStatus == kCCSuccess, tailWritten == 16, (1...16).contains(padding),
              tail.suffix(padding).allSatisfy({ Int($0) == padding }), written == blob.count - 3 - padding else {
            zeroSecretBytes(&output)
            return (CCCryptorStatus(kCCDecodeError), [])
        }
        output.removeSubrange(written..<output.count)
        return (status, output)
    }
    let result = decrypt(key)
    if result.status == kCCSuccess { return result.bytes }
    guard result.status == kCCDecodeError else { throw ChromiumCryptoError.decryptFailed }
    var fallback: [UInt8] = [0xd0, 0xd0, 0xec, 0x9c, 0x7d, 0x77, 0xd4, 0x3a, 0xc5, 0x41, 0x87, 0xfa, 0x48, 0x18, 0xd1, 0x7f]
    defer { zeroSecretBytes(&fallback) }
    let retry = decrypt(fallback)
    guard retry.status == kCCSuccess else { throw ChromiumCryptoError.decryptFailed }
    return retry.bytes
}
