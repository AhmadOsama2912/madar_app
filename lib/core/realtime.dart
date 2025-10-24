// lib/core/realtime.dart
import 'dart:async';
import 'dart:convert';
import 'dart:developer' as dev;

import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;

/// Snapshot of the playlist/config for the screen.
class PlaylistSnapshot {
  final String contentVersion;
  final DateTime? updatedAt;
  final List<Map<String, dynamic>> items;

  const PlaylistSnapshot({
    required this.contentVersion,
    required this.updatedAt,
    required this.items,
  });

  Map<String, dynamic> toJson() => {
        'content_version': contentVersion,
        'updated_at': updatedAt?.toIso8601String(),
        'items': items,
      };
}

/// Singleton realtime manager
class RealtimeManager {
  RealtimeManager._();
  static final RealtimeManager I = RealtimeManager._();

  final _controller = StreamController<PlaylistSnapshot>.broadcast();
  Stream<PlaylistSnapshot> get stream => _controller.stream;

  IO.Socket? _socket;
  String? _apiBase; // e.g. http://192.168.1.148:8000
  String? _wsUrl;   // e.g. http://192.168.1.148:8081
  String? _token;

  /// Start realtime. If [apiBase] or [wsUrl] are not provided, we try to read
  /// base_origin/token from SharedPreferences.
  Future<void> start({String? apiBase, String? wsUrl, bool fetchImmediately = true}) async {
    final prefs = await SharedPreferences.getInstance();
    _token = prefs.getString('token');

    if (_token == null || _token!.isEmpty) {
      dev.log('[Realtime] No token found. Realtime not started.');
      return;
    }

    final storedBase = prefs.getString('base_origin');
    _apiBase = apiBase ?? storedBase ?? 'http://192.168.1.148:8000';
    _wsUrl   = wsUrl   ?? _deriveWsFromBase(_apiBase!);

    _connectSocket();

    if (fetchImmediately) {
      await fetchAndBroadcast();
    }
  }

  Future<void> stop() async {
    try {
      _socket?.dispose();
      _socket?.close();
    } catch (_) {}
    _socket = null;
  }

  String _deriveWsFromBase(String base) {
    final u = Uri.parse(base);
    return '${u.scheme}://${u.host}:8081';
  }

  void _connectSocket() {
    _socket?.dispose();

    final opts = IO.OptionBuilder()
        .setTransports(['websocket'])
        .enableReconnection()
        .setQuery({'token': _token}) // WS gateway will map this to the screen
        .build();

    final s = IO.io(_wsUrl, opts);

    s.onConnect((_) => dev.log('[Realtime] connected to $_wsUrl'));
    s.onReconnect((_) => dev.log('[Realtime] reconnected'));
    s.onError((e) => dev.log('[Realtime] error: $e'));
    s.onDisconnect((_) => dev.log('[Realtime] disconnected'));

    // The server emits "playlist.bump" to the socket (or to a room it joins)
    s.on('playlist.bump', (data) async {
      dev.log('[Realtime] playlist.bump => $data');
      await fetchAndBroadcast();
    });

    _socket = s;
  }

  /// Fetch current config and broadcast a PlaylistSnapshot on the stream.
  Future<PlaylistSnapshot?> fetchAndBroadcast() async {
    try {
      final snap = await _fetchConfig();
      if (snap != null) _controller.add(snap);
      return snap;
    } catch (e) {
      dev.log('[Realtime] fetchAndBroadcast error: $e');
      return null;
    }
  }

  Future<PlaylistSnapshot?> _fetchConfig() async {
    if (_apiBase == null || _token == null) return null;

    final dio = Dio(BaseOptions(
      baseUrl: _apiBase!,
      headers: {
        'Accept': 'application/json',
        'X-Screen-Token': _token!,
      },
      connectTimeout: const Duration(seconds: 20),
      receiveTimeout: const Duration(seconds: 20),
    ));

    final r = await dio.get('/api/screen/v1/config');
    if (r.statusCode == 200 && r.data is Map) {
      final m = r.data as Map;

      final items = ((m['items'] ?? []) as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();

      final snap = PlaylistSnapshot(
        contentVersion: (m['content_version'] ?? '').toString(),
        updatedAt: DateTime.tryParse((m['updated_at'] ?? '').toString()),
        items: items,
      );

      // Persist for your HomePage (same keys you’re already using)
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('playlist_items', jsonEncode(items));
      await prefs.setString('playlist_content_version', snap.contentVersion);
      await prefs.setString('playlist_updated_at', snap.updatedAt?.toIso8601String() ?? '');

      return snap;
    }
    return null;
  }
}
