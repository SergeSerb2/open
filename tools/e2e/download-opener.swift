import AppKit
import CryptoKit

/// A disposable background application used by the real Library Open action.
/// It has no windows and reads only one bounded file in the runner's root.
@MainActor
private final class DocumentReceiver: NSObject, NSApplicationDelegate {
    private var received = false
    private var deadline: Task<Void, Never>?
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !received else { return }
        deadline = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            if !Task.isCancelled, self?.received == false { NSApp.terminate(nil) }
        }
    }
    func application(_ sender: NSApplication, open urls: [URL]) { receive(urls, reply: false) }
    func application(_ sender: NSApplication, openFiles filenames: [String]) { receive(filenames.map { URL(fileURLWithPath: $0) }, reply: true) }
    func application(_ sender: NSApplication, openFile filename: String) -> Bool { receive([URL(fileURLWithPath: filename)], reply: false); return true }
    private func receive(_ urls: [URL], reply: Bool) {
        guard !received else { return }
        received = true; deadline?.cancel(); deadline = nil
        let environment = ProcessInfo.processInfo.environment
        let root = environment["OPEN_DOWNLOADS_OPEN_FILE_ROOT"] ?? ""
        let receipt = environment["OPEN_DOWNLOADS_OPEN_FILE_RECEIPT"] ?? ""
        Task {
            await Task.detached(priority: .utility) {
                let allowed = URL(fileURLWithPath: root).resolvingSymlinksInPath().standardizedFileURL
                let output = URL(fileURLWithPath: receipt)
                guard !root.isEmpty, output.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL == allowed else { return }
                var result: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier]
                do {
                    guard urls.count == 1 else { throw CocoaError(.fileReadInvalidFileName) }
                    let file = urls[0].resolvingSymlinksInPath().standardizedFileURL
                    guard file.path.hasPrefix(allowed.path + "/") else { throw CocoaError(.fileReadNoPermission) }
                    let handle = try FileHandle(forReadingFrom: file)
                    defer { try? handle.close() }
                    // One allocation is bounded at 2 MiB + 1; refuse a larger file.
                    let bytes = try handle.read(upToCount: 2 * 1024 * 1024 + 1) ?? Data()
                    guard bytes.count <= 2 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
                    result["url"] = file.absoluteString
                    result["bytes"] = bytes.count
                    result["sha256"] = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                } catch { result["error"] = error.localizedDescription }
                if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) { try? data.write(to: output, options: .atomic) }
            }.value
            if reply { NSApp.reply(toOpenOrPrint: .success) }
            NSApp.terminate(nil)
        }
    }
}

@main private enum DownloadOpenProbe {
    @MainActor static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        let receiver = DocumentReceiver()
        application.delegate = receiver
        withExtendedLifetime(receiver) { application.run() }
    }
}
