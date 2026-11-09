#if OPEN_AUTOMATION
import OpenEngine
import OpenModel
import CoreFoundation

extension AutomationController {
  func credentialPreferences(_ args: [String: Any]) throws -> [String: Any] {
    let keys = ["passwordSaving", "cardsSaving", "addressesSaving", "cardReauthentication"]
    guard args.keys.allSatisfy({ keys.contains($0) || $0 == "profile" }),
          keys.allSatisfy({ key in
            guard let value = args[key] else { return true }
            guard let number = value as? NSNumber else { return false }
            return CFGetTypeID(number) == CFBooleanGetTypeID()
          }),
          args["profile"] == nil || (args["profile"] as? String).map({ $0.utf8.count <= 4096 }) == true else {
      throw Failure(message: "expected profile and optional passwordSaving, cardsSaving, addressesSaving, cardReauthentication booleans")
    }
    let factory = try window
    let profile = (args["profile"] as? String).flatMap { requested in
      factory.model.profiles.first { $0.id.description == requested || $0.name == requested || $0.dataDirectoryName == requested }
    } ?? (args["profile"] == nil ? factory.focusedProfile : nil)
    guard let profile, let context = factory.context(for: profile.id) else { throw Failure(message: "no profile context") }
    if let value = args["passwordSaving"] as? Bool { context.passwordSavingEnabled = value }
    if let value = args["cardsSaving"] as? Bool { context.creditCardsSavingEnabled = value }
    if let value = args["addressesSaving"] as? Bool { context.addressesSavingEnabled = value }
    if let value = args["cardReauthentication"] as? Bool { context.creditCardReauthenticationEnabled = value }
    return ["cardReauthentication": context.creditCardReauthenticationEnabled, "passwordSaving": context.passwordSavingEnabled, "cardsSaving": context.creditCardsSavingEnabled,
      "addressesSaving": context.addressesSavingEnabled, "canEnablePasswordSaving": context.canEnablePasswordSaving,
      "canEnableCardsSaving": context.canEnableCreditCardsSaving, "canEnableCreditCardsSaving": context.canEnableCreditCardsSaving]
  }

  /// Counts and capability flags only. The existing factory creates profile
  /// contexts lazily, including a profile with no live page yet.
  func credentialCounts(_ args: [String: Any]) async throws -> [String: Any] {
    let factory = try window
    let profile = if let requested = args["profile"] as? String {
      factory.model.profiles.first {
        $0.id.description == requested || $0.name == requested || $0.dataDirectoryName == requested
      }
    } else { factory.focusedProfile }
    guard let profile, let context = factory.context(for: profile.id) else {
      throw Failure(message: "no profile context")
    }
    let counts = await context.fetchCredentialCounts()
    return ["logins": counts.logins, "blockedSites": counts.blockedSites,
            "cards": counts.cards, "addresses": counts.addresses, "cookies": counts.cookies,
            "passwordSavingEnabled": context.passwordSavingEnabled,
            "canEnablePasswordSaving": context.canEnablePasswordSaving,
            "creditCardsSavingEnabled": context.creditCardsSavingEnabled,
            "canEnableCreditCardsSaving": context.canEnableCreditCardsSaving,
            "addressesSavingEnabled": context.addressesSavingEnabled,
            "supportsSecretsImport": OEEngine.shared.supportsSecretsImport,
            "usesMockKeychain": OEEngine.shared.usesMockKeychain]
  }
}
#endif
