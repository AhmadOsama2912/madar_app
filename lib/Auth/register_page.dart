import 'dart:convert';
import 'dart:io' show Platform, Directory, File;

import 'package:android_id/android_id.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:madar_app/homepage.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../core/tv_dpad_utility.dart';

class RegisterPage extends StatefulWidget {
  const RegisterPage({
    super.key,
    this.apiEndpoint = 'http://192.168.1.124:8000/api/screen/v1/register',
    this.buttonLabel = 'Register',
    this.headerTitle = 'Device Registration',
    this.logoAsset = 'assets/logo/2.png', // update if different
  });

  final String apiEndpoint;
  final String buttonLabel;
  final String headerTitle;
  final String logoAsset;

  @override
  State<RegisterPage> createState() => _RegisterPageState();
}

class _RegisterPageState extends State<RegisterPage> with TvDpadUtility<RegisterPage> {
  final _formKey = GlobalKey<FormState>();
  final _claimCodeCtrl = TextEditingController();

  bool _loading = false;
  String? _error;

  String? _serialNumber;
  String? _deviceModel;
  String? _osVersion;
  String? _appVersion;

  @override
  void initState() {
    super.initState();
    _initDeviceInfo();
  }

  @override
  void dispose() {
    _claimCodeCtrl.dispose();
    super.dispose();
  }

  // ---------- UTILITIES (inlined to avoid extra files) ----------

  Uri _baseOriginFrom(String apiEndpoint) {
    final u = Uri.parse(apiEndpoint);
    return Uri(scheme: u.scheme, host: u.host, port: u.port);
  }

  /// Convert "media/customer_<id>/file.png" -> "{origin}/storage/media/customer_<id>/file.png"
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

  // ---------- DEVICE INFO ----------

  Future<void> _initDeviceInfo() async {
    try {
      final deviceInfo = DeviceInfoPlugin();
      String deviceModel = 'Unknown';
      String osVersion = 'Unknown';
      String appVersion = 'Unknown';
      String serial = await _getSerialNumber();

      if (Platform.isAndroid) {
        final info = await deviceInfo.androidInfo;
        deviceModel = '${info.manufacturer} ${info.model}'.trim();
        osVersion = 'Android ${info.version.release}';
      } else if (Platform.isIOS) {
        final info = await deviceInfo.iosInfo;
        deviceModel = '${info.name} (${info.utsname.machine})';
        osVersion = 'iOS ${info.systemVersion}';
      } else {
        final base = await deviceInfo.deviceInfo;
        deviceModel = base.data['model']?.toString() ?? 'Unknown';
        osVersion = base.data['osVersion']?.toString() ?? 'Unknown';
      }

      final pkg = await PackageInfo.fromPlatform();
      appVersion = pkg.version.isNotEmpty ? pkg.version : '1.0.0';

      setState(() {
        _serialNumber = serial;
        _deviceModel = deviceModel;
        _osVersion = osVersion;
        _appVersion = appVersion;
      });
    } catch (e) {
      setState(() => _error = 'Failed to read device info: $e');
    }
  }

  Future<String> _getSerialNumber() async {
    try {
      if (Platform.isAndroid) {
        const androidId = AndroidId();
        final id = await androidId.getId() ?? '';
        if (id.isNotEmpty) return 'ANDROID_ID:$id';
      } else if (Platform.isIOS) {
        return 'IOS:NO_SERIAL';
      }
    } catch (_) {}
    return 'UNKNOWN_SERIAL';
  }

  // ---------- SUBMIT ----------

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _loading = true;
      _error = null;
    });

    final body = {
      "serial_number": _serialNumber ?? 'UNKNOWN_SERIAL',
      "device_model": _deviceModel ?? 'Unknown',
      "os_version": _osVersion ?? 'Unknown',
      "app_version": _appVersion ?? '1.0.0',
      "claim_code": _claimCodeCtrl.text.trim(),
    };

    try {
      final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 20),
        headers: {'Content-Type': 'application/json', 'Accept': 'application/json'},
      ));

      final resp = await dio.post(widget.apiEndpoint, data: body);

      if (resp.statusCode != null && resp.statusCode! >= 200 && resp.statusCode! < 300) {
        final data = resp.data as Map<String, dynamic>;
        final prefs = await SharedPreferences.getInstance();

        // Save basics
        final token = (data['token'] ?? '').toString();
        await prefs.setString('token', token);
        await prefs.setBool('device_registered', true);
        await prefs.setString('registered_serial', body['serial_number'] as String);
        await prefs.setString('registered_claim_code', body['claim_code'] as String);

        // Save origin once
        final baseOrigin = _baseOriginFrom(widget.apiEndpoint).toString();
        await prefs.setString('base_origin', baseOrigin);

        // Playlist handling + download
        final playlist = (data['playlist'] ?? {}) as Map<String, dynamic>;
        final items = (playlist['items'] ?? []) as List<dynamic>;
        final contentVersion = (playlist['content_version'] ?? '').toString();
        final updatedAt = (playlist['updated_at'] ?? '').toString();

        final mediaClient = Dio(BaseOptions(
          headers: {
            'Accept': 'application/json',
            if (token.isNotEmpty) 'Authorization': 'Bearer $token',
          },
          connectTimeout: const Duration(seconds: 25),
          receiveTimeout: const Duration(seconds: 40),
        ));

        final List<Map<String, dynamic>> resolved = [];
        for (final it in items) {
          final m = it as Map<String, dynamic>;
          final type = (m['type'] ?? '').toString();
          final rel = (m['url'] ?? '').toString();
          final duration = int.tryParse((m['duration_sec'] ?? '10').toString()) ?? 10;
          if (rel.isEmpty) continue;

          // Apply required prefix rule:
          final abs = _resolveCustomerMediaUrl(baseOrigin: baseOrigin, url: rel);
          final local = await _downloadToCache(mediaClient, abs);

          resolved.add({
            'type': type,
            'url': abs,
            'local_path': local,
            'duration_sec': duration,
          });
        }

        // Persist playlist
        await prefs.setString('playlist_items', jsonEncode(resolved));
        await prefs.setString('playlist_content_version', contentVersion);
        await prefs.setString('playlist_updated_at', updatedAt);

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Registration successful')),
          );
          Navigator.of(context).pushAndRemoveUntil(
            MaterialPageRoute(builder: (_) => const HomePage()),
            (route) => false,
          );
        }
      } else {
        setState(() => _error = 'Registration failed (HTTP ${resp.statusCode}).');
      }
    } on DioException catch (e) {
      setState(() {
        _error = e.response?.data?.toString() ?? 'Network error: ${e.message ?? e.toString()}';
      });
    } catch (e) {
      setState(() => _error = 'Unexpected error: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _refreshDeviceInfo() async {
    setState(() {
      _serialNumber = null;
      _deviceModel = null;
      _osVersion = null;
      _appVersion = null;
      _error = null;
      _loading = true;
    });
    await _initDeviceInfo();
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final w = mq.size.width;
    final h = mq.size.height;
    final shortest = mq.size.shortestSide;
    final scale = (shortest / 720).clamp(0.75, 2.2);

    final double pageMaxWidth = (w * 0.55).clamp(360, 1000);
    final double padding = 24 * scale;
    final double gap = 16 * scale;
    final double titleSize = (28 * scale).clamp(20, 44);
    final double infoLabelSize = (14 * scale).clamp(12, 20);
    final double infoValueSize = (14 * scale).clamp(12, 20);
    final double buttonHeight = (56 * scale).clamp(48, 72);
    final double logoWidth = (w * 0.18).clamp(120, 420);

    return Focus(
      autofocus: true,
      focusNode: rootFocusNode,
      onKey: handleDpadKey,
      child: Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, _) {
            return Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: pageMaxWidth),
                child: Padding(
                  padding: EdgeInsets.all(padding),
                  child: FocusTraversalGroup(
                    policy: OrderedTraversalPolicy(),
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Column(
                            children: [
                              Image.asset(widget.logoAsset, width: logoWidth, fit: BoxFit.contain),
                              SizedBox(height: 12 * scale),
                              Text(
                                widget.headerTitle,
                                textAlign: TextAlign.center,
                                style: TextStyle(fontSize: titleSize, fontWeight: FontWeight.bold),
                              ),
                            ],
                          ),
                          SizedBox(height: gap),

                          Form(
                            key: _formKey,
                            child: TextFormField(
                              controller: _claimCodeCtrl,
                              textInputAction: TextInputAction.done,
                              style: TextStyle(fontSize: infoValueSize),
                              decoration: InputDecoration(
                                labelText: 'Claim code',
                                hintText: 'e.g. GFB9C4CN',
                                prefixIcon: const Icon(Icons.verified_user),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12 * scale),
                                ),
                                contentPadding: EdgeInsets.symmetric(
                                  horizontal: 16 * scale,
                                  vertical: 14 * scale,
                                ),
                              ),
                              validator: (v) {
                                final val = v?.trim() ?? '';
                                if (val.isEmpty) return 'Please enter your claim code';
                                if (val.length < 6) return 'Claim code looks too short';
                                return null;
                              },
                              onFieldSubmitted: (_) => _submit(),
                            ),
                          ),

                          if (_error != null) ...[
                            SizedBox(height: 12 * scale),
                            Text(_error!, style: const TextStyle(color: Colors.red), textAlign: TextAlign.center),
                          ],

                          SizedBox(height: gap * 1.25),

                          SizedBox(
                            width: double.infinity,
                            height: buttonHeight,
                            child: ElevatedButton.icon(
                              icon: _loading
                                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                                  : const Icon(Icons.send),
                              label: Text(
                                _loading ? 'Submitting...' : widget.buttonLabel,
                                style: TextStyle(fontSize: (18 * scale).clamp(16, 28), fontWeight: FontWeight.w600),
                              ),
                              onPressed: _loading ? null : _submit,
                            ),
                          ),

                          SizedBox(height: 12 * scale),
                          Text(
                            'By registering, this device will be linked to your dashboard using the claim code.',
                            textAlign: TextAlign.center,
                            style: TextStyle(fontSize: (12 * scale).clamp(11, 18), color: Colors.black54),
                          ),

                          SizedBox(height: h * 0.04),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
      backgroundColor: Colors.white,
      ),
    );
  }

  Widget _kv(String label, String? value, {double valueSize = 14}) {
    final v = value ?? 'Reading...';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(child: Text(label, style: const TextStyle(fontWeight: FontWeight.w600))),
          const SizedBox(width: 12),
          Expanded(
            child: SelectableText(
              v,
              textAlign: TextAlign.right,
              style: TextStyle(fontFamily: 'monospace', fontSize: valueSize),
            ),
          ),
        ],
      ),
    );
  }
}
