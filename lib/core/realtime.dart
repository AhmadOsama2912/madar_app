// lib/core/realtime.dart
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;

/// Minimal shape carried on push; the app fetches the real playlist via REST.
class PlaylistSnapshot {
  final String contentVersion;
  final List<dynamic> items; // optional hint from server (often empty)

  PlaylistSnapshot({required this.contentVersion, required this.items});

  factory PlaylistSnapshot.fromPush(dynamic data) {
    try {
      final m = (data is Map) ? Map<String, dynamic>.from(data) : <String, dynamic>{};
      return PlaylistSnapshot(
        contentVersion: (m['version'] ?? '').toString(),
        items: (m['items'] is List) ? List.from(m['items']) : const [],
      );
    } catch (_) {
      return PlaylistSnapshot(contentVersion: '', items: const []);
    }
  }
}

/// Idempotent realtime manager (singleton). Call start() once; it will reconnect automatically.
class RealtimeManager {
  RealtimeManager._();
  static final RealtimeManager I = RealtimeManager._();

  final _controller = StreamController<PlaylistSnapshot>.broadcast();
  Stream<PlaylistSnapshot> get stream => _controller.stream;

  IO.Socket? _socket;
  String? _apiBase;
  String? _wsUrl;
  bool _starting = false;

  bool get isConnected => _socket?.connected == true;

  Future<void> start({required String apiBase, required String wsUrl}) async {
    _apiBase = apiBase;
    _wsUrl = wsUrl;

    if (_starting) return;
    _starting = true;

    try {
      // Load device token from storage
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('token');
      if (token == null || token.isEmpty) {
        debugPrint('[Realtime] No token found. Realtime not started.');
        return;
      }

      // Dispose previous socket if URL changed
      if (_socket != null) {
        try { _socket!.dispose(); } catch (_) { try { _socket!.disconnect(); } catch (_) {} }
        _socket = null;
      }

      // Build base options with OptionBuilder
      final opts = IO.OptionBuilder()
          .setTransports(['websocket'])
          .enableForceNew()          // new underlying socket each time
          .disableAutoConnect()      // call connect() ourselves
          .setExtraHeaders({'Accept': 'application/json'})
          .build();

      // 👇 Add flags that OptionBuilder in 2.0.3+1 doesn't expose
      opts['query'] = {'token': token};
      opts['reconnection'] = true;
      opts['reconnectionDelay'] = 2000;   // ms
      opts['timeout'] = 20000;            // ms

      final s = IO.io(wsUrl, opts);

      s.onConnect((_) => debugPrint('[Realtime] connected to $wsUrl'));
      s.onDisconnect((_) => debugPrint('[Realtime] disconnected'));
      s.onReconnectAttempt((_) => debugPrint('[Realtime] reconnecting…'));
      s.onConnectError((e) => debugPrint('[Realtime] connect_error: $e'));
      s.onError((e) => debugPrint('[Realtime] error: $e'));

      // Server emits 'playlist.bump' to room `screen-<id>`
      s.on('playlist.bump', (data) {
        debugPrint('[Realtime] push playlist.bump: $data');
        _controller.add(PlaylistSnapshot.fromPush(data));
      });

      s.connect();
      _socket = s;
    } finally {
      _starting = false;
    }
  }

  void stop() {
    try { _socket?.dispose(); } catch (_) { try { _socket?.disconnect(); } catch (_) {} }
    _socket = null;
  }
}
