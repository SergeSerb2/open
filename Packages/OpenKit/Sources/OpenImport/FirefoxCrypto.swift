import Foundation
import CommonCrypto
import CryptoKit

/// Minimal DER for the NSS structures in Firefox `key4.db` and `logins.json`.
/// Only the tags those structures use: SEQUENCE, OCTET STRING, INTEGER, OID.
/// Evidence: docs/re/browser-import.md §4.3; public NSS `lib/softoken/lowpbe.c`
/// and `sdr.c` describe the layouts. Our own implementation.
indirect enum DER: Equatable {
    case sequence([DER])
    case octets([UInt8])
    case integer([UInt8])
    case oid([UInt8])
    case other(UInt8, [UInt8])

    static let tagSequence: UInt8 = 0x30, tagOctets: UInt8 = 0x04, tagInteger: UInt8 = 0x02, tagOID: UInt8 = 0x06

    static func parse(_ bytes: [UInt8]) -> DER? {
        var index = 0
        guard let value = parse(bytes, &index, depth: 0), index == bytes.count else { return nil }
        return value
    }

    private static func parse(_ bytes: [UInt8], _ index: inout Int, depth: Int) -> DER? {
        guard depth < 16, index + 2 <= bytes.count else { return nil }
        let tag = bytes[index]; index += 1
        var length = Int(bytes[index]); index += 1
        if length & 0x80 != 0 {
            let count = length & 0x7F
            guard (1...3).contains(count), index + count <= bytes.count else { return nil }
            length = 0
            for _ in 0..<count { length = length << 8 | Int(bytes[index]); index += 1 }
        }
        guard length <= bytes.count - index else { return nil }
        let body = Array(bytes[index..<index + length])
        index += length
        switch tag {
        case tagSequence:
            var children: [DER] = [], inner = 0
            while inner < body.count {
                guard let child = parse(body, &inner, depth: depth + 1) else { return nil }
                children.append(child)
            }
            return .sequence(children)
        case tagOctets: return .octets(body)
        case tagInteger: return .integer(body)
        case tagOID: return .oid(body)
        default: return .other(tag, body)
        }
    }

    var encoded: [UInt8] {
        let (tag, body): (UInt8, [UInt8])
        switch self {
        case .sequence(let children): (tag, body) = (Self.tagSequence, children.flatMap(\.encoded))
        case .octets(let value): (tag, body) = (Self.tagOctets, value)
        case .integer(let value): (tag, body) = (Self.tagInteger, value)
        case .oid(let value): (tag, body) = (Self.tagOID, value)
        case .other(let t, let value): (tag, body) = (t, value)
        }
        var out = [tag]
        if body.count < 0x80 { out.append(UInt8(body.count)) }
        else if body.count <= 0xFF { out += [0x81, UInt8(body.count)] }
        else if body.count <= 0xFFFF { out += [0x82, UInt8(body.count >> 8), UInt8(body.count & 0xFF)] }
        else { out += [0x83, UInt8(body.count >> 16), UInt8(body.count >> 8 & 0xFF), UInt8(body.count & 0xFF)] }
        return out + body
    }

    var children: [DER]? { if case .sequence(let c) = self { c } else { nil } }
    var octetBytes: [UInt8]? { if case .octets(let v) = self { v } else { nil } }
    var oidBytes: [UInt8]? { if case .oid(let v) = self { v } else { nil } }
    var intValue: Int? {
        guard case .integer(let v) = self, !v.isEmpty, v.count <= 4 else { return nil }
        return v.reduce(0) { $0 << 8 | Int($1) }
    }

    static func int(_ value: Int) -> DER {
        var bytes: [UInt8] = []
        var rest = value
        repeat { bytes.insert(UInt8(rest & 0xFF), at: 0); rest >>= 8 } while rest > 0
        if bytes[0] & 0x80 != 0 { bytes.insert(0, at: 0) }
        return .integer(bytes)
    }
}

/// Object identifiers (DER body bytes) used by NSS.
enum NSSOID {
    static let pbes2: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x05, 0x0D]          // 1.2.840.113549.1.5.13
    static let pbkdf2: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x05, 0x0C]         // 1.2.840.113549.1.5.12
    static let hmacSHA256: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x02, 0x09]           // 1.2.840.113549.2.9
    static let aes256CBC: [UInt8] = [0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x01, 0x2A]      // 2.16.840.1.101.3.4.1.42
    static let desEDE3CBC: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x03, 0x07]           // 1.2.840.113549.3.7
    static let pbeSHA1TripleDES: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x0C, 0x05, 0x01, 0x03] // 1.2.840.113549.1.12.5.1.3
}

enum FirefoxCryptoError: Error { case malformed, unsupported, decryptFailed, primaryPasswordRequired }

/// NSS key store and SDR decryption. Secrets live in `[UInt8]` buffers that callers zero.
enum FirefoxCrypto {
    /// The NSS CKA_ID that marks the SDR key in `nssPrivate.a102`.
    static let sdrKeyID: [UInt8] = [0xF8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]
    static let passwordCheck = Array("password-check".utf8)

    static func sha1(_ bytes: [UInt8]) -> [UInt8] { Array(Insecure.SHA1.hash(data: bytes)) }

    static func hmacSHA1(key: [UInt8], _ data: [UInt8]) -> [UInt8] {
        Array(HMAC<Insecure.SHA1>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }

    static func pbkdf2SHA256(password: [UInt8], salt: [UInt8], iterations: Int, length: Int) throws -> [UInt8] {
        guard iterations > 0, iterations <= 10_000_000, (16...64).contains(length) else { throw FirefoxCryptoError.unsupported }
        var out = [UInt8](repeating: 0, count: length)
        let status = password.withUnsafeBufferPointer { pw in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pw.baseAddress.map { UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self) },
                                 pw.count, salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                                 UInt32(iterations), &out, length)
        }
        guard status == kCCSuccess else { throw FirefoxCryptoError.decryptFailed }
        return out
    }

    static func cbc(_ operation: CCOperation, algorithm: CCAlgorithm, key: [UInt8], iv: [UInt8], _ input: [UInt8]) throws -> [UInt8] {
        let block = algorithm == CCAlgorithm(kCCAlgorithmAES) ? kCCBlockSizeAES128 : kCCBlockSize3DES
        guard iv.count == block, operation == CCOperation(kCCEncrypt) || (input.count % block == 0 && !input.isEmpty) else {
            throw FirefoxCryptoError.malformed
        }
        var out = [UInt8](repeating: 0, count: input.count + block)
        var moved = 0
        let status = CCCrypt(operation, algorithm, CCOptions(kCCOptionPKCS7Padding), key, key.count, iv, input, input.count, &out, out.count, &moved)
        guard status == kCCSuccess else { zeroSecretBytes(&out); throw FirefoxCryptoError.decryptFailed }
        let result = Array(out[0..<moved])
        zeroSecretBytes(&out)
        return result
    }

    /// Decrypts an NSS PBE blob (PBES2 with AES-256-CBC, or the legacy SHA1 + 3DES scheme).
    static func decryptPBE(_ der: DER, globalSalt: [UInt8], primaryPassword: [UInt8]) throws -> [UInt8] {
        guard let top = der.children, top.count == 2, let algorithm = top[0].children, algorithm.count == 2,
              let oid = algorithm[0].oidBytes, let ciphertext = top[1].octetBytes else { throw FirefoxCryptoError.malformed }
        var hashed = sha1(globalSalt + primaryPassword)
        defer { zeroSecretBytes(&hashed) }
        if oid == NSSOID.pbes2 {
            guard let params = algorithm[1].children, params.count == 2,
                  let kdf = params[0].children, kdf.count == 2, kdf[0].oidBytes == NSSOID.pbkdf2,
                  let kdfParams = kdf[1].children, kdfParams.count >= 2,
                  let salt = kdfParams[0].octetBytes, let iterations = kdfParams[1].intValue,
                  let cipher = params[1].children, cipher.count == 2, cipher[0].oidBytes == NSSOID.aes256CBC,
                  let ivTail = cipher[1].octetBytes else { throw FirefoxCryptoError.malformed }
            let length = kdfParams.count >= 3 ? (kdfParams[2].intValue ?? 32) : 32
            if kdfParams.count >= 4, let prf = kdfParams[3].children, prf.first?.oidBytes != NSSOID.hmacSHA256 { throw FirefoxCryptoError.unsupported }
            var key = try pbkdf2SHA256(password: hashed, salt: salt, iterations: iterations, length: length)
            defer { zeroSecretBytes(&key) }
            // NSS stores 14 IV bytes; the full IV is the DER header 04 0E plus those bytes.
            let iv = ivTail.count == 14 ? [0x04, 0x0E] + ivTail : ivTail
            return try cbc(CCOperation(kCCDecrypt), algorithm: CCAlgorithm(kCCAlgorithmAES), key: key, iv: iv, ciphertext)
        }
        if oid == NSSOID.pbeSHA1TripleDES {
            guard let params = algorithm[1].children, params.count == 2, let entrySalt = params[0].octetBytes else { throw FirefoxCryptoError.malformed }
            var keyIV = legacyKey(hashedPassword: hashed, entrySalt: entrySalt)
            defer { zeroSecretBytes(&keyIV) }
            return try cbc(CCOperation(kCCDecrypt), algorithm: CCAlgorithm(kCCAlgorithm3DES),
                           key: Array(keyIV[0..<24]), iv: Array(keyIV[32..<40]), ciphertext)
        }
        throw FirefoxCryptoError.unsupported
    }

    /// NSS legacy PBE: 40 bytes; the 3DES key is bytes 0..<24 and the IV the last 8.
    static func legacyKey(hashedPassword: [UInt8], entrySalt: [UInt8]) -> [UInt8] {
        let padded = entrySalt + [UInt8](repeating: 0, count: max(0, 20 - entrySalt.count))
        let chp = sha1(hashedPassword + entrySalt)
        let k1 = hmacSHA1(key: chp, padded + entrySalt)
        let tk = hmacSHA1(key: chp, padded)
        let k2 = hmacSHA1(key: chp, tk + entrySalt)
        return k1 + k2
    }

    /// One `logins.json` field: base64 DER { keyID, { cipher OID, IV }, ciphertext }.
    static func decryptSDR(base64: String, key: [UInt8]) throws -> [UInt8] {
        guard let data = Data(base64Encoded: base64), data.count <= 64 * 1024, let der = DER.parse(Array(data)),
              let parts = der.children, parts.count == 3, parts[0].octetBytes == sdrKeyID,
              let cipher = parts[1].children, cipher.count == 2, let oid = cipher[0].oidBytes,
              let iv = cipher[1].octetBytes, let ciphertext = parts[2].octetBytes else { throw FirefoxCryptoError.malformed }
        if oid == NSSOID.desEDE3CBC {
            guard key.count >= 24 else { throw FirefoxCryptoError.malformed }
            return try cbc(CCOperation(kCCDecrypt), algorithm: CCAlgorithm(kCCAlgorithm3DES), key: Array(key[0..<24]), iv: iv, ciphertext)
        }
        if oid == NSSOID.aes256CBC {
            guard key.count == 32 else { throw FirefoxCryptoError.malformed }
            return try cbc(CCOperation(kCCDecrypt), algorithm: CCAlgorithm(kCCAlgorithmAES), key: key, iv: iv, ciphertext)
        }
        throw FirefoxCryptoError.unsupported
    }

    // MARK: Encryption (synthetic fixtures only)

    static func encryptPBES2(_ plaintext: [UInt8], globalSalt: [UInt8], primaryPassword: [UInt8], salt: [UInt8], ivTail: [UInt8], iterations: Int) throws -> DER {
        var hashed = sha1(globalSalt + primaryPassword)
        defer { zeroSecretBytes(&hashed) }
        var key = try pbkdf2SHA256(password: hashed, salt: salt, iterations: iterations, length: 32)
        defer { zeroSecretBytes(&key) }
        let ciphertext = try cbc(CCOperation(kCCEncrypt), algorithm: CCAlgorithm(kCCAlgorithmAES), key: key, iv: [0x04, 0x0E] + ivTail, plaintext)
        return .sequence([
            .sequence([.oid(NSSOID.pbes2), .sequence([
                .sequence([.oid(NSSOID.pbkdf2), .sequence([.octets(salt), .int(iterations), .int(32), .sequence([.oid(NSSOID.hmacSHA256)])])]),
                .sequence([.oid(NSSOID.aes256CBC), .octets(ivTail)]),
            ])]),
            .octets(ciphertext),
        ])
    }

    static func encryptLegacyPBE(_ plaintext: [UInt8], globalSalt: [UInt8], primaryPassword: [UInt8], entrySalt: [UInt8]) throws -> DER {
        var hashed = sha1(globalSalt + primaryPassword)
        defer { zeroSecretBytes(&hashed) }
        let keyIV = legacyKey(hashedPassword: hashed, entrySalt: entrySalt)
        let ciphertext = try cbc(CCOperation(kCCEncrypt), algorithm: CCAlgorithm(kCCAlgorithm3DES), key: Array(keyIV[0..<24]), iv: Array(keyIV[32..<40]), plaintext)
        return .sequence([.sequence([.oid(NSSOID.pbeSHA1TripleDES), .sequence([.octets(entrySalt), .int(1)])]), .octets(ciphertext)])
    }

    static func encryptSDR(_ plaintext: [UInt8], key: [UInt8], iv: [UInt8], aes: Bool) throws -> String {
        let ciphertext = aes
            ? try cbc(CCOperation(kCCEncrypt), algorithm: CCAlgorithm(kCCAlgorithmAES), key: key, iv: iv, plaintext)
            : try cbc(CCOperation(kCCEncrypt), algorithm: CCAlgorithm(kCCAlgorithm3DES), key: Array(key[0..<24]), iv: iv, plaintext)
        let der = DER.sequence([.octets(sdrKeyID), .sequence([.oid(aes ? NSSOID.aes256CBC : NSSOID.desEDE3CBC), .octets(iv)]), .octets(ciphertext)])
        return Data(der.encoded).base64EncodedString()
    }
}
