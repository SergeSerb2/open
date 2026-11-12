#if OPEN_AUTOMATION
  import Foundation

  /// Debug-only end-to-end test channel: a Unix-domain socket that accepts one
  /// JSON object per line and answers with one JSON object per line.
  /// Protocol and commands: docs/automation.md.
  ///
  /// File descriptor lifetime: one `Connection` owns each client fd. Reads, writes and the close all
  /// run on `queue` (serial). A reply that arrives after its client went away is dropped: it is matched
  /// to the connection object, never to the fd number, because the kernel reuses numbers at once (a late
  /// write once hit a guarded system fd and killed the App with EXC_GUARD, 2026-11-12).
  final class AutomationServer: @unchecked Sendable {
    /// Confined to `queue`. A reply task carries the reference across the main actor and hands it
    /// back to `queue`; it never reads or writes the fields elsewhere.
    private final class Connection: @unchecked Sendable {
      let fd: Int32
      let source: any DispatchSourceRead
      var buffer = Data()
      var isOpen = true
      init(fd: Int32, source: any DispatchSourceRead) { self.fd = fd; self.source = source }
    }
    let socketURL: URL
    private let controller: AutomationController
    private let queue = DispatchQueue(label: "app.open.automation")
    private var listenFD: Int32 = -1
    private var acceptSource: (any DispatchSourceRead)?
    private var connections: [ObjectIdentifier: Connection] = [:]
    /// A request line over this size closes its connection (the largest real request is a few KiB).
    private static let maxRequestBytes = 16 << 20

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
        Darwin.close(fd)
        throw POSIXError(.init(rawValue: errno) ?? .EIO)
      }
      chmod(path, 0o600)
      listenFD = fd
      let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
      source.setEventHandler { [weak self] in self?.acceptClient() }
      source.setCancelHandler { Darwin.close(fd) }
      source.resume()
      acceptSource = source
    }

    func stop() {
      queue.sync {
        // The listen fd closes in the accept source's cancel handler, on this queue, after the last event.
        acceptSource?.cancel(); acceptSource = nil
        for connection in Array(connections.values) { close(connection) }
        unlink(socketURL.path)
      }
    }

    private func acceptClient() {
      let client = accept(listenFD, nil, nil)
      guard client >= 0 else { return }
      var on: Int32 = 1
      setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
      // A client that stops reading must not block the serial queue for ever.
      var timeout = timeval(tv_sec: 10, tv_usec: 0)
      setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
      let source = DispatchSource.makeReadSource(fileDescriptor: client, queue: queue)
      let connection = Connection(fd: client, source: source)
      source.setEventHandler { [weak self, weak connection] in
        guard let self, let connection else { return }
        self.read(connection)
      }
      // The only close of this fd. It runs on `queue` after the source's last event, so no read or
      // write of this connection can run after it (writes check `isOpen`, which is false by then).
      source.setCancelHandler { Darwin.close(client) }
      connections[ObjectIdentifier(connection)] = connection
      source.resume()
    }

    /// On `queue`. Idempotent. After this call nothing writes to the connection's fd.
    private func close(_ connection: Connection) {
      guard connection.isOpen else { return }
      connection.isOpen = false
      connections.removeValue(forKey: ObjectIdentifier(connection))
      connection.source.cancel()
    }

    private func read(_ connection: Connection) {
      guard connection.isOpen else { return }
      var chunk = [UInt8](repeating: 0, count: 65536)
      let n = Darwin.read(connection.fd, &chunk, chunk.count)
      if n < 0, errno == EINTR || errno == EAGAIN { return }
      if n <= 0 { close(connection); return }
      connection.buffer.append(contentsOf: chunk[0..<n])
      while let newline = connection.buffer.firstIndex(of: 0x0A) {
        let line = Data(connection.buffer[connection.buffer.startIndex..<newline])
        connection.buffer = Data(connection.buffer[(newline + 1)...])
        guard !line.isEmpty else { continue }
        let controller = self.controller
        Task { @MainActor in
          let response = await controller.handle(line)
          // The connection object keeps its identity; the fd number alone would not.
          self.queue.async { self.write(response, to: connection) }
        }
      }
      if connection.buffer.count > Self.maxRequestBytes { close(connection) }
    }

    /// On `queue`. Drops the reply when the client has gone; closes the connection on a write error.
    private func write(_ data: Data, to connection: Connection) {
      guard connection.isOpen else { return }
      var out = data
      out.append(0x0A)
      let complete = out.withUnsafeBytes { raw -> Bool in
        var offset = 0
        while offset < raw.count {
          let w = Darwin.write(connection.fd, raw.baseAddress! + offset, raw.count - offset)
          if w < 0, errno == EINTR { continue }
          if w <= 0 { return false }
          offset += w
        }
        return true
      }
      if !complete { close(connection) }
    }
  }
#endif
