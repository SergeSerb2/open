// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "open_unified/browser/open_automation_server.h"

#include <algorithm>
#include <atomic>
#include <cstring>
#include <list>
#include <set>
#include <utility>
#include <vector>

#include "base/base64.h"
#include "base/command_line.h"
#include "base/environment.h"
#include "base/files/file_util.h"
#include "base/functional/bind.h"
#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/logging.h"
#include "base/memory/ref_counted.h"
#include "base/memory/ref_counted_memory.h"
#include "base/no_destructor.h"
#include "base/process/process_handle.h"
#include "base/rand_util.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/string_util.h"
#include "base/strings/utf_string_conversions.h"
#include "base/synchronization/lock.h"
#include "base/synchronization/waitable_event.h"
#include "base/task/single_thread_task_runner.h"
#include "base/task/thread_pool.h"
#include "base/threading/platform_thread.h"
#include "base/threading/thread_restrictions.h"
#include "base/time/time.h"
#include "base/timer/timer.h"
#include "base/version_info/version_info.h"
#include "build/build_config.h"
#include "chrome/browser/lifetime/application_lifetime.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/views/frame/browser_view.h"
#include "chrome/common/chrome_isolated_world_ids.h"
#include "components/input/native_web_keyboard_event.h"
#include "content/public/browser/browser_thread.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/render_widget_host.h"
#include "content/public/browser/render_widget_host_view.h"
#include "content/public/browser/web_contents.h"
#include "content/public/common/isolated_world_ids.h"
#include "open/adblock/open_adblock_service.h"
#include "open_unified/browser/open_boost_controller.h"
#include "open_unified/browser/open_browser_service.h"
#include "open_unified/browser/open_extension_bridge.h"
#include "open_unified/browser/open_json.h"
#include "open_unified/browser/open_model_util.h"
#include "open_unified/browser/open_sleep_controller.h"
#include "open_unified/browser/open_switches.h"
#include "open_unified/browser/open_tab_bridge.h"
#include "open_unified/browser/open_window_controller.h"
#include "open_unified/core/adblock/open_adblock_profile_service.h"
#include "open_unified/core/store/sqlite_stores.h"
#include "open_unified/core/sync/sync_engine.h"
#include "third_party/blink/public/common/input/web_input_event.h"
#include "third_party/blink/public/common/input/web_keyboard_event.h"
#include "third_party/blink/public/common/input/web_mouse_event.h"
#include "ui/base/accelerators/accelerator.h"
#include "ui/base/base_window.h"
#include "ui/events/base_event_utils.h"
#include "ui/events/event.h"
#include "ui/events/event_constants.h"
#include "ui/events/keycodes/dom/dom_code.h"
#include "ui/events/keycodes/dom/dom_key.h"
#include "ui/events/keycodes/keyboard_codes.h"
#include "ui/gfx/codec/png_codec.h"
#include "ui/gfx/image/image.h"
#include "ui/snapshot/snapshot.h"
#include "ui/views/focus/focus_manager.h"
#include "ui/views/widget/widget.h"
#include "url/gurl.h"

#if BUILDFLAG(IS_WIN)
#include <winsock2.h>
#include <ws2tcpip.h>
// winsock2.h must come first.
#include <afunix.h>
#include <windows.h>
#include <sddl.h>
#ifdef FindWindow
#undef FindWindow
#endif
#else
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>
#endif

namespace open_unified {

namespace {

// ===========================================================================
// Portable sockets (blocking, served on background platform threads).
// ===========================================================================

#if BUILDFLAG(IS_WIN)
using SocketHandle = SOCKET;
constexpr SocketHandle kInvalidSocket = INVALID_SOCKET;
void CloseSocket(SocketHandle s) {
  closesocket(s);
}
void ShutdownSocket(SocketHandle s) {
  shutdown(s, SD_BOTH);
}
int PollRead(SocketHandle s, int timeout_ms) {
  WSAPOLLFD fd = {};
  fd.fd = s;
  fd.events = POLLRDNORM;
  return WSAPoll(&fd, 1, timeout_ms);
}
bool EnsureSocketsInitialized() {
  static const bool initialized = [] {
    WSADATA data;
    return WSAStartup(MAKEWORD(2, 2), &data) == 0;
  }();
  return initialized;
}
#else
using SocketHandle = int;
constexpr SocketHandle kInvalidSocket = -1;
void CloseSocket(SocketHandle s) {
  close(s);
}
void ShutdownSocket(SocketHandle s) {
  shutdown(s, SHUT_RDWR);
}
int PollRead(SocketHandle s, int timeout_ms) {
  pollfd fd = {};
  fd.fd = s;
  fd.events = POLLIN;
  return poll(&fd, 1, timeout_ms);
}
bool EnsureSocketsInitialized() {
  return true;
}
#endif

bool SendAll(SocketHandle s, const std::string& data) {
  size_t sent = 0;
  while (sent < data.size()) {
#if BUILDFLAG(IS_WIN)
    const int n = send(s, data.data() + sent,
                       static_cast<int>(std::min<size_t>(data.size() - sent,
                                                         1 << 20)),
                       0);
#else
#if defined(MSG_NOSIGNAL)
    constexpr int kSendFlags = MSG_NOSIGNAL;
#else
    constexpr int kSendFlags = 0;  // macOS: the browser ignores SIGPIPE.
#endif
    const ssize_t n =
        send(s, data.data() + sent, data.size() - sent, kSendFlags);
#endif
    if (n <= 0) {
      return false;
    }
    sent += static_cast<size_t>(n);
  }
  return true;
}

constexpr int kPollMs = 250;
constexpr size_t kMaxRequestBytes = 16 * 1024 * 1024;

// The UI thread fills this; the connection thread waits for it.
class PendingReply : public base::RefCountedThreadSafe<PendingReply> {
 public:
  PendingReply()
      : done_(base::WaitableEvent::ResetPolicy::MANUAL,
              base::WaitableEvent::InitialState::NOT_SIGNALED) {}

  // The first completion wins (a ReplyGuard may complete a dropped reply
  // after a late real one).
  void Complete(std::string line) {
    {
      base::AutoLock lock(lock_);
      if (completed_) {
        return;
      }
      completed_ = true;
      line_ = std::move(line);
    }
    done_.Signal();
  }
  bool Wait(const std::atomic<bool>& stop) {
    while (!stop.load()) {
      if (done_.TimedWait(base::Milliseconds(kPollMs))) {
        return true;
      }
    }
    return false;
  }
  std::string TakeLine() {
    base::AutoLock lock(lock_);
    return std::move(line_);
  }

 private:
  friend class base::RefCountedThreadSafe<PendingReply>;
  ~PendingReply() = default;

  base::Lock lock_;
  bool completed_ = false;
  std::string line_;
  base::WaitableEvent done_;
};

std::string ResponseLine(const base::Value& id,
                         base::expected<base::Value, std::string> result) {
  base::DictValue response;
  response.Set("id", id.Clone());
  if (result.has_value()) {
    response.Set("ok", true);
    response.Set("result", std::move(result).value());
  } else {
    response.Set("ok", false);
    response.Set("error", result.error());
  }
  std::optional<std::string> json = base::WriteJson(response);
  return (json ? *json : std::string(R"({"ok":false,"error":"encode"})")) +
         "\n";
}

// Answers a command's PendingReply with an error when the reply callback is
// destroyed without running (a handler or a Chromium callback dropped it,
// or the UI task was discarded at shutdown), so the connection thread never
// waits forever.
class ReplyGuard {
 public:
  ReplyGuard(base::Value id, scoped_refptr<PendingReply> pending)
      : id_(std::move(id)), pending_(std::move(pending)) {}
  ReplyGuard(const ReplyGuard&) = delete;
  ReplyGuard& operator=(const ReplyGuard&) = delete;
  ~ReplyGuard() {
    if (pending_) {
      pending_->Complete(ResponseLine(
          id_, base::unexpected("command dropped without a reply")));
    }
  }

  void Complete(base::expected<base::Value, std::string> result) {
    if (pending_) {
      pending_->Complete(ResponseLine(id_, std::move(result)));
      pending_.reset();
    }
  }

 private:
  base::Value id_;
  scoped_refptr<PendingReply> pending_;
};

}  // namespace

// ===========================================================================
// Transport: accept loop + one thread per connection.
// ===========================================================================

class OpenAutomationServer::Transport : public base::PlatformThread::Delegate {
 public:
  Transport(base::WeakPtr<OpenAutomationServer> server,
            SocketHandle listen_socket,
            std::string token,
            base::FilePath unix_path)
      : server_(std::move(server)),
        ui_task_runner_(content::GetUIThreadTaskRunner({})),
        listen_socket_(listen_socket),
        token_(std::move(token)),
        unix_path_(std::move(unix_path)) {}

  ~Transport() override {
    // Joins below wait at most one poll interval (250 ms) per thread.
    base::ScopedAllowBaseSyncPrimitivesForTesting allow_join;
    stop_.store(true);
    if (accept_thread_) {
      base::PlatformThread::Join(*accept_thread_);
    }
    CloseSocket(listen_socket_);
    std::list<std::unique_ptr<Connection>> connections;
    {
      base::AutoLock lock(lock_);
      connections.swap(connections_);
    }
    for (auto& connection : connections) {
      connection->Stop();
    }
    connections.clear();  // Joins each thread.
    if (!unix_path_.empty()) {
      base::ScopedAllowBlockingForTesting allow_blocking;
      base::DeleteFile(unix_path_);
    }
  }

  bool Start() {
    base::PlatformThreadHandle handle;
    if (!base::PlatformThread::Create(0, this, &handle)) {
      return false;
    }
    accept_thread_ = handle;
    return true;
  }

  // base::PlatformThread::Delegate:
  void ThreadMain() override {
    base::PlatformThread::SetName("OpenAutomationAccept");
    while (!stop_.load()) {
      if (PollRead(listen_socket_, kPollMs) <= 0) {
        continue;
      }
      SocketHandle client = accept(listen_socket_, nullptr, nullptr);
      if (client == kInvalidSocket) {
        continue;
      }
      ReapFinishedConnections();
      auto connection = std::make_unique<Connection>(this, client);
      if (connection->Start()) {
        base::AutoLock lock(lock_);
        connections_.push_back(std::move(connection));
      }
    }
  }

  // Joins and frees connections whose thread has ended (the peer closed or
  // sent a bad request), so a long harness run does not keep one dead
  // thread handle and socket per past connection.
  void ReapFinishedConnections() {
    std::list<std::unique_ptr<Connection>> finished;
    {
      base::AutoLock lock(lock_);
      for (auto it = connections_.begin(); it != connections_.end();) {
        if ((*it)->finished()) {
          finished.push_back(std::move(*it));
          it = connections_.erase(it);
        } else {
          ++it;
        }
      }
    }
    finished.clear();  // Outside the lock: each join returns at once.
  }

 private:
  class Connection : public base::PlatformThread::Delegate {
   public:
    Connection(Transport* transport, SocketHandle socket)
        : transport_(transport), socket_(socket) {}
    ~Connection() override {
      Stop();
      if (thread_) {
        base::PlatformThread::Join(*thread_);
      }
      CloseSocket(socket_);
    }

    bool Start() {
      base::PlatformThreadHandle handle;
      if (!base::PlatformThread::Create(0, this, &handle)) {
        return false;
      }
      thread_ = handle;
      return true;
    }
    void Stop() {
      stop_.store(true);
      ShutdownSocket(socket_);
    }
    bool finished() const { return finished_.load(); }

    void ThreadMain() override {
      base::PlatformThread::SetName("OpenAutomationConn");
      Serve();
      finished_.store(true);
    }

   private:
    void Serve() {
      std::string buffer;
      char chunk[64 * 1024];
      while (!stop_.load() && !transport_->stop_.load()) {
        const int ready = PollRead(socket_, kPollMs);
        if (ready == 0) {
          continue;
        }
        if (ready < 0) {
          break;
        }
        const int n = static_cast<int>(recv(socket_, chunk, sizeof(chunk), 0));
        if (n <= 0) {
          break;
        }
        buffer.append(chunk, static_cast<size_t>(n));
        if (buffer.size() > kMaxRequestBytes) {
          SendAll(socket_, ResponseLine(base::Value(),
                                        base::unexpected("request too large")));
          break;
        }
        size_t newline;
        while ((newline = buffer.find('\n')) != std::string::npos) {
          std::string line = buffer.substr(0, newline);
          buffer.erase(0, newline + 1);
          if (!base::TrimWhitespaceASCII(line, base::TRIM_ALL).empty() &&
              !HandleLine(line)) {
            return;
          }
        }
      }
    }

    // Returns false when the connection must end.
    bool HandleLine(const std::string& line) {
      std::optional<base::DictValue> request =
          base::JSONReader::ReadDict(line, base::JSON_PARSE_RFC);
      if (!request) {
        return SendAll(socket_, ResponseLine(base::Value(),
                                             base::unexpected("bad json")));
      }
      base::Value id = request->Find("id") ? request->Find("id")->Clone()
                                           : base::Value();
      const std::string* cmd = request->FindString("cmd");
      if (!cmd) {
        return SendAll(socket_,
                       ResponseLine(id, base::unexpected("missing cmd")));
      }
      if (!transport_->token_.empty()) {
        const std::string* token = request->FindString("token");
        if (!token || *token != transport_->token_) {
          return SendAll(socket_,
                         ResponseLine(id, base::unexpected("bad token")));
        }
      }
      base::DictValue args;
      if (base::DictValue* a = request->FindDict("args")) {
        args = std::move(*a);
      }
      auto pending = base::MakeRefCounted<PendingReply>();
      // The guard travels with the task, then with the reply callback: if
      // either is destroyed unrun, the request is answered with an error.
      auto guard = std::make_unique<ReplyGuard>(id.Clone(), pending);
      transport_->ui_task_runner_->PostTask(
          FROM_HERE,
          base::BindOnce(
              [](base::WeakPtr<OpenAutomationServer> server, std::string cmd,
                 base::DictValue args, std::unique_ptr<ReplyGuard> guard) {
                if (!server) {
                  guard->Complete(base::unexpected("shutting down"));
                  return;
                }
                server->Dispatch(
                    cmd, std::move(args),
                    base::BindOnce(
                        [](std::unique_ptr<ReplyGuard> guard,
                           base::expected<base::Value, std::string> result) {
                          guard->Complete(std::move(result));
                        },
                        std::move(guard)));
              },
              transport_->server_, *cmd, std::move(args), std::move(guard)));
      if (!pending->Wait(stop_)) {
        return false;
      }
      return SendAll(socket_, pending->TakeLine());
    }

    raw_ptr<Transport> transport_;
    SocketHandle socket_;
    std::atomic<bool> stop_{false};
    std::atomic<bool> finished_{false};
    std::optional<base::PlatformThreadHandle> thread_;
  };

  base::WeakPtr<OpenAutomationServer> server_;
  scoped_refptr<base::SingleThreadTaskRunner> ui_task_runner_;
  SocketHandle listen_socket_;
  const std::string token_;
  const base::FilePath unix_path_;
  std::atomic<bool> stop_{false};
  std::optional<base::PlatformThreadHandle> accept_thread_;
  base::Lock lock_;
  std::list<std::unique_ptr<Connection>> connections_;
};

// ===========================================================================
// Command helpers (UI thread).
// ===========================================================================

namespace {

using Reply = OpenAutomationServer::Reply;

OpenBrowserService* Svc() {
  return OpenBrowserService::Get();
}

void Ok(Reply reply, base::Value value) {
  std::move(reply).Run(std::move(value));
}

void Ok(Reply reply, base::DictValue dict) {
  std::move(reply).Run(base::Value(std::move(dict)));
}

void Err(Reply reply, std::string message) {
  std::move(reply).Run(base::unexpected(std::move(message)));
}

// `tab`: sidebar tab id (string); `index`: position in the focused Space's
// tab order; neither: the selected tab.
std::optional<ItemID> ResolveTab(const base::DictValue& args,
                                 std::string* error) {
  OpenBrowserService* service = Svc();
  BrowserModel& model = service->model();
  if (const std::string* id = args.FindString("tab")) {
    if (model.FindTab(*id) || model.FindNode(*id)) {
      return *id;
    }
    *error = "no tab " + *id;
    return std::nullopt;
  }
  std::optional<int> index = args.FindInt("index");
  if (!index) {
    index = args.FindInt("tab");
  }
  if (index) {
    const BrowserWindowState* window =
        model.FindWindow(service->MainWindowId());
    if (window) {
      std::vector<ItemID> ids =
          model_util::OrderedTabIds(model, window->focused_space_id);
      if (*index >= 0 && static_cast<size_t>(*index) < ids.size()) {
        return ids[static_cast<size_t>(*index)];
      }
    }
    *error = "no tab at index " + base::NumberToString(*index);
    return std::nullopt;
  }
  if (std::optional<ItemID> active = service->tab_bridge()->ActiveTabId()) {
    return active;
  }
  *error = "no selected tab";
  return std::nullopt;
}

// Resolves and loads the tab's page.
content::WebContents* ResolveContents(const base::DictValue& args,
                                      std::string* error) {
  std::optional<ItemID> id = ResolveTab(args, error);
  if (!id) {
    return nullptr;
  }
  content::WebContents* contents = Svc()->tab_bridge()->EnsureLoaded(*id);
  if (!contents) {
    *error = "tab " + *id + " has no page";
  }
  return contents;
}

OpenWindowUi* MainUi() {
  OpenWindowController* windows = Svc()->window_controller();
  return windows ? windows->MainWindowUi() : nullptr;
}

BrowserView* MainBrowserView() {
  BrowserWindowInterface* browser = Svc()->tab_bridge()->MainBrowser();
  return browser ? BrowserView::GetBrowserViewForBrowser(browser) : nullptr;
}

std::string_view SectionOf(const BrowserModel& model, const ItemID& id) {
  switch (model_util::SectionOfNode(model, id).value_or(
      NodeParentKind::kSpaceToday)) {
    case NodeParentKind::kFavorites:
      return "favorites";
    case NodeParentKind::kSpacePinned:
      return "pinned";
    default:
      return "today";
  }
}

base::DictValue PageState(content::WebContents* contents) {
  return base::DictValue()
      .Set("url", contents->GetLastCommittedURL().spec())
      .Set("title", base::UTF16ToUTF8(contents->GetTitle()))
      .Set("loading", contents->IsLoading())
      .Set("discarded", contents->WasDiscarded())
      .Set("crashed", contents->IsCrashed())
      .Set("visible",
           contents->GetVisibility() == content::Visibility::VISIBLE);
}

base::DictValue TabRow(const ItemID& id) {
  OpenBrowserService* service = Svc();
  const BrowserModel& model = service->model();
  const Tab* tab = model.FindTab(id);
  content::WebContents* contents = service->tab_bridge()->WebContentsForTab(id);
  base::DictValue row;
  row.Set("id", id);
  row.Set("title", tab ? tab->display_title() : std::string());
  row.Set("url", tab ? tab->url : std::string());
  row.Set("section", SectionOf(model, id));
  row.Set("selected", service->tab_bridge()->ActiveTabId() == id);
  row.Set("visible",
          contents &&
              contents->GetVisibility() == content::Visibility::VISIBLE);
  row.Set("loaded", contents != nullptr);
  row.Set("loading", tab && tab->live_state.is_loading);
  row.Set("audible", tab && tab->live_state.is_audible);
  row.Set("crashed", tab && tab->live_state.is_crashed);
  row.Set("favicon", tab && !tab->live_state.favicon_png.empty());
  row.Set("phase", json::SleepPhaseName(tab ? tab->live_state.sleep_phase
                                            : SleepPhase::kPlaceholder));
  if (tab) {
    row.Set("createdAt", tab->created_at);
    row.Set("lastActiveAt", tab->last_active_at);
  }
  if (std::optional<NodeParent> parent = model.GetParent(id)) {
    row.Set("parent", base::DictValue()
                          .Set("kind", json::NodeParentKindName(parent->kind))
                          .Set("id", parent->owner_id));
  }
  if (contents) {
    row.Set("page", PageState(contents));
  }
  return row;
}

// Waits on the UI thread until a page is live and not loading. Live
// waiters are tracked so the server's teardown answers them at once.
class LoadWaiter {
 public:
  static void Start(ItemID tab_id, base::TimeDelta timeout, Reply reply) {
    auto* waiter = new LoadWaiter(std::move(tab_id), timeout, std::move(reply));
    waiter->Check();
  }

  // OpenAutomationServer teardown: every pending wait fails now.
  static void CancelAll() {
    std::set<LoadWaiter*> waiters;
    waiters.swap(Live());
    for (LoadWaiter* waiter : waiters) {
      waiter->Finish(base::unexpected("shutting down"));
    }
  }

 private:
  static std::set<LoadWaiter*>& Live() {
    static base::NoDestructor<std::set<LoadWaiter*>> live;
    return *live;
  }

  LoadWaiter(ItemID tab_id, base::TimeDelta timeout, Reply reply)
      : tab_id_(std::move(tab_id)),
        deadline_(base::TimeTicks::Now() + timeout),
        reply_(std::move(reply)) {
    Live().insert(this);
  }
  ~LoadWaiter() { Live().erase(this); }

  void Check() {
    OpenBrowserService* service = Svc();
    content::WebContents* contents =
        service ? service->tab_bridge()->WebContentsForTab(tab_id_) : nullptr;
    if (contents && !contents->IsLoading() &&
        !contents->GetLastCommittedURL().is_empty()) {
      Finish(base::Value(PageState(contents).Set("tab", tab_id_)));
      return;
    }
    if (!service || base::TimeTicks::Now() >= deadline_) {
      Finish(base::unexpected("timeout waiting for tab " + tab_id_));
      return;
    }
    timer_.Start(FROM_HERE, base::Milliseconds(50),
                 base::BindOnce(&LoadWaiter::Check, base::Unretained(this)));
  }

  void Finish(base::expected<base::Value, std::string> result) {
    std::move(reply_).Run(std::move(result));
    delete this;
  }

  ItemID tab_id_;
  base::TimeTicks deadline_;
  Reply reply_;
  base::OneShotTimer timer_;
};

// Key names of docs/automation.md `key` (and DOM KeyboardEvent.key names).
struct KeySpec {
  ui::KeyboardCode code = ui::VKEY_UNKNOWN;
  char16_t character = 0;
};

std::optional<KeySpec> ParseKey(const std::string& raw, bool shift) {
  const std::string key = base::ToLowerASCII(raw);
  struct Named {
    const char* name;
    ui::KeyboardCode code;
    char16_t character;
  };
  static constexpr Named kNamed[] = {
      {"enter", ui::VKEY_RETURN, u'\r'},  {"return", ui::VKEY_RETURN, u'\r'},
      {"escape", ui::VKEY_ESCAPE, 0},     {"esc", ui::VKEY_ESCAPE, 0},
      {"tab", ui::VKEY_TAB, u'\t'},       {"backspace", ui::VKEY_BACK, 0},
      {"delete", ui::VKEY_DELETE, 0},     {"space", ui::VKEY_SPACE, u' '},
      {"arrowup", ui::VKEY_UP, 0},        {"up", ui::VKEY_UP, 0},
      {"arrowdown", ui::VKEY_DOWN, 0},    {"down", ui::VKEY_DOWN, 0},
      {"arrowleft", ui::VKEY_LEFT, 0},    {"left", ui::VKEY_LEFT, 0},
      {"arrowright", ui::VKEY_RIGHT, 0},  {"right", ui::VKEY_RIGHT, 0},
      {"home", ui::VKEY_HOME, 0},         {"end", ui::VKEY_END, 0},
      {"pageup", ui::VKEY_PRIOR, 0},      {"pagedown", ui::VKEY_NEXT, 0},
      {",", ui::VKEY_OEM_COMMA, u','},    {".", ui::VKEY_OEM_PERIOD, u'.'},
      {"/", ui::VKEY_OEM_2, u'/'},        {";", ui::VKEY_OEM_1, u';'},
      {"[", ui::VKEY_OEM_4, u'['},        {"]", ui::VKEY_OEM_6, u']'},
      {"-", ui::VKEY_OEM_MINUS, u'-'},    {"=", ui::VKEY_OEM_PLUS, u'='},
      {"`", ui::VKEY_OEM_3, u'`'},        {"\\", ui::VKEY_OEM_5, u'\\'},
  };
  for (const Named& named : kNamed) {
    if (key == named.name) {
      return KeySpec{named.code, named.character};
    }
  }
  if (key.size() >= 2 && key.size() <= 3 && key[0] == 'f') {
    int n = 0;
    if (base::StringToInt(key.substr(1), &n) && n >= 1 && n <= 12) {
      return KeySpec{static_cast<ui::KeyboardCode>(ui::VKEY_F1 + n - 1), 0};
    }
  }
  if (key.size() == 1) {
    const char c = key[0];
    if (c >= 'a' && c <= 'z') {
      return KeySpec{static_cast<ui::KeyboardCode>(ui::VKEY_A + (c - 'a')),
                     static_cast<char16_t>(shift ? c - 'a' + 'A' : c)};
    }
    if (c >= '0' && c <= '9') {
      return KeySpec{static_cast<ui::KeyboardCode>(ui::VKEY_0 + (c - '0')),
                     static_cast<char16_t>(c)};
    }
  }
  return std::nullopt;
}

// "mod"/"cmd" is the platform's primary modifier (Command on macOS,
// Control elsewhere), so one suite drives every platform.
int ParseModifiers(const base::ListValue* list) {
  int flags = ui::EF_NONE;
  if (!list) {
    return flags;
  }
  for (const base::Value& item : *list) {
    if (!item.is_string()) {
      continue;
    }
    const std::string m = base::ToLowerASCII(item.GetString());
    if (m == "mod" || m == "cmd" || m == "command" || m == "meta") {
#if BUILDFLAG(IS_MAC)
      flags |= ui::EF_COMMAND_DOWN;
#else
      flags |= (m == "meta") ? ui::EF_COMMAND_DOWN : ui::EF_CONTROL_DOWN;
#endif
    } else if (m == "ctrl" || m == "control") {
      flags |= ui::EF_CONTROL_DOWN;
    } else if (m == "alt" || m == "option") {
      flags |= ui::EF_ALT_DOWN;
    } else if (m == "shift") {
      flags |= ui::EF_SHIFT_DOWN;
    }
  }
  return flags;
}

int BlinkModifiers(int ui_flags) {
  int m = blink::WebInputEvent::kNoModifiers;
  if (ui_flags & ui::EF_SHIFT_DOWN) m |= blink::WebInputEvent::kShiftKey;
  if (ui_flags & ui::EF_CONTROL_DOWN) m |= blink::WebInputEvent::kControlKey;
  if (ui_flags & ui::EF_ALT_DOWN) m |= blink::WebInputEvent::kAltKey;
  if (ui_flags & ui::EF_COMMAND_DOWN) m |= blink::WebInputEvent::kMetaKey;
  return m;
}

void ForwardKeyToPage(content::WebContents* contents,
                      const KeySpec& key,
                      int ui_flags) {
  content::RenderWidgetHostView* view = contents->GetRenderWidgetHostView();
  if (!view) {
    return;
  }
  content::RenderWidgetHost* host = view->GetRenderWidgetHost();
  const int modifiers = BlinkModifiers(ui_flags);
  auto make = [&](blink::WebInputEvent::Type type) {
    input::NativeWebKeyboardEvent event(type, modifiers,
                                        ui::EventTimeForNow());
    event.windows_key_code = key.code;
    event.native_key_code = key.code;
    if (key.character) {
      event.text[0] = key.character;
      event.unmodified_text[0] = key.character;
    }
    return event;
  };
  host->ForwardKeyboardEvent(make(blink::WebInputEvent::Type::kRawKeyDown));
  const bool shortcut = ui_flags & (ui::EF_CONTROL_DOWN | ui::EF_COMMAND_DOWN);
  if (key.character && !shortcut) {
    host->ForwardKeyboardEvent(make(blink::WebInputEvent::Type::kChar));
  }
  host->ForwardKeyboardEvent(make(blink::WebInputEvent::Type::kKeyUp));
}

void TypeIntoPage(content::WebContents* contents, const std::u16string& text) {
  content::RenderWidgetHostView* view = contents->GetRenderWidgetHostView();
  if (!view) {
    return;
  }
  contents->Focus();
  content::RenderWidgetHost* host = view->GetRenderWidgetHost();
  for (char16_t c : text) {
    input::NativeWebKeyboardEvent event(blink::WebInputEvent::Type::kChar,
                                        blink::WebInputEvent::kNoModifiers,
                                        ui::EventTimeForNow());
    event.text[0] = c;
    event.unmodified_text[0] = c;
    event.windows_key_code = c;
    host->ForwardKeyboardEvent(event);
  }
}

void ClickAt(content::WebContents* contents, double x, double y) {
  content::RenderWidgetHostView* view = contents->GetRenderWidgetHostView();
  if (!view) {
    return;
  }
  contents->Focus();
  content::RenderWidgetHost* host = view->GetRenderWidgetHost();
  const float fx = static_cast<float>(x);
  const float fy = static_cast<float>(y);

  blink::WebMouseEvent move(blink::WebInputEvent::Type::kMouseMove,
                            blink::WebInputEvent::kNoModifiers,
                            ui::EventTimeForNow());
  move.pointer_type = blink::WebPointerProperties::PointerType::kMouse;
  move.SetPositionInWidget(fx, fy);
  move.SetPositionInScreen(fx, fy);
  host->ForwardMouseEvent(move);

  blink::WebMouseEvent down(blink::WebInputEvent::Type::kMouseDown,
                            blink::WebInputEvent::kLeftButtonDown,
                            ui::EventTimeForNow());
  down.pointer_type = blink::WebPointerProperties::PointerType::kMouse;
  down.button = blink::WebPointerProperties::Button::kLeft;
  down.click_count = 1;
  down.SetPositionInWidget(fx, fy);
  down.SetPositionInScreen(fx, fy);
  host->ForwardMouseEvent(down);

  blink::WebMouseEvent up(blink::WebInputEvent::Type::kMouseUp,
                          blink::WebInputEvent::kNoModifiers,
                          ui::EventTimeForNow());
  up.pointer_type = blink::WebPointerProperties::PointerType::kMouse;
  up.button = blink::WebPointerProperties::Button::kLeft;
  up.click_count = 1;
  up.SetPositionInWidget(fx, fy);
  up.SetPositionInScreen(fx, fy);
  host->ForwardMouseEvent(up);
}

void WritePngAndReply(base::FilePath path,
                      scoped_refptr<base::RefCountedMemory> png,
                      int width,
                      int height,
                      Reply reply) {
  if (!png || png->size() == 0) {
    Err(std::move(reply), "snapshot failed");
    return;
  }
  base::ThreadPool::PostTaskAndReplyWithResult(
      FROM_HERE, {base::MayBlock(), base::TaskPriority::USER_BLOCKING},
      base::BindOnce(
          [](base::FilePath path, scoped_refptr<base::RefCountedMemory> png) {
            base::CreateDirectory(path.DirName());
            return base::WriteFile(path, *png);
          },
          path, png),
      base::BindOnce(
          [](base::FilePath path, size_t size, int width, int height,
             Reply reply, bool written) {
            if (!written) {
              Err(std::move(reply), "cannot write " + path.AsUTF8Unsafe());
              return;
            }
            Ok(std::move(reply), base::DictValue()
                                     .Set("path", path.AsUTF8Unsafe())
                                     .Set("bytes", static_cast<int>(size))
                                     .Set("width", width)
                                     .Set("height", height));
          },
          path, png->size(), width, height, std::move(reply)));
}

base::DictValue AdBlockStateFor(const ProfileID& profile_id) {
  base::DictValue state;
  state.Set("profile", profile_id);
  ProfileServices* ps = Svc()->ProfileServicesFor(profile_id);
  OpenAdBlockProfileService* adblock = ps ? ps->adblock() : nullptr;
  state.Set("available", adblock && adblock->service());
  if (!adblock || !adblock->service()) {
    return state;
  }
  const AdBlockProfileSnapshot snapshot = adblock->GetSnapshot();
  const open_engine::AdBlockStatus& status = snapshot.engine_status;
  base::ListValue lists;
  for (const std::string& id : snapshot.enabled_list_ids) {
    lists.Append(id);
  }
  base::ListValue excluded;
  for (const std::string& domain : snapshot.excluded_domains) {
    excluded.Append(domain);
  }
  state.Set("enabled", snapshot.enabled);
  state.Set("engineLoaded", status.engine_loaded);
  state.Set("awaitingGeneration", status.awaiting_generation);
  state.Set("generation", static_cast<double>(status.generation));
  state.Set("listCount", static_cast<int>(status.list_count));
  state.Set("checks", static_cast<double>(status.checks));
  state.Set("lastError", status.last_error);
  state.Set("lists", std::move(lists));
  state.Set("excluded", std::move(excluded));
  return state;
}

// Creates |path| readable and writable by the current user only, and fails
// rather than following a planted link or reusing another user's file.
bool WriteOwnerOnlyFile(const base::FilePath& path, const std::string& data) {
  base::DeleteFile(path);  // A stale file of an earlier run.
#if BUILDFLAG(IS_WIN)
  PSECURITY_DESCRIPTOR descriptor = nullptr;
  // Protected DACL: full access for the owner (and SYSTEM) only.
  if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(
          L"D:P(A;;FA;;;OW)(A;;FA;;;SY)", SDDL_REVISION_1, &descriptor,
          nullptr)) {
    return false;
  }
  SECURITY_ATTRIBUTES attributes = {};
  attributes.nLength = sizeof(attributes);
  attributes.lpSecurityDescriptor = descriptor;
  attributes.bInheritHandle = FALSE;
  HANDLE file = CreateFileW(path.value().c_str(), GENERIC_WRITE, 0,
                            &attributes, CREATE_NEW,
                            FILE_ATTRIBUTE_NORMAL, nullptr);
  LocalFree(descriptor);
  if (file == INVALID_HANDLE_VALUE) {
    return false;
  }
  DWORD written = 0;
  const bool ok =
      WriteFile(file, data.data(), static_cast<DWORD>(data.size()), &written,
                nullptr) &&
      written == data.size();
  CloseHandle(file);
  return ok;
#else
  const int fd = open(path.value().c_str(),
                      O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                      0600);
  if (fd < 0) {
    return false;
  }
  size_t offset = 0;
  bool ok = true;
  while (offset < data.size()) {
    const ssize_t n = write(fd, data.data() + offset, data.size() - offset);
    if (n < 0 && errno == EINTR) {
      continue;
    }
    if (n <= 0) {
      ok = false;
      break;
    }
    offset += static_cast<size_t>(n);
  }
  ok = (close(fd) == 0) && ok;
  return ok;
#endif
}

base::DictValue SyncStatusValue(const SyncStatusInfo& info) {
  base::DictValue categories;
  for (const auto& [name, enabled] : info.categories) {
    categories.Set(name, enabled);
  }
  base::DictValue d;
  d.Set("signedIn", info.signed_in);
  d.Set("email", info.email);
  d.Set("serverUrl", info.server_url);
  d.Set("state", info.state);
  d.Set("revision", static_cast<double>(info.revision));
  if (info.last_sync_at) {
    d.Set("lastSyncAt", *info.last_sync_at);
  }
  if (info.error_message) {
    d.Set("error", *info.error_message);
  }
  d.Set("categories", std::move(categories));
  return d;
}

}  // namespace

// ===========================================================================
// OpenAutomationServer
// ===========================================================================

// static
std::unique_ptr<OpenAutomationServer>
OpenAutomationServer::CreateFromCommandLine(
    OpenBrowserService* service,
    const base::CommandLine& command_line,
    const base::FilePath& user_data_dir) {
  auto server = std::make_unique<OpenAutomationServer>(service);
  bool any = false;

  base::FilePath socket_path =
      command_line.GetSwitchValuePath(switches::kAutomationSocket);
  if (socket_path.empty()) {
    std::unique_ptr<base::Environment> env = base::Environment::Create();
    if (std::optional<std::string> value =
            env->GetVar(switches::kAutomationSocketEnv);
        value && !value->empty()) {
      socket_path = base::FilePath::FromUTF8Unsafe(*value);
    }
  }
  const bool want_tcp = command_line.HasSwitch(switches::kAutomationPort);
  if (socket_path.empty() && !want_tcp) {
    socket_path = user_data_dir.AppendASCII("automation.sock");
  }
  if (!socket_path.empty()) {
    any |= server->ListenUnix(socket_path);
  }
  if (want_tcp) {
    int port = 0;
    base::StringToInt(
        command_line.GetSwitchValueASCII(switches::kAutomationPort), &port);
    any |= server->ListenTcp(port, user_data_dir) != 0;
  }
  if (!any) {
    LOG(ERROR) << "Open automation: no transport started";
    return nullptr;
  }
  return server;
}

OpenAutomationServer::OpenAutomationServer(OpenBrowserService* service)
    : service_(service) {
  RegisterCommands();
}

OpenAutomationServer::~OpenAutomationServer() {
  // Requests still queued for the UI thread find the server gone and answer
  // "shutting down"; pending waits answer now; transports join their threads
  // (each wakes within one poll interval).
  weak_factory_.InvalidateWeakPtrs();
  LoadWaiter::CancelAll();
  unix_transport_.reset();
  tcp_transport_.reset();
  base::ScopedAllowBlockingForTesting allow_blocking;
  for (const base::FilePath& path : {token_path_, port_path_}) {
    if (!path.empty()) {
      base::DeleteFile(path);
    }
  }
}

bool OpenAutomationServer::ListenUnix(const base::FilePath& path) {
  if (!EnsureSocketsInitialized()) {
    return false;
  }
  const std::string utf8 = path.AsUTF8Unsafe();
  sockaddr_un address = {};
  if (utf8.size() >= sizeof(address.sun_path)) {
    LOG(ERROR) << "Open automation: socket path too long: " << utf8;
    return false;
  }
  base::CreateDirectory(path.DirName());
  base::DeleteFile(path);
  SocketHandle s = socket(AF_UNIX, SOCK_STREAM, 0);
  if (s == kInvalidSocket) {
    return false;
  }
  address.sun_family = AF_UNIX;
#if BUILDFLAG(IS_WIN)
  std::memcpy(address.sun_path, utf8.c_str(), utf8.size() + 1);
  const bool bound =
      bind(s, reinterpret_cast<sockaddr*>(&address), sizeof(address)) == 0 &&
      listen(s, 8) == 0;
#else
  // No process-wide umask change (other threads create files too): the
  // socket is bound inside a fresh 0700 directory next to its final path,
  // made 0600, then renamed into place, so it is never reachable with
  // looser permissions.
  bool bound = false;
  std::string private_dir =
      path.DirName().AppendASCII(".open-automation-XXXXXX").AsUTF8Unsafe();
  if (mkdtemp(private_dir.data())) {
    const std::string staged = private_dir + "/s";
    if (staged.size() < sizeof(address.sun_path)) {
      std::memcpy(address.sun_path, staged.c_str(), staged.size() + 1);
      bound = bind(s, reinterpret_cast<sockaddr*>(&address),
                   sizeof(address)) == 0 &&
              chmod(staged.c_str(), 0600) == 0 && listen(s, 8) == 0 &&
              rename(staged.c_str(), utf8.c_str()) == 0;
      if (!bound) {
        unlink(staged.c_str());
      }
    }
    rmdir(private_dir.c_str());
  }
  if (!bound) {
    // A staging path too long for sun_path: bind in place, then restrict
    // (the data directory itself is private to the user).
    CloseSocket(s);
    s = socket(AF_UNIX, SOCK_STREAM, 0);
    if (s == kInvalidSocket) {
      return false;
    }
    std::memcpy(address.sun_path, utf8.c_str(), utf8.size() + 1);
    bound = bind(s, reinterpret_cast<sockaddr*>(&address), sizeof(address)) ==
                0 &&
            chmod(utf8.c_str(), 0600) == 0 && listen(s, 8) == 0;
  }
#endif
  if (!bound) {
    LOG(ERROR) << "Open automation: cannot listen on " << utf8;
    CloseSocket(s);
    return false;
  }
  unix_transport_ = std::make_unique<Transport>(weak_factory_.GetWeakPtr(), s,
                                                std::string(), path);
  if (!unix_transport_->Start()) {
    unix_transport_.reset();
    return false;
  }
  LOG(WARNING) << "Open automation: listening on " << utf8;
  return true;
}

int OpenAutomationServer::ListenTcp(int port,
                                    const base::FilePath& user_data_dir) {
  if (!EnsureSocketsInitialized() || port < 0 || port > 65535) {
    return 0;
  }
  SocketHandle s = socket(AF_INET, SOCK_STREAM, 0);
  if (s == kInvalidSocket) {
    return 0;
  }
  sockaddr_in address = {};
  address.sin_family = AF_INET;
  address.sin_port = htons(static_cast<uint16_t>(port));
  address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  if (bind(s, reinterpret_cast<sockaddr*>(&address), sizeof(address)) != 0 ||
      listen(s, 8) != 0) {
    LOG(ERROR) << "Open automation: cannot listen on 127.0.0.1:" << port;
    CloseSocket(s);
    return 0;
  }
  sockaddr_in bound = {};
#if BUILDFLAG(IS_WIN)
  int length = sizeof(bound);
#else
  socklen_t length = sizeof(bound);
#endif
  getsockname(s, reinterpret_cast<sockaddr*>(&bound), &length);
  const int bound_port = ntohs(bound.sin_port);

  // Token and port files: the harness reads both from the data root. The
  // token file is created owner-only from the first byte (never written
  // then chmod-ed) and removed when the server stops.
  const std::string token = base::HexEncode(base::RandBytesAsVector(16));
  const base::FilePath token_path =
      user_data_dir.AppendASCII("automation.token");
  base::CreateDirectory(user_data_dir);
  if (!WriteOwnerOnlyFile(token_path, token)) {
    LOG(ERROR) << "Open automation: cannot create "
               << token_path.AsUTF8Unsafe();
    CloseSocket(s);
    return 0;
  }
  token_path_ = token_path;
  port_path_ = user_data_dir.AppendASCII("automation.port");
  base::WriteFile(port_path_, base::NumberToString(bound_port));

  tcp_transport_ = std::make_unique<Transport>(weak_factory_.GetWeakPtr(), s,
                                               token, base::FilePath());
  if (!tcp_transport_->Start()) {
    tcp_transport_.reset();
    return 0;
  }
  LOG(WARNING) << "Open automation: listening on 127.0.0.1:" << bound_port;
  return bound_port;
}

void OpenAutomationServer::Add(const std::string& name, Handler handler) {
  handlers_[name] = std::move(handler);
}

void OpenAutomationServer::Dispatch(const std::string& cmd,
                                    base::DictValue args,
                                    Reply reply) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  auto it = handlers_.find(cmd);
  if (it == handlers_.end()) {
    Err(std::move(reply), "unknown command " + cmd);
    return;
  }
  if (!OpenBrowserService::Get() || !OpenBrowserService::Get()->tab_bridge()) {
    Err(std::move(reply), "browser not ready");
    return;
  }
  it->second.Run(args, std::move(reply));
}

// ===========================================================================
// Commands (docs/automation.md names and fields where they exist).
// ===========================================================================

void OpenAutomationServer::RegisterCommands() {
  // --- Process ---------------------------------------------------------------
  Add("ping", base::BindRepeating([](const base::DictValue&, Reply reply) {
        OpenBrowserService* service = Svc();
        Ok(std::move(reply),
           base::DictValue()
               .Set("pid", static_cast<int>(base::GetCurrentProcId()))
               .Set("chromium", version_info::GetVersionNumber())
               .Set("engine", "chromium-views")
               .Set("cef", base::Value())
               .Set("dataRoot", service->user_data_dir().AsUTF8Unsafe())
               .Set("firstRun", service->is_first_run())
#if BUILDFLAG(IS_WIN)
               .Set("platform", "windows")
#elif BUILDFLAG(IS_MAC)
               .Set("platform", "macos")
#else
               .Set("platform", "linux")
#endif
        );
      }));

  Add("quit", base::BindRepeating([](const base::DictValue&, Reply reply) {
        Ok(std::move(reply), base::DictValue().Set("quitting", true));
        // After the reply is queued: the connection thread writes it before
        // the browser tears the server down.
        content::GetUIThreadTaskRunner({})->PostDelayedTask(
            FROM_HERE, base::BindOnce(&chrome::AttemptExit),
            base::Milliseconds(100));
      }));

  // --- Tabs ------------------------------------------------------------------
  Add("tabs", base::BindRepeating([](const base::DictValue& args,
                                     Reply reply) {
        OpenBrowserService* service = Svc();
        const BrowserModel& model = service->model();
        const BrowserWindowState* window =
            model.FindWindow(service->MainWindowId());
        base::ListValue tabs;
        if (window) {
          for (const ItemID& id :
               model_util::OrderedTabIds(model, window->focused_space_id)) {
            tabs.Append(TabRow(id));
          }
        }
        if (!args.FindBool("sidebar").value_or(false) || !window) {
          Ok(std::move(reply), base::Value(std::move(tabs)));
          return;
        }
        base::DictValue result;
        const Space* space = model.FindSpace(window->focused_space_id);
        base::ListValue favorites, pinned, today;
        if (const Profile* profile =
                space ? model.FindProfile(space->profile_id) : nullptr) {
          for (const Tab& tab : profile->favorites) {
            favorites.Append(json::TabToValue(tab));
          }
        }
        if (space) {
          for (const SidebarNode& node : space->pinned) {
            pinned.Append(json::SidebarNodeToValue(node));
          }
          for (const SidebarNode& node : space->today) {
            today.Append(json::SidebarNodeToValue(node));
          }
        }
        auto selected =
            window->selected_node_by_space.find(window->focused_space_id);
        result.Set("tabs", std::move(tabs));
        result.Set("rows", base::DictValue()
                               .Set("favorites", std::move(favorites))
                               .Set("pinned", std::move(pinned))
                               .Set("today", std::move(today)));
        result.Set("selectedNode",
                   selected == window->selected_node_by_space.end()
                       ? base::Value()
                       : base::Value(selected->second));
        Ok(std::move(reply), std::move(result));
      }));

  Add("tab-state", base::BindRepeating([](const base::DictValue& args,
                                          Reply reply) {
        std::string error;
        std::optional<ItemID> id = ResolveTab(args, &error);
        if (!id) {
          Err(std::move(reply), error);
          return;
        }
        OpenBrowserService* service = Svc();
        base::DictValue state = TabRow(*id);
        if (const Tab* tab = service->model().FindTab(*id)) {
          state.Set("model", json::TabToValue(*tab));
        }
        if (std::optional<SpaceID> space =
                model_util::SpaceOfNode(service->model(), *id)) {
          state.Set("space", *space);
        }
        state.Set("sleep", service->sleep_controller()->StateFor(*id));
        Ok(std::move(reply), std::move(state));
      }));

  Add("open", base::BindRepeating([](const base::DictValue& args,
                                     Reply reply) {
        const GURL url(json::GetString(args, "url", "about:blank"));
        if (!url.is_valid()) {
          Err(std::move(reply), "bad url");
          return;
        }
        const ItemID id = Svc()->tab_bridge()->OpenTab(
            url, args.FindBool("background").value_or(false));
        if (id.empty()) {
          Err(std::move(reply), "cannot open tab");
          return;
        }
        Ok(std::move(reply), TabRow(id));
      }));

  Add("select", base::BindRepeating([](const base::DictValue& args,
                                       Reply reply) {
        std::string error;
        std::optional<ItemID> id = ResolveTab(args, &error);
        if (!id || !Svc()->tab_bridge()->SelectNode(*id)) {
          Err(std::move(reply), id ? "cannot select " + *id : error);
          return;
        }
        Ok(std::move(reply), TabRow(*id));
      }));

  Add("close", base::BindRepeating([](const base::DictValue& args,
                                      Reply reply) {
        std::string error;
        std::optional<ItemID> id = ResolveTab(args, &error);
        if (!id || !Svc()->tab_bridge()->CloseNode(*id)) {
          Err(std::move(reply), id ? "cannot close " + *id : error);
          return;
        }
        Ok(std::move(reply),
           base::DictValue()
               .Set("closed", *id)
               .Set("stillInSidebar", Svc()->model().FindNode(*id) != nullptr));
      }));

  Add("pin", base::BindRepeating([](const base::DictValue& args,
                                    Reply reply) {
        std::string error;
        std::optional<ItemID> id = ResolveTab(args, &error);
        if (!id || !Svc()->tab_bridge()->TogglePin(*id)) {
          Err(std::move(reply), id ? "cannot pin " + *id : error);
          return;
        }
        Ok(std::move(reply), TabRow(*id));
      }));

  Add("favorite", base::BindRepeating([](const base::DictValue& args,
                                         Reply reply) {
        std::string error;
        std::optional<ItemID> id = ResolveTab(args, &error);
        std::optional<ProfileID> profile =
            id ? model_util::ProfileOfNode(Svc()->model(), *id) : std::nullopt;
        if (!id || !profile || !Svc()->model().AddFavorite(*id, *profile)) {
          Err(std::move(reply), id ? "cannot favorite " + *id : error);
          return;
        }
        Ok(std::move(reply), TabRow(*id));
      }));

  Add("folder", base::BindRepeating([](const base::DictValue& args,
                                       Reply reply) {
        OpenBrowserService* service = Svc();
        const BrowserWindowState* window =
            service->model().FindWindow(service->MainWindowId());
        const base::ListValue* tabs = args.FindList("tabs");
        if (!window || !tabs) {
          Err(std::move(reply), "folder needs tabs");
          return;
        }
        std::vector<ItemID> children;
        for (const base::Value& tab : *tabs) {
          if (tab.is_string()) {
            children.push_back(tab.GetString());
          }
        }
        const bool pinned =
            json::GetString(args, "section", "today") == "pinned";
        const ItemID folder = service->model().CreateFolder(
            NodeParent{pinned ? NodeParentKind::kSpacePinned
                              : NodeParentKind::kSpaceToday,
                       window->focused_space_id},
            json::GetString(args, "title", "New Folder"),
            static_cast<size_t>(std::max(0, json::GetInt(args, "at", 0))),
            children);
        if (folder.empty()) {
          Err(std::move(reply), "cannot create folder");
          return;
        }
        Ok(std::move(reply), base::DictValue().Set("folder", folder));
      }));

  Add("split", base::BindRepeating([](const base::DictValue& args,
                                      Reply reply) {
        std::string error;
        std::optional<ItemID> id = ResolveTab(args, &error);
        if (!id) {
          Err(std::move(reply), error);
          return;
        }
        std::optional<ItemID> split = Svc()->tab_bridge()->ToggleSplit(*id);
        base::DictValue result;
        result.Set("split", split ? base::Value(*split) : base::Value());
        if (split) {
          if (const SidebarNode* node = Svc()->model().FindNode(*split)) {
            result.Set("node", json::SidebarNodeToValue(*node));
          }
        }
        Ok(std::move(reply), std::move(result));
      }));

  Add("navigate", base::BindRepeating([](const base::DictValue& args,
                                         Reply reply) {
        std::string error;
        std::optional<ItemID> id = ResolveTab(args, &error);
        const GURL url(json::GetString(args, "url"));
        if (!id || !Svc()->tab_bridge()->Navigate(*id, url)) {
          Err(std::move(reply), id ? "cannot navigate" : error);
          return;
        }
        Ok(std::move(reply), TabRow(*id));
      }));

  Add("back", base::BindRepeating([](const base::DictValue& args,
                                     Reply reply) {
        std::string error;
        std::optional<ItemID> id = ResolveTab(args, &error);
        if (!id || !Svc()->tab_bridge()->GoBack(*id)) {
          Err(std::move(reply), id ? "cannot go back" : error);
          return;
        }
        Ok(std::move(reply), TabRow(*id));
      }));

  Add("wait", base::BindRepeating([](const base::DictValue& args,
                                     Reply reply) {
        std::string error;
        std::optional<ItemID> id = ResolveTab(args, &error);
        if (!id) {
          Err(std::move(reply), error);
          return;
        }
        Svc()->tab_bridge()->EnsureLoaded(*id);
        const double timeout = json::GetDouble(args, "timeout", 30.0);
        LoadWaiter::Start(*id,
                          base::Seconds(std::clamp(timeout, 0.05, 600.0)),
                          std::move(reply));
      }));

  // --- Page scripting and input ----------------------------------------------
  Add("eval", base::BindRepeating([](const base::DictValue& args,
                                     Reply reply) {
        std::string error;
        content::WebContents* contents = ResolveContents(args, &error);
        if (!contents) {
          Err(std::move(reply), error);
          return;
        }
        const std::string world = json::GetString(args, "world", "page");
        const int32_t world_id =
            world == "open" ? static_cast<int32_t>(ISOLATED_WORLD_ID_OPEN)
                            : static_cast<int32_t>(
                                  content::ISOLATED_WORLD_ID_GLOBAL);
        // Test-build only (open_enable_automation): runs in any world of any
        // page and awaits promises.
        contents->GetPrimaryMainFrame()->ExecuteJavaScriptForTests(
            base::UTF8ToUTF16(json::GetString(args, "js")),
            base::BindOnce(
                [](Reply reply, base::Value value) {
                  Ok(std::move(reply), std::move(value));
                },
                std::move(reply)),
            world_id);
      }));

  Add("click", base::BindRepeating([](const base::DictValue& args,
                                      Reply reply) {
        std::string error;
        content::WebContents* contents = ResolveContents(args, &error);
        if (!contents) {
          Err(std::move(reply), error);
          return;
        }
        // Find the element, scroll it into view, return its center; then a
        // real mouse down/up goes through the RenderWidgetHost (a user
        // gesture inside the page).
        base::DictValue query;
        query.Set("selector", json::GetString(args, "selector"));
        query.Set("text", json::GetString(args, "text"));
        std::string query_json;
        base::JSONWriter::Write(query, &query_json);
        const std::string script =
            "(() => { const q = " + query_json +
            "; let el = q.selector ? document.querySelector(q.selector) : null;"
            " if (!el && q.text) { const all = document.querySelectorAll("
            "'a,button,input,[role=button],[onclick],label,span,div');"
            " for (const c of all) { if ((c.innerText || c.value || '').trim()"
            " === q.text) { el = c; break; } } }"
            " if (!el) return null; el.scrollIntoView({block: 'center'});"
            " const r = el.getBoundingClientRect();"
            " return {x: r.left + r.width / 2, y: r.top + r.height / 2}; })()";
        contents->GetPrimaryMainFrame()->ExecuteJavaScriptForTests(
            base::UTF8ToUTF16(script),
            base::BindOnce(
                [](base::WeakPtr<content::WebContents> contents, Reply reply,
                   base::Value point) {
                  if (!contents || !point.is_dict()) {
                    Err(std::move(reply), "no element");
                    return;
                  }
                  const double x = point.GetDict().FindDouble("x").value_or(0);
                  const double y = point.GetDict().FindDouble("y").value_or(0);
                  ClickAt(contents.get(), x, y);
                  Ok(std::move(reply),
                     base::DictValue().Set("x", x).Set("y", y));
                },
                contents->GetWeakPtr(), std::move(reply)),
            content::ISOLATED_WORLD_ID_GLOBAL);
      }));

  Add("type", base::BindRepeating([](const base::DictValue& args,
                                     Reply reply) {
        const std::u16string text =
            base::UTF8ToUTF16(json::GetString(args, "text"));
        BrowserView* browser_view = MainBrowserView();
        OpenWindowUi* ui = MainUi();
        if (browser_view && ui && ui->command_bar_shown()) {
          ui->TypeInCommandBar(text);
          Ok(std::move(reply), base::DictValue().Set("target", "commandBar"));
          return;
        }
        std::string error;
        content::WebContents* contents = ResolveContents(args, &error);
        if (!contents) {
          Err(std::move(reply), error);
          return;
        }
        TypeIntoPage(contents, text);
        Ok(std::move(reply), base::DictValue().Set("target", "page"));
      }));

  Add("key", base::BindRepeating([](const base::DictValue& args,
                                    Reply reply) {
        const int flags = ParseModifiers(args.FindList("modifiers"));
        std::optional<KeySpec> key = ParseKey(json::GetString(args, "key"),
                                              flags & ui::EF_SHIFT_DOWN);
        if (!key) {
          Err(std::move(reply), "unknown key");
          return;
        }
        const std::string route = json::GetString(args, "route", "app");
        BrowserView* browser_view = MainBrowserView();
        if (route == "app" && browser_view) {
          // Real accelerator path: Open's and Chromium's shortcuts are
          // registered with the window's FocusManager.
          views::FocusManager* focus = browser_view->GetFocusManager();
          if (focus && focus->ProcessAccelerator(ui::Accelerator(key->code,
                                                                 flags))) {
            Ok(std::move(reply), base::DictValue().Set("handled",
                                                          "accelerator"));
            return;
          }
          if (OpenWindowUi* ui = MainUi(); ui && ui->command_bar_shown()) {
            // The bar lives in its own child widget (focus is in its field).
            views::Widget* target = ui->command_bar_widget()
                                        ? ui->command_bar_widget()
                                        : browser_view->GetWidget();
            ui::KeyEvent press(ui::EventType::kKeyPressed, key->code, flags);
            target->OnKeyEvent(&press);
            ui::KeyEvent release(ui::EventType::kKeyReleased, key->code, flags);
            target->OnKeyEvent(&release);
            Ok(std::move(reply), base::DictValue().Set("handled",
                                                          "commandBar"));
            return;
          }
        }
        std::string error;
        content::WebContents* contents = ResolveContents(args, &error);
        if (!contents) {
          Err(std::move(reply), error);
          return;
        }
        ForwardKeyToPage(contents, *key, flags);
        Ok(std::move(reply), base::DictValue().Set("handled", "page"));
      }));

  // --- Window pixels ---------------------------------------------------------
  Add("snapshot", base::BindRepeating([](const base::DictValue& args,
                                         Reply reply) {
        OpenBrowserService* service = Svc();
        base::FilePath path = base::FilePath::FromUTF8Unsafe(
            json::GetString(args, "path"));
        if (path.empty()) {
          path = service->user_data_dir()
                     .AppendASCII("snapshots")
                     .AppendASCII(base::NumberToString(
                                      base::Time::Now()
                                          .InMillisecondsSinceUnixEpoch()) +
                                  ".png");
        }
        if (args.Find("tab")) {
          std::string error;
          content::WebContents* contents = ResolveContents(args, &error);
          if (!contents) {
            Err(std::move(reply), error);
            return;
          }
          const gfx::Rect bounds(contents->GetContainerBounds().size());
          ui::GrabViewSnapshot(
              contents->GetNativeView(), bounds,
              base::BindOnce(
                  [](base::FilePath path, Reply reply, gfx::Image image) {
                    scoped_refptr<base::RefCountedMemory> png =
                        image.IsEmpty() ? nullptr : image.As1xPNGBytes();
                    WritePngAndReply(path, png, image.Width(), image.Height(),
                                     std::move(reply));
                  },
                  path, std::move(reply)));
          return;
        }
        BrowserView* browser_view = MainBrowserView();
        views::Widget* widget =
            browser_view ? browser_view->GetWidget() : nullptr;
        if (!widget) {
          Err(std::move(reply), "no window");
          return;
        }
        const gfx::Rect bounds(widget->GetWindowBoundsInScreen().size());
        ui::GrabWindowSnapshotAsPNG(
            widget->GetNativeWindow(), bounds,
            base::BindOnce(
                [](base::FilePath path, int width, int height, Reply reply,
                   scoped_refptr<base::RefCountedMemory> png) {
                  WritePngAndReply(path, png, width, height, std::move(reply));
                },
                path, bounds.width(), bounds.height(), std::move(reply)));
      }));

  // --- Spaces ----------------------------------------------------------------
  Add("spaces", base::BindRepeating([](const base::DictValue&, Reply reply) {
        OpenBrowserService* service = Svc();
        const BrowserModel& model = service->model();
        const BrowserWindowState* window =
            model.FindWindow(service->MainWindowId());
        base::ListValue spaces;
        for (const Space& space : model.spaces()) {
          const Profile* profile = model.FindProfile(space.profile_id);
          base::DictValue row;
          row.Set("id", space.id);
          row.Set("title", space.title.value_or(std::string()));
          row.Set("profile", space.profile_id);
          row.Set("profileName", profile ? profile->name : std::string());
          row.Set("focused", window && window->focused_space_id == space.id);
          row.Set("pinned", static_cast<int>(space.pinned.size()));
          row.Set("today", static_cast<int>(space.today.size()));
          row.Set("theme", json::SpaceThemeToValue(space.theme));
          spaces.Append(std::move(row));
        }
        Ok(std::move(reply), base::Value(std::move(spaces)));
      }));

  Add("space", base::BindRepeating([](const base::DictValue& args,
                                      Reply reply) {
        OpenBrowserService* service = Svc();
        std::string target = json::GetString(args, "space");
        // Accept a Space id or title.
        if (!service->model().FindSpace(target)) {
          for (const Space& space : service->model().spaces()) {
            if (space.title == target) {
              target = space.id;
              break;
            }
          }
        }
        if (!service->tab_bridge()->FocusSpace(target)) {
          Err(std::move(reply), "no space " + target);
          return;
        }
        Ok(std::move(reply), base::DictValue().Set("focused", target));
      }));

  Add("space-create", base::BindRepeating([](const base::DictValue& args,
                                             Reply reply) {
        OpenBrowserService* service = Svc();
        const std::string title = json::GetString(args, "title", "Space");
        const std::string profile_name = json::GetString(args, "profile");
        auto create = [](std::string title, Reply reply, ProfileID profile) {
          OpenBrowserService* service = Svc();
          if (!service) {
            Err(std::move(reply), "shutting down");
            return;
          }
          if (profile.empty()) {
            Err(std::move(reply), "cannot create the profile");
            return;
          }
          const SpaceID id = service->model().CreateSpace(profile, title);
          Ok(std::move(reply),
             base::DictValue().Set("id", id).Set("profile", profile));
        };
        if (profile_name.empty()) {
          create(title, std::move(reply), service->ActiveProfileId());
          return;
        }
        for (const Profile& profile : service->model().profiles()) {
          if (profile.name == profile_name || profile.id == profile_name) {
            create(title, std::move(reply), profile.id);
            return;
          }
        }
        // A new Profile name creates an Open Profile with its own Chromium
        // Profile directory.
        service->CreateProfile(
            profile_name, std::nullopt,
            base::BindOnce(create, title, std::move(reply)));
      }));

  Add("space-theme", base::BindRepeating([](const base::DictValue& args,
                                            Reply reply) {
        OpenBrowserService* service = Svc();
        const std::string space_id = json::GetString(args, "space");
        std::optional<SpaceStyle> style =
            json::SpaceStyleFromValue(args.Find("style"));
        const Space* current = service->model().FindSpace(space_id);
        if (!style || !current) {
          Err(std::move(reply), "cannot update space theme");
          return;
        }
        SpaceTheme theme = current->theme;
        theme.style = *style;
        if (!service->model().UpdateSpace(space_id, std::nullopt, std::nullopt,
                                          theme)) {
          Err(std::move(reply), "cannot update space theme");
          return;
        }
        const Space* space = service->model().FindSpace(space_id);
        Ok(std::move(reply), json::SpaceThemeToValue(space->theme));
      }));

  // --- Views (Tracks 4 and 5) ------------------------------------------------
  Add("command-bar", base::BindRepeating([](const base::DictValue& args,
                                            Reply reply) {
        OpenWindowUi* ui = MainUi();
        if (!ui) {
          Err(std::move(reply), "no window");
          return;
        }
        const std::string action = json::GetString(args, "action", "state");
        if (action == "open") {
          const bool edit = json::GetString(args, "mode") == "edit";
          ui->ShowCommandBar(edit ? CommandBarMode::kEditCurrentUrl
                                  : CommandBarMode::kNewTab,
                             base::UTF8ToUTF16(json::GetString(args, "text")),
                             std::nullopt);
        } else if (action == "close") {
          ui->HideCommandBar();
        } else if (action == "enter") {
          ui->CommitCommandBar();
        } else if (action != "state") {
          Err(std::move(reply), "unknown action " + action);
          return;
        }
        Ok(std::move(reply), ui->CommandBarState());
      }));

  auto peek = [](std::string op) {
    return base::BindRepeating(
        [](std::string op, const base::DictValue& args, Reply reply) {
          OpenWindowUi* ui = MainUi();
          if (!ui) {
            Err(std::move(reply), "no window");
            return;
          }
          if (op == "open") {
            const GURL url(json::GetString(args, "url"));
            if (!url.is_valid()) {
              Err(std::move(reply), "bad url");
              return;
            }
            ui->OpenPeek(url, Svc()->tab_bridge()->ActiveTabId());
          } else if (op == "expand") {
            ui->ExpandPeek();
          } else if (op == "close") {
            ui->ClosePeek();
          }
          Ok(std::move(reply), ui->PeekState());
        },
        std::move(op));
  };
  Add("peek-open", peek("open"));
  Add("peek-expand", peek("expand"));
  Add("peek-close", peek("close"));
  Add("peek-state", peek("state"));

  Add("site-controls", base::BindRepeating([](const base::DictValue& args,
                                              Reply reply) {
        OpenWindowUi* ui = MainUi();
        if (!ui) {
          Err(std::move(reply), "no window");
          return;
        }
        const std::string action = json::GetString(args, "action", "state");
        if (action == "open") {
          ui->ShowSiteControls(nullptr);
        } else if (action == "close") {
          ui->HideSiteControls();
        } else if (action != "state") {
          Err(std::move(reply), "unknown action " + action);
          return;
        }
        Ok(std::move(reply), ui->SiteControlState());
      }));

  Add("find-bar", base::BindRepeating([](const base::DictValue& args,
                                         Reply reply) {
        OpenWindowUi* ui = MainUi();
        if (!ui) {
          Err(std::move(reply), "no window");
          return;
        }
        const std::string action = json::GetString(args, "action", "state");
        if (action == "open") {
          std::optional<std::u16string> text;
          if (const std::string* value = args.FindString("text")) {
            text = base::UTF8ToUTF16(*value);
          }
          ui->ShowFindBar(std::move(text));
        } else if (action == "next" || action == "previous") {
          ui->FindNext(action == "next");
        } else if (action == "close") {
          ui->CloseFindBar();
        } else if (action != "state") {
          Err(std::move(reply), "unknown action " + action);
          return;
        }
        Ok(std::move(reply), ui->FindBarState());
      }));

  Add("toasts", base::BindRepeating([](const base::DictValue& args,
                                       Reply reply) {
        OpenWindowUi* ui = MainUi();
        if (!ui) {
          Err(std::move(reply), "no window");
          return;
        }
        const std::string action = json::GetString(args, "action", "state");
        if (action == "copied-url") {
          ui->ShowToast(ToastSpec::CopiedUrl());
        } else if (action != "state") {
          Err(std::move(reply), "unknown action " + action);
          return;
        }
        Ok(std::move(reply), ui->ToastState());
      }));

  Add("tab-switcher", base::BindRepeating([](const base::DictValue& args,
                                             Reply reply) {
        OpenWindowUi* ui = MainUi();
        if (!ui) {
          Err(std::move(reply), "no window");
          return;
        }
        const std::string action = json::GetString(args, "action", "state");
        if (action == "forward" || action == "backward") {
          ui->TabSwitcherStep(action == "backward");
        } else if (action == "commit") {
          ui->TabSwitcherCommit();
        } else if (action == "cancel") {
          ui->TabSwitcherCancel();
        } else if (action != "state") {
          Err(std::move(reply), "unknown action " + action);
          return;
        }
        Ok(std::move(reply), ui->TabSwitcherState());
      }));

  // Little Open: open [url], route (Air Traffic Control), open-in-space
  // [space_id], close, state. Acts on the newest Little Open window.
  Add("little-open", base::BindRepeating([](const base::DictValue& args,
                                            Reply reply) {
        OpenWindowController* windows = Svc()->window_controller();
        const std::string action = json::GetString(args, "action", "state");
        auto newest = [windows]() -> OpenLittleOpenController* {
          for (auto it = windows->little_opens().rbegin();
               it != windows->little_opens().rend(); ++it) {
            if (!(*it)->State().FindBool("closing").value_or(false)) {
              return it->get();
            }
          }
          return nullptr;
        };
        if (action == "open") {
          std::optional<GURL> url;
          if (const std::string* value = args.FindString("url")) {
            url = GURL(*value);
            if (!url->is_valid()) {
              Err(std::move(reply), "bad url");
              return;
            }
          }
          if (!windows->OpenLittleOpen(url)) {
            Err(std::move(reply), "cannot open Little Open");
            return;
          }
        } else if (action == "route") {
          const GURL url(json::GetString(args, "url"));
          if (!url.is_valid()) {
            Err(std::move(reply), "bad url");
            return;
          }
          std::optional<std::string> source;
          if (const std::string* value = args.FindString("source_app_id")) {
            source = *value;
          }
          windows->RouteExternalUrl(url, std::move(source));
        } else if (action == "open-in-space" || action == "close") {
          OpenLittleOpenController* little_open = newest();
          if (!little_open) {
            Err(std::move(reply), "no Little Open window");
            return;
          }
          if (action == "close") {
            little_open->Close();
          } else {
            std::optional<SpaceID> space;
            if (const std::string* value = args.FindString("space_id")) {
              space = *value;
            }
            little_open->OnLittleOpenOpenInSpace(std::move(space));
          }
        } else if (action != "state") {
          Err(std::move(reply), "unknown action " + action);
          return;
        }
        base::ListValue list;
        for (const auto& little_open : windows->little_opens()) {
          list.Append(little_open->State());
        }
        Ok(std::move(reply), base::DictValue().Set("windows", std::move(list)));
      }));

  // --- Extensions ------------------------------------------------------------
  Add("extensions", base::BindRepeating([](const base::DictValue&,
                                           Reply reply) {
        OpenExtensionBridge* bridge = Svc()->extension_bridge();
        base::ListValue installed, actions;
        if (bridge) {
          for (const auto& info : bridge->ListInstalled()) {
            installed.Append(OpenExtensionBridge::ToValue(info));
          }
          for (const auto& info : bridge->ListActions()) {
            actions.Append(OpenExtensionBridge::ToValue(info));
          }
        }
        Ok(std::move(reply), base::DictValue()
                                 .Set("installed", std::move(installed))
                                 .Set("actions", std::move(actions)));
      }));

  Add("popup", base::BindRepeating([](const base::DictValue& args,
                                      Reply reply) {
        OpenExtensionBridge* bridge = Svc()->extension_bridge();
        if (!bridge) {
          Err(std::move(reply), "no extension bridge");
          return;
        }
        bridge->ExecuteAction(
            json::GetString(args, "extension"), nullptr,
            base::BindOnce(
                [](Reply reply, bool shown) {
                  Ok(std::move(reply), base::DictValue().Set("shown", shown));
                },
                std::move(reply)));
      }));

  Add("extension-pin", base::BindRepeating([](const base::DictValue& args,
                                              Reply reply) {
        OpenExtensionBridge* bridge = Svc()->extension_bridge();
        const bool ok =
            bridge && bridge->SetPinned(json::GetString(args, "extension"),
                                        json::GetBool(args, "pinned", true));
        if (!ok) {
          Err(std::move(reply), "cannot pin extension");
          return;
        }
        Ok(std::move(reply), base::DictValue().Set("ok", true));
      }));

  // --- Tab sleep -------------------------------------------------------------
  Add("engine-sleep", base::BindRepeating([](const base::DictValue& args,
                                             Reply reply) {
        std::string error;
        std::optional<ItemID> id = ResolveTab(args, &error);
        if (!id) {
          Err(std::move(reply), error);
          return;
        }
        OpenSleepController* sleep = Svc()->sleep_controller();
        const std::string op = json::GetString(args, "op", "state");
        if (op == "state") {
          Ok(std::move(reply), sleep->StateFor(*id));
        } else if (op == "hide") {
          Ok(std::move(reply), sleep->Hide(*id));
        } else if (op == "show") {
          Ok(std::move(reply), sleep->Show(*id));
        } else if (op == "freeze") {
          Ok(std::move(reply), sleep->Freeze(*id));
        } else if (op == "unfreeze") {
          Ok(std::move(reply), sleep->Unfreeze(*id));
        } else if (op == "capture") {
          Ok(std::move(reply), sleep->Capture(*id));
        } else if (op == "discard") {
          sleep->Discard(*id, base::BindOnce(
                                  [](Reply reply, base::DictValue state) {
                                    Ok(std::move(reply), std::move(state));
                                  },
                                  std::move(reply)));
        } else if (op == "unload") {
          Svc()->tab_bridge()->UnloadTab(*id);
          Ok(std::move(reply), sleep->StateFor(*id));
        } else {
          Err(std::move(reply), "unknown op " + op);
        }
      }));

  // --- Ad blocking -----------------------------------------------------------
  Add("settings-adblock", base::BindRepeating([](const base::DictValue& args,
                                                 Reply reply) {
        OpenBrowserService* service = Svc();
        const ProfileID profile_id =
            json::GetString(args, "profile", service->ActiveProfileId());
        ProfileServices* ps = service->ProfileServicesFor(profile_id);
        OpenAdBlockProfileService* adblock = ps ? ps->adblock() : nullptr;
        if (!adblock) {
          Err(std::move(reply), "ad blocking unavailable for this profile");
          return;
        }
        if (std::optional<bool> enabled = args.FindBool("enabled")) {
          adblock->SetEnabled(*enabled);
        }
        if (const std::string* list = args.FindString("list")) {
          adblock->SetListEnabled(*list,
                                  json::GetBool(args, "listEnabled", true));
        }
        if (const std::string* host = args.FindString("host")) {
          if (json::GetBool(args, "excluded", true)) {
            adblock->AddExcludedDomain(*host);
          } else {
            adblock->RemoveExcludedDomain(*host);
          }
        }
        Ok(std::move(reply), AdBlockStateFor(profile_id));
      }));

  // Publishes a list generation (filter text compiled by the real Rust
  // engine) and replies when the engine has loaded it. E2E fixtures use it
  // instead of downloading public lists.
  Add("adblock-publish", base::BindRepeating([](const base::DictValue& args,
                                                Reply reply) {
        OpenBrowserService* service = Svc();
        const ProfileID profile_id =
            json::GetString(args, "profile", service->ActiveProfileId());
        ProfileServices* ps = service->ProfileServicesFor(profile_id);
        OpenAdBlockProfileService* adblock = ps ? ps->adblock() : nullptr;
        const base::ListValue* lists = args.FindList("lists");
        if (!adblock || !lists) {
          Err(std::move(reply), "adblock-publish needs lists and a profile");
          return;
        }
        std::vector<std::pair<std::string, std::string>> pairs;
        std::vector<std::string> ids;
        for (const base::Value& item : *lists) {
          if (!item.is_dict()) {
            continue;
          }
          const std::string id = json::GetString(item.GetDict(), "id");
          const std::string text = json::GetString(item.GetDict(), "text");
          if (!id.empty() && !text.empty()) {
            pairs.emplace_back(id, text);
            ids.push_back(id);
          }
        }
        bool published = false;
        {
          // Automation builds only: OpenAdBlockProfileService writes the
          // generation files synchronously.
          base::ScopedAllowBlockingForTesting allow_blocking;
          adblock->SetEnabledListIds(ids);
          published = adblock->PublishGeneration(pairs);
        }
        if (!published) {
          Err(std::move(reply), "the list generation was not published");
          return;
        }
        adblock->ReloadLists(base::BindOnce(
            [](ProfileID profile_id, Reply reply,
               open_engine::AdBlockLoadResult result) {
              base::DictValue state = AdBlockStateFor(profile_id);
              state.Set("loadResult", static_cast<int>(result));
              Ok(std::move(reply), std::move(state));
            },
            profile_id, std::move(reply)));
      }));

  Add("adblock-stats", base::BindRepeating([](const base::DictValue& args,
                                              Reply reply) {
        std::string error;
        std::optional<ItemID> id = ResolveTab(args, &error);
        content::WebContents* contents =
            id ? Svc()->tab_bridge()->WebContentsForTab(*id) : nullptr;
        if (!contents) {
          Err(std::move(reply), id ? "tab not loaded" : error);
          return;
        }
        Ok(std::move(reply),
           base::DictValue()
               .Set("tab", *id)
               .Set("blocked",
                    OpenAdBlockProfileService::GetBlockedCount(contents))
               .Set("redirected",
                    OpenAdBlockProfileService::GetRedirectedCount(contents))
               .Set("total",
                    OpenAdBlockProfileService::GetTotalStoppedCount(contents)));
      }));

  // --- Boosts ----------------------------------------------------------------
  Add("boosts-state", base::BindRepeating([](const base::DictValue&,
                                             Reply reply) {
        Ok(std::move(reply),
           Svc()->boost_controller()->StateForAutomation());
      }));

  // --- Library ---------------------------------------------------------------
  Add("archive", base::BindRepeating([](const base::DictValue& args,
                                        Reply reply) {
        OpenBrowserService* service = Svc();
        ProfileServices* ps = service->ProfileServicesFor(
            json::GetString(args, "profile", service->ActiveProfileId()));
        if (!ps) {
          Err(std::move(reply), "no profile");
          return;
        }
        RunOnStore(
            ps->archive,
            base::BindOnce(
                [](std::string query, int limit, ArchiveStore* store) {
                  return store->List(limit, 0, query);
                },
                json::GetString(args, "query"),
                std::clamp(json::GetInt(args, "limit", 50), 1, 1000)),
            base::BindOnce(
                [](Reply reply, std::vector<ArchivedTabRecord> records) {
                  base::ListValue rows;
                  for (const auto& record : records) {
                    rows.Append(json::ArchivedTabToValue(record, ""));
                  }
                  Ok(std::move(reply), base::Value(std::move(rows)));
                },
                std::move(reply)));
      }));

  // --- Sync ------------------------------------------------------------------
  Add("sync-status", base::BindRepeating([](const base::DictValue&,
                                            Reply reply) {
        SyncEngine* sync = Svc()->sync();
        if (!sync) {
          Err(std::move(reply), "sync unavailable");
          return;
        }
        Ok(std::move(reply), SyncStatusValue(sync->Status()));
      }));

  Add("sync", base::BindRepeating([](const base::DictValue& args,
                                     Reply reply) {
        SyncEngine* sync = Svc()->sync();
        if (!sync) {
          Err(std::move(reply), "sync unavailable");
          return;
        }
        const std::string op = json::GetString(args, "op", "status");
        const std::string server = json::GetString(args, "server");
        const std::string email = json::GetString(args, "email");
        const std::string password = json::GetString(args, "password");
        auto status_reply = base::BindOnce(
            [](Reply reply, SyncStatusInfo info) {
              Ok(std::move(reply), SyncStatusValue(info));
            },
            std::move(reply));
        if (op == "status") {
          std::move(status_reply).Run(sync->Status());
        } else if (op == "configure") {
          sync->ConfigureServer(server, {}, std::move(status_reply));
        } else if (op == "now") {
          sync->SyncNow(base::BindOnce(
              [](base::OnceCallback<void(SyncStatusInfo)> status_reply,
                 SyncResult result) {
                OpenBrowserService* service = Svc();
                SyncStatusInfo info = service && service->sync()
                                          ? service->sync()->Status()
                                          : SyncStatusInfo();
                if (!result.ok) {
                  info.error_message = result.error_message;
                }
                std::move(status_reply).Run(std::move(info));
              },
              std::move(status_reply)));
        } else if (op == "logout") {
          sync->Logout(std::move(status_reply));
        } else if (op == "register") {
          sync->Register(
              email, password, server,
              base::BindOnce(
                  [](base::OnceCallback<void(SyncStatusInfo)> status_reply,
                     base::expected<std::string, std::string> result) {
                    OpenBrowserService* service = Svc();
                    SyncStatusInfo info = service && service->sync()
                                              ? service->sync()->Status()
                                              : SyncStatusInfo();
                    if (!result.has_value()) {
                      info.error_message = result.error();
                    }
                    std::move(status_reply).Run(std::move(info));
                  },
                  std::move(status_reply)));
        } else if (op == "login") {
          sync->Login(
              email, password, server,
              base::BindOnce(
                  [](base::OnceCallback<void(SyncStatusInfo)> status_reply,
                     base::expected<bool, std::string> result) {
                    OpenBrowserService* service = Svc();
                    SyncStatusInfo info = service && service->sync()
                                              ? service->sync()->Status()
                                              : SyncStatusInfo();
                    if (!result.has_value()) {
                      info.error_message = result.error();
                    }
                    std::move(status_reply).Run(std::move(info));
                  },
                  std::move(status_reply)));
        } else {
          std::move(status_reply).Run(sync->Status());
        }
      }));
}

}  // namespace open_unified
