// Copyright 2026 The Open Authors. All rights reserved.
// Real Chromium 156 WebSocket client for Open Sync v1 (/v1/sync/ws) backed by
// network::mojom::NetworkContext::CreateWebSocket.

#ifndef OPEN_UNIFIED_CORE_SYNC_SYNC_WS_CLIENT_H_
#define OPEN_UNIFIED_CORE_SYNC_SYNC_WS_CLIENT_H_

#include <cstdint>
#include <deque>
#include <memory>
#include <string>
#include <vector>

#include "base/functional/callback.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "base/timer/timer.h"
#include "base/unguessable_token.h"
#include "mojo/public/cpp/bindings/receiver.h"
#include "mojo/public/cpp/bindings/remote.h"
#include "mojo/public/cpp/system/data_pipe.h"
#include "mojo/public/cpp/system/simple_watcher.h"
#include "open_unified/core/sync/sync_engine.h"
#include "services/network/public/mojom/network_context.mojom.h"
#include "services/network/public/mojom/websocket.mojom.h"

namespace open_unified {

// Supplies the active Chromium NetworkContext on the UI thread (may return
// nullptr during startup or shutdown, in which case connection fails cleanly).
using SyncNetworkContextProvider =
    base::RepeatingCallback<network::mojom::NetworkContext*()>;

// Concrete SyncWebSocketClient using Chromium 156's
// network::mojom::NetworkContext::CreateWebSocket.
//
// Connects to the SyncServer WebSocket endpoint (<ws|wss>://<server>/v1/sync/ws)
// with `Authorization: Bearer <accessToken>` and `X-Open-Device-Id: <deviceId>`
// headers, dispatches server push notifications (`connected`, `sync_available`)
// to SyncWebSocketClient::Delegate (and an optional OnRemoteEventCallback) on
// the UI thread, and supports clean shutdown and optional exponential backoff
// reconnect (1s -> 2s -> ... -> 60s) when used standalone.
class ChromiumSyncWebSocketClient final
    : public SyncWebSocketClient,
      public network::mojom::WebSocketHandshakeClient,
      public network::mojom::WebSocketClient {
 public:
  using OnRemoteEventCallback =
      base::RepeatingCallback<void(const std::string& json_frame)>;

  static constexpr size_t kMaxIncomingMessageBytes = 128 * 1024;
  static constexpr size_t kMaxPendingOutgoingMessages = 16;
  static constexpr double kMinBackoffSeconds = 1.0;
  static constexpr double kMaxBackoffSeconds = 60.0;

  explicit ChromiumSyncWebSocketClient(
      SyncNetworkContextProvider network_context_provider);
  ~ChromiumSyncWebSocketClient() override;

  ChromiumSyncWebSocketClient(const ChromiumSyncWebSocketClient&) = delete;
  ChromiumSyncWebSocketClient& operator=(const ChromiumSyncWebSocketClient&) =
      delete;

  // Updates the NetworkContext provider (safe to call before Connect()).
  void SetNetworkContextProvider(
      SyncNetworkContextProvider network_context_provider);

  // Optional raw JSON frame observer invoked on the UI thread for every
  // completed incoming text message.
  void SetOnRemoteEventCallback(OnRemoteEventCallback callback);

  // Enables internal exponential-backoff reconnect (1s..60s) for standalone
  // callers without a SyncEngine::Delegate managing reconnects. When driven
  // by SyncEngine (the default), leave false so SyncEngine manages backoff and
  // 401 token refresh without duplicate timers.
  void SetAutoReconnect(bool enabled);

  // SyncWebSocketClient:
  void Connect(const std::string& ws_url,
               const std::string& access_token,
               const std::string& device_id,
               Delegate* delegate) override;
  void SendText(const std::string& text) override;
  void Disconnect() override;
  bool IsConnected() const override;

  // network::mojom::WebSocketHandshakeClient:
  void OnOpeningHandshakeStarted(
      network::mojom::WebSocketHandshakeRequestPtr request) override;
  void OnFailure(const std::string& message,
                 int32_t net_error,
                 int32_t response_code) override;
  void OnConnectionEstablished(
      mojo::PendingRemote<network::mojom::WebSocket> socket,
      mojo::PendingReceiver<network::mojom::WebSocketClient> client_receiver,
      network::mojom::WebSocketHandshakeResponsePtr response,
      mojo::ScopedDataPipeConsumerHandle readable,
      mojo::ScopedDataPipeProducerHandle writable) override;

  // network::mojom::WebSocketClient:
  void OnDataFrame(bool fin,
                   network::mojom::WebSocketMessageType type,
                   uint64_t data_length) override;
  void OnDropChannel(bool was_clean,
                     uint16_t code,
                     const std::string& reason) override;
  void OnClosingHandshake() override;

 private:
  struct PendingIncomingFrame {
    bool fin = false;
    network::mojom::WebSocketMessageType type =
        network::mojom::WebSocketMessageType::TEXT;
    uint64_t remaining_bytes = 0;
  };

  struct PendingOutgoingMessage {
    std::string data;
    size_t offset = 0;
    bool header_sent = false;
  };

  void StartHandshake();
  void ResetConnection(bool send_close_frame);
  void OnHandshakePipeDisconnected();
  void OnChannelPipeDisconnected();

  void OnReadableReady(MojoResult result,
                       const mojo::HandleSignalsState& state);
  void DrainIncomingFrames();
  void HandleCompletedTextMessage(const std::string& message);

  void OnWritableReady(MojoResult result,
                       const mojo::HandleSignalsState& state);
  void FlushOutgoingMessages();

  void NotifyDisconnected(int close_code,
                          std::string reason,
                          int http_status);
  void ScheduleAutoReconnect();

  SyncNetworkContextProvider network_context_provider_;
  OnRemoteEventCallback on_remote_event_;
  bool auto_reconnect_ = false;

  std::string ws_url_;
  std::string access_token_;
  std::string device_id_;
  raw_ptr<Delegate> delegate_ = nullptr;

  bool connected_ = false;
  bool manually_disconnected_ = false;
  bool closing_ = false;
  uint64_t connection_generation_ = 0;

  base::UnguessableToken network_restrictions_id_;

  mojo::Receiver<network::mojom::WebSocketHandshakeClient> handshake_receiver_{
      this};
  mojo::Receiver<network::mojom::WebSocketClient> client_receiver_{this};
  mojo::Remote<network::mojom::WebSocket> socket_;

  mojo::ScopedDataPipeConsumerHandle readable_;
  mojo::ScopedDataPipeProducerHandle writable_;
  std::unique_ptr<mojo::SimpleWatcher> readable_watcher_;
  std::unique_ptr<mojo::SimpleWatcher> writable_watcher_;

  // Incoming frame assembly state.
  std::deque<PendingIncomingFrame> incoming_frames_;
  bool assembling_text_ = false;
  bool discarding_current_message_ = false;
  std::string message_buffer_;

  // Outgoing write queue.
  std::deque<PendingOutgoingMessage> outgoing_messages_;

  // Standalone auto-reconnect state.
  base::OneShotTimer reconnect_timer_;
  double backoff_seconds_ = kMinBackoffSeconds;

  base::WeakPtrFactory<ChromiumSyncWebSocketClient> weak_factory_{this};
};

// Factory returning a Chromium NetworkContext-backed SyncWebSocketClient.
std::unique_ptr<SyncWebSocketClient> CreateChromiumSyncWebSocketClient(
    SyncNetworkContextProvider network_context_provider);

}  // namespace open_unified

#endif  // OPEN_UNIFIED_CORE_SYNC_SYNC_WS_CLIENT_H_
