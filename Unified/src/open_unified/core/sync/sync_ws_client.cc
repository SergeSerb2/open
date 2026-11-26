// Copyright 2026 The Open Authors. All rights reserved.
// Chromium 156 NetworkContext::CreateWebSocket implementation of
// SyncWebSocketClient.

#include "open_unified/core/sync/sync_ws_client.h"

#include <algorithm>
#include <utility>

#include "base/containers/span.h"
#include "base/strings/string_view_util.h"
#include "base/functional/bind.h"
#include "base/json/json_reader.h"
#include "base/location.h"
#include "base/logging.h"
#include "base/task/sequenced_task_runner.h"
#include "base/time/time.h"
#include "net/base/isolation_info.h"
#include "net/storage_access_api/status.h"
#include "net/traffic_annotation/network_traffic_annotation.h"
#include "services/network/public/cpp/originating_process_id.h"
#include "services/network/public/mojom/client_security_state.mojom.h"
#include "services/network/public/mojom/ip_address_space.mojom.h"
#include "url/gurl.h"
#include "url/origin.h"

namespace open_unified {

namespace {

constexpr net::NetworkTrafficAnnotationTag kOpenSyncWsTrafficAnnotation =
    net::DefineNetworkTrafficAnnotation("open_sync_v1_websocket", R"(
        semantics {
          sender: "Open Sync v1 WebSocket Client"
          description:
            "Maintains a lightweight WebSocket connection to the user-"
            "configured self-hosted Open Sync Server (/v1/sync/ws) to receive "
            "real-time revision wakeup notifications."
          trigger:
            "User signs in to Open Sync or launches Open while signed in."
          data:
            "Bearer access token, device UUID header, and small JSON revision "
            "wakeup/ping frames."
          destination: OTHER
          destination_other: "User-configured Open Sync Server"
        }
        policy {
          cookies_allowed: NO
          setting:
            "Optional feature; disabled unless the user configures Open Sync "
            "in open://settings."
          policy_exception_justification: "User-configured opt-in sync."
        })");

constexpr size_t kReadChunkBytes = 4096;

}  // namespace

ChromiumSyncWebSocketClient::ChromiumSyncWebSocketClient(
    SyncNetworkContextProvider network_context_provider)
    : network_context_provider_(std::move(network_context_provider)),
      network_restrictions_id_(base::UnguessableToken::Create()) {}

ChromiumSyncWebSocketClient::~ChromiumSyncWebSocketClient() {
  Disconnect();
}

void ChromiumSyncWebSocketClient::SetNetworkContextProvider(
    SyncNetworkContextProvider network_context_provider) {
  network_context_provider_ = std::move(network_context_provider);
}

void ChromiumSyncWebSocketClient::SetOnRemoteEventCallback(
    OnRemoteEventCallback callback) {
  on_remote_event_ = std::move(callback);
}

void ChromiumSyncWebSocketClient::SetAutoReconnect(bool enabled) {
  auto_reconnect_ = enabled;
  if (!enabled) {
    reconnect_timer_.Stop();
  }
}

void ChromiumSyncWebSocketClient::Connect(const std::string& ws_url,
                                          const std::string& access_token,
                                          const std::string& device_id,
                                          Delegate* delegate) {
  reconnect_timer_.Stop();
  ResetConnection(/*send_close_frame=*/false);

  ws_url_ = ws_url;
  access_token_ = access_token;
  device_id_ = device_id;
  delegate_ = delegate;
  manually_disconnected_ = false;
  backoff_seconds_ = kMinBackoffSeconds;

  StartHandshake();
}

void ChromiumSyncWebSocketClient::SendText(const std::string& text) {
  if (!connected_ || closing_ || !socket_.is_bound() || !writable_.is_valid()) {
    return;
  }
  if (outgoing_messages_.size() >= kMaxPendingOutgoingMessages) {
    // Drop oldest stale ping/message if pipe is backed up.
    return;
  }
  PendingOutgoingMessage msg;
  msg.data = text;
  outgoing_messages_.push_back(std::move(msg));
  FlushOutgoingMessages();
}

void ChromiumSyncWebSocketClient::Disconnect() {
  manually_disconnected_ = true;
  reconnect_timer_.Stop();
  delegate_ = nullptr;
  ResetConnection(/*send_close_frame=*/true);
}

bool ChromiumSyncWebSocketClient::IsConnected() const {
  return connected_ && !closing_ && socket_.is_bound();
}

void ChromiumSyncWebSocketClient::StartHandshake() {
  ++connection_generation_;
  const uint64_t gen = connection_generation_;

  GURL url(ws_url_);
  if (!url.is_valid() || !(url.SchemeIs("ws") || url.SchemeIs("wss"))) {
    base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE,
        base::BindOnce(
            [](base::WeakPtr<ChromiumSyncWebSocketClient> self, uint64_t g) {
              if (!self || self->connection_generation_ != g) {
                return;
              }
              self->NotifyDisconnected(1006, "Invalid WebSocket URL", 0);
            },
            weak_factory_.GetWeakPtr(), gen));
    return;
  }

  network::mojom::NetworkContext* network_context =
      network_context_provider_ ? network_context_provider_.Run() : nullptr;
  if (!network_context) {
    base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE,
        base::BindOnce(
            [](base::WeakPtr<ChromiumSyncWebSocketClient> self, uint64_t g) {
              if (!self || self->connection_generation_ != g) {
                return;
              }
              self->NotifyDisconnected(1006, "No NetworkContext available", 0);
            },
            weak_factory_.GetWeakPtr(), gen));
    return;
  }

  std::vector<network::mojom::HttpHeaderPtr> additional_headers;
  if (!access_token_.empty()) {
    additional_headers.push_back(network::mojom::HttpHeader::New(
        "Authorization", "Bearer " + access_token_));
  }
  if (!device_id_.empty()) {
    additional_headers.push_back(
        network::mojom::HttpHeader::New("X-Open-Device-Id", device_id_));
  }

  const url::Origin origin = url::Origin::Create(url);
  const net::IsolationInfo isolation_info =
      net::IsolationInfo::CreateForInternalRequest(origin);

  mojo::PendingRemote<network::mojom::WebSocketHandshakeClient>
      handshake_remote = handshake_receiver_.BindNewPipeAndPassRemote();
  handshake_receiver_.set_disconnect_handler(
      base::BindOnce(&ChromiumSyncWebSocketClient::OnHandshakePipeDisconnected,
                     weak_factory_.GetWeakPtr()));

  network_context->CreateWebSocket(
      url, /*requested_protocols=*/{}, net::StorageAccessApiStatus::kNone,
      isolation_info, std::move(additional_headers),
      network::OriginatingProcessId::browser(), origin,
      network::mojom::ClientSecurityState::New(),
      network::mojom::kWebSocketOptionBlockAllCookies,
      net::MutableNetworkTrafficAnnotationTag(kOpenSyncWsTrafficAnnotation),
      std::move(handshake_remote),
      /*url_loader_network_observer=*/mojo::NullRemote(),
      /*auth_handler=*/mojo::NullRemote(),
      /*header_client=*/mojo::NullRemote(),
      /*throttling_profile_id=*/std::nullopt, network_restrictions_id_,
      network::mojom::IPAddressSpace::kUnknown,
      /*target_network=*/std::nullopt);
}

void ChromiumSyncWebSocketClient::ResetConnection(bool send_close_frame) {
  ++connection_generation_;
  if (send_close_frame && connected_ && socket_.is_bound()) {
    socket_->StartClosingHandshake(1000, "client_disconnect");
  }
  connected_ = false;
  closing_ = false;

  if (readable_watcher_) {
    readable_watcher_->Cancel();
    readable_watcher_.reset();
  }
  if (writable_watcher_) {
    writable_watcher_->Cancel();
    writable_watcher_.reset();
  }
  readable_.reset();
  writable_.reset();

  handshake_receiver_.reset();
  client_receiver_.reset();
  socket_.reset();

  incoming_frames_.clear();
  assembling_text_ = false;
  discarding_current_message_ = false;
  message_buffer_.clear();
  outgoing_messages_.clear();
}

void ChromiumSyncWebSocketClient::OnHandshakePipeDisconnected() {
  if (connected_ || manually_disconnected_) {
    return;
  }
  ResetConnection(/*send_close_frame=*/false);
  NotifyDisconnected(1006, "WebSocket handshake disconnected", 0);
}

void ChromiumSyncWebSocketClient::OnChannelPipeDisconnected() {
  if (manually_disconnected_) {
    return;
  }
  ResetConnection(/*send_close_frame=*/false);
  NotifyDisconnected(1006, "WebSocket connection dropped", 0);
}

void ChromiumSyncWebSocketClient::OnOpeningHandshakeStarted(
    network::mojom::WebSocketHandshakeRequestPtr /*request*/) {}

void ChromiumSyncWebSocketClient::OnFailure(const std::string& message,
                                            int32_t /*net_error*/,
                                            int32_t response_code) {
  if (manually_disconnected_) {
    return;
  }
  ResetConnection(/*send_close_frame=*/false);
  const int http_status = response_code > 0 ? static_cast<int>(response_code) : 0;
  NotifyDisconnected(1006, message, http_status);
}

void ChromiumSyncWebSocketClient::OnConnectionEstablished(
    mojo::PendingRemote<network::mojom::WebSocket> socket,
    mojo::PendingReceiver<network::mojom::WebSocketClient> client_receiver,
    network::mojom::WebSocketHandshakeResponsePtr /*response*/,
    mojo::ScopedDataPipeConsumerHandle readable,
    mojo::ScopedDataPipeProducerHandle writable) {
  if (manually_disconnected_) {
    return;
  }

  handshake_receiver_.set_disconnect_handler(base::NullCallback());
  handshake_receiver_.reset();

  socket_.Bind(std::move(socket));
  client_receiver_.Bind(std::move(client_receiver));

  socket_.set_disconnect_handler(
      base::BindOnce(&ChromiumSyncWebSocketClient::OnChannelPipeDisconnected,
                     weak_factory_.GetWeakPtr()));
  client_receiver_.set_disconnect_handler(
      base::BindOnce(&ChromiumSyncWebSocketClient::OnChannelPipeDisconnected,
                     weak_factory_.GetWeakPtr()));

  readable_ = std::move(readable);
  writable_ = std::move(writable);
  connected_ = true;
  closing_ = false;
  backoff_seconds_ = kMinBackoffSeconds;

  readable_watcher_ = std::make_unique<mojo::SimpleWatcher>(
      FROM_HERE, mojo::SimpleWatcher::ArmingPolicy::MANUAL,
      base::SequencedTaskRunner::GetCurrentDefault());
  readable_watcher_->Watch(
      readable_.get(),
      MOJO_HANDLE_SIGNAL_READABLE | MOJO_HANDLE_SIGNAL_PEER_CLOSED,
      MOJO_WATCH_CONDITION_SATISFIED,
      base::BindRepeating(&ChromiumSyncWebSocketClient::OnReadableReady,
                          weak_factory_.GetWeakPtr()));

  writable_watcher_ = std::make_unique<mojo::SimpleWatcher>(
      FROM_HERE, mojo::SimpleWatcher::ArmingPolicy::MANUAL,
      base::SequencedTaskRunner::GetCurrentDefault());
  writable_watcher_->Watch(
      writable_.get(),
      MOJO_HANDLE_SIGNAL_WRITABLE | MOJO_HANDLE_SIGNAL_PEER_CLOSED,
      MOJO_WATCH_CONDITION_SATISFIED,
      base::BindRepeating(&ChromiumSyncWebSocketClient::OnWritableReady,
                          weak_factory_.GetWeakPtr()));

  socket_->StartReceiving();
  FlushOutgoingMessages();
}

void ChromiumSyncWebSocketClient::OnDataFrame(
    bool fin,
    network::mojom::WebSocketMessageType type,
    uint64_t data_length) {
  if (!connected_ || manually_disconnected_) {
    return;
  }
  PendingIncomingFrame frame;
  frame.fin = fin;
  frame.type = type;
  frame.remaining_bytes = data_length;
  incoming_frames_.push_back(frame);
  DrainIncomingFrames();
}

void ChromiumSyncWebSocketClient::OnDropChannel(bool /*was_clean*/,
                                                uint16_t code,
                                                const std::string& reason) {
  if (manually_disconnected_) {
    return;
  }
  ResetConnection(/*send_close_frame=*/false);
  NotifyDisconnected(static_cast<int>(code), reason, 0);
}

void ChromiumSyncWebSocketClient::OnClosingHandshake() {
  closing_ = true;
}

void ChromiumSyncWebSocketClient::OnReadableReady(
    MojoResult result,
    const mojo::HandleSignalsState& /*state*/) {
  if (!connected_ || manually_disconnected_) {
    return;
  }
  if (result == MOJO_RESULT_OK) {
    DrainIncomingFrames();
    return;
  }
  if (result == MOJO_RESULT_FAILED_PRECONDITION) {
    OnChannelPipeDisconnected();
  }
}

void ChromiumSyncWebSocketClient::DrainIncomingFrames() {
  if (!readable_.is_valid()) {
    return;
  }

  std::vector<uint8_t> scratch(kReadChunkBytes);

  while (!incoming_frames_.empty() && connected_) {
    PendingIncomingFrame& frame = incoming_frames_.front();

    if (frame.type == network::mojom::WebSocketMessageType::TEXT) {
      if (!assembling_text_) {
        assembling_text_ = true;
        discarding_current_message_ = false;
        message_buffer_.clear();
      }
    } else if (frame.type == network::mojom::WebSocketMessageType::BINARY) {
      assembling_text_ = false;
      discarding_current_message_ = true;
      message_buffer_.clear();
    } else if (frame.type ==
               network::mojom::WebSocketMessageType::CONTINUATION) {
      if (!assembling_text_) {
        discarding_current_message_ = true;
      }
    }

    while (frame.remaining_bytes > 0) {
      const size_t to_read = static_cast<size_t>(
          std::min<uint64_t>(frame.remaining_bytes, scratch.size()));
      size_t bytes_read = 0;
      MojoResult rv = readable_->ReadData(
          MOJO_READ_DATA_FLAG_NONE, base::span(scratch).first(to_read),
          bytes_read);
      if (rv == MOJO_RESULT_SHOULD_WAIT) {
        if (readable_watcher_) {
          readable_watcher_->ArmOrNotify();
        }
        return;
      }
      if (rv != MOJO_RESULT_OK) {
        OnChannelPipeDisconnected();
        return;
      }
      if (bytes_read == 0) {
        if (readable_watcher_) {
          readable_watcher_->ArmOrNotify();
        }
        return;
      }

      frame.remaining_bytes -= bytes_read;
      if (!discarding_current_message_) {
        if (message_buffer_.size() + bytes_read > kMaxIncomingMessageBytes) {
          discarding_current_message_ = true;
          message_buffer_.clear();
        } else {
          message_buffer_.append(
              base::as_string_view(base::span(scratch).first(bytes_read)));
        }
      }
    }

    const bool fin = frame.fin;
    incoming_frames_.pop_front();

    if (fin) {
      const bool emit = assembling_text_ && !discarding_current_message_;
      std::string completed = std::move(message_buffer_);
      message_buffer_.clear();
      assembling_text_ = false;
      discarding_current_message_ = false;
      if (emit) {
        HandleCompletedTextMessage(completed);
      }
    }
  }
}

void ChromiumSyncWebSocketClient::HandleCompletedTextMessage(
    const std::string& message) {
  if (on_remote_event_) {
    on_remote_event_.Run(message);
  }
  if (!delegate_) {
    return;
  }
  auto dict = base::JSONReader::ReadDict(message, base::JSON_PARSE_RFC);
  if (!dict) {
    return;
  }
  const std::string* type = dict->FindString("type");
  if (!type) {
    return;
  }
  if (*type == "connected") {
    delegate_->OnWsConnected(dict->FindInt("serverRevision").value_or(0),
                             dict->FindInt("resetRevision").value_or(0));
  } else if (*type == "sync_available") {
    const std::string* src = dict->FindString("sourceDeviceId");
    delegate_->OnWsSyncAvailable(dict->FindInt("revision").value_or(0),
                                 dict->FindInt("resetRevision").value_or(0),
                                 src ? *src : std::string());
  }
}

void ChromiumSyncWebSocketClient::OnWritableReady(
    MojoResult result,
    const mojo::HandleSignalsState& /*state*/) {
  if (!connected_ || manually_disconnected_) {
    return;
  }
  if (result == MOJO_RESULT_OK) {
    FlushOutgoingMessages();
    return;
  }
  if (result == MOJO_RESULT_FAILED_PRECONDITION) {
    OnChannelPipeDisconnected();
  }
}

void ChromiumSyncWebSocketClient::FlushOutgoingMessages() {
  if (!connected_ || !socket_.is_bound() || !writable_.is_valid()) {
    return;
  }

  while (!outgoing_messages_.empty()) {
    PendingOutgoingMessage& msg = outgoing_messages_.front();
    if (!msg.header_sent) {
      socket_->SendMessage(network::mojom::WebSocketMessageType::TEXT,
                           static_cast<uint64_t>(msg.data.size()));
      msg.header_sent = true;
    }

    while (msg.offset < msg.data.size()) {
      size_t bytes_written = 0;
      MojoResult rv = writable_->WriteData(
          base::as_byte_span(msg.data).subspan(msg.offset),
          MOJO_WRITE_DATA_FLAG_NONE, bytes_written);
      if (rv == MOJO_RESULT_SHOULD_WAIT) {
        if (writable_watcher_) {
          writable_watcher_->ArmOrNotify();
        }
        return;
      }
      if (rv != MOJO_RESULT_OK) {
        OnChannelPipeDisconnected();
        return;
      }
      if (bytes_written == 0) {
        if (writable_watcher_) {
          writable_watcher_->ArmOrNotify();
        }
        return;
      }
      msg.offset += bytes_written;
    }

    outgoing_messages_.pop_front();
  }
}

void ChromiumSyncWebSocketClient::NotifyDisconnected(int close_code,
                                                     std::string reason,
                                                     int http_status) {
  if (manually_disconnected_) {
    return;
  }
  Delegate* delegate = delegate_;
  if (delegate) {
    delegate->OnWsDisconnected(close_code, reason, http_status);
  } else if (auto_reconnect_ && close_code != kSyncWsSessionRevokedCloseCode &&
             reason != "session_revoked") {
    ScheduleAutoReconnect();
  }
}

void ChromiumSyncWebSocketClient::ScheduleAutoReconnect() {
  if (manually_disconnected_ || !auto_reconnect_) {
    return;
  }
  const double delay = backoff_seconds_;
  backoff_seconds_ = std::min(backoff_seconds_ * 2.0, kMaxBackoffSeconds);
  reconnect_timer_.Start(
      FROM_HERE, base::Seconds(delay),
      base::BindOnce(&ChromiumSyncWebSocketClient::StartHandshake,
                     weak_factory_.GetWeakPtr()));
}

std::unique_ptr<SyncWebSocketClient> CreateChromiumSyncWebSocketClient(
    SyncNetworkContextProvider network_context_provider) {
  return std::make_unique<ChromiumSyncWebSocketClient>(
      std::move(network_context_provider));
}

}  // namespace open_unified
