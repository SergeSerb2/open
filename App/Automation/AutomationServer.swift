#if OPEN_AUTOMATION
  import Foundation

  /// Debug-only end-to-end test channel: a Unix-domain socket that accepts one
  /// JSON object per line and answers with one JSON object per line.
  /// Protocol and commands: docs/automation.md.
  final class AutomationServer: @unchecked Sendable {
    let socketURL: URL
    private let controller: AutomationController
    private let queue = DispatchQueue(label: "app.open.automation")
    private var listenFD: Int32 = -1
    private var acceptSource: (any DispatchSourceRead)?
    private var clients: [Int32: any DispatchSourceRead] = [:]
    private var buffers: [Int32: Data] = [:]

    init(socketURL: URL, controller: AutomationController) {
      self.socketURL = socketURL
      self.controller = controller
    }

    func start() throws {
      let path = socketURL.path
      unlink(path)
      let fd = socket(AF_UNIX, SOCK_STREAM, 0)
      guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
      var addr = sockaddr_un()
      addr.sun_family = sa_family_t(AF_UNIX)
      let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
      guard path.utf8.count < maxLen else { throw POSIXError(.ENAMETOOLONG) }
      withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        raw.copyBytes(from: path.utf8)
        raw[path.utf8.count] = 0
      }
      let len = socklen_t(MemoryLayout<sockaddr_un>.size)
      let bound = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
      }
      guard bound == 0, listen(fd, 8) == 0 else {
        close(fd)
        throw POSIXError(.init(rawValue: errno) ?? .EIO)
      }
      chmod(path, 0o600)
      listenFD = fd
      let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
      source.setEventHandler { [weak self] in self?.acceptClient() }
      source.resume()
      acceptSource = source
    }

    func stop() {
      queue.sync {
        acceptSource?.cancel()
        clients.values.forEach { $0.cancel() }
        if listenFD >= 0 { close(listenFD) }
        unlink(socketURL.path)
      }
    }

    private func acceptClient() {
      let client = accept(listenFD, nil, nil)
      guard client >= 0 else { return }
      var on: Int32 = 1
      setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
      let source = DispatchSource.makeReadSource(fileDescriptor: client, queue: queue)
      source.setEventHandler { [weak self] in self?.readClient(client) }
      source.setCancelHandler { close(client) }
      clients[client] = source
      buffers[client] = Data()
      source.resume()
    }

    private func readClient(_ fd: Int32) {
      var chunk = [UInt8](repeating: 0, count: 65536)
      let n = read(fd, &chunk, chunk.count)
      if n <= 0 {
        clients.removeValue(forKey: fd)?.cancel()
        buffers.removeValue(forKey: fd)
        return
      }
      buffers[fd, default: Data()].append(contentsOf: chunk[0..<n])
      while let buffer = buffers[fd], let newline = buffer.firstIndex(of: 0x0A) {
        let line = buffer[buffer.startIndex..<newline]
        buffers[fd] = Data(buffer[(newline + 1)...])
        guard !line.isEmpty else { continue }
        let request = Data(line)
        let controller = self.controller
        Task { @MainActor in
          let response = await controller.handle(request)
          self.queue.async { self.write(response, to: fd) }
        }
      }
    }

    private func write(_ data: Data, to fd: Int32) {
      var out = data
      out.append(0x0A)
      out.withUnsafeBytes { raw in
        var offset = 0
        while offset < raw.count {
          let w = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
          if w <= 0 { break }
          offset += w
        }
      }
    }
  }
#endif
