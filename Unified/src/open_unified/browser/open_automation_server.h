// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef OPEN_UNIFIED_BROWSER_OPEN_AUTOMATION_SERVER_H_
#define OPEN_UNIFIED_BROWSER_OPEN_AUTOMATION_SERVER_H_

#include <map>
#include <memory>
#include <string>

#include "base/files/file_path.h"
#include "base/functional/callback.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "base/types/expected.h"
#include "base/values.h"
#include "open_unified/buildflags.h"

#if !BUILDFLAG(OPEN_ENABLE_AUTOMATION)
#error "open_automation_server.h is only built with open_enable_automation"
#endif

namespace base {
class CommandLine;
}

namespace open_unified {

class OpenBrowserService;

// The test harness channel of docs/automation.md for the unified browser:
// one JSON object per line in each direction,
//
//   -> {"id": 1, "cmd": "open", "args": {"url": "https://example.com"}}
//   <- {"id": 1, "ok": true, "result": {...}}
//   <- {"id": 2, "ok": false, "error": "no tab 1234"}
//
// Transports (both may run at once):
// - AF_UNIX stream socket, mode 0600: --automation-socket=PATH, else
//   $OPEN_AUTOMATION_SOCKET, else <user data>/automation.sock. Linux,
//   macOS, and Windows 10 1803+ (afunix.h).
// - Loopback TCP 127.0.0.1:<port>: --automation-port=PORT (0 = any free
//   port; the bound port is written to <user data>/automation.port). Every
//   request must carry "token" equal to <user data>/automation.token
//   (random, mode 0600 where supported), since any local user can reach a
//   loopback port.
//
// Sockets are served on background platform threads (one per connection,
// commands run one at a time per connection). Each command runs on the UI
// thread; the UI thread never blocks on a socket. Only builds with
// open_enable_automation = true contain this class.
class OpenAutomationServer {
 public:
  using Reply =
      base::OnceCallback<void(base::expected<base::Value, std::string>)>;
  using Handler =
      base::RepeatingCallback<void(const base::DictValue& args, Reply)>;

  // Starts the transports the command line asks for. Returns null (and logs)
  // when no transport could start.
  static std::unique_ptr<OpenAutomationServer> CreateFromCommandLine(
      OpenBrowserService* service,
      const base::CommandLine& command_line,
      const base::FilePath& user_data_dir);

  explicit OpenAutomationServer(OpenBrowserService* service);
  ~OpenAutomationServer();

  OpenAutomationServer(const OpenAutomationServer&) = delete;
  OpenAutomationServer& operator=(const OpenAutomationServer&) = delete;

  bool ListenUnix(const base::FilePath& path);
  // |port| 0 picks a free port. Returns the bound port, or 0 on failure.
  int ListenTcp(int port, const base::FilePath& user_data_dir);

  // Runs one command on the UI thread (also used by tests of the protocol
  // through the socket only; there is no in-process shortcut).
  void Dispatch(const std::string& cmd, base::DictValue args, Reply reply);

 private:
  class Transport;
  friend class Transport;

  void RegisterCommands();
  void Add(const std::string& name, Handler handler);

  raw_ptr<OpenBrowserService> service_;
  std::map<std::string, Handler> handlers_;
  std::unique_ptr<Transport> unix_transport_;
  std::unique_ptr<Transport> tcp_transport_;
  base::WeakPtrFactory<OpenAutomationServer> weak_factory_{this};
};

}  // namespace open_unified

#endif  // OPEN_UNIFIED_BROWSER_OPEN_AUTOMATION_SERVER_H_
