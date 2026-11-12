#if OPEN_AUTOMATION
import Foundation
import ObjectiveC

/// e2e isolation (LEAD 10:45): an automation build launched with `OPEN_E2E_PREFERENCES_DOMAIN` keeps every
/// preference in that private domain. `UserDefaults.standard` (ours, AppKit's, SwiftUI's `@AppStorage`) then
/// reads and writes the private domain only: a suite's keys never reach `io.github.sergeserb2.open`, and the
/// user's own preferences never change a test. A suite-name defaults object does not read the App's own domain
/// (checked: it searches its suite, the global domain and the registration domain).
enum AutomationPreferences {
  static let realDomain = "io.github.sergeserb2.open"
  static let prefix = realDomain + ".e2e."
  /// The domain `UserDefaults.standard` persists to in this process.
  nonisolated(unsafe) private(set) static var domain = realDomain

  /// Call first in main.swift, before anything reads a preference. An invalid name stops the launch:
  /// a harness that asked for isolation must never fall back to the real domain.
  static func installIfRequested() {
    guard let name = ProcessInfo.processInfo.environment["OPEN_E2E_PREFERENCES_DOMAIN"], !name.isEmpty else { return }
    let tail = name.dropFirst(prefix.count)
    guard name.hasPrefix(prefix), name.utf8.count <= 120, !tail.isEmpty, !tail.hasSuffix("."),
      tail.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == ".") }),
      let suite = UserDefaults(suiteName: name),
      let method = class_getClassMethod(UserDefaults.self, #selector(getter: UserDefaults.standard))
    else {
      FileHandle.standardError.write(Data("Open: invalid OPEN_E2E_PREFERENCES_DOMAIN; refusing to use the real preferences domain\n".utf8))
      exit(64)
    }
    let block: @convention(block) (AnyObject) -> UserDefaults = { _ in suite }
    method_setImplementation(method, imp_implementationWithBlock(block))
    domain = name
  }
}
#endif
