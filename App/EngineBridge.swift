import AppKit
import OpenEngine
import OpenWeb

// The App target is the only place where OpenEngine meets OpenKit: these
// adapters make the engine classes usable through the OpenWeb protocols.

extension OEWebContent: @retroactive WebContent {
  public var faviconPNG: Data? { favicon.flatMap(EngineWebContentHostFactory.pngData) }
  public var isCrashed: Bool { crashState != .none }
  public func evaluateJavaScript(_ script: String, in world: ScriptWorld) async throws -> Any {
    try await evaluateJavaScript(script, inWorld: world == .open ? .open : .page)
  }
  public func snapshotPNG() async throws -> Data { try await takeSnapshot() }
  public func motionSnapshotPNG() async throws -> Data {
    let result = try await sendDevToolsMethod("Page.captureScreenshot", parameters: [
      "format": "png", "fromSurface": false, "captureBeyondViewport": false,
    ])
    guard let encoded = result["data"] as? String, encoded.utf8.count <= 90 * 1024 * 1024,
      let data = Data(base64Encoded: encoded), data.count <= 64 * 1024 * 1024
    else { throw CocoaError(.fileReadCorruptFile) }
    return data
  }
  /// EP-8 (page-platform §6): OpenEngine's tiled DevTools capture.
  public func fullPagePNG(maxDevicePixels: Int) async throws -> FullPagePNG {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<FullPagePNG, any Error>) in
      captureFullPage(maxDevicePixels: maxDevicePixels) { png, truncated, error in
        if let png { continuation.resume(returning: FullPagePNG(data: png, truncated: truncated)) }
        else { continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
      }
    }
  }
}

/// OpenWeb.WebProfile over one OEBrowserContext.
@MainActor
final class EngineWebProfile: WebProfile {
  let context: OEBrowserContext

  init(_ context: OEBrowserContext) { self.context = context }

  var identifier: String { context.identifier }

  var userScripts: [UserScript] {
    context.userScripts.map {
      UserScript(
        id: $0.identifier, source: $0.kind == .javaScript ? OpenWorldPrelude.unwrapped($0.source, world: $0.world) : $0.source, kind: $0.kind == .styleSheet ? .styleSheet : .javaScript,
        injectionTime: $0.injectionTime == .documentEnd ? .documentEnd : .documentStart,
        matchPatterns: $0.matchPatterns, mainFrameOnly: $0.mainFrameOnly,
        world: $0.world == .open ? .open : .page)
    }
  }

  func addUserScript(_ script: UserScript) {
    context.addUserScript(Self.engineScript(script))
  }

  func replaceUserScripts(removing ids: [String], adding scripts: [UserScript]) {
    context.replaceUserScripts(removing: ids, adding: scripts.map(Self.engineScript))
  }

  private static func engineScript(_ script: UserScript) -> OEUserScript {
    let value = OEUserScript(
        identifier: script.id, source: script.world == .open && script.kind == .javaScript ? OpenWorldPrelude.source + "\n" + script.source : script.source,
        kind: script.kind == .styleSheet ? .styleSheet : .javaScript,
        injectionTime: script.injectionTime == .documentEnd ? .documentEnd : .documentStart,
        matchPatterns: script.matchPatterns, mainFrameOnly: script.mainFrameOnly)
    value.world = script.world == .open ? .open : .page
    return value
  }

  func removeUserScript(id: String) { context.removeUserScript(identifier: id) }

  func setRequestFilter(_ filter: RequestFilter?) {
    guard let filter else {
      context.requestFilter = nil
      return
    }
    context.requestFilter = { request in
      let info = ResourceRequestInfo(
        url: request.urlString, method: request.method, firstPartyURL: request.firstPartyURLString,
        initiator: request.initiator, type: Self.type(request.resourceType), isNavigation: request.isNavigation)
      return filter(info) ? .block : .allow
    }
  }

  nonisolated private static func type(_ t: OEResourceType) -> ResourceType {
    switch t {
    case .mainFrame: return .mainFrame
    case .subFrame: return .subFrame
    case .stylesheet: return .stylesheet
    case .script: return .script
    case .image: return .image
    case .font: return .font
    case .media: return .media
    case .XHR: return .xhr
    case .fetch: return .fetch
    case .ping: return .ping
    case .worker: return .worker
    case .serviceWorker: return .serviceWorker
    case .favicon: return .favicon
    default: return .other
    }
  }

  private static func kind(_ p: SitePermission) -> OEPermissionKind {
    switch p {
    case .camera: return .camera
    case .microphone: return .microphone
    case .geolocation: return .geolocation
    case .notifications: return .notifications
    case .clipboard: return .clipboard
    case .midi: return .MIDI
    case .screenCapture: return .screenCapture
    case .automaticDownloads: return .multipleDownloads
    case .storageAccess: return .storageAccess
    case .windowManagement: return .windowManagement
    case .localFonts: return .localFonts
    case .idleDetection: return .idleDetection
    }
  }

  func permission(_ permission: SitePermission, origin: URL) -> SitePermissionState {
    switch SitePermissionStore.forContext(context).state(origin: origin, kind: Self.kind(permission)) {
    case .allow: return .allow
    case .block: return .block
    default: return .ask
    }
  }

  func setPermission(_ state: SitePermissionState, for permission: SitePermission, origin: URL) {
    let s: OEPermissionState = state == .allow ? .allow : state == .block ? .block : .ask
    SitePermissionStore.forContext(context).set(origin: origin, kind: Self.kind(permission), state: s)
  }

  /// Runs after every permission write through this adapter (tab sleep's notification gate).
  static var onPermissionChange: ((OEBrowserContext) -> Void)?
}
