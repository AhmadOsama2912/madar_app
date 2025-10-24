import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  List<_PlayableItem> _items = [];
  int _currentIndex = 0;
  Timer? _slideTimer;
  Timer? _heartbeatTimer;

  String? _token;
  String _baseOrigin = 'http://192.168.1.134:8000'; // fallback if not saved
  String? _contentVersion;

  // Heartbeat state
  String _accountStatus = 'unknown';
  int? _licenseDaysLeft;
  String? _serverTimeIso;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _slideTimer?.cancel();
    _heartbeatTimer?.cancel();
    super.dispose();
  }

  Future<void> _init() async {
    final prefs = await SharedPreferences.getInstance();
    _token = prefs.getString('token');
    _baseOrigin = prefs.getString('base_origin') ?? _baseOrigin;
    _contentVersion = prefs.getString('playlist_content_version');

    final rawItems = prefs.getString('playlist_items');
    if (rawItems != null && rawItems.isNotEmpty) {
      try {
        final decoded = jsonDecode(rawItems) as List<dynamic>;
        _items = decoded.map((e) => _PlayableItem.fromMap(Map<String, dynamic>.from(e))).toList();
      } catch (_) {
        // if old format, ignore
      }
    }

    setState(() {}); // refresh UI
    _startPlayback();
    _startHeartbeat();
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
    _sendHeartbeat(); // first ping now
  }

  Future<void> _sendHeartbeat() async {
  if (_token == null || _token!.isEmpty) return;

  final dio = Dio(BaseOptions(
    baseUrl: _baseOrigin, // e.g. http://192.168.1.134:8000
    headers: {
      'Accept': '*/*',
      'X-Screen-Token': _token, // matches your server
    },
    connectTimeout: const Duration(seconds: 8),
    receiveTimeout: const Duration(seconds: 8),
  ));

  final url = '/api/screen/v1/heartbeat';
  debugPrint('Sending heartbeat POST to ${dio.options.baseUrl}$url');

  try {
    final payload = <String, dynamic>{};
    if (_contentVersion != null && _contentVersion!.isNotEmpty) {
      payload['content_version'] = _contentVersion;
    }

    // Server expects POST (like your Insomnia screenshot)
    final resp = await dio.post(url, data: payload);

    debugPrint('Heartbeat response: ${resp.statusCode} ${resp.data}');

    if (resp.statusCode != null && resp.statusCode! >= 200 && resp.statusCode! < 300) {
      final data = (resp.data as Map<String, dynamic>);
      final status = (data['status'] ?? 'unknown').toString();
      final serverTime = (data['server_time'] ?? '').toString();
      final license = (data['license'] ?? {}) as Map<String, dynamic>;
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
    } else {
      debugPrint('Heartbeat non-2xx: ${resp.statusCode}');
    }
  } on DioException catch (e) {
    // Print exact root cause to diagnose networking vs. TLS vs. HTTP errors
    debugPrint('Heartbeat DioException: ${e.type} ${e.message}');
    if (e.response != null) {
      debugPrint('Response: ${e.response?.statusCode} ${e.response?.data}');
    }
  } catch (e) {
    debugPrint('Heartbeat error: $e');
  }
}


  // ---------- UI ----------

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final shortest = mq.size.shortestSide;
    final scale = (shortest / 720).clamp(0.75, 2.2);
    final logoSize = (mq.size.width * 0.22).clamp(140.0, 520.0);

    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (_items.isEmpty)
            Center(
              child: Image.asset(
                'assets/images/1.png', // keep default logo centered if no playlist
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
      backgroundColor: Colors.black,
    );
  }

  String _statusText() {
    final days = _licenseDaysLeft != null ? ' • ${_licenseDaysLeft}d left' : '';
    final time = _serverTimeIso != null && _serverTimeIso!.isNotEmpty ? ' • $_serverTimeIso' : '';
    return '$_accountStatus$days$time';
  }

  Widget _buildCurrentSlide() {
    final item = _items[_currentIndex];
    switch (item.type) {
      case 'image':
        if (item.localPath != null && File(item.localPath!).existsSync()) {
          return Image.file(File(item.localPath!), fit: BoxFit.cover);
        }
        return Image.network(item.url, fit: BoxFit.cover);
      // case 'video': // future: implement video playback
      default:
        return const SizedBox.shrink();
    }
  }
}

class _PlayableItem {
  final String type;      // image | (video in future)
  final String url;       // absolute URL
  final String? localPath;
  final int durationSec;

  _PlayableItem({
    required this.type,
    required this.url,
    required this.localPath,
    required this.durationSec,
  });

  factory _PlayableItem.fromMap(Map<String, dynamic> m) {
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
