// lib/homepage.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/realtime.dart'; // RealtimeManager + PlaylistSnapshot

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  // Realtime
  StreamSubscription<PlaylistSnapshot>? _rtSub;
  Timer? _debounce; // debounce rapid pushes

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
  String _baseOrigin = 'http://192.168.1.168:8000'; // fallback if not stored
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
    _debounce?.cancel();
    // DO NOT call RealtimeManager.I.stop(); keep the singleton alive.
    super.dispose();
  }

  Future<void> _init() async {
    final prefs = await SharedPreferences.getInstance();
    _token = prefs.getString('token'); // set by RegisterPage
    _baseOrigin = prefs.getString('base_origin') ?? _baseOrigin;
    _contentVersion = prefs.getString('playlist_content_version');

    // Restore cached playlist (normalize URLs and ignore bogus local paths)
    final rawItems = prefs.getString('playlist_items');
    if (rawItems != null && rawItems.isNotEmpty) {
      try {
        final decoded = jsonDecode(rawItems) as List;
        _items = decoded.map((e) {
          final m = Map<String, dynamic>.from(e as Map);
          final fixedUrl = _ensureAbsoluteUrl(_baseOrigin, m['url']?.toString() ?? '');
          final lp = m['local_path']?.toString();
          // accept only real app data paths
          final cleanLocalPath = (lp != null && lp.startsWith('/data/')) ? lp : null;
          return _PlayableItem(
            type: (m['type'] ?? '').toString(),
            url: fixedUrl,
            localPath: cleanLocalPath,
            durationSec: int.tryParse((m['duration_sec'] ?? '10').toString()) ?? 10,
          );
        }).toList();
      } catch (_) {/* ignore */}
    }

    debugPrint('[BOOT] origin=$_baseOrigin token=${_token != null ? '***' : '(none)'} '
        'restored_items=${_items.length} content_version=${_contentVersion ?? '-'}');

    setState(() {});
    _startPlayback();
    _startHeartbeat();

    // Realtime join + listen (idempotent start)
    if (_token != null && _token!.isNotEmpty) {
      final host = Uri.parse(_baseOrigin);
      final wsUrl = '${host.scheme}://${host.host}:8081';

      await RealtimeManager.I.start(apiBase: _baseOrigin, wsUrl: wsUrl);

      _rtSub?.cancel();
      _rtSub = RealtimeManager.I.stream.listen((snap) {
        debugPrint('[PUSH] event → version=${snap.contentVersion} items_hint=${snap.items.length} '
            '@${DateTime.now().toIso8601String()}');
        _debounce?.cancel();
        _debounce = Timer(const Duration(milliseconds: 350), () {
          _fetchConfigAndApply(reason: 'push');
        });
      });
    }

    // Initial sync after boot
    await _fetchConfigAndApply(reason: 'boot');
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
      baseUrl: _baseOrigin,
      headers: {'Accept': '*/*', 'X-Screen-Token': _token!},
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 8),
    ));

    try {
      final payload = <String, dynamic>{};
      if (_contentVersion != null && _contentVersion!.isNotEmpty) {
        payload['content_version'] = _contentVersion;
      }
      final resp = await dio.post('/api/screen/v1/heartbeat', data: payload);
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

        if (status != 'active') {
          _slideTimer?.cancel();
          if (mounted) setState(() => _items = []);
        }
      }
    } catch (_) {/* ignore */}
  }

  // ---------- Pull latest, normalize, download, apply ----------
  Future<void> _fetchConfigAndApply({required String reason}) async {
    if (_token == null || _token!.isEmpty) return;

    final dio = Dio(BaseOptions(
      baseUrl: _baseOrigin,
      headers: {'Accept': 'application/json', 'X-Screen-Token': _token!},
      connectTimeout: const Duration(seconds: 20),
      receiveTimeout: const Duration(seconds: 20),
    ));

    try {
      debugPrint('[CONFIG:$reason] GET /api/screen/v1/config …');
      final r = await dio.get('/api/screen/v1/config');
      if (r.statusCode == 200 && r.data is Map) {
        final m = r.data as Map;
        final items = (m['items'] ?? []) as List;
        final contentVersion = (m['content_version'] ?? '').toString();
        final updatedAt = (m['updated_at'] ?? '').toString();

        debugPrint('[CONFIG:$reason] received version=$contentVersion items=${items.length}');

        // If version unchanged and we already have items → skip heavy work
        if (_contentVersion != null &&
            _contentVersion!.isNotEmpty &&
            _contentVersion == contentVersion &&
            _items.isNotEmpty) {
          debugPrint('[CONFIG:$reason] version unchanged → skip apply');
          return;
        }

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

          final abs = _ensureAbsoluteUrl(_baseOrigin, rel);
          final local = await _downloadToCache(mediaClient, abs);

          debugPrint('[MEDIA] type=$type\n  src=$rel\n  abs=$abs\n  saved=$local');

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

        debugPrint('[CONFIG:$reason] applied version=$contentVersion now_playing=${_items.length} slides');
      }
    } catch (e) {
      debugPrint('[CONFIG:$reason] FAILED: $e');
    }
  }

  // ---------- URL helpers ----------
  /// Ensure backend URL is absolute:
  ///  - "media/customer_4/file.png"
  ///  - "/media/customer_4/file.png"
  ///  - "/storage/media/customer_4/file.png"
  ///  - or already absolute http/https
  String _ensureAbsoluteUrl(String origin, String url) {
    if (url.isEmpty) return url;
    if (url.startsWith('http://') || url.startsWith('https://')) return url;

    var base = origin;
    if (base.endsWith('/')) base = base.substring(0, base.length - 1);

    if (url.startsWith('/storage/')) return '$base$url';

    final reg = RegExp(r'^/?media/customer_(\d+)\/(.+)$');
    final m = reg.firstMatch(url);
    if (m != null) {
      final cid = m.group(1)!;
      final tail = m.group(2)!;
      return '$base/storage/media/customer_$cid/$tail';
    }

    if (url.startsWith('/')) return '$base$url';
    return '$base/$url';
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
          // Positioned(
          //   top: 20 * scale,
          //   right: 20 * scale,
          //   child: DecoratedBox(
          //     decoration: BoxDecoration(
          //       color: Colors.black54,
          //       borderRadius: BorderRadius.circular(12),
          //     ),
          //     child: Padding(
          //       padding: EdgeInsets.symmetric(horizontal: 12 * scale, vertical: 6 * scale),
          //       child: Text(
          //         _statusText(),
          //         style: TextStyle(color: Colors.white, fontSize: (12 * scale).clamp(11, 18)),
          //       ),
          //     ),
          //   ),
          // ),
        ],
      ),
    );
  }

  // String _statusText() {
  //   final days = _licenseDaysLeft != null ? ' • ${_licenseDaysLeft}d left' : '';
  //   final time = _serverTimeIso != null && _serverTimeIso!.isNotEmpty ? ' • $_serverTimeIso' : '';
  //   final ver = _contentVersion != null && _contentVersion!.isNotEmpty ? ' • $_contentVersion' : '';
  //   return '$_accountStatus$days$time$ver';
  // }

  Widget _buildCurrentSlide() {
    final item = _items[_currentIndex];

    // If local file missing, guarantee a valid absolute URL
    final displayUrl = item.localPath != null && File(item.localPath!).existsSync()
        ? null
        : _ensureAbsoluteUrl(_baseOrigin, item.url);

    if (item.type == 'image') {
      if (item.localPath != null && File(item.localPath!).existsSync()) {
        return Image.file(File(item.localPath!), fit: BoxFit.cover);
      }
      return Image.network(displayUrl!, fit: BoxFit.cover);
    }

    // (video support can be added later)
    return const SizedBox.shrink();
  }
}

class _PlayableItem {
  final String type; // image | (video later)
  final String url; // absolute after normalization
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
