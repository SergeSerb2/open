import Foundation
import OpenImport

func runSyntheticSecretsFixture() throws {
    let result = try verifySyntheticSecretsImport()
    let r = result.report
    print("synthetic secrets (generated fixtures; Keychain not requested):")
    print("  logins rows=\(r.loginRows) ok=\(r.loginsDecryptOK) failed=\(r.loginsDecryptFailed) blacklisted=\(r.loginsBlacklisted) invalidTime=\(r.loginsInvalidTime)")
    print("  cookies rows=\(r.cookieRows) ok=\(r.cookiesDecryptOK) failed=\(r.cookiesDecryptFailed) expired=\(r.cookiesExpired) invalidTime=\(r.cookiesInvalidTime) legacyNoHashPrefix=\(r.legacyNoHashPrefix)")
    print("  cards rows=\(r.cardRows) ok=\(r.cardsDecryptOK) failed=\(r.cardsDecryptFailed)")
    print("  addresses rows=\(r.addressRows) invalidTime=\(r.addressesInvalidTime) autofill rows=\(r.autofillRows) invalidTime=\(r.autofillInvalidTime)")
    print("  badPrefix=\(r.badPrefix) redactedRecordKinds=\(result.redactedRecordKinds) knownKey=\(result.knownKeyMatches) hashValues=\(result.hashValuesMatch)")
    let passed = r.loginRows == 13 && r.loginsDecryptOK == 4 && r.loginsDecryptFailed == 5 && r.loginsBlacklisted == 1 && r.loginsInvalidTime == 3 &&
        r.cookieRows == 12 && r.cookiesDecryptOK == 5 && r.cookiesDecryptFailed == 4 && r.cookiesExpired == 1 && r.cookiesInvalidTime == 2 && r.legacyNoHashPrefix == 2 &&
        r.cardRows == 4 && r.cardsDecryptOK == 1 && r.cardsDecryptFailed == 3 && r.badPrefix == 5 &&
        r.addressRows == 4 && r.addressesInvalidTime == 3 && r.autofillRows == 4 && r.autofillInvalidTime == 3 &&
        result.redactedRecordKinds == 4 && result.knownKeyMatches && result.hashValuesMatch
    print("  stored=0 result=\(passed ? "PASS" : "FAIL")")
    if !passed { exit(1) }
}
