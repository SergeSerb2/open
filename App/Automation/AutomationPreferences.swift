#if OPEN_AUTOMATION
import Foundation
import ObjectiveC

/// e2e isolation (LEAD 10:45, 12:18): an automation build launched with `OPEN_E2E_PREFERENCES_DOMAIN`, or by a script
/// (`scriptedLaunchDomain`), keeps every
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
    let env = ProcessInfo.processInfo.environment
    guard let name = env["OPEN_E2E_PREFERENCES_DOMAIN"].flatMap({ $0.isEmpty ? nil : $0 }) ?? scriptedLaunchDomain(env) else { return }
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

  /// A scripted launch without its own domain (timing, bench and capture scripts) still never uses the real
  /// domain. Scripted means a data folder or an automation socket was given (`--user-data-dir=`, `OPEN_USER_DATA`,
  /// `--automation-socket=`, `OPEN_AUTOMATION_SOCKET`); a person's launch of an automation build gives neither and
  /// keeps the real domain. The name is derived from the data folder (else the socket), so relaunches with the
  /// same folder keep their preferences.
  static func scriptedLaunchDomain(_ env: [String: String]) -> String? {
    func argument(_ name: String) -> String? {
      CommandLine.arguments.dropFirst().first { $0.hasPrefix("--\(name)=") }.map { String($0.dropFirst(name.count + 3)) }
    }
    guard let key = argument("user-data-dir") ?? env["OPEN_USER_DATA"] ?? argument("automation-socket") ?? env["OPEN_AUTOMATION_SOCKET"],
      !key.isEmpty else { return nil }
    let path = URL(fileURLWithPath: (key as NSString).expandingTildeInPath).standardizedFileURL.path
    // FNV-1a 64: stable across launches and processes (Swift's Hasher is seeded per process).
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in path.utf8 { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3 }
    return prefix + "s" + String(format: "%016llx", hash)
  }
}
#endif
