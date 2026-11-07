#if OPEN_AUTOMATION
import OpenEngine
import OpenModel

extension AutomationController {
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
