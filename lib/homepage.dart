// lib/homepage.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/realtime.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  // Realtime
  StreamSubscription? _rtSub;

  // Playlist & playback
  List<_PlayableItem> _items = [];
  int _currentIndex = 0;
  Timer? _slideTimer;

  // Heartbeat
  Timer? _heartbeatTimer;
  String _accountStatus = 'unknown';
  int? _licenseDaysLeft;
  String? _serverTimeIso;

  // Device config
  String? _token;
  String _baseOrigin = 'http://192.168.1.148:8000'; // fallback
  String? _contentVersion;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _slideTimer?.cancel();
    _heartbeatTimer?.cancel();
    _rtSub?.cancel();
    // optional: keep WS running globally if you also use it elsewhere
    // RealtimeManager.I.stop();
    super.dispose();
  }

  Future<void> _init() async {
    final prefs = await SharedPreferences.getInstance();
    _token = prefs.getString('token');                     // set by RegisterPage
    _baseOrigin = prefs.getString('base_origin') ?? _baseOrigin;
    _contentVersion = prefs.getString('playlist_content_version');

    // restore cached playlist for instant boot
    final rawItems = prefs.getString('playlist_items');
    if (rawItems != null && rawItems.isNotEmpty) {
      try {
        final decoded = jsonDecode(rawItems) as List;
        _items = decoded.map((e) => _PlayableItem.fromMap(Map.from(e))).toList();
      } catch (_) {
        // ignore restore error
      }
    }
    setState(() {});
    _startPlayback();
    _startHeartbeat();

    // ---- Realtime: start & subscribe ----
    // If base_origin = http://192.168.1.148:8000  => wsUrl = http://192.168.1.148:8081
    if (_token != null && _token!.isNotEmpty) {
      final host = Uri.parse(_baseOrigin);
      final wsUrl = '${host.scheme}://${host.host}:8081';

      // Safe to call even if already started elsewhere (should be idempotent)
      await RealtimeManager.I.start(
        apiBase: _baseOrigin,
        wsUrl: wsUrl,
      );


      _rtSub?.cancel();
      _rtSub = RealtimeManager.I.stream.listen((event) async {
        // Any realtime push (e.g. {event:'playlist.bump', ...}) → refresh config
        await _fetchConfigAndApply();
      });
    }

    // Initial sync once at boot (in case device registered before WS is live)
    await _fetchConfigAndApply();
  }

  // ---------- Playback ----------
  void _startPlayback() {
    _slideTimer?.cancel();
    if (_items.isEmpty) return;
    _scheduleNext();
  }

  void _scheduleNext() {
    if (_items.isEmpty) return;
    final current = _items[_currentIndex];
    _slideTimer = Timer(Duration(seconds: current.durationSec), () {
      if (!mounted) return;
      setState(() {
        _currentIndex = (_currentIndex + 1) % _items.length;
      });
      _scheduleNext();
    });
  }

  // ---------- Heartbeat ----------
  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(minutes: 3), (_) => _sendHeartbeat());
    _sendHeartbeat();
  }

  Future<void> _sendHeartbeat() async {
    if (_token == null || _token!.isEmpty) return;

    final dio = Dio(BaseOptions(
      baseUrl: _baseOrigin, // e.g. http://192.168.1.148:8000
      headers: {
        'Accept': '*/*',
        'X-Screen-Token': _token!, // middleware: screen.auth
      },
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 8),
    ));

    const url = '/api/screen/v1/heartbeat';
    try {
      final payload = <String, dynamic>{};
      if (_contentVersion != null && _contentVersion!.isNotEmpty) {
        payload['content_version'] = _contentVersion;
      }
      final resp = await dio.post(url, data: payload);
      if (resp.statusCode != null && resp.statusCode! >= 200 && resp.statusCode! < 300) {
        final data = (resp.data as Map);
        final status = (data['status'] ?? 'unknown').toString();
        final serverTime = (data['server_time'] ?? '').toString();
        final license = (data['license'] ?? {}) as Map;
        final daysLeft = int.tryParse((license['days_left'] ?? '').toString());
        setState(() {
          _accountStatus = status;
          _serverTimeIso = serverTime;
          _licenseDaysLeft = daysLeft;
        });

        // If not active, blank the playlist
        if (status != 'active') {
          _slideTimer?.cancel();
          if (mounted) setState(() => _items = []);
        }
      }
    } catch (_) {
      // ignore heartbeat errors for now
    }
  }

  // ---------- Fetch latest content (called on WS push) ----------
  Future<void> _fetchConfigAndApply() async {
    if (_token == null || _token!.isEmpty) return;

    final dio = Dio(BaseOptions(
      baseUrl: _baseOrigin,
      headers: {
        'Accept': 'application/json',
        'X-Screen-Token': _token!,
      },
      connectTimeout: const Duration(seconds: 20),
      receiveTimeout: const Duration(seconds: 20),
    ));

    try {
      final r = await dio.get('/api/screen/v1/config');
      if (r.statusCode == 200 && r.data is Map) {
        final m = r.data as Map;
        final items = (m['items'] ?? []) as List;
        final contentVersion = (m['content_version'] ?? '').toString();
        final updatedAt = (m['updated_at'] ?? '').toString();

        // Download media to cache
        final mediaClient = Dio(BaseOptions(
          headers: {'Accept': 'application/json'},
          connectTimeout: const Duration(seconds: 25),
          receiveTimeout: const Duration(seconds: 40),
        ));

        final List<Map<String, dynamic>> resolved = [];
        for (final it in items) {
          final im = it as Map;
          final type = (im['type'] ?? '').toString();
          final rel = (im['url'] ?? '').toString();
          final duration = int.tryParse((im['duration_sec'] ?? '10').toString()) ?? 10;
          if (rel.isEmpty) continue;

          final abs = _resolveCustomerMediaUrl(baseOrigin: _baseOrigin, url: rel);
          final local = await _downloadToCache(mediaClient, abs);
          resolved.add({
            'type': type,
            'url': abs,
            'local_path': local,
            'duration_sec': duration,
          });
        }

        // Persist & apply
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('playlist_items', jsonEncode(resolved));
        await prefs.setString('playlist_content_version', contentVersion);
        await prefs.setString('playlist_updated_at', updatedAt);
        _contentVersion = contentVersion;

        if (!mounted) return;
        setState(() {
          _items = resolved.map((e) => _PlayableItem.fromMap(e)).toList();
          _currentIndex = 0;
        });
        _startPlayback();
      }
    } catch (e) {
      debugPrint('Config fetch failed: $e');
    }
  }

  // ---------- Helpers ----------
  /// Convert "media/customer_/file.png" -> "{origin}/storage/media/customer_/file.png"
  String _resolveCustomerMediaUrl({required String baseOrigin, required String url}) {
    if (url.startsWith('http://') || url.startsWith('https://')) return url;
    final reg = RegExp(r'^/?media/customer_(\d+)\/(.+)$');
    final m = reg.firstMatch(url);
    if (m != null) {
      final cid = m.group(1)!;
      final tail = m.group(2)!;
      return '$baseOrigin/storage/media/customer_$cid/$tail';
    }
    if (url.startsWith('/')) return '$baseOrigin$url';
    return '$baseOrigin/$url';
  }

  Future<String> _downloadToCache(Dio dio, String absoluteUrl, {String? filename}) async {
    final dir = await getApplicationSupportDirectory();
    final mediaDir = Directory('${dir.path}/media');
    if (!await mediaDir.exists()) {
      await mediaDir.create(recursive: true);
    }
    final name = filename ?? absoluteUrl.split('?').first.split('/').last;
    final savePath = '${mediaDir.path}/$name';
    final f = File(savePath);
    if (await f.exists() && (await f.length()) > 0) return savePath;
    await dio.download(absoluteUrl, savePath);
    return savePath;
  }

  // ---------- UI ----------
  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final shortest = mq.size.shortestSide;
    final scale = (shortest / 720).clamp(0.75, 2.2);
    final logoSize = (mq.size.width * 0.22).clamp(140.0, 520.0);

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (_items.isEmpty)
            Center(
              child: Image.asset(
                'assets/images/1.png',
                width: logoSize,
                fit: BoxFit.contain,
              ),
            )
          else
            _buildCurrentSlide(),

          // status chip (top-right)
          Positioned(
            top: 20 * scale,
            right: 20 * scale,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 12 * scale, vertical: 6 * scale),
                child: Text(
                  _statusText(),
                  style: TextStyle(color: Colors.white, fontSize: (12 * scale).clamp(11, 18)),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _statusText() {
    final days = _licenseDaysLeft != null ? ' • ${_licenseDaysLeft}d left' : '';
    final time = _serverTimeIso != null && _serverTimeIso!.isNotEmpty ? ' • $_serverTimeIso' : '';
    final ver = _contentVersion != null && _contentVersion!.isNotEmpty ? ' • $_contentVersion' : '';
    return '$_accountStatus$days$time$ver';
  }

  Widget _buildCurrentSlide() {
    final item = _items[_currentIndex];
    switch (item.type) {
      case 'image':
        if (item.localPath != null && File(item.localPath!).existsSync()) {
          return Image.file(File(item.localPath!), fit: BoxFit.cover);
        }
        return Image.network(item.url, fit: BoxFit.cover);
      // case 'video': // TODO
      default:
        return const SizedBox.shrink();
    }
  }
}

class _PlayableItem {
  final String type; // image | (video later)
  final String url; // absolute URL
  final String? localPath;
  final int durationSec;

  _PlayableItem({
    required this.type,
    required this.url,
    required this.localPath,
    required this.durationSec,
  });

  factory _PlayableItem.fromMap(Map m) {
    return _PlayableItem(
      type: (m['type'] ?? '').toString(),
      url: (m['url'] ?? '').toString(),
      localPath: (m['local_path']?.toString().isEmpty ?? true) ? null : m['local_path'].toString(),
      durationSec: int.tryParse((m['duration_sec'] ?? '10').toString()) ?? 10,
    );
  }

  Map<String, dynamic> toMap() => {
        'type': type,
        'url': url,
        'local_path': localPath,
        'duration_sec': durationSec,
      };
}
